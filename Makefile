feyn: src/*
	cabal build feyn
	cp dist/build/feyn/feyn ./feyn

prof: src/*
	cabal build feyn-prof
	cp dist/build/feyn-prof/feyn-prof ./feyn-prof
