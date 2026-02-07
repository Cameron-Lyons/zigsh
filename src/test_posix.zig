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

fn expectExitCode(cmd: []const u8, code: u8) !void {
    const result = try runShell(cmd);
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);
    try testing.expectEqual(process.Child.Term{ .exited = code }, result.term);
}

// --- Arithmetic assignment operators ---

test "arithmetic simple assignment" {
    try expectOutput("x=5; echo $((x = 10)); echo $x", "10\n10\n");
}

test "arithmetic += assignment" {
    try expectOutput("x=5; echo $((x += 3)); echo $x", "8\n8\n");
}

test "arithmetic -= assignment" {
    try expectOutput("x=10; echo $((x -= 3)); echo $x", "7\n7\n");
}

test "arithmetic *= assignment" {
    try expectOutput("x=4; echo $((x *= 5)); echo $x", "20\n20\n");
}

test "arithmetic /= assignment" {
    try expectOutput("x=20; echo $((x /= 4)); echo $x", "5\n5\n");
}

test "arithmetic %= assignment" {
    try expectOutput("x=17; echo $((x %= 5)); echo $x", "2\n2\n");
}

test "arithmetic <<= assignment" {
    try expectOutput("x=1; echo $((x <<= 3)); echo $x", "8\n8\n");
}

test "arithmetic >>= assignment" {
    try expectOutput("x=16; echo $((x >>= 2)); echo $x", "4\n4\n");
}

test "arithmetic &= assignment" {
    try expectOutput("x=15; echo $((x &= 6)); echo $x", "6\n6\n");
}

test "arithmetic |= assignment" {
    try expectOutput("x=5; echo $((x |= 2)); echo $x", "7\n7\n");
}

test "arithmetic ^= assignment" {
    try expectOutput("x=15; echo $((x ^= 9)); echo $x", "6\n6\n");
}

// --- Arithmetic increment/decrement ---

test "arithmetic post-increment" {
    try expectOutput("x=5; echo $((x++)); echo $x", "5\n6\n");
}

test "arithmetic post-decrement" {
    try expectOutput("x=5; echo $((x--)); echo $x", "5\n4\n");
}

test "arithmetic pre-increment" {
    try expectOutput("x=5; echo $((++x)); echo $x", "6\n6\n");
}

test "arithmetic pre-decrement" {
    try expectOutput("x=5; echo $((--x)); echo $x", "4\n4\n");
}

test "arithmetic chained increment in expression" {
    try expectOutput("x=3; echo $((x++ + 10)); echo $x", "13\n4\n");
}

test "arithmetic assignment to unset variable" {
    try expectOutput("echo $((y = 42)); echo $y", "42\n42\n");
}

test "arithmetic increment unset variable" {
    try expectOutput("echo $((z++)); echo $z", "0\n1\n");
}

// --- POSIX character classes in glob ---

test "glob [:upper:]" {
    try expectOutput("case A in [[:upper:]]) echo yes;; *) echo no;; esac", "yes\n");
}

test "glob [:upper:] rejects lowercase" {
    try expectOutput("case a in [[:upper:]]) echo yes;; *) echo no;; esac", "no\n");
}

test "glob [:lower:]" {
    try expectOutput("case z in [[:lower:]]) echo yes;; *) echo no;; esac", "yes\n");
}

test "glob [:lower:] rejects uppercase" {
    try expectOutput("case Z in [[:lower:]]) echo yes;; *) echo no;; esac", "no\n");
}

test "glob [:digit:]" {
    try expectOutput("case 7 in [[:digit:]]) echo yes;; *) echo no;; esac", "yes\n");
}

test "glob [:digit:] rejects alpha" {
    try expectOutput("case x in [[:digit:]]) echo yes;; *) echo no;; esac", "no\n");
}

test "glob [:alpha:]" {
    try expectOutput("case m in [[:alpha:]]) echo yes;; *) echo no;; esac", "yes\n");
}

test "glob [:alpha:] rejects digit" {
    try expectOutput("case 5 in [[:alpha:]]) echo yes;; *) echo no;; esac", "no\n");
}

test "glob [:alnum:]" {
    try expectOutput("case a in [[:alnum:]]) echo yes;; *) echo no;; esac", "yes\n");
}

test "glob [:alnum:] matches digit" {
    try expectOutput("case 3 in [[:alnum:]]) echo yes;; *) echo no;; esac", "yes\n");
}

test "glob [:alnum:] rejects punct" {
    try expectOutput("case . in [[:alnum:]]) echo yes;; *) echo no;; esac", "no\n");
}

test "glob [:space:]" {
    try expectOutput("case ' ' in [[:space:]]) echo yes;; *) echo no;; esac", "yes\n");
}

test "glob [:xdigit:]" {
    try expectOutput("case f in [[:xdigit:]]) echo yes;; *) echo no;; esac", "yes\n");
}

test "glob [:xdigit:] rejects g" {
    try expectOutput("case g in [[:xdigit:]]) echo yes;; *) echo no;; esac", "no\n");
}

test "glob [:blank:]" {
    try expectOutput("case '\t' in [[:blank:]]) echo yes;; *) echo no;; esac", "yes\n");
}

test "glob multiple character classes" {
    try expectOutput("case A in [[:upper:][:digit:]]) echo yes;; *) echo no;; esac", "yes\n");
}

test "glob multiple character classes match digit" {
    try expectOutput("case 5 in [[:upper:][:digit:]]) echo yes;; *) echo no;; esac", "yes\n");
}

test "glob negated character class" {
    try expectOutput("case 5 in [![:alpha:]]) echo yes;; *) echo no;; esac", "yes\n");
}

test "glob negated character class rejects match" {
    try expectOutput("case a in [![:alpha:]]) echo yes;; *) echo no;; esac", "no\n");
}

// --- times builtin ---

test "times produces two lines" {
    const result = try runShell("times");
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    var count: usize = 0;
    while (lines.next()) |line| {
        if (line.len > 0) count += 1;
    }
    try testing.expectEqual(@as(usize, 2), count);
    try testing.expectEqual(process.Child.Term{ .exited = 0 }, result.term);
}

test "times format contains m and s" {
    const result = try runShell("times");
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);
    try testing.expect(std.mem.indexOfScalar(u8, result.stdout, 'm') != null);
    try testing.expect(std.mem.indexOfScalar(u8, result.stdout, 's') != null);
}

// --- cd -L/-P ---

test "cd -P resolves to physical path" {
    try expectOutput("cd -P /tmp; echo $PWD", "/tmp\n");
}

test "cd -L is default logical" {
    try expectOutput("cd -L /tmp; echo $PWD", "/tmp\n");
}

test "cd -P after -L, last wins" {
    try expectOutput("cd -L -P /tmp; echo $PWD", "/tmp\n");
}

// --- test -nt/-ot/-ef ---

test "test -nt newer file" {
    try expectOutput(
        "touch /tmp/zigsh_nt_a; sleep 0.1; touch /tmp/zigsh_nt_b; test /tmp/zigsh_nt_b -nt /tmp/zigsh_nt_a && echo yes; rm -f /tmp/zigsh_nt_a /tmp/zigsh_nt_b",
        "yes\n",
    );
}

test "test -ot older file" {
    try expectOutput(
        "touch /tmp/zigsh_ot_a; sleep 0.1; touch /tmp/zigsh_ot_b; test /tmp/zigsh_ot_a -ot /tmp/zigsh_ot_b && echo yes; rm -f /tmp/zigsh_ot_a /tmp/zigsh_ot_b",
        "yes\n",
    );
}

test "test -ef same file" {
    try expectOutput(
        "touch /tmp/zigsh_ef_a; ln -f /tmp/zigsh_ef_a /tmp/zigsh_ef_b; test /tmp/zigsh_ef_a -ef /tmp/zigsh_ef_b && echo yes; rm -f /tmp/zigsh_ef_a /tmp/zigsh_ef_b",
        "yes\n",
    );
}

test "test -ef different files" {
    try expectExitCode(
        "touch /tmp/zigsh_ef_c; touch /tmp/zigsh_ef_d; test /tmp/zigsh_ef_c -ef /tmp/zigsh_ef_d; s=$?; rm -f /tmp/zigsh_ef_c /tmp/zigsh_ef_d; exit $s",
        1,
    );
}

test "test -nt with [ syntax" {
    try expectOutput(
        "touch /tmp/zigsh_ntb_a; sleep 0.1; touch /tmp/zigsh_ntb_b; [ /tmp/zigsh_ntb_b -nt /tmp/zigsh_ntb_a ] && echo yes; rm -f /tmp/zigsh_ntb_a /tmp/zigsh_ntb_b",
        "yes\n",
    );
}

// --- trap -p ---

test "trap -p shows set traps" {
    try expectOutput(
        "trap 'echo bye' EXIT; trap -p",
        "trap -- 'echo bye' EXIT\n",
    );
}

test "trap -p with no traps is empty" {
    try expectOutput("trap -p", "");
}

test "trap -p shows signal traps" {
    try expectOutput(
        "trap 'handle int' INT; trap -p | grep INT",
        "trap -- 'handle int' INT\n",
    );
}

test "trap with no args lists traps" {
    try expectOutput(
        "trap 'echo bye' EXIT; trap",
        "trap -- 'echo bye' EXIT\n",
    );
}

// --- export -p ---

test "export -p shows exported vars" {
    const result = try runShell("export ZIGSH_TEST_EP=hello; export -p");
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "export ZIGSH_TEST_EP=\"hello\"") != null);
    try testing.expectEqual(process.Child.Term{ .exited = 0 }, result.term);
}

test "export with no args shows exported vars" {
    const result = try runShell("export ZIGSH_TEST_EP2=world; export");
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "export ZIGSH_TEST_EP2=\"world\"") != null);
    try testing.expectEqual(process.Child.Term{ .exited = 0 }, result.term);
}

// --- readonly -p ---

test "readonly -p shows readonly vars" {
    const result = try runShell("readonly ZIGSH_TEST_RO=42; readonly -p");
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "readonly ZIGSH_TEST_RO=\"42\"") != null);
    try testing.expectEqual(process.Child.Term{ .exited = 0 }, result.term);
}

test "readonly with no args shows readonly vars" {
    const result = try runShell("readonly ZIGSH_TEST_RO2=99; readonly");
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "readonly ZIGSH_TEST_RO2=\"99\"") != null);
    try testing.expectEqual(process.Child.Term{ .exited = 0 }, result.term);
}

// --- hash -d/-t ---

test "hash -t prints cached path" {
    try expectOutput("hash ls; hash -t ls", "/usr/bin/ls\n");
}

test "hash -d removes cached entry" {
    try expectExitCode("hash ls; hash -d ls; hash -t ls", 1);
}

test "hash -r clears all" {
    try expectOutput("hash ls; hash -r; hash", "");
}

// --- $_ tracking ---

test "$_ is last arg of previous command" {
    try expectOutput("echo hello world; echo $_", "hello world\nworld\n");
}

test "$_ updates per command" {
    try expectOutput("echo first; echo second third; echo $_", "first\nsecond third\nthird\n");
}

test "$_ with single arg" {
    try expectOutput("echo only; echo $_", "only\nonly\n");
}

// --- Special builtin error handling ---

test "readonly var assignment exits non-interactive shell" {
    const result = try runShell("readonly X=1; X=2; echo nope");
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);
    try testing.expectEqualStrings("", result.stdout);
    try testing.expect(std.mem.indexOf(u8, result.stderr, "readonly variable") != null);
    try testing.expectEqual(process.Child.Term{ .exited = 1 }, result.term);
}

test "readonly var preserves value" {
    try expectOutput("readonly Y=42; echo $Y", "42\n");
}

// --- PS2 default ---

test "PS2 defaults to '> '" {
    try expectOutput("echo \"$PS2\"", "> \n");
}
