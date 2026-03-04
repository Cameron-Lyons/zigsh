const std = @import("std");
const Shell = @import("shell.zig").Shell;

pub const token = @import("token.zig");
pub const ast = @import("ast.zig");
pub const lexer = @import("lexer.zig");
pub const parser = @import("parser.zig");
pub const env = @import("env.zig");
pub const redirect = @import("redirect.zig");
pub const expander = @import("expander.zig");
pub const builtins = @import("builtins.zig");
pub const executor = @import("executor.zig");
pub const shell = @import("shell.zig");
pub const types = @import("types.zig");
pub const arithmetic = @import("arithmetic.zig");
pub const glob = @import("glob.zig");
pub const signals = @import("signals.zig");
pub const jobs = @import("jobs.zig");
pub const line_editor = @import("line_editor.zig");
pub const posix = @import("posix.zig");

pub fn main(init: std.process.Init.Minimal) u8 {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var sh = Shell.init(gpa);
    sh.linkJobTable();
    sh.linkHistory();
    signals.setActiveState(&sh.env.signal_state);
    defer signals.clearActiveState();
    defer sh.deinit();

    var ppid_buf: [16]u8 = undefined;
    const ppid_str = std.fmt.bufPrint(&ppid_buf, "{d}", .{posix.getppid()}) catch "0";
    sh.env.set("PPID", ppid_str, false) catch {};
    sh.env.markReadonly("PPID");

    var uid_buf: [16]u8 = undefined;
    const uid_str = std.fmt.bufPrint(&uid_buf, "{d}", .{std.c.getuid()}) catch "0";
    sh.env.set("UID", uid_str, false) catch {};
    sh.env.markReadonly("UID");

    var euid_buf: [16]u8 = undefined;
    const euid_str = std.fmt.bufPrint(&euid_buf, "{d}", .{posix.geteuid()}) catch "0";
    sh.env.set("EUID", euid_str, false) catch {};
    sh.env.markReadonly("EUID");

    sh.env.set("PS2", "> ", false) catch {};
    sh.env.set("OPTIND", "1", false) catch {};

    var args_buf: [256][]const u8 = undefined;
    var args_count: usize = 0;
    var args_iter = std.process.Args.Iterator.init(init.args);
    _ = args_iter.next();
    while (args_iter.next()) |arg| {
        if (args_count < args_buf.len) {
            args_buf[args_count] = arg;
            args_count += 1;
        }
    }
    const args = args_buf[0..args_count];
    var rcfile_override: ?[]const u8 = null;
    var skip_env_file = false;

    if (args.len > 0) {
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "-c") or std.mem.eql(u8, args[i], "+c")) {
                i += 1;
                if (i >= args.len) {
                    posix.writeAll(2, "zigsh: -c: option requires an argument\n");
                    return 2;
                }
                const cmd = args[i];
                i += 1;
                if (i < args.len) {
                    sh.env.shell_name = args[i];
                    i += 1;
                    if (i < args.len) {
                        sh.env.positional_params = args[i..];
                    }
                }
                if (rcfile_override) |rc| {
                    sh.env.set("ENV", rc, false) catch {};
                }
                const status = sh.executeSource(cmd);
                sh.runExitTrap();
                if (sh.env.should_exit) return sh.env.exit_value;
                return status;
            } else if (std.mem.eql(u8, args[i], "-s")) {
                if (rcfile_override) |rc| {
                    sh.env.set("ENV", rc, false) catch {};
                }
                return sh.runInteractive();
            } else if (std.mem.eql(u8, args[i], "-o")) {
                i += 1;
                if (i >= args.len) {
                    posix.writeAll(2, "zigsh: -o: option requires an argument\n");
                    return 2;
                }
                if (!sh.env.setOption(args[i], true)) {
                    posix.writeAll(2, "zigsh: -o: invalid option name: ");
                    posix.writeAll(2, args[i]);
                    posix.writeAll(2, "\n");
                    return 2;
                }
            } else if (std.mem.eql(u8, args[i], "+o")) {
                i += 1;
                if (i >= args.len) {
                    posix.writeAll(2, "zigsh: +o: option requires an argument\n");
                    return 2;
                }
                if (!sh.env.setOption(args[i], false)) {
                    posix.writeAll(2, "zigsh: +o: invalid option name: ");
                    posix.writeAll(2, args[i]);
                    posix.writeAll(2, "\n");
                    return 2;
                }
            } else if (std.mem.eql(u8, args[i], "-O")) {
                i += 1;
                if (i >= args.len) {
                    posix.writeAll(2, "zigsh: -O: option requires an argument\n");
                    return 2;
                }
                if (!sh.env.setShoptOption(args[i], true)) {
                    posix.writeAll(2, "zigsh: -O: invalid shopt name: ");
                    posix.writeAll(2, args[i]);
                    posix.writeAll(2, "\n");
                    return 2;
                }
            } else if (std.mem.eql(u8, args[i], "+O")) {
                i += 1;
                if (i >= args.len) {
                    posix.writeAll(2, "zigsh: +O: option requires an argument\n");
                    return 2;
                }
                if (!sh.env.setShoptOption(args[i], false)) {
                    posix.writeAll(2, "zigsh: +O: invalid shopt name: ");
                    posix.writeAll(2, args[i]);
                    posix.writeAll(2, "\n");
                    return 2;
                }
            } else if (std.mem.eql(u8, args[i], "--rcfile") or std.mem.eql(u8, args[i], "--init-file")) {
                i += 1;
                if (i >= args.len) {
                    posix.writeAll(2, "zigsh: --rcfile: option requires an argument\n");
                    return 2;
                }
                rcfile_override = args[i];
            } else if (std.mem.eql(u8, args[i], "--norc") or std.mem.eql(u8, args[i], "--noprofile")) {
                skip_env_file = true;
            } else if (std.mem.eql(u8, args[i], "--posix")) {
                sh.env.set("POSIXLY_CORRECT", "1", true) catch {};
                sh.env.shopt.strict_arg_parse = true;
            } else if (args[i].len > 1 and args[i][0] == '-' and args[i][1] != '-') {
                for (args[i][1..]) |ch| {
                    if (!sh.env.setShortOption(ch, true)) {
                        posix.writeAll(2, "zigsh: invalid option: -");
                        var cbuf: [1]u8 = .{ch};
                        posix.writeAll(2, &cbuf);
                        posix.writeAll(2, "\n");
                        return 2;
                    }
                    if (ch == 'i' and sh.env.get("PS1") == null) {
                        sh.env.set("PS1", "\\s-\\v\\$ ", false) catch {};
                    }
                }
            } else if (args[i].len > 1 and args[i][0] == '+') {
                for (args[i][1..]) |ch| {
                    if (!sh.env.setShortOption(ch, false)) {
                        posix.writeAll(2, "zigsh: invalid option: +");
                        var cbuf: [1]u8 = .{ch};
                        posix.writeAll(2, &cbuf);
                        posix.writeAll(2, "\n");
                        return 2;
                    }
                }
            } else if (std.mem.startsWith(u8, args[i], "--")) {
                posix.writeAll(2, "zigsh: unrecognized option: ");
                posix.writeAll(2, args[i]);
                posix.writeAll(2, "\n");
                return 2;
            } else if (args[i].len > 0 and args[i][0] != '-') {
                sh.env.shell_name = args[i];
                if (i + 1 < args.len) {
                    sh.env.positional_params = args[i + 1 ..];
                }
                if (rcfile_override) |rc| {
                    sh.env.set("ENV", rc, false) catch {};
                }
                return sh.executeFile(args[i]);
            }
        }
    }

    if (rcfile_override) |rc| {
        sh.env.set("ENV", rc, false) catch {};
    }

    if (posix.isatty(0)) {
        sh.env.set("PS1", "$ ", false) catch {};
    }

    sh.env.options.interactive = true;
    if (!skip_env_file) {
        sh.loadEnvFile();
    }
    return sh.runInteractive();
}

test {
    _ = lexer;
    _ = parser;
    _ = env;
    _ = redirect;
    _ = expander;
    _ = arithmetic;
    _ = glob;
    _ = types;
    _ = posix;
}
