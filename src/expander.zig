const std = @import("std");
const ast = @import("ast.zig");
const Lexer = @import("lexer.zig").Lexer;
const Parser = @import("parser.zig").Parser;
const Arithmetic = @import("arithmetic.zig").Arithmetic;
const glob = @import("glob.zig");
const posix = @import("posix.zig");
const Environment = @import("env.zig").Environment;

pub const ExpandError = error{
    UnsetVariable,
    BadSubstitution,
    CommandSubstitutionFailed,
    ArithmeticError,
    PatternError,
    OutOfMemory,
};

const JobTable = @import("jobs.zig").JobTable;

pub const Expander = struct {
    env: *Environment,
    jobs: *JobTable,
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator, env: *Environment, jobs: *JobTable) Expander {
        return .{ .env = env, .jobs = jobs, .alloc = alloc };
    }

    pub fn expandWord(self: *Expander, word: ast.Word) ExpandError![]const u8 {
        var result: std.ArrayListUnmanaged(u8) = .empty;
        for (word.parts) |part| {
            const expanded = try self.expandPart(part);
            try result.appendSlice(self.alloc, expanded);
        }
        return result.toOwnedSlice(self.alloc);
    }

    pub fn expandWordNoSplit(self: *Expander, word: ast.Word) ExpandError![]const u8 {
        return self.expandWord(word);
    }

    pub fn expandFields(self: *Expander, word: ast.Word) ExpandError![]const []const u8 {
        const expanded = try self.expandWord(word);
        if (expanded.len == 0) {
            self.alloc.free(expanded);
            return &.{};
        }
        return self.fieldSplit(expanded);
    }

    pub fn expandWordsToFields(self: *Expander, words: []const ast.Word) ExpandError![]const []const u8 {
        var fields: std.ArrayListUnmanaged([]const u8) = .empty;
        for (words) |word| {
            if (isQuoted(word)) {
                const expanded = try self.expandWord(word);
                try fields.append(self.alloc, expanded);
            } else {
                const expanded = try self.expandWord(word);
                if (expanded.len == 0) {
                    self.alloc.free(expanded);
                    continue;
                }
                const split = try self.fieldSplit(expanded);
                if (!self.env.options.noglob) {
                    for (split) |field| {
                        const globbed = glob.expand(self.alloc, field) catch {
                            try fields.append(self.alloc, field);
                            continue;
                        };
                        try fields.appendSlice(self.alloc, globbed);
                    }
                } else {
                    try fields.appendSlice(self.alloc, split);
                }
            }
        }
        return fields.toOwnedSlice(self.alloc);
    }

    fn expandPart(self: *Expander, part: ast.WordPart) ExpandError![]const u8 {
        switch (part) {
            .literal => |lit| return try self.alloc.dupe(u8, lit),
            .single_quoted => |sq| return try self.alloc.dupe(u8, sq),
            .double_quoted => |parts| {
                var result: std.ArrayListUnmanaged(u8) = .empty;
                for (parts) |inner| {
                    const expanded = try self.expandPart(inner);
                    try result.appendSlice(self.alloc, expanded);
                    self.alloc.free(expanded);
                }
                return result.toOwnedSlice(self.alloc);
            },
            .parameter => |param| return try self.expandParameter(param),
            .command_sub => |cs| return try self.expandCommandSub(cs),
            .arith_sub => |expr| return try self.expandArithmetic(expr),
            .backtick_sub => |body| return try self.expandCommandSub(.{ .body = body }),
            .tilde => |tilde_text| return try self.expandTilde(tilde_text),
        }
    }

    fn expandParameter(self: *Expander, param: ast.ParameterExp) ExpandError![]const u8 {
        switch (param) {
            .simple => |name| {
                if (self.env.get(name)) |val| return try self.alloc.dupe(u8, val);
                return try self.alloc.dupe(u8, "");
            },
            .special => |c| return try self.expandSpecial(c),
            .positional => |n| {
                if (n == 0) {
                    return try self.alloc.dupe(u8, "zigsh");
                }
                if (self.env.getPositional(n)) |val| return try self.alloc.dupe(u8, val);
                return try self.alloc.dupe(u8, "");
            },
            .length => |name| {
                if (self.env.get(name)) |val| {
                    return try std.fmt.allocPrint(self.alloc, "{d}", .{val.len});
                }
                return try self.alloc.dupe(u8, "0");
            },
            .default => |op| {
                const val = self.env.get(op.name);
                if (val == null or (op.colon and val.?.len == 0)) {
                    return try self.expandWord(op.word);
                }
                return try self.alloc.dupe(u8, val.?);
            },
            .assign => |op| {
                const val = self.env.get(op.name);
                if (val == null or (op.colon and val.?.len == 0)) {
                    const new_val = try self.expandWord(op.word);
                    self.env.set(op.name, new_val, false) catch {};
                    return new_val;
                }
                return try self.alloc.dupe(u8, val.?);
            },
            .error_msg => |op| {
                const val = self.env.get(op.name);
                if (val == null or (op.colon and val.?.len == 0)) {
                    const msg = try self.expandWord(op.word);
                    const err_msg = std.fmt.allocPrint(self.alloc, "zigsh: {s}: {s}\n", .{ op.name, msg }) catch {
                        self.alloc.free(msg);
                        return error.OutOfMemory;
                    };
                    _ = std.c.write(2, err_msg.ptr, err_msg.len);
                    self.alloc.free(err_msg);
                    self.alloc.free(msg);
                    return error.UnsetVariable;
                }
                return try self.alloc.dupe(u8, val.?);
            },
            .alternative => |op| {
                const val = self.env.get(op.name);
                if (val != null and (!op.colon or val.?.len > 0)) {
                    return try self.expandWord(op.word);
                }
                return try self.alloc.dupe(u8, "");
            },
            .prefix_strip => |op| return try self.stripPattern(op.name, op.pattern, .prefix_short),
            .prefix_strip_long => |op| return try self.stripPattern(op.name, op.pattern, .prefix_long),
            .suffix_strip => |op| return try self.stripPattern(op.name, op.pattern, .suffix_short),
            .suffix_strip_long => |op| return try self.stripPattern(op.name, op.pattern, .suffix_long),
        }
    }

    const StripMode = enum { prefix_short, prefix_long, suffix_short, suffix_long };

    fn stripPattern(self: *Expander, name: []const u8, pattern: ast.Word, mode: StripMode) ExpandError![]const u8 {
        const val = self.env.get(name) orelse return try self.alloc.dupe(u8, "");
        const pat = try self.expandWord(pattern);
        defer self.alloc.free(pat);

        switch (mode) {
            .prefix_short => {
                var i: usize = 0;
                while (i <= val.len) : (i += 1) {
                    if (simpleMatch(pat, val[0..i])) {
                        return try self.alloc.dupe(u8, val[i..]);
                    }
                }
            },
            .prefix_long => {
                var i: usize = val.len;
                while (true) {
                    if (simpleMatch(pat, val[0..i])) {
                        return try self.alloc.dupe(u8, val[i..]);
                    }
                    if (i == 0) break;
                    i -= 1;
                }
            },
            .suffix_short => {
                var i: usize = val.len;
                while (true) {
                    if (simpleMatch(pat, val[i..])) {
                        return try self.alloc.dupe(u8, val[0..i]);
                    }
                    if (i == 0) break;
                    i -= 1;
                }
            },
            .suffix_long => {
                var i: usize = 0;
                while (i <= val.len) : (i += 1) {
                    if (simpleMatch(pat, val[i..])) {
                        return try self.alloc.dupe(u8, val[0..i]);
                    }
                }
            },
        }
        return try self.alloc.dupe(u8, val);
    }

    fn expandSpecial(self: *Expander, c: u8) ExpandError![]const u8 {
        switch (c) {
            '?' => return try std.fmt.allocPrint(self.alloc, "{d}", .{self.env.last_exit_status}),
            '$' => return try std.fmt.allocPrint(self.alloc, "{d}", .{self.env.shell_pid}),
            '#' => return try std.fmt.allocPrint(self.alloc, "{d}", .{self.env.positional_params.len}),
            '!' => {
                if (self.env.last_bg_pid) |pid| {
                    return try std.fmt.allocPrint(self.alloc, "{d}", .{pid});
                }
                return try self.alloc.dupe(u8, "");
            },
            '-' => return try self.alloc.dupe(u8, self.env.options.toFlagString()),
            '@', '*' => {
                var result: std.ArrayListUnmanaged(u8) = .empty;
                for (self.env.positional_params, 0..) |param, i| {
                    if (i > 0) try result.append(self.alloc, ' ');
                    try result.appendSlice(self.alloc, param);
                }
                return result.toOwnedSlice(self.alloc);
            },
            '0' => return try self.alloc.dupe(u8, "zigsh"),
            else => return try self.alloc.dupe(u8, ""),
        }
    }

    fn expandTilde(self: *Expander, text: []const u8) ExpandError![]const u8 {
        if (text.len == 1) {
            if (self.env.get("HOME")) |home| return try self.alloc.dupe(u8, home);
        }
        return try self.alloc.dupe(u8, text);
    }

    fn expandCommandSub(self: *Expander, cs: ast.CommandSub) ExpandError![]const u8 {
        const pipe_fds = posix.pipe() catch return error.CommandSubstitutionFailed;

        const pid = posix.fork() catch {
            posix.close(pipe_fds[0]);
            posix.close(pipe_fds[1]);
            return error.CommandSubstitutionFailed;
        };

        if (pid == 0) {
            posix.close(pipe_fds[0]);
            posix.dup2(pipe_fds[1], 1) catch posix.exit(1);
            posix.close(pipe_fds[1]);

            var lexer = Lexer.init(cs.body);
            var parser = Parser.init(self.alloc, &lexer) catch posix.exit(2);
            const program = parser.parseProgram() catch posix.exit(2);

            const Executor = @import("executor.zig").Executor;
            var executor = Executor.init(self.alloc, self.env, self.jobs);
            const status = executor.executeProgram(program);
            posix.exit(status);
        }

        posix.close(pipe_fds[1]);

        var output: std.ArrayListUnmanaged(u8) = .empty;
        var buf: [4096]u8 = undefined;
        while (true) {
            const n = posix.read(pipe_fds[0], &buf) catch break;
            if (n == 0) break;
            output.appendSlice(self.alloc, buf[0..n]) catch break;
        }
        posix.close(pipe_fds[0]);

        _ = posix.waitpid(pid, 0);

        while (output.items.len > 0 and output.items[output.items.len - 1] == '\n') {
            _ = output.pop();
        }

        return output.toOwnedSlice(self.alloc);
    }

    fn expandArithmetic(self: *Expander, expr: []const u8) ExpandError![]const u8 {
        var expanded_expr: std.ArrayListUnmanaged(u8) = .empty;
        var i: usize = 0;
        while (i < expr.len) {
            if (expr[i] == '$' and i + 1 < expr.len) {
                if (expr[i + 1] == '{') {
                    i += 2;
                    const start = i;
                    while (i < expr.len and expr[i] != '}') : (i += 1) {}
                    const name = expr[start..i];
                    if (i < expr.len) i += 1;
                    const val = self.env.get(name) orelse "0";
                    try expanded_expr.appendSlice(self.alloc, val);
                } else if (isNameStart(expr[i + 1])) {
                    i += 1;
                    const start = i;
                    while (i < expr.len and isNameCont(expr[i])) : (i += 1) {}
                    const name = expr[start..i];
                    const val = self.env.get(name) orelse "0";
                    try expanded_expr.appendSlice(self.alloc, val);
                } else if (expr[i + 1] >= '0' and expr[i + 1] <= '9') {
                    i += 1;
                    const digit = expr[i] - '0';
                    i += 1;
                    const val = if (digit == 0) "0" else self.env.getPositional(@intCast(digit)) orelse "0";
                    try expanded_expr.appendSlice(self.alloc, val);
                } else if (expr[i + 1] == '#') {
                    i += 2;
                    var num_buf: [16]u8 = undefined;
                    const val = std.fmt.bufPrint(&num_buf, "{d}", .{self.env.positional_params.len}) catch "0";
                    try expanded_expr.appendSlice(self.alloc, val);
                } else if (expr[i + 1] == '?') {
                    i += 2;
                    var num_buf: [16]u8 = undefined;
                    const val = std.fmt.bufPrint(&num_buf, "{d}", .{self.env.last_exit_status}) catch "0";
                    try expanded_expr.appendSlice(self.alloc, val);
                } else if (expr[i + 1] == '$') {
                    i += 2;
                    var num_buf: [16]u8 = undefined;
                    const val = std.fmt.bufPrint(&num_buf, "{d}", .{self.env.shell_pid}) catch "0";
                    try expanded_expr.appendSlice(self.alloc, val);
                } else {
                    try expanded_expr.append(self.alloc, expr[i]);
                    i += 1;
                }
            } else {
                try expanded_expr.append(self.alloc, expr[i]);
                i += 1;
            }
        }
        const final_expr = try expanded_expr.toOwnedSlice(self.alloc);
        defer self.alloc.free(final_expr);

        const env_ptr = self.env;
        const lookup = struct {
            var env: *Environment = undefined;
            fn f(name: []const u8) ?[]const u8 {
                return env.get(name);
            }
        };
        lookup.env = env_ptr;
        const result = Arithmetic.evaluate(final_expr, &lookup.f) catch return error.ArithmeticError;
        return std.fmt.allocPrint(self.alloc, "{d}", .{result});
    }

    fn isNameStart(ch: u8) bool {
        return (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or ch == '_';
    }

    fn isNameCont(ch: u8) bool {
        return isNameStart(ch) or (ch >= '0' and ch <= '9');
    }

    fn fieldSplit(self: *Expander, input: []const u8) ExpandError![]const []const u8 {
        var fields: std.ArrayListUnmanaged([]const u8) = .empty;
        const ifs = self.env.ifs;
        var i: usize = 0;

        while (i < input.len) {
            while (i < input.len and isIfsChar(input[i], ifs)) : (i += 1) {}
            if (i >= input.len) break;

            const start = i;
            while (i < input.len and !isIfsChar(input[i], ifs)) : (i += 1) {}

            try fields.append(self.alloc, try self.alloc.dupe(u8, input[start..i]));
        }

        self.alloc.free(input);
        return fields.toOwnedSlice(self.alloc);
    }

    fn isIfsChar(c: u8, ifs: []const u8) bool {
        return std.mem.indexOfScalar(u8, ifs, c) != null;
    }

    fn isQuoted(word: ast.Word) bool {
        if (word.parts.len == 1) {
            return switch (word.parts[0]) {
                .single_quoted, .double_quoted => true,
                else => false,
            };
        }
        return false;
    }
};

fn simpleMatch(pattern: []const u8, text: []const u8) bool {
    var pi: usize = 0;
    var ti: usize = 0;
    var star_pi: ?usize = null;
    var star_ti: usize = 0;

    while (ti < text.len) {
        if (pi < pattern.len and (pattern[pi] == '?' or pattern[pi] == text[ti])) {
            pi += 1;
            ti += 1;
        } else if (pi < pattern.len and pattern[pi] == '*') {
            star_pi = pi;
            star_ti = ti;
            pi += 1;
        } else if (star_pi) |sp| {
            pi = sp + 1;
            star_ti += 1;
            ti = star_ti;
        } else {
            return false;
        }
    }

    while (pi < pattern.len and pattern[pi] == '*') : (pi += 1) {}
    return pi == pattern.len;
}

test "expand literal word" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = @import("env.zig").Environment.init(alloc);
    var jobs = JobTable.init(alloc);
    var exp = Expander.init(alloc, &env, &jobs);

    const word = ast.Word{
        .parts = &.{.{ .literal = "hello" }},
    };
    const result = try exp.expandWord(word);
    try std.testing.expectEqualStrings("hello", result);
}

test "expand parameter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = @import("env.zig").Environment.init(alloc);
    try env.set("FOO", "bar", false);
    var jobs = JobTable.init(alloc);
    var exp = Expander.init(alloc, &env, &jobs);

    const word = ast.Word{
        .parts = &.{.{ .parameter = .{ .simple = "FOO" } }},
    };
    const result = try exp.expandWord(word);
    try std.testing.expectEqualStrings("bar", result);
}

test "expand default value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = @import("env.zig").Environment.init(alloc);
    var jobs = JobTable.init(alloc);
    var exp = Expander.init(alloc, &env, &jobs);

    const default_word = ast.Word{
        .parts = &.{.{ .literal = "default" }},
    };
    const word = ast.Word{
        .parts = &.{.{ .parameter = .{ .default = .{
            .name = "UNSET",
            .colon = true,
            .word = default_word,
        } } }},
    };
    const result = try exp.expandWord(word);
    try std.testing.expectEqualStrings("default", result);
}

test "simple pattern matching" {
    try std.testing.expect(simpleMatch("*.txt", "file.txt"));
    try std.testing.expect(!simpleMatch("*.txt", "file.log"));
    try std.testing.expect(simpleMatch("?oo", "foo"));
    try std.testing.expect(simpleMatch("*", "anything"));
}
