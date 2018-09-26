OPENQASM 2.0;
include "qelib1.inc";
gate adder a0,a1,a2,a3,b0,b1,b2,b3,cin,cout
{
	cx a0,b0;
	cx a0,cin;
	ccx cin,b0,a0;
	cx a1,b1;
	cx a1,a0;
	ccx a0,b1,a1;
	cx a2,b2;
	cx a2,a1;
	ccx a1,b2,a2;
	cx a3,b3;
	cx a3,a2;
	ccx a2,b3,a3;
	cx a3,cout;
	ccx a2,b3,a3;
	cx a3,a2;
	cx a2,b3;
	ccx a1,b2,a2;
	cx a2,a1;
	cx a1,b2;
	ccx a0,b1,a1;
	cx a1,a0;
	cx a0,b1;
	ccx cin,b0,a0;
	cx a0,cin;
	cx cin,b0;
}
