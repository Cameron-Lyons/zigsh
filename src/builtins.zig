const std = @import("std");
const Environment = @import("env.zig").Environment;
const JobTable = @import("jobs.zig").JobTable;
const LineEditor = @import("line_editor.zig").LineEditor;
const signals = @import("signals.zig");
const posix = @import("posix.zig");
const types = @import("types.zig");
const libc = std.c;

pub const BuiltinFn = *const fn (args: []const []const u8, env: *Environment) u8;

pub const builtins = std.StaticStringMap(BuiltinFn).initComptime(.{
    .{ ":", &builtinColon },
    .{ "true", &builtinTrue },
    .{ "false", &builtinFalse },
    .{ "exit", &builtinExit },
    .{ "cd", &builtinCd },
    .{ "pwd", &builtinPwd },
    .{ "export", &builtinExport },
    .{ "unset", &builtinUnset },
    .{ "set", &builtinSet },
    .{ "shift", &builtinShift },
    .{ "return", &builtinReturn },
    .{ "break", &builtinBreak },
    .{ "continue", &builtinContinue },
    .{ "echo", &builtinEcho },
    .{ "test", &builtinTest },
    .{ "[", &builtinTest },
    .{ "jobs", &builtinJobs },
    .{ "wait", &builtinWait },
    .{ "kill", &builtinKill },
    .{ "trap", &builtinTrap },
    .{ "readonly", &builtinReadonly },
    .{ "read", &builtinRead },
    .{ "umask", &builtinUmask },
    .{ "type", &builtinType },
    .{ "getopts", &builtinGetopts },
    .{ "fg", &builtinFg },
    .{ "bg", &builtinBg },
    .{ "alias", &builtinAlias },
    .{ "unalias", &builtinUnalias },
    .{ "hash", &builtinHash },
    .{ "printf", &builtinPrintf },
    .{ "fc", &builtinFc },
    .{ "times", &builtinTimes },
    .{ "ulimit", &builtinUlimit },
    .{ "history", &builtinHistory },
    .{ "typeset", &builtinDeclare },
    .{ "declare", &builtinDeclare },
    .{ "local", &builtinDeclare },
    .{ "chdir", &builtinCd },
    .{ "let", &builtinLet },
    .{ "shopt", &builtinShopt },
});

pub fn lookup(name: []const u8) ?BuiltinFn {
    return builtins.get(name);
}

fn builtinColon(_: []const []const u8, _: *Environment) u8 {
    return 0;
}

fn builtinTrue(_: []const []const u8, _: *Environment) u8 {
    return 0;
}

fn builtinFalse(_: []const []const u8, _: *Environment) u8 {
    return 1;
}

fn builtinExit(args: []const []const u8, env: *Environment) u8 {
    var code: u8 = env.last_exit_status;
    if (args.len > 1) {
        if (std.fmt.parseInt(i64, args[1], 10)) |n| {
            code = @truncate(@as(u64, @bitCast(n)));
        } else |_| {
            posix.writeAll(2, "exit: ");
            posix.writeAll(2, args[1]);
            posix.writeAll(2, ": numeric argument required\n");
            code = 2;
            env.should_exit = true;
            env.exit_value = code;
            return code;
        }
        if (args.len > 2) {
            posix.writeAll(2, "exit: too many arguments\n");
            return 2;
        }
    }
    env.should_exit = true;
    env.exit_value = code;
    return code;
}

fn builtinCd(args: []const []const u8, env: *Environment) u8 {
    var physical = false;
    var arg_start: usize = 1;

    while (arg_start < args.len) {
        if (std.mem.eql(u8, args[arg_start], "-L")) {
            physical = false;
            arg_start += 1;
        } else if (std.mem.eql(u8, args[arg_start], "-P")) {
            physical = true;
            arg_start += 1;
        } else if (std.mem.eql(u8, args[arg_start], "--")) {
            arg_start += 1;
            break;
        } else {
            break;
        }
    }

    const target = if (arg_start < args.len)
        args[arg_start]
    else
        env.get("HOME") orelse {
            posix.writeAll(2, "cd: HOME not set\n");
            return 1;
        };

    var old_buf: [4096]u8 = undefined;
    const old_pwd = posix.getcwd(&old_buf) catch null;

    const is_relative = target.len > 0 and target[0] != '/' and
        !(target.len >= 1 and target[0] == '.') and
        !std.mem.eql(u8, target, "-");

    var cdpath_hit = false;
    if (is_relative) {
        if (env.get("CDPATH")) |cdpath| {
            var cditer = std.mem.splitScalar(u8, cdpath, ':');
            while (cditer.next()) |dir| {
                var try_buf: [4096]u8 = undefined;
                const try_path = std.fmt.bufPrint(&try_buf, "{s}/{s}", .{ dir, target }) catch continue;
                if (posix.chdir(try_path)) {
                    cdpath_hit = true;
                    break;
                } else |_| {}
            }
        }
    }

    if (!cdpath_hit) {
        if (std.mem.eql(u8, target, "-")) {
            const oldpwd = env.get("OLDPWD") orelse {
                posix.writeAll(2, "cd: OLDPWD not set\n");
                return 1;
            };
            posix.chdir(oldpwd) catch {
                posix.writeAll(2, "cd: ");
                posix.writeAll(2, oldpwd);
                posix.writeAll(2, ": No such file or directory\n");
                return 1;
            };
            var cd_dash_buf: [4096]u8 = undefined;
            const cd_dash_pwd = posix.getcwd(&cd_dash_buf) catch null;
            if (cd_dash_pwd) |p| {
                posix.writeAll(1, p);
                posix.writeAll(1, "\n");
            }
            cdpath_hit = true;
        } else {
            posix.chdir(target) catch {
                posix.writeAll(2, "cd: ");
                posix.writeAll(2, target);
                posix.writeAll(2, ": No such file or directory\n");
                return 1;
            };
        }
    }

    if (old_pwd) |pwd| {
        env.set("OLDPWD", pwd, true) catch {};
    }

    if (physical) {
        var new_buf: [4096]u8 = undefined;
        const cwd = posix.getcwd(&new_buf) catch null;
        if (cwd) |cwd_str| {
            const cwd_z = std.posix.toPosixPath(cwd_str) catch {
                env.set("PWD", cwd_str, true) catch {};
                return 0;
            };
            var real_buf: [4096]u8 = undefined;
            if (posix.realpath(&cwd_z, &real_buf)) |resolved| {
                env.set("PWD", resolved, true) catch {};
            } else {
                env.set("PWD", cwd_str, true) catch {};
            }
        }
    } else {
        var new_buf: [4096]u8 = undefined;
        const new_pwd = posix.getcwd(&new_buf) catch null;
        if (new_pwd) |pwd| {
            env.set("PWD", pwd, true) catch {};
            if (cdpath_hit and is_relative) {
                posix.writeAll(1, pwd);
                posix.writeAll(1, "\n");
            }
        }
    }

    return 0;
}

fn builtinPwd(args: []const []const u8, env: *Environment) u8 {
    var physical = false;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-L")) {
            physical = false;
        } else if (std.mem.eql(u8, args[i], "-P")) {
            physical = true;
        } else break;
    }

    if (!physical) {
        if (env.get("PWD")) |pwd| {
            if (pwd.len > 0 and pwd[0] == '/') {
                posix.writeAll(1, pwd);
                posix.writeAll(1, "\n");
                return 0;
            }
        }
    }

    var buf: [4096]u8 = undefined;
    const cwd = posix.getcwd(&buf) catch {
        posix.writeAll(2, "pwd: error getting current directory\n");
        return 1;
    };
    posix.writeAll(1, cwd);
    posix.writeAll(1, "\n");
    return 0;
}

fn builtinExport(args: []const []const u8, env: *Environment) u8 {
    if (args.len < 2 or (args.len == 2 and std.mem.eql(u8, args[1], "-p"))) {
        var it = env.vars.iterator();
        while (it.next()) |entry| {
            if (!entry.value_ptr.exported) continue;
            posix.writeAll(1, "export ");
            posix.writeAll(1, entry.key_ptr.*);
            posix.writeAll(1, "=\"");
            posix.writeAll(1, entry.value_ptr.value);
            posix.writeAll(1, "\"\n");
        }
        return 0;
    }

    const start_idx: usize = if (args.len > 1 and std.mem.eql(u8, args[1], "-p")) 2 else 1;
    for (args[start_idx..]) |arg| {
        if (std.mem.indexOfScalar(u8, arg, '=')) |eq| {
            const is_append = eq > 0 and arg[eq - 1] == '+';
            const name = if (is_append) arg[0 .. eq - 1] else arg[0..eq];
            if (!isValidVarName(name)) {
                posix.writeAll(2, "export: `");
                posix.writeAll(2, arg);
                posix.writeAll(2, "': not a valid identifier\n");
                env.should_exit = true;
                env.exit_value = 2;
                return 2;
            }
            var value = arg[eq + 1 ..];
            if (is_append) {
                const existing = env.get(name) orelse "";
                value = std.fmt.allocPrint(env.alloc, "{s}{s}", .{ existing, value }) catch value;
            }
            env.set(name, value, true) catch return 1;
        } else {
            if (!isValidVarName(arg)) {
                posix.writeAll(2, "export: `");
                posix.writeAll(2, arg);
                posix.writeAll(2, "': not a valid identifier\n");
                env.should_exit = true;
                env.exit_value = 2;
                return 2;
            }
            env.markExported(arg);
        }
    }
    return 0;
}

fn builtinUnset(args: []const []const u8, env: *Environment) u8 {
    var unset_func = false;
    var start: usize = 1;
    while (start < args.len) {
        if (std.mem.eql(u8, args[start], "-v")) {
            unset_func = false;
            start += 1;
        } else if (std.mem.eql(u8, args[start], "-f")) {
            unset_func = true;
            start += 1;
        } else {
            break;
        }
    }
    var status: u8 = 0;
    for (args[start..]) |name| {
        if (unset_func) {
            _ = env.unsetFunction(name);
        } else {
            if (!isValidVarName(name)) {
                posix.writeAll(2, "zigsh: unset: `");
                posix.writeAll(2, name);
                posix.writeAll(2, "': not a valid identifier\n");
                status = 2;
                continue;
            }
            if (env.vars.get(name) != null) {
                if (env.unset(name) == .readonly) {
                    posix.writeAll(2, "zigsh: unset: ");
                    posix.writeAll(2, name);
                    posix.writeAll(2, ": readonly variable\n");
                    env.should_exit = true;
                    env.exit_value = 2;
                    return 2;
                }
            } else {
                _ = env.unsetFunction(name);
            }
        }
    }
    return status;
}

fn isValidVarName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (name[0] != '_' and !std.ascii.isAlphabetic(name[0])) return false;
    for (name[1..]) |ch| {
        if (ch != '_' and !std.ascii.isAlphanumeric(ch)) return false;
    }
    return true;
}

fn isValidVarRef(name: []const u8) bool {
    if (std.mem.indexOfScalar(u8, name, '[')) |bracket| {
        if (name.len == 0 or name[name.len - 1] != ']') return false;
        return isValidVarName(name[0..bracket]);
    }
    return isValidVarName(name);
}

fn setWriteValue(value: []const u8) void {
    var has_special = false;
    for (value) |ch| {
        switch (ch) {
            '\n', '\r', '\t', 0x01...0x08, 0x0b, 0x0c, 0x0e...0x1f, 0x7f...0xff => {
                has_special = true;
            },
            else => {},
        }
    }
    if (has_special) {
        posix.writeAll(1, "$'");
        for (value) |ch| {
            switch (ch) {
                '\'' => posix.writeAll(1, "\\'"),
                '\\' => posix.writeAll(1, "\\\\"),
                '\n' => posix.writeAll(1, "\\n"),
                '\r' => posix.writeAll(1, "\\r"),
                '\t' => posix.writeAll(1, "\\t"),
                0x07 => posix.writeAll(1, "\\a"),
                0x08 => posix.writeAll(1, "\\b"),
                0x1b => posix.writeAll(1, "\\E"),
                else => {
                    if (ch < 0x20 or ch == 0x7f) {
                        var hex_buf: [8]u8 = undefined;
                        const hex = std.fmt.bufPrint(&hex_buf, "\\u{x:0>4}", .{ch}) catch return;
                        posix.writeAll(1, hex);
                    } else if (ch >= 0x80) {
                        var hex_buf: [8]u8 = undefined;
                        const hex = std.fmt.bufPrint(&hex_buf, "\\x{x:0>2}", .{ch}) catch return;
                        posix.writeAll(1, hex);
                    } else {
                        const buf = [1]u8{ch};
                        posix.writeAll(1, &buf);
                    }
                },
            }
        }
        posix.writeAll(1, "'");
    } else {
        posix.writeAll(1, "'");
        for (value) |ch| {
            if (ch == '\'') {
                posix.writeAll(1, "'\\''");
            } else {
                const buf = [1]u8{ch};
                posix.writeAll(1, &buf);
            }
        }
        posix.writeAll(1, "'");
    }
}

fn builtinSet(args: []const []const u8, env: *Environment) u8 {
    if (args.len < 2) {
        var keys: std.ArrayListUnmanaged([]const u8) = .empty;
        var it = env.vars.iterator();
        while (it.next()) |entry| {
            keys.append(env.alloc, entry.key_ptr.*) catch continue;
        }
        std.mem.sort([]const u8, keys.items, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.lessThan);
        for (keys.items) |key| {
            if (env.vars.get(key)) |entry| {
                posix.writeAll(1, key);
                posix.writeAll(1, "=");
                setWriteValue(entry.value);
                posix.writeAll(1, "\n");
            }
        }
        return 0;
    }

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--")) {
            i += 1;
            env.positional_params = args[i..];
            env.set("OPTIND", "1", false) catch {};
            env.set("OPTPOS", "0", false) catch {};
            return 0;
        }
        if (std.mem.eql(u8, arg, "-")) {
            env.options.xtrace = false;
            env.options.verbose = false;
            i += 1;
            if (i <= args.len) {
                env.positional_params = args[i..];
                env.set("OPTIND", "1", false) catch {};
                env.set("OPTPOS", "0", false) catch {};
            }
            return 0;
        }
        if (std.mem.eql(u8, arg, "+")) {
            continue;
        }
        if (arg.len < 2 or (arg[0] != '-' and arg[0] != '+')) break;
        const enable = arg[0] == '-';

        if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "+o")) {
            if (i + 1 < args.len and args[i + 1].len > 0 and args[i + 1][0] != '-' and args[i + 1][0] != '+') {
                i += 1;
                if (!setOptionByName(&env.options, args[i], enable)) return 2;
            } else if (enable) {
                printOptions(&env.options);
            } else {
                printOptionsReinput(&env.options);
            }
            continue;
        }

        for (arg[1..]) |opt_c| {
            switch (opt_c) {
                'e' => env.options.errexit = enable,
                'u' => env.options.nounset = enable,
                'x' => env.options.xtrace = enable,
                'f' => env.options.noglob = enable,
                'n' => env.options.noexec = enable,
                'a' => env.options.allexport = enable,
                'v' => env.options.verbose = enable,
                'C' => env.options.noclobber = enable,
                'm' => env.options.monitor = enable,
                'o' => {
                    if (enable) printOptions(&env.options);
                },
                else => {},
            }
        }
    }

    if (i < args.len) {
        env.positional_params = args[i..];
        env.set("OPTIND", "1", false) catch {};
        env.set("OPTPOS", "0", false) catch {};
    }
    return 0;
}

fn setOptionByName(options: *Environment.ShellOptions, name: []const u8, enable: bool) bool {
    if (std.mem.eql(u8, name, "errexit")) { options.errexit = enable; }
    else if (std.mem.eql(u8, name, "nounset")) { options.nounset = enable; }
    else if (std.mem.eql(u8, name, "xtrace")) { options.xtrace = enable; }
    else if (std.mem.eql(u8, name, "noglob")) { options.noglob = enable; }
    else if (std.mem.eql(u8, name, "noexec")) { options.noexec = enable; }
    else if (std.mem.eql(u8, name, "allexport")) { options.allexport = enable; }
    else if (std.mem.eql(u8, name, "monitor")) { options.monitor = enable; }
    else if (std.mem.eql(u8, name, "noclobber")) { options.noclobber = enable; }
    else if (std.mem.eql(u8, name, "verbose")) { options.verbose = enable; }
    else if (std.mem.eql(u8, name, "pipefail")) { options.pipefail = enable; }
    else if (std.mem.eql(u8, name, "history")) { options.history = enable; }
    else if (std.mem.eql(u8, name, "posix") or std.mem.eql(u8, name, "interactive") or std.mem.eql(u8, name, "hashall") or std.mem.eql(u8, name, "braceexpand") or std.mem.eql(u8, name, "vi") or std.mem.eql(u8, name, "emacs")) {}
    else {
        posix.writeAll(2, "set: unknown option: ");
        posix.writeAll(2, name);
        posix.writeAll(2, "\n");
        return false;
    }
    return true;
}

fn printOptions(options: *const Environment.ShellOptions) void {
    const entries = [_]struct { name: []const u8, value: bool }{
        .{ .name = "allexport", .value = options.allexport },
        .{ .name = "errexit", .value = options.errexit },
        .{ .name = "monitor", .value = options.monitor },
        .{ .name = "noclobber", .value = options.noclobber },
        .{ .name = "noexec", .value = options.noexec },
        .{ .name = "noglob", .value = options.noglob },
        .{ .name = "nounset", .value = options.nounset },
        .{ .name = "pipefail", .value = options.pipefail },
        .{ .name = "verbose", .value = options.verbose },
        .{ .name = "xtrace", .value = options.xtrace },
    };
    for (entries) |entry| {
        posix.writeAll(1, "set ");
        posix.writeAll(1, if (entry.value) "-o " else "+o ");
        posix.writeAll(1, entry.name);
        posix.writeAll(1, "\n");
    }
}

fn printOptionsReinput(options: *const Environment.ShellOptions) void {
    const entries = [_]struct { name: []const u8, value: bool }{
        .{ .name = "allexport", .value = options.allexport },
        .{ .name = "errexit", .value = options.errexit },
        .{ .name = "monitor", .value = options.monitor },
        .{ .name = "noclobber", .value = options.noclobber },
        .{ .name = "noexec", .value = options.noexec },
        .{ .name = "noglob", .value = options.noglob },
        .{ .name = "nounset", .value = options.nounset },
        .{ .name = "pipefail", .value = options.pipefail },
        .{ .name = "verbose", .value = options.verbose },
        .{ .name = "xtrace", .value = options.xtrace },
    };
    for (entries) |entry| {
        posix.writeAll(1, "set ");
        posix.writeAll(1, if (entry.value) "-o " else "+o ");
        posix.writeAll(1, entry.name);
        posix.writeAll(1, "\n");
    }
}

fn builtinShift(args: []const []const u8, env: *Environment) u8 {
    if (args.len > 2) {
        posix.writeAll(2, "shift: too many arguments\n");
        return 2;
    }
    var n: usize = 1;
    if (args.len > 1) {
        n = std.fmt.parseInt(usize, args[1], 10) catch {
            posix.writeAll(2, "shift: ");
            posix.writeAll(2, args[1]);
            posix.writeAll(2, ": numeric argument required\n");
            return 2;
        };
    }
    if (n > env.positional_params.len) return 2;
    env.positional_params = env.positional_params[n..];
    return 0;
}

fn builtinReturn(args: []const []const u8, env: *Environment) u8 {
    var val: u8 = env.last_exit_status;
    if (args.len > 1) {
        if (std.fmt.parseInt(i64, args[1], 10)) |n| {
            val = @truncate(@as(u64, @bitCast(n)));
        } else |_| {
            posix.writeAll(2, "return: ");
            posix.writeAll(2, args[1]);
            posix.writeAll(2, ": Illegal number\n");
            env.should_exit = true;
            env.exit_value = 2;
            return 2;
        }
    }
    env.should_return = true;
    env.return_value = val;
    return val;
}

fn builtinBreak(args: []const []const u8, env: *Environment) u8 {
    if (args.len > 2) {
        posix.writeAll(2, "break: too many arguments\n");
        return 1;
    }
    var n: u32 = 1;
    if (args.len > 1) {
        n = std.fmt.parseInt(u32, args[1], 10) catch {
            posix.writeAll(2, "break: ");
            posix.writeAll(2, args[1]);
            posix.writeAll(2, ": numeric argument required\n");
            return 1;
        };
        if (n == 0) {
            posix.writeAll(2, "break: loop count must be > 0\n");
            return 1;
        }
    }
    if (env.loop_depth == 0) return if (env.in_subshell) @as(u8, 1) else 0;
    env.break_count = n;
    return 0;
}

fn builtinContinue(args: []const []const u8, env: *Environment) u8 {
    if (args.len > 2) {
        posix.writeAll(2, "continue: too many arguments\n");
        if (!env.options.interactive) {
            env.should_exit = true;
            env.exit_value = 2;
        }
        return 2;
    }
    var n: u32 = 1;
    if (args.len > 1) {
        n = std.fmt.parseInt(u32, args[1], 10) catch {
            posix.writeAll(2, "continue: ");
            posix.writeAll(2, args[1]);
            posix.writeAll(2, ": numeric argument required\n");
            return 1;
        };
        if (n == 0) {
            posix.writeAll(2, "continue: loop count must be > 0\n");
            return 1;
        }
    }
    if (env.loop_depth == 0) return if (env.in_subshell) @as(u8, 1) else 0;
    env.continue_count = n;
    return 0;
}

fn builtinEcho(args: []const []const u8, _: *Environment) u8 {
    var i: usize = 1;
    var no_newline = false;
    var interpret_escapes = false;

    while (i < args.len) {
        const arg = args[i];
        if (arg.len < 2 or arg[0] != '-') break;
        var valid = true;
        var has_n = false;
        var has_e = false;
        var has_big_e = false;
        for (arg[1..]) |ch| {
            switch (ch) {
                'n' => has_n = true,
                'e' => has_e = true,
                'E' => has_big_e = true,
                else => {
                    valid = false;
                    break;
                },
            }
        }
        if (!valid) break;
        if (has_n) no_newline = true;
        if (has_e) interpret_escapes = true;
        if (has_big_e) interpret_escapes = false;
        i += 1;
    }

    const first_arg = i;
    while (i < args.len) : (i += 1) {
        if (i > first_arg) posix.writeAll(1, " ");
        if (interpret_escapes) {
            if (echoEscape(args[i])) return 0;
        } else {
            posix.writeAll(1, args[i]);
        }
    }
    if (!no_newline) posix.writeAll(1, "\n");
    return 0;
}

fn echoEscape(s: []const u8) bool {
    var j: usize = 0;
    while (j < s.len) {
        if (s[j] == '\\' and j + 1 < s.len) {
            switch (s[j + 1]) {
                'a' => {
                    posix.writeAll(1, "\x07");
                    j += 2;
                },
                'b' => {
                    posix.writeAll(1, "\x08");
                    j += 2;
                },
                'c' => return true,
                'e', 'E' => {
                    posix.writeAll(1, "\x1b");
                    j += 2;
                },
                'f' => {
                    posix.writeAll(1, "\x0c");
                    j += 2;
                },
                'n' => {
                    posix.writeAll(1, "\n");
                    j += 2;
                },
                'r' => {
                    posix.writeAll(1, "\r");
                    j += 2;
                },
                't' => {
                    posix.writeAll(1, "\t");
                    j += 2;
                },
                'v' => {
                    posix.writeAll(1, "\x0b");
                    j += 2;
                },
                '\\' => {
                    posix.writeAll(1, "\\");
                    j += 2;
                },
                '0' => {
                    j += 2;
                    var val: u8 = 0;
                    var count: u8 = 0;
                    while (count < 3 and j < s.len and s[j] >= '0' and s[j] <= '7') {
                        val = val *% 8 +% (s[j] - '0');
                        j += 1;
                        count += 1;
                    }
                    const buf = [1]u8{val};
                    posix.writeAll(1, &buf);
                },
                'x' => {
                    j += 2;
                    var val: u8 = 0;
                    var count: u8 = 0;
                    while (count < 2 and j < s.len) {
                        const d = s[j];
                        if (d >= '0' and d <= '9') {
                            val = val *% 16 +% (d - '0');
                        } else if (d >= 'a' and d <= 'f') {
                            val = val *% 16 +% (d - 'a' + 10);
                        } else if (d >= 'A' and d <= 'F') {
                            val = val *% 16 +% (d - 'A' + 10);
                        } else break;
                        j += 1;
                        count += 1;
                    }
                    const buf = [1]u8{val};
                    posix.writeAll(1, &buf);
                },
                else => {
                    posix.writeAll(1, s[j .. j + 2]);
                    j += 2;
                },
            }
        } else {
            const start = j;
            j += 1;
            while (j < s.len and s[j] != '\\') j += 1;
            posix.writeAll(1, s[start..j]);
        }
    }
    return false;
}

fn builtinTest(args: []const []const u8, test_env: *Environment) u8 {
    const effective_args = if (args.len > 0 and std.mem.eql(u8, args[0], "[")) blk: {
        if (args.len < 2 or !std.mem.eql(u8, args[args.len - 1], "]")) {
            posix.writeAll(2, "[: missing ]\n");
            return 2;
        }
        break :blk args[1 .. args.len - 1];
    } else args[1..];

    return testEvaluate(effective_args, test_env);
}

fn testEvaluate(targs: []const []const u8, test_env: *Environment) u8 {
    if (targs.len == 0) return 1;

    if (targs.len == 1) {
        return if (targs[0].len > 0) 0 else 1;
    }

    if (targs.len == 2) {
        if (std.mem.eql(u8, targs[0], "!")) {
            return if (testEvaluate(targs[1..], test_env) == 0) 1 else 0;
        }
        return testUnary(targs[0], targs[1], test_env);
    }

    if (targs.len == 3) {
        if (std.mem.eql(u8, targs[0], "!")) {
            return if (testEvaluate(targs[1..], test_env) == 0) 1 else 0;
        }
        if (std.mem.eql(u8, targs[0], "(") and std.mem.eql(u8, targs[2], ")")) {
            return testEvaluate(targs[1..2], test_env);
        }
        if (std.mem.eql(u8, targs[1], "-a")) {
            const l: u8 = if (targs[0].len > 0) 0 else 1;
            const r: u8 = if (targs[2].len > 0) 0 else 1;
            return if (l == 0 and r == 0) 0 else 1;
        }
        if (std.mem.eql(u8, targs[1], "-o")) {
            const l: u8 = if (targs[0].len > 0) 0 else 1;
            const r: u8 = if (targs[2].len > 0) 0 else 1;
            return if (l == 0 or r == 0) 0 else 1;
        }
        return testBinary(targs[0], targs[1], targs[2]);
    }

    if (targs.len == 4 and std.mem.eql(u8, targs[0], "!")) {
        return if (testEvaluate(targs[1..], test_env) == 0) 1 else 0;
    }

    var pos: usize = 0;
    return testParseOr(targs, &pos, test_env);
}

fn testParseOr(targs: []const []const u8, pos: *usize, test_env: *Environment) u8 {
    var result = testParseAnd(targs, pos, test_env);
    while (pos.* < targs.len and std.mem.eql(u8, targs[pos.*], "-o")) {
        pos.* += 1;
        const right = testParseAnd(targs, pos, test_env);
        result = if (result == 0 or right == 0) 0 else 1;
    }
    return result;
}

fn testParseAnd(targs: []const []const u8, pos: *usize, test_env: *Environment) u8 {
    var result = testParsePrimary(targs, pos, test_env);
    while (pos.* < targs.len and std.mem.eql(u8, targs[pos.*], "-a")) {
        pos.* += 1;
        const right = testParsePrimary(targs, pos, test_env);
        result = if (result == 0 and right == 0) 0 else 1;
    }
    return result;
}

fn testParsePrimary(targs: []const []const u8, pos: *usize, test_env: *Environment) u8 {
    if (pos.* >= targs.len) return 1;

    if (std.mem.eql(u8, targs[pos.*], "!")) {
        pos.* += 1;
        return if (testParsePrimary(targs, pos, test_env) == 0) 1 else 0;
    }

    if (std.mem.eql(u8, targs[pos.*], "(")) {
        pos.* += 1;
        const result = testParseOr(targs, pos, test_env);
        if (pos.* < targs.len and std.mem.eql(u8, targs[pos.*], ")")) {
            pos.* += 1;
        }
        return result;
    }

    if (isTestUnaryOp(targs[pos.*]) and pos.* + 1 < targs.len) {
        const op = targs[pos.*];
        pos.* += 1;
        const operand = targs[pos.*];
        pos.* += 1;
        return testUnary(op, operand, test_env);
    }

    if (pos.* + 2 < targs.len and isTestBinaryOp(targs[pos.* + 1])) {
        const left = targs[pos.*];
        const op = targs[pos.* + 1];
        const right = targs[pos.* + 2];
        pos.* += 3;
        return testBinary(left, op, right);
    }

    const result: u8 = if (targs[pos.*].len > 0) 0 else 1;
    pos.* += 1;
    return result;
}

fn isTestUnaryOp(op: []const u8) bool {
    const ops = [_][]const u8{
        "-a", "-b", "-c", "-d", "-e", "-f", "-g", "-h", "-k", "-L", "-n", "-p",
        "-r", "-s", "-S", "-t", "-u", "-w", "-x", "-z",
        "-G", "-O", "-v", "-o",
    };
    for (ops) |o| {
        if (std.mem.eql(u8, op, o)) return true;
    }
    return false;
}

fn isTestBinaryOp(op: []const u8) bool {
    const ops = [_][]const u8{
        "=", "==", "!=", "<", ">", "-eq", "-ne", "-lt", "-le", "-gt", "-ge",
        "-nt", "-ot", "-ef",
    };
    for (ops) |o| {
        if (std.mem.eql(u8, op, o)) return true;
    }
    return false;
}

fn testUnary(op: []const u8, operand: []const u8, test_env: *Environment) u8 {
    if (std.mem.eql(u8, op, "-n")) return if (operand.len > 0) 0 else 1;
    if (std.mem.eql(u8, op, "-z")) return if (operand.len == 0) 0 else 1;

    if (std.mem.eql(u8, op, "-v")) {
        return if (test_env.get(operand) != null) 0 else 1;
    }
    if (std.mem.eql(u8, op, "-o")) {
        if (std.mem.eql(u8, operand, "errexit")) return if (test_env.options.errexit) 0 else 1;
        if (std.mem.eql(u8, operand, "nounset")) return if (test_env.options.nounset) 0 else 1;
        if (std.mem.eql(u8, operand, "xtrace")) return if (test_env.options.xtrace) 0 else 1;
        if (std.mem.eql(u8, operand, "verbose")) return if (test_env.options.verbose) 0 else 1;
        if (std.mem.eql(u8, operand, "noclobber")) return if (test_env.options.noclobber) 0 else 1;
        if (std.mem.eql(u8, operand, "noexec")) return if (test_env.options.noexec) 0 else 1;
        if (std.mem.eql(u8, operand, "noglob")) return if (test_env.options.noglob) 0 else 1;
        if (std.mem.eql(u8, operand, "allexport")) return if (test_env.options.allexport) 0 else 1;
        if (std.mem.eql(u8, operand, "monitor")) return if (test_env.options.monitor) 0 else 1;
        return 1;
    }

    if (std.mem.eql(u8, op, "-t")) {
        const fd_num = std.fmt.parseInt(posix.fd_t, operand, 10) catch return 2;
        return if (posix.isatty(fd_num)) 0 else 1;
    }

    const path_z = std.posix.toPosixPath(operand) catch return 1;

    if (std.mem.eql(u8, op, "-a") or std.mem.eql(u8, op, "-e")) {
        _ = posix.stat(&path_z) catch return 1;
        return 0;
    }
    if (std.mem.eql(u8, op, "-f")) {
        const st = posix.stat(&path_z) catch return 1;
        return if (st.mode & posix.S_IFMT == posix.S_IFREG) 0 else 1;
    }
    if (std.mem.eql(u8, op, "-d")) {
        const st = posix.stat(&path_z) catch return 1;
        return if (st.mode & posix.S_IFMT == posix.S_IFDIR) 0 else 1;
    }
    if (std.mem.eql(u8, op, "-b")) {
        const st = posix.stat(&path_z) catch return 1;
        return if (st.mode & posix.S_IFMT == posix.S_IFBLK) 0 else 1;
    }
    if (std.mem.eql(u8, op, "-c")) {
        const st = posix.stat(&path_z) catch return 1;
        return if (st.mode & posix.S_IFMT == posix.S_IFCHR) 0 else 1;
    }
    if (std.mem.eql(u8, op, "-p")) {
        const st = posix.stat(&path_z) catch return 1;
        return if (st.mode & posix.S_IFMT == posix.S_IFIFO) 0 else 1;
    }
    if (std.mem.eql(u8, op, "-h") or std.mem.eql(u8, op, "-L")) {
        const st = posix.lstat(&path_z) catch return 1;
        return if (st.mode & posix.S_IFMT == posix.S_IFLNK) 0 else 1;
    }
    if (std.mem.eql(u8, op, "-S")) {
        const st = posix.stat(&path_z) catch return 1;
        return if (st.mode & posix.S_IFMT == posix.S_IFSOCK) 0 else 1;
    }
    if (std.mem.eql(u8, op, "-g")) {
        const st = posix.stat(&path_z) catch return 1;
        return if (st.mode & posix.S_ISGID != 0) 0 else 1;
    }
    if (std.mem.eql(u8, op, "-u")) {
        const st = posix.stat(&path_z) catch return 1;
        return if (st.mode & posix.S_ISUID != 0) 0 else 1;
    }
    if (std.mem.eql(u8, op, "-r")) {
        return if (posix.access(&path_z, posix.R_OK)) 0 else 1;
    }
    if (std.mem.eql(u8, op, "-w")) {
        return if (posix.access(&path_z, posix.W_OK)) 0 else 1;
    }
    if (std.mem.eql(u8, op, "-x")) {
        return if (posix.access(&path_z, posix.X_OK)) 0 else 1;
    }
    if (std.mem.eql(u8, op, "-s")) {
        const st = posix.stat(&path_z) catch return 1;
        return if (st.size > 0) 0 else 1;
    }
    if (std.mem.eql(u8, op, "-k")) {
        const st = posix.stat(&path_z) catch return 1;
        return if (st.mode & posix.S_ISVTX != 0) 0 else 1;
    }
    if (std.mem.eql(u8, op, "-G")) {
        const st = posix.stat(&path_z) catch return 1;
        return if (st.gid == posix.getegid()) 0 else 1;
    }
    if (std.mem.eql(u8, op, "-O")) {
        const st = posix.stat(&path_z) catch return 1;
        return if (st.uid == posix.geteuid()) 0 else 1;
    }
    return 2;
}

fn testBinary(left: []const u8, op: []const u8, right: []const u8) u8 {
    if (std.mem.eql(u8, op, "=") or std.mem.eql(u8, op, "==")) {
        return if (std.mem.eql(u8, left, right)) 0 else 1;
    }
    if (std.mem.eql(u8, op, "!=")) {
        return if (!std.mem.eql(u8, left, right)) 0 else 1;
    }
    if (std.mem.eql(u8, op, "<")) {
        return if (std.mem.order(u8, left, right) == .lt) 0 else 1;
    }
    if (std.mem.eql(u8, op, ">")) {
        return if (std.mem.order(u8, left, right) == .gt) 0 else 1;
    }

    if (std.mem.eql(u8, op, "-nt") or std.mem.eql(u8, op, "-ot") or std.mem.eql(u8, op, "-ef")) {
        const left_z = std.posix.toPosixPath(left) catch return 1;
        const right_z = std.posix.toPosixPath(right) catch return 1;
        const left_st = posix.stat(&left_z) catch return 1;
        const right_st = posix.stat(&right_z) catch return 1;

        if (std.mem.eql(u8, op, "-nt")) {
            if (left_st.mtime_sec != right_st.mtime_sec)
                return if (left_st.mtime_sec > right_st.mtime_sec) 0 else 1;
            return if (left_st.mtime_nsec > right_st.mtime_nsec) 0 else 1;
        }
        if (std.mem.eql(u8, op, "-ot")) {
            if (left_st.mtime_sec != right_st.mtime_sec)
                return if (left_st.mtime_sec < right_st.mtime_sec) 0 else 1;
            return if (left_st.mtime_nsec < right_st.mtime_nsec) 0 else 1;
        }
        if (std.mem.eql(u8, op, "-ef")) {
            return if (left_st.dev_major == right_st.dev_major and
                left_st.dev_minor == right_st.dev_minor and
                left_st.ino == right_st.ino) 0 else 1;
        }
    }

    const lhs = std.fmt.parseInt(i64, left, 10) catch return 2;
    const rhs = std.fmt.parseInt(i64, right, 10) catch return 2;

    if (std.mem.eql(u8, op, "-eq")) return if (lhs == rhs) 0 else 1;
    if (std.mem.eql(u8, op, "-ne")) return if (lhs != rhs) 0 else 1;
    if (std.mem.eql(u8, op, "-lt")) return if (lhs < rhs) 0 else 1;
    if (std.mem.eql(u8, op, "-le")) return if (lhs <= rhs) 0 else 1;
    if (std.mem.eql(u8, op, "-gt")) return if (lhs > rhs) 0 else 1;
    if (std.mem.eql(u8, op, "-ge")) return if (lhs >= rhs) 0 else 1;
    return 2;
}

fn builtinJobs(args: []const []const u8, env: *Environment) u8 {
    const jt = env.job_table orelse return 1;
    var show_long = false;
    var pids_only = false;
    for (args[1..]) |arg| {
        if (arg.len > 1 and arg[0] == '-') {
            for (arg[1..]) |flag_c| {
                switch (flag_c) {
                    'l' => show_long = true,
                    'p' => pids_only = true,
                    else => {},
                }
            }
        }
    }

    for (&jt.jobs.*) |*slot| {
        if (slot.*) |*job| {
            if (pids_only) {
                var pid_buf: [16]u8 = undefined;
                const pid_str = std.fmt.bufPrint(&pid_buf, "{d}\n", .{job.pid}) catch "";
                posix.writeAll(1, pid_str);
                continue;
            }
            var buf: [16]u8 = undefined;
            const id_str = std.fmt.bufPrint(&buf, "[{d}]", .{job.id}) catch "";
            posix.writeAll(1, id_str);
            if (show_long) {
                var pid_buf: [16]u8 = undefined;
                const pid_str = std.fmt.bufPrint(&pid_buf, " {d}", .{job.pid}) catch "";
                posix.writeAll(1, pid_str);
            }
            const state_str = switch (job.state) {
                .running => "  Running\t\t",
                .stopped => "  Stopped\t\t",
                .done => "  Done\t\t",
            };
            posix.writeAll(1, state_str);
            posix.writeAll(1, job.command);
            posix.writeAll(1, "\n");
        }
    }
    return 0;
}

fn builtinWait(args: []const []const u8, env: *Environment) u8 {
    if (args.len > 1 and std.mem.eql(u8, args[1], "-n")) {
        if (args.len == 2) {
            const result = posix.waitpid(-1, 0);
            if (result.pid <= 0) return 127;
            return posix.statusFromWait(result.status);
        }
        var has_error = false;
        var pids: [64]posix.pid_t = undefined;
        var npids: usize = 0;
        for (args[2..]) |arg| {
            const pid = std.fmt.parseInt(posix.pid_t, arg, 10) catch {
                posix.writeAll(2, "wait: `");
                posix.writeAll(2, arg);
                posix.writeAll(2, "': not a pid or valid job spec\n");
                has_error = true;
                continue;
            };
            if (npids < 64) {
                pids[npids] = pid;
                npids += 1;
            }
        }
        if (has_error) return 127;
        for (pids[0..npids]) |pid| {
            const result = posix.waitpid(pid, posix.WNOHANG);
            if (result.pid > 0) return posix.statusFromWait(result.status);
        }
        const result = posix.waitpid(pids[0], 0);
        if (result.pid <= 0) return 127;
        return posix.statusFromWait(result.status);
    }
    if (args.len > 1) {
        var status: u8 = 0;
        for (args[1..]) |arg| {
            if (arg.len > 0 and arg[0] == '%') {
                const jt = env.job_table orelse {
                    posix.writeAll(2, "wait: no job control\n");
                    status = 2;
                    continue;
                };
                const job = jt.parseJobSpec(arg) orelse {
                    posix.writeAll(2, "wait: no such job: ");
                    posix.writeAll(2, arg);
                    posix.writeAll(2, "\n");
                    status = 2;
                    continue;
                };
                const result = posix.waitpid(job.pid, 0);
                if (result.pid <= 0) {
                    status = 127;
                } else {
                    status = posix.statusFromWait(result.status);
                }
            } else {
                const pid = std.fmt.parseInt(posix.pid_t, arg, 10) catch {
                    posix.writeAll(2, "zigsh: wait: `");
                    posix.writeAll(2, arg);
                    posix.writeAll(2, "': not a pid or valid job spec\n");
                    status = 2;
                    continue;
                };
                const result = posix.waitpid(pid, 0);
                if (result.pid <= 0) {
                    status = 127;
                } else {
                    status = posix.statusFromWait(result.status);
                }
            }
        }
        return status;
    }
    while (true) {
        const result = posix.waitpid(-1, 0);
        if (result.pid <= 0) break;
    }
    return 0;
}

fn builtinKill(args: []const []const u8, env: *Environment) u8 {
    if (args.len < 2) {
        posix.writeAll(2, "kill: usage: kill [-s signal | -signal] pid ...\n");
        return 2;
    }

    var sig: u6 = signals.SIGTERM;
    var start: usize = 1;

    if (std.mem.eql(u8, args[1], "-l") or std.mem.eql(u8, args[1], "-L")) {
        if (args.len > 2) {
            var status: u8 = 0;
            for (args[2..]) |arg| {
                if (std.fmt.parseInt(u32, arg, 10)) |num| {
                    var exit_num = num;
                    if (exit_num == 128 or exit_num > 256) {
                        posix.writeAll(2, "kill: invalid signal number: ");
                        posix.writeAll(2, arg);
                        posix.writeAll(2, "\n");
                        status = 1;
                        continue;
                    }
                    if (exit_num > 128) exit_num -= 128;
                    if (signals.sigNameFromNum(@intCast(exit_num & 0x3f))) |name| {
                        posix.writeAll(1, name);
                        posix.writeAll(1, "\n");
                    } else {
                        posix.writeAll(2, "kill: invalid signal number: ");
                        posix.writeAll(2, arg);
                        posix.writeAll(2, "\n");
                        status = 1;
                    }
                } else |_| {
                    if (sigFromName(arg)) |n| {
                        var buf: [8]u8 = undefined;
                        const s = std.fmt.bufPrint(&buf, "{d}\n", .{n}) catch continue;
                        posix.writeAll(1, s);
                    } else {
                        posix.writeAll(2, "kill: invalid signal: ");
                        posix.writeAll(2, arg);
                        posix.writeAll(2, "\n");
                        status = 1;
                    }
                }
            }
            return status;
        }
        var i: u6 = 1;
        while (i < 32) : (i += 1) {
            if (signals.sigNameFromNum(i)) |name| {
                var buf: [8]u8 = undefined;
                const num_s = std.fmt.bufPrint(&buf, "{d:>2}) ", .{i}) catch continue;
                posix.writeAll(1, num_s);
                posix.writeAll(1, "SIG");
                posix.writeAll(1, name);
                posix.writeAll(1, "\n");
            }
        }
        return 0;
    }

    if (std.mem.eql(u8, args[1], "-n")) {
        if (args.len < 3) {
            posix.writeAll(2, "kill: -n requires a signal number\n");
            return 2;
        }
        sig = std.fmt.parseInt(u6, args[2], 10) catch {
            posix.writeAll(2, "kill: invalid signal number: ");
            posix.writeAll(2, args[2]);
            posix.writeAll(2, "\n");
            return 1;
        };
        start = 3;
    } else if (std.mem.eql(u8, args[1], "-s")) {
        if (args.len < 3) {
            posix.writeAll(2, "kill: -s requires a signal name\n");
            return 2;
        }
        sig = sigFromName(args[2]) orelse {
            posix.writeAll(2, "kill: invalid signal: ");
            posix.writeAll(2, args[2]);
            posix.writeAll(2, "\n");
            return 2;
        };
        start = 3;
    } else if (args[1].len > 1 and args[1][0] == '-') {
        const sig_str = args[1][1..];
        if (std.fmt.parseInt(u6, sig_str, 10)) |n| {
            sig = n;
            start = 2;
        } else |_| {
            sig = sigFromName(sig_str) orelse {
                posix.writeAll(2, "kill: invalid signal: ");
                posix.writeAll(2, sig_str);
                posix.writeAll(2, "\n");
                return 1;
            };
            start = 2;
        }
    }

    _ = env;
    for (args[start..]) |arg| {
        const pid = std.fmt.parseInt(posix.pid_t, arg, 10) catch {
            posix.writeAll(2, "kill: invalid pid: ");
            posix.writeAll(2, arg);
            posix.writeAll(2, "\n");
            continue;
        };
        signals.sendSignal(pid, sig) catch {
            posix.writeAll(2, "kill: failed to send signal\n");
        };
    }
    return 0;
}

fn builtinTrap(args: []const []const u8, env: *Environment) u8 {
    var operand_start: usize = 1;
    var print_mode = false;
    var list_mode = false;

    while (operand_start < args.len) {
        const arg = args[operand_start];
        if (arg.len == 0 or arg[0] != '-' or arg.len == 1) break;
        if (std.mem.eql(u8, arg, "--")) {
            operand_start += 1;
            break;
        }
        if (std.mem.eql(u8, arg, "-p")) {
            print_mode = true;
            operand_start += 1;
        } else if (std.mem.eql(u8, arg, "-l")) {
            list_mode = true;
            operand_start += 1;
        } else {
            posix.writeAll(2, "trap: invalid option: ");
            posix.writeAll(2, arg);
            posix.writeAll(2, "\n");
            return 2;
        }
    }

    if (list_mode) {
        posix.writeAll(1, "EXIT HUP INT QUIT TERM USR1 USR2 ERR\n");
        return 0;
    }

    const operands = args[operand_start..];

    if (print_mode) {
        if (operands.len == 0) {
            printTraps();
        } else {
            for (operands) |sig_name| {
                printSpecificTrap(sig_name);
            }
        }
        return 0;
    }

    if (operands.len == 0) {
        printTraps();
        return 0;
    }

    if (operands.len == 1) {
        if (!trapResetSignal(operands[0], env)) {
            posix.writeAll(2, "trap: invalid signal: ");
            posix.writeAll(2, operands[0]);
            posix.writeAll(2, "\n");
            return 1;
        }
        return 0;
    }

    if (isUnsignedInt(operands[0])) {
        var status: u8 = 0;
        for (operands) |sig_name| {
            if (!trapResetSignal(sig_name, env)) {
                posix.writeAll(2, "trap: invalid signal: ");
                posix.writeAll(2, sig_name);
                posix.writeAll(2, "\n");
                status = 1;
            }
        }
        return status;
    }

    const action_src = operands[0];
    const conditions = operands[1..];

    if (std.mem.eql(u8, action_src, "-")) {
        var status: u8 = 0;
        for (conditions) |sig_name| {
            if (!trapResetSignal(sig_name, env)) {
                posix.writeAll(2, "trap: invalid signal: ");
                posix.writeAll(2, sig_name);
                posix.writeAll(2, "\n");
                status = 1;
            }
        }
        return status;
    }

    const action = env.alloc.dupe(u8, action_src) catch return 1;
    var status: u8 = 0;

    if (action.len > 0) {
        var arena = std.heap.ArenaAllocator.init(env.alloc);
        defer arena.deinit();
        var test_lexer = @import("lexer.zig").Lexer.init(action);
        var test_parser = @import("parser.zig").Parser.init(arena.allocator(), &test_lexer) catch {
            status = 1;
            env.alloc.free(action);
            return status;
        };
        _ = test_parser.parseProgram() catch {
            posix.writeAll(2, "trap: invalid code: ");
            posix.writeAll(2, action);
            posix.writeAll(2, "\n");
            status = 1;
        };
        if (status != 0) {
            env.alloc.free(action);
            return status;
        }
    }

    var any_set = false;
    for (conditions) |sig_name| {
        if (!trapSetAction(sig_name, action, env)) {
            posix.writeAll(2, "trap: invalid signal: ");
            posix.writeAll(2, sig_name);
            posix.writeAll(2, "\n");
            status = 1;
        } else {
            any_set = true;
        }
    }
    if (!any_set) {
        env.alloc.free(action);
    }
    return status;
}

fn isUnsignedInt(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |ch| {
        if (ch < '0' or ch > '9') return false;
    }
    return true;
}

fn trapResetSignal(sig_name: []const u8, env: *Environment) bool {
    if (std.mem.eql(u8, sig_name, "EXIT") or std.mem.eql(u8, sig_name, "0")) {
        if (signals.getExitTrap()) |old| env.alloc.free(old);
        signals.setExitTrap(null);
        return true;
    }
    if (std.mem.eql(u8, sig_name, "ERR")) {
        if (signals.getErrTrap()) |old| env.alloc.free(old);
        signals.setErrTrap(null);
        return true;
    }
    const sig = sigFromName(sig_name) orelse return false;
    if (signals.trap_handlers[@intCast(sig)]) |old| env.alloc.free(old);
    signals.setTrap(sig, null);
    return true;
}

fn trapSetAction(sig_name: []const u8, action: ?[]const u8, env: *Environment) bool {
    if (std.mem.eql(u8, sig_name, "EXIT") or std.mem.eql(u8, sig_name, "0")) {
        if (signals.getExitTrap()) |old| env.alloc.free(old);
        signals.setExitTrap(action);
        return true;
    }
    if (std.mem.eql(u8, sig_name, "ERR")) {
        if (signals.getErrTrap()) |old| env.alloc.free(old);
        signals.setErrTrap(action);
        return true;
    }
    const sig = sigFromName(sig_name) orelse return false;
    if (signals.trap_handlers[@intCast(sig)]) |old| env.alloc.free(old);
    signals.setTrap(sig, action);
    return true;
}

fn builtinReadonly(args: []const []const u8, env: *Environment) u8 {
    if (args.len < 2 or (args.len == 2 and std.mem.eql(u8, args[1], "-p"))) {
        var it = env.vars.iterator();
        while (it.next()) |entry| {
            if (!entry.value_ptr.readonly) continue;
            posix.writeAll(1, "readonly ");
            posix.writeAll(1, entry.key_ptr.*);
            posix.writeAll(1, "=\"");
            posix.writeAll(1, entry.value_ptr.value);
            posix.writeAll(1, "\"\n");
        }
        return 0;
    }

    const start_ro: usize = if (args.len > 1 and std.mem.eql(u8, args[1], "-p")) 2 else 1;
    for (args[start_ro..]) |arg| {
        if (std.mem.indexOfScalar(u8, arg, '=')) |eq| {
            const is_append = eq > 0 and arg[eq - 1] == '+';
            const name = if (is_append) arg[0 .. eq - 1] else arg[0..eq];
            var value = arg[eq + 1 ..];
            if (is_append) {
                const existing = env.get(name) orelse "";
                value = std.fmt.allocPrint(env.alloc, "{s}{s}", .{ existing, value }) catch value;
            }
            env.set(name, value, false) catch return 1;
            env.markReadonly(name);
        } else {
            if (!isValidVarName(arg)) {
                posix.writeAll(2, "readonly: `");
                posix.writeAll(2, arg);
                posix.writeAll(2, "': not a valid identifier\n");
                env.should_exit = true;
                env.exit_value = 2;
                return 2;
            }
            env.markReadonly(arg);
        }
    }
    return 0;
}

fn isIfsWhitespace(ch: u8, ifs: []const u8) bool {
    for (ifs) |c| {
        if (c == ch and (ch == ' ' or ch == '\t' or ch == '\n')) return true;
    }
    return false;
}

fn isIfsNonWhitespace(ch: u8, ifs: []const u8) bool {
    for (ifs) |c| {
        if (c == ch and ch != ' ' and ch != '\t' and ch != '\n') return true;
    }
    return false;
}

fn isIfsChar(ch: u8, ifs: []const u8) bool {
    for (ifs) |c| {
        if (c == ch) return true;
    }
    return false;
}

fn builtinRead(args: []const []const u8, env: *Environment) u8 {
    var raw = false;
    var prompt: ?[]const u8 = null;
    var delim: u8 = '\n';
    var use_nul_delim = false;
    var nchars: ?usize = null;
    var nchars_exact = false;
    var read_fd: types.Fd = types.STDIN;
    var arg_start: usize = 1;

    while (arg_start < args.len) {
        const arg = args[arg_start];
        if (arg.len == 0 or arg[0] != '-' or arg.len == 1) break;
        if (std.mem.eql(u8, arg, "--")) {
            arg_start += 1;
            break;
        }
        var j: usize = 1;
        while (j < arg.len) : (j += 1) {
            switch (arg[j]) {
                'r' => raw = true,
                's' => {},
                'p' => {
                    if (j + 1 < arg.len) {
                        prompt = arg[j + 1 ..];
                    } else if (arg_start + 1 < args.len) {
                        arg_start += 1;
                        prompt = args[arg_start];
                    }
                    break;
                },
                'd' => {
                    if (j + 1 < arg.len) {
                        delim = arg[j + 1];
                    } else if (arg_start + 1 < args.len) {
                        arg_start += 1;
                        if (args[arg_start].len > 0) {
                            delim = args[arg_start][0];
                        } else {
                            delim = 0;
                            use_nul_delim = true;
                        }
                    }
                    break;
                },
                'n', 'N' => {
                    nchars_exact = arg[j] == 'N';
                    if (j + 1 < arg.len) {
                        nchars = std.fmt.parseInt(usize, arg[j + 1 ..], 10) catch {
                            posix.writeAll(2, "read: invalid count\n");
                            return 2;
                        };
                    } else if (arg_start + 1 < args.len) {
                        arg_start += 1;
                        nchars = std.fmt.parseInt(usize, args[arg_start], 10) catch {
                            posix.writeAll(2, "read: invalid count\n");
                            return 2;
                        };
                    }
                    break;
                },
                't' => {
                    var timeout_str: ?[]const u8 = null;
                    if (j + 1 < arg.len) {
                        timeout_str = arg[j + 1 ..];
                    } else if (arg_start + 1 < args.len) {
                        arg_start += 1;
                        timeout_str = args[arg_start];
                    }
                    if (timeout_str) |ts| {
                        const tval = std.fmt.parseFloat(f64, ts) catch 0;
                        if (tval < 0) return 2;
                        if (tval == 0) {
                            var poll_fds = [_]std.posix.pollfd{.{
                                .fd = read_fd,
                                .events = 1,
                                .revents = 0,
                            }};
                            const poll_result = std.posix.poll(&poll_fds, 0) catch return 1;
                            if (poll_result == 0) return 1;
                        }
                    }
                    break;
                },
                'u' => {
                    if (j + 1 < arg.len) {
                        read_fd = std.fmt.parseInt(types.Fd, arg[j + 1 ..], 10) catch {
                            posix.writeAll(2, "read: invalid fd\n");
                            return 2;
                        };
                    } else if (arg_start + 1 < args.len) {
                        arg_start += 1;
                        read_fd = std.fmt.parseInt(types.Fd, args[arg_start], 10) catch {
                            posix.writeAll(2, "read: invalid fd\n");
                            return 2;
                        };
                    }
                    if (read_fd < 0) {
                        posix.writeAll(2, "read: invalid fd\n");
                        return 2;
                    }
                    break;
                },
                else => break,
            }
        }
        arg_start += 1;
    }

    const var_names = if (arg_start < args.len) args[arg_start..] else &[_][]const u8{};
    const default_reply: []const []const u8 = &.{"REPLY"};
    const effective_names: []const []const u8 = if (var_names.len == 0) default_reply else var_names;

    if (prompt) |p| {
        posix.writeAll(2, p);
    }

    var buf: [4096]u8 = undefined;
    var escaped: [4096]bool = .{false} ** 4096;
    var total: usize = 0;
    var hit_eof = false;

    if (raw) {
        const max_chars = nchars orelse buf.len;
        while (total < buf.len and total < max_chars) {
            const n = posix.read(read_fd, buf[total .. total + 1]) catch {
                hit_eof = true;
                break;
            };
            if (n == 0) {
                hit_eof = true;
                break;
            }
            if (!nchars_exact and ((use_nul_delim and buf[total] == 0) or (!use_nul_delim and buf[total] == delim))) break;
            total += 1;
        }
    } else if (nchars != null) {
        var logical_chars: usize = 0;
        const max_chars = nchars.?;
        while (total < buf.len and logical_chars < max_chars) {
            var byte_buf: [1]u8 = undefined;
            const n = posix.read(read_fd, &byte_buf) catch {
                hit_eof = true;
                break;
            };
            if (n == 0) {
                hit_eof = true;
                break;
            }
            const ch = byte_buf[0];
            if (!nchars_exact and ((use_nul_delim and ch == 0) or (!use_nul_delim and ch == delim))) break;
            if (ch == '\\') {
                const n2 = posix.read(read_fd, &byte_buf) catch {
                    hit_eof = true;
                    break;
                };
                if (n2 == 0) {
                    hit_eof = true;
                    break;
                }
                if (byte_buf[0] == '\n') continue;
                buf[total] = byte_buf[0];
                escaped[total] = true;
                total += 1;
                logical_chars += 1;
            } else {
                buf[total] = ch;
                total += 1;
                logical_chars += 1;
            }
        }
    } else {
        while (total < buf.len) {
            var byte_buf: [1]u8 = undefined;
            const n = posix.read(read_fd, &byte_buf) catch {
                hit_eof = true;
                break;
            };
            if (n == 0) {
                hit_eof = true;
                break;
            }
            const ch = byte_buf[0];
            if ((use_nul_delim and ch == 0) or (!use_nul_delim and ch == delim)) break;
            if (ch == '\\') {
                const n2 = posix.read(read_fd, &byte_buf) catch {
                    hit_eof = true;
                    break;
                };
                if (n2 == 0) {
                    hit_eof = true;
                    break;
                }
                if (byte_buf[0] == '\n') continue;
                buf[total] = byte_buf[0];
                escaped[total] = true;
                total += 1;
            } else {
                buf[total] = ch;
                total += 1;
            }
        }
    }

    const line = buf[0..total];
    const ifs = env.ifs;

    if (effective_names.len == 1) {
        if (nchars_exact or var_names.len == 0) {
            env.set(effective_names[0], line, false) catch return 1;
        } else {
            var start: usize = 0;
            while (start < line.len and !escaped[start] and isIfsWhitespace(line[start], ifs)) : (start += 1) {}
            var end: usize = line.len;
            while (end > start and !escaped[end - 1] and isIfsWhitespace(line[end - 1], ifs)) : (end -= 1) {}
            env.set(effective_names[0], line[start..end], false) catch return 1;
        }
        return if (hit_eof) 1 else 0;
    }

    var pos: usize = 0;
    while (pos < line.len and !escaped[pos] and isIfsWhitespace(line[pos], ifs)) : (pos += 1) {}

    var var_idx: usize = 0;
    while (var_idx < effective_names.len - 1) : (var_idx += 1) {
        if (pos >= line.len) {
            env.set(effective_names[var_idx], "", false) catch return 1;
            continue;
        }
        const field_start = pos;
        while (pos < line.len and (escaped[pos] or !isIfsChar(line[pos], ifs))) : (pos += 1) {}
        env.set(effective_names[var_idx], line[field_start..pos], false) catch return 1;

        if (pos < line.len) {
            while (pos < line.len and !escaped[pos] and isIfsWhitespace(line[pos], ifs)) : (pos += 1) {}
            if (pos < line.len and !escaped[pos] and isIfsNonWhitespace(line[pos], ifs)) {
                pos += 1;
                while (pos < line.len and !escaped[pos] and isIfsWhitespace(line[pos], ifs)) : (pos += 1) {}
            }
        }
    }

    if (var_idx < effective_names.len) {
        var end: usize = line.len;
        while (end > pos and !escaped[end - 1] and isIfsWhitespace(line[end - 1], ifs)) : (end -= 1) {}
        if (end > pos and !escaped[end - 1] and isIfsNonWhitespace(line[end - 1], ifs)) {
            var trial_end = end - 1;
            while (trial_end > pos and !escaped[trial_end - 1] and isIfsWhitespace(line[trial_end - 1], ifs)) : (trial_end -= 1) {}
            var has_nws_ifs = false;
            var i = pos;
            while (i < trial_end) : (i += 1) {
                if (!escaped[i] and isIfsNonWhitespace(line[i], ifs)) {
                    has_nws_ifs = true;
                    break;
                }
            }
            if (!has_nws_ifs) end = trial_end;
        }
        env.set(effective_names[var_idx], line[pos..end], false) catch return 1;
    }

    return if (hit_eof) 1 else 0;
}

const PrintfSpec = struct {
    flag_minus: bool = false,
    flag_plus: bool = false,
    flag_space: bool = false,
    flag_zero: bool = false,
    flag_hash: bool = false,
    width: usize = 0,
    width_star: bool = false,
    precision: ?usize = null,
    precision_star: bool = false,
    conversion: u8 = 0,
    len: usize = 0,
};

fn printfProcessEscape(fmt: []const u8) struct { byte: u8, advance: usize } {
    if (fmt.len < 2 or fmt[0] != '\\') return .{ .byte = fmt[0], .advance = 1 };
    switch (fmt[1]) {
        '\\' => return .{ .byte = '\\', .advance = 2 },
        'a' => return .{ .byte = 0x07, .advance = 2 },
        'b' => return .{ .byte = 0x08, .advance = 2 },
        'f' => return .{ .byte = 0x0c, .advance = 2 },
        'n' => return .{ .byte = '\n', .advance = 2 },
        'r' => return .{ .byte = '\r', .advance = 2 },
        't' => return .{ .byte = '\t', .advance = 2 },
        'v' => return .{ .byte = 0x0b, .advance = 2 },
        '0'...'7' => {
            var val: u8 = fmt[1] - '0';
            var count: usize = 1;
            var i: usize = 2;
            while (i < fmt.len and count < 3 and fmt[i] >= '0' and fmt[i] <= '7') : (i += 1) {
                val = val *% 8 +% (fmt[i] - '0');
                count += 1;
            }
            return .{ .byte = val, .advance = i };
        },
        'x' => {
            var val: u8 = 0;
            var count: usize = 0;
            var i: usize = 2;
            while (i < fmt.len and count < 2) : (i += 1) {
                const d = hexDigit(fmt[i]) orelse break;
                val = val *% 16 +% d;
                count += 1;
            }
            return .{ .byte = val, .advance = i };
        },
        else => return .{ .byte = '\\', .advance = 1 },
    }
}

fn printfWriteUtf8(codepoint: u21) void {
    var buf: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(codepoint, &buf) catch {
        posix.writeAll(1, "\xef\xbf\xbd");
        return;
    };
    posix.writeAll(1, buf[0..len]);
}

fn printfProcessBEscape(fmt: []const u8) struct { byte: u8, advance: usize, is_unicode: bool, codepoint: u21 } {
    if (fmt.len < 2 or fmt[0] != '\\') return .{ .byte = fmt[0], .advance = 1, .is_unicode = false, .codepoint = 0 };
    switch (fmt[1]) {
        '\\' => return .{ .byte = '\\', .advance = 2, .is_unicode = false, .codepoint = 0 },
        'a' => return .{ .byte = 0x07, .advance = 2, .is_unicode = false, .codepoint = 0 },
        'b' => return .{ .byte = 0x08, .advance = 2, .is_unicode = false, .codepoint = 0 },
        'f' => return .{ .byte = 0x0c, .advance = 2, .is_unicode = false, .codepoint = 0 },
        'n' => return .{ .byte = '\n', .advance = 2, .is_unicode = false, .codepoint = 0 },
        'r' => return .{ .byte = '\r', .advance = 2, .is_unicode = false, .codepoint = 0 },
        't' => return .{ .byte = '\t', .advance = 2, .is_unicode = false, .codepoint = 0 },
        'v' => return .{ .byte = 0x0b, .advance = 2, .is_unicode = false, .codepoint = 0 },
        '0' => {
            var val: u8 = 0;
            var count: usize = 0;
            var i: usize = 2;
            while (i < fmt.len and count < 3 and fmt[i] >= '0' and fmt[i] <= '7') : (i += 1) {
                val = val *% 8 +% (fmt[i] - '0');
                count += 1;
            }
            return .{ .byte = val, .advance = i, .is_unicode = false, .codepoint = 0 };
        },
        '1'...'7' => {
            var val: u8 = fmt[1] - '0';
            var count: usize = 1;
            var i: usize = 2;
            while (i < fmt.len and count < 3 and fmt[i] >= '0' and fmt[i] <= '7') : (i += 1) {
                val = val *% 8 +% (fmt[i] - '0');
                count += 1;
            }
            return .{ .byte = val, .advance = i, .is_unicode = false, .codepoint = 0 };
        },
        'x' => {
            var val: u8 = 0;
            var count: usize = 0;
            var i: usize = 2;
            while (i < fmt.len and count < 2) : (i += 1) {
                const d = hexDigit(fmt[i]) orelse break;
                val = val *% 16 +% d;
                count += 1;
            }
            return .{ .byte = val, .advance = i, .is_unicode = false, .codepoint = 0 };
        },
        'u', 'U' => {
            const max_digits: usize = if (fmt[1] == 'u') 4 else 8;
            var codepoint: u21 = 0;
            var j: usize = 2;
            var count: usize = 0;
            while (j < fmt.len and count < max_digits) : (j += 1) {
                const d = hexDigit(fmt[j]) orelse break;
                codepoint = codepoint * 16 + @as(u21, d);
                count += 1;
            }
            if (count > 0) {
                return .{ .byte = 0, .advance = j, .is_unicode = true, .codepoint = codepoint };
            }
            return .{ .byte = '\\', .advance = 1, .is_unicode = false, .codepoint = 0 };
        },
        else => return .{ .byte = '\\', .advance = 1, .is_unicode = false, .codepoint = 0 },
    }
}

fn hexDigit(ch: u8) ?u8 {
    if (ch >= '0' and ch <= '9') return ch - '0';
    if (ch >= 'a' and ch <= 'f') return ch - 'a' + 10;
    if (ch >= 'A' and ch <= 'F') return ch - 'A' + 10;
    return null;
}

fn printfParseSpec(fmt: []const u8) PrintfSpec {
    var spec = PrintfSpec{};
    var i: usize = 1;

    while (i < fmt.len) : (i += 1) {
        switch (fmt[i]) {
            '-' => spec.flag_minus = true,
            '+' => spec.flag_plus = true,
            ' ' => spec.flag_space = true,
            '0' => spec.flag_zero = true,
            '#' => spec.flag_hash = true,
            else => break,
        }
    }

    if (i < fmt.len and fmt[i] == '*') {
        spec.width_star = true;
        i += 1;
    } else {
        while (i < fmt.len and fmt[i] >= '0' and fmt[i] <= '9') {
            spec.width = spec.width * 10 + (fmt[i] - '0');
            i += 1;
        }
    }

    if (i < fmt.len and fmt[i] == '.') {
        i += 1;
        if (i < fmt.len and fmt[i] == '*') {
            spec.precision_star = true;
            i += 1;
        } else {
            var prec: usize = 0;
            while (i < fmt.len and fmt[i] >= '0' and fmt[i] <= '9') {
                prec = prec * 10 + (fmt[i] - '0');
                i += 1;
            }
            spec.precision = prec;
        }
    }

    if (i < fmt.len) {
        spec.conversion = fmt[i];
        i += 1;
    }

    spec.len = i;
    return spec;
}

fn printfGetNextArg(arg_args: []const []const u8, arg_idx: *usize) []const u8 {
    if (arg_idx.* < arg_args.len) {
        const val = arg_args[arg_idx.*];
        arg_idx.* += 1;
        return val;
    }
    return "";
}

fn printfParseNumericArg(arg: []const u8, had_error: *bool) i64 {
    if (arg.len == 0) return 0;

    var s = arg;
    while (s.len > 0 and s[0] == ' ') s = s[1..];
    if (s.len == 0) return 0;

    if (s.len >= 1 and (s[0] == '\'' or s[0] == '"')) {
        const bytes = s[1..];
        if (bytes.len == 0) return 0;
        const b0 = bytes[0];
        if (b0 < 0x80) return @intCast(b0);
        if (b0 & 0xE0 == 0xC0 and bytes.len >= 2) return @as(i64, b0 & 0x1F) << 6 | @as(i64, bytes[1] & 0x3F);
        if (b0 & 0xF0 == 0xE0 and bytes.len >= 3) return @as(i64, b0 & 0x0F) << 12 | @as(i64, bytes[1] & 0x3F) << 6 | @as(i64, bytes[2] & 0x3F);
        if (b0 & 0xF8 == 0xF0 and bytes.len >= 4) return @as(i64, b0 & 0x07) << 18 | @as(i64, bytes[1] & 0x3F) << 12 | @as(i64, bytes[2] & 0x3F) << 6 | @as(i64, bytes[3] & 0x3F);
        return @intCast(b0);
    }

    var end = s.len;
    while (end > 0 and s[end - 1] == ' ') end -= 1;
    const has_trailing_space = end < s.len;
    s = s[0..end];
    if (s.len == 0) return 0;

    if (std.mem.indexOfScalar(u8, s, '#')) |hash_pos| {
        had_error.* = true;
        printfNumericError(arg);
        if (hash_pos > 0) {
            if (std.fmt.parseInt(i64, s[0..hash_pos], 10)) |v| return v else |_| {}
        }
        return 0;
    }

    var negative = false;
    var sign_len: usize = 0;
    if (s[0] == '-') {
        negative = true;
        sign_len = 1;
    } else if (s[0] == '+') {
        sign_len = 1;
    }

    const num_part = s[sign_len..];
    if (num_part.len == 0) {
        had_error.* = true;
        printfNumericError(arg);
        return 0;
    }

    if (has_trailing_space) {
        had_error.* = true;
        printfNumericError(arg);
    }

    if (num_part.len >= 2 and num_part[0] == '0' and num_part[1] != 'x' and num_part[1] != 'X') {
        if (std.fmt.parseInt(i64, num_part, 8)) |v| {
            return if (negative) -v else v;
        } else |_| {}
    }

    if (std.fmt.parseInt(i64, s, 0)) |v| return v else |_| {}

    had_error.* = true;
    if (!has_trailing_space) printfNumericError(arg);

    var base: u8 = 10;
    var prefix_start = sign_len;
    if (num_part.len >= 2 and num_part[0] == '0' and (num_part[1] == 'x' or num_part[1] == 'X')) {
        base = 16;
        prefix_start = sign_len + 2;
    } else if (num_part.len >= 1 and num_part[0] == '0') {
        base = 8;
    }

    var valid_end = prefix_start;
    while (valid_end < s.len) {
        const ch = s[valid_end];
        const is_valid = switch (base) {
            16 => std.ascii.isDigit(ch) or (ch >= 'a' and ch <= 'f') or (ch >= 'A' and ch <= 'F'),
            8 => ch >= '0' and ch <= '7',
            else => std.ascii.isDigit(ch),
        };
        if (!is_valid) break;
        valid_end += 1;
    }

    if (valid_end > prefix_start) {
        if (std.fmt.parseInt(i64, s[0..valid_end], 0)) |v| return v else |_| {}
        const abs_part = s[sign_len..valid_end];
        if (std.fmt.parseInt(i64, abs_part, base)) |v| return if (negative) -v else v else |_| {}
    }

    return 0;
}

fn printfParseFloatArg(arg: []const u8, had_error: *bool) f64 {
    if (arg.len == 0) return 0.0;
    var s = arg;
    while (s.len > 0 and s[0] == ' ') s = s[1..];
    if (s.len == 0) return 0.0;
    if (s.len >= 1 and (s[0] == '\'' or s[0] == '"')) {
        if (s.len < 2) return 0.0;
        return @floatFromInt(@as(i64, s[1]));
    }
    return std.fmt.parseFloat(f64, s) catch {
        had_error.* = true;
        posix.writeAll(2, "printf: '");
        posix.writeAll(2, arg);
        posix.writeAll(2, "': not a valid number\n");
        return 0.0;
    };
}

fn printfFormatFloat(value: f64, spec: PrintfSpec) void {
    var c_fmt: [64]u8 = undefined;
    var fi: usize = 0;
    c_fmt[fi] = '%';
    fi += 1;
    if (spec.flag_minus) { c_fmt[fi] = '-'; fi += 1; }
    if (spec.flag_plus) { c_fmt[fi] = '+'; fi += 1; }
    if (spec.flag_space) { c_fmt[fi] = ' '; fi += 1; }
    if (spec.flag_zero) { c_fmt[fi] = '0'; fi += 1; }
    if (spec.flag_hash) { c_fmt[fi] = '#'; fi += 1; }
    if (spec.width > 0) {
        const w = std.fmt.bufPrint(c_fmt[fi..], "{d}", .{spec.width}) catch return;
        fi += w.len;
    }
    if (spec.precision) |p| {
        c_fmt[fi] = '.';
        fi += 1;
        const ps = std.fmt.bufPrint(c_fmt[fi..], "{d}", .{p}) catch return;
        fi += ps.len;
    }
    c_fmt[fi] = spec.conversion;
    fi += 1;
    c_fmt[fi] = 0;

    var out_buf: [256]u8 = undefined;
    const c_snprintf = @extern(*const fn ([*]u8, usize, [*:0]const u8, ...) callconv(.c) c_int, .{ .name = "snprintf" });
    const n = c_snprintf(&out_buf, out_buf.len, @ptrCast(&c_fmt), value);
    if (n > 0) {
        posix.writeAll(1, out_buf[0..@intCast(n)]);
    }
}

fn printfNumericError(arg: []const u8) void {
    posix.writeAll(2, "printf: '");
    posix.writeAll(2, arg);
    posix.writeAll(2, "': not a valid number\n");
}

fn printfWritePadding(ch: u8, count: usize) void {
    var pad_buf: [64]u8 = undefined;
    @memset(&pad_buf, ch);
    var remaining = count;
    while (remaining > 0) {
        const to_write = @min(remaining, pad_buf.len);
        posix.writeAll(1, pad_buf[0..to_write]);
        remaining -= to_write;
    }
}

fn printfFormatString(arg: []const u8, spec: PrintfSpec) void {
    const effective = if (spec.precision) |p| arg[0..@min(p, arg.len)] else arg;
    if (spec.width > effective.len) {
        const pad = spec.width - effective.len;
        if (spec.flag_minus) {
            posix.writeAll(1, effective);
            printfWritePadding(' ', pad);
        } else {
            printfWritePadding(' ', pad);
            posix.writeAll(1, effective);
        }
    } else {
        posix.writeAll(1, effective);
    }
}

fn printfFormatBString(arg: []const u8, spec: PrintfSpec, early_exit: *bool) void {
    var out_buf: [4096]u8 = undefined;
    var out_len: usize = 0;
    var i: usize = 0;
    while (i < arg.len and out_len + 4 < out_buf.len) {
        if (arg[i] == '\\') {
            if (i + 1 < arg.len and arg[i + 1] == 'c') {
                early_exit.* = true;
                break;
            }
            const esc = printfProcessBEscape(arg[i..]);
            if (esc.is_unicode) {
                var utf8_buf: [4]u8 = undefined;
                const utf8_len = std.unicode.utf8Encode(esc.codepoint, &utf8_buf) catch blk: {
                    utf8_buf[0] = 0xef;
                    utf8_buf[1] = 0xbf;
                    utf8_buf[2] = 0xbd;
                    break :blk @as(u3, 3);
                };
                for (utf8_buf[0..utf8_len]) |b| {
                    if (out_len < out_buf.len) {
                        out_buf[out_len] = b;
                        out_len += 1;
                    }
                }
            } else {
                out_buf[out_len] = esc.byte;
                out_len += 1;
            }
            i += esc.advance;
        } else {
            out_buf[out_len] = arg[i];
            out_len += 1;
            i += 1;
        }
    }
    const effective = out_buf[0..out_len];
    if (spec.width > effective.len) {
        const pad = spec.width - effective.len;
        if (spec.flag_minus) {
            posix.writeAll(1, effective);
            printfWritePadding(' ', pad);
        } else {
            printfWritePadding(' ', pad);
            posix.writeAll(1, effective);
        }
    } else {
        posix.writeAll(1, effective);
    }
}

fn printfFormatInt(value: i64, spec: PrintfSpec) void {
    var digit_buf: [64]u8 = undefined;
    var digit_len: usize = 0;

    const is_negative = value < 0;
    const base: u64 = switch (spec.conversion) {
        'o' => 8,
        'x', 'X' => 16,
        'u' => 10,
        else => 10,
    };
    const is_unsigned = spec.conversion == 'u' or spec.conversion == 'o' or spec.conversion == 'x' or spec.conversion == 'X';
    const abs_val: u64 = if (is_negative and !is_unsigned) @intCast(-value) else @bitCast(value);

    if (abs_val == 0) {
        digit_buf[0] = '0';
        digit_len = 1;
    } else {
        var tmp = abs_val;
        while (tmp > 0) {
            const d: u8 = @intCast(tmp % base);
            digit_buf[digit_len] = if (d < 10) '0' + d else if (spec.conversion == 'X') 'A' + d - 10 else 'a' + d - 10;
            digit_len += 1;
            tmp /= base;
        }
        var lo: usize = 0;
        var hi: usize = digit_len - 1;
        while (lo < hi) {
            const t = digit_buf[lo];
            digit_buf[lo] = digit_buf[hi];
            digit_buf[hi] = t;
            lo += 1;
            hi -= 1;
        }
    }

    var prefix_buf: [3]u8 = undefined;
    var prefix_len: usize = 0;
    if (!is_unsigned and is_negative) {
        prefix_buf[prefix_len] = '-';
        prefix_len += 1;
    } else if (!is_unsigned and spec.flag_plus) {
        prefix_buf[prefix_len] = '+';
        prefix_len += 1;
    } else if (!is_unsigned and spec.flag_space) {
        prefix_buf[prefix_len] = ' ';
        prefix_len += 1;
    }

    if (spec.flag_hash and abs_val != 0) {
        if (spec.conversion == 'o') {
            if (digit_len == 0 or digit_buf[0] != '0') {
                prefix_buf[prefix_len] = '0';
                prefix_len += 1;
            }
        } else if (spec.conversion == 'x') {
            prefix_buf[prefix_len] = '0';
            prefix_len += 1;
            prefix_buf[prefix_len] = 'x';
            prefix_len += 1;
        } else if (spec.conversion == 'X') {
            prefix_buf[prefix_len] = '0';
            prefix_len += 1;
            prefix_buf[prefix_len] = 'X';
            prefix_len += 1;
        }
    }

    const precision = spec.precision orelse 0;
    const zero_pad_digits = if (precision > digit_len) precision - digit_len else 0;
    const content_len = prefix_len + zero_pad_digits + digit_len;

    if (spec.flag_minus) {
        posix.writeAll(1, prefix_buf[0..prefix_len]);
        printfWritePadding('0', zero_pad_digits);
        posix.writeAll(1, digit_buf[0..digit_len]);
        if (spec.width > content_len) printfWritePadding(' ', spec.width - content_len);
    } else if (spec.flag_zero and spec.precision == null) {
        posix.writeAll(1, prefix_buf[0..prefix_len]);
        const total_needed = if (spec.width > content_len) spec.width - content_len else 0;
        printfWritePadding('0', total_needed + zero_pad_digits);
        posix.writeAll(1, digit_buf[0..digit_len]);
    } else {
        if (spec.width > content_len) printfWritePadding(' ', spec.width - content_len);
        posix.writeAll(1, prefix_buf[0..prefix_len]);
        printfWritePadding('0', zero_pad_digits);
        posix.writeAll(1, digit_buf[0..digit_len]);
    }
}

fn printfFormatQString(arg: []const u8, spec: PrintfSpec) void {
    if (arg.len == 0) {
        const quoted = "''";
        if (spec.width > quoted.len) {
            if (spec.flag_minus) {
                posix.writeAll(1, quoted);
                printfWritePadding(' ', spec.width - quoted.len);
            } else {
                printfWritePadding(' ', spec.width - quoted.len);
                posix.writeAll(1, quoted);
            }
        } else {
            posix.writeAll(1, quoted);
        }
        return;
    }

    var needs_quoting = false;
    var has_control = false;
    var has_single_quote = false;
    {
        var si: usize = 0;
        while (si < arg.len) {
            const ch = arg[si];
            if (ch < 0x80) {
                switch (ch) {
                    'a'...'z', 'A'...'Z', '0'...'9', '_', '/', '.', '-', '+', ':', ',', '@', '%', '^' => {},
                    '\'' => {
                        has_single_quote = true;
                        needs_quoting = true;
                    },
                    '\n', '\r', '\t', 0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f, 0x7f => {
                        has_control = true;
                        needs_quoting = true;
                    },
                    else => {
                        needs_quoting = true;
                    },
                }
                si += 1;
            } else {
                const seq_len = printfUtf8SeqLen(ch);
                if (seq_len > 1 and si + seq_len <= arg.len and printfValidUtf8Cont(arg[si + 1 .. si + seq_len])) {
                    si += seq_len;
                } else {
                    has_control = true;
                    needs_quoting = true;
                    si += 1;
                }
            }
        }
    }

    if (!needs_quoting) {
        printfFormatString(arg, spec);
        return;
    }

    var buf: [8192]u8 = undefined;
    var len: usize = 0;

    if (has_control) {
        buf[len] = '$';
        len += 1;
        buf[len] = '\'';
        len += 1;
        var ii: usize = 0;
        while (ii < arg.len) {
            if (len + 10 >= buf.len) break;
            const ch = arg[ii];
            if (ch >= 0x80) {
                const seq_len = printfUtf8SeqLen(ch);
                if (seq_len > 1 and ii + seq_len <= arg.len and printfValidUtf8Cont(arg[ii + 1 .. ii + seq_len])) {
                    @memcpy(buf[len .. len + seq_len], arg[ii .. ii + seq_len]);
                    len += seq_len;
                    ii += seq_len;
                } else {
                    if (ch >= 0xc0 and ch <= 0xf4) {
                        const hex_chars = "0123456789abcdef";
                        buf[len] = '\\';
                        buf[len + 1] = 'x';
                        buf[len + 2] = hex_chars[ch >> 4];
                        buf[len + 3] = hex_chars[ch & 0xf];
                        len += 4;
                    } else {
                        buf[len] = '\\';
                        buf[len + 1] = '0' + (ch >> 6);
                        buf[len + 2] = '0' + ((ch >> 3) & 7);
                        buf[len + 3] = '0' + (ch & 7);
                        len += 4;
                    }
                    ii += 1;
                }
                continue;
            }
            switch (ch) {
                '\'' => {
                    buf[len] = '\\';
                    buf[len + 1] = '\'';
                    len += 2;
                },
                '\\' => {
                    buf[len] = '\\';
                    buf[len + 1] = '\\';
                    len += 2;
                },
                '\n' => {
                    buf[len] = '\\';
                    buf[len + 1] = 'n';
                    len += 2;
                },
                '\r' => {
                    buf[len] = '\\';
                    buf[len + 1] = 'r';
                    len += 2;
                },
                '\t' => {
                    buf[len] = '\\';
                    buf[len + 1] = 't';
                    len += 2;
                },
                0x07 => {
                    buf[len] = '\\';
                    buf[len + 1] = 'a';
                    len += 2;
                },
                0x08 => {
                    buf[len] = '\\';
                    buf[len + 1] = 'b';
                    len += 2;
                },
                else => {
                    if (ch < 0x20 or ch == 0x7f) {
                        const hex_chars = "0123456789abcdef";
                        buf[len] = '\\';
                        buf[len + 1] = 'u';
                        buf[len + 2] = '0';
                        buf[len + 3] = '0';
                        buf[len + 4] = hex_chars[ch >> 4];
                        buf[len + 5] = hex_chars[ch & 0xf];
                        len += 6;
                    } else {
                        buf[len] = ch;
                        len += 1;
                    }
                },
            }
            ii += 1;
        }
        if (len + 1 < buf.len) {
            buf[len] = '\'';
            len += 1;
        }
    } else if (has_single_quote) {
        var ii: usize = 0;
        while (ii < arg.len) {
            if (len + 6 >= buf.len) break;
            const ch = arg[ii];
            if (ch >= 0x80) {
                buf[len] = ch;
                len += 1;
                ii += 1;
                continue;
            }
            switch (ch) {
                'a'...'z', 'A'...'Z', '0'...'9', '_', '/', '.', '-', '+', ':', ',', '@', '%', '^' => {
                    buf[len] = ch;
                    len += 1;
                },
                else => {
                    buf[len] = '\\';
                    buf[len + 1] = ch;
                    len += 2;
                },
            }
            ii += 1;
        }
    } else {
        buf[len] = '\'';
        len += 1;
        for (arg) |ch| {
            if (len + 1 >= buf.len) break;
            buf[len] = ch;
            len += 1;
        }
        if (len + 1 < buf.len) {
            buf[len] = '\'';
            len += 1;
        }
    }

    const result = buf[0..len];
    if (spec.width > result.len) {
        if (spec.flag_minus) {
            posix.writeAll(1, result);
            printfWritePadding(' ', spec.width - result.len);
        } else {
            printfWritePadding(' ', spec.width - result.len);
            posix.writeAll(1, result);
        }
    } else {
        posix.writeAll(1, result);
    }
}

fn printfUtf8SeqLen(lead: u8) u3 {
    if (lead < 0xC2) return 1;
    if (lead < 0xE0) return 2;
    if (lead < 0xF0) return 3;
    if (lead < 0xF5) return 4;
    return 1;
}

fn printfValidUtf8Cont(bytes: []const u8) bool {
    for (bytes) |b| {
        if ((b & 0xC0) != 0x80) return false;
    }
    return true;
}

fn printfFormatChar(arg: []const u8, spec: PrintfSpec) void {
    const ch: [1]u8 = .{if (arg.len > 0) arg[0] else 0};
    if (spec.width > 1) {
        if (spec.flag_minus) {
            posix.writeAll(1, &ch);
            printfWritePadding(' ', spec.width - 1);
        } else {
            printfWritePadding(' ', spec.width - 1);
            posix.writeAll(1, &ch);
        }
    } else {
        posix.writeAll(1, &ch);
    }
}

fn printfProcessFormat(fmt: []const u8, printf_args: []const []const u8, arg_idx: *usize) struct { status: u8, early_exit: bool } {
    var status: u8 = 0;
    var i: usize = 0;

    while (i < fmt.len) {
        if (fmt[i] == '\\') {
            if (i + 1 < fmt.len and (fmt[i + 1] == 'u' or fmt[i + 1] == 'U')) {
                const max_digits: usize = if (fmt[i + 1] == 'u') 4 else 8;
                var codepoint: u21 = 0;
                var j: usize = i + 2;
                var count: usize = 0;
                while (j < fmt.len and count < max_digits) : (j += 1) {
                    const d = hexDigit(fmt[j]) orelse break;
                    codepoint = codepoint * 16 + d;
                    count += 1;
                }
                if (count > 0) {
                    printfWriteUtf8(codepoint);
                    i = j;
                } else {
                    posix.writeAll(1, "\\");
                    i += 1;
                }
            } else {
                const esc = printfProcessEscape(fmt[i..]);
                const byte_arr: [1]u8 = .{esc.byte};
                posix.writeAll(1, &byte_arr);
                i += esc.advance;
            }
        } else if (fmt[i] == '%') {
            if (i + 1 < fmt.len and fmt[i + 1] == '%') {
                posix.writeAll(1, "%");
                i += 2;
                continue;
            }
            var spec = printfParseSpec(fmt[i..]);
            if (spec.width_star) {
                const w_arg = printfGetNextArg(printf_args, arg_idx);
                var w_err = false;
                const w = printfParseNumericArg(w_arg, &w_err);
                if (w_err) status = 1;
                if (w < 0) {
                    spec.flag_minus = true;
                    spec.width = @intCast(-w);
                } else {
                    spec.width = @intCast(w);
                }
            }
            if (spec.precision_star) {
                const p_arg = printfGetNextArg(printf_args, arg_idx);
                var p_err = false;
                const p = printfParseNumericArg(p_arg, &p_err);
                if (p_err) status = 1;
                spec.precision = if (p >= 0) @intCast(p) else null;
            }

            switch (spec.conversion) {
                's' => {
                    const arg = printfGetNextArg(printf_args, arg_idx);
                    printfFormatString(arg, spec);
                },
                'b' => {
                    const arg = printfGetNextArg(printf_args, arg_idx);
                    var early_exit = false;
                    printfFormatBString(arg, spec, &early_exit);
                    if (early_exit) return .{ .status = status, .early_exit = true };
                },
                'd', 'i' => {
                    const arg = printfGetNextArg(printf_args, arg_idx);
                    var had_error = false;
                    const val = printfParseNumericArg(arg, &had_error);
                    if (had_error) status = 1;
                    printfFormatInt(val, spec);
                },
                'u', 'o', 'x', 'X' => {
                    const arg = printfGetNextArg(printf_args, arg_idx);
                    var had_error = false;
                    const val = printfParseNumericArg(arg, &had_error);
                    if (had_error) status = 1;
                    printfFormatInt(val, spec);
                },
                'q' => {
                    const arg = printfGetNextArg(printf_args, arg_idx);
                    printfFormatQString(arg, spec);
                },
                'c' => {
                    const arg = printfGetNextArg(printf_args, arg_idx);
                    printfFormatChar(arg, spec);
                },
                'f', 'F', 'e', 'E', 'g', 'G' => {
                    const arg = printfGetNextArg(printf_args, arg_idx);
                    var had_error = false;
                    const val = printfParseFloatArg(arg, &had_error);
                    if (had_error) status = 1;
                    printfFormatFloat(val, spec);
                },
                0 => {
                    posix.writeAll(2, "printf: missing format character\n");
                    return .{ .status = 1, .early_exit = false };
                },
                else => {
                    posix.writeAll(2, "printf: unknown format character: ");
                    const conv_arr: [1]u8 = .{spec.conversion};
                    posix.writeAll(2, &conv_arr);
                    posix.writeAll(2, "\n");
                    status = 1;
                },
            }
            i += spec.len;
        } else {
            var end = i + 1;
            while (end < fmt.len and fmt[end] != '\\' and fmt[end] != '%') : (end += 1) {}
            posix.writeAll(1, fmt[i..end]);
            i = end;
        }
    }
    return .{ .status = status, .early_exit = false };
}

fn builtinPrintf(args: []const []const u8, env: *Environment) u8 {
    if (args.len < 2) {
        posix.writeAll(2, "printf: usage: printf format [arguments]\n");
        return 2;
    }

    var fmt_idx: usize = 1;
    if (std.mem.eql(u8, args[1], "--")) {
        fmt_idx = 2;
        if (fmt_idx >= args.len) {
            posix.writeAll(2, "printf: usage: printf format [arguments]\n");
            return 2;
        }
    }

    var var_name: ?[]const u8 = null;
    if (fmt_idx < args.len and std.mem.eql(u8, args[fmt_idx], "-v")) {
        fmt_idx += 1;
        if (fmt_idx >= args.len) {
            posix.writeAll(2, "printf: -v: option requires an argument\n");
            return 2;
        }
        var_name = args[fmt_idx];
        if (!isValidVarRef(args[fmt_idx])) {
            posix.writeAll(2, "printf: `");
            posix.writeAll(2, args[fmt_idx]);
            posix.writeAll(2, "': not a valid identifier\n");
            return 2;
        }
        fmt_idx += 1;
        if (fmt_idx >= args.len) {
            posix.writeAll(2, "printf: usage: printf format [arguments]\n");
            return 2;
        }
    }

    const fmt = args[fmt_idx];
    const printf_args = if (args.len > fmt_idx + 1) args[fmt_idx + 1 ..] else &[_][]const u8{};
    var arg_idx: usize = 0;
    var status: u8 = 0;

    var saved_stdout: i32 = -1;
    var pipe_fds: [2]i32 = .{ -1, -1 };
    if (var_name != null) {
        pipe_fds = posix.pipe() catch return 1;
        saved_stdout = posix.dup(1) catch {
            posix.close(pipe_fds[0]);
            posix.close(pipe_fds[1]);
            return 1;
        };
        posix.dup2(pipe_fds[1], 1) catch {
            posix.close(saved_stdout);
            posix.close(pipe_fds[0]);
            posix.close(pipe_fds[1]);
            return 1;
        };
        posix.close(pipe_fds[1]);
    }

    const result = printfProcessFormat(fmt, printf_args, &arg_idx);
    if (result.status != 0) status = result.status;
    if (!result.early_exit and arg_idx > 0) {
        while (arg_idx < printf_args.len) {
            const prev_idx = arg_idx;
            const loop_result = printfProcessFormat(fmt, printf_args, &arg_idx);
            if (loop_result.status != 0) status = loop_result.status;
            if (loop_result.early_exit) break;
            if (arg_idx == prev_idx) break;
        }
    }

    if (var_name) |vn| {
        posix.dup2(saved_stdout, 1) catch {};
        posix.close(saved_stdout);

        var output: std.ArrayListUnmanaged(u8) = .empty;
        var buf: [4096]u8 = undefined;
        while (true) {
            const n = posix.read(pipe_fds[0], &buf) catch break;
            if (n == 0) break;
            output.appendSlice(env.alloc, buf[0..n]) catch break;
        }
        posix.close(pipe_fds[0]);

        const val = output.toOwnedSlice(env.alloc) catch return 1;
        env.set(vn, val, false) catch {};
        env.alloc.free(val);
    }

    return status;
}

fn builtinUmask(args: []const []const u8, _: *Environment) u8 {
    if (args.len < 2) {
        const current = libc.umask(0);
        _ = libc.umask(current);
        var buf: [8]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{o:0>4}\n", .{current}) catch return 1;
        posix.writeAll(1, s);
        return 0;
    }

    var symbolic_display = false;
    var print_reusable = false;
    var arg_start: usize = 1;
    while (arg_start < args.len) {
        if (std.mem.eql(u8, args[arg_start], "-S")) {
            symbolic_display = true;
            arg_start += 1;
        } else if (std.mem.eql(u8, args[arg_start], "-p")) {
            print_reusable = true;
            arg_start += 1;
        } else break;
    }

    if (arg_start >= args.len and (symbolic_display or print_reusable)) {
        const current = libc.umask(0);
        _ = libc.umask(current);
        if (symbolic_display) {
            const perm: c_uint = ~current & 0o777;
            var buf: [32]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "u={s}{s}{s},g={s}{s}{s},o={s}{s}{s}\n", .{
                @as([]const u8, if (perm & 0o400 != 0) "r" else ""),
                @as([]const u8, if (perm & 0o200 != 0) "w" else ""),
                @as([]const u8, if (perm & 0o100 != 0) "x" else ""),
                @as([]const u8, if (perm & 0o040 != 0) "r" else ""),
                @as([]const u8, if (perm & 0o020 != 0) "w" else ""),
                @as([]const u8, if (perm & 0o010 != 0) "x" else ""),
                @as([]const u8, if (perm & 0o004 != 0) "r" else ""),
                @as([]const u8, if (perm & 0o002 != 0) "w" else ""),
                @as([]const u8, if (perm & 0o001 != 0) "x" else ""),
            }) catch return 1;
            posix.writeAll(1, s);
        } else {
            var buf: [16]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "umask {o:0>4}\n", .{current}) catch return 1;
            posix.writeAll(1, s);
        }
        return 0;
    }

    if (arg_start >= args.len) return 0;
    const mask_arg = args[arg_start];

    if (std.fmt.parseInt(c_uint, mask_arg, 8)) |new_mask| {
        _ = libc.umask(new_mask);
        return 0;
    } else |_| {}

    const current = libc.umask(0);
    var perm: c_uint = ~current & 0o777;

    var i: usize = 0;
    while (i < mask_arg.len) {
        var who_u = false;
        var who_g = false;
        var who_o = false;
        while (i < mask_arg.len) : (i += 1) {
            switch (mask_arg[i]) {
                'u' => who_u = true,
                'g' => who_g = true,
                'o' => who_o = true,
                'a' => {
                    who_u = true;
                    who_g = true;
                    who_o = true;
                },
                else => break,
            }
        }
        if (!who_u and !who_g and !who_o) {
            who_u = true;
            who_g = true;
            who_o = true;
        }

        if (i >= mask_arg.len) break;
        var op = mask_arg[i];
        if (op != '=' and op != '+' and op != '-') {
            posix.writeAll(2, "umask: invalid symbolic mode\n");
            _ = libc.umask(current);
            return 1;
        }
        i += 1;

        while (true) {
            var bits: c_uint = 0;
            while (i < mask_arg.len and mask_arg[i] != ',') : (i += 1) {
                switch (mask_arg[i]) {
                    'r' => bits |= 4,
                    'w' => bits |= 2,
                    'x' => bits |= 1,
                    else => break,
                }
            }

            var mask_bits: c_uint = 0;
            if (who_u) mask_bits |= bits << 6;
            if (who_g) mask_bits |= bits << 3;
            if (who_o) mask_bits |= bits;

            switch (op) {
                '=' => {
                    var clear: c_uint = 0;
                    if (who_u) clear |= 0o700;
                    if (who_g) clear |= 0o070;
                    if (who_o) clear |= 0o007;
                    perm = (perm & ~clear) | mask_bits;
                },
                '+' => perm |= mask_bits,
                '-' => perm &= ~mask_bits,
                else => {},
            }

            if (i < mask_arg.len and (mask_arg[i] == '+' or mask_arg[i] == '-' or mask_arg[i] == '=')) {
                op = mask_arg[i];
                i += 1;
                continue;
            }
            break;
        }

        if (i < mask_arg.len and mask_arg[i] == ',') i += 1;
    }

    _ = libc.umask(~perm & 0o777);
    return 0;
}

fn builtinType(args: []const []const u8, env: *Environment) u8 {
    if (args.len < 2) return 0;
    var status: u8 = 0;
    for (args[1..]) |name| {
        if (isShellKeyword(name)) {
            posix.writeAll(1, name);
            posix.writeAll(1, " is a shell keyword\n");
        } else if (env.getAlias(name)) |val| {
            posix.writeAll(1, name);
            posix.writeAll(1, " is aliased to '");
            posix.writeAll(1, val);
            posix.writeAll(1, "'\n");
        } else if (builtins.get(name) != null or isExecutorBuiltin(name)) {
            posix.writeAll(1, name);
            if (isSpecialBuiltin(name)) {
                posix.writeAll(1, " is a special shell builtin\n");
            } else {
                posix.writeAll(1, " is a shell builtin\n");
            }
        } else if (env.functions.get(name) != null) {
            posix.writeAll(1, name);
            posix.writeAll(1, " is a shell function\n");
        } else if (findInPathStr(name, env)) |path| {
            posix.writeAll(1, name);
            posix.writeAll(1, " is ");
            posix.writeAll(1, path);
            posix.writeAll(1, "\n");
        } else {
            posix.writeAll(2, name);
            posix.writeAll(2, ": not found\n");
            status = 1;
        }
    }
    return status;
}

fn isExecutorBuiltin(name: []const u8) bool {
    const executor_builtins = [_][]const u8{
        ".", "source", "eval", "exec", "command",
    };
    for (executor_builtins) |b| {
        if (std.mem.eql(u8, name, b)) return true;
    }
    return false;
}

fn isShellKeyword(name: []const u8) bool {
    const keywords = [_][]const u8{
        "if", "then", "else", "elif", "fi", "do", "done",
        "case", "esac", "while", "until", "for", "in",
        "{", "}", "!", "[[", "]]",
    };
    for (keywords) |kw| {
        if (std.mem.eql(u8, name, kw)) return true;
    }
    return false;
}

fn isSpecialBuiltin(name: []const u8) bool {
    const specials = [_][]const u8{
        ":", ".", "break", "continue", "eval", "exec", "exit",
        "export", "readonly", "set", "shift", "unset", "return", "trap", "times",
    };
    for (specials) |s| {
        if (std.mem.eql(u8, name, s)) return true;
    }
    return false;
}

fn findInPath(name: []const u8, env: *const Environment) bool {
    if (std.mem.indexOfScalar(u8, name, '/') != null) {
        const path_z = std.posix.toPosixPath(name) catch return false;
        return posix.access(&path_z, 1);
    }
    const path_env = env.get("PATH") orelse "/usr/bin:/bin";
    var iter = std.mem.splitScalar(u8, path_env, ':');
    while (iter.next()) |dir| {
        var full_buf: [4096]u8 = undefined;
        const full = std.fmt.bufPrint(&full_buf, "{s}/{s}", .{ dir, name }) catch continue;
        const full_z = std.posix.toPosixPath(full) catch continue;
        if (posix.access(&full_z, 1)) return true;
    }
    return false;
}

var find_path_result_buf: [4096]u8 = undefined;

fn findInPathStr(name: []const u8, env: *const Environment) ?[]const u8 {
    if (std.mem.indexOfScalar(u8, name, '/') != null) {
        const path_z = std.posix.toPosixPath(name) catch return null;
        if (posix.access(&path_z, 1)) return name;
        return null;
    }
    const path_env = env.get("PATH") orelse "/usr/bin:/bin";
    var iter = std.mem.splitScalar(u8, path_env, ':');
    while (iter.next()) |dir| {
        const full = std.fmt.bufPrint(&find_path_result_buf, "{s}/{s}", .{ dir, name }) catch continue;
        const full_z = std.posix.toPosixPath(full) catch continue;
        if (posix.access(&full_z, 1)) return full;
    }
    return null;
}

fn builtinGetopts(args: []const []const u8, env: *Environment) u8 {
    if (args.len < 3) {
        posix.writeAll(2, "getopts: usage: getopts optstring name [arg ...]\n");
        return 2;
    }
    const raw_optstring = args[1];
    const varname = args[2];
    if (varname.len == 0 or (varname[0] != '_' and !std.ascii.isAlphabetic(varname[0]))) {
        posix.writeAll(2, "getopts: ");
        posix.writeAll(2, varname);
        posix.writeAll(2, ": invalid variable name\n");
        return 2;
    }
    for (varname[1..]) |vc| {
        if (vc != '_' and !std.ascii.isAlphanumeric(vc)) {
            posix.writeAll(2, "getopts: ");
            posix.writeAll(2, varname);
            posix.writeAll(2, ": invalid variable name\n");
            return 2;
        }
    }
    const params = if (args.len > 3) args[3..] else env.positional_params;

    const silent = raw_optstring.len > 0 and raw_optstring[0] == ':';
    const optstring = if (silent) raw_optstring[1..] else raw_optstring;

    const optind_str = env.get("OPTIND") orelse "1";
    var optind = std.fmt.parseInt(usize, optind_str, 10) catch 1;
    if (optind == 0) optind = 1;

    var optpos_val: usize = 0;
    if (env.get("OPTPOS")) |pos_str| {
        optpos_val = std.fmt.parseInt(usize, pos_str, 10) catch 0;
    }

    if (optind > params.len) {
        env.set(varname, "?", false) catch {};
        _ = env.unset("OPTARG");
        return 1;
    }

    const current_arg = params[optind - 1];

    if (optpos_val == 0) {
        if (current_arg.len < 2 or current_arg[0] != '-') {
            env.set(varname, "?", false) catch {};
            return 1;
        }
        if (std.mem.eql(u8, current_arg, "--")) {
            optind += 1;
            var ind_buf2: [16]u8 = undefined;
            const ind_str2 = std.fmt.bufPrint(&ind_buf2, "{d}", .{optind}) catch return 1;
            env.set("OPTIND", ind_str2, false) catch {};
            env.set(varname, "?", false) catch {};
            return 1;
        }
        optpos_val = 1;
    }

    const opt_char = current_arg[optpos_val];
    var found = false;
    var expects_arg = false;
    for (optstring, 0..) |ch, idx| {
        if (ch == ':') continue;
        if (ch == opt_char) {
            found = true;
            if (idx + 1 < optstring.len and optstring[idx + 1] == ':') {
                expects_arg = true;
            }
            break;
        }
    }

    var val_buf: [2]u8 = undefined;
    val_buf[0] = opt_char;
    const val: []const u8 = val_buf[0..1];

    if (!found) {
        if (silent) {
            env.set(varname, "?", false) catch {};
            env.set("OPTARG", val, false) catch {};
        } else {
            env.set(varname, "?", false) catch {};
            _ = env.unset("OPTARG");
            posix.writeAll(2, "getopts: illegal option -- ");
            posix.writeAll(2, val);
            posix.writeAll(2, "\n");
        }
        optpos_val += 1;
        if (optpos_val >= current_arg.len) {
            optind += 1;
            optpos_val = 0;
        }
    } else {
        env.set(varname, val, false) catch {};
        if (!expects_arg) {
            env.set("OPTARG", "", false) catch {};
        }
        if (expects_arg) {
            if (optpos_val + 1 < current_arg.len) {
                env.set("OPTARG", current_arg[optpos_val + 1 ..], false) catch {};
            } else if (optind < params.len) {
                optind += 1;
                env.set("OPTARG", params[optind - 1], false) catch {};
            } else {
                if (silent) {
                    env.set(varname, ":", false) catch {};
                    env.set("OPTARG", val, false) catch {};
                } else {
                    env.set(varname, "?", false) catch {};
                    posix.writeAll(2, "getopts: option requires an argument -- ");
                    posix.writeAll(2, val);
                    posix.writeAll(2, "\n");
                }
                optind += 1;
                optpos_val = 0;
                var ind_buf: [16]u8 = undefined;
                const ind_str = std.fmt.bufPrint(&ind_buf, "{d}", .{optind}) catch return 1;
                env.set("OPTIND", ind_str, false) catch {};
                var pos_buf: [16]u8 = undefined;
                const pos_str = std.fmt.bufPrint(&pos_buf, "{d}", .{optpos_val}) catch return 1;
                env.set("OPTPOS", pos_str, false) catch {};
                return 0;
            }
            optind += 1;
            optpos_val = 0;
        } else {
            optpos_val += 1;
            if (optpos_val >= current_arg.len) {
                optind += 1;
                optpos_val = 0;
            }
        }
    }

    var ind_buf: [16]u8 = undefined;
    const ind_str = std.fmt.bufPrint(&ind_buf, "{d}", .{optind}) catch return 1;
    env.set("OPTIND", ind_str, false) catch {};
    var pos_buf: [16]u8 = undefined;
    const pos_str = std.fmt.bufPrint(&pos_buf, "{d}", .{optpos_val}) catch return 1;
    env.set("OPTPOS", pos_str, false) catch {};
    return 0;
}

fn builtinFg(args: []const []const u8, env: *Environment) u8 {
    const jt = env.job_table orelse return 1;
    const spec = if (args.len > 1) args[1] else "";
    const job = jt.parseJobSpec(spec) orelse {
        posix.writeAll(2, "fg: no such job\n");
        return 1;
    };

    posix.writeAll(2, job.command);
    posix.writeAll(2, "\n");

    signals.sendSignal(job.pgid, signals.SIGCONT) catch {};

    posix.tcsetpgrp(0, job.pgid) catch {};

    const result = posix.waitpid(job.pid, 2);
    const shell_pgid = posix.getpid();
    posix.tcsetpgrp(0, shell_pgid) catch {};

    if (result.pid > 0) {
        if (result.status & 0xff == 0x7f) {
            job.state = .stopped;
            job.notified = false;
            posix.writeAll(2, "\n[");
            var buf: [16]u8 = undefined;
            const id_str = std.fmt.bufPrint(&buf, "{d}", .{job.id}) catch "";
            posix.writeAll(2, id_str);
            posix.writeAll(2, "]  Stopped\t\t");
            posix.writeAll(2, job.command);
            posix.writeAll(2, "\n");
            return @truncate(128 + ((result.status >> 8) & 0xff));
        }
        const status = posix.statusFromWait(result.status);
        jt.removeJob(job.id);
        return status;
    }
    return 1;
}

fn builtinBg(args: []const []const u8, env: *Environment) u8 {
    const jt = env.job_table orelse return 1;
    const spec = if (args.len > 1) args[1] else "";
    const job = jt.parseJobSpec(spec) orelse {
        posix.writeAll(2, "bg: no such job\n");
        return 1;
    };

    if (job.state != .stopped) {
        posix.writeAll(2, "bg: job is not stopped\n");
        return 1;
    }

    signals.sendSignal(job.pgid, signals.SIGCONT) catch {};
    job.state = .running;

    posix.writeAll(1, "[");
    var buf: [16]u8 = undefined;
    const id_str = std.fmt.bufPrint(&buf, "{d}", .{job.id}) catch "";
    posix.writeAll(1, id_str);
    posix.writeAll(1, "]  ");
    posix.writeAll(1, job.command);
    posix.writeAll(1, " &\n");
    return 0;
}

fn builtinAlias(args: []const []const u8, env: *Environment) u8 {
    if (args.len < 2) {
        var it = env.aliases.iterator();
        while (it.next()) |entry| {
            posix.writeAll(1, "alias ");
            posix.writeAll(1, entry.key_ptr.*);
            posix.writeAll(1, "='");
            posix.writeAll(1, entry.value_ptr.*);
            posix.writeAll(1, "'\n");
        }
        return 0;
    }

    var status: u8 = 0;
    for (args[1..]) |arg| {
        if (std.mem.indexOfScalar(u8, arg, '=')) |eq| {
            const name = arg[0..eq];
            const value = arg[eq + 1 ..];
            env.setAlias(name, value) catch {
                status = 1;
            };
        } else {
            if (env.getAlias(arg)) |val| {
                posix.writeAll(1, "alias ");
                posix.writeAll(1, arg);
                posix.writeAll(1, "='");
                posix.writeAll(1, val);
                posix.writeAll(1, "'\n");
            } else {
                posix.writeAll(2, "alias: ");
                posix.writeAll(2, arg);
                posix.writeAll(2, " not found\n");
                status = 1;
            }
        }
    }
    return status;
}

fn builtinUnalias(args: []const []const u8, env: *Environment) u8 {
    if (args.len < 2) {
        posix.writeAll(2, "unalias: usage: unalias [-a] name ...\n");
        return 2;
    }

    if (std.mem.eql(u8, args[1], "-a")) {
        env.clearAliases();
        return 0;
    }

    var status: u8 = 0;
    for (args[1..]) |name| {
        if (!env.removeAlias(name)) {
            posix.writeAll(2, "unalias: ");
            posix.writeAll(2, name);
            posix.writeAll(2, ": not found\n");
            status = 1;
        }
    }
    return status;
}

fn builtinHash(args: []const []const u8, env: *Environment) u8 {
    if (args.len < 2) {
        var it = env.command_hash.iterator();
        while (it.next()) |entry| {
            posix.writeAll(1, entry.value_ptr.*);
            posix.writeAll(1, "\n");
        }
        return 0;
    }

    if (std.mem.eql(u8, args[1], "-r")) {
        if (args.len > 2) {
            posix.writeAll(2, "hash: -r: too many arguments\n");
            return 1;
        }
        env.clearCommandHash();
        return 0;
    }

    if (std.mem.eql(u8, args[1], "-d")) {
        for (args[2..]) |name| {
            env.removeCachedCommand(name);
        }
        return 0;
    }

    if (std.mem.eql(u8, args[1], "-t")) {
        var status: u8 = 0;
        for (args[2..]) |name| {
            if (env.getCachedCommand(name)) |path| {
                posix.writeAll(1, path);
                posix.writeAll(1, "\n");
            } else {
                posix.writeAll(2, "hash: ");
                posix.writeAll(2, name);
                posix.writeAll(2, ": not found\n");
                status = 1;
            }
        }
        return status;
    }

    var status: u8 = 0;
    for (args[1..]) |name| {
        if (findInPath(name, env)) {
            const path_env = env.get("PATH") orelse "/usr/bin:/bin";
            var iter = std.mem.splitScalar(u8, path_env, ':');
            while (iter.next()) |dir| {
                var full_buf: [4096]u8 = undefined;
                const full = std.fmt.bufPrint(&full_buf, "{s}/{s}", .{ dir, name }) catch continue;
                const full_z = std.posix.toPosixPath(full) catch continue;
                if (posix.access(&full_z, 1)) {
                    env.cacheCommand(name, full) catch {};
                    break;
                }
            }
        } else {
            posix.writeAll(2, "hash: ");
            posix.writeAll(2, name);
            posix.writeAll(2, ": not found\n");
            status = 1;
        }
    }
    return status;
}

fn builtinFc(args: []const []const u8, env: *Environment) u8 {
    const history = env.history orelse {
        posix.writeAll(2, "fc: no history available\n");
        return 1;
    };
    if (history.count == 0) {
        posix.writeAll(2, "fc: no history\n");
        return 1;
    }

    var list_mode = false;
    var suppress_numbers = false;
    var reverse = false;
    var arg_start: usize = 1;

    while (arg_start < args.len) {
        const arg = args[arg_start];
        if (arg.len == 0 or arg[0] != '-') break;
        if (std.mem.eql(u8, arg, "--")) {
            arg_start += 1;
            break;
        }
        for (arg[1..]) |flag_c| {
            switch (flag_c) {
                'l' => list_mode = true,
                'n' => suppress_numbers = true,
                'r' => reverse = true,
                's' => {},
                else => {},
            }
        }
        arg_start += 1;
    }

    if (list_mode) {
        return fcList(args[arg_start..], history, suppress_numbers, reverse);
    }

    posix.writeAll(2, "fc: use fc -l to list or fc -s to re-execute\n");
    return 1;
}

pub fn fcResolveNum(spec: []const u8, count: usize) usize {
    if (std.fmt.parseInt(i64, spec, 10)) |n| {
        if (n < 0) {
            const abs: usize = @intCast(-n);
            if (abs >= count) return 1;
            return count - abs + 1;
        }
        const un: usize = @intCast(n);
        if (un > count) return count;
        if (un == 0) return 1;
        return un;
    } else |_| {}
    return count;
}

fn fcList(extra_args: []const []const u8, history: *const LineEditor.History, suppress_numbers: bool, reverse: bool) u8 {
    const count = history.count;
    var first: usize = if (count > 16) count - 16 + 1 else 1;
    var last: usize = count;

    if (extra_args.len >= 1) {
        first = fcResolveNum(extra_args[0], count);
    }
    if (extra_args.len >= 2) {
        last = fcResolveNum(extra_args[1], count);
    }

    if (first < 1) first = 1;
    if (last > count) last = count;
    if (first > last) {
        const tmp = first;
        first = last;
        last = tmp;
    }

    if (reverse) {
        var i: usize = last;
        while (i >= first) : (i -= 1) {
            if (history.entries[i - 1]) |entry| {
                if (!suppress_numbers) {
                    var num_buf: [16]u8 = undefined;
                    const num_str = std.fmt.bufPrint(&num_buf, "{d}\t", .{i}) catch continue;
                    posix.writeAll(1, num_str);
                }
                posix.writeAll(1, entry);
                posix.writeAll(1, "\n");
            }
            if (i == first) break;
        }
    } else {
        var i: usize = first;
        while (i <= last) : (i += 1) {
            if (history.entries[i - 1]) |entry| {
                if (!suppress_numbers) {
                    var num_buf: [16]u8 = undefined;
                    const num_str = std.fmt.bufPrint(&num_buf, "{d}\t", .{i}) catch continue;
                    posix.writeAll(1, num_str);
                }
                posix.writeAll(1, entry);
                posix.writeAll(1, "\n");
            }
        }
    }
    return 0;
}

pub fn fcGetReexecCommand(extra_args: []const []const u8, history: *const LineEditor.History) ?[]const u8 {
    var old_pat: ?[]const u8 = null;
    var new_pat: ?[]const u8 = null;
    var cmd_spec: ?[]const u8 = null;

    for (extra_args) |arg| {
        if (std.mem.indexOfScalar(u8, arg, '=')) |eq| {
            old_pat = arg[0..eq];
            new_pat = arg[eq + 1 ..];
        } else {
            cmd_spec = arg;
        }
    }

    const entry_idx = if (cmd_spec) |spec| fcResolveNum(spec, history.count) else history.count;
    if (entry_idx < 1 or entry_idx > history.count) {
        posix.writeAll(2, "fc: no such history entry\n");
        return null;
    }

    const entry = history.entries[entry_idx - 1] orelse {
        posix.writeAll(2, "fc: no such history entry\n");
        return null;
    };

    if (old_pat != null and new_pat != null) {
        var out_buf: [4096]u8 = undefined;
        var out_len: usize = 0;
        var j: usize = 0;
        while (j < entry.len and out_len < out_buf.len) {
            if (j + old_pat.?.len <= entry.len and std.mem.eql(u8, entry[j .. j + old_pat.?.len], old_pat.?)) {
                const remaining = out_buf.len - out_len;
                const copy_len = @min(new_pat.?.len, remaining);
                @memcpy(out_buf[out_len .. out_len + copy_len], new_pat.?[0..copy_len]);
                out_len += copy_len;
                j += old_pat.?.len;
            } else {
                out_buf[out_len] = entry[j];
                out_len += 1;
                j += 1;
            }
        }
        return out_buf[0..out_len];
    }
    return entry;
}

fn printTrapEntry(action: []const u8, name: []const u8) void {
    posix.writeAll(1, "trap -- '");
    posix.writeAll(1, action);
    posix.writeAll(1, "' ");
    posix.writeAll(1, name);
    posix.writeAll(1, "\n");
}

const trap_sig_entries = [_]struct { num: u6, name: []const u8 }{
    .{ .num = signals.SIGHUP, .name = "HUP" },
    .{ .num = signals.SIGINT, .name = "INT" },
    .{ .num = signals.SIGQUIT, .name = "QUIT" },
    .{ .num = signals.SIGABRT, .name = "ABRT" },
    .{ .num = signals.SIGALRM, .name = "ALRM" },
    .{ .num = signals.SIGTERM, .name = "TERM" },
    .{ .num = signals.SIGTSTP, .name = "TSTP" },
    .{ .num = signals.SIGCONT, .name = "CONT" },
    .{ .num = signals.SIGCHLD, .name = "CHLD" },
    .{ .num = signals.SIGUSR1, .name = "USR1" },
    .{ .num = signals.SIGUSR2, .name = "USR2" },
    .{ .num = signals.SIGPIPE, .name = "PIPE" },
};

fn printTraps() void {
    if (signals.getExitTrap()) |action| {
        printTrapEntry(action, "EXIT");
    }
    if (signals.getErrTrap()) |action| {
        printTrapEntry(action, "ERR");
    }
    for (trap_sig_entries) |entry| {
        if (signals.trap_handlers[@intCast(entry.num)]) |action| {
            printTrapEntry(action, entry.name);
        }
    }
}

fn printSpecificTrap(sig_name: []const u8) void {
    if (std.mem.eql(u8, sig_name, "EXIT") or std.mem.eql(u8, sig_name, "0")) {
        if (signals.getExitTrap()) |action| {
            printTrapEntry(action, "EXIT");
        }
        return;
    }
    if (std.mem.eql(u8, sig_name, "ERR")) {
        if (signals.getErrTrap()) |action| {
            printTrapEntry(action, "ERR");
        }
        return;
    }
    if (sigFromName(sig_name)) |sig| {
        if (signals.trap_handlers[@intCast(sig)]) |action| {
            const full_name = signals.sigFullName(sig) orelse sig_name;
            printTrapEntry(action, full_name);
        }
    }
}

fn builtinTimes(_: []const []const u8, _: *Environment) u8 {
    const self_ru = posix.getrusage(posix.RUSAGE_SELF);
    const children_ru = posix.getrusage(posix.RUSAGE_CHILDREN);

    const self_user_ms: u64 = @intCast(@divTrunc(self_ru.user_usec, 1000));
    const self_sys_ms: u64 = @intCast(@divTrunc(self_ru.sys_usec, 1000));
    const child_user_ms: u64 = @intCast(@divTrunc(children_ru.user_usec, 1000));
    const child_sys_ms: u64 = @intCast(@divTrunc(children_ru.sys_usec, 1000));

    var buf: [128]u8 = undefined;
    const line1 = std.fmt.bufPrint(&buf, "{d}m{d}.{d:0>3}s {d}m{d}.{d:0>3}s\n", .{
        @divTrunc(self_ru.user_sec, 60),
        @rem(self_ru.user_sec, 60),
        self_user_ms,
        @divTrunc(self_ru.sys_sec, 60),
        @rem(self_ru.sys_sec, 60),
        self_sys_ms,
    }) catch return 1;
    posix.writeAll(1, line1);

    var buf2: [128]u8 = undefined;
    const line2 = std.fmt.bufPrint(&buf2, "{d}m{d}.{d:0>3}s {d}m{d}.{d:0>3}s\n", .{
        @divTrunc(children_ru.user_sec, 60),
        @rem(children_ru.user_sec, 60),
        child_user_ms,
        @divTrunc(children_ru.sys_sec, 60),
        @rem(children_ru.sys_sec, 60),
        child_sys_ms,
    }) catch return 1;
    posix.writeAll(1, line2);
    return 0;
}

const rlimit_resource = libc.rlimit_resource;

const UlimitResource = struct {
    flag: u8,
    resource: rlimit_resource,
    name: []const u8,
    divisor: u64,
};

const ulimit_resources = [_]UlimitResource{
    .{ .flag = 'c', .resource = .CORE, .name = "core file size (blocks)", .divisor = 512 },
    .{ .flag = 'd', .resource = .DATA, .name = "data seg size (kbytes)", .divisor = 1024 },
    .{ .flag = 'f', .resource = .FSIZE, .name = "file size (blocks)", .divisor = 512 },
    .{ .flag = 'n', .resource = .NOFILE, .name = "open files", .divisor = 1 },
    .{ .flag = 's', .resource = .STACK, .name = "stack size (kbytes)", .divisor = 1024 },
    .{ .flag = 't', .resource = .CPU, .name = "cpu time (seconds)", .divisor = 1 },
    .{ .flag = 'v', .resource = .AS, .name = "virtual memory (kbytes)", .divisor = 1024 },
};

fn ulimitPrintValue(val: u64, divisor: u64) void {
    if (val == std.c.RLIM.INFINITY) {
        posix.writeAll(1, "unlimited\n");
    } else {
        var buf: [32]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d}\n", .{val / divisor}) catch return;
        posix.writeAll(1, s);
    }
}

fn builtinUlimit(args: []const []const u8, _: *Environment) u8 {
    var use_soft = true;
    var use_hard = false;
    var show_all = false;
    var resource_flag: u8 = 'f';
    var set_value: ?[]const u8 = null;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (arg.len >= 2 and arg[0] == '-') {
            for (arg[1..]) |flag_c| {
                switch (flag_c) {
                    'a' => show_all = true,
                    'S' => {
                        use_soft = true;
                        use_hard = false;
                    },
                    'H' => {
                        use_soft = false;
                        use_hard = true;
                    },
                    'c', 'd', 'f', 'n', 's', 't', 'v' => resource_flag = flag_c,
                    else => {
                        posix.writeAll(2, "ulimit: invalid option: -");
                        const ch_arr: [1]u8 = .{flag_c};
                        posix.writeAll(2, &ch_arr);
                        posix.writeAll(2, "\n");
                        return 2;
                    },
                }
            }
        } else {
            set_value = arg;
        }
    }

    if (show_all) {
        for (ulimit_resources) |res| {
            posix.writeAll(1, "-");
            const flag_arr: [1]u8 = .{res.flag};
            posix.writeAll(1, &flag_arr);
            posix.writeAll(1, ": ");
            posix.writeAll(1, res.name);
            var pad_buf: [40]u8 = undefined;
            const pad_needed = if (res.name.len < 30) 30 - res.name.len else 0;
            @memset(pad_buf[0..pad_needed], ' ');
            posix.writeAll(1, pad_buf[0..pad_needed]);
            const limits = std.posix.getrlimit(res.resource) catch {
                posix.writeAll(1, "error\n");
                continue;
            };
            const val = if (use_hard) limits.max else limits.cur;
            ulimitPrintValue(val, res.divisor);
        }
        return 0;
    }

    var target_res: ?UlimitResource = null;
    for (ulimit_resources) |res| {
        if (res.flag == resource_flag) {
            target_res = res;
            break;
        }
    }

    const res = target_res orelse {
        posix.writeAll(2, "ulimit: unknown resource\n");
        return 1;
    };

    if (set_value) |val_str| {
        var limits = std.posix.getrlimit(res.resource) catch {
            posix.writeAll(2, "ulimit: cannot get limit\n");
            return 1;
        };
        var new_val: u64 = undefined;
        if (std.mem.eql(u8, val_str, "unlimited")) {
            new_val = std.c.RLIM.INFINITY;
        } else {
            const parsed = std.fmt.parseInt(u64, val_str, 10) catch {
                posix.writeAll(2, "ulimit: invalid limit: ");
                posix.writeAll(2, val_str);
                posix.writeAll(2, "\n");
                return 1;
            };
            new_val = parsed * res.divisor;
        }
        if (use_hard) {
            limits.max = new_val;
        } else {
            limits.cur = new_val;
        }
        std.posix.setrlimit(res.resource, limits) catch {
            posix.writeAll(2, "ulimit: cannot modify limit\n");
            return 1;
        };
        return 0;
    }

    const limits = std.posix.getrlimit(res.resource) catch {
        posix.writeAll(2, "ulimit: cannot get limit\n");
        return 1;
    };
    const val = if (use_hard) limits.max else limits.cur;
    ulimitPrintValue(val, res.divisor);
    return 0;
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        const la = if (ca >= 'a' and ca <= 'z') ca - 32 else ca;
        const lb = if (cb >= 'a' and cb <= 'z') cb - 32 else cb;
        if (la != lb) return false;
    }
    return true;
}

fn sigFromName(name: []const u8) ?u6 {
    const trimmed = std.mem.trim(u8, name, " \t");
    if (std.fmt.parseInt(u6, trimmed, 10)) |n| {
        if (n >= 32) return null;
        return n;
    } else |_| {}
    const stripped = if (trimmed.len > 3 and eqlIgnoreCase(trimmed[0..3], "SIG")) trimmed[3..] else trimmed;
    if (eqlIgnoreCase(stripped, "EXIT")) return 0;
    if (eqlIgnoreCase(stripped, "HUP")) return 1;
    if (eqlIgnoreCase(stripped, "INT")) return 2;
    if (eqlIgnoreCase(stripped, "QUIT")) return 3;
    if (eqlIgnoreCase(stripped, "ILL")) return 4;
    if (eqlIgnoreCase(stripped, "TRAP")) return 5;
    if (eqlIgnoreCase(stripped, "ABRT")) return 6;
    if (eqlIgnoreCase(stripped, "BUS")) return 7;
    if (eqlIgnoreCase(stripped, "FPE")) return 8;
    if (eqlIgnoreCase(stripped, "KILL")) return 9;
    if (eqlIgnoreCase(stripped, "USR1")) return 10;
    if (eqlIgnoreCase(stripped, "SEGV")) return 11;
    if (eqlIgnoreCase(stripped, "USR2")) return 12;
    if (eqlIgnoreCase(stripped, "PIPE")) return 13;
    if (eqlIgnoreCase(stripped, "ALRM")) return 14;
    if (eqlIgnoreCase(stripped, "TERM")) return 15;
    if (eqlIgnoreCase(stripped, "CHLD")) return 17;
    if (eqlIgnoreCase(stripped, "CONT")) return 18;
    if (eqlIgnoreCase(stripped, "STOP")) return 19;
    if (eqlIgnoreCase(stripped, "TSTP")) return 20;
    if (eqlIgnoreCase(stripped, "TTIN")) return 21;
    if (eqlIgnoreCase(stripped, "TTOU")) return 22;
    if (eqlIgnoreCase(stripped, "URG")) return 23;
    if (eqlIgnoreCase(stripped, "XCPU")) return 24;
    if (eqlIgnoreCase(stripped, "XFSZ")) return 25;
    if (eqlIgnoreCase(stripped, "VTALRM")) return 26;
    if (eqlIgnoreCase(stripped, "PROF")) return 27;
    if (eqlIgnoreCase(stripped, "WINCH")) return 28;
    if (eqlIgnoreCase(stripped, "IO")) return 29;
    if (eqlIgnoreCase(stripped, "PWR")) return 30;
    if (eqlIgnoreCase(stripped, "SYS")) return 31;
    return null;
}

fn builtinHistory(args: []const []const u8, env: *Environment) u8 {
    if (args.len <= 1) return 0;
    if (args.len == 2) {
        const arg = args[1];
        if (std.mem.eql(u8, arg, "-c")) {
            if (env.history) |h| h.clear();
            return 0;
        }
        if (arg.len > 0 and arg[0] == '-') {
            posix.writeAll(2, "history: ");
            posix.writeAll(2, arg);
            posix.writeAll(2, ": invalid option\n");
            return 2;
        }
        if (std.fmt.parseInt(i64, arg, 10)) |_| {
            return 0;
        } else |_| {
            posix.writeAll(2, "history: ");
            posix.writeAll(2, arg);
            posix.writeAll(2, ": numeric argument required\n");
            return 2;
        }
    }
    posix.writeAll(2, "history: too many arguments\n");
    return 2;
}

fn builtinDeclare(args: []const []const u8, env: *Environment) u8 {
    if (args.len < 2) {
        var it = env.vars.iterator();
        while (it.next()) |entry| {
            posix.writeAll(1, entry.key_ptr.*);
            posix.writeAll(1, "=");
            setWriteValue(entry.value_ptr.value);
            posix.writeAll(1, "\n");
        }
        return 0;
    }
    var flags_export = false;
    var flags_readonly = false;
    var flags_integer = false;
    var flags_lowercase = false;
    var flags_uppercase = false;
    var flags_print = false;
    var flags_unset_attrs = false;
    var flags_func = false;
    var flags_func_names = false;
    var has_export = false;
    var has_readonly = false;
    var has_integer = false;
    var has_lowercase = false;
    var has_uppercase = false;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (arg.len < 2 or (arg[0] != '-' and arg[0] != '+')) break;
        if (std.mem.eql(u8, arg, "--")) {
            i += 1;
            break;
        }
        const removing = arg[0] == '+';
        if (removing) flags_unset_attrs = true;
        for (arg[1..]) |ch| {
            switch (ch) {
                'x' => {
                    has_export = true;
                    flags_export = !removing;
                },
                'r' => {
                    has_readonly = true;
                    flags_readonly = !removing;
                },
                'i' => {
                    has_integer = true;
                    flags_integer = !removing;
                },
                'p' => flags_print = true,
                'f' => flags_func = true,
                'F' => flags_func_names = true,
                'l' => {
                    has_lowercase = true;
                    flags_lowercase = !removing;
                },
                'u' => {
                    has_uppercase = true;
                    flags_uppercase = !removing;
                },
                'a', 'A', 'n', 'g', 't' => {},
                else => {},
            }
        }
    }

    if (flags_func_names or (flags_func and flags_print)) {
        if (i >= args.len) {
            var fit = env.functions.iterator();
            while (fit.next()) |entry| {
                posix.writeAll(1, "declare -f ");
                posix.writeAll(1, entry.key_ptr.*);
                posix.writeAll(1, "\n");
            }
            return 0;
        }
        var status: u8 = 0;
        while (i < args.len) : (i += 1) {
            if (env.functions.get(args[i])) |_| {
                posix.writeAll(1, "declare -f ");
                posix.writeAll(1, args[i]);
                posix.writeAll(1, "\n");
            } else {
                status = 1;
            }
        }
        return status;
    }
    if (flags_func and i < args.len) {
        var status: u8 = 0;
        while (i < args.len) : (i += 1) {
            if (env.functions.get(args[i])) |fdef| {
                posix.writeAll(1, args[i]);
                posix.writeAll(1, " () {\n  ");
                posix.writeAll(1, fdef.source);
                posix.writeAll(1, "\n}\n");
            } else {
                status = 1;
            }
        }
        return status;
    }

    if (flags_print and i >= args.len) {
        var it = env.vars.iterator();
        while (it.next()) |entry| {
            posix.writeAll(1, "declare ");
            if (entry.value_ptr.exported) posix.writeAll(1, "-x ");
            if (entry.value_ptr.readonly) posix.writeAll(1, "-r ");
            if (entry.value_ptr.integer) posix.writeAll(1, "-i ");
            posix.writeAll(1, "-- ");
            posix.writeAll(1, entry.key_ptr.*);
            posix.writeAll(1, "=");
            setWriteValue(entry.value_ptr.value);
            posix.writeAll(1, "\n");
        }
        return 0;
    }
    if (flags_print) {
        var status: u8 = 0;
        while (i < args.len) : (i += 1) {
            const name = args[i];
            if (env.get(name)) |val| {
                posix.writeAll(1, "declare ");
                if (env.vars.get(name)) |v| {
                    if (v.exported) posix.writeAll(1, "-x ");
                    if (v.readonly) posix.writeAll(1, "-r ");
                    if (v.integer) posix.writeAll(1, "-i ");
                }
                posix.writeAll(1, "-- ");
                posix.writeAll(1, name);
                posix.writeAll(1, "=");
                setWriteValue(val);
                posix.writeAll(1, "\n");
            } else {
                posix.writeAll(2, "declare: ");
                posix.writeAll(2, name);
                posix.writeAll(2, ": not found\n");
                status = 1;
            }
        }
        return status;
    }

    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.indexOf(u8, arg, "=")) |eq| {
            const is_append = eq > 0 and arg[eq - 1] == '+';
            const name = if (is_append) arg[0 .. eq - 1] else arg[0..eq];
            if (!isValidVarName(name)) {
                posix.writeAll(2, args[0]);
                posix.writeAll(2, ": `");
                posix.writeAll(2, arg);
                posix.writeAll(2, "': not a valid identifier\n");
                env.should_exit = true;
                env.exit_value = 2;
                return 2;
            }
            var val = arg[eq + 1 ..];
            if (is_append) {
                const existing = env.get(name) orelse "";
                val = std.fmt.allocPrint(env.alloc, "{s}{s}", .{ existing, val }) catch val;
            }
            if (flags_integer) {
                val = declareEvalInt(val, env);
            }
            if (flags_lowercase or flags_uppercase) {
                if (env.vars.getPtr(name)) |v| {
                    v.lowercase = flags_lowercase;
                    v.uppercase = flags_uppercase;
                } else {
                    env.set(name, "", flags_export) catch {};
                    if (env.vars.getPtr(name)) |v| {
                        v.lowercase = flags_lowercase;
                        v.uppercase = flags_uppercase;
                    }
                }
            }
            env.set(name, val, flags_export) catch {};
            if (flags_integer) {
                if (env.vars.getPtr(name)) |v| v.integer = true;
            }
            if (flags_readonly) {
                if (env.vars.getPtr(name)) |v| v.readonly = true;
            }
        } else {
            if (flags_unset_attrs) {
                if (env.vars.getPtr(arg)) |v| {
                    if (has_integer) v.integer = false;
                    if (has_export) v.exported = false;
                    if (has_readonly) v.readonly = false;
                    if (has_lowercase) v.lowercase = false;
                    if (has_uppercase) v.uppercase = false;
                }
            } else {
                if (env.vars.getPtr(arg)) |v| {
                    if (flags_export) v.exported = true;
                    if (flags_readonly) v.readonly = true;
                    if (flags_integer) v.integer = true;
                    if (flags_lowercase) { v.lowercase = true; v.uppercase = false; }
                    if (flags_uppercase) { v.uppercase = true; v.lowercase = false; }
                } else {
                    env.set(arg, "", flags_export) catch {};
                    if (flags_integer) {
                        if (env.vars.getPtr(arg)) |v| v.integer = true;
                    }
                    if (flags_readonly) {
                        if (env.vars.getPtr(arg)) |v| v.readonly = true;
                    }
                    if (flags_lowercase) {
                        if (env.vars.getPtr(arg)) |v| { v.lowercase = true; v.uppercase = false; }
                    }
                    if (flags_uppercase) {
                        if (env.vars.getPtr(arg)) |v| { v.uppercase = true; v.lowercase = false; }
                    }
                }
            }
        }
    }
    return 0;
}

fn declareEvalInt(val: []const u8, env: *Environment) []const u8 {
    if (val.len == 0) return "0";
    const Arithmetic = @import("arithmetic.zig").Arithmetic;
    const lookup_fn = struct {
        var e: *Environment = undefined;
        fn f(name: []const u8) ?[]const u8 {
            return e.get(name);
        }
        fn setter(name: []const u8, v: i64) void {
            var buf: [32]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{d}", .{v}) catch return;
            e.set(name, s, false) catch {};
        }
    };
    lookup_fn.e = env;
    const result = Arithmetic.evaluateWithSetter(val, &lookup_fn.f, &lookup_fn.setter) catch return val;
    var buf: [32]u8 = undefined;
    return std.fmt.bufPrint(&buf, "{d}", .{result}) catch val;
}

fn builtinLet(args: []const []const u8, env: *Environment) u8 {
    if (args.len < 2) return 1;
    const lookup_env = struct {
        var e: *Environment = undefined;
        fn f(name: []const u8) ?[]const u8 {
            return e.get(name);
        }
        fn setter(name: []const u8, val: i64) void {
            var buf: [32]u8 = undefined;
            const val_str = std.fmt.bufPrint(&buf, "{d}", .{val}) catch return;
            e.set(name, val_str, false) catch {};
        }
    };
    lookup_env.e = env;
    var result: i64 = 0;
    for (args[1..]) |expr| {
        result = @import("arithmetic.zig").Arithmetic.evaluateWithSetter(expr, &lookup_env.f, &lookup_env.setter) catch return 1;
    }
    return if (result != 0) 0 else 1;
}

const ShoptMode = enum { none, set, unset, query, print };

fn builtinShopt(args: []const []const u8, env: *Environment) u8 {
    const Env = @import("env.zig").Environment;
    var set_mode: ShoptMode = .none;
    var use_set_o = false;
    var arg_start: usize = 1;

    while (arg_start < args.len) {
        const a = args[arg_start];
        if (a.len >= 2 and a[0] == '-') {
            for (a[1..]) |ch| {
                switch (ch) {
                    's' => set_mode = .set,
                    'u' => set_mode = .unset,
                    'q' => set_mode = .query,
                    'p' => set_mode = .print,
                    'o' => use_set_o = true,
                    else => {
                        posix.writeAll(2, "shopt: invalid option: -");
                        const arr: [1]u8 = .{ch};
                        posix.writeAll(2, &arr);
                        posix.writeAll(2, "\n");
                        return 2;
                    },
                }
            }
            arg_start += 1;
        } else break;
    }

    const opt_names = args[arg_start..];

    if (use_set_o) {
        return shoptSetO(opt_names, set_mode, env);
    }

    if (opt_names.len == 0) {
        const pm = if (set_mode == .print) set_mode else .print;
        _ = pm;
        const fields = [_]struct { name: []const u8, val: *bool }{
            .{ .name = "autocd", .val = &env.shopt.autocd },
            .{ .name = "cdable_vars", .val = &env.shopt.cdable_vars },
            .{ .name = "checkwinsize", .val = &env.shopt.checkwinsize },
            .{ .name = "dotglob", .val = &env.shopt.dotglob },
            .{ .name = "expand_aliases", .val = &env.shopt.expand_aliases },
            .{ .name = "extglob", .val = &env.shopt.extglob },
            .{ .name = "failglob", .val = &env.shopt.failglob },
            .{ .name = "globstar", .val = &env.shopt.globstar },
            .{ .name = "inherit_errexit", .val = &env.shopt.inherit_errexit },
            .{ .name = "lastpipe", .val = &env.shopt.lastpipe },
            .{ .name = "nocaseglob", .val = &env.shopt.nocaseglob },
            .{ .name = "nocasematch", .val = &env.shopt.nocasematch },
            .{ .name = "nullglob", .val = &env.shopt.nullglob },
        };
        var any_off = false;
        for (fields) |f| {
            if (set_mode == .set and !f.val.*) continue;
            if (set_mode == .unset and f.val.*) continue;
            if (set_mode != .query) {
                posix.writeAll(1, "shopt ");
                posix.writeAll(1, if (f.val.*) "-s " else "-u ");
                posix.writeAll(1, f.name);
                posix.writeAll(1, "\n");
            }
            if (!f.val.*) any_off = true;
        }
        if (set_mode == .query) return if (any_off) 1 else 0;
        return 0;
    }

    var status: u8 = 0;
    for (opt_names) |name| {
        if (shoptGetField(&env.shopt, name)) |ptr| {
            switch (set_mode) {
                .set => ptr.* = true,
                .unset => ptr.* = false,
                .query => {
                    if (!ptr.*) status = 1;
                },
                .print, .none => {
                    posix.writeAll(1, "shopt ");
                    posix.writeAll(1, if (ptr.*) "-s " else "-u ");
                    posix.writeAll(1, name);
                    posix.writeAll(1, "\n");
                },
            }
        } else {
            if (env.shopt.ignore_shopt_not_impl) {
                status = 2;
                continue;
            }
            if (set_mode == .query) {
                status = 2;
            } else {
                posix.writeAll(2, "shopt: ");
                posix.writeAll(2, name);
                posix.writeAll(2, ": invalid shell option name\n");
                status = if (set_mode == .set or set_mode == .unset) 1 else 2;
            }
        }
    }
    _ = Env;
    return status;
}

fn shoptGetField(shopt: *@import("env.zig").Environment.ShoptOptions, name: []const u8) ?*bool {
    const fields = .{
        .{ "nullglob", &shopt.nullglob },
        .{ "failglob", &shopt.failglob },
        .{ "extglob", &shopt.extglob },
        .{ "dotglob", &shopt.dotglob },
        .{ "globstar", &shopt.globstar },
        .{ "lastpipe", &shopt.lastpipe },
        .{ "expand_aliases", &shopt.expand_aliases },
        .{ "nocaseglob", &shopt.nocaseglob },
        .{ "nocasematch", &shopt.nocasematch },
        .{ "inherit_errexit", &shopt.inherit_errexit },
        .{ "autocd", &shopt.autocd },
        .{ "cdable_vars", &shopt.cdable_vars },
        .{ "checkwinsize", &shopt.checkwinsize },
        .{ "ignore_shopt_not_impl", &shopt.ignore_shopt_not_impl },
    };
    inline for (fields) |f| {
        if (std.mem.eql(u8, name, f[0])) return f[1];
    }
    return null;
}

fn shoptSetO(opt_names: []const []const u8, mode: ShoptMode, env: *Environment) u8 {
    if (opt_names.len == 0) {
        const fields = [_]struct { name: []const u8, val: bool }{
            .{ .name = "allexport", .val = env.options.allexport },
            .{ .name = "errexit", .val = env.options.errexit },
            .{ .name = "monitor", .val = env.options.monitor },
            .{ .name = "noclobber", .val = env.options.noclobber },
            .{ .name = "noexec", .val = env.options.noexec },
            .{ .name = "noglob", .val = env.options.noglob },
            .{ .name = "nounset", .val = env.options.nounset },
            .{ .name = "verbose", .val = env.options.verbose },
            .{ .name = "xtrace", .val = env.options.xtrace },
        };
        for (fields) |f| {
            if (mode == .set and !f.val) continue;
            if (mode == .unset and f.val) continue;
            posix.writeAll(1, "set ");
            posix.writeAll(1, if (f.val) "-o " else "+o ");
            posix.writeAll(1, f.name);
            posix.writeAll(1, "\n");
        }
        return 0;
    }

    var status: u8 = 0;
    for (opt_names) |name| {
        const ptr: ?*bool = if (std.mem.eql(u8, name, "allexport")) &env.options.allexport
            else if (std.mem.eql(u8, name, "errexit")) &env.options.errexit
            else if (std.mem.eql(u8, name, "monitor")) &env.options.monitor
            else if (std.mem.eql(u8, name, "noclobber")) &env.options.noclobber
            else if (std.mem.eql(u8, name, "noexec")) &env.options.noexec
            else if (std.mem.eql(u8, name, "noglob")) &env.options.noglob
            else if (std.mem.eql(u8, name, "nounset")) &env.options.nounset
            else if (std.mem.eql(u8, name, "verbose")) &env.options.verbose
            else if (std.mem.eql(u8, name, "xtrace")) &env.options.xtrace
            else null;

        if (ptr) |p| {
            switch (mode) {
                .set => p.* = true,
                .unset => p.* = false,
                .query => {
                    if (!p.*) status = 1;
                },
                .print, .none => {
                    posix.writeAll(1, "set ");
                    posix.writeAll(1, if (p.*) "-o " else "+o ");
                    posix.writeAll(1, name);
                    posix.writeAll(1, "\n");
                },
            }
        } else {
            posix.writeAll(2, "shopt: ");
            posix.writeAll(2, name);
            posix.writeAll(2, ": invalid option name\n");
            status = 1;
        }
    }
    return status;
}

test "printfProcessEscape basic sequences" {
    const testing = std.testing;
    try testing.expectEqual(@as(u8, '\n'), printfProcessEscape("\\n").byte);
    try testing.expectEqual(@as(usize, 2), printfProcessEscape("\\n").advance);
    try testing.expectEqual(@as(u8, '\t'), printfProcessEscape("\\t").byte);
    try testing.expectEqual(@as(u8, '\\'), printfProcessEscape("\\\\").byte);
    try testing.expectEqual(@as(u8, 0x07), printfProcessEscape("\\a").byte);
    try testing.expectEqual(@as(u8, 0x08), printfProcessEscape("\\b").byte);
    try testing.expectEqual(@as(u8, '\r'), printfProcessEscape("\\r").byte);
}

test "printfProcessEscape octal" {
    const testing = std.testing;
    const result = printfProcessEscape("\\101");
    try testing.expectEqual(@as(u8, 'A'), result.byte);
    try testing.expectEqual(@as(usize, 4), result.advance);

    const r2 = printfProcessEscape("\\0");
    try testing.expectEqual(@as(u8, 0), r2.byte);

    const r3 = printfProcessEscape("\\044");
    try testing.expectEqual(@as(u8, '$'), r3.byte);
    try testing.expectEqual(@as(usize, 4), r3.advance);

    const r4 = printfProcessEscape("\\0377");
    try testing.expectEqual(@as(u8, 31), r4.byte);
    try testing.expectEqual(@as(usize, 4), r4.advance);

    const r5 = printfProcessEscape("\\377");
    try testing.expectEqual(@as(u8, 255), r5.byte);
    try testing.expectEqual(@as(usize, 4), r5.advance);
}

test "printfProcessEscape hex" {
    const testing = std.testing;
    const result = printfProcessEscape("\\x41");
    try testing.expectEqual(@as(u8, 'A'), result.byte);
    try testing.expectEqual(@as(usize, 4), result.advance);

    const r2 = printfProcessEscape("\\x6e");
    try testing.expectEqual(@as(u8, 'n'), r2.byte);
}

test "printfParseSpec flags and width" {
    const testing = std.testing;
    const s1 = printfParseSpec("%d");
    try testing.expectEqual(@as(u8, 'd'), s1.conversion);
    try testing.expectEqual(@as(usize, 0), s1.width);
    try testing.expectEqual(false, s1.flag_minus);

    const s2 = printfParseSpec("%-10s");
    try testing.expectEqual(@as(u8, 's'), s2.conversion);
    try testing.expectEqual(@as(usize, 10), s2.width);
    try testing.expectEqual(true, s2.flag_minus);

    const s3 = printfParseSpec("%05d");
    try testing.expectEqual(@as(u8, 'd'), s3.conversion);
    try testing.expectEqual(@as(usize, 5), s3.width);
    try testing.expectEqual(true, s3.flag_zero);

    const s4 = printfParseSpec("%.3s");
    try testing.expectEqual(@as(u8, 's'), s4.conversion);
    try testing.expectEqual(@as(?usize, 3), s4.precision);

    const s5 = printfParseSpec("%*d");
    try testing.expectEqual(true, s5.width_star);
    try testing.expectEqual(@as(u8, 'd'), s5.conversion);

    const s6 = printfParseSpec("%+d");
    try testing.expectEqual(true, s6.flag_plus);

    const s7 = printfParseSpec("%#x");
    try testing.expectEqual(true, s7.flag_hash);
}

test "printfParseNumericArg" {
    const testing = std.testing;
    var err = false;

    try testing.expectEqual(@as(i64, 42), printfParseNumericArg("42", &err));
    try testing.expectEqual(false, err);

    try testing.expectEqual(@as(i64, 0x1F), printfParseNumericArg("0x1F", &err));
    try testing.expectEqual(false, err);

    try testing.expectEqual(@as(i64, 65), printfParseNumericArg("'A", &err));
    try testing.expectEqual(false, err);

    try testing.expectEqual(@as(i64, -10), printfParseNumericArg("-10", &err));
    try testing.expectEqual(false, err);

    try testing.expectEqual(@as(i64, 0), printfParseNumericArg("", &err));
    try testing.expectEqual(false, err);
}

test "IFS helpers" {
    const testing = std.testing;
    const default_ifs = " \t\n";

    try testing.expectEqual(true, isIfsWhitespace(' ', default_ifs));
    try testing.expectEqual(true, isIfsWhitespace('\t', default_ifs));
    try testing.expectEqual(true, isIfsWhitespace('\n', default_ifs));
    try testing.expectEqual(false, isIfsWhitespace(':', default_ifs));

    try testing.expectEqual(false, isIfsNonWhitespace(' ', default_ifs));
    try testing.expectEqual(false, isIfsNonWhitespace('\t', default_ifs));

    const colon_ifs = ":";
    try testing.expectEqual(true, isIfsNonWhitespace(':', colon_ifs));
    try testing.expectEqual(false, isIfsWhitespace(':', colon_ifs));
    try testing.expectEqual(true, isIfsChar(':', colon_ifs));
    try testing.expectEqual(false, isIfsChar(' ', colon_ifs));

    const mixed_ifs = " :\t";
    try testing.expectEqual(true, isIfsWhitespace(' ', mixed_ifs));
    try testing.expectEqual(true, isIfsNonWhitespace(':', mixed_ifs));
    try testing.expectEqual(true, isIfsChar(':', mixed_ifs));
    try testing.expectEqual(true, isIfsChar(' ', mixed_ifs));
}
