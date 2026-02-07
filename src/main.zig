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
    defer sh.deinit();

    var ppid_buf: [16]u8 = undefined;
    const ppid_str = std.fmt.bufPrint(&ppid_buf, "{d}", .{posix.getppid()}) catch "0";
    sh.env.set("PPID", ppid_str, false) catch {};
    sh.env.markReadonly("PPID");

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

    if (args.len > 0) {
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "-c")) {
                i += 1;
                if (i >= args.len) {
                    posix.writeAll(2, "zigsh: -c: option requires an argument\n");
                    return 2;
                }
                return sh.executeSource(args[i]);
            } else if (std.mem.eql(u8, args[i], "-s")) {
                return sh.runInteractive();
            } else if (args[i].len > 0 and args[i][0] != '-') {
                return sh.executeFile(args[i]);
            }
        }
    }

    if (posix.isatty(0)) {
        sh.env.set("PS1", "$ ", false) catch {};
    }

    sh.env.options.interactive = true;
    sh.loadEnvFile();
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
