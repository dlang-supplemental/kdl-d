module kdl.parse;

import std.algorithm : among, canFind, startsWith;
import std.array : appender;
import std.ascii : isDigit, isHexDigit;
import std.conv : parse, to;
import std.exception : enforce;
import std.format : format;
import std.math : isInfinity, isNaN;
import std.string : strip;
import std.utf : decode, stride;

import kdl.ast;
import kdl.exception;

/// Parse KDL source into a document.
///
/// With `KdlVersion.auto_`, tries KDL 2.0 first, then falls back to 1.0.
KdlDocument parseKdl(string source, KdlVersion ver = KdlVersion.auto_)
{
	auto hint = detectVersionHint(source);
	if (ver == KdlVersion.auto_ && hint != KdlVersion.auto_)
		ver = hint;

	if (ver == KdlVersion.v1)
		return parseFixed(source, KdlVersion.v1);
	if (ver == KdlVersion.v2)
		return parseFixed(source, KdlVersion.v2);

	try
	{
		return parseFixed(source, KdlVersion.v2);
	}
	catch (KdlParseException e2)
	{
		try
		{
			return parseFixed(source, KdlVersion.v1);
		}
		catch (KdlParseException e1)
		{
			throw e2; // prefer the v2 error for modern docs
		}
	}
}

private KdlVersion detectVersionHint(string source)
{
	size_t i = 0;
	if (source.length >= 3 && source[0] == 0xEF && source[1] == 0xBB && source[2] == 0xBF)
		i = 3;
	skipWsAndBom(source, i);
	// /- kdl-version N
	if (i + 2 <= source.length && source[i] == '/' && source[i + 1] == '-')
	{
		auto j = i + 2;
		skipSpaces(source, j);
		if (source[j .. $].startsWith("kdl-version"))
		{
			j += "kdl-version".length;
			skipSpaces(source, j);
			if (j < source.length && source[j] == '1')
				return KdlVersion.v1;
			if (j < source.length && source[j] == '2')
				return KdlVersion.v2;
		}
	}
	return KdlVersion.auto_;
}

private void skipWsAndBom(string s, ref size_t i)
{
	if (i + 3 <= s.length && s[i] == 0xEF && s[i + 1] == 0xBB && s[i + 2] == 0xBF)
		i += 3;
	skipSpaces(s, i);
}

private void skipSpaces(string s, ref size_t i)
{
	while (i < s.length)
	{
		auto c = s[i];
		if (c == ' ' || c == '\t' || c == '\u00A0')
			i++;
		else
			break;
	}
}

private KdlDocument parseFixed(string source, KdlVersion ver)
{
	auto p = Parser(source, ver);
	auto doc = p.parseDocument();
	doc.parsedAs = ver;
	return doc;
}

private struct Parser
{
	string src;
	KdlVersion ver;
	size_t pos;
	size_t line = 1;
	size_t col = 1;

	this(string source, KdlVersion ver)
	{
		this.src = source;
		this.ver = ver;
		if (src.length >= 3 && src[0] == 0xEF && src[1] == 0xBB && src[2] == 0xBF)
			advance(3);
	}

	KdlDocument parseDocument()
	{
		KdlDocument doc;
		skipLinespace();
		while (!eof)
		{
			if (peekSlashdash())
			{
				consumeSlashdash();
				if (!eof && !atNodeTerminator)
					parseNode(true); // discarded
				skipLinespace();
				continue;
			}
			if (atNodeTerminator && !eof)
			{
				// lone newline/semicolon
				if (peek == ';')
					advance();
				else
					skipNewline();
				skipLinespace();
				continue;
			}
			if (eof)
				break;
			doc.nodes ~= parseNode(false);
			skipLinespace();
		}
		return doc;
	}

	KdlNode parseNode(bool slashdashed)
	{
		KdlNode node;
		skipNodeSpace();
		if (peek == '(')
			node.typeAnnotation = parseTypeAnnotation();
		skipNodeSpace();
		node.name = parseIdentifier();
		while (true)
		{
			auto saved = save();
			skipNodeSpace();
			if (eof || atNodeTerminator || peek == '{')
			{
				restore(saved);
				break;
			}
			if (peekSlashdash())
			{
				consumeSlashdash();
				skipNodeSpace();
				if (peek == '{')
				{
					parseChildren(true);
					continue;
				}
				// discard prop or arg
				parsePropOrArg(true);
				continue;
			}
			if (peek == '{')
			{
				restore(saved);
				break;
			}
			auto entry = parsePropOrArg(false);
			if (entry.isProp)
				upsertProp(node, entry.name, entry.value);
			else
				node.arguments ~= entry.value;
		}
		skipNodeSpace();
		if (peekSlashdash())
		{
			// optional slashdashed children before real children
			while (peekSlashdash())
			{
				consumeSlashdash();
				skipNodeSpace();
				if (peek == '{')
					parseChildren(true);
				else
					break;
				skipNodeSpace();
			}
		}
		skipNodeSpace();
		if (peek == '{')
			node.children = parseChildren(false);
		skipNodeSpace();
		// trailing slashdashed children
		while (peekSlashdash())
		{
			consumeSlashdash();
			skipNodeSpace();
			if (peek == '{')
				parseChildren(true);
			else
				break;
			skipNodeSpace();
		}
		if (!eof && !atNodeTerminator)
			error("expected node terminator");
		if (peek == ';')
			advance();
		else if (!eof && isNewline(peek))
			skipNewline();
		if (slashdashed)
			return KdlNode.init;
		return node;
	}

	struct Entry
	{
		bool isProp;
		string name;
		KdlValue value;
	}

	Entry parsePropOrArg(bool discarded)
	{
		Entry e;
		auto saved = save();
		string maybeName;
		try
		{
			maybeName = parseIdentifier();
			skipNodeSpace();
			if (peek == '=')
			{
				advance();
				skipNodeSpace();
				e.isProp = true;
				e.name = maybeName;
				e.value = parseValue();
				return e;
			}
		}
		catch (KdlParseException)
		{
		}
		restore(saved);
		e.isProp = false;
		e.value = parseValue();
		return e;
	}

	void upsertProp(ref KdlNode node, string name, KdlValue value)
	{
		foreach (ref p; node.properties)
		{
			if (p.name == name)
			{
				p.value = value;
				return;
			}
		}
		node.properties ~= KdlProperty(name, value);
	}

	KdlNode[] parseChildren(bool discarded)
	{
		expect('{');
		KdlNode[] kids;
		skipLinespace();
		while (!eof && peek != '}')
		{
			if (peekSlashdash())
			{
				consumeSlashdash();
				skipLinespace();
				if (peek != '}' && !eof)
					parseNode(true);
				skipLinespace();
				continue;
			}
			if (peek == ';')
			{
				advance();
				skipLinespace();
				continue;
			}
			if (isNewline(peek))
			{
				skipNewline();
				skipLinespace();
				continue;
			}
			kids ~= parseNode(false);
			skipLinespace();
		}
		expect('}');
		if (discarded)
			return null;
		return kids;
	}

	KdlValue parseValue()
	{
		string typeAnn;
		if (peek == '(')
			typeAnn = parseTypeAnnotation();
		skipNodeSpace();
		if (ver == KdlVersion.v2)
			return parseValueV2(typeAnn);
		return parseValueV1(typeAnn);
	}

	KdlValue parseValueV2(string typeAnn)
	{
		if (src[pos .. $].startsWith("#true"))
		{
			advance(5);
			return KdlValue.fromBool(true, typeAnn);
		}
		if (src[pos .. $].startsWith("#false"))
		{
			advance(6);
			return KdlValue.fromBool(false, typeAnn);
		}
		if (src[pos .. $].startsWith("#null"))
		{
			advance(5);
			return KdlValue.nullValue(typeAnn);
		}
		if (src[pos .. $].startsWith("#nan"))
		{
			advance(4);
			return KdlValue.fromFloat(double.nan, typeAnn);
		}
		if (src[pos .. $].startsWith("#inf"))
		{
			advance(4);
			return KdlValue.fromFloat(double.infinity, typeAnn);
		}
		if (src[pos .. $].startsWith("#-inf"))
		{
			advance(5);
			return KdlValue.fromFloat(-double.infinity, typeAnn);
		}
		if (peek == '"' || peek == '#')
			return KdlValue.fromString(parseStringV2(), typeAnn);
		if (isNumberStart())
			return parseNumber(typeAnn);
		// identifier string as value
		return KdlValue.fromString(parseIdentifier(), typeAnn);
	}

	KdlValue parseValueV1(string typeAnn)
	{
		if (src[pos .. $].startsWith("true") && !isIdentContinueAt(pos + 4))
		{
			advance(4);
			return KdlValue.fromBool(true, typeAnn);
		}
		if (src[pos .. $].startsWith("false") && !isIdentContinueAt(pos + 5))
		{
			advance(5);
			return KdlValue.fromBool(false, typeAnn);
		}
		if (src[pos .. $].startsWith("null") && !isIdentContinueAt(pos + 4))
		{
			advance(4);
			return KdlValue.nullValue(typeAnn);
		}
		if (peek == '"' || (peek == 'r' && pos + 1 < src.length && (src[pos + 1] == '"' || src[pos + 1] == '#')))
			return KdlValue.fromString(parseStringV1(), typeAnn);
		if (isNumberStart())
			return parseNumber(typeAnn);
		return KdlValue.fromString(parseIdentifier(), typeAnn);
	}

	string parseTypeAnnotation()
	{
		expect('(');
		skipNodeSpace();
		auto id = parseIdentifier();
		skipNodeSpace();
		expect(')');
		return id;
	}

	string parseIdentifier()
	{
		if (peek == '"' || (ver == KdlVersion.v2 && peek == '#')
			|| (ver == KdlVersion.v1 && peek == 'r' && pos + 1 < src.length
				&& (src[pos + 1] == '"' || src[pos + 1] == '#')))
		{
			return ver == KdlVersion.v2 ? parseStringV2() : parseStringV1();
		}
		return parseBareIdentifier();
	}

	string parseBareIdentifier()
	{
		if (eof)
			error("expected identifier");
		auto start = pos;
		dchar c = decodeAt();
		if (isNonInitial(c) && c != '+' && c != '-' && !(ver == KdlVersion.v2 && c == '.'))
			error("invalid identifier start");
		if ((c == '+' || c == '-') && pos < src.length)
		{
			auto c2 = peekDchar();
			if (c2 >= '0' && c2 <= '9')
				error("identifier cannot look like a number");
		}
		while (!eof)
		{
			auto c2 = peekDchar();
			if (isNonIdent(c2))
				break;
			advanceDchar();
		}
		auto ident = src[start .. pos];
		if (ver == KdlVersion.v2)
		{
			if (ident.among!("true", "false", "null", "inf", "-inf", "nan"))
				error("disallowed keyword identifier: " ~ ident);
		}
		else
		{
			if (ident.among!("true", "false", "null"))
				error("keyword cannot be a bare identifier: " ~ ident);
		}
		if (!ident.length)
			error("empty identifier");
		return ident;
	}

	string parseStringV2()
	{
		// raw: #+"..."#+  or multiline variants — support single-line forms
		size_t hashes = 0;
		while (peek == '#')
		{
			advance();
			hashes++;
		}
		if (peek != '"')
		{
			if (hashes)
				error("expected \" after raw-string hashes");
			error("expected string");
		}
		// multiline """ ?
		if (pos + 3 <= src.length && src[pos .. pos + 3] == `"""`)
			return parseMultilineQuoted(hashes);
		advance(); // opening "
		if (hashes)
			return parseRawBody(hashes, false);
		return parseEscapedBody(false);
	}

	string parseStringV1()
	{
		if (peek == 'r')
		{
			advance();
			size_t hashes = 0;
			while (peek == '#')
			{
				advance();
				hashes++;
			}
			expect('"');
			auto buf = appender!string();
			while (!eof)
			{
				if (peek == '"')
				{
					auto look = pos + 1;
					size_t h = 0;
					while (look < src.length && src[look] == '#' && h < hashes)
					{
						look++;
						h++;
					}
					if (h == hashes)
					{
						advance();
						foreach (i; 0 .. hashes)
							advance();
						return buf.data;
					}
				}
				buf.put(peek);
				advance();
			}
			error("unterminated raw string");
		}
		expect('"');
		return parseEscapedBodyV1();
	}

	string parseMultilineQuoted(size_t hashes)
	{
		advance(3); // """
		if (!isNewline(peek))
			error("multiline string must start with a newline after \"\"\"");
		skipNewline();
		if (hashes)
			return parseRawBody(hashes, true);
		return parseEscapedBody(true);
	}

	string parseRawBody(size_t hashes, bool multiline)
	{
		auto buf = appender!string();
		string closer = `"` ~ replicate('#', hashes);
		if (multiline)
			closer = `"""` ~ replicate('#', hashes);
		while (!eof)
		{
			if (src[pos .. $].startsWith(closer))
			{
				// for multiline, allow leading spaces on closing line already consumed as content —
				// simplify: require closer at current pos
				if (multiline)
				{
					// strip trailing whitespace-only last line handling is complex; accept closer when found
				}
				advance(closer.length);
				return buf.data;
			}
			buf.put(peek);
			if (isNewline(peek))
				skipNewline();
			else
				advance();
		}
		error("unterminated raw string");
		assert(0);
	}

	string parseEscapedBody(bool multiline)
	{
		auto buf = appender!string();
		string closer = multiline ? `"""` : `"`;
		while (!eof)
		{
			if (src[pos .. $].startsWith(closer))
			{
				advance(closer.length);
				return buf.data;
			}
			if (peek == '\\')
			{
				advance();
				if (eof)
					error("unterminated escape");
				// whitespace escape: \ followed by whitespace/newlines — discard
				if (isWs(peek) || isNewline(peek))
				{
					while (!eof && (isWs(peek) || isNewline(peek)))
					{
						if (isNewline(peek))
							skipNewline();
						else
							advance();
					}
					continue;
				}
				buf.put(parseEscapeChar());
				continue;
			}
			if (!multiline && isNewline(peek))
				error("newline in single-line string");
			if (isNewline(peek))
			{
				buf.put('\n');
				skipNewline();
			}
			else
			{
				buf.put(peek);
				advance();
			}
		}
		error("unterminated string");
		assert(0);
	}

	string parseEscapedBodyV1()
	{
		auto buf = appender!string();
		while (!eof)
		{
			if (peek == '"')
			{
				advance();
				return buf.data;
			}
			if (peek == '\\')
			{
				advance();
				buf.put(parseEscapeCharV1());
				continue;
			}
			buf.put(peek);
			if (isNewline(peek))
				skipNewline();
			else
				advance();
		}
		error("unterminated string");
		assert(0);
	}

	dchar parseEscapeChar()
	{
		auto c = peek;
		advance();
		switch (c)
		{
		case 'n':
			return '\n';
		case 'r':
			return '\r';
		case 't':
			return '\t';
		case '\\':
			return '\\';
		case '"':
			return '"';
		case 'b':
			return '\b';
		case 'f':
			return '\f';
		case 's':
			return ' ';
		case 'u':
			return parseUnicodeEscape();
		default:
			error("invalid escape");
			assert(0);
		}
	}

	dchar parseEscapeCharV1()
	{
		auto c = peek;
		advance();
		switch (c)
		{
		case 'n':
			return '\n';
		case 'r':
			return '\r';
		case 't':
			return '\t';
		case '\\':
			return '\\';
		case '/':
			return '/';
		case '"':
			return '"';
		case 'b':
			return '\b';
		case 'f':
			return '\f';
		case 'u':
			return parseUnicodeEscape();
		default:
			error("invalid escape");
			assert(0);
		}
	}

	dchar parseUnicodeEscape()
	{
		expect('{');
		auto start = pos;
		while (!eof && peek != '}')
		{
			if (!isHexDigit(peek))
				error("invalid unicode escape");
			advance();
		}
		auto hex = src[start .. pos];
		expect('}');
		if (!hex.length || hex.length > 6)
			error("invalid unicode escape length");
		uint cp = to!uint(hex, 16);
		if (cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF))
			error("invalid unicode scalar");
		return cast(dchar) cp;
	}

	KdlValue parseNumber(string typeAnn)
	{
		auto start = pos;
		if (peek == '+' || peek == '-')
			advance();
		if (src[pos .. $].startsWith("0x") || src[pos .. $].startsWith("0X"))
		{
			advance(2);
			enforceDigits!"hex"();
			auto text = stripUnderscores(src[start .. pos]);
			auto sign = 1L;
			size_t i = 0;
			if (text[0] == '+')
				i = 1;
			else if (text[0] == '-')
			{
				sign = -1;
				i = 1;
			}
			auto n = to!long(text[i + 2 .. $], 16) * sign;
			return KdlValue.fromInt(n, typeAnn);
		}
		if (src[pos .. $].startsWith("0o"))
		{
			advance(2);
			enforceDigits!"oct"();
			auto text = stripUnderscores(src[start .. pos]);
			auto sign = 1L;
			size_t i = 0;
			if (text[0] == '+')
				i = 1;
			else if (text[0] == '-')
			{
				sign = -1;
				i = 1;
			}
			auto n = to!long(text[i + 2 .. $], 8) * sign;
			return KdlValue.fromInt(n, typeAnn);
		}
		if (src[pos .. $].startsWith("0b"))
		{
			advance(2);
			enforceDigits!"bin"();
			auto text = stripUnderscores(src[start .. pos]);
			auto sign = 1L;
			size_t i = 0;
			if (text[0] == '+')
				i = 1;
			else if (text[0] == '-')
			{
				sign = -1;
				i = 1;
			}
			auto n = to!long(text[i + 2 .. $], 2) * sign;
			return KdlValue.fromInt(n, typeAnn);
		}
		bool sawDot, sawExp;
		if (!isDigit(peek))
			error("expected number");
		while (!eof && (isDigit(peek) || peek == '_'))
			advance();
		if (peek == '.')
		{
			sawDot = true;
			advance();
			if (!isDigit(peek))
				error("expected digit after decimal point");
			while (!eof && (isDigit(peek) || peek == '_'))
				advance();
		}
		if (peek == 'e' || peek == 'E')
		{
			sawExp = true;
			advance();
			if (peek == '+' || peek == '-')
				advance();
			if (!isDigit(peek))
				error("expected exponent digits");
			while (!eof && (isDigit(peek) || peek == '_'))
				advance();
		}
		auto text = stripUnderscores(src[start .. pos]);
		if (sawDot || sawExp)
			return KdlValue.fromFloat(to!double(text), typeAnn);
		return KdlValue.fromInt(to!long(text), typeAnn);
	}

	void enforceDigits(string kind)()
	{
		bool any;
		while (!eof)
		{
			auto c = peek;
			bool ok;
			static if (kind == "hex")
				ok = isHexDigit(c) || c == '_';
			else static if (kind == "oct")
				ok = (c >= '0' && c <= '7') || c == '_';
			else
				ok = c == '0' || c == '1' || c == '_';
			if (!ok)
				break;
			if (c != '_')
				any = true;
			advance();
		}
		if (!any)
			error("expected " ~ kind ~ " digits");
	}

	static string stripUnderscores(string s)
	{
		auto buf = appender!string();
		foreach (c; s)
			if (c != '_')
				buf.put(c);
		return buf.data;
	}

	static string replicate(char c, size_t n)
	{
		auto buf = appender!string();
		foreach (i; 0 .. n)
			buf.put(c);
		return buf.data;
	}

	bool isNumberStart()
	{
		if (peek == '+' || peek == '-')
		{
			if (pos + 1 < src.length && isDigit(src[pos + 1]))
				return true;
			if (pos + 2 < src.length && src[pos + 1] == '0'
				&& src[pos + 2].among!('x', 'X', 'o', 'b'))
				return true;
			return false;
		}
		return isDigit(peek);
	}

	bool isIdentContinueAt(size_t p)
	{
		if (p >= src.length)
			return false;
		dchar c;
		auto i = p;
		c = decode(src, i);
		return !isNonIdent(c);
	}

	bool isNonInitial(dchar c) const
	{
		if (c >= '0' && c <= '9')
			return true;
		return isNonIdent(c);
	}

	bool isNonIdent(dchar c) const
	{
		if (c <= 0x20)
			return true;
		if (ver == KdlVersion.v2)
		{
			// v2: \ / ( ) { } ; [ ] " # =
			return canFind(`\/(){};[]"#=`, c) || isNewline(c) || isWs(c);
		}
		// v1: \ / ( ) { } < > ; [ ] = , "
		return canFind(`\/(){}<>;[]=,"`, c) || isNewline(c) || isWs(c);
	}

	bool isWs(dchar c) const
	{
		return c.among!(
			'\t', ' ', '\u00A0', '\u1680',
			'\u2000', '\u2001', '\u2002', '\u2003', '\u2004', '\u2005', '\u2006',
			'\u2007', '\u2008', '\u2009', '\u200A', '\u202F', '\u205F', '\u3000'
		) != 0;
	}

	bool isNewline(dchar c) const
	{
		return c.among!('\n', '\r', '\f', '\u0085', '\u2028', '\u2029') != 0;
	}

	@property bool atNodeTerminator() const
	{
		if (eof)
			return true;
		if (peek == ';')
			return true;
		if (isNewline(peek))
			return true;
		// single-line comment starts terminator in grammar
		if (pos + 1 < src.length && src[pos] == '/' && src[pos + 1] == '/')
			return true;
		return false;
	}

	bool peekSlashdash() const
	{
		return pos + 1 < src.length && src[pos] == '/' && src[pos + 1] == '-';
	}

	void consumeSlashdash()
	{
		advance(2);
		skipLinespace();
	}

	void skipLinespace()
	{
		while (!eof)
		{
			if (isWs(peek))
			{
				advance();
				continue;
			}
			if (isNewline(peek))
			{
				skipNewline();
				continue;
			}
			if (pos + 1 < src.length && src[pos] == '/' && src[pos + 1] == '/')
			{
				skipLineComment();
				continue;
			}
			if (pos + 1 < src.length && src[pos] == '/' && src[pos + 1] == '*')
			{
				skipBlockComment();
				continue;
			}
			break;
		}
	}

	void skipNodeSpace()
	{
		while (!eof)
		{
			if (isWs(peek))
			{
				advance();
				continue;
			}
			if (pos + 1 < src.length && src[pos] == '/' && src[pos + 1] == '*')
			{
				skipBlockComment();
				continue;
			}
			if (peek == '\\')
			{
				advance();
				while (!eof && isWs(peek))
					advance();
				if (pos + 1 < src.length && src[pos] == '/' && src[pos + 1] == '/')
					skipLineComment();
				else if (!eof && isNewline(peek))
					skipNewline();
				else if (!eof)
					error("invalid line continuation");
				continue;
			}
			break;
		}
	}

	void skipLineComment()
	{
		advance(2);
		while (!eof && !isNewline(peek))
			advance();
		if (!eof)
			skipNewline();
	}

	void skipBlockComment()
	{
		advance(2);
		int depth = 1;
		while (!eof && depth)
		{
			if (pos + 1 < src.length && src[pos] == '/' && src[pos + 1] == '*')
			{
				advance(2);
				depth++;
			}
			else if (pos + 1 < src.length && src[pos] == '*' && src[pos + 1] == '/')
			{
				advance(2);
				depth--;
			}
			else if (isNewline(peek))
				skipNewline();
			else
				advance();
		}
		if (depth)
			error("unterminated block comment");
	}

	void skipNewline()
	{
		if (peek == '\r')
		{
			advance();
			if (peek == '\n')
				advance();
		}
		else if (isNewline(peek))
			advance();
	}

	struct SavePoint
	{
		size_t pos, line, col;
	}

	SavePoint save() const
	{
		return SavePoint(pos, line, col);
	}

	void restore(SavePoint s)
	{
		pos = s.pos;
		line = s.line;
		col = s.col;
	}

	@property bool eof() const
	{
		return pos >= src.length;
	}

	@property char peek() const
	{
		return eof ? char.init : src[pos];
	}

	dchar peekDchar()
	{
		if (eof)
			return dchar.init;
		size_t i = pos;
		return decode(src, i);
	}

	dchar decodeAt()
	{
		if (eof)
			error("unexpected EOF");
		auto c = decode(src, pos);
		updateLineCol(c);
		return c;
	}

	void advanceDchar()
	{
		decodeAt();
	}

	void advance(size_t n = 1)
	{
		foreach (i; 0 .. n)
		{
			if (eof)
				return;
			auto c = src[pos];
			pos++;
			if (c == '\n')
			{
				line++;
				col = 1;
			}
			else if (c == '\r')
			{
				if (pos < src.length && src[pos] == '\n')
				{
					// handled by skipNewline typically
				}
				line++;
				col = 1;
			}
			else
				col++;
		}
	}

	void updateLineCol(dchar c)
	{
		if (c == '\n')
		{
			line++;
			col = 1;
		}
		else
			col++;
	}

	void expect(char c)
	{
		if (peek != c)
			error(format("expected '%s'", c));
		advance();
	}

	void error(string msg)
	{
		throw new KdlParseException(msg, line, col);
	}
}

unittest
{
	auto doc = parseKdl(`title "Hello"
person name="Alice" age=32 {
	child "Bob"
}
`);
	assert(doc.nodes.length == 2);
	assert(doc.nodes[0].name == "title");
	assert(doc.nodes[0].arguments[0].asString == "Hello");
	assert(doc.nodes[1].property("name").value.asString == "Alice");
	assert(doc.nodes[1].property("age").value.asInt == 32);
	assert(doc.nodes[1].children[0].name == "child");
}

unittest
{
	auto doc = parseKdl(`node #true flag=#false empty=#null`, KdlVersion.v2);
	assert(doc.nodes[0].arguments[0].asBool == true);
	assert(doc.nodes[0].property("flag").value.asBool == false);
	assert(doc.nodes[0].property("empty").value.isNull);
}

unittest
{
	auto doc = parseKdl(`node true flag=false empty=null`, KdlVersion.v1);
	assert(doc.nodes[0].arguments[0].asBool == true);
	assert(doc.nodes[0].property("flag").value.asBool == false);
	assert(doc.nodes[0].property("empty").value.isNull);
}

unittest
{
	auto doc = parseKdl(`parent {
	/- commented 1 2
	real 3
}`);
	assert(doc.nodes[0].children.length == 1);
	assert(doc.nodes[0].children[0].name == "real");
	assert(doc.nodes[0].children[0].arguments[0].asInt == 3);
}
