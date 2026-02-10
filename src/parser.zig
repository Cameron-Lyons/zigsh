const std = @import("std");
const Lexer = @import("lexer.zig").Lexer;
const Token = @import("token.zig").Token;
const Tag = @import("token.zig").Tag;
const ast = @import("ast.zig");
const posix = @import("posix.zig");

const List = std.ArrayListUnmanaged;

pub const ParseError = error{
    UnexpectedToken,
    ExpectedWord,
    ExpectedName,
    ExpectedIn,
    ExpectedDo,
    ExpectedDone,
    ExpectedThen,
    ExpectedFi,
    ExpectedEsac,
    ExpectedBraceClose,
    ExpectedParenClose,
    ExpectedPattern,
    MissingSemicolon,
    InvalidRedirection,
    InvalidHeredocDelimiter,
    InvalidFunctionName,
    EmptyCommand,
    OutOfMemory,
    UnterminatedSingleQuote,
    UnterminatedDoubleQuote,
    UnterminatedBackquote,
    UnterminatedParenthesis,
    InvalidEscapeSequence,
    UnexpectedEOF,
    InvalidToken,
};

pub const Parser = struct {
    lexer: *Lexer,
    alloc: std.mem.Allocator,
    current: Token,
    source: []const u8,

    pub fn init(alloc: std.mem.Allocator, lexer: *Lexer) !Parser {
        const source = lexer.source;
        const first = try lexer.next();
        return .{
            .lexer = lexer,
            .alloc = alloc,
            .current = first,
            .source = source,
        };
    }

    fn advance(self: *Parser) ParseError!void {
        self.current = try self.lexer.next();
    }

    fn expect(self: *Parser, tag: Tag) ParseError!Token {
        if (self.current.tag != tag) {
            return error.UnexpectedToken;
        }
        const tok = self.current;
        try self.advance();
        return tok;
    }

    fn skipNewlines(self: *Parser) ParseError!void {
        while (self.current.tag == .newline) {
            self.lexer.reserved_word_context = true;
            try self.advance();
        }
    }

    fn tokenText(self: *Parser, tok: Token) []const u8 {
        return tok.slice(self.source);
    }

    pub fn parseProgram(self: *Parser) ParseError!ast.Program {
        var commands: List(ast.CompleteCommand) = .empty;
        try self.skipNewlines();
        while (self.current.tag != .eof) {
            const cmd = try self.parseCompleteCommand();
            try commands.append(self.alloc, cmd);
            try self.skipNewlines();
        }
        return .{ .commands = try commands.toOwnedSlice(self.alloc) };
    }

    fn parseCompleteCommand(self: *Parser) ParseError!ast.CompleteCommand {
        const line = self.lexer.line;
        const list = try self.parseList();

        var bg = false;
        if (self.current.tag == .ampersand) {
            bg = true;
            try self.advance();
        } else if (self.current.tag == .semicolon) {
            try self.advance();
        }

        if (self.current.tag == .newline) {
            try self.advance();
        }

        return .{ .list = list, .bg = bg, .line = line };
    }

    fn parseList(self: *Parser) ParseError!ast.List {
        const first = try self.parseAndOr();
        var rest: List(ast.ListRest) = .empty;

        while (true) {
            if (self.current.tag == .semicolon) {
                const peek_save = self.lexer.pos;
                self.lexer.reserved_word_context = true;
                try self.advance();
                if (self.isCommandStart()) {
                    const and_or = try self.parseAndOr();
                    try rest.append(self.alloc, .{ .op = .semi, .and_or = and_or });
                } else {
                    self.lexer.pos = peek_save;
                    self.current.tag = .semicolon;
                    break;
                }
            } else if (self.current.tag == .ampersand) {
                const save_pos = self.lexer.pos;
                const save_tok = self.current;
                self.lexer.reserved_word_context = true;
                try self.advance();
                if (self.isCommandStart()) {
                    const and_or = try self.parseAndOr();
                    try rest.append(self.alloc, .{ .op = .amp, .and_or = and_or });
                } else if (self.current.tag == .newline or self.current.tag == .eof) {
                    try self.skipNewlines();
                    if (self.isCommandStart()) {
                        const and_or = try self.parseAndOr();
                        try rest.append(self.alloc, .{ .op = .amp, .and_or = and_or });
                    } else {
                        self.lexer.pos = save_pos;
                        self.current = save_tok;
                        break;
                    }
                } else {
                    self.lexer.pos = save_pos;
                    self.current = save_tok;
                    break;
                }
            } else if (self.current.tag == .newline) {
                try self.skipNewlines();
                if (self.isCommandStart()) {
                    const and_or = try self.parseAndOr();
                    try rest.append(self.alloc, .{ .op = .semi, .and_or = and_or });
                } else {
                    break;
                }
            } else {
                break;
            }
        }

        return .{ .first = first, .rest = try rest.toOwnedSlice(self.alloc) };
    }

    fn parseAndOr(self: *Parser) ParseError!ast.AndOr {
        const line = self.lexer.line;
        const first = try self.parsePipeline();
        var rest: List(ast.AndOrRest) = .empty;

        while (self.current.tag == .and_if or self.current.tag == .or_if) {
            const op: ast.AndOrOp = if (self.current.tag == .and_if) .and_if else .or_if;
            try self.advance();
            try self.skipNewlines();
            const pipeline = try self.parsePipeline();
            try rest.append(self.alloc, .{ .op = op, .pipeline = pipeline });
        }

        return .{ .first = first, .rest = try rest.toOwnedSlice(self.alloc), .line = line };
    }

    fn parsePipeline(self: *Parser) ParseError!ast.Pipeline {
        var bang = false;
        if (self.current.tag == .bang) {
            bang = true;
            try self.advance();
        }
        if (self.current.tag == .word and std.mem.eql(u8, self.tokenText(self.current), "time")) {
            const save_pos = self.lexer.pos;
            const save_tok = self.current;
            try self.advance();
            if (self.current.tag == .word and std.mem.eql(u8, self.tokenText(self.current), "-p")) {
                try self.advance();
            }
            if (self.current.tag == .eof or self.current.tag == .newline or self.current.tag == .semicolon) {
                self.lexer.pos = save_pos;
                self.current = save_tok;
            }
        }

        var commands: List(ast.Command) = .empty;
        const first_cmd = try self.parseCommand();
        try commands.append(self.alloc, first_cmd);

        while (self.current.tag == .pipe or self.current.tag == .pipe_and) {
            const is_pipe_and = self.current.tag == .pipe_and;
            try self.advance();
            try self.skipNewlines();
            if (is_pipe_and) {
                const last_idx = commands.items.len - 1;
                const last_cmd = &commands.items[last_idx];
                switch (last_cmd.*) {
                    .simple => |*sc| {
                        const stderr_redir = ast.Redirect{
                            .fd = 2,
                            .op = .dup_output,
                            .target = .{ .fd = 1 },
                        };
                        var new_redirs: List(ast.Redirect) = .empty;
                        try new_redirs.appendSlice(self.alloc, sc.redirects);
                        try new_redirs.append(self.alloc, stderr_redir);
                        sc.redirects = try new_redirs.toOwnedSlice(self.alloc);
                    },
                    .compound => |*cp| {
                        const stderr_redir = ast.Redirect{
                            .fd = 2,
                            .op = .dup_output,
                            .target = .{ .fd = 1 },
                        };
                        var new_redirs: List(ast.Redirect) = .empty;
                        try new_redirs.appendSlice(self.alloc, cp.redirects);
                        try new_redirs.append(self.alloc, stderr_redir);
                        cp.redirects = try new_redirs.toOwnedSlice(self.alloc);
                    },
                    .function_def => {},
                }
            }
            const cmd = try self.parseCommand();
            try commands.append(self.alloc, cmd);
        }

        return .{ .bang = bang, .commands = try commands.toOwnedSlice(self.alloc) };
    }

    fn parseCommand(self: *Parser) ParseError!ast.Command {
        self.lexer.reserved_word_context = true;

        switch (self.current.tag) {
            .kw_if => return .{ .compound = try self.parseCompoundWithRedirects(.{ .if_clause = try self.parseIfClause() }) },
            .kw_while => return .{ .compound = try self.parseCompoundWithRedirects(.{ .while_clause = try self.parseWhileClause() }) },
            .kw_until => return .{ .compound = try self.parseCompoundWithRedirects(.{ .until_clause = try self.parseUntilClause() }) },
            .kw_for => {
                const for_cmd = try self.parseForOrArithFor();
                return .{ .compound = try self.parseCompoundWithRedirects(for_cmd) };
            },
            .kw_case => return .{ .compound = try self.parseCompoundWithRedirects(.{ .case_clause = try self.parseCaseClause() }) },
            .kw_dbracket => return .{ .compound = try self.parseCompoundWithRedirects(.{ .double_bracket = try self.parseDoubleBracket() }) },
            .lbrace => return .{ .compound = try self.parseCompoundWithRedirects(.{ .brace_group = try self.parseBraceGroup() }) },
            .lparen => {
                if (self.current.end < self.source.len and self.source[self.current.end] == '(') {
                    return .{ .compound = try self.parseCompoundWithRedirects(.{ .arith_command = try self.parseArithCommand() }) };
                }
                return .{ .compound = try self.parseCompoundWithRedirects(.{ .subshell = try self.parseSubshell() }) };
            },
            else => {
                if (try self.tryParseFunctionDef()) |func_def| {
                    return .{ .function_def = func_def };
                }
                return .{ .simple = try self.parseSimpleCommand() };
            },
        }
    }

    fn parseCompoundWithRedirects(self: *Parser, body: ast.CompoundCommand) ParseError!ast.CompoundPair {
        const redirects = try self.parseRedirectList();
        return .{ .body = body, .redirects = redirects };
    }

    fn parseSimpleCommand(self: *Parser) ParseError!ast.SimpleCommand {
        self.lexer.reserved_word_context = false;
        var assigns: List(ast.Assignment) = .empty;
        var words: List(ast.Word) = .empty;
        var redirects: List(ast.Redirect) = .empty;

        while (self.current.tag == .assignment_word) {
            const assign = try self.parseAssignment();
            try assigns.append(self.alloc, assign);
        }

        while (true) {
            if (self.current.tag == .io_number or self.current.tag.isRedirectionOp()) {
                const redir = try self.parseRedirect();
                try redirects.append(self.alloc, redir);
            } else if (self.current.tag == .word or self.current.tag == .assignment_word) {
                const word = try self.parseWordToken();
                try words.append(self.alloc, word);
            } else {
                break;
            }
        }

        self.lexer.reserved_word_context = true;

        if (assigns.items.len == 0 and words.items.len == 0 and redirects.items.len == 0) {
            if (self.current.tag == .semicolon or self.current.tag == .ampersand) {
                return error.UnexpectedToken;
            }
        }

        return .{
            .assigns = try assigns.toOwnedSlice(self.alloc),
            .words = try words.toOwnedSlice(self.alloc),
            .redirects = try redirects.toOwnedSlice(self.alloc),
        };
    }

    fn parseAssignment(self: *Parser) ParseError!ast.Assignment {
        const text = self.tokenText(self.current);
        const eq_idx = std.mem.indexOfScalar(u8, text, '=').?;
        const is_append = eq_idx > 0 and text[eq_idx - 1] == '+';
        const name = if (is_append) text[0 .. eq_idx - 1] else text[0..eq_idx];
        const value_text = text[eq_idx + 1 ..];
        try self.advance();

        const value = try self.buildWordAssign(value_text);
        return .{ .name = name, .value = value, .append = is_append };
    }

    fn parseWordToken(self: *Parser) ParseError!ast.Word {
        const text = self.tokenText(self.current);
        try self.advance();
        return self.buildWord(text);
    }

    pub fn buildWord(self: *Parser, text: []const u8) ParseError!ast.Word {
        return self.buildWordImpl(text, false, false);
    }

    fn buildWordParamExp(self: *Parser, text: []const u8, in_dquote: bool) ParseError!ast.Word {
        return self.buildWordImpl(text, true, in_dquote);
    }

    fn buildWordImpl(self: *Parser, text: []const u8, in_param_exp: bool, in_dquote: bool) ParseError!ast.Word {
        return self.buildWordImplFull(text, in_param_exp, in_dquote, false);
    }

    fn buildWordAssign(self: *Parser, text: []const u8) ParseError!ast.Word {
        return self.buildWordImplFull(text, false, false, true);
    }

    fn buildWordImplFull(self: *Parser, text: []const u8, in_param_exp: bool, in_dquote: bool, in_assignment: bool) ParseError!ast.Word {
        var parts: List(ast.WordPart) = .empty;
        var i: usize = 0;
        var literal_start: usize = 0;

        while (i < text.len) {
            switch (text[i]) {
                '\'' => {
                    if (in_dquote) {
                        i += 1;
                        continue;
                    }
                    if (i > literal_start) {
                        try parts.append(self.alloc, .{ .literal = text[literal_start..i] });
                    }
                    i += 1;
                    const start = i;
                    while (i < text.len and text[i] != '\'') : (i += 1) {}
                    try parts.append(self.alloc, .{ .single_quoted = text[start..i] });
                    if (i < text.len) i += 1;
                    literal_start = i;
                },
                '"' => {
                    if (i > literal_start) {
                        try parts.append(self.alloc, .{ .literal = text[literal_start..i] });
                    }
                    i += 1;
                    const dq_parts = try self.parseDoubleQuoteContents(text, &i);
                    try parts.append(self.alloc, .{ .double_quoted = dq_parts });
                    if (i < text.len and text[i] == '"') i += 1;
                    literal_start = i;
                },
                '\\' => {
                    if (i + 1 < text.len and text[i + 1] == '\n') {
                        if (i > literal_start) {
                            try parts.append(self.alloc, .{ .literal = text[literal_start..i] });
                        }
                        i += 2;
                        literal_start = i;
                        continue;
                    }
                    if (i + 1 < text.len) {
                        const next = text[i + 1];
                        if (in_dquote and next != '$' and next != '`' and next != '"' and next != '\\' and !(in_param_exp and next == '}')) {
                            i += 1;
                            continue;
                        }
                    }
                    if (i > literal_start) {
                        try parts.append(self.alloc, .{ .literal = text[literal_start..i] });
                    }
                    i += 1;
                    if (i < text.len) {
                        try parts.append(self.alloc, .{ .single_quoted = text[i .. i + 1] });
                        i += 1;
                    }
                    literal_start = i;
                },
                '$' => {
                    if (i > literal_start) {
                        try parts.append(self.alloc, .{ .literal = text[literal_start..i] });
                    }
                    const part = try self.parseDollarExpansion(text, &i, in_dquote);
                    try parts.append(self.alloc, part);
                    literal_start = i;
                },
                '`' => {
                    if (i > literal_start) {
                        try parts.append(self.alloc, .{ .literal = text[literal_start..i] });
                    }
                    i += 1;
                    const start = i;
                    while (i < text.len and text[i] != '`') {
                        if (text[i] == '\\') i += 1;
                        i += 1;
                    }
                    try parts.append(self.alloc, .{ .backtick_sub = text[start..i] });
                    if (i < text.len) i += 1;
                    literal_start = i;
                },
                '~' => {
                    const at_start = i == 0;
                    const after_colon = i > 0 and text[i - 1] == ':';
                    if (!in_dquote and (at_start or (after_colon and (in_assignment or in_param_exp)))) {
                        if (i > literal_start) {
                            try parts.append(self.alloc, .{ .literal = text[literal_start..i] });
                        }
                        const start = i;
                        i += 1;
                        while (i < text.len and text[i] != '/' and text[i] != ':') : (i += 1) {}
                        try parts.append(self.alloc, .{ .tilde = text[start..i] });
                        literal_start = i;
                    } else {
                        i += 1;
                    }
                },
                else => i += 1,
            }
        }

        if (literal_start < text.len) {
            try parts.append(self.alloc, .{ .literal = text[literal_start..] });
        }

        if (parts.items.len == 0) {
            try parts.append(self.alloc, .{ .literal = "" });
        }

        return .{ .parts = try parts.toOwnedSlice(self.alloc) };
    }

    fn parseDoubleQuoteContents(self: *Parser, text: []const u8, i: *usize) ParseError![]const ast.WordPart {
        var parts: List(ast.WordPart) = .empty;
        var literal_start = i.*;

        while (i.* < text.len and text[i.*] != '"') {
            switch (text[i.*]) {
                '\\' => {
                    if (i.* + 1 < text.len and text[i.* + 1] == '\n') {
                        if (i.* > literal_start) {
                            try parts.append(self.alloc, .{ .literal = text[literal_start..i.*] });
                        }
                        i.* += 2;
                        literal_start = i.*;
                        continue;
                    }
                    if (i.* > literal_start) {
                        try parts.append(self.alloc, .{ .literal = text[literal_start..i.*] });
                    }
                    i.* += 1;
                    if (i.* < text.len) {
                        const ch = text[i.*];
                        if (ch == '$' or ch == '`' or ch == '"' or ch == '\\') {
                            try parts.append(self.alloc, .{ .literal = text[i.* .. i.* + 1] });
                        } else {
                            try parts.append(self.alloc, .{ .literal = text[i.* - 1 .. i.* + 1] });
                        }
                        i.* += 1;
                    }
                    literal_start = i.*;
                },
                '$' => {
                    if (i.* + 1 >= text.len or text[i.* + 1] == '"') {
                        i.* += 1;
                        continue;
                    }
                    if (i.* > literal_start) {
                        try parts.append(self.alloc, .{ .literal = text[literal_start..i.*] });
                    }
                    const part = try self.parseDollarExpansion(text, i, true);
                    try parts.append(self.alloc, part);
                    literal_start = i.*;
                },
                '`' => {
                    if (i.* > literal_start) {
                        try parts.append(self.alloc, .{ .literal = text[literal_start..i.*] });
                    }
                    i.* += 1;
                    const start = i.*;
                    while (i.* < text.len and text[i.*] != '`') {
                        if (text[i.*] == '\\') i.* += 1;
                        i.* += 1;
                    }
                    try parts.append(self.alloc, .{ .backtick_sub = text[start..i.*] });
                    if (i.* < text.len) i.* += 1;
                    literal_start = i.*;
                },
                else => i.* += 1,
            }
        }

        if (literal_start < i.* and i.* <= text.len) {
            try parts.append(self.alloc, .{ .literal = text[literal_start..i.*] });
        }

        return parts.toOwnedSlice(self.alloc);
    }

    fn parseDollarExpansion(self: *Parser, text: []const u8, i: *usize, in_dquote: bool) ParseError!ast.WordPart {
        i.* += 1;
        while (i.* + 1 < text.len and text[i.*] == '\\' and text[i.* + 1] == '\n') {
            i.* += 2;
        }
        if (i.* >= text.len) return .{ .literal = "$" };

        switch (text[i.*]) {
            '{' => return try self.parseBraceParam(text, i, in_dquote),
            '(' => {
                if (i.* + 1 < text.len and text[i.* + 1] == '(') {
                    i.* += 2;
                    const start = i.*;
                    var depth: u32 = 0;
                    while (i.* + 1 < text.len) {
                        if (text[i.*] == '(') {
                            depth += 1;
                        } else if (text[i.*] == ')') {
                            if (depth > 0) {
                                depth -= 1;
                            } else if (text[i.* + 1] == ')') {
                                const body = text[start..i.*];
                                i.* += 2;
                                return .{ .arith_sub = body };
                            }
                        }
                        i.* += 1;
                    }
                    return .{ .arith_sub = text[start..i.*] };
                }
                i.* += 1;
                const start = i.*;
                var depth: u32 = 1;
                while (i.* < text.len and depth > 0) {
                    if (text[i.*] == '(') depth += 1;
                    if (text[i.*] == ')') depth -= 1;
                    if (depth > 0) i.* += 1;
                }
                const body = text[start..i.*];
                if (i.* < text.len) i.* += 1;
                return .{ .command_sub = .{ .body = body } };
            },
            '\'' => return try self.parseDollarSingleQuote(text, i),
            '"' => {
                i.* += 1;
                const dq_parts = try self.parseDoubleQuoteContents(text, i);
                if (i.* < text.len and text[i.*] == '"') i.* += 1;
                return .{ .double_quoted = dq_parts };
            },
            '@', '*', '#', '?', '-', '$', '!' => {
                const special = text[i.*];
                i.* += 1;
                return .{ .parameter = .{ .special = special } };
            },
            '0'...'9' => {
                const start = i.*;
                while (i.* < text.len and text[i.*] >= '0' and text[i.*] <= '9') : (i.* += 1) {}
                const num_str = text[start..i.*];
                const num = std.fmt.parseInt(u32, num_str, 10) catch 0;
                return .{ .parameter = .{ .positional = num } };
            },
            'a'...'z', 'A'...'Z', '_' => {
                const start = i.*;
                while (i.* < text.len and (std.ascii.isAlphanumeric(text[i.*]) or text[i.*] == '_')) : (i.* += 1) {}
                return .{ .parameter = .{ .simple = text[start..i.*] } };
            },
            '[' => {
                i.* += 1;
                const start = i.*;
                var depth: u32 = 1;
                while (i.* < text.len and depth > 0) {
                    if (text[i.*] == '[') depth += 1;
                    if (text[i.*] == ']') depth -= 1;
                    if (depth > 0) i.* += 1;
                }
                const body = text[start..i.*];
                if (i.* < text.len) i.* += 1;
                return .{ .arith_sub = body };
            },
            else => return .{ .literal = "$" },
        }
    }

    fn parseDollarSingleQuote(self: *Parser, text: []const u8, i: *usize) ParseError!ast.WordPart {
        i.* += 1;
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        while (i.* < text.len) {
            const ch = text[i.*];
            if (ch == '\'') {
                i.* += 1;
                break;
            }
            if (ch == '\\' and i.* + 1 < text.len) {
                i.* += 1;
                const esc = text[i.*];
                switch (esc) {
                    'a' => {
                        try buf.append(self.alloc, 0x07);
                        i.* += 1;
                    },
                    'b' => {
                        try buf.append(self.alloc, 0x08);
                        i.* += 1;
                    },
                    'e', 'E' => {
                        try buf.append(self.alloc, 0x1B);
                        i.* += 1;
                    },
                    'f' => {
                        try buf.append(self.alloc, 0x0C);
                        i.* += 1;
                    },
                    'n' => {
                        try buf.append(self.alloc, '\n');
                        i.* += 1;
                    },
                    'r' => {
                        try buf.append(self.alloc, '\r');
                        i.* += 1;
                    },
                    't' => {
                        try buf.append(self.alloc, '\t');
                        i.* += 1;
                    },
                    'v' => {
                        try buf.append(self.alloc, 0x0B);
                        i.* += 1;
                    },
                    '\\' => {
                        try buf.append(self.alloc, '\\');
                        i.* += 1;
                    },
                    '\'' => {
                        try buf.append(self.alloc, '\'');
                        i.* += 1;
                    },
                    '"' => {
                        try buf.append(self.alloc, '"');
                        i.* += 1;
                    },
                    '0'...'7' => {
                        var val: u8 = esc - '0';
                        i.* += 1;
                        var count: u8 = 1;
                        while (count < 3 and i.* < text.len and text[i.*] >= '0' and text[i.*] <= '7') {
                            val = val *% 8 +% (text[i.*] - '0');
                            i.* += 1;
                            count += 1;
                        }
                        try buf.append(self.alloc, val);
                    },
                    'x' => {
                        i.* += 1;
                        var val: u8 = 0;
                        var count: u8 = 0;
                        while (count < 2 and i.* < text.len) {
                            const d = text[i.*];
                            if (d >= '0' and d <= '9') {
                                val = val *% 16 +% (d - '0');
                            } else if (d >= 'a' and d <= 'f') {
                                val = val *% 16 +% (d - 'a' + 10);
                            } else if (d >= 'A' and d <= 'F') {
                                val = val *% 16 +% (d - 'A' + 10);
                            } else break;
                            i.* += 1;
                            count += 1;
                        }
                        try buf.append(self.alloc, val);
                    },
                    'c' => {
                        i.* += 1;
                        if (i.* < text.len) {
                            const ctrl_char: u8 = text[i.*] & 0x1f;
                            try buf.append(self.alloc, ctrl_char);
                            i.* += 1;
                        }
                    },
                    'u', 'U' => {
                        const max_digits: u8 = if (esc == 'u') 4 else 8;
                        i.* += 1;
                        var has_brace = false;
                        if (i.* < text.len and text[i.*] == '{') {
                            has_brace = true;
                            i.* += 1;
                        }
                        var val: u21 = 0;
                        var count: u8 = 0;
                        const limit: u8 = if (has_brace) 8 else max_digits;
                        while (count < limit and i.* < text.len) {
                            const d = text[i.*];
                            if (d >= '0' and d <= '9') {
                                val = val * 16 + (d - '0');
                            } else if (d >= 'a' and d <= 'f') {
                                val = val * 16 + (d - 'a' + 10);
                            } else if (d >= 'A' and d <= 'F') {
                                val = val * 16 + (d - 'A' + 10);
                            } else break;
                            i.* += 1;
                            count += 1;
                        }
                        if (count == 0 or (has_brace and (i.* >= text.len or text[i.*] != '}'))) {
                            try buf.append(self.alloc, '\\');
                            try buf.append(self.alloc, esc);
                            if (has_brace) {
                                try buf.append(self.alloc, '{');
                                const hex_start = i.* - count;
                                try buf.appendSlice(self.alloc, text[hex_start..i.*]);
                            }
                        } else {
                            if (has_brace) i.* += 1;
                            var utf8_buf: [4]u8 = undefined;
                            const len = std.unicode.utf8Encode(val, &utf8_buf) catch 1;
                            try buf.appendSlice(self.alloc, utf8_buf[0..len]);
                        }
                    },
                    else => {
                        try buf.append(self.alloc, '\\');
                        try buf.append(self.alloc, esc);
                        i.* += 1;
                    },
                }
            } else {
                try buf.append(self.alloc, ch);
                i.* += 1;
            }
        }
        return .{ .ansi_c_quoted = buf.toOwnedSlice(self.alloc) catch "" };
    }

    fn parseBraceParam(self: *Parser, text: []const u8, i: *usize, in_dquote: bool) ParseError!ast.WordPart {
        i.* += 1;
        if (i.* >= text.len) return .{ .literal = "${" };

        if (text[i.*] == '#') {
            const after_hash = i.* + 1;
            if (after_hash >= text.len) {
                i.* += 1;
                return .{ .parameter = .{ .length = "" } };
            }
            if (text[after_hash] == '}') {
                // ${#} → special param $#
            } else if (text[after_hash] == '#') {
                const after_two = after_hash + 1;
                if (after_two < text.len and text[after_two] == '}') {
                    i.* = after_two + 1;
                    return .{ .parameter = .{ .length = "#" } };
                }
            } else if (text[after_hash] == '%' or text[after_hash] == ':') {
                // ${#%...} or ${#:...} → $# with operator, handled below
            } else {
                // ${#name} → length of name
                i.* += 1;
                const start = i.*;
                while (i.* < text.len and text[i.*] != '}') : (i.* += 1) {}
                const name = text[start..i.*];
                if (i.* < text.len) i.* += 1;
                return .{ .parameter = .{ .length = name } };
            }
        }

        if (i.* < text.len and text[i.*] == '!') {
            const after_bang = i.* + 1;
            if (after_bang < text.len and text[after_bang] == '}') {
                i.* = after_bang + 1;
                return .{ .parameter = .{ .special = '!' } };
            }
            if (after_bang < text.len and (std.ascii.isAlphabetic(text[after_bang]) or text[after_bang] == '_')) {
                i.* = after_bang;
                const name_s = i.*;
                while (i.* < text.len and (std.ascii.isAlphanumeric(text[i.*]) or text[i.*] == '_')) : (i.* += 1) {}
                const indirect_name = text[name_s..i.*];
                if (i.* < text.len and text[i.*] == '}') {
                    i.* += 1;
                    return .{ .parameter = .{ .indirect = indirect_name } };
                }
                i.* = after_bang - 1;
            }
        }

        const name_start = i.*;
        if (i.* < text.len and (text[i.*] == '@' or text[i.*] == '*' or text[i.*] == '#' or
            text[i.*] == '?' or text[i.*] == '-' or text[i.*] == '$' or text[i.*] == '!'))
        {
            const special = text[i.*];
            i.* += 1;
            if (i.* < text.len and text[i.*] == '}') {
                i.* += 1;
                return .{ .parameter = .{ .special = special } };
            }
        } else {
            while (i.* < text.len and (std.ascii.isAlphanumeric(text[i.*]) or text[i.*] == '_')) : (i.* += 1) {}
        }
        const name = text[name_start..i.*];

        if (i.* >= text.len) return .{ .parameter = .{ .simple = name } };

        if (text[i.*] == '}') {
            i.* += 1;
            return .{ .parameter = .{ .simple = name } };
        }

        if (text[i.*] == '^' or text[i.*] == ',') {
            return try self.parseCaseConv(text, i, name, in_dquote);
        }

        if (text[i.*] == '@' and i.* + 1 < text.len) {
            const op_char = text[i.* + 1];
            if (i.* + 2 >= text.len or text[i.* + 2] == '}') {
                i.* += 2;
                if (i.* < text.len and text[i.*] == '}') i.* += 1;
                return .{ .parameter = .{ .transform = .{ .name = name, .operator = op_char } } };
            }
        }

        if (text[i.*] == '/') {
            return try self.parsePatternSub(text, i, name, in_dquote);
        }

        const colon = text[i.*] == ':';
        if (colon) i.* += 1;

        if (i.* >= text.len) return .{ .parameter = .{ .simple = name } };

        if (colon and (i.* >= text.len or (text[i.*] != '-' and text[i.*] != '=' and text[i.*] != '?' and text[i.*] != '+'))) {
            return try self.parseSubstring(text, i, name);
        }

        const op_char = text[i.*];
        i.* += 1;

        const word_start = i.*;
        var depth: u32 = 1;
        while (i.* < text.len and depth > 0) {
            switch (text[i.*]) {
                '}' => {
                    depth -= 1;
                    if (depth == 0) break;
                    i.* += 1;
                },
                '{' => {
                    depth += 1;
                    i.* += 1;
                },
                '\\' => {
                    i.* += 1;
                    if (i.* < text.len) i.* += 1;
                },
                '\'' => {
                    if (!in_dquote or op_char == '#' or op_char == '%') {
                        i.* += 1;
                        while (i.* < text.len and text[i.*] != '\'') : (i.* += 1) {}
                        if (i.* < text.len) i.* += 1;
                    } else {
                        i.* += 1;
                    }
                },
                '"' => {
                    i.* += 1;
                    while (i.* < text.len and text[i.*] != '"') {
                        if (text[i.*] == '\\' and i.* + 1 < text.len) i.* += 1;
                        i.* += 1;
                    }
                    if (i.* < text.len) i.* += 1;
                },
                '$' => {
                    i.* += 1;
                    if (i.* < text.len and text[i.*] == '{') {
                        depth += 1;
                        i.* += 1;
                    }
                },
                else => i.* += 1,
            }
        }
        const word_text = text[word_start..i.*];
        if (i.* < text.len) i.* += 1;

        return switch (op_char) {
            '-' => blk: {
                const word = try self.buildWordParamExp(word_text, in_dquote);
                break :blk .{ .parameter = .{ .default = .{ .name = name, .colon = colon, .word = word } } };
            },
            '=' => blk: {
                const word = try self.buildWordParamExp(word_text, in_dquote);
                break :blk .{ .parameter = .{ .assign = .{ .name = name, .colon = colon, .word = word } } };
            },
            '?' => blk: {
                const word = try self.buildWordParamExp(word_text, in_dquote);
                break :blk .{ .parameter = .{ .error_msg = .{ .name = name, .colon = colon, .word = word } } };
            },
            '+' => blk: {
                const word = try self.buildWordParamExp(word_text, in_dquote);
                break :blk .{ .parameter = .{ .alternative = .{ .name = name, .colon = colon, .word = word } } };
            },
            '#' => {
                const pat_word = try self.buildWordParamExp(word_text, false);
                if (word_text.len > 0 and word_text[0] == '#') {
                    const inner_word = try self.buildWordParamExp(word_text[1..], false);
                    return .{ .parameter = .{ .prefix_strip_long = .{ .name = name, .pattern = inner_word } } };
                }
                return .{ .parameter = .{ .prefix_strip = .{ .name = name, .pattern = pat_word } } };
            },
            '%' => {
                const pat_word = try self.buildWordParamExp(word_text, false);
                if (word_text.len > 0 and word_text[0] == '%') {
                    const inner_word = try self.buildWordParamExp(word_text[1..], false);
                    return .{ .parameter = .{ .suffix_strip_long = .{ .name = name, .pattern = inner_word } } };
                }
                return .{ .parameter = .{ .suffix_strip = .{ .name = name, .pattern = pat_word } } };
            },
            else => {
                if (!std.ascii.isAlphanumeric(op_char) and op_char != '_') {
                    posix.writeAll(2, "zigsh: bad substitution\n");
                    return error.UnexpectedToken;
                }
                return .{ .parameter = .{ .simple = name } };
            },
        };
    }

    fn parsePatternSub(self: *Parser, text: []const u8, i: *usize, name: []const u8, _: bool) ParseError!ast.WordPart {
        i.* += 1;
        var mode: ast.PatSubMode = .first;
        if (i.* < text.len) {
            switch (text[i.*]) {
                '/' => {
                    mode = .all;
                    i.* += 1;
                },
                '#' => {
                    mode = .prefix;
                    i.* += 1;
                },
                '%' => {
                    mode = .suffix;
                    i.* += 1;
                },
                else => {},
            }
        }

        const pat_start = i.*;
        var depth: u32 = 1;
        var found_slash = false;
        while (i.* < text.len and depth > 0) {
            if (text[i.*] == '\\' and i.* + 1 < text.len) {
                i.* += 2;
                continue;
            }
            if (text[i.*] == '\'' and depth == 1) {
                i.* += 1;
                while (i.* < text.len and text[i.*] != '\'') : (i.* += 1) {}
                if (i.* < text.len) i.* += 1;
                continue;
            }
            if (text[i.*] == '"' and depth == 1) {
                i.* += 1;
                while (i.* < text.len and text[i.*] != '"') {
                    if (text[i.*] == '\\' and i.* + 1 < text.len) {
                        i.* += 2;
                    } else {
                        i.* += 1;
                    }
                }
                if (i.* < text.len) i.* += 1;
                continue;
            }
            if (text[i.*] == '{') {
                depth += 1;
            } else if (text[i.*] == '}') {
                depth -= 1;
                if (depth == 0) break;
            } else if (text[i.*] == '/' and depth == 1 and i.* > pat_start) {
                found_slash = true;
                break;
            }
            i.* += 1;
        }

        const pat_text = text[pat_start..i.*];
        var rep_text: []const u8 = "";

        if (found_slash) {
            i.* += 1;
            const rep_start = i.*;
            depth = 1;
            while (i.* < text.len and depth > 0) {
                if (text[i.*] == '\\' and i.* + 1 < text.len) {
                    i.* += 2;
                    continue;
                }
                if (text[i.*] == '{') {
                    depth += 1;
                } else if (text[i.*] == '}') {
                    depth -= 1;
                    if (depth == 0) break;
                }
                i.* += 1;
            }
            rep_text = text[rep_start..i.*];
        }

        if (i.* < text.len and text[i.*] == '}') i.* += 1;

        const pattern = try self.buildWordParamExp(pat_text, false);
        const replacement = try self.buildWordParamExp(rep_text, false);

        return .{ .parameter = .{ .pattern_sub = .{
            .name = name,
            .pattern = pattern,
            .replacement = replacement,
            .mode = mode,
        } } };
    }

    fn parseSubstring(_: *Parser, text: []const u8, i: *usize, name: []const u8) ParseError!ast.WordPart {
        const offset_start = i.*;
        var depth: u32 = 1;
        var paren_depth: u32 = 0;
        while (i.* < text.len and depth > 0) {
            if (text[i.*] == '(') {
                paren_depth += 1;
            } else if (text[i.*] == ')') {
                if (paren_depth > 0) paren_depth -= 1;
            } else if (text[i.*] == '{') {
                depth += 1;
            } else if (text[i.*] == '}') {
                depth -= 1;
                if (depth == 0) break;
            } else if (text[i.*] == ':' and depth == 1 and paren_depth == 0) {
                break;
            }
            i.* += 1;
        }
        const offset_text = text[offset_start..i.*];
        var length_text: ?[]const u8 = null;

        if (i.* < text.len and text[i.*] == ':') {
            i.* += 1;
            const len_start = i.*;
            depth = 1;
            while (i.* < text.len and depth > 0) {
                if (text[i.*] == '{') {
                    depth += 1;
                } else if (text[i.*] == '}') {
                    depth -= 1;
                    if (depth == 0) break;
                }
                i.* += 1;
            }
            length_text = text[len_start..i.*];
        }

        if (i.* < text.len and text[i.*] == '}') i.* += 1;

        return .{ .parameter = .{ .substring = .{
            .name = name,
            .offset = offset_text,
            .length = length_text,
        } } };
    }

    fn parseDoubleBracket(self: *Parser) ParseError!*ast.DoubleBracketExpr {
        _ = try self.expect(.kw_dbracket);
        try self.skipDbNewlines();
        const expr = try self.parseDbOr();
        if (self.current.tag != .kw_dbracket_close) {
            return error.UnexpectedToken;
        }
        try self.advance();
        return expr;
    }

    fn skipDbNewlines(self: *Parser) ParseError!void {
        while (self.current.tag == .newline) {
            try self.advance();
        }
    }

    fn parseDbOr(self: *Parser) ParseError!*ast.DoubleBracketExpr {
        var left = try self.parseDbAnd();
        while (true) {
            try self.skipDbNewlines();
            if (self.current.tag != .or_if) break;
            try self.advance();
            try self.skipDbNewlines();
            const right = try self.parseDbAnd();
            const node = try self.alloc.create(ast.DoubleBracketExpr);
            node.* = .{ .or_expr = .{ .left = left, .right = right } };
            left = node;
        }
        return left;
    }

    fn parseDbAnd(self: *Parser) ParseError!*ast.DoubleBracketExpr {
        var left = try self.parseDbPrimary();
        while (true) {
            try self.skipDbNewlines();
            if (self.current.tag != .and_if) break;
            try self.advance();
            try self.skipDbNewlines();
            const right = try self.parseDbPrimary();
            const node = try self.alloc.create(ast.DoubleBracketExpr);
            node.* = .{ .and_expr = .{ .left = left, .right = right } };
            left = node;
        }
        return left;
    }

    fn parseDbPrimary(self: *Parser) ParseError!*ast.DoubleBracketExpr {
        if (self.current.tag == .bang) {
            try self.advance();
            const inner = try self.parseDbPrimary();
            const node = try self.alloc.create(ast.DoubleBracketExpr);
            node.* = .{ .not_expr = inner };
            return node;
        }
        if (self.current.tag == .lparen) {
            try self.advance();
            const inner = try self.parseDbOr();
            if (self.current.tag == .rparen) try self.advance();
            return inner;
        }
        const first_text = self.tokenText(self.current);
        const first_word = try self.parseDbWord();
        if (self.isDbBinaryOp()) {
            const op = self.getDbBinaryOpText();
            try self.advance();
            const rhs = try self.parseDbWord();
            const node = try self.alloc.create(ast.DoubleBracketExpr);
            node.* = .{ .binary_test = .{ .lhs = first_word, .op = op, .rhs = rhs } };
            return node;
        }
        if (isDbUnaryOp(first_text)) {
            if (self.current.tag == .kw_dbracket_close or
                self.current.tag == .and_if or self.current.tag == .or_if or
                self.current.tag == .rparen)
            {
                return error.UnexpectedToken;
            }
            const operand = try self.parseDbWord();
            const node = try self.alloc.create(ast.DoubleBracketExpr);
            node.* = .{ .unary_test = .{ .op = first_text, .operand = operand } };
            return node;
        }
        const node = try self.alloc.create(ast.DoubleBracketExpr);
        node.* = .{ .unary_test = .{ .op = "-n", .operand = first_word } };
        return node;
    }

    fn parseDbWord(self: *Parser) ParseError!ast.Word {
        if (self.current.tag == .word or self.current.tag == .assignment_word or
            isDbWordTag(self.current.tag))
        {
            return self.parseWordToken();
        }
        return error.ExpectedWord;
    }

    fn isDbBinaryOp(self: *Parser) bool {
        if (self.current.tag == .less_than or self.current.tag == .greater_than) return true;
        if (self.current.tag != .word) return false;
        const text = self.tokenText(self.current);
        const ops = [_][]const u8{ "==", "!=", "=~", "=", "-eq", "-ne", "-lt", "-gt", "-le", "-ge", "-nt", "-ot", "-ef" };
        for (ops) |op| {
            if (std.mem.eql(u8, text, op)) return true;
        }
        return false;
    }

    fn getDbBinaryOpText(self: *Parser) []const u8 {
        if (self.current.tag == .less_than) return "<";
        if (self.current.tag == .greater_than) return ">";
        return self.tokenText(self.current);
    }

    fn isDbWordTag(tag: Tag) bool {
        return switch (tag) {
            .kw_if, .kw_then, .kw_else, .kw_elif, .kw_fi,
            .kw_do, .kw_done, .kw_case, .kw_esac,
            .kw_while, .kw_until, .kw_for, .kw_in,
            .bang => true,
            else => false,
        };
    }

    fn isDbUnaryOp(text: []const u8) bool {
        const ops = [_][]const u8{
            "-n", "-z", "-e", "-f", "-d", "-r", "-w", "-x", "-s",
            "-h", "-L", "-p", "-b", "-c", "-S", "-t", "-o", "-v",
            "-a", "-u", "-g", "-k", "-G", "-O", "-N", "-R",
        };
        for (ops) |op| {
            if (std.mem.eql(u8, text, op)) return true;
        }
        return false;
    }

    fn parseCaseConv(self: *Parser, text: []const u8, i: *usize, name: []const u8, _: bool) ParseError!ast.WordPart {
        const first_char = text[i.*];
        i.* += 1;
        var mode: ast.CaseConvMode = undefined;
        if (first_char == '^') {
            if (i.* < text.len and text[i.*] == '^') {
                mode = .upper_all;
                i.* += 1;
            } else {
                mode = .upper_first;
            }
        } else {
            if (i.* < text.len and text[i.*] == ',') {
                mode = .lower_all;
                i.* += 1;
            } else {
                mode = .lower_first;
            }
        }
        var pattern: ?ast.Word = null;
        if (i.* < text.len and text[i.*] != '}') {
            const pat_start = i.*;
            var depth: u32 = 1;
            while (i.* < text.len and depth > 0) {
                if (text[i.*] == '{') {
                    depth += 1;
                } else if (text[i.*] == '}') {
                    depth -= 1;
                    if (depth == 0) break;
                }
                i.* += 1;
            }
            pattern = try self.buildWordParamExp(text[pat_start..i.*], false);
        }
        if (i.* < text.len and text[i.*] == '}') i.* += 1;
        return .{ .parameter = .{ .case_conv = .{
            .name = name,
            .mode = mode,
            .pattern = pattern,
        } } };
    }

    fn parseRedirect(self: *Parser) ParseError!ast.Redirect {
        var fd: ?i32 = null;

        if (self.current.tag == .io_number) {
            const num_text = self.tokenText(self.current);
            fd = std.fmt.parseInt(i32, num_text, 10) catch null;
            try self.advance();
        }

        const op: ast.RedirectOp = switch (self.current.tag) {
            .less_than => .input,
            .greater_than => .output,
            .dgreat => .append,
            .lessand => .dup_input,
            .greatand => .dup_output,
            .lessgreat => .read_write,
            .clobber => .clobber,
            .dless => .heredoc,
            .dlessdash => .heredoc_strip,
            .tless => .here_string,
            .and_great => .and_great,
            .and_dgreat => .and_dgreat,
            else => return error.InvalidRedirection,
        };
        try self.advance();

        if (op == .heredoc or op == .heredoc_strip) {
            return self.parseHeredocRedirect(fd, op);
        }

        if (self.current.tag != .word and self.current.tag != .assignment_word) {
            return error.ExpectedWord;
        }

        const word_text = self.tokenText(self.current);
        try self.advance();

        if (op == .dup_input or op == .dup_output) {
            if (std.mem.eql(u8, word_text, "-")) {
                return .{ .fd = fd, .op = op, .target = .close };
            }
            if (std.fmt.parseInt(i32, word_text, 10)) |target_fd| {
                return .{ .fd = fd, .op = op, .target = .{ .fd = target_fd } };
            } else |_| {}
        }

        const word = try self.buildWord(word_text);
        return .{ .fd = fd, .op = op, .target = .{ .word = word } };
    }

    fn parseHeredocRedirect(self: *Parser, fd: ?i32, op: ast.RedirectOp) ParseError!ast.Redirect {
        if (self.current.tag != .word) return error.InvalidHeredocDelimiter;

        const delim_text = self.tokenText(self.current);

        var quoted = false;
        var delimiter = delim_text;
        if (delim_text.len >= 2 and delim_text[0] == '\'' and delim_text[delim_text.len - 1] == '\'') {
            quoted = true;
            delimiter = delim_text[1 .. delim_text.len - 1];
        } else if (delim_text.len >= 2 and delim_text[0] == '"' and delim_text[delim_text.len - 1] == '"') {
            quoted = true;
            delimiter = delim_text[1 .. delim_text.len - 1];
        } else if (std.mem.indexOfScalar(u8, delim_text, '\\') != null) {
            quoted = true;
        }

        const body_ptr = self.alloc.create([]const u8) catch return error.OutOfMemory;
        body_ptr.* = "";

        self.lexer.addPendingHeredoc(.{
            .delimiter = delimiter,
            .strip_tabs = (op == .heredoc_strip),
            .body_ptr = body_ptr,
        });

        try self.advance();

        return .{
            .fd = fd,
            .op = op,
            .target = .{ .heredoc = .{
                .delimiter = delimiter,
                .body_ptr = body_ptr,
                .quoted = quoted,
            } },
        };
    }

    fn parseRedirectList(self: *Parser) ParseError![]const ast.Redirect {
        var redirects: List(ast.Redirect) = .empty;
        while (self.current.tag == .io_number or self.current.tag.isRedirectionOp()) {
            const redir = try self.parseRedirect();
            try redirects.append(self.alloc, redir);
        }
        return redirects.toOwnedSlice(self.alloc);
    }

    fn parseIfClause(self: *Parser) ParseError!ast.IfClause {
        _ = try self.expect(.kw_if);
        const condition = try self.parseCompoundList();
        _ = try self.expect(.kw_then);
        const then_body = try self.parseCompoundList();
        if (then_body.len == 0) return error.UnexpectedToken;

        var elifs: List(ast.ElifClause) = .empty;
        while (self.current.tag == .kw_elif) {
            try self.advance();
            const elif_cond = try self.parseCompoundList();
            _ = try self.expect(.kw_then);
            const elif_body = try self.parseCompoundList();
            try elifs.append(self.alloc, .{ .condition = elif_cond, .body = elif_body });
        }

        var else_body: ?[]const ast.CompleteCommand = null;
        if (self.current.tag == .kw_else) {
            try self.advance();
            else_body = try self.parseCompoundList();
        }

        _ = try self.expect(.kw_fi);
        return .{
            .condition = condition,
            .then_body = then_body,
            .elifs = try elifs.toOwnedSlice(self.alloc),
            .else_body = else_body,
        };
    }

    fn parseWhileClause(self: *Parser) ParseError!ast.WhileClause {
        _ = try self.expect(.kw_while);
        const condition = try self.parseCompoundList();
        _ = try self.expect(.kw_do);
        const body = try self.parseCompoundList();
        if (body.len == 0) return error.UnexpectedToken;
        _ = try self.expect(.kw_done);
        return .{ .condition = condition, .body = body };
    }

    fn parseUntilClause(self: *Parser) ParseError!ast.UntilClause {
        _ = try self.expect(.kw_until);
        const condition = try self.parseCompoundList();
        _ = try self.expect(.kw_do);
        const body = try self.parseCompoundList();
        if (body.len == 0) return error.UnexpectedToken;
        _ = try self.expect(.kw_done);
        return .{ .condition = condition, .body = body };
    }

    fn parseForOrArithFor(self: *Parser) ParseError!ast.CompoundCommand {
        _ = try self.expect(.kw_for);
        if (self.current.tag == .lparen and self.current.end < self.source.len and self.source[self.current.end] == '(') {
            return .{ .arith_for_clause = try self.parseArithForClause() };
        }
        return .{ .for_clause = try self.parseForClauseAfterFor() };
    }

    fn parseArithForClause(self: *Parser) ParseError!ast.ArithForClause {
        var pos = self.current.start + 2;
        var exprs: [3][]const u8 = .{ "", "", "" };
        var expr_idx: usize = 0;

        while (expr_idx < 3 and pos < self.source.len) {
            while (pos < self.source.len and (self.source[pos] == ' ' or self.source[pos] == '\t' or self.source[pos] == '\n')) {
                pos += 1;
            }
            const start = pos;
            var depth: u32 = 0;
            while (pos < self.source.len) {
                const ch = self.source[pos];
                if (ch == '(') {
                    depth += 1;
                    pos += 1;
                } else if (ch == ')') {
                    if (depth == 0) break;
                    depth -= 1;
                    pos += 1;
                } else if (ch == ';' and depth == 0 and expr_idx < 2) {
                    break;
                } else if (ch == '\'' or ch == '"') {
                    pos += 1;
                    while (pos < self.source.len and self.source[pos] != ch) : (pos += 1) {}
                    if (pos < self.source.len) pos += 1;
                } else if (ch == '$' and pos + 1 < self.source.len and self.source[pos + 1] == '\'') {
                    pos += 2;
                    while (pos < self.source.len and self.source[pos] != '\'') : (pos += 1) {}
                    if (pos < self.source.len) pos += 1;
                } else if (ch == '$' and pos + 1 < self.source.len and self.source[pos + 1] == '"') {
                    pos += 2;
                    while (pos < self.source.len and self.source[pos] != '"') : (pos += 1) {}
                    if (pos < self.source.len) pos += 1;
                } else {
                    pos += 1;
                }
            }
            var end = pos;
            while (end > start and (self.source[end - 1] == ' ' or self.source[end - 1] == '\t' or self.source[end - 1] == '\n')) {
                end -= 1;
            }
            exprs[expr_idx] = self.source[start..end];
            expr_idx += 1;
            if (pos < self.source.len and self.source[pos] == ';') {
                pos += 1;
            }
        }

        if (pos + 1 < self.source.len and self.source[pos] == ')' and self.source[pos + 1] == ')') {
            pos += 2;
        } else {
            return error.ExpectedParenClose;
        }

        self.lexer.pos = pos;
        self.current = try self.lexer.next();

        if (self.current.tag == .semicolon or self.current.tag == .newline) {
            try self.advance();
        }
        try self.skipNewlines();

        if (self.current.tag == .lbrace) {
            try self.advance();
            const body = try self.parseCompoundList();
            if (self.current.tag == .rbrace) {
                try self.advance();
            }
            return .{ .init = exprs[0], .cond = exprs[1], .step = exprs[2], .body = body };
        }

        _ = try self.expect(.kw_do);
        const body = try self.parseCompoundList();
        _ = try self.expect(.kw_done);
        return .{ .init = exprs[0], .cond = exprs[1], .step = exprs[2], .body = body };
    }

    fn parseForClauseAfterFor(self: *Parser) ParseError!ast.ForClause {
        const name_text = self.tokenText(self.current);
        if (self.current.tag != .word and self.current.tag != .kw_in and
            self.current.tag != .kw_do and self.current.tag != .kw_done)
        {
            return error.ExpectedName;
        }
        if (!isValidName(name_text)) return error.ExpectedName;
        const name = name_text;
        try self.advance();

        var wordlist: ?[]const ast.Word = null;

        try self.skipNewlines();
        if (self.current.tag == .kw_in) {
            try self.advance();
            var words: List(ast.Word) = .empty;
            while (self.current.tag == .word) {
                const word = try self.parseWordToken();
                try words.append(self.alloc, word);
            }
            wordlist = try words.toOwnedSlice(self.alloc);
            if (self.current.tag == .semicolon or self.current.tag == .newline) {
                try self.advance();
            }
        } else if (self.current.tag == .semicolon) {
            try self.advance();
        }

        try self.skipNewlines();
        _ = try self.expect(.kw_do);
        const body = try self.parseCompoundList();
        _ = try self.expect(.kw_done);
        return .{ .name = name, .wordlist = wordlist, .body = body };
    }

    fn parseCaseClause(self: *Parser) ParseError!ast.CaseClause {
        _ = try self.expect(.kw_case);
        self.lexer.reserved_word_context = false;
        if (self.current.tag == .newline or self.current.tag == .eof) return error.ExpectedWord;
        const word_text = self.tokenText(self.current);
        self.lexer.reserved_word_context = true;
        try self.advance();
        const word = try self.buildWord(word_text);
        try self.skipNewlines();
        _ = try self.expect(.kw_in);
        try self.skipNewlines();

        var items: List(ast.CaseItem) = .empty;
        while (self.current.tag != .kw_esac) {
            if (self.current.tag == .eof) return error.ExpectedEsac;
            const item = try self.parseCaseItem();
            try items.append(self.alloc, item);
            try self.skipNewlines();
        }
        _ = try self.expect(.kw_esac);
        return .{ .word = word, .items = try items.toOwnedSlice(self.alloc) };
    }

    fn parseCaseItem(self: *Parser) ParseError!ast.CaseItem {
        if (self.current.tag == .lparen) {
            try self.advance();
        }

        var patterns: List(ast.Word) = .empty;
        self.lexer.reserved_word_context = false;
        const first_pat = try self.parseWordToken();
        try patterns.append(self.alloc, first_pat);
        while (self.current.tag == .pipe) {
            try self.advance();
            const pat = try self.parseWordToken();
            try patterns.append(self.alloc, pat);
        }
        self.lexer.reserved_word_context = true;
        _ = try self.expect(.rparen);

        try self.skipNewlines();

        var body: ?[]const ast.CompleteCommand = null;
        if (self.current.tag != .dsemi and self.current.tag != .semi_and and
            self.current.tag != .dsemi_and and self.current.tag != .kw_esac)
        {
            body = try self.parseCompoundList();
        }

        var terminator: ast.CaseTerminator = .dsemi;
        if (self.current.tag == .dsemi) {
            try self.advance();
            try self.skipNewlines();
        } else if (self.current.tag == .semi_and) {
            terminator = .fall_through;
            try self.advance();
            try self.skipNewlines();
        } else if (self.current.tag == .dsemi_and) {
            terminator = .continue_testing;
            try self.advance();
            try self.skipNewlines();
        }

        return .{ .patterns = try patterns.toOwnedSlice(self.alloc), .body = body, .terminator = terminator };
    }

    fn parseBraceGroup(self: *Parser) ParseError!ast.BraceGroup {
        _ = try self.expect(.lbrace);
        const body = try self.parseCompoundList();
        _ = try self.expect(.rbrace);
        return .{ .body = body };
    }

    fn parseArithCommand(self: *Parser) ParseError![]const u8 {
        _ = try self.expect(.lparen);
        const start = self.lexer.pos;
        if (start < self.source.len and self.source[start] == '(') {
            self.lexer.pos += 1;
        }
        const expr_start = self.lexer.pos;
        var depth: u32 = 0;
        while (self.lexer.pos < self.source.len) {
            if (self.source[self.lexer.pos] == '(') {
                depth += 1;
            } else if (self.source[self.lexer.pos] == ')') {
                if (depth > 0) {
                    depth -= 1;
                } else if (self.lexer.pos + 1 < self.source.len and self.source[self.lexer.pos + 1] == ')') {
                    const expr = self.source[expr_start..self.lexer.pos];
                    self.lexer.pos += 2;
                    self.current = try self.lexer.next();
                    return expr;
                }
            }
            self.lexer.pos += 1;
        }
        return error.UnexpectedEOF;
    }

    fn parseSubshell(self: *Parser) ParseError!ast.Subshell {
        _ = try self.expect(.lparen);
        const body = try self.parseCompoundList();
        _ = try self.expect(.rparen);
        return .{ .body = body };
    }

    fn tryParseFunctionDef(self: *Parser) ParseError!?ast.FunctionDef {
        if (self.current.tag != .word) return null;

        const saved_pos = self.lexer.pos;
        const saved_current = self.current;
        const saved_rwc = self.lexer.reserved_word_context;

        const name = self.tokenText(self.current);

        try self.advance();

        if (self.current.tag == .lparen) {
            try self.advance();
            if (self.current.tag == .rparen) {
                if (!isValidFunctionName(name)) return error.UnexpectedToken;
                try self.advance();
                try self.skipNewlines();
                const body_start = self.current.start;
                self.lexer.reserved_word_context = true;
                const body_cmd = try self.parseCommand();
                const body_end = self.lexer.pos;
                const compound = switch (body_cmd) {
                    .compound => |cp| cp,
                    else => return error.UnexpectedToken,
                };
                return .{ .name = name, .body = compound, .source = self.lexer.source[body_start..body_end] };
            }
            if (isValidFunctionName(name)) {
                posix.writeAll(2, "zigsh: syntax error near unexpected token\n");
                return error.UnexpectedToken;
            }
        }

        self.lexer.pos = saved_pos;
        self.current = saved_current;
        self.lexer.reserved_word_context = saved_rwc;
        return null;
    }

    fn isValidFunctionName(name: []const u8) bool {
        if (name.len == 0) return false;
        if (name[0] != '_' and !std.ascii.isAlphabetic(name[0])) return false;
        for (name[1..]) |ch| {
            if (ch != '_' and !std.ascii.isAlphanumeric(ch)) return false;
        }
        return true;
    }

    fn parseCompoundList(self: *Parser) ParseError![]const ast.CompleteCommand {
        var commands: List(ast.CompleteCommand) = .empty;
        try self.skipNewlines();

        while (self.isCommandStart()) {
            const cmd = try self.parseCompleteCommand();
            try commands.append(self.alloc, cmd);
            try self.skipNewlines();
        }

        return commands.toOwnedSlice(self.alloc);
    }

    fn isValidName(text: []const u8) bool {
        if (text.len == 0) return false;
        if (text[0] != '_' and !std.ascii.isAlphabetic(text[0])) return false;
        for (text[1..]) |ch| {
            if (ch != '_' and !std.ascii.isAlphanumeric(ch)) return false;
        }
        return true;
    }

    fn isCommandStart(self: *Parser) bool {
        return switch (self.current.tag) {
            .word, .assignment_word, .io_number, .bang => true,
            .kw_if, .kw_while, .kw_until, .kw_for, .kw_case, .kw_dbracket => true,
            .lbrace, .lparen => true,
            .less_than, .greater_than, .dless, .dgreat, .lessand, .greatand, .lessgreat, .dlessdash, .clobber => true,
            else => false,
        };
    }
};

test "parse simple command" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var lex = Lexer.init("echo hello world");
    var parser = try Parser.init(alloc, &lex);
    const program = try parser.parseProgram();

    try std.testing.expectEqual(@as(usize, 1), program.commands.len);
    const cmd = program.commands[0].list.first.first.commands[0];
    const simple = cmd.simple;
    try std.testing.expectEqual(@as(usize, 3), simple.words.len);
}

test "parse assignment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var lex = Lexer.init("FOO=bar echo");
    var parser = try Parser.init(alloc, &lex);
    const program = try parser.parseProgram();

    const simple = program.commands[0].list.first.first.commands[0].simple;
    try std.testing.expectEqual(@as(usize, 1), simple.assigns.len);
    try std.testing.expectEqualStrings("FOO", simple.assigns[0].name);
    try std.testing.expectEqual(@as(usize, 1), simple.words.len);
}

test "parse pipeline" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var lex = Lexer.init("ls | grep foo");
    var parser = try Parser.init(alloc, &lex);
    const program = try parser.parseProgram();

    const pipeline = program.commands[0].list.first.first;
    try std.testing.expectEqual(@as(usize, 2), pipeline.commands.len);
}

test "parse and-or list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var lex = Lexer.init("true && echo yes || echo no");
    var parser = try Parser.init(alloc, &lex);
    const program = try parser.parseProgram();

    const and_or = program.commands[0].list.first;
    try std.testing.expectEqual(@as(usize, 2), and_or.rest.len);
    try std.testing.expectEqual(ast.AndOrOp.and_if, and_or.rest[0].op);
    try std.testing.expectEqual(ast.AndOrOp.or_if, and_or.rest[1].op);
}

test "parse redirection" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var lex = Lexer.init("echo hello >out.txt 2>&1");
    var parser = try Parser.init(alloc, &lex);
    const program = try parser.parseProgram();

    const simple = program.commands[0].list.first.first.commands[0].simple;
    try std.testing.expectEqual(@as(usize, 2), simple.redirects.len);
    try std.testing.expectEqual(ast.RedirectOp.output, simple.redirects[0].op);
    try std.testing.expectEqual(ast.RedirectOp.dup_output, simple.redirects[1].op);
}

test "parse if clause" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var lex = Lexer.init("if true; then echo yes; fi");
    var parser = try Parser.init(alloc, &lex);
    const program = try parser.parseProgram();

    try std.testing.expectEqual(@as(usize, 1), program.commands.len);
    const cmd = program.commands[0].list.first.first.commands[0];
    try std.testing.expectEqual(ast.CompoundCommand.if_clause, std.meta.activeTag(cmd.compound.body));
}

test "parse if-else clause" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var lex = Lexer.init("if false; then echo no; else echo yes; fi");
    var parser = try Parser.init(alloc, &lex);
    const program = try parser.parseProgram();

    const cmd = program.commands[0].list.first.first.commands[0];
    const ic = cmd.compound.body.if_clause;
    try std.testing.expect(ic.else_body != null);
}

test "parse while clause" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var lex = Lexer.init("while true; do echo loop; done");
    var parser = try Parser.init(alloc, &lex);
    const program = try parser.parseProgram();

    const cmd = program.commands[0].list.first.first.commands[0];
    try std.testing.expectEqual(ast.CompoundCommand.while_clause, std.meta.activeTag(cmd.compound.body));
}

test "parse for clause" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var lex = Lexer.init("for i in a b c; do echo $i; done");
    var parser = try Parser.init(alloc, &lex);
    const program = try parser.parseProgram();

    const cmd = program.commands[0].list.first.first.commands[0];
    const fc = cmd.compound.body.for_clause;
    try std.testing.expectEqualStrings("i", fc.name);
    try std.testing.expectEqual(@as(usize, 3), fc.wordlist.?.len);
}

test "parse case clause" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var lex = Lexer.init("case x in a) echo a;; b) echo b;; esac");
    var parser = try Parser.init(alloc, &lex);
    const program = try parser.parseProgram();

    const cmd = program.commands[0].list.first.first.commands[0];
    const cc = cmd.compound.body.case_clause;
    try std.testing.expectEqual(@as(usize, 2), cc.items.len);
}

test "parse bang pipeline" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var lex = Lexer.init("! false");
    var parser = try Parser.init(alloc, &lex);
    const program = try parser.parseProgram();

    const pipeline = program.commands[0].list.first.first;
    try std.testing.expect(pipeline.bang);
}

test "parse background command" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var lex = Lexer.init("echo a & echo b");
    var parser = try Parser.init(alloc, &lex);
    const program = try parser.parseProgram();

    const rest = program.commands[0].list.rest;
    try std.testing.expect(rest.len == 1);
    try std.testing.expect(rest[0].op == .amp);
}

test "parse brace group" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var lex = Lexer.init("{ echo hello; }");
    var parser = try Parser.init(alloc, &lex);
    const program = try parser.parseProgram();

    const cmd = program.commands[0].list.first.first.commands[0];
    try std.testing.expectEqual(ast.CompoundCommand.brace_group, std.meta.activeTag(cmd.compound.body));
}

test "parse subshell" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var lex = Lexer.init("(echo hello)");
    var parser = try Parser.init(alloc, &lex);
    const program = try parser.parseProgram();

    const cmd = program.commands[0].list.first.first.commands[0];
    try std.testing.expectEqual(ast.CompoundCommand.subshell, std.meta.activeTag(cmd.compound.body));
}

test "parse function definition" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var lex = Lexer.init("myfunc() { echo hello; }");
    var parser = try Parser.init(alloc, &lex);
    const program = try parser.parseProgram();

    const cmd = program.commands[0].list.first.first.commands[0];
    try std.testing.expectEqualStrings("myfunc", cmd.function_def.name);
}

test "parse multiple commands" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var lex = Lexer.init("echo a; echo b; echo c");
    var parser = try Parser.init(alloc, &lex);
    const program = try parser.parseProgram();

    try std.testing.expectEqual(@as(usize, 1), program.commands.len);
    const list = program.commands[0].list;
    try std.testing.expectEqual(@as(usize, 2), list.rest.len);
}

test "parse empty input" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var lex = Lexer.init("");
    var parser = try Parser.init(alloc, &lex);
    const program = try parser.parseProgram();

    try std.testing.expectEqual(@as(usize, 0), program.commands.len);
}

test "parse three-stage pipeline" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var lex = Lexer.init("ls | grep foo | wc -l");
    var parser = try Parser.init(alloc, &lex);
    const program = try parser.parseProgram();

    const pipeline = program.commands[0].list.first.first;
    try std.testing.expectEqual(@as(usize, 3), pipeline.commands.len);
}
