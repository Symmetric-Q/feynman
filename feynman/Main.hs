{-# LANGUAGE TupleSections #-}
module Main (main) where

import Feynman.Core (Primitive(CNOT, T, Tinv), ID)
import Feynman.Frontend.DotQC
import Feynman.Optimization.PhaseFold
import Feynman.Optimization.TPar
import Feynman.Verification.SOP

import System.Environment

import Data.List

import Data.Set (Set)
import qualified Data.Set as Set

import Data.Map (Map)
import qualified Data.Map as Map

import Control.Monad
import System.Time
import System.Random
import Control.DeepSeq

import Benchmarks

{- Toolkit passes -}

type DotQCPass = DotQC -> Either String DotQC

trivPass :: DotQCPass
trivPass = Right

inlinePass :: DotQCPass
inlinePass = Right . inlineDotQC

optimizationPass :: ([ID] -> [ID] -> [Primitive] -> [Primitive]) -> DotQCPass
optimizationPass f qc = Right $ qc { decls = map applyOpt $ decls qc }
  where applyOpt decl = decl { body = wrap (f (qubits qc ++ params decl) (inp ++ params decl)) $ body decl }
        wrap g        = fromCliffordT . g . toCliffordT
        inp           = Set.toList $ inputs qc

phasefoldPass :: DotQCPass
phasefoldPass = optimizationPass phaseFold

tparPass :: DotQCPass
tparPass = optimizationPass tpar

cnotminPass :: DotQCPass
cnotminPass = optimizationPass minCNOT

simplifyPass :: DotQCPass
simplifyPass = Right . simplifyDotQC

badPass :: StdGen -> DotQCPass
badPass = gen optimizationPass f
  where f _ _ gates =
          let (i, _) = randomR (0, length gates) gen in
            (\(pref, suff) -> pref ++ tail suff) $ splitAt i gates

equivalenceCheck :: DotQC -> DotQC -> Either String DotQC
equivalenceCheck qc qc' =
  let gatelist      = toCliffordT . toGatelist $ qc
      gatelist'     = toCliffordT . toGatelist $ qc'
      primaryInputs = Set.toList $ inputs qc
      result        = validate (union (qubits qc) (qubits qc')) primaryInputs gatelist gatelist'
  in
    case (inputs qc == inputs qc', result) of
      (False, _)    -> Left $ "Failed to verify: different inputs"
      (_, Just sop) -> Left $ "Failed to verify: " ++ show sop
      _             -> Right qc'

{- Main program -}

run :: DotQCPass -> Bool -> String -> String -> IO ()
run pass verify fname src = do
  TOD starts startp <- getClockTime
  TOD ends endp     <- parseAndPass `seq` getClockTime
  case parseAndPass of
    Left err        -> putStrLn $ "ERROR: " ++ err
    Right (qc, qc') -> do
      let time = (fromIntegral $ ends - starts) * 1000 + (fromIntegral $ endp - startp) / 10^9
      putStrLn $ "# Feynman -- quantum circuit toolkit"
      putStrLn $ "# Original (" ++ fname ++ "):"
      mapM_ putStrLn . map ("#   " ++) $ showCliffordTStats qc
      putStrLn $ "# Result (" ++ formatFloatN time 3 ++ "ms):"
      mapM_ putStrLn . map ("#   " ++) $ showCliffordTStats qc'
      putStrLn $ show qc'
  where printErr (Left l)  = Left $ show l
        printErr (Right r) = Right r
        parseAndPass = do
          qc  <- printErr $ parseDotQC src
          qc' <- pass qc
          seq (depth $ toGatelist qc') (return ()) -- Nasty solution to strictifying
          when verify . void $ equivalenceCheck qc qc'
          return (qc, qc')

printHelp :: IO ()
printHelp = mapM_ putStrLn lines
  where lines = [
          "Feynman -- quantum circuit toolkit",
          "Written by Matthew Amy",
          "",
          "Run with feyn [passes] (<circuit>.qc | Small | Med | All)",
          "",
          "Passes:",
          "  -inline\tInline all sub-circuits",
          "  -simplify\tBasic gate-cancellation pass",
          "  -phasefold\tPhase folding pass, merges phase gates. Non-increasing in all metrics",
          "  -tpar\t\tPhase folding + T-parallelization algorithm from [AMM14]",
          "  -cnotmin\tPhase folding + CNOT-minimization algorithm from [AAM17]",
          "  -verify\tPerform verification algorithm of [A18] after optimization passes",
          "",
          "E.g. \"feyn -verify -inline -cnotmin -simplify circuit.qc\" will first inline the circuit,",
          "       then optimize CNOTs, followed by a gate cancellation pass and finally verify the result",
          "",
          "WARNING: Using \"-verify\" with \"All\" will likely crash your computer without first setting",
          "         user-level memory limits. Use with caution"
          ]
          

parseArgs :: DotQCPass -> Bool -> [String] -> IO ()
parseArgs pass verify []     = printHelp
parseArgs pass verify (x:xs) = case x of
  "-h"         -> printHelp
  "-inline"    -> parseArgs (pass >=> inlinePass) verify xs
  "-phasefold" -> parseArgs (pass >=> phasefoldPass) verify xs
  "-cnotmin"   -> parseArgs (pass >=> cnotminPass) verify xs
  "-tpar"      -> parseArgs (pass >=> tparPass) verify xs
  "-simplify"  -> parseArgs (pass >=> simplifyPass) verify xs
  "-bad"       -> newStdGen >>= \g -> parseArgs (pass >=> badPass g) verify xs
  "-verify"    -> parseArgs pass True xs
  "VerBench"   -> runBenchmarks cnotminPass (Just equivalenceCheck) benchmarksMedium
  "VerAlg"     -> runVerSuite
  "Small"      -> runBenchmarks pass (if verify then Just equivalenceCheck else Nothing) benchmarksSmall
  "Med"        -> runBenchmarks pass (if verify then Just equivalenceCheck else Nothing) benchmarksMedium
  "All"        -> runBenchmarks pass (if verify then Just equivalenceCheck else Nothing) benchmarksAll
  "HS"         -> simulateHiddenShift (read $ head xs) (read . head $ tail xs) ()
  f | (drop (length f - 3) f) == ".qc" -> readFile f >>= run pass verify f
  f | otherwise -> putStrLn ("Unrecognized option \"" ++ f ++ "\"") >> printHelp

main :: IO ()
main = getArgs >>= parseArgs trivPass False
