const std = @import("std");
const Token = @import("token.zig").Token;
const Tag = @import("token.zig").Tag;
const reserved_words = @import("token.zig").reserved_words;

pub const Lexer = struct {
    source: []const u8,
    pos: u32,
    reserved_word_context: bool,
    line: u32,

    pending_heredocs: [16]HeredocPending = undefined,
    pending_heredoc_count: u8 = 0,

    pub const HeredocPending = struct {
        delimiter: []const u8,
        strip_tabs: bool,
        body_ptr: *[]const u8,
    };

    pub fn init(source: []const u8) Lexer {
        return .{
            .source = source,
            .pos = 0,
            .reserved_word_context = true,
            .line = 1,
        };
    }

    pub fn next(self: *Lexer) !Token {
        self.skipBlanks();

        if (self.pos >= self.source.len) {
            return Token{ .tag = .eof, .start = self.pos, .end = self.pos };
        }

        if (self.source[self.pos] == '\\' and self.pos + 1 < self.source.len and self.source[self.pos + 1] == '\n') {
            self.pos += 2;
            self.line += 1;
            return self.next();
        }

        if (self.source[self.pos] == '#') {
            self.skipComment();
            return self.next();
        }

        if (self.source[self.pos] == '\n') {
            const start = self.pos;
            self.pos += 1;
            self.line += 1;
            self.collectPendingHeredocs();
            return Token{ .tag = .newline, .start = start, .end = self.pos };
        }

        if (self.tryOperator()) |tok| {
            return tok;
        }

        return self.readWord();
    }

    fn skipBlanks(self: *Lexer) void {
        while (self.pos < self.source.len) {
            switch (self.source[self.pos]) {
                ' ', '\t' => self.pos += 1,
                '\\' => {
                    if (self.pos + 1 < self.source.len and self.source[self.pos + 1] == '\n') {
                        self.pos += 2;
                        self.line += 1;
                    } else break;
                },
                else => break,
            }
        }
    }

    fn skipComment(self: *Lexer) void {
        while (self.pos < self.source.len and self.source[self.pos] != '\n') {
            self.pos += 1;
        }
    }

    fn tryOperator(self: *Lexer) ?Token {
        const start = self.pos;
        const c = self.source[self.pos];
        const next_c: u8 = if (self.pos + 1 < self.source.len) self.source[self.pos + 1] else 0;

        switch (c) {
            '&' => {
                if (next_c == '&') {
                    self.pos += 2;
                    return Token{ .tag = .and_if, .start = start, .end = self.pos };
                }
                if (next_c == '>') {
                    if (self.pos + 2 < self.source.len and self.source[self.pos + 2] == '>') {
                        self.pos += 3;
                        return Token{ .tag = .and_dgreat, .start = start, .end = self.pos };
                    }
                    self.pos += 2;
                    return Token{ .tag = .and_great, .start = start, .end = self.pos };
                }
                self.pos += 1;
                return Token{ .tag = .ampersand, .start = start, .end = self.pos };
            },
            '|' => {
                if (next_c == '|') {
                    self.pos += 2;
                    return Token{ .tag = .or_if, .start = start, .end = self.pos };
                }
                if (next_c == '&') {
                    self.pos += 2;
                    return Token{ .tag = .pipe_and, .start = start, .end = self.pos };
                }
                self.pos += 1;
                return Token{ .tag = .pipe, .start = start, .end = self.pos };
            },
            ';' => {
                if (next_c == ';') {
                    if (self.pos + 2 < self.source.len and self.source[self.pos + 2] == '&') {
                        self.pos += 3;
                        return Token{ .tag = .dsemi_and, .start = start, .end = self.pos };
                    }
                    self.pos += 2;
                    return Token{ .tag = .dsemi, .start = start, .end = self.pos };
                }
                if (next_c == '&') {
                    self.pos += 2;
                    return Token{ .tag = .semi_and, .start = start, .end = self.pos };
                }
                self.pos += 1;
                return Token{ .tag = .semicolon, .start = start, .end = self.pos };
            },
            '<' => {
                if (next_c == '<') {
                    if (self.pos + 2 < self.source.len and self.source[self.pos + 2] == '<') {
                        self.pos += 3;
                        return Token{ .tag = .tless, .start = start, .end = self.pos };
                    }
                    if (self.pos + 2 < self.source.len and self.source[self.pos + 2] == '-') {
                        self.pos += 3;
                        return Token{ .tag = .dlessdash, .start = start, .end = self.pos };
                    }
                    self.pos += 2;
                    return Token{ .tag = .dless, .start = start, .end = self.pos };
                }
                if (next_c == '&') {
                    self.pos += 2;
                    return Token{ .tag = .lessand, .start = start, .end = self.pos };
                }
                if (next_c == '>') {
                    self.pos += 2;
                    return Token{ .tag = .lessgreat, .start = start, .end = self.pos };
                }
                self.pos += 1;
                return Token{ .tag = .less_than, .start = start, .end = self.pos };
            },
            '>' => {
                if (next_c == '>') {
                    self.pos += 2;
                    return Token{ .tag = .dgreat, .start = start, .end = self.pos };
                }
                if (next_c == '&') {
                    self.pos += 2;
                    return Token{ .tag = .greatand, .start = start, .end = self.pos };
                }
                if (next_c == '|') {
                    self.pos += 2;
                    return Token{ .tag = .clobber, .start = start, .end = self.pos };
                }
                self.pos += 1;
                return Token{ .tag = .greater_than, .start = start, .end = self.pos };
            },
            '(' => {
                self.pos += 1;
                return Token{ .tag = .lparen, .start = start, .end = self.pos };
            },
            ')' => {
                self.pos += 1;
                return Token{ .tag = .rparen, .start = start, .end = self.pos };
            },
            '!' => {
                if (self.reserved_word_context) {
                    if (self.pos + 1 >= self.source.len or
                        self.source[self.pos + 1] == ' ' or self.source[self.pos + 1] == '\t' or
                        self.source[self.pos + 1] == '\n' or self.source[self.pos + 1] == '(' or
                        self.source[self.pos + 1] == '{')
                    {
                        self.pos += 1;
                        return Token{ .tag = .bang, .start = start, .end = self.pos };
                    }
                }
                return null;
            },
            else => return null,
        }
    }

    fn readWord(self: *Lexer) !Token {
        const start = self.pos;

        while (self.pos < self.source.len) {
            const c = self.source[self.pos];
            switch (c) {
                ' ', '\t', '\n' => break,
                '&', '|', ';', '<', '>', '(', ')' => break,
                '\\' => {
                    if (self.pos + 1 < self.source.len and self.source[self.pos + 1] == '\n') {
                        self.pos += 2;
                        self.line += 1;
                    } else {
                        self.pos += 1;
                        if (self.pos < self.source.len) {
                            self.pos += 1;
                        }
                    }
                },
                '\'' => try self.skipSingleQuote(),
                '"' => try self.skipDoubleQuote(),
                '`' => try self.skipBackquote(),
                '$' => self.skipDollar(),
                else => self.pos += 1,
            }
        }

        if (self.pos == start) {
            return error.InvalidToken;
        }

        const text = self.source[start..self.pos];
        var tag: Tag = .word;

        if (self.reserved_word_context) {
            if (reserved_words.get(text)) |rw| {
                tag = rw;
            }
        }

        if (tag == .word) {
            if (self.isIoNumber(start)) {
                tag = .io_number;
            } else if (self.isAssignmentWord(start)) {
                tag = .assignment_word;
            }
        }

        return Token{ .tag = tag, .start = start, .end = self.pos };
    }

    fn skipSingleQuote(self: *Lexer) !void {
        self.pos += 1;
        while (self.pos < self.source.len) {
            if (self.source[self.pos] == '\'') {
                self.pos += 1;
                return;
            }
            self.pos += 1;
        }
        return error.UnterminatedSingleQuote;
    }

    fn skipDoubleQuote(self: *Lexer) !void {
        self.pos += 1;
        while (self.pos < self.source.len) {
            switch (self.source[self.pos]) {
                '"' => {
                    self.pos += 1;
                    return;
                },
                '\\' => {
                    if (self.pos + 1 < self.source.len and self.source[self.pos + 1] == '\n') {
                        self.pos += 2;
                        self.line += 1;
                    } else {
                        self.pos += 1;
                        if (self.pos < self.source.len) {
                            self.pos += 1;
                        }
                    }
                },
                '$' => self.skipDollar(),
                '`' => try self.skipBackquote(),
                else => self.pos += 1,
            }
        }
        return error.UnterminatedDoubleQuote;
    }

    fn skipBackquote(self: *Lexer) !void {
        self.pos += 1;
        while (self.pos < self.source.len) {
            switch (self.source[self.pos]) {
                '`' => {
                    self.pos += 1;
                    return;
                },
                '\\' => {
                    self.pos += 1;
                    if (self.pos < self.source.len) {
                        self.pos += 1;
                    }
                },
                else => self.pos += 1,
            }
        }
        return error.UnterminatedBackquote;
    }

    fn skipDollar(self: *Lexer) void {
        self.pos += 1;
        if (self.pos >= self.source.len) return;

        switch (self.source[self.pos]) {
            '(' => {
                if (self.pos + 1 < self.source.len and self.source[self.pos + 1] == '(') {
                    self.pos += 2;
                    self.skipUntilDoubleCloseParen();
                } else {
                    self.pos += 1;
                    self.skipNestedParens(1);
                }
            },
            '{' => {
                self.pos += 1;
                self.skipUntilCloseBrace();
            },
            '\'' => self.skipDollarSingleQuote(),
            '[' => {
                self.pos += 1;
                var depth: u32 = 1;
                while (self.pos < self.source.len and depth > 0) {
                    if (self.source[self.pos] == '[') depth += 1 else if (self.source[self.pos] == ']') depth -= 1;
                    if (depth > 0) self.pos += 1;
                }
                if (self.pos < self.source.len) self.pos += 1;
            },
            '@', '*', '#', '?', '-', '$', '!' => self.pos += 1,
            '0'...'9' => {
                while (self.pos < self.source.len and self.source[self.pos] >= '0' and self.source[self.pos] <= '9') {
                    self.pos += 1;
                }
            },
            'a'...'z', 'A'...'Z', '_' => {
                while (self.pos < self.source.len and (std.ascii.isAlphanumeric(self.source[self.pos]) or self.source[self.pos] == '_')) {
                    self.pos += 1;
                }
            },
            else => {},
        }
    }

    fn skipDollarSingleQuote(self: *Lexer) void {
        self.pos += 1;
        while (self.pos < self.source.len) {
            switch (self.source[self.pos]) {
                '\'' => {
                    self.pos += 1;
                    return;
                },
                '\\' => {
                    self.pos += 1;
                    if (self.pos < self.source.len) self.pos += 1;
                },
                else => self.pos += 1,
            }
        }
    }

    fn skipNestedParens(self: *Lexer, initial_depth: u32) void {
        var depth = initial_depth;
        while (self.pos < self.source.len and depth > 0) {
            switch (self.source[self.pos]) {
                '(' => {
                    depth += 1;
                    self.pos += 1;
                },
                ')' => {
                    depth -= 1;
                    if (depth > 0) self.pos += 1;
                    if (depth == 0) {
                        self.pos += 1;
                        return;
                    }
                },
                '\'' => {
                    self.skipSingleQuote() catch return;
                },
                '"' => {
                    self.skipDoubleQuote() catch return;
                },
                '\\' => {
                    self.pos += 1;
                    if (self.pos < self.source.len) self.pos += 1;
                },
                else => self.pos += 1,
            }
        }
    }

    fn skipUntilDoubleCloseParen(self: *Lexer) void {
        var depth: u32 = 0;
        while (self.pos < self.source.len) {
            if (self.source[self.pos] == '(') {
                depth += 1;
            } else if (self.source[self.pos] == ')') {
                if (depth > 0) {
                    depth -= 1;
                } else if (self.pos + 1 < self.source.len and self.source[self.pos + 1] == ')') {
                    self.pos += 2;
                    return;
                }
            }
            self.pos += 1;
        }
    }

    fn skipUntilCloseBrace(self: *Lexer) void {
        var depth: u32 = 1;
        while (self.pos < self.source.len and depth > 0) {
            switch (self.source[self.pos]) {
                '}' => {
                    depth -= 1;
                    self.pos += 1;
                    if (depth == 0) return;
                },
                '{' => {
                    depth += 1;
                    self.pos += 1;
                },
                '\\' => {
                    self.pos += 1;
                    if (self.pos < self.source.len) self.pos += 1;
                },
                '\'' => {
                    self.skipSingleQuote() catch return;
                },
                '"' => {
                    self.skipDoubleQuote() catch return;
                },
                '$' => self.skipDollar(),
                '`' => {
                    self.skipBackquote() catch return;
                },
                else => self.pos += 1,
            }
        }
    }

    fn isIoNumber(self: *Lexer, start: u32) bool {
        if (self.pos >= self.source.len) return false;

        const ch = self.source[self.pos];
        if (ch != '<' and ch != '>') return false;

        if (self.pos - start > 1) return false;
        for (self.source[start..self.pos]) |d| {
            if (d < '0' or d > '9') return false;
        }
        return self.pos > start;
    }

    fn isAssignmentWord(self: *Lexer, start: u32) bool {
        const text = self.source[start..self.pos];
        const eq_idx = std.mem.indexOfScalar(u8, text, '=') orelse return false;
        if (eq_idx == 0) return false;

        var name = text[0..eq_idx];
        if (name.len > 0 and name[name.len - 1] == '+') {
            name = name[0 .. name.len - 1];
            if (name.len == 0) return false;
        }
        if (name[0] != '_' and !std.ascii.isAlphabetic(name[0])) return false;
        for (name[1..]) |c| {
            if (c != '_' and !std.ascii.isAlphanumeric(c)) return false;
        }
        return true;
    }

    pub fn addPendingHeredoc(self: *Lexer, hd: HeredocPending) void {
        if (self.pending_heredoc_count < 16) {
            self.pending_heredocs[self.pending_heredoc_count] = hd;
            self.pending_heredoc_count += 1;
        }
    }

    fn collectPendingHeredocs(self: *Lexer) void {
        for (self.pending_heredocs[0..self.pending_heredoc_count]) |*hd| {
            const body_start = self.pos;
            var body_end = body_start;

            while (self.pos < self.source.len) {
                const line_start = self.pos;
                var effective_start = line_start;

                if (hd.strip_tabs) {
                    while (effective_start < self.source.len and self.source[effective_start] == '\t') {
                        effective_start += 1;
                    }
                }

                const line_end = std.mem.indexOfScalarPos(u8, self.source, self.pos, '\n') orelse self.source.len;
                const line_content = self.source[effective_start..line_end];

                self.pos = @intCast(@min(line_end + 1, self.source.len));

                if (std.mem.eql(u8, line_content, hd.delimiter)) {
                    body_end = line_start;
                    break;
                }
            }

            hd.body_ptr.* = self.source[body_start..body_end];
        }
        self.pending_heredoc_count = 0;
    }
};

test "lex simple command" {
    var lex = Lexer.init("echo hello world");
    const t1 = try lex.next();
    try std.testing.expectEqual(Tag.word, t1.tag);
    try std.testing.expectEqualStrings("echo", t1.slice(lex.source));
    const t2 = try lex.next();
    try std.testing.expectEqual(Tag.word, t2.tag);
    try std.testing.expectEqualStrings("hello", t2.slice(lex.source));
    const t3 = try lex.next();
    try std.testing.expectEqual(Tag.word, t3.tag);
    try std.testing.expectEqualStrings("world", t3.slice(lex.source));
    const t4 = try lex.next();
    try std.testing.expectEqual(Tag.eof, t4.tag);
}

test "lex operators" {
    var lex = Lexer.init("a | b && c || d ; e &");
    lex.reserved_word_context = false;
    try std.testing.expectEqual(Tag.word, (try lex.next()).tag);
    try std.testing.expectEqual(Tag.pipe, (try lex.next()).tag);
    try std.testing.expectEqual(Tag.word, (try lex.next()).tag);
    try std.testing.expectEqual(Tag.and_if, (try lex.next()).tag);
    try std.testing.expectEqual(Tag.word, (try lex.next()).tag);
    try std.testing.expectEqual(Tag.or_if, (try lex.next()).tag);
    try std.testing.expectEqual(Tag.word, (try lex.next()).tag);
    try std.testing.expectEqual(Tag.semicolon, (try lex.next()).tag);
    try std.testing.expectEqual(Tag.word, (try lex.next()).tag);
    try std.testing.expectEqual(Tag.ampersand, (try lex.next()).tag);
    try std.testing.expectEqual(Tag.eof, (try lex.next()).tag);
}

test "lex redirections" {
    var lex = Lexer.init("2>file <input >>append");
    const io = try lex.next();
    try std.testing.expectEqual(Tag.io_number, io.tag);
    try std.testing.expectEqualStrings("2", io.slice(lex.source));
    try std.testing.expectEqual(Tag.greater_than, (try lex.next()).tag);
    try std.testing.expectEqual(Tag.word, (try lex.next()).tag);
    try std.testing.expectEqual(Tag.less_than, (try lex.next()).tag);
    try std.testing.expectEqual(Tag.word, (try lex.next()).tag);
    try std.testing.expectEqual(Tag.dgreat, (try lex.next()).tag);
    try std.testing.expectEqual(Tag.word, (try lex.next()).tag);
}

test "lex assignment" {
    var lex = Lexer.init("FOO=bar baz");
    lex.reserved_word_context = false;
    const t1 = try lex.next();
    try std.testing.expectEqual(Tag.assignment_word, t1.tag);
    try std.testing.expectEqualStrings("FOO=bar", t1.slice(lex.source));
}

test "lex reserved words" {
    var lex = Lexer.init("if then else fi");
    try std.testing.expectEqual(Tag.kw_if, (try lex.next()).tag);
    try std.testing.expectEqual(Tag.kw_then, (try lex.next()).tag);
    try std.testing.expectEqual(Tag.kw_else, (try lex.next()).tag);
    try std.testing.expectEqual(Tag.kw_fi, (try lex.next()).tag);
}

test "lex single quotes" {
    var lex = Lexer.init("'hello world' next");
    lex.reserved_word_context = false;
    const t1 = try lex.next();
    try std.testing.expectEqualStrings("'hello world'", t1.slice(lex.source));
    const t2 = try lex.next();
    try std.testing.expectEqualStrings("next", t2.slice(lex.source));
}

test "lex double quotes" {
    var lex = Lexer.init("\"hello $world\" next");
    lex.reserved_word_context = false;
    const t1 = try lex.next();
    try std.testing.expectEqualStrings("\"hello $world\"", t1.slice(lex.source));
}

test "lex comments" {
    var lex = Lexer.init("echo hello # this is a comment\nworld");
    lex.reserved_word_context = false;
    try std.testing.expectEqualStrings("echo", (try lex.next()).slice(lex.source));
    try std.testing.expectEqualStrings("hello", (try lex.next()).slice(lex.source));
    try std.testing.expectEqual(Tag.newline, (try lex.next()).tag);
    try std.testing.expectEqualStrings("world", (try lex.next()).slice(lex.source));
}

test "lex backquotes" {
    var lex = Lexer.init("`echo hi` done");
    lex.reserved_word_context = false;
    const t1 = try lex.next();
    try std.testing.expectEqualStrings("`echo hi`", t1.slice(lex.source));
    try std.testing.expectEqualStrings("done", (try lex.next()).slice(lex.source));
}

test "lex dollar expansion" {
    var lex = Lexer.init("$FOO ${BAR} $(cmd) $((1+2))");
    lex.reserved_word_context = false;
    try std.testing.expectEqualStrings("$FOO", (try lex.next()).slice(lex.source));
    try std.testing.expectEqualStrings("${BAR}", (try lex.next()).slice(lex.source));
    try std.testing.expectEqualStrings("$(cmd)", (try lex.next()).slice(lex.source));
    try std.testing.expectEqualStrings("$((1+2))", (try lex.next()).slice(lex.source));
}

test "lex escape sequences" {
    var lex = Lexer.init("hello\\ world next");
    lex.reserved_word_context = false;
    try std.testing.expectEqualStrings("hello\\ world", (try lex.next()).slice(lex.source));
    try std.testing.expectEqualStrings("next", (try lex.next()).slice(lex.source));
}

test "lex dsemi" {
    var lex = Lexer.init("a ;; b");
    lex.reserved_word_context = false;
    try std.testing.expectEqual(Tag.word, (try lex.next()).tag);
    try std.testing.expectEqual(Tag.dsemi, (try lex.next()).tag);
    try std.testing.expectEqual(Tag.word, (try lex.next()).tag);
}

test "lex heredoc operators" {
    var lex = Lexer.init("<<EOF <<-STRIP");
    try std.testing.expectEqual(Tag.dless, (try lex.next()).tag);
    try std.testing.expectEqual(Tag.word, (try lex.next()).tag);
    try std.testing.expectEqual(Tag.dlessdash, (try lex.next()).tag);
    try std.testing.expectEqual(Tag.word, (try lex.next()).tag);
}

test "lex empty input" {
    var lex = Lexer.init("");
    try std.testing.expectEqual(Tag.eof, (try lex.next()).tag);
}

test "lex only whitespace" {
    var lex = Lexer.init("   \t  ");
    try std.testing.expectEqual(Tag.eof, (try lex.next()).tag);
}

test "lex reserved words not in reserved context" {
    var lex = Lexer.init("if then");
    lex.reserved_word_context = false;
    try std.testing.expectEqual(Tag.word, (try lex.next()).tag);
    try std.testing.expectEqual(Tag.word, (try lex.next()).tag);
}

test "lex all reserved words" {
    var lex = Lexer.init("while until for do done case esac in");
    try std.testing.expectEqual(Tag.kw_while, (try lex.next()).tag);
    try std.testing.expectEqual(Tag.kw_until, (try lex.next()).tag);
    try std.testing.expectEqual(Tag.kw_for, (try lex.next()).tag);
    try std.testing.expectEqual(Tag.kw_do, (try lex.next()).tag);
    try std.testing.expectEqual(Tag.kw_done, (try lex.next()).tag);
    try std.testing.expectEqual(Tag.kw_case, (try lex.next()).tag);
    try std.testing.expectEqual(Tag.kw_esac, (try lex.next()).tag);
    try std.testing.expectEqual(Tag.kw_in, (try lex.next()).tag);
}

test "lex unterminated single quote" {
    var lex = Lexer.init("'hello");
    try std.testing.expectError(error.UnterminatedSingleQuote, lex.next());
}

test "lex bang as reserved word" {
    var lex = Lexer.init("! false");
    const t1 = try lex.next();
    try std.testing.expectEqual(Tag.bang, t1.tag);
    try std.testing.expectEqualStrings("!", t1.slice(lex.source));
    const t2 = try lex.next();
    try std.testing.expectEqual(Tag.word, t2.tag);
}

test "lex unterminated double quote" {
    var lex = Lexer.init("\"hello");
    try std.testing.expectError(error.UnterminatedDoubleQuote, lex.next());
}
