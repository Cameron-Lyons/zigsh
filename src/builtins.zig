const std = @import("std");
const Environment = @import("env.zig").Environment;
const JobTable = @import("jobs.zig").JobTable;
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
        env.set("OLDPWD", pwd, false) catch {};
    }

    var new_buf: [4096]u8 = undefined;
    const new_pwd = posix.getcwd(&new_buf) catch null;
    if (new_pwd) |pwd| {
        env.set("PWD", pwd, false) catch {};
        if (cdpath_hit and is_relative) {
            posix.writeAll(1, pwd);
            posix.writeAll(1, "\n");
        }
    }

    return 0;
}

fn builtinPwd(_: []const []const u8, _: *Environment) u8 {
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
        if (i > 1 and (if (no_newline) i > 2 else i > 1)) posix.writeAll(1, " ");
        posix.writeAll(1, args[i]);
    }
    if (!no_newline) posix.writeAll(1, "\n");
    return 0;
}

fn builtinTest(args: []const []const u8, _: *Environment) u8 {
    const effective_args = if (args.len > 0 and std.mem.eql(u8, args[0], "[")) blk: {
        if (args.len < 2 or !std.mem.eql(u8, args[args.len - 1], "]")) {
            posix.writeAll(2, "[: missing ]\n");
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
            posix.writeAll(1, id_str);
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

fn builtinWait(args: []const []const u8, _: *Environment) u8 {
    if (args.len > 1) {
        const pid = std.fmt.parseInt(posix.pid_t, args[1], 10) catch return 127;
        const result = posix.waitpid(pid, 0);
        if (result.pid <= 0) return 127;
        return posix.statusFromWait(result.status);
    }
    while (true) {
        const result = posix.waitpid(-1, 0);
        if (result.pid <= 0) break;
    }
    return 0;
}

fn builtinKill(args: []const []const u8, _: *Environment) u8 {
    if (args.len < 2) {
        posix.writeAll(2, "kill: usage: kill [-s signal] pid ...\n");
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
    if (args.len < 3) {
        if (args.len == 2 and std.mem.eql(u8, args[1], "-l")) {
            posix.writeAll(1, "EXIT HUP INT QUIT TERM USR1 USR2 ERR\n");
            return 0;
        }
        return 0;
    }

    const action_src = args[1];
    const reset = std.mem.eql(u8, action_src, "-") or std.mem.eql(u8, action_src, "");
    const action = if (!reset) (env.alloc.dupe(u8, action_src) catch return 1) else @as(?[]const u8, null);

    for (args[2..]) |sig_name| {
        if (std.mem.eql(u8, sig_name, "EXIT") or std.mem.eql(u8, sig_name, "0")) {
            if (signals.getExitTrap()) |old| env.alloc.free(old);
            signals.setExitTrap(action);
            continue;
        }
        if (std.mem.eql(u8, sig_name, "ERR")) {
            if (signals.getErrTrap()) |old| env.alloc.free(old);
            signals.setErrTrap(action);
            continue;
        }
        const sig = sigFromName(sig_name) orelse {
            posix.writeAll(2, "trap: invalid signal: ");
            posix.writeAll(2, sig_name);
            posix.writeAll(2, "\n");
            continue;
        };
        if (reset) {
            if (signals.trap_handlers[@intCast(sig)]) |old| env.alloc.free(old);
            signals.setTrap(sig, null);
        } else {
            if (signals.trap_handlers[@intCast(sig)]) |old| env.alloc.free(old);
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
                        if (args[arg_start].len > 0) delim = args[arg_start][0];
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
    var total: usize = 0;
    var hit_eof = false;

    if (raw) {
        while (total < buf.len) {
            const n = posix.read(0, buf[total .. total + 1]) catch {
                hit_eof = true;
                break;
            };
            if (n == 0) {
                hit_eof = true;
                break;
            }
            if (buf[total] == delim) break;
            total += 1;
        }
    } else {
        while (total < buf.len) {
            var byte_buf: [1]u8 = undefined;
            const n = posix.read(0, &byte_buf) catch {
                hit_eof = true;
                break;
            };
            if (n == 0) {
                hit_eof = true;
                break;
            }
            const ch = byte_buf[0];
            if (ch == delim) break;
            if (ch == '\\') {
                const n2 = posix.read(0, &byte_buf) catch {
                    hit_eof = true;
                    break;
                };
                if (n2 == 0) {
                    hit_eof = true;
                    break;
                }
                if (byte_buf[0] == '\n') continue;
                buf[total] = byte_buf[0];
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
        var start: usize = 0;
        while (start < line.len and isIfsWhitespace(line[start], ifs)) : (start += 1) {}
        var end: usize = line.len;
        while (end > start and isIfsWhitespace(line[end - 1], ifs)) : (end -= 1) {}
        env.set(effective_names[0], line[start..end], false) catch return 1;
        return if (hit_eof) 1 else 0;
    }

    var pos: usize = 0;
    while (pos < line.len and isIfsWhitespace(line[pos], ifs)) : (pos += 1) {}

    var var_idx: usize = 0;
    while (var_idx < effective_names.len - 1) : (var_idx += 1) {
        if (pos >= line.len) {
            env.set(effective_names[var_idx], "", false) catch return 1;
            continue;
        }
        const field_start = pos;
        while (pos < line.len and !isIfsChar(line[pos], ifs)) : (pos += 1) {}
        env.set(effective_names[var_idx], line[field_start..pos], false) catch return 1;

        if (pos < line.len) {
            while (pos < line.len and isIfsWhitespace(line[pos], ifs)) : (pos += 1) {}
            if (pos < line.len and isIfsNonWhitespace(line[pos], ifs)) {
                pos += 1;
                while (pos < line.len and isIfsWhitespace(line[pos], ifs)) : (pos += 1) {}
            }
        }
    }

    if (var_idx < effective_names.len) {
        var end: usize = line.len;
        while (end > pos and isIfsWhitespace(line[end - 1], ifs)) : (end -= 1) {}
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
        '0' => {
            var val: u8 = 0;
            var count: usize = 0;
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
        else => return .{ .byte = fmt[1], .advance = 2 },
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
    if (arg.len >= 2 and arg[0] == '\'') {
        return @intCast(arg[1]);
    }
    if (arg.len >= 2 and arg[0] == '"') {
        return @intCast(arg[1]);
    }
    if (std.fmt.parseInt(i64, arg, 0)) |v| return v else |_| {}
    had_error.* = true;
    posix.writeAll(2, "printf: '");
    posix.writeAll(2, arg);
    posix.writeAll(2, "': not a valid number\n");
    return 0;
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
    while (i < arg.len and out_len < out_buf.len) {
        if (arg[i] == '\\') {
            if (i + 1 < arg.len and arg[i + 1] == 'c') {
                early_exit.* = true;
                break;
            }
            const esc = printfProcessEscape(arg[i..]);
            out_buf[out_len] = esc.byte;
            out_len += 1;
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
            const esc = printfProcessEscape(fmt[i..]);
            const byte_arr: [1]u8 = .{esc.byte};
            posix.writeAll(1, &byte_arr);
            i += esc.advance;
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
                'c' => {
                    const arg = printfGetNextArg(printf_args, arg_idx);
                    printfFormatChar(arg, spec);
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

fn builtinPrintf(args: []const []const u8, _: *Environment) u8 {
    if (args.len < 2) {
        posix.writeAll(2, "printf: usage: printf format [arguments]\n");
        return 1;
    }

    const fmt = args[1];
    const printf_args = if (args.len > 2) args[2..] else &[_][]const u8{};
    var arg_idx: usize = 0;
    var status: u8 = 0;

    const result = printfProcessFormat(fmt, printf_args, &arg_idx);
    if (result.status != 0) status = result.status;
    if (result.early_exit) return status;

    while (arg_idx < printf_args.len) {
        const prev_idx = arg_idx;
        const loop_result = printfProcessFormat(fmt, printf_args, &arg_idx);
        if (loop_result.status != 0) status = loop_result.status;
        if (loop_result.early_exit) return status;
        if (arg_idx == prev_idx) break;
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
    const new_mask = std.fmt.parseInt(c_uint, args[1], 8) catch {
        posix.writeAll(2, "umask: invalid mask\n");
        return 1;
    };
    _ = libc.umask(new_mask);
    return 0;
}

fn builtinType(args: []const []const u8, env: *Environment) u8 {
    if (args.len < 2) return 0;
    var status: u8 = 0;
    for (args[1..]) |name| {
        if (env.getAlias(name)) |val| {
            posix.writeAll(1, name);
            posix.writeAll(1, " is aliased to '");
            posix.writeAll(1, val);
            posix.writeAll(1, "'\n");
        } else if (builtins.get(name) != null) {
            posix.writeAll(1, name);
            posix.writeAll(1, " is a shell builtin\n");
        } else if (env.functions.get(name) != null) {
            posix.writeAll(1, name);
            posix.writeAll(1, " is a shell function\n");
        } else if (findInPath(name, env)) {
            posix.writeAll(1, name);
            posix.writeAll(1, " is ");
            posix.writeAll(1, name);
            posix.writeAll(1, "\n");
        } else {
            posix.writeAll(2, name);
            posix.writeAll(2, ": not found\n");
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
        posix.writeAll(2, "getopts: usage: getopts optstring name [arg ...]\n");
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
                posix.writeAll(2, "getopts: option requires an argument -- ");
                posix.writeAll(2, val);
                posix.writeAll(2, "\n");
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
            posix.writeAll(1, entry.key_ptr.*);
            posix.writeAll(1, "\t");
            posix.writeAll(1, entry.value_ptr.*);
            posix.writeAll(1, "\n");
        }
        return 0;
    }

    if (std.mem.eql(u8, args[1], "-r")) {
        env.clearCommandHash();
        return 0;
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
    const result = printfProcessEscape("\\0101");
    try testing.expectEqual(@as(u8, 'A'), result.byte);
    try testing.expectEqual(@as(usize, 5), result.advance);

    const r2 = printfProcessEscape("\\0");
    try testing.expectEqual(@as(u8, 0), r2.byte);
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
