.v a b c
.i a b c

BEGIN Toffoli(x y z)
	H z
	T x
	T y
	T z
	cnot x y
	cnot y z
	cnot z x
	T* x
	T* y
	T z
	cnot y x
	T* x
	cnot y z
	cnot z x
	cnot x y
	H z
END

BEGIN CS(x y)
	T* x
	T* y
	cnot x y
	T y
	cnot x y
END

BEGIN
Toffoli a b c
CS a b
END
