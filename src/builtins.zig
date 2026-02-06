const std = @import("std");
const Environment = @import("env.zig").Environment;
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
});

pub fn lookup(name: []const u8) ?BuiltinFn {
    return builtins.get(name);
}

fn writeAll(fd: i32, data: []const u8) void {
    posix.writeAll(fd, data);
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
        code = std.fmt.parseInt(u8, args[1], 10) catch env.last_exit_status;
    }
    env.should_exit = true;
    env.exit_value = code;
    return code;
}

fn builtinCd(args: []const []const u8, env: *Environment) u8 {
    const target = if (args.len > 1)
        args[1]
    else
        env.get("HOME") orelse {
            writeAll(2, "cd: HOME not set\n");
            return 1;
        };

    var old_buf: [4096]u8 = undefined;
    const old_pwd = posix.getcwd(&old_buf) catch null;

    posix.chdir(target) catch {
        writeAll(2, "cd: ");
        writeAll(2, target);
        writeAll(2, ": No such file or directory\n");
        return 1;
    };

    if (old_pwd) |pwd| {
        env.set("OLDPWD", pwd, false) catch {};
    }

    var new_buf: [4096]u8 = undefined;
    const new_pwd = posix.getcwd(&new_buf) catch null;
    if (new_pwd) |pwd| {
        env.set("PWD", pwd, false) catch {};
    }

    return 0;
}

fn builtinPwd(_: []const []const u8, _: *Environment) u8 {
    var buf: [4096]u8 = undefined;
    const cwd = posix.getcwd(&buf) catch {
        writeAll(2, "pwd: error getting current directory\n");
        return 1;
    };
    writeAll(1, cwd);
    writeAll(1, "\n");
    return 0;
}

fn builtinExport(args: []const []const u8, env: *Environment) u8 {
    if (args.len < 2) return 0;

    for (args[1..]) |arg| {
        if (std.mem.indexOfScalar(u8, arg, '=')) |eq| {
            const name = arg[0..eq];
            const value = arg[eq + 1 ..];
            env.set(name, value, true) catch return 1;
        } else {
            env.markExported(arg);
        }
    }
    return 0;
}

fn builtinUnset(args: []const []const u8, env: *Environment) u8 {
    for (args[1..]) |name| {
        env.unset(name);
    }
    return 0;
}

fn builtinSet(args: []const []const u8, env: *Environment) u8 {
    if (args.len < 2) return 0;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (arg.len < 2 or (arg[0] != '-' and arg[0] != '+')) break;
        const enable = arg[0] == '-';
        for (arg[1..]) |c| {
            switch (c) {
                'e' => env.options.errexit = enable,
                'u' => env.options.nounset = enable,
                'x' => env.options.xtrace = enable,
                'f' => env.options.noglob = enable,
                'n' => env.options.noexec = enable,
                'a' => env.options.allexport = enable,
                'v' => env.options.verbose = enable,
                'C' => env.options.noclobber = enable,
                'm' => env.options.monitor = enable,
                else => {},
            }
        }
    }

    if (i < args.len and std.mem.eql(u8, args[i], "--")) {
        i += 1;
    }

    if (i < args.len) {
        env.positional_params = args[i..];
    }
    return 0;
}

fn builtinShift(args: []const []const u8, env: *Environment) u8 {
    var n: usize = 1;
    if (args.len > 1) {
        n = std.fmt.parseInt(usize, args[1], 10) catch return 1;
    }
    if (n > env.positional_params.len) return 1;
    env.positional_params = env.positional_params[n..];
    return 0;
}

fn builtinReturn(args: []const []const u8, env: *Environment) u8 {
    var val: u8 = env.last_exit_status;
    if (args.len > 1) {
        val = std.fmt.parseInt(u8, args[1], 10) catch env.last_exit_status;
    }
    env.should_return = true;
    env.return_value = val;
    return val;
}

fn builtinBreak(args: []const []const u8, env: *Environment) u8 {
    var n: u32 = 1;
    if (args.len > 1) {
        n = std.fmt.parseInt(u32, args[1], 10) catch 1;
    }
    if (n == 0) n = 1;
    env.break_count = n;
    return 0;
}

fn builtinContinue(args: []const []const u8, env: *Environment) u8 {
    var n: u32 = 1;
    if (args.len > 1) {
        n = std.fmt.parseInt(u32, args[1], 10) catch 1;
    }
    if (n == 0) n = 1;
    env.continue_count = n;
    return 0;
}

fn builtinEcho(args: []const []const u8, _: *Environment) u8 {
    var i: usize = 1;
    var no_newline = false;

    if (i < args.len and std.mem.eql(u8, args[i], "-n")) {
        no_newline = true;
        i += 1;
    }

    while (i < args.len) : (i += 1) {
        if (i > 1 and (if (no_newline) i > 2 else i > 1)) writeAll(1, " ");
        writeAll(1, args[i]);
    }
    if (!no_newline) writeAll(1, "\n");
    return 0;
}

fn builtinTest(args: []const []const u8, _: *Environment) u8 {
    const effective_args = if (args.len > 0 and std.mem.eql(u8, args[0], "[")) blk: {
        if (args.len < 2 or !std.mem.eql(u8, args[args.len - 1], "]")) {
            writeAll(2, "[: missing ]\n");
            return 2;
        }
        break :blk args[1 .. args.len - 1];
    } else args[1..];

    if (effective_args.len == 0) return 1;

    if (effective_args.len == 1) {
        return if (effective_args[0].len > 0) 0 else 1;
    }

    if (effective_args.len == 2) {
        if (std.mem.eql(u8, effective_args[0], "!")) {
            return if (effective_args[1].len > 0) 1 else 0;
        }
        if (std.mem.eql(u8, effective_args[0], "-n")) {
            return if (effective_args[1].len > 0) 0 else 1;
        }
        if (std.mem.eql(u8, effective_args[0], "-z")) {
            return if (effective_args[1].len == 0) 0 else 1;
        }
        if (std.mem.eql(u8, effective_args[0], "-e") or std.mem.eql(u8, effective_args[0], "-f")) {
            const path_z = std.posix.toPosixPath(effective_args[1]) catch return 1;
            _ = posix.stat(&path_z) catch return 1;
            return 0;
        }
        if (std.mem.eql(u8, effective_args[0], "-d")) {
            const path_z = std.posix.toPosixPath(effective_args[1]) catch return 1;
            const st = posix.stat(&path_z) catch return 1;
            return if (st.mode & posix.S_IFMT == posix.S_IFDIR) 0 else 1;
        }
    }

    if (effective_args.len == 3) {
        if (std.mem.eql(u8, effective_args[1], "=") or std.mem.eql(u8, effective_args[1], "==")) {
            return if (std.mem.eql(u8, effective_args[0], effective_args[2])) 0 else 1;
        }
        if (std.mem.eql(u8, effective_args[1], "!=")) {
            return if (!std.mem.eql(u8, effective_args[0], effective_args[2])) 0 else 1;
        }

        const lhs = std.fmt.parseInt(i64, effective_args[0], 10) catch return 2;
        const rhs = std.fmt.parseInt(i64, effective_args[2], 10) catch return 2;

        if (std.mem.eql(u8, effective_args[1], "-eq")) return if (lhs == rhs) 0 else 1;
        if (std.mem.eql(u8, effective_args[1], "-ne")) return if (lhs != rhs) 0 else 1;
        if (std.mem.eql(u8, effective_args[1], "-lt")) return if (lhs < rhs) 0 else 1;
        if (std.mem.eql(u8, effective_args[1], "-le")) return if (lhs <= rhs) 0 else 1;
        if (std.mem.eql(u8, effective_args[1], "-gt")) return if (lhs > rhs) 0 else 1;
        if (std.mem.eql(u8, effective_args[1], "-ge")) return if (lhs >= rhs) 0 else 1;
    }

    return 2;
}

fn builtinJobs(_: []const []const u8, env: *Environment) u8 {
    const jt = env.job_table orelse return 1;
    for (&jt.jobs.*) |*slot| {
        if (slot.*) |*job| {
            var buf: [16]u8 = undefined;
            const id_str = std.fmt.bufPrint(&buf, "[{d}]", .{job.id}) catch "";
            writeAll(1, id_str);
            const state_str = switch (job.state) {
                .running => "  Running\t\t",
                .stopped => "  Stopped\t\t",
                .done => "  Done\t\t",
            };
            writeAll(1, state_str);
            writeAll(1, job.command);
            writeAll(1, "\n");
        }
    }
    return 0;
}

fn builtinWait(args: []const []const u8, env: *Environment) u8 {
    if (args.len > 1) {
        const pid = std.fmt.parseInt(posix.pid_t, args[1], 10) catch return 127;
        const result = posix.waitpid(pid, 0);
        if (result.pid <= 0) return 127;
        const status = if (result.status & 0x7f == 0)
            @as(u8, @truncate((result.status >> 8) & 0xff))
        else
            @as(u8, @truncate(128 + (result.status & 0x7f)));
        return status;
    }
    while (true) {
        const result = posix.waitpid(-1, 0);
        if (result.pid <= 0) break;
    }
    _ = env;
    return 0;
}

fn builtinKill(args: []const []const u8, _: *Environment) u8 {
    if (args.len < 2) {
        writeAll(2, "kill: usage: kill [-s signal] pid ...\n");
        return 2;
    }

    var sig: u6 = signals.SIGTERM;
    var start: usize = 1;

    if (args.len > 2 and args[1].len > 1 and args[1][0] == '-') {
        const sig_str = args[1][1..];
        sig = std.fmt.parseInt(u6, sig_str, 10) catch signals.SIGTERM;
        start = 2;
    }

    for (args[start..]) |arg| {
        const pid = std.fmt.parseInt(posix.pid_t, arg, 10) catch {
            writeAll(2, "kill: invalid pid: ");
            writeAll(2, arg);
            writeAll(2, "\n");
            continue;
        };
        signals.sendSignal(pid, sig) catch {
            writeAll(2, "kill: failed to send signal\n");
        };
    }
    return 0;
}

fn builtinTrap(args: []const []const u8, _: *Environment) u8 {
    if (args.len < 3) {
        if (args.len == 2 and std.mem.eql(u8, args[1], "-l")) {
            writeAll(1, "HUP INT QUIT TERM USR1 USR2\n");
            return 0;
        }
        return 0;
    }

    const action = args[1];
    for (args[2..]) |sig_name| {
        const sig = sigFromName(sig_name) orelse {
            writeAll(2, "trap: invalid signal: ");
            writeAll(2, sig_name);
            writeAll(2, "\n");
            continue;
        };
        if (std.mem.eql(u8, action, "-") or std.mem.eql(u8, action, "")) {
            signals.setTrap(sig, null);
        } else {
            signals.setTrap(sig, action);
        }
    }
    return 0;
}

fn builtinReadonly(args: []const []const u8, env: *Environment) u8 {
    if (args.len < 2) return 0;
    for (args[1..]) |arg| {
        if (std.mem.indexOfScalar(u8, arg, '=')) |eq| {
            const name = arg[0..eq];
            const value = arg[eq + 1 ..];
            env.set(name, value, false) catch return 1;
            env.markReadonly(name);
        } else {
            env.markReadonly(arg);
        }
    }
    return 0;
}

fn builtinRead(args: []const []const u8, env: *Environment) u8 {
    if (args.len < 2) {
        writeAll(2, "read: missing variable name\n");
        return 1;
    }

    var buf: [4096]u8 = undefined;
    var total: usize = 0;
    while (total < buf.len) {
        const n = posix.read(0, buf[total .. total + 1]) catch return 1;
        if (n == 0) {
            if (total == 0) return 1;
            break;
        }
        if (buf[total] == '\n') break;
        total += 1;
    }

    const line = buf[0..total];
    const var_names = args[1..];

    if (var_names.len == 1) {
        env.set(var_names[0], line, false) catch return 1;
        return 0;
    }

    var field_start: usize = 0;
    var var_idx: usize = 0;
    var i: usize = 0;
    while (var_idx < var_names.len - 1 and i < line.len) {
        while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
        field_start = i;
        while (i < line.len and line[i] != ' ' and line[i] != '\t') : (i += 1) {}
        env.set(var_names[var_idx], line[field_start..i], false) catch return 1;
        var_idx += 1;
    }
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
    if (var_idx < var_names.len) {
        env.set(var_names[var_idx], line[i..], false) catch return 1;
        var_idx += 1;
    }
    while (var_idx < var_names.len) : (var_idx += 1) {
        env.set(var_names[var_idx], "", false) catch return 1;
    }
    return 0;
}

fn builtinUmask(args: []const []const u8, _: *Environment) u8 {
    if (args.len < 2) {
        const current = libc.umask(0);
        _ = libc.umask(current);
        var buf: [8]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{o:0>4}\n", .{current}) catch return 1;
        writeAll(1, s);
        return 0;
    }
    const new_mask = std.fmt.parseInt(c_uint, args[1], 8) catch {
        writeAll(2, "umask: invalid mask\n");
        return 1;
    };
    _ = libc.umask(new_mask);
    return 0;
}

fn builtinType(args: []const []const u8, env: *Environment) u8 {
    if (args.len < 2) return 0;
    var status: u8 = 0;
    for (args[1..]) |name| {
        if (builtins.get(name) != null) {
            writeAll(1, name);
            writeAll(1, " is a shell builtin\n");
        } else if (env.functions.get(name) != null) {
            writeAll(1, name);
            writeAll(1, " is a shell function\n");
        } else if (findInPath(name, env)) {
            writeAll(1, name);
            writeAll(1, " is ");
            writeAll(1, name);
            writeAll(1, "\n");
        } else {
            writeAll(2, name);
            writeAll(2, ": not found\n");
            status = 1;
        }
    }
    return status;
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

fn builtinGetopts(args: []const []const u8, env: *Environment) u8 {
    if (args.len < 3) {
        writeAll(2, "getopts: usage: getopts optstring name [arg ...]\n");
        return 2;
    }
    const optstring = args[1];
    const varname = args[2];
    const params = if (args.len > 3) args[3..] else env.positional_params;

    const optind_str = env.get("OPTIND") orelse "1";
    var optind = std.fmt.parseInt(usize, optind_str, 10) catch 1;
    if (optind == 0) optind = 1;

    if (optind > params.len) {
        env.set(varname, "?", false) catch {};
        return 1;
    }

    const current_arg = params[optind - 1];
    if (current_arg.len < 2 or current_arg[0] != '-' or current_arg[1] == '-') {
        env.set(varname, "?", false) catch {};
        return 1;
    }

    const opt_char = current_arg[1];
    var found = false;
    var expects_arg = false;
    for (optstring) |ch| {
        if (ch == opt_char) {
            found = true;
            break;
        }
    }
    if (found) {
        for (optstring, 0..) |ch, idx| {
            if (ch == opt_char and idx + 1 < optstring.len and optstring[idx + 1] == ':') {
                expects_arg = true;
                break;
            }
        }
    }

    var val_buf: [2]u8 = undefined;
    val_buf[0] = opt_char;
    const val: []const u8 = val_buf[0..1];

    if (!found) {
        env.set(varname, "?", false) catch {};
        env.set("OPTARG", val, false) catch {};
    } else {
        env.set(varname, val, false) catch {};
        if (expects_arg) {
            if (current_arg.len > 2) {
                env.set("OPTARG", current_arg[2..], false) catch {};
            } else if (optind < params.len) {
                optind += 1;
                env.set("OPTARG", params[optind - 1], false) catch {};
            } else {
                env.set(varname, "?", false) catch {};
                writeAll(2, "getopts: option requires an argument -- ");
                writeAll(2, val);
                writeAll(2, "\n");
                optind += 1;
                var ind_buf: [16]u8 = undefined;
                const ind_str = std.fmt.bufPrint(&ind_buf, "{d}", .{optind}) catch return 1;
                env.set("OPTIND", ind_str, false) catch {};
                return 1;
            }
        }
    }

    optind += 1;
    var ind_buf: [16]u8 = undefined;
    const ind_str = std.fmt.bufPrint(&ind_buf, "{d}", .{optind}) catch return 1;
    env.set("OPTIND", ind_str, false) catch {};
    return 0;
}

fn sigFromName(name: []const u8) ?u6 {
    if (std.fmt.parseInt(u6, name, 10)) |n| return n else |_| {}
    if (std.mem.eql(u8, name, "HUP")) return signals.SIGHUP;
    if (std.mem.eql(u8, name, "INT")) return signals.SIGINT;
    if (std.mem.eql(u8, name, "QUIT")) return signals.SIGQUIT;
    if (std.mem.eql(u8, name, "TERM")) return signals.SIGTERM;
    if (std.mem.eql(u8, name, "TSTP")) return signals.SIGTSTP;
    if (std.mem.eql(u8, name, "CONT")) return signals.SIGCONT;
    if (std.mem.eql(u8, name, "CHLD")) return signals.SIGCHLD;
    if (std.mem.eql(u8, name, "USR1")) return signals.SIGUSR1;
    if (std.mem.eql(u8, name, "USR2")) return signals.SIGUSR2;
    if (std.mem.eql(u8, name, "PIPE")) return signals.SIGPIPE;
    return null;
}
