const std = @import("std");

// Inspired by the Zig compiler lexer (std.zig.tokenizer)

pub const Token = struct {
    tag: Tag,
    loc: Loc,
    content: ?[]const u8,

    /// Indexing starts at 0. For user information increment the values by one.
    pub const CharPosition = struct {
        ch: u32,
        line: u32,
        index: usize,
    };

    const Loc = struct {
        start: CharPosition,
        end: CharPosition,
    };

    pub const Tag = enum {
        identifier,
        string_literal,
        keyword_const,
        keyword_use,
        keyword_free,
        keyword_otherwise,

        // starting with '#'
        special_number,

        numeric_literal,

        lparen,
        rparen,
        fatrightarrow,
        exclamation_mark,
        less,
        leq,
        greater,
        geq,
        eq,
        assign,
        shift,
        rule_symbol,
        tilde,
        comma,
        semicolon,
        colon,
        pipe,
        logic_or,
        ampersand,
        logic_and,
        asterisk,
        plus,
        minus,
        lbracket,
        rbracket,
        lbrace,
        rbrace,
        commentline,
        eof,
        invalid,

        pub fn lexeme(tag: Tag) ?[]const u8 {
            return switch (tag) {
                .identifier, .eof, .string_literal, .numeric_literal, .invalid, .special_number => null,
                .keyword_free => "free",
                .keyword_const => "const",
                .keyword_use => "use",
                .keyword_otherwise => "otherwise",
                .lparen => "(",
                .rparen => ")",
                .fatrightarrow => "=>",
                .exclamation_mark => "!",
                .less => "<",
                .leq => "<=",
                .greater => ">",
                .geq => ">=",
                .eq => "==",
                .assign => "=",
                .shift => "<<",
                .rule_symbol => "><",
                .tilde => "~",
                .comma => ",",
                .semicolon => ";",
                .colon => ":",
                .pipe => "|",
                .logic_or => "||",
                .ampersand => "&",
                .logic_and => "&&",
                .asterisk => "*",
                .plus => "+",
                .minus => "-",
                .lbracket => "[",
                .rbracket => "]",
                .lbrace => "{",
                .rbrace => "}",
                .commentline => "//",
            };
        }
        pub fn symbol(tag: Tag) []const u8 {
            return tag.lexeme() orelse switch (tag) {
                .identifier => "an identifier",
                .eof => "EOF",
                .string_literal => "a string literal",
                .numeric_literal => "a numeric literal",
                .invalid => "an invalid token",
                else => unreachable,
            };
        }
    };

    pub const keywords = std.StaticStringMap(Tag).initComptime(.{
        .{ "free", .keyword_free },
        .{ "const", .keyword_const },
        .{ "otherwise", .keyword_otherwise },
        .{ "use", .keyword_use },
    });

    pub const specials = std.StaticStringMap(Tag).initComptime(.{
        .{ "#num", .special_number },
    });

    pub fn getKeyword(content: []const u8) ?Tag {
        return keywords.get(content);
    }

    pub fn getSpecial(content: []const u8) ?Tag {
        return specials.get(content);
    }
};

pub const Tokenizer = struct {
    buffer: [:0]const u8,
    index: usize,
    pos: Token.CharPosition,

    fn advance(self: *Tokenizer) void {
        if (self.buffer[self.index] == '\n') {
            self.pos.line += 1;
            self.pos.ch = 0;
        } else {
            self.pos.ch += 1;
        }
        self.index += 1;
        self.pos.index = self.index;
    }

    pub fn init(buffer: [:0]const u8) Tokenizer {
        return .{
            .buffer = buffer,
            .index = 0,
            .pos = .{
                .index = 0,
                .ch = 0,
                .line = 0,
            },
        };
    }

    const State = enum {
        start,
        string_literal,
        numeric_literal,
        decimal,

        identifier,
        special,

        state,
        eq,
        less,
        greater,
        pipe,
        ampersand,
        forward_slash,
        commentline,
        end,
        invalid,
    };

    pub fn next(self: *Tokenizer) Token {
        var result: Token = .{
            .tag = undefined,
            .loc = .{
                .start = self.pos,
                .end = undefined,
            },
            .content = null,
        };

        state: switch (State.start) {
            .start => switch (self.buffer[self.index]) {
                0 => {
                    if (self.index == self.buffer.len) {
                        return .{
                            .tag = .eof,
                            .loc = .{
                                .start = self.pos,
                                .end = self.pos,
                            },
                            .content = null,
                        };
                    } else {
                        continue :state .invalid;
                    }
                },
                ' ', '\t', '\n', '\r' => {
                    self.advance();
                    result.loc.start = self.pos;
                    continue :state .start;
                },
                'a'...'z', 'A'...'Z', '_' => {
                    result.tag = .identifier;
                    continue :state .identifier;
                },
                '#' => {
                    continue :state .special;
                },
                '0'...'9' => {
                    result.tag = .numeric_literal;
                    continue :state .numeric_literal;
                },
                '(' => {
                    self.advance();
                    result.tag = .lparen;
                },
                ')' => {
                    self.advance();
                    result.tag = .rparen;
                },
                '[' => {
                    self.advance();
                    result.tag = .lbracket;
                },
                ']' => {
                    self.advance();
                    result.tag = .rbracket;
                },
                '{' => {
                    self.advance();
                    result.tag = .lbrace;
                },
                '}' => {
                    self.advance();
                    result.tag = .rbrace;
                },
                ';' => {
                    self.advance();
                    result.tag = .semicolon;
                },
                ':' => {
                    self.advance();
                    result.tag = .colon;
                },
                '!' => {
                    self.advance();
                    result.tag = .exclamation_mark;
                },
                ',' => {
                    self.advance();
                    result.tag = .comma;
                },
                '~' => {
                    self.advance();
                    result.tag = .tilde;
                },
                '|' => {
                    self.advance();
                    continue :state .pipe;
                },
                '&' => {
                    self.advance();
                    continue :state .ampersand;
                },
                '=' => {
                    self.advance();
                    continue :state .eq;
                },
                '<' => {
                    self.advance();
                    continue :state .less;
                },
                '>' => {
                    self.advance();
                    continue :state .greater;
                },
                '"' => {
                    // Unclear if the string literals will even be necessary
                    result.tag = .string_literal;
                    continue :state .string_literal;
                },
                '.' => {
                    // We don't allow .123 type numbers?
                    continue :state .invalid;
                },
                '/' => {
                    self.advance();
                    continue :state .forward_slash;
                },
                else => {
                    std.debug.print("invalid char: {c}, number {}\n", .{ self.buffer[self.index], self.buffer[self.index] });
                    continue :state .invalid;
                },
            },
            .pipe => switch (self.buffer[self.index]) {
                '|' => {
                    self.advance();
                    result.tag = .logic_or;
                },
                else => result.tag = .pipe,
            },
            .ampersand => switch (self.buffer[self.index]) {
                '&' => {
                    self.advance();
                    result.tag = .logic_and;
                },
                else => result.tag = .ampersand,
            },
            .eq => switch (self.buffer[self.index]) {
                '=' => {
                    self.advance();
                    result.tag = .eq;
                },
                '>' => {
                    self.advance();
                    result.tag = .fatrightarrow;
                },
                else => result.tag = .assign,
            },
            .less => switch (self.buffer[self.index]) {
                '=' => {
                    self.advance();
                    result.tag = .leq;
                },
                '<' => {
                    self.advance();
                    result.tag = .shift;
                },
                else => result.tag = .less,
            },
            .greater => switch (self.buffer[self.index]) {
                '=' => {
                    self.advance();
                    result.tag = .geq;
                },
                '<' => {
                    self.advance();
                    result.tag = .rule_symbol;
                },
                else => result.tag = .greater,
            },
            .identifier => {
                self.advance();
                switch (self.buffer[self.index]) {
                    'a'...'z', 'A'...'Z', '0'...'9', '\'', '_' => continue :state .identifier,
                    else => {
                        const content = self.buffer[result.loc.start.index..self.index];
                        if (Token.getKeyword(content)) |tag| {
                            result.tag = tag;
                        } else {
                            result.content = content;
                        }
                    },
                }
            },
            .special => {
                self.advance();
                switch (self.buffer[self.index]) {
                    'a'...'z' => continue :state .special,
                    else => {
                        const content = self.buffer[result.loc.start.index..self.index];
                        if (Token.getSpecial(content)) |tag| {
                            result.tag = tag;
                        } else {
                            result.tag = .invalid;
                        }
                    },
                }
            },
            .string_literal => {
                self.advance();
                // Add real string handling?
                switch (self.buffer[self.index]) {
                    0 => {
                        if (self.index != self.buffer.len) {
                            continue :state .invalid;
                        } else {
                            result.tag = .invalid;
                        }
                    },
                    '"' => {
                        const content = self.buffer[result.loc.start.index + 1 .. self.index];
                        result.content = content;
                        self.advance();
                    },
                    else => continue :state .string_literal,
                }
            },
            .numeric_literal => {
                self.advance();
                switch (self.buffer[self.index]) {
                    '0'...'9' => {
                        continue :state .numeric_literal;
                    },
                    '.' => {
                        self.advance();
                        if (self.index == self.buffer.len or self.buffer[self.index] == '\n') {
                            result.tag = .invalid;
                        } else if (!std.ascii.isDigit(self.buffer[self.index])) {
                            continue :state .invalid;
                        } else {
                            continue :state .decimal;
                        }
                    },
                    else => {
                        const content = self.buffer[result.loc.start.index..self.index];
                        result.content = content;
                    },
                }
            },
            .decimal => {
                self.advance();
                switch (self.buffer[self.index]) {
                    '0'...'9' => {
                        continue :state .decimal;
                    },
                    else => {
                        const content = self.buffer[result.loc.start.index..self.index];
                        result.content = content;
                    },
                }
            },
            .forward_slash => {
                switch (self.buffer[self.index]) {
                    '/' => {
                        continue :state .commentline;
                    },
                    else => {
                        result.tag = .invalid;
                    },
                }
            },
            .commentline => {
                self.advance();
                switch (self.buffer[self.index]) {
                    '\n', 0 => {
                        result.tag = .commentline;
                    },
                    else => {
                        continue :state .commentline;
                    },
                }
            },
            .invalid => {
                self.advance();
                switch (self.buffer[self.index]) {
                    0 => if (self.index == self.buffer.len) {
                        result.tag = .invalid;
                    } else {
                        continue :state .invalid;
                    },
                    '\n' => {
                        result.tag = .invalid;
                    },
                    else => continue :state .invalid,
                }
            },
            else => unreachable,
        }
        result.loc.end = self.pos;
        return result;
    }
};

/// Simply tokenizes the file contents using std.ArrayList.
/// The caller owns the tokens.
/// Tokens do not own anything.
pub fn tokenize(gpa: std.mem.Allocator, contents: [:0]const u8) error{OutOfMemory}![]Token {
    var arr: std.ArrayList(Token) = std.ArrayList(Token).empty;
    var tokenizer = Tokenizer.init(contents);
    var cur = tokenizer.next();
    while (cur.tag != .eof) : (cur = tokenizer.next()) {
        if (cur.tag != .commentline) {
            try arr.append(gpa, cur);
        }
    }
    try arr.append(gpa, cur);
    return try arr.toOwnedSlice(gpa);
}

const TokenizeTestError = error{
    NotEqual,
    BadLength,
};

test "numerals" {
    try testTokenize("123\n123.123\n0\n123.\n.123\n0", &.{ .numeric_literal, .numeric_literal, .numeric_literal, .invalid, .invalid, .numeric_literal });
}

test "single active pair program" {
    try testTokenize(
        \\ Add(r, x) >< S(y) =>
        \\  r ~ S(w),
        \\  Add(w, x) ~ y;
    , &.{ .identifier, .lparen, .identifier, .comma, .identifier, .rparen, .rule_symbol, .identifier, .lparen, .identifier, .rparen, .fatrightarrow, .identifier, .tilde, .identifier, .lparen, .identifier, .rparen, .comma, .identifier, .lparen, .identifier, .comma, .identifier, .rparen, .tilde, .identifier, .semicolon });
}

test "specials" {
    try testTokenize("#number #num #asd asd", &.{ .invalid, .special_number, .invalid, .identifier });
}

test "identifier contents" {
    var tokenizer1 = Tokenizer.init(" hello_w'orld' ");
    var tokenizer2 = Tokenizer.init("\n\nhello_w'orld'\"hello, world\"");
    const t1 = tokenizer1.next();
    const t2 = tokenizer2.next();
    try std.testing.expectEqualSlices(u8, t1.content.?, t2.content.?);
    try std.testing.expectEqualSlices(u8, t1.content.?, "hello_w'orld'");
}

test "strings" {
    try testTokenize("\"free hello world\"hello world free\"hello world\"", &.{ .string_literal, .identifier, .identifier, .keyword_free, .string_literal });
}

test "keywords" {
    try testTokenize("hello const return ifce free", &.{ .identifier, .keyword_const, .identifier, .identifier, .keyword_free });
}

test "different assignments" {
    try testTokenize("= == <= >= => ><", &.{ .assign, .eq, .leq, .geq, .fatrightarrow, .rule_symbol });
}

test "empty" {
    try testTokenize("", &.{});
}

fn testTokenize(content: [:0]const u8, expected: []const Token.Tag) !void {
    var dalloc = std.heap.DebugAllocator(.{}).init;
    defer _ = dalloc.deinit();
    const allocator = dalloc.allocator();
    var tokenizer = Tokenizer.init(content);
    var array = std.ArrayList(Token.Tag).empty;
    defer array.deinit(allocator);
    var cur: Token = tokenizer.next();
    while (cur.tag != .eof) : (cur = tokenizer.next()) {
        try array.append(allocator, cur.tag);
    }
    if (expected.len != array.items.len) {
        std.debug.print("Lengths differ: {} != {}\nexpected: {any}\nactual: {any}\n", .{ expected.len, array.items.len, expected, array.items });
        return TokenizeTestError.BadLength;
    }

    {
        var i: usize = 0;
        while (i < expected.len) : (i += 1) {
            if (expected[i] != array.items[i]) {
                std.debug.print("Item {} difference.\nexpected: {}\nactual:{}\n", .{ i, expected[i], array.items[i] });
                return TokenizeTestError.NotEqual;
            }
        }
    }
}
