const std = @import("std");
const testing = std.testing;
const process = std.process;
const test_support = @import("test_support.zig");
const runShellWithInput = test_support.runShellWithInput;

fn expectReadOutput(cmd: []const u8, input: []const u8, expected: []const u8) !void {
    try test_support.expectOutputWithInput(cmd, input, expected);
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

test "read REPLY preserves whitespace" {
    try expectReadOutput(
        "read; printf '<%s>\\n' \"$REPLY\"",
        "  spaced  \n",
        "<  spaced  >\n",
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

test "read -p suppresses prompt on non-tty stderr" {
    const result = try runShellWithInput(
        "read -p 'Enter: ' x; printf '%s\\n' \"$x\"",
        "hello\n",
    );
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);
    try testing.expectEqualStrings("hello\n", result.stdout);
    try testing.expectEqualStrings("", result.stderr);
    try testing.expectEqual(process.Child.Term{ .exited = 0 }, result.term);
}

test "read -p with empty prompt" {
    const result = try runShellWithInput(
        "read -p '' x; printf '%s\\n' \"$x\"",
        "hello\n",
    );
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);
    try testing.expectEqualStrings("hello\n", result.stdout);
    try testing.expectEqualStrings("", result.stderr);
}

test "read -p prompt with REPLY default" {
    const result = try runShellWithInput(
        "read -p '> '; printf '%s\\n' \"$REPLY\"",
        "test\n",
    );
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);
    try testing.expectEqualStrings("test\n", result.stdout);
    try testing.expectEqualStrings("", result.stderr);
}

test "read -d custom delimiter" {
    try expectReadOutput(
        "read -d : x; printf '<%s>\\n' \"$x\"",
        "hello:world\n",
        "<hello>\n",
    );
}

test "read -d reads up to delimiter ignoring newlines" {
    try expectReadOutput(
        "read -d : x; printf '<%s>\\n' \"$x\"",
        "line1\nline2:",
        "<line1\nline2>\n",
    );
}

test "read -d with multiple variables" {
    try expectReadOutput(
        "read -d : a b; printf '<%s><%s>\\n' \"$a\" \"$b\"",
        "one two three:",
        "<one><two three>\n",
    );
}

test "read -d EOF without delimiter" {
    const result = try runShellWithInput(
        "read -d : x; printf '<%s>' \"$x\"",
        "no delimiter here",
    );
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);
    try testing.expectEqualStrings("<no delimiter here>", result.stdout);
}

test "read -d with single char arg" {
    try expectReadOutput(
        "read -d , x; printf '<%s>\\n' \"$x\"",
        "a,b,c\n",
        "<a>\n",
    );
}

test "read -rp combined flags" {
    const result = try runShellWithInput(
        "read -rp 'prompt: ' x; printf '%s\\n' \"$x\"",
        "back\\slash\n",
    );
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);
    try testing.expectEqualStrings("back\\slash\n", result.stdout);
    try testing.expectEqualStrings("", result.stderr);
}

test "read -r -d combined separate flags" {
    try expectReadOutput(
        "read -r -d : x; printf '<%s>\\n' \"$x\"",
        "back\\slash:",
        "<back\\slash>\n",
    );
}

test "read -r -p -d all three flags" {
    const result = try runShellWithInput(
        "read -r -p 'go: ' -d , x; printf '<%s>\\n' \"$x\"",
        "a\\b,rest",
    );
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);
    try testing.expectEqualStrings("<a\\b>\n", result.stdout);
    try testing.expectEqualStrings("", result.stderr);
}

test "read -p with prompt as next arg" {
    const result = try runShellWithInput(
        "read -p 'ask: ' x; printf '%s\\n' \"$x\"",
        "val\n",
    );
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);
    try testing.expectEqualStrings("val\n", result.stdout);
    try testing.expectEqualStrings("", result.stderr);
}

test "read -d with delimiter as next arg" {
    try expectReadOutput(
        "read -d ';' x; printf '<%s>\\n' \"$x\"",
        "hello;world",
        "<hello>\n",
    );
}
