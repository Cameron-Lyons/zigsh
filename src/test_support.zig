const std = @import("std");
const testing = std.testing;
const process = std.process;

const zigsh_argv_prefix = [_][]const u8{ "./zig-out/bin/zigsh", "-c" };

pub const RunResult = struct {
    stdout: []u8,
    stderr: []u8,
    term: process.Child.Term,
};

pub fn runShell(cmd: []const u8) !RunResult {
    const argv = zigsh_argv_prefix ++ .{cmd};
    const result = try process.run(testing.allocator, testing.io, .{
        .argv = &argv,
    });
    return .{ .stdout = result.stdout, .stderr = result.stderr, .term = result.term };
}

pub fn runShellWithInput(cmd: []const u8, input: []const u8) !RunResult {
    const io = testing.io;
    const argv = zigsh_argv_prefix ++ .{cmd};
    var child = try process.spawn(io, .{
        .argv = &argv,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    defer child.kill(io);

    child.stdin.?.writeStreamingAll(io, input) catch {};
    child.stdin.?.close(io);
    child.stdin = null;

    var stdout: std.ArrayList(u8) = .empty;
    defer stdout.deinit(testing.allocator);
    var stderr: std.ArrayList(u8) = .empty;
    defer stderr.deinit(testing.allocator);

    try child.collectOutput(testing.allocator, &stdout, &stderr, 50 * 1024);
    const term = try child.wait(io);
    const stdout_owned = try stdout.toOwnedSlice(testing.allocator);
    errdefer testing.allocator.free(stdout_owned);
    const stderr_owned = try stderr.toOwnedSlice(testing.allocator);
    errdefer testing.allocator.free(stderr_owned);

    return .{
        .stdout = stdout_owned,
        .stderr = stderr_owned,
        .term = term,
    };
}

pub fn expectOutput(cmd: []const u8, expected: []const u8) !void {
    const result = try runShell(cmd);
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);
    try testing.expectEqualStrings(expected, result.stdout);
    try testing.expectEqual(process.Child.Term{ .exited = 0 }, result.term);
}

pub fn expectExitCode(cmd: []const u8, code: u8) !void {
    const result = try runShell(cmd);
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);
    try testing.expectEqual(process.Child.Term{ .exited = code }, result.term);
}

pub fn expectOutputWithInput(cmd: []const u8, input: []const u8, expected: []const u8) !void {
    const result = try runShellWithInput(cmd, input);
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);
    try testing.expectEqualStrings(expected, result.stdout);
    try testing.expectEqual(process.Child.Term{ .exited = 0 }, result.term);
}
