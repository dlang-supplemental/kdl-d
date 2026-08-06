module kdl.ast;

import std.algorithm : canFind;
import std.array : appender;
import std.conv : to;
import std.exception : enforce;
import std.format : format;
import std.math : isInfinity, isNaN;
import std.variant : Algebraic;

/// Dialect requested when parsing or writing.
enum KdlVersion
{
	/// Prefer KDL 2.0; fall back to 1.0 when parse fails and auto is set.
	auto_,
	/// Legacy KDL 1.0 (`true`/`false`/`null`, `r#"..."#`).
	v1,
	/// KDL 2.0 (`#true`/`#false`/`#null`, `#""#` raw strings).
	v2,
}

/// Scalar value kinds stored on nodes.
enum KdlValueKind
{
	null_,
	bool_,
	int_,
	float_,
	string_,
}

/// A typed KDL value (argument or property value).
struct KdlValue
{
	KdlValueKind kind = KdlValueKind.null_;
	string typeAnnotation;
	private Algebraic!(bool, long, double, string) _payload;

	static KdlValue nullValue(string typeAnnotation = null)
	{
		KdlValue v;
		v.kind = KdlValueKind.null_;
		v.typeAnnotation = typeAnnotation;
		return v;
	}

	static KdlValue fromBool(bool b, string typeAnnotation = null)
	{
		KdlValue v;
		v.kind = KdlValueKind.bool_;
		v.typeAnnotation = typeAnnotation;
		v._payload = b;
		return v;
	}

	static KdlValue fromInt(long n, string typeAnnotation = null)
	{
		KdlValue v;
		v.kind = KdlValueKind.int_;
		v.typeAnnotation = typeAnnotation;
		v._payload = n;
		return v;
	}

	static KdlValue fromFloat(double n, string typeAnnotation = null)
	{
		KdlValue v;
		v.kind = KdlValueKind.float_;
		v.typeAnnotation = typeAnnotation;
		v._payload = n;
		return v;
	}

	static KdlValue fromString(string s, string typeAnnotation = null)
	{
		KdlValue v;
		v.kind = KdlValueKind.string_;
		v.typeAnnotation = typeAnnotation;
		v._payload = s;
		return v;
	}

	@property bool isNull() const { return kind == KdlValueKind.null_; }
	@property bool asBool() const
	{
		enforce(kind == KdlValueKind.bool_, "value is not a boolean");
		return _payload.get!bool;
	}
	@property long asInt() const
	{
		if (kind == KdlValueKind.int_)
			return _payload.get!long;
		if (kind == KdlValueKind.float_)
			return cast(long) _payload.get!double;
		throw new Exception("value is not a number");
	}
	@property double asFloat() const
	{
		if (kind == KdlValueKind.float_)
			return _payload.get!double;
		if (kind == KdlValueKind.int_)
			return cast(double) _payload.get!long;
		throw new Exception("value is not a number");
	}
	@property string asString() const
	{
		enforce(kind == KdlValueKind.string_, "value is not a string");
		return _payload.get!string;
	}

	string toString() const
	{
		final switch (kind)
		{
		case KdlValueKind.null_:
			return "null";
		case KdlValueKind.bool_:
			return asBool ? "true" : "false";
		case KdlValueKind.int_:
			return asInt.to!string;
		case KdlValueKind.float_:
			auto f = asFloat;
			if (isNaN(f))
				return "nan";
			if (isInfinity(f))
				return f < 0 ? "-inf" : "inf";
			return f.to!string;
		case KdlValueKind.string_:
			return asString;
		}
	}
}

/// Key/value property on a node. Later duplicates override earlier ones.
struct KdlProperty
{
	string name;
	KdlValue value;
}

/// A KDL node: name, optional type annotation, args, properties, children.
struct KdlNode
{
	string name;
	string typeAnnotation;
	KdlValue[] arguments;
	KdlProperty[] properties;
	KdlNode[] children;

	/// Last property with the given name, or `null` if absent.
	inout(KdlProperty)* property(string name) inout
	{
		inout(KdlProperty)* found;
		foreach (ref p; properties)
			if (p.name == name)
				found = &p;
		return found;
	}

	/// All direct children with the given name.
	inout(KdlNode)[] childrenNamed(string name) inout
	{
		inout(KdlNode)[] result;
		foreach (ref c; children)
			if (c.name == name)
				result ~= c;
		return result;
	}

	/// First direct child with the given name, or `null`.
	inout(KdlNode)* child(string name) inout
	{
		foreach (ref c; children)
			if (c.name == name)
				return &c;
		return null;
	}
}

/// Top-level KDL document (ordered list of nodes).
struct KdlDocument
{
	KdlNode[] nodes;
	/// Dialect that successfully parsed the document (when known).
	KdlVersion parsedAs = KdlVersion.auto_;

	inout(KdlNode)* node(string name) inout
	{
		foreach (ref n; nodes)
			if (n.name == name)
				return &n;
		return null;
	}

	inout(KdlNode)[] nodesNamed(string name) inout
	{
		inout(KdlNode)[] result;
		foreach (ref n; nodes)
			if (n.name == name)
				result ~= n;
		return result;
	}
}
