const std = @import("std");
const ast = @import("ast.zig");
const Lexer = @import("lexer.zig").Lexer;
const Parser = @import("parser.zig").Parser;
const Arithmetic = @import("arithmetic.zig").Arithmetic;
const glob = @import("glob.zig");
const posix = @import("posix.zig");
const types = @import("types.zig");
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
            const ew = try self.expandWordWithSplitInfo(word);
            if (ew.text.len == 0) {
                if (hasQuotedParts(word)) {
                    try fields.append(self.alloc, ew.text);
                }
                continue;
            }
            const split = try self.fieldSplitWithQuoting(ew.text, ew.splittable);
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
                if (self.env.options.nounset) {
                    const msg = std.fmt.allocPrint(self.alloc, "zigsh: {s}: parameter not set\n", .{name}) catch return error.OutOfMemory;
                    _ = std.c.write(2, msg.ptr, msg.len);
                    self.alloc.free(msg);
                    return error.UnsetVariable;
                }
                return try self.alloc.dupe(u8, "");
            },
            .special => |ch| return try self.expandSpecial(ch),
            .positional => |n| {
                if (n == 0) {
                    return try self.alloc.dupe(u8, "zigsh");
                }
                if (self.env.getPositional(n)) |val| return try self.alloc.dupe(u8, val);
                if (self.env.options.nounset) {
                    const msg = std.fmt.allocPrint(self.alloc, "zigsh: {d}: parameter not set\n", .{n}) catch return error.OutOfMemory;
                    _ = std.c.write(2, msg.ptr, msg.len);
                    self.alloc.free(msg);
                    return error.UnsetVariable;
                }
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
                    if (glob.fnmatch(pat, val[0..i])) {
                        return try self.alloc.dupe(u8, val[i..]);
                    }
                }
            },
            .prefix_long => {
                var i: usize = val.len;
                while (true) {
                    if (glob.fnmatch(pat, val[0..i])) {
                        return try self.alloc.dupe(u8, val[i..]);
                    }
                    if (i == 0) break;
                    i -= 1;
                }
            },
            .suffix_short => {
                var i: usize = val.len;
                while (true) {
                    if (glob.fnmatch(pat, val[i..])) {
                        return try self.alloc.dupe(u8, val[0..i]);
                    }
                    if (i == 0) break;
                    i -= 1;
                }
            },
            .suffix_long => {
                var i: usize = 0;
                while (i <= val.len) : (i += 1) {
                    if (glob.fnmatch(pat, val[i..])) {
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
        if (text.len == 1 and text[0] == '~') {
            if (self.env.get("HOME")) |home| return try self.alloc.dupe(u8, home);
            return try self.alloc.dupe(u8, text);
        }
        if (text.len == 2 and text[0] == '~' and text[1] == '+') {
            if (self.env.get("PWD")) |pwd| return try self.alloc.dupe(u8, pwd);
            return try self.alloc.dupe(u8, text);
        }
        if (text.len == 2 and text[0] == '~' and text[1] == '-') {
            if (self.env.get("OLDPWD")) |oldpwd| return try self.alloc.dupe(u8, oldpwd);
            return try self.alloc.dupe(u8, text);
        }
        if (text.len > 1 and text[0] == '~') {
            const username = text[1..];
            const username_z = self.alloc.dupeZ(u8, username) catch return error.OutOfMemory;
            defer self.alloc.free(username_z);
            if (posix.getpwnam(username_z.ptr)) |home_dir| {
                return try self.alloc.dupe(u8, std.mem.sliceTo(home_dir, 0));
            }
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
                } else if (types.isNameStart(expr[i + 1])) {
                    i += 1;
                    const start = i;
                    while (i < expr.len and types.isNameCont(expr[i])) : (i += 1) {}
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

    const SplitInfo = struct {
        text: []const u8,
        splittable: []const bool,
    };

    fn expandWordWithSplitInfo(self: *Expander, word: ast.Word) ExpandError!SplitInfo {
        var text: std.ArrayListUnmanaged(u8) = .empty;
        var splittable: std.ArrayListUnmanaged(bool) = .empty;

        for (word.parts) |part| {
            const expanded = try self.expandPart(part);
            const is_splittable = switch (part) {
                .parameter, .command_sub, .arith_sub, .backtick_sub => true,
                .literal, .single_quoted, .double_quoted, .tilde => false,
            };
            try text.appendSlice(self.alloc, expanded);
            for (0..expanded.len) |_| {
                try splittable.append(self.alloc, is_splittable);
            }
        }

        return .{
            .text = try text.toOwnedSlice(self.alloc),
            .splittable = try splittable.toOwnedSlice(self.alloc),
        };
    }

    fn fieldSplitWithQuoting(self: *Expander, text: []const u8, splittable: []const bool) ExpandError![]const []const u8 {
        var fields: std.ArrayListUnmanaged([]const u8) = .empty;
        const ifs = self.env.ifs;
        var i: usize = 0;

        while (i < text.len and splittable[i] and isIfsChar(text[i], ifs)) : (i += 1) {}

        while (i < text.len) {
            var field: std.ArrayListUnmanaged(u8) = .empty;

            while (i < text.len) {
                if (splittable[i] and isIfsChar(text[i], ifs)) break;
                try field.append(self.alloc, text[i]);
                i += 1;
            }

            if (field.items.len > 0) {
                try fields.append(self.alloc, try field.toOwnedSlice(self.alloc));
            }

            while (i < text.len and splittable[i] and isIfsChar(text[i], ifs)) : (i += 1) {}
        }

        return fields.toOwnedSlice(self.alloc);
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

    fn isIfsChar(ch: u8, ifs: []const u8) bool {
        return std.mem.indexOfScalar(u8, ifs, ch) != null;
    }

    fn hasQuotedParts(word: ast.Word) bool {
        for (word.parts) |part| {
            switch (part) {
                .single_quoted, .double_quoted => return true,
                else => {},
            }
        }
        return false;
    }
};

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

test "expand single quoted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env_inst = @import("env.zig").Environment.init(alloc);
    var jobs = JobTable.init(alloc);
    var exp = Expander.init(alloc, &env_inst, &jobs);

    const word = ast.Word{ .parts = &.{.{ .single_quoted = "hello world" }} };
    const result = try exp.expandWord(word);
    try std.testing.expectEqualStrings("hello world", result);
}

test "expand special param question mark" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env_inst = @import("env.zig").Environment.init(alloc);
    env_inst.last_exit_status = 42;
    var jobs = JobTable.init(alloc);
    var exp = Expander.init(alloc, &env_inst, &jobs);

    const word = ast.Word{ .parts = &.{.{ .parameter = .{ .special = '?' } }} };
    const result = try exp.expandWord(word);
    try std.testing.expectEqualStrings("42", result);
}

test "expand special param hash" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env_inst = @import("env.zig").Environment.init(alloc);
    const params: []const []const u8 = &.{ "a", "b", "c" };
    env_inst.positional_params = params;
    var jobs = JobTable.init(alloc);
    var exp = Expander.init(alloc, &env_inst, &jobs);

    const word = ast.Word{ .parts = &.{.{ .parameter = .{ .special = '#' } }} };
    const result = try exp.expandWord(word);
    try std.testing.expectEqualStrings("3", result);
}

test "expand positional param" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env_inst = @import("env.zig").Environment.init(alloc);
    const params: []const []const u8 = &.{ "first", "second" };
    env_inst.positional_params = params;
    var jobs = JobTable.init(alloc);
    var exp = Expander.init(alloc, &env_inst, &jobs);

    const word = ast.Word{ .parts = &.{.{ .parameter = .{ .positional = 1 } }} };
    const result = try exp.expandWord(word);
    try std.testing.expectEqualStrings("first", result);

    const word2 = ast.Word{ .parts = &.{.{ .parameter = .{ .positional = 2 } }} };
    const result2 = try exp.expandWord(word2);
    try std.testing.expectEqualStrings("second", result2);

    const word3 = ast.Word{ .parts = &.{.{ .parameter = .{ .positional = 3 } }} };
    const result3 = try exp.expandWord(word3);
    try std.testing.expectEqualStrings("", result3);
}

test "expand length" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env_inst = @import("env.zig").Environment.init(alloc);
    try env_inst.set("MSG", "hello", false);
    var jobs = JobTable.init(alloc);
    var exp = Expander.init(alloc, &env_inst, &jobs);

    const word = ast.Word{ .parts = &.{.{ .parameter = .{ .length = "MSG" } }} };
    const result = try exp.expandWord(word);
    try std.testing.expectEqualStrings("5", result);
}

test "expand length unset" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env_inst = @import("env.zig").Environment.init(alloc);
    var jobs = JobTable.init(alloc);
    var exp = Expander.init(alloc, &env_inst, &jobs);

    const word = ast.Word{ .parts = &.{.{ .parameter = .{ .length = "NOPE" } }} };
    const result = try exp.expandWord(word);
    try std.testing.expectEqualStrings("0", result);
}

test "expand alternative value set" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env_inst = @import("env.zig").Environment.init(alloc);
    try env_inst.set("X", "val", false);
    var jobs = JobTable.init(alloc);
    var exp = Expander.init(alloc, &env_inst, &jobs);

    const alt_word = ast.Word{ .parts = &.{.{ .literal = "alt" }} };
    const word = ast.Word{ .parts = &.{.{ .parameter = .{ .alternative = .{
        .name = "X",
        .colon = false,
        .word = alt_word,
    } } }} };
    const result = try exp.expandWord(word);
    try std.testing.expectEqualStrings("alt", result);
}

test "expand alternative value unset" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env_inst = @import("env.zig").Environment.init(alloc);
    var jobs = JobTable.init(alloc);
    var exp = Expander.init(alloc, &env_inst, &jobs);

    const alt_word = ast.Word{ .parts = &.{.{ .literal = "alt" }} };
    const word = ast.Word{ .parts = &.{.{ .parameter = .{ .alternative = .{
        .name = "NOPE",
        .colon = false,
        .word = alt_word,
    } } }} };
    const result = try exp.expandWord(word);
    try std.testing.expectEqualStrings("", result);
}

test "expand assign value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env_inst = @import("env.zig").Environment.init(alloc);
    var jobs = JobTable.init(alloc);
    var exp = Expander.init(alloc, &env_inst, &jobs);

    const assign_word = ast.Word{ .parts = &.{.{ .literal = "assigned" }} };
    const word = ast.Word{ .parts = &.{.{ .parameter = .{ .assign = .{
        .name = "NEW",
        .colon = true,
        .word = assign_word,
    } } }} };
    const result = try exp.expandWord(word);
    try std.testing.expectEqualStrings("assigned", result);
    try std.testing.expectEqualStrings("assigned", env_inst.get("NEW").?);
}

test "expand tilde" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env_inst = @import("env.zig").Environment.init(alloc);
    try env_inst.set("HOME", "/home/test", false);
    var jobs = JobTable.init(alloc);
    var exp = Expander.init(alloc, &env_inst, &jobs);

    const word = ast.Word{ .parts = &.{.{ .tilde = "~" }} };
    const result = try exp.expandWord(word);
    try std.testing.expectEqualStrings("/home/test", result);
}

test "expand double quoted parts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env_inst = @import("env.zig").Environment.init(alloc);
    try env_inst.set("NAME", "world", false);
    var jobs = JobTable.init(alloc);
    var exp = Expander.init(alloc, &env_inst, &jobs);

    const inner_parts: []const ast.WordPart = &.{
        .{ .literal = "hello " },
        .{ .parameter = .{ .simple = "NAME" } },
    };
    const word = ast.Word{ .parts = &.{.{ .double_quoted = inner_parts }} };
    const result = try exp.expandWord(word);
    try std.testing.expectEqualStrings("hello world", result);
}

test "field splitting" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env_inst = @import("env.zig").Environment.init(alloc);
    try env_inst.set("VAR", "one two three", false);
    var jobs = JobTable.init(alloc);
    var exp = Expander.init(alloc, &env_inst, &jobs);

    const word = ast.Word{ .parts = &.{.{ .parameter = .{ .simple = "VAR" } }} };
    const fields = try exp.expandFields(word);
    try std.testing.expectEqual(@as(usize, 3), fields.len);
    try std.testing.expectEqualStrings("one", fields[0]);
    try std.testing.expectEqualStrings("two", fields[1]);
    try std.testing.expectEqualStrings("three", fields[2]);
}

test "no field split on literal plus single quoted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env_inst = @import("env.zig").Environment.init(alloc);
    var jobs = JobTable.init(alloc);
    var exp = Expander.init(alloc, &env_inst, &jobs);

    const word = ast.Word{ .parts = &.{
        .{ .literal = "ll=" },
        .{ .single_quoted = "ls -l" },
    } };
    const fields = try exp.expandWordsToFields(&.{word});
    try std.testing.expectEqual(@as(usize, 1), fields.len);
    try std.testing.expectEqualStrings("ll=ls -l", fields[0]);
}

test "field split only unquoted expansion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env_inst = @import("env.zig").Environment.init(alloc);
    try env_inst.set("FOO", "a b", false);
    var jobs = JobTable.init(alloc);
    var exp = Expander.init(alloc, &env_inst, &jobs);

    const word = ast.Word{ .parts = &.{
        .{ .parameter = .{ .simple = "FOO" } },
        .{ .single_quoted = "bar" },
    } };
    const fields = try exp.expandWordsToFields(&.{word});
    try std.testing.expectEqual(@as(usize, 2), fields.len);
    try std.testing.expectEqualStrings("a", fields[0]);
    try std.testing.expectEqualStrings("bbar", fields[1]);
}

test "expand default when var is set" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env_inst = @import("env.zig").Environment.init(alloc);
    try env_inst.set("X", "existing", false);
    var jobs = JobTable.init(alloc);
    var exp = Expander.init(alloc, &env_inst, &jobs);

    const default_word = ast.Word{ .parts = &.{.{ .literal = "default" }} };
    const word = ast.Word{ .parts = &.{.{ .parameter = .{ .default = .{
        .name = "X",
        .colon = true,
        .word = default_word,
    } } }} };
    const result = try exp.expandWord(word);
    try std.testing.expectEqualStrings("existing", result);
}
