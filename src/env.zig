const std = @import("std");
const posix = @import("posix.zig");
const JobTable = @import("jobs.zig").JobTable;

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

    loop_depth: u32,
    break_count: u32,
    continue_count: u32,
    should_return: bool,
    return_value: u8,
    should_exit: bool,
    exit_value: u8,
    job_table: ?*JobTable,

    pub const Variable = struct {
        value: []const u8,
        exported: bool,
        readonly: bool,
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

        pub fn toFlagString(self: *const ShellOptions) []const u8 {
            _ = self;
            return "";
        }
    };

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
            .loop_depth = 0,
            .break_count = 0,
            .continue_count = 0,
            .should_return = false,
            .return_value = 0,
            .should_exit = false,
            .exit_value = 0,
            .job_table = null,
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
            if (existing.readonly) return;
        }

        const owned_value = try self.alloc.dupe(u8, value);

        if (self.vars.getPtr(name)) |existing| {
            self.alloc.free(existing.value);
            existing.value = owned_value;
            if (exported) existing.exported = true;
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
    }

    pub fn unset(self: *Environment, name: []const u8) void {
        if (self.vars.get(name)) |v| {
            if (v.readonly) return;
        }
        if (self.vars.fetchRemove(name)) |kv| {
            self.alloc.free(kv.key);
            self.alloc.free(kv.value.value);
        }
        if (std.mem.eql(u8, name, "IFS")) {
            self.ifs = " \t\n";
        }
    }

    pub fn markExported(self: *Environment, name: []const u8) void {
        if (self.vars.getPtr(name)) |v| {
            v.exported = true;
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
    env.unset("FOO");
    try std.testing.expect(env.get("FOO") == null);
}
