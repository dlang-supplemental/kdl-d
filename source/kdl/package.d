/++
	Native KDL document language library for D.

	Supports a hybrid of KDL 1.0 and KDL 2.0: parse tries the requested
	dialect (default: auto — prefer v2, then fall back to v1 when the
	document is unambiguous with the other version).

	See https://kdl.dev/ and https://github.com/kdl-org/kdl
+/
module kdl;

public import kdl.ast;
public import kdl.exception;
public import kdl.parse;
public import kdl.write;
