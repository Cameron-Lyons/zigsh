const std = @import("std");
const testing = std.testing;
const process = std.process;

const zigsh_argv_prefix = [_][]const u8{ "./zig-out/bin/zigsh", "-c" };

fn runShell(cmd: []const u8) !struct { stdout: []u8, stderr: []u8, term: process.Child.Term } {
    const argv = zigsh_argv_prefix ++ .{cmd};
    const result = try process.run(testing.allocator, testing.io, .{
        .argv = &argv,
    });
    return .{ .stdout = result.stdout, .stderr = result.stderr, .term = result.term };
}

fn expectOutput(cmd: []const u8, expected: []const u8) !void {
    const result = try runShell(cmd);
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);
    try testing.expectEqualStrings(expected, result.stdout);
    try testing.expectEqual(process.Child.Term{ .exited = 0 }, result.term);
}

test "printf %s" {
    try expectOutput("printf '%s' hello", "hello");
}

test "printf %s with newline" {
    try expectOutput("printf '%s\\n' hello", "hello\n");
}

test "printf multiple %s args reuse format" {
    try expectOutput("printf '%s\\n' hello world", "hello\nworld\n");
}

test "printf %d" {
    try expectOutput("printf '%d' 42", "42");
}

test "printf %d negative" {
    try expectOutput("printf '%d' -7", "-7");
}

test "printf %05d zero-padded" {
    try expectOutput("printf '%05d' 42", "00042");
}

test "printf %10d right-aligned" {
    try expectOutput("printf '%10d' 42", "        42");
}

test "printf %-10d left-aligned" {
    try expectOutput("printf '%-10d' 42", "42        ");
}

test "printf %+d positive sign" {
    try expectOutput("printf '%+d' 42", "+42");
}

test "printf %+d negative sign" {
    try expectOutput("printf '%+d' -42", "-42");
}

test "printf % d space sign" {
    try expectOutput("printf '% d' 42", " 42");
}

test "printf %x hex lowercase" {
    try expectOutput("printf '%x' 255", "ff");
}

test "printf %X hex uppercase" {
    try expectOutput("printf '%X' 255", "FF");
}

test "printf %#x alternate hex" {
    try expectOutput("printf '%#x' 255", "0xff");
}

test "printf %#X alternate hex uppercase" {
    try expectOutput("printf '%#X' 255", "0XFF");
}

test "printf %o octal" {
    try expectOutput("printf '%o' 8", "10");
}

test "printf %#o alternate octal" {
    try expectOutput("printf '%#o' 8", "010");
}

test "printf %u unsigned" {
    try expectOutput("printf '%u' 42", "42");
}

test "printf %c char" {
    try expectOutput("printf '%c' A", "A");
}

test "printf %%" {
    try expectOutput("printf '%%'", "%");
}

test "printf %s with width" {
    try expectOutput("printf '%10s' hi", "        hi");
}

test "printf %-10s left-aligned string" {
    try expectOutput("printf '%-10s|' foo", "foo       |");
}

test "printf %.3s precision truncation" {
    try expectOutput("printf '%.3s' hello", "hel");
}

test "printf %b with escapes" {
    try expectOutput("printf '%b' 'hello\\tworld'", "hello\tworld");
}

test "printf %b with \\c stops output" {
    try expectOutput("printf '%b' 'hello\\cworld'", "hello");
}

test "printf escape \\n in format" {
    try expectOutput("printf 'a\\nb'", "a\nb");
}

test "printf escape \\t in format" {
    try expectOutput("printf 'a\\tb'", "a\tb");
}

test "printf escape \\0101 octal in format" {
    try expectOutput("printf '\\0101'", "A");
}

test "printf escape \\x41 hex in format" {
    try expectOutput("printf '\\x41'", "A");
}

test "printf char value 'A as numeric" {
    try expectOutput("printf '%d' \"'A\"", "65");
}

test "printf %d with 0x hex input" {
    try expectOutput("printf '%d' 0x1F", "31");
}

test "printf %d with 0 octal input" {
    try expectOutput("printf '%d' 010", "8");
}

test "printf * width from args" {
    try expectOutput("printf '%*d' 5 42", "   42");
}

test "printf .* precision from args" {
    try expectOutput("printf '%.*s' 3 hello", "hel");
}

test "printf format reuse with leftover args" {
    try expectOutput("printf '%s ' a b c", "a b c ");
}

test "printf mixed specifiers" {
    try expectOutput("printf '%-10s|%05d\\n' foo 42", "foo       |00042\n");
}

test "printf empty string arg for %d" {
    try expectOutput("printf '%d' ''", "0");
}

test "printf no args for %s" {
    try expectOutput("printf '%s'", "");
}

test "printf no args for %d" {
    try expectOutput("printf '%d'", "0");
}

test "printf plain text no specifiers" {
    try expectOutput("printf 'hello world'", "hello world");
}

test "printf %d zero" {
    try expectOutput("printf '%d' 0", "0");
}

test "printf %#x zero no prefix" {
    try expectOutput("printf '%#x' 0", "0");
}

test "printf multiple format types" {
    try expectOutput("printf '%s=%d\\n' count 10", "count=10\n");
}
