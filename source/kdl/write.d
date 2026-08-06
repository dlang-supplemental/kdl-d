module kdl.write;

import std.algorithm : among, canFind;
import std.array : Appender, appender;
import std.conv : to;
import std.format : format;
import std.math : isInfinity, isNaN;

import kdl.ast;

/// Serialize a document to KDL text.
string writeKdl(const KdlDocument doc, KdlVersion ver = KdlVersion.v2, bool pretty = true)
{
	auto buf = appender!string();
	foreach (i, ref node; doc.nodes)
	{
		writeNode(buf, node, ver, pretty, 0);
		if (i + 1 < doc.nodes.length || pretty)
			buf.put('\n');
	}
	return buf.data;
}

/// Serialize a single node.
string writeKdl(const KdlNode node, KdlVersion ver = KdlVersion.v2, bool pretty = true)
{
	auto buf = appender!string();
	writeNode(buf, node, ver, pretty, 0);
	return buf.data;
}

private void writeNode(ref Appender!string buf, const ref KdlNode node, KdlVersion ver,
	bool pretty, int indent)
{
	if (pretty)
		foreach (i; 0 .. indent)
			buf.put('\t');
	if (node.typeAnnotation.length)
	{
		buf.put('(');
		buf.put(formatIdent(node.typeAnnotation, ver));
		buf.put(')');
	}
	buf.put(formatIdent(node.name, ver));
	foreach (ref arg; node.arguments)
	{
		buf.put(' ');
		writeValue(buf, arg, ver);
	}
	foreach (ref prop; node.properties)
	{
		buf.put(' ');
		buf.put(formatIdent(prop.name, ver));
		buf.put('=');
		writeValue(buf, prop.value, ver);
	}
	if (node.children.length)
	{
		buf.put(" {");
		if (pretty)
			buf.put('\n');
		foreach (ref child; node.children)
		{
			writeNode(buf, child, ver, pretty, indent + 1);
			if (pretty)
				buf.put('\n');
			else
				buf.put("; ");
		}
		if (pretty)
			foreach (i; 0 .. indent)
				buf.put('\t');
		buf.put('}');
	}
}

private void writeValue(ref Appender!string buf, const ref KdlValue value, KdlVersion ver)
{
	if (value.typeAnnotation.length)
	{
		buf.put('(');
		buf.put(formatIdent(value.typeAnnotation, ver));
		buf.put(')');
	}
	final switch (value.kind)
	{
	case KdlValueKind.null_:
		buf.put(ver == KdlVersion.v1 ? "null" : "#null");
		break;
	case KdlValueKind.bool_:
		if (ver == KdlVersion.v1)
			buf.put(value.asBool ? "true" : "false");
		else
			buf.put(value.asBool ? "#true" : "#false");
		break;
	case KdlValueKind.int_:
		buf.put(value.asInt.to!string);
		break;
	case KdlValueKind.float_:
		auto f = value.asFloat;
		if (isNaN(f))
			buf.put(ver == KdlVersion.v1 ? "nan" : "#nan"); // v1 has no nan keyword; quote if needed
		else if (isInfinity(f))
		{
			if (ver == KdlVersion.v1)
				buf.put(f < 0 ? "-inf" : "inf");
			else
				buf.put(f < 0 ? "#-inf" : "#inf");
		}
		else
			buf.put(format("%.16g", f));
		break;
	case KdlValueKind.string_:
		buf.put(formatString(value.asString, ver));
		break;
	}
}

private string formatIdent(string s, KdlVersion ver)
{
	if (canBareIdent(s, ver))
		return s;
	return formatString(s, ver);
}

private bool canBareIdent(string s, KdlVersion ver)
{
	if (!s.length)
		return false;
	if (ver == KdlVersion.v2 && s.among!("true", "false", "null", "inf", "-inf", "nan"))
		return false;
	if (ver == KdlVersion.v1 && s.among!("true", "false", "null"))
		return false;
	import std.utf : decode;
	size_t i = 0;
	auto c0 = decode(s, i);
	if ((c0 >= '0' && c0 <= '9') || isBannedIdentChar(c0, ver))
		return false;
	if ((c0 == '+' || c0 == '-') && i < s.length)
	{
		auto c1 = decode(s, i);
		if (c1 >= '0' && c1 <= '9')
			return false;
	}
	i = 0;
	while (i < s.length)
	{
		auto c = decode(s, i);
		if (isBannedIdentChar(c, ver) || c <= 0x20)
			return false;
	}
	return true;
}

private bool isBannedIdentChar(dchar c, KdlVersion ver)
{
	import std.algorithm : canFind, among;
	if (ver == KdlVersion.v2)
		return canFind(`\/(){};[]"#=`, c);
	return canFind(`\/(){}<>;[]=,"`, c);
}

private string formatString(string s, KdlVersion ver)
{
	import std.array : appender;
	auto buf = appender!string();
	buf.put('"');
	foreach (dchar c; s)
	{
		switch (c)
		{
		case '"':
			buf.put(`\"`);
			break;
		case '\\':
			buf.put(`\\`);
			break;
		case '\n':
			buf.put(`\n`);
			break;
		case '\r':
			buf.put(`\r`);
			break;
		case '\t':
			buf.put(`\t`);
			break;
		case '\b':
			buf.put(`\b`);
			break;
		case '\f':
			buf.put(`\f`);
			break;
		default:
			if (c < 0x20)
				buf.put(format(`\u{%x}`, cast(uint) c));
			else
				buf.put(c);
		}
	}
	buf.put('"');
	return buf.data;
}

unittest
{
	import kdl.parse : parseKdl;
	auto src = `package name="kdl" {
	dependency "foo" version="1.0"
}
`;
	auto doc = parseKdl(src);
	auto out_ = writeKdl(doc, doc.parsedAs == KdlVersion.auto_ ? KdlVersion.v2 : doc.parsedAs);
	auto again = parseKdl(out_);
	assert(again.nodes[0].name == "package");
	assert(again.nodes[0].property("name").value.asString == "kdl");
}
