const std = @import("std");
const Lexer = @import("lexer.zig").Lexer;
const Token = @import("token.zig").Token;
const Tag = @import("token.zig").Tag;
const ast = @import("ast.zig");

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

        return .{ .list = list, .bg = bg };
    }

    fn parseList(self: *Parser) ParseError!ast.List {
        const first = try self.parseAndOr();
        var rest: List(ast.ListRest) = .empty;

        while (true) {
            if (self.current.tag == .semicolon) {
                const peek_save = self.lexer.pos;
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
        const first = try self.parsePipeline();
        var rest: List(ast.AndOrRest) = .empty;

        while (self.current.tag == .and_if or self.current.tag == .or_if) {
            const op: ast.AndOrOp = if (self.current.tag == .and_if) .and_if else .or_if;
            try self.advance();
            try self.skipNewlines();
            const pipeline = try self.parsePipeline();
            try rest.append(self.alloc, .{ .op = op, .pipeline = pipeline });
        }

        return .{ .first = first, .rest = try rest.toOwnedSlice(self.alloc) };
    }

    fn parsePipeline(self: *Parser) ParseError!ast.Pipeline {
        var bang = false;
        if (self.current.tag == .bang) {
            bang = true;
            try self.advance();
        }

        var commands: List(ast.Command) = .empty;
        const first_cmd = try self.parseCommand();
        try commands.append(self.alloc, first_cmd);

        while (self.current.tag == .pipe) {
            try self.advance();
            try self.skipNewlines();
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
            .kw_for => return .{ .compound = try self.parseCompoundWithRedirects(.{ .for_clause = try self.parseForClause() }) },
            .kw_case => return .{ .compound = try self.parseCompoundWithRedirects(.{ .case_clause = try self.parseCaseClause() }) },
            .lbrace => return .{ .compound = try self.parseCompoundWithRedirects(.{ .brace_group = try self.parseBraceGroup() }) },
            .lparen => return .{ .compound = try self.parseCompoundWithRedirects(.{ .subshell = try self.parseSubshell() }) },
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

        return .{
            .assigns = try assigns.toOwnedSlice(self.alloc),
            .words = try words.toOwnedSlice(self.alloc),
            .redirects = try redirects.toOwnedSlice(self.alloc),
        };
    }

    fn parseAssignment(self: *Parser) ParseError!ast.Assignment {
        const text = self.tokenText(self.current);
        const eq_idx = std.mem.indexOfScalar(u8, text, '=').?;
        const name = text[0..eq_idx];
        const value_text = text[eq_idx + 1 ..];
        try self.advance();

        const value = try self.buildWord(value_text);
        return .{ .name = name, .value = value };
    }

    fn parseWordToken(self: *Parser) ParseError!ast.Word {
        const text = self.tokenText(self.current);
        try self.advance();
        return self.buildWord(text);
    }

    fn buildWord(self: *Parser, text: []const u8) ParseError!ast.Word {
        var parts: List(ast.WordPart) = .empty;
        var i: usize = 0;
        var literal_start: usize = 0;

        while (i < text.len) {
            switch (text[i]) {
                '\'' => {
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
                    if (i > literal_start) {
                        try parts.append(self.alloc, .{ .literal = text[literal_start..i] });
                    }
                    i += 1;
                    if (i < text.len) {
                        try parts.append(self.alloc, .{ .literal = text[i .. i + 1] });
                        i += 1;
                    }
                    literal_start = i;
                },
                '$' => {
                    if (i > literal_start) {
                        try parts.append(self.alloc, .{ .literal = text[literal_start..i] });
                    }
                    const part = try self.parseDollarExpansion(text, &i);
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
                    if (i == 0 or (i > 0 and text[i - 1] == ':')) {
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
                    if (i.* > literal_start) {
                        try parts.append(self.alloc, .{ .literal = text[literal_start..i.*] });
                    }
                    i.* += 1;
                    if (i.* < text.len) {
                        const c = text[i.*];
                        if (c == '$' or c == '`' or c == '"' or c == '\\' or c == '\n') {
                            try parts.append(self.alloc, .{ .literal = text[i.* .. i.* + 1] });
                        } else {
                            try parts.append(self.alloc, .{ .literal = text[i.* - 1 .. i.* + 1] });
                        }
                        i.* += 1;
                    }
                    literal_start = i.*;
                },
                '$' => {
                    if (i.* > literal_start) {
                        try parts.append(self.alloc, .{ .literal = text[literal_start..i.*] });
                    }
                    const part = try self.parseDollarExpansion(text, i);
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

    fn parseDollarExpansion(self: *Parser, text: []const u8, i: *usize) ParseError!ast.WordPart {
        i.* += 1;
        if (i.* >= text.len) return .{ .literal = "$" };

        switch (text[i.*]) {
            '{' => return try self.parseBraceParam(text, i),
            '(' => {
                if (i.* + 1 < text.len and text[i.* + 1] == '(') {
                    i.* += 2;
                    const start = i.*;
                    while (i.* + 1 < text.len) {
                        if (text[i.*] == ')' and text[i.* + 1] == ')') {
                            const body = text[start..i.*];
                            i.* += 2;
                            return .{ .arith_sub = body };
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
            else => return .{ .literal = "$" },
        }
    }

    fn parseBraceParam(self: *Parser, text: []const u8, i: *usize) ParseError!ast.WordPart {
        i.* += 1;
        if (i.* >= text.len) return .{ .literal = "${" };

        if (text[i.*] == '#') {
            i.* += 1;
            const start = i.*;
            while (i.* < text.len and text[i.*] != '}') : (i.* += 1) {}
            const name = text[start..i.*];
            if (i.* < text.len) i.* += 1;
            return .{ .parameter = .{ .length = name } };
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

        const colon = text[i.*] == ':';
        if (colon) i.* += 1;

        if (i.* >= text.len) return .{ .parameter = .{ .simple = name } };

        const op_char = text[i.*];
        i.* += 1;

        const word_start = i.*;
        var depth: u32 = 1;
        while (i.* < text.len and depth > 0) {
            if (text[i.*] == '{') depth += 1;
            if (text[i.*] == '}') {
                depth -= 1;
                if (depth == 0) break;
            }
            if (text[i.*] == '\\' and i.* + 1 < text.len) i.* += 1;
            i.* += 1;
        }
        const word_text = text[word_start..i.*];
        if (i.* < text.len) i.* += 1;

        const word = try self.buildWord(word_text);

        return switch (op_char) {
            '-' => .{ .parameter = .{ .default = .{ .name = name, .colon = colon, .word = word } } },
            '=' => .{ .parameter = .{ .assign = .{ .name = name, .colon = colon, .word = word } } },
            '?' => .{ .parameter = .{ .error_msg = .{ .name = name, .colon = colon, .word = word } } },
            '+' => .{ .parameter = .{ .alternative = .{ .name = name, .colon = colon, .word = word } } },
            '#' => {
                if (word_text.len > 0 and word_text[0] == '#') {
                    const inner_word = try self.buildWord(word_text[1..]);
                    return .{ .parameter = .{ .prefix_strip_long = .{ .name = name, .pattern = inner_word } } };
                }
                return .{ .parameter = .{ .prefix_strip = .{ .name = name, .pattern = word } } };
            },
            '%' => {
                if (word_text.len > 0 and word_text[0] == '%') {
                    const inner_word = try self.buildWord(word_text[1..]);
                    return .{ .parameter = .{ .suffix_strip_long = .{ .name = name, .pattern = inner_word } } };
                }
                return .{ .parameter = .{ .suffix_strip = .{ .name = name, .pattern = word } } };
            },
            else => .{ .parameter = .{ .simple = name } },
        };
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
        _ = try self.expect(.kw_done);
        return .{ .condition = condition, .body = body };
    }

    fn parseUntilClause(self: *Parser) ParseError!ast.UntilClause {
        _ = try self.expect(.kw_until);
        const condition = try self.parseCompoundList();
        _ = try self.expect(.kw_do);
        const body = try self.parseCompoundList();
        _ = try self.expect(.kw_done);
        return .{ .condition = condition, .body = body };
    }

    fn parseForClause(self: *Parser) ParseError!ast.ForClause {
        _ = try self.expect(.kw_for);
        if (self.current.tag != .word) return error.ExpectedName;
        const name = self.tokenText(self.current);
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
        if (self.current.tag != .dsemi and self.current.tag != .kw_esac) {
            body = try self.parseCompoundList();
        }

        if (self.current.tag == .dsemi) {
            try self.advance();
            try self.skipNewlines();
        }

        return .{ .patterns = try patterns.toOwnedSlice(self.alloc), .body = body };
    }

    fn parseBraceGroup(self: *Parser) ParseError!ast.BraceGroup {
        _ = try self.expect(.lbrace);
        const body = try self.parseCompoundList();
        _ = try self.expect(.rbrace);
        return .{ .body = body };
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
        }

        self.lexer.pos = saved_pos;
        self.current = saved_current;
        self.lexer.reserved_word_context = saved_rwc;
        return null;
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

    fn isCommandStart(self: *Parser) bool {
        return switch (self.current.tag) {
            .word, .assignment_word, .io_number, .bang => true,
            .kw_if, .kw_while, .kw_until, .kw_for, .kw_case => true,
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
