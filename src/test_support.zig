const std = @import("std");
const testing = std.testing;
const process = std.process;
const Io = std.Io;

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

    var multi_reader_buffer: Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: Io.File.MultiReader = undefined;
    multi_reader.init(testing.allocator, io, multi_reader_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi_reader.deinit();

    const stdout_reader = multi_reader.reader(0);
    const stderr_reader = multi_reader.reader(1);

    while (multi_reader.fill(64, .none)) |_| {
        if (stdout_reader.buffered().len > 50 * 1024 or stderr_reader.buffered().len > 50 * 1024) {
            return error.StreamTooLong;
        }
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => |e| return e,
    }

    try multi_reader.checkAnyError();
    const term = try child.wait(io);
    const stdout = try multi_reader.toOwnedSlice(0);
    errdefer testing.allocator.free(stdout);
    const stderr = try multi_reader.toOwnedSlice(1);
    errdefer testing.allocator.free(stderr);

    return .{
        .stdout = stdout,
        .stderr = stderr,
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
