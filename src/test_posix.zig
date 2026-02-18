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

fn expectedPhysicalTmpPath() ![]u8 {
    const result = try runShell("cd /tmp; /bin/pwd -P");
    defer testing.allocator.free(result.stderr);
    try testing.expectEqual(process.Child.Term{ .exited = 0 }, result.term);
    return result.stdout;
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
    const expected = try expectedPhysicalTmpPath();
    defer testing.allocator.free(expected);
    try expectOutput("cd -P /tmp; echo $PWD", expected);
}

test "cd -L is default logical" {
    try expectOutput("cd -L /tmp; echo $PWD", "/tmp\n");
}

test "cd -P after -L, last wins" {
    const expected = try expectedPhysicalTmpPath();
    defer testing.allocator.free(expected);
    try expectOutput("cd -L -P /tmp; echo $PWD", expected);
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
        "trap -- 'echo bye' EXIT\nbye\n",
    );
}

test "trap -p with no traps is empty" {
    try expectOutput("trap -p", "");
}

test "trap -p shows signal traps" {
    try expectOutput(
        "trap 'handle int' INT; trap -p INT",
        "trap -- 'handle int' SIGINT\n",
    );
}

test "trap with no args lists traps" {
    try expectOutput(
        "trap 'echo bye' EXIT; trap",
        "trap -- 'echo bye' EXIT\nbye\n",
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
    const result = try runShell("hash ls; hash -t ls");
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);
    try testing.expect(result.stdout.len > "/ls\n".len);
    try testing.expect(result.stdout[0] == '/');
    try testing.expect(std.mem.endsWith(u8, result.stdout, "/ls\n"));
    try testing.expectEqual(process.Child.Term{ .exited = 0 }, result.term);
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

// --- set no args prints variables ---

test "set no args prints variables" {
    const result = try runShell("X_TEST_SET=hello; set");
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "X_TEST_SET=hello") != null);
    try testing.expectEqual(process.Child.Term{ .exited = 0 }, result.term);
}

// --- set -- clears positional params ---

test "set -- clears positional params" {
    try expectOutput("set -- a b c; echo $#; set --; echo $#", "3\n0\n");
}

test "set -- with args" {
    try expectOutput("set -- x y; echo $1 $2", "x y\n");
}

// --- set +o reinput format ---

test "set +o shows reinput format" {
    const result = try runShell("set +o");
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "set +o errexit") != null);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "set +o nounset") != null);
    try testing.expectEqual(process.Child.Term{ .exited = 0 }, result.term);
}

// --- unset -f ---

test "unset -f removes function" {
    try expectExitCode("f(){ echo x; }; unset -f f; f", 127);
}

test "unset -v removes variable" {
    try expectOutput("X=42; unset -v X; echo ${X-gone}", "gone\n");
}

// --- kill signal names ---

test "kill -l lists signals" {
    const result = try runShell("kill -l");
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "HUP") != null);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "INT") != null);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "TERM") != null);
    try testing.expectEqual(process.Child.Term{ .exited = 0 }, result.term);
}

test "kill -l exit_status converts to signal name" {
    try expectOutput("kill -l 130", "INT\n");
}

test "kill -l 137 gives KILL" {
    try expectOutput("kill -l 137", "KILL\n");
}

test "kill -l 2 gives INT" {
    try expectOutput("kill -l 2", "INT\n");
}

// --- umask -S ---

test "umask -S symbolic display" {
    try expectOutput("umask 022; umask -S", "u=rwx,g=rx,o=rx\n");
}

test "umask -S with 077" {
    try expectOutput("umask 077; umask -S", "u=rwx,g=,o=\n");
}

test "umask symbolic input" {
    try expectOutput("umask u=rwx,g=rx,o=rx; umask", "0022\n");
}

test "umask symbolic input restrictive" {
    try expectOutput("umask u=rwx,g=,o=; umask", "0077\n");
}

// --- pwd -L/-P ---

test "pwd -P shows physical path" {
    const expected = try expectedPhysicalTmpPath();
    defer testing.allocator.free(expected);
    try expectOutput("cd /tmp; pwd -P", expected);
}

test "pwd -L shows logical path" {
    try expectOutput("cd /tmp; pwd -L", "/tmp\n");
}

// --- type full path ---

test "type shows full path for external commands" {
    const result = try runShell("type ls");
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "ls is /") != null);
    try testing.expectEqual(process.Child.Term{ .exited = 0 }, result.term);
}

test "type shows builtin for shell builtins" {
    try expectOutput("type echo", "echo is a shell builtin\n");
}

test "type not found returns 1" {
    try expectExitCode("type nonexistent_command_xyz123", 1);
}

// --- getopts clustering ---

test "getopts processes clustered options" {
    try expectOutput("while getopts abc opt -abc; do printf '%s ' \"$opt\"; done; echo", "a b c \n");
}

test "getopts with option argument" {
    try expectOutput("while getopts a:b opt -afoo -b; do printf '%s:%s ' \"$opt\" \"$OPTARG\"; done; echo", "a:foo b: \n");
}

test "getopts silent mode unknown option" {
    try expectOutput(
        "while getopts :ab opt -a -x -b; do printf '%s:%s ' \"$opt\" \"$OPTARG\"; done; echo",
        "a: ?:x b: \n",
    );
}

// --- cd - prints directory ---

test "cd - prints new directory" {
    const result = try runShell("cd /tmp; cd /; cd -");
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);
    try testing.expectEqualStrings("/tmp\n", result.stdout);
    try testing.expectEqual(process.Child.Term{ .exited = 0 }, result.term);
}

// --- trap -p SIGNAL ---

test "trap -p INT shows specific trap" {
    try expectOutput(
        "trap 'echo bye' INT; trap -p INT",
        "trap -- 'echo bye' SIGINT\n",
    );
}

test "trap -p with no matching trap shows nothing" {
    try expectOutput("trap -p INT", "");
}

test "trap -p EXIT shows exit trap" {
    try expectOutput(
        "trap 'true' EXIT; trap -p EXIT",
        "trap -- 'true' EXIT\n",
    );
}

// --- ulimit ---

test "ulimit -n shows open files" {
    const result = try runShell("ulimit -n");
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);
    try testing.expect(result.stdout.len > 0);
    try testing.expect(result.stdout[result.stdout.len - 1] == '\n');
    try testing.expectEqual(process.Child.Term{ .exited = 0 }, result.term);
}

test "ulimit -a shows all limits" {
    const result = try runShell("ulimit -a");
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "open files") != null);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "stack size") != null);
    try testing.expectEqual(process.Child.Term{ .exited = 0 }, result.term);
}

test "ulimit default is file size" {
    const result = try runShell("ulimit");
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);
    try testing.expect(result.stdout.len > 0);
    try testing.expectEqual(process.Child.Term{ .exited = 0 }, result.term);
}
