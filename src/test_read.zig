const std = @import("std");
const testing = std.testing;
const process = std.process;
const Io = std.Io;
const ArrayList = std.ArrayList;

const zigsh_argv_prefix = [_][]const u8{ "./zig-out/bin/zigsh", "-c" };

fn runShellWithInput(cmd: []const u8, input: []const u8) !struct { stdout: []u8, stderr: []u8, term: process.Child.Term } {
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

    var stdout: ArrayList(u8) = .empty;
    defer stdout.deinit(testing.allocator);
    var stderr: ArrayList(u8) = .empty;
    defer stderr.deinit(testing.allocator);

    try child.collectOutput(testing.allocator, &stdout, &stderr, 50 * 1024);
    const term = try child.wait(io);

    return .{
        .stdout = try stdout.toOwnedSlice(testing.allocator),
        .stderr = try stderr.toOwnedSlice(testing.allocator),
        .term = term,
    };
}

fn expectReadOutput(cmd: []const u8, input: []const u8, expected: []const u8) !void {
    const result = try runShellWithInput(cmd, input);
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);
    try testing.expectEqualStrings(expected, result.stdout);
    try testing.expectEqual(process.Child.Term{ .exited = 0 }, result.term);
}

test "read single variable" {
    try expectReadOutput(
        "read x; printf '%s\\n' \"$x\"",
        "hello\n",
        "hello\n",
    );
}

test "read two variables" {
    try expectReadOutput(
        "read a b; printf '%s\\n' \"$a\"; printf '%s\\n' \"$b\"",
        "hello world\n",
        "hello\nworld\n",
    );
}

test "read last variable gets remainder" {
    try expectReadOutput(
        "read a b; printf '%s\\n' \"$a\"; printf '%s\\n' \"$b\"",
        "one two three four\n",
        "one\ntwo three four\n",
    );
}

test "read extra variables get empty" {
    try expectReadOutput(
        "read a b c; printf '<%s>\\n' \"$a\" \"$b\" \"$c\"",
        "hello\n",
        "<hello>\n<>\n<>\n",
    );
}

test "read REPLY default" {
    try expectReadOutput(
        "read; printf '%s\\n' \"$REPLY\"",
        "hello world\n",
        "hello world\n",
    );
}

test "read strips leading and trailing IFS whitespace for single var" {
    try expectReadOutput(
        "read x; printf '<%s>\\n' \"$x\"",
        "  hello world  \n",
        "<hello world>\n",
    );
}

test "read strips leading IFS whitespace for multiple vars" {
    try expectReadOutput(
        "read a b; printf '<%s>\\n' \"$a\" \"$b\"",
        "  hello   world  \n",
        "<hello>\n<world>\n",
    );
}

test "read -r raw mode preserves backslash" {
    try expectReadOutput(
        "read -r x; printf '%s\\n' \"$x\"",
        "hello\\world\n",
        "hello\\world\n",
    );
}

test "read backslash-newline continuation" {
    try expectReadOutput(
        "read x; printf '%s\\n' \"$x\"",
        "hello\\\nworld\n",
        "helloworld\n",
    );
}

test "read -r backslash-newline no continuation" {
    try expectReadOutput(
        "read -r x; printf '%s\\n' \"$x\"",
        "hello\\\n",
        "hello\\\n",
    );
}

test "read backslash escapes literal char" {
    try expectReadOutput(
        "read x; printf '%s\\n' \"$x\"",
        "hello\\ world\n",
        "hello world\n",
    );
}

test "read with IFS=: colon splitting" {
    try expectReadOutput(
        "IFS=: read a b c; printf '%s\\n' \"$a\" \"$b\" \"$c\"",
        "one:two:three\n",
        "one\ntwo\nthree\n",
    );
}

test "read with IFS=: last var gets remainder" {
    try expectReadOutput(
        "IFS=: read a b; printf '%s\\n' \"$a\" \"$b\"",
        "one:two:three\n",
        "one\ntwo:three\n",
    );
}

test "read with IFS=: extra vars empty" {
    try expectReadOutput(
        "IFS=: read a b c; printf '<%s>\\n' \"$a\" \"$b\" \"$c\"",
        "one:two\n",
        "<one>\n<two>\n<>\n",
    );
}

test "read with custom IFS mixed whitespace and non-whitespace" {
    try expectReadOutput(
        "IFS=', ' read a b c; printf '%s\\n' \"$a\" \"$b\" \"$c\"",
        "one,two three\n",
        "one\ntwo\nthree\n",
    );
}

test "read empty input returns EOF status" {
    const result = try runShellWithInput("read x; printf '<%s>' \"$x\"", "");
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);
    try testing.expectEqualStrings("<>", result.stdout);
}

test "read partial line without newline returns EOF" {
    const result = try runShellWithInput("read x; printf '<%s>' \"$x\"", "hello");
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);
    try testing.expectEqualStrings("<hello>", result.stdout);
}

test "read multiple lines only reads first" {
    try expectReadOutput(
        "read x; printf '%s\\n' \"$x\"",
        "first\nsecond\nthird\n",
        "first\n",
    );
}

test "read -r with multiple variables" {
    try expectReadOutput(
        "read -r a b; printf '%s\\n' \"$a\" \"$b\"",
        "one\\two three\n",
        "one\\two\nthree\n",
    );
}

test "read combined -r flag with other position" {
    try expectReadOutput(
        "read -r x; printf '%s\\n' \"$x\"",
        "back\\slash\n",
        "back\\slash\n",
    );
}

test "read REPLY strips whitespace" {
    try expectReadOutput(
        "read; printf '<%s>\\n' \"$REPLY\"",
        "  spaced  \n",
        "<spaced>\n",
    );
}

test "read with -- ends options" {
    try expectReadOutput(
        "read -- x; printf '%s\\n' \"$x\"",
        "hello\n",
        "hello\n",
    );
}

test "read IFS empty no splitting" {
    try expectReadOutput(
        "IFS= read x; printf '<%s>\\n' \"$x\"",
        "  hello  world  \n",
        "<  hello  world  >\n",
    );
}

test "read successive reads consume lines" {
    try expectReadOutput(
        "read a; read b; printf '%s,%s\\n' \"$a\" \"$b\"",
        "first\nsecond\n",
        "first,second\n",
    );
}
