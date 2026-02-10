const std = @import("std");
const posix = @import("posix.zig");
const JobTable = @import("jobs.zig").JobTable;
const LineEditor = @import("line_editor.zig").LineEditor;

pub const Environment = struct {
    vars: std.StringHashMap(Variable),
    positional_params: []const []const u8,
    positional_stack: std.ArrayListUnmanaged([]const []const u8),
    functions: std.StringHashMap(FunctionDef),
    last_exit_status: u8,
    shell_pid: posix.pid_t,
    last_bg_pid: ?posix.pid_t,
    ifs: []const u8,

    alloc: std.mem.Allocator,

    options: ShellOptions,
    shopt: ShoptOptions,
    aliases: std.StringHashMap([]const u8),
    command_hash: std.StringHashMap([]const u8),

    loop_depth: u32,
    break_count: u32,
    continue_count: u32,
    errexit_suppressed: u32,
    should_return: bool,
    return_value: u8,
    should_exit: bool,
    exit_value: u8,
    in_subshell: bool,
    shell_name: []const u8,
    job_table: ?*JobTable,
    history: ?*LineEditor.History,
    command_number: u32,

    pub const Variable = struct {
        value: []const u8,
        exported: bool,
        readonly: bool,
        integer: bool = false,
    };

    pub const FunctionDef = struct {
        source: []const u8,
    };

    pub const ShellOptions = struct {
        errexit: bool = false,
        nounset: bool = false,
        xtrace: bool = false,
        noglob: bool = false,
        noexec: bool = false,
        allexport: bool = false,
        monitor: bool = false,
        noclobber: bool = false,
        verbose: bool = false,
        interactive: bool = false,
        pipefail: bool = false,

        flag_buf: [16]u8 = undefined,

        pub fn toFlagString(self: *ShellOptions) []const u8 {
            var len: usize = 0;
            if (self.errexit) { self.flag_buf[len] = 'e'; len += 1; }
            if (self.nounset) { self.flag_buf[len] = 'u'; len += 1; }
            if (self.xtrace) { self.flag_buf[len] = 'x'; len += 1; }
            if (self.noglob) { self.flag_buf[len] = 'f'; len += 1; }
            if (self.noexec) { self.flag_buf[len] = 'n'; len += 1; }
            if (self.allexport) { self.flag_buf[len] = 'a'; len += 1; }
            if (self.monitor) { self.flag_buf[len] = 'm'; len += 1; }
            if (self.noclobber) { self.flag_buf[len] = 'C'; len += 1; }
            if (self.verbose) { self.flag_buf[len] = 'v'; len += 1; }
            if (self.interactive) { self.flag_buf[len] = 'i'; len += 1; }
            return self.flag_buf[0..len];
        }
    };

    pub const ShoptOptions = struct {
        nullglob: bool = false,
        failglob: bool = false,
        extglob: bool = false,
        dotglob: bool = false,
        globstar: bool = false,
        lastpipe: bool = false,
        expand_aliases: bool = false,
        nocaseglob: bool = false,
        nocasematch: bool = false,
        inherit_errexit: bool = false,
        autocd: bool = false,
        cdable_vars: bool = false,
        checkwinsize: bool = false,
        ignore_shopt_not_impl: bool = false,
    };

    pub fn setOption(self: *Environment, name: []const u8, enable: bool) void {
        if (std.mem.eql(u8, name, "errexit")) { self.options.errexit = enable; }
        else if (std.mem.eql(u8, name, "nounset")) { self.options.nounset = enable; }
        else if (std.mem.eql(u8, name, "xtrace")) { self.options.xtrace = enable; }
        else if (std.mem.eql(u8, name, "noglob")) { self.options.noglob = enable; }
        else if (std.mem.eql(u8, name, "noexec")) { self.options.noexec = enable; }
        else if (std.mem.eql(u8, name, "allexport")) { self.options.allexport = enable; }
        else if (std.mem.eql(u8, name, "monitor")) { self.options.monitor = enable; }
        else if (std.mem.eql(u8, name, "noclobber")) { self.options.noclobber = enable; }
        else if (std.mem.eql(u8, name, "verbose")) { self.options.verbose = enable; }
        else if (std.mem.eql(u8, name, "pipefail")) { self.options.pipefail = enable; }
    }

    pub fn setShortOption(self: *Environment, ch: u8, enable: bool) void {
        switch (ch) {
            'e' => self.options.errexit = enable,
            'u' => self.options.nounset = enable,
            'x' => self.options.xtrace = enable,
            'f' => self.options.noglob = enable,
            'n' => self.options.noexec = enable,
            'a' => self.options.allexport = enable,
            'v' => self.options.verbose = enable,
            'C' => self.options.noclobber = enable,
            'm' => self.options.monitor = enable,
            'i' => self.options.interactive = enable,
            else => {},
        }
    }

    pub fn setShoptOption(self: *Environment, name: []const u8, enable: bool) void {
        if (std.mem.eql(u8, name, "nullglob")) { self.shopt.nullglob = enable; }
        else if (std.mem.eql(u8, name, "failglob")) { self.shopt.failglob = enable; }
        else if (std.mem.eql(u8, name, "extglob")) { self.shopt.extglob = enable; }
        else if (std.mem.eql(u8, name, "dotglob")) { self.shopt.dotglob = enable; }
        else if (std.mem.eql(u8, name, "globstar")) { self.shopt.globstar = enable; }
        else if (std.mem.eql(u8, name, "lastpipe")) { self.shopt.lastpipe = enable; }
        else if (std.mem.eql(u8, name, "expand_aliases")) { self.shopt.expand_aliases = enable; }
        else if (std.mem.eql(u8, name, "nocaseglob")) { self.shopt.nocaseglob = enable; }
        else if (std.mem.eql(u8, name, "nocasematch")) { self.shopt.nocasematch = enable; }
        else if (std.mem.eql(u8, name, "inherit_errexit")) { self.shopt.inherit_errexit = enable; }
    }

    pub fn init(alloc: std.mem.Allocator) Environment {
        var env = Environment{
            .vars = std.StringHashMap(Variable).init(alloc),
            .positional_params = &.{},
            .positional_stack = .empty,
            .functions = std.StringHashMap(FunctionDef).init(alloc),
            .last_exit_status = 0,
            .shell_pid = posix.getpid(),
            .last_bg_pid = null,
            .ifs = " \t\n",
            .alloc = alloc,
            .options = .{},
            .shopt = .{},
            .aliases = std.StringHashMap([]const u8).init(alloc),
            .command_hash = std.StringHashMap([]const u8).init(alloc),
            .loop_depth = 0,
            .break_count = 0,
            .continue_count = 0,
            .errexit_suppressed = 0,
            .should_return = false,
            .return_value = 0,
            .should_exit = false,
            .exit_value = 0,
            .in_subshell = false,
            .shell_name = "zigsh",
            .job_table = null,
            .history = null,
            .command_number = 0,
        };

        env.importEnviron();
        return env;
    }

    pub fn deinit(self: *Environment) void {
        var it = self.vars.iterator();
        while (it.next()) |entry| {
            self.alloc.free(entry.key_ptr.*);
            self.alloc.free(entry.value_ptr.value);
        }
        self.vars.deinit();

        var fit = self.functions.iterator();
        while (fit.next()) |entry| {
            self.alloc.free(entry.key_ptr.*);
            self.alloc.free(entry.value_ptr.source);
        }
        self.functions.deinit();

        self.positional_stack.deinit(self.alloc);

        var ait = self.aliases.iterator();
        while (ait.next()) |entry| {
            self.alloc.free(entry.key_ptr.*);
            self.alloc.free(entry.value_ptr.*);
        }
        self.aliases.deinit();

        var hit = self.command_hash.iterator();
        while (hit.next()) |entry| {
            self.alloc.free(entry.key_ptr.*);
            self.alloc.free(entry.value_ptr.*);
        }
        self.command_hash.deinit();
    }

    fn importEnviron(self: *Environment) void {
        const environ: [*:null]const ?[*:0]const u8 = @ptrCast(std.c.environ);
        var i: usize = 0;
        while (environ[i]) |entry| : (i += 1) {
            const full = std.mem.sliceTo(entry, 0);
            if (std.mem.indexOfScalar(u8, full, '=')) |eq| {
                const name = self.alloc.dupe(u8, full[0..eq]) catch continue;
                const value = self.alloc.dupe(u8, full[eq + 1 ..]) catch {
                    self.alloc.free(name);
                    continue;
                };
                self.vars.put(name, .{ .value = value, .exported = true, .readonly = false }) catch {
                    self.alloc.free(name);
                    self.alloc.free(value);
                };
            }
        }
    }

    pub fn get(self: *const Environment, name: []const u8) ?[]const u8 {
        if (self.vars.get(name)) |v| return v.value;
        return null;
    }

    pub fn set(self: *Environment, name: []const u8, value: []const u8, exported: bool) !void {
        if (self.vars.get(name)) |existing| {
            if (existing.readonly) return error.ReadonlyVariable;
        }

        const owned_value = try self.alloc.dupe(u8, value);

        if (self.vars.getPtr(name)) |existing| {
            self.alloc.free(existing.value);
            existing.value = owned_value;
            if (exported or self.options.allexport or existing.exported) existing.exported = true;
        } else {
            const owned_name = try self.alloc.dupe(u8, name);
            try self.vars.put(owned_name, .{
                .value = owned_value,
                .exported = exported or self.options.allexport,
                .readonly = false,
            });
        }

        if (std.mem.eql(u8, name, "IFS")) {
            self.ifs = self.vars.get(name).?.value;
        }
        if (std.mem.eql(u8, name, "PATH")) {
            self.clearCommandHash();
        }
    }

    pub const UnsetResult = enum { ok, readonly };

    pub fn unset(self: *Environment, name: []const u8) UnsetResult {
        if (self.vars.get(name)) |v| {
            if (v.readonly) return .readonly;
        }
        if (self.vars.fetchRemove(name)) |kv| {
            self.alloc.free(kv.key);
            self.alloc.free(kv.value.value);
        }
        if (std.mem.eql(u8, name, "IFS")) {
            self.ifs = " \t\n";
        }
        return .ok;
    }

    pub fn unsetFunction(self: *Environment, name: []const u8) bool {
        if (self.functions.fetchRemove(name)) |kv| {
            self.alloc.free(kv.key);
            self.alloc.free(kv.value.source);
            return true;
        }
        return false;
    }

    pub fn markExported(self: *Environment, name: []const u8) void {
        if (self.vars.getPtr(name)) |v| {
            v.exported = true;
        } else {
            self.set(name, "", true) catch {};
        }
    }

    pub fn markReadonly(self: *Environment, name: []const u8) void {
        if (self.vars.getPtr(name)) |v| {
            v.readonly = true;
        }
    }

    pub fn buildEnvp(self: *const Environment) ![:null]const ?[*:0]const u8 {
        var list: std.ArrayListUnmanaged(?[*:0]const u8) = .empty;
        var it = self.vars.iterator();
        while (it.next()) |entry| {
            if (!entry.value_ptr.exported) continue;
            const env_str = try std.fmt.allocPrintSentinel(self.alloc, "{s}={s}", .{ entry.key_ptr.*, entry.value_ptr.value }, 0);
            try list.append(self.alloc, env_str.ptr);
        }
        return list.toOwnedSliceSentinel(self.alloc, null);
    }

    pub fn pushPositionalParams(self: *Environment, params: []const []const u8) !void {
        try self.positional_stack.append(self.alloc, self.positional_params);
        self.positional_params = params;
    }

    pub fn popPositionalParams(self: *Environment) void {
        if (self.positional_stack.items.len > 0) {
            self.positional_params = self.positional_stack.pop().?;
        }
    }

    pub fn getPositional(self: *const Environment, n: u32) ?[]const u8 {
        if (n == 0) return null;
        const idx = n - 1;
        if (idx < self.positional_params.len) return self.positional_params[idx];
        return null;
    }

    pub fn setAlias(self: *Environment, name: []const u8, value: []const u8) !void {
        const owned_value = try self.alloc.dupe(u8, value);
        if (self.aliases.getPtr(name)) |existing| {
            self.alloc.free(existing.*);
            existing.* = owned_value;
        } else {
            const owned_name = try self.alloc.dupe(u8, name);
            try self.aliases.put(owned_name, owned_value);
        }
    }

    pub fn removeAlias(self: *Environment, name: []const u8) bool {
        if (self.aliases.fetchRemove(name)) |kv| {
            self.alloc.free(kv.key);
            self.alloc.free(kv.value);
            return true;
        }
        return false;
    }

    pub fn getAlias(self: *const Environment, name: []const u8) ?[]const u8 {
        return self.aliases.get(name);
    }

    pub fn clearAliases(self: *Environment) void {
        var it = self.aliases.iterator();
        while (it.next()) |entry| {
            self.alloc.free(entry.key_ptr.*);
            self.alloc.free(entry.value_ptr.*);
        }
        self.aliases.clearAndFree();
    }

    pub fn cacheCommand(self: *Environment, name: []const u8, path: []const u8) !void {
        const owned_path = try self.alloc.dupe(u8, path);
        if (self.command_hash.getPtr(name)) |existing| {
            self.alloc.free(existing.*);
            existing.* = owned_path;
        } else {
            const owned_name = try self.alloc.dupe(u8, name);
            try self.command_hash.put(owned_name, owned_path);
        }
    }

    pub fn getCachedCommand(self: *const Environment, name: []const u8) ?[]const u8 {
        return self.command_hash.get(name);
    }

    pub fn removeCachedCommand(self: *Environment, name: []const u8) void {
        if (self.command_hash.fetchRemove(name)) |kv| {
            self.alloc.free(kv.key);
            self.alloc.free(kv.value);
        }
    }

    pub fn clearCommandHash(self: *Environment) void {
        var it = self.command_hash.iterator();
        while (it.next()) |entry| {
            self.alloc.free(entry.key_ptr.*);
            self.alloc.free(entry.value_ptr.*);
        }
        self.command_hash.clearAndFree();
    }
};

test "env set and get" {
    var env = Environment.init(std.testing.allocator);
    defer env.deinit();

    try env.set("FOO", "bar", false);
    try std.testing.expectEqualStrings("bar", env.get("FOO").?);

    try env.set("FOO", "baz", false);
    try std.testing.expectEqualStrings("baz", env.get("FOO").?);
}

test "env unset" {
    var env = Environment.init(std.testing.allocator);
    defer env.deinit();

    try env.set("FOO", "bar", false);
    _ = env.unset("FOO");
    try std.testing.expect(env.get("FOO") == null);
}

test "env readonly" {
    var env = Environment.init(std.testing.allocator);
    defer env.deinit();

    try env.set("RO", "original", false);
    env.markReadonly("RO");
    try std.testing.expectError(error.ReadonlyVariable, env.set("RO", "modified", false));
    try std.testing.expectEqualStrings("original", env.get("RO").?);
}

test "env readonly prevents unset" {
    var env = Environment.init(std.testing.allocator);
    defer env.deinit();

    try env.set("RO", "val", false);
    env.markReadonly("RO");
    try std.testing.expect(env.unset("RO") == .readonly);
    try std.testing.expectEqualStrings("val", env.get("RO").?);
}

test "env exported" {
    var env = Environment.init(std.testing.allocator);
    defer env.deinit();

    try env.set("EX", "val", false);
    env.markExported("EX");
    const v = env.vars.get("EX").?;
    try std.testing.expect(v.exported);
}

test "env set with export flag" {
    var env = Environment.init(std.testing.allocator);
    defer env.deinit();

    try env.set("EX", "val", true);
    const v = env.vars.get("EX").?;
    try std.testing.expect(v.exported);
}

test "env IFS tracking" {
    var env = Environment.init(std.testing.allocator);
    defer env.deinit();

    try std.testing.expectEqualStrings(" \t\n", env.ifs);
    try env.set("IFS", ":", false);
    try std.testing.expectEqualStrings(":", env.ifs);
    _ = env.unset("IFS");
    try std.testing.expectEqualStrings(" \t\n", env.ifs);
}

test "env positional params" {
    var env = Environment.init(std.testing.allocator);
    defer env.deinit();

    const params: []const []const u8 = &.{ "a", "b", "c" };
    env.positional_params = params;

    try std.testing.expect(env.getPositional(0) == null);
    try std.testing.expectEqualStrings("a", env.getPositional(1).?);
    try std.testing.expectEqualStrings("b", env.getPositional(2).?);
    try std.testing.expectEqualStrings("c", env.getPositional(3).?);
    try std.testing.expect(env.getPositional(4) == null);
}

test "env positional push and pop" {
    var env = Environment.init(std.testing.allocator);
    defer env.deinit();

    const original: []const []const u8 = &.{ "a", "b" };
    env.positional_params = original;

    const new_params: []const []const u8 = &.{ "x", "y", "z" };
    try env.pushPositionalParams(new_params);
    try std.testing.expectEqual(@as(usize, 3), env.positional_params.len);
    try std.testing.expectEqualStrings("x", env.getPositional(1).?);

    env.popPositionalParams();
    try std.testing.expectEqual(@as(usize, 2), env.positional_params.len);
    try std.testing.expectEqualStrings("a", env.getPositional(1).?);
}

test "env get unset var" {
    var env = Environment.init(std.testing.allocator);
    defer env.deinit();

    try std.testing.expect(env.get("NONEXISTENT_VAR_12345") == null);
}

test "env overwrite value" {
    var env = Environment.init(std.testing.allocator);
    defer env.deinit();

    try env.set("V", "one", false);
    try env.set("V", "two", false);
    try env.set("V", "three", false);
    try std.testing.expectEqualStrings("three", env.get("V").?);
}

test "alias set get remove" {
    var env = Environment.init(std.testing.allocator);
    defer env.deinit();

    try env.setAlias("ll", "ls -l");
    try std.testing.expectEqualStrings("ls -l", env.getAlias("ll").?);

    try env.setAlias("ll", "ls -la");
    try std.testing.expectEqualStrings("ls -la", env.getAlias("ll").?);

    try std.testing.expect(env.removeAlias("ll"));
    try std.testing.expect(env.getAlias("ll") == null);
    try std.testing.expect(!env.removeAlias("ll"));
}

test "alias clear all" {
    var env = Environment.init(std.testing.allocator);
    defer env.deinit();

    try env.setAlias("a", "b");
    try env.setAlias("c", "d");
    env.clearAliases();
    try std.testing.expect(env.getAlias("a") == null);
    try std.testing.expect(env.getAlias("c") == null);
}

test "command hash cache and clear" {
    var env = Environment.init(std.testing.allocator);
    defer env.deinit();

    try env.cacheCommand("ls", "/usr/bin/ls");
    try std.testing.expectEqualStrings("/usr/bin/ls", env.getCachedCommand("ls").?);

    env.clearCommandHash();
    try std.testing.expect(env.getCachedCommand("ls") == null);
}

test "PATH change clears command hash" {
    var env = Environment.init(std.testing.allocator);
    defer env.deinit();

    try env.cacheCommand("ls", "/usr/bin/ls");
    try env.set("PATH", "/new/path", false);
    try std.testing.expect(env.getCachedCommand("ls") == null);
}
