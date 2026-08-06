module kdl.exception;

import std.format : format;

/// Thrown when KDL text cannot be parsed.
class KdlParseException : Exception
{
	size_t line;
	size_t column;

	this(string msg, size_t line = 0, size_t column = 0,
		string file = __FILE__, size_t lineNo = __LINE__)
	{
		this.line = line;
		this.column = column;
		super(line ? format("%s (line %s, column %s)", msg, line, column) : msg, file, lineNo);
	}
}
