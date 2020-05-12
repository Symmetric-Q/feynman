module Feynman.Optimization.HPhaseFold where

import Feynman.Core hiding (subst)
import Feynman.Algebra.Base
import Feynman.Algebra.Linear
import Feynman.Algebra.Polynomial hiding (zero, one, terms)
import qualified Feynman.Algebra.Polynomial as P
import Feynman.Synthesis.Phase

import Data.List hiding (transpose)
import Data.Maybe

import Data.Map.Strict (Map, (!))
import qualified Data.Map.Strict as Map

import Data.Set (Set)
import qualified Data.Set as Set

import Control.Monad.State.Strict

import Data.Bits

import Debug.Trace

{-- Super-phase folding -}
{- The idea here is to apply some [HH] reductions when possible
   to help find extra T reductions. This should be a more
   principled approach to Hadamard conjugation, and if we let
   apply full [HH] reductions (i.e. not just linear ones)
   we should be able to identify compute-uncompute patterns -}

data AnalysisState = SOP {
  dim   :: Int,
  ket   :: Map ID BasisSt,
  terms :: Map Parity (Set (Loc, Bool), Angle),
  pp    :: Multilinear Angle,
  paths :: Set Int,
  phase :: Angle
} deriving Show

type Parity = F2Vec
type BasisSt = (Parity, Bool)
type Analysis = State AnalysisState

-- The /i/th variable
var :: Int -> String
var i = "v" ++ show i

-- The number of a variable
unvar :: String -> Int
unvar = read . tail

-- Allocate a new variable
alloc :: Analysis Int
alloc = do
  n <- gets dim
  modify $ \st -> st { dim = n + 1 }
  return n

-- Get the state of variable v
getSt :: ID -> Analysis BasisSt
getSt v = get >>= \st ->
  case Map.lookup v (ket st) of
    Just bv -> return bv
    Nothing -> do
      n <- alloc
      modify $ \st -> st { ket = Map.insert v (bit n, False) (ket st) }
      return (bit n, False)

-- Set the state of a variable
setSt :: ID -> BasisSt -> Analysis ()
setSt v bv = modify $ \st -> st { ket = Map.insert v bv (ket st) }

-- Adds a mergeable phase term
addTerm :: Angle -> Loc -> BasisSt -> Analysis ()
addTerm theta l (bv, p) =
  case p of
    False -> modify $ \st -> st { terms = Map.alter (f theta) bv (terms st),
                                  pp    = pp st + distribute theta (multilinearOfBV (bv ,p)) }
    True  -> modify $ \st -> st { terms = Map.alter (f (-theta)) bv (terms st),
                                  pp    = pp st + distribute theta (multilinearOfBV (bv ,p)),
                                  phase = (phase st) + theta }
  where f theta' (Just (s, x)) = Just (Set.insert (l, p) s, x + theta')
        f theta' Nothing       = Just (Set.singleton (l, p), theta')

-- Adds a quadratic (unmergeable) phase term
addQuadTerm :: Int -> BasisSt -> Analysis ()
addQuadTerm n bv = modify $ \st -> st { pp = pp st + ofVar (var n) * quad } where
  quad = distribute (Discrete $ dyadic 1 1) (multilinearOfBV bv)

-- Finding [HH] reductions
applyReductions :: Analysis ()
applyReductions = do
  poly     <- gets pp
  pathVars <- gets paths
  outVars  <- gets (Set.unions . map (varsOfBV . fst) . Map.elems . ket)
  case matchHHLinear poly $ Set.difference pathVars outVars of
    Nothing         -> return ()
    Just (x, y, bv) -> do
      elimVar x
      substVar y bv
      applyReductions

-- Remove an internal variable
elimVar :: Int -> Analysis ()
elimVar x = modify $ \st -> st { terms = Map.filterWithKey f $ terms st,
                                 pp    = removeVar (var x) $ pp st }
  where f parity _ = Set.notMember x $ varsOfBV parity

-- Substitute a variable
substVar :: Int -> BasisSt -> Analysis ()
substVar x bv = modify $ \st -> st { terms = Map.mapKeysWith add f $ terms st,
                                     pp    = subst (var x) (multilinearOfBV bv) $ pp st,
                                     ket   = Map.map g $ ket st }
  where add (s1, a1) (s2, a2) = (Set.union s1 s2, a1 + a2)
        f parity = case testBit parity x of
            False -> parity
            True  -> (complementBit parity x) + (fst bv)
        g bv     = (f $ fst bv, snd bv)

{- Utilities -}

injectZ2 :: Periodic a => a -> Maybe Bool
injectZ2 a = case order a of
  0 -> Just False
  2 -> Just True
  _ -> Nothing

toBooleanPoly :: (Eq a, Periodic a) => Multilinear a -> Maybe (Multilinear Bool)
toBooleanPoly = convertMaybe injectZ2 . simplify

-- Converts a bitvector into a polynomial
multilinearOfBV :: BasisSt -> Multilinear Bool
multilinearOfBV bv = Set.foldr (+) const . Set.map (ofVar . var) . varsOfBV $ fst bv
  where const = if snd bv then 1 else 0

-- Gets the variables in a bitvector
varsOfBV :: Parity -> Set Int
varsOfBV bv = Set.fromList $ filter (testBit bv) [0..(width bv) - 1]

-- Converts a linear Boolean polynomial into a bitvector
bvOfMultilinear :: Multilinear Bool -> Maybe BasisSt
bvOfMultilinear p
  | degree p > 1 = Nothing
  | otherwise    = Just $ unsafeConvert p
    where unsafeConvert = (foldl' f (bitI 0 0, False)). Map.toList . P.terms
          f (bv, const) (m, b)
            | b == False      = (bv, const)
            | emptyMonomial m = (bv, const `xor` True)
            | otherwise       =
              let v = unvar $ firstVar m in
                (bv `xor` (bitI (v+1) v), const)

-- Matches a *linear* instance of [HH]
matchHHLinear :: Multilinear Angle -> Set Int -> Maybe (Int, Int, BasisSt)
matchHHLinear poly paths = msum . map (go . var) $ Set.toDescList paths where
  go v = do
    p'       <- toBooleanPoly $ factorOut v poly
    (u, sub) <- find (\(u, sub) -> (unvar u) `elem` paths && degree sub <= 1) $ solveForX p'
    bv       <- bvOfMultilinear sub
    return (unvar v, unvar u, bv)

{-- The main algorithm -}
applyGate :: (Primitive, Loc) -> Analysis ()
applyGate (gate, l) = case gate of
  T v    -> getSt v >>= addTerm (Discrete $ dyadic 1 3) l
  Tinv v -> getSt v >>= addTerm (Discrete $ dyadic 7 3) l
  S v    -> getSt v >>= addTerm (Discrete $ dyadic 1 2) l
  Sinv v -> getSt v >>= addTerm (Discrete $ dyadic 3 2) l
  Z v    -> getSt v >>= addTerm (Discrete $ dyadic 1 1) l
  Rz p v -> getSt v >>= addTerm p l
  CNOT c t -> do
    bv  <- getSt c
    bv' <- getSt t
    setSt t (fst bv + fst bv', snd bv `xor` snd bv')
  X v      -> do
    bv <- getSt v
    setSt v (fst bv, Prelude.not $ snd bv)
  H v      -> do
    bv <- getSt v
    n <- alloc
    modify $ \st -> st { paths = Set.insert n $ paths st }
    addQuadTerm n bv
    setSt v (bit n, False)
  Swap u v -> do
    bv  <- getSt u
    bv' <- getSt v
    setSt u bv'
    setSt v bv
  _      -> error "Unsupported gate"
  
runAnalysis :: [ID] -> [ID] -> [Primitive] -> AnalysisState
runAnalysis vars inputs gates =
  let init = 
        SOP { dim   = dim', 
              ket   = Map.fromList ivals, 
              terms = Map.empty,
              pp    = 0,
              paths = Set.empty,
              phase = 0 }
  in
    execState (mapM_ applyGate (zip gates [2..]) >> applyReductions) init
  where dim'    = length inputs
        bitvecs = [(bitI dim' x, False) | x <- [0..]] 
        ivals   = zip (inputs ++ (vars \\ inputs)) bitvecs

hPhaseFold :: [ID] -> [ID] -> [Primitive] -> [Primitive]
hPhaseFold vars inputs gates =
  let (SOP _ _ terms _ _ phase) = runAnalysis vars inputs gates
      (lmap, phase') =
        let f (lmap, phase) (locs, exp) =
              let (i, phase', exp') = case Set.findMax locs of
                    (i, False) -> (i, phase, exp)
                    (i, True)  -> (i, phase + exp, (-exp))
              in
                (Set.foldr (\(j, _) -> Map.insert j (if i == j then exp' else zero)) lmap locs, phase')
        in
          foldl' f (Map.empty, phase) (Map.elems terms)
      gates' =
        let getTarget gate = case gate of
              T x    -> x
              S x    -> x
              Z x    -> x
              Tinv x -> x
              Sinv x -> x
              Rz _ x -> x
            f (gate, i) = case Map.lookup i lmap of
              Nothing -> [(gate, i)]
              Just exp
                | exp == zero -> []
                | otherwise   -> zip (synthesizePhase (getTarget gate) exp) (repeat i)
        in
          concatMap f (zip gates [2..])
  in
    (fst $ unzip $ gates') ++ (globalPhase (head vars) phase')

  
