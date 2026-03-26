const builtin = @import("builtin");
const std = @import("std");
const Io = std.Io;

const ast = @import("ast.zig");
const Arithmetic = @import("arithmetic.zig").Arithmetic;
const Environment = @import("env.zig").Environment;
const Expander = @import("expander.zig").Expander;
const JobTable = @import("jobs.zig").JobTable;
const Lexer = @import("lexer.zig").Lexer;
const Parser = @import("parser.zig").Parser;
const Shell = @import("shell.zig").Shell;
const glob = @import("glob.zig");

const KiB: u64 = 1024;
const MiB: u64 = 1024 * KiB;
const default_min_time_ms: u64 = 250;
const default_samples: usize = 5;
const calibration_floor_ns: u64 = std.time.ns_per_ms;
const max_auto_iterations: usize = 100_000;

const shell_script =
    \\: "${SHELL##*/}" && : "$PWD" || : "/tmp"
    \\if [ -n "${HOME:-/tmp}" ]; then
    \\  for item in one two three four five six seven eight; do
    \\    case "$item" in
    \\      one|two) : "$item" ;;
    \\      *) : "${HOME:-/tmp}" "$item" "$PWD" ;;
    \\    esac
    \\  done
    \\fi
    \\
;

const parser_script =
    shell_script ++
    shell_script ++
    shell_script ++
    shell_script;

const lexer_script =
    parser_script ++
    \\: "${PATH:-/usr/bin}" "${SHELL##*/}" "$((1 + 2 * 3))"
    \\[ -n "$PWD" ] && : || :
    \\
    ;

const arithmetic_expression =
    "((alpha + beta * 3) << 2) / (gamma ? 7 : 5) + (delta & 15) - (epsilon % 11) + (zeta == 12 ? eta : theta)";

const GlobCase = struct {
    pattern: []const u8,
    text: []const u8,
    pathname: bool = false,
    nocase: bool = false,
};

const glob_cases = [_]GlobCase{
    .{ .pattern = "*.zig", .text = "bench.zig" },
    .{ .pattern = "src/*.zig", .text = "src/bench.zig", .pathname = true },
    .{ .pattern = "src/*/*.zig", .text = "src/bench.zig", .pathname = true },
    .{ .pattern = "test-??.sh", .text = "test-ab.sh" },
    .{ .pattern = "[[:alpha:]]*.md", .text = "README.md" },
    .{ .pattern = "[![:digit:]]*.zig", .text = "bench.zig" },
    .{ .pattern = "foo\\*bar", .text = "foo*bar" },
    .{ .pattern = "src/**", .text = "src/parser.zig", .pathname = true },
    .{ .pattern = "*.[ch]", .text = "main.c" },
    .{ .pattern = "*.[ch]", .text = "main.zig" },
    .{ .pattern = "README.MD", .text = "readme.md", .nocase = true },
    .{ .pattern = "docs/[[:upper:]]*/index.*", .text = "docs/API/index.md", .pathname = true },
};

fn globCaseBytes() comptime_int {
    var total: usize = 0;
    inline for (glob_cases) |gc| {
        total += gc.pattern.len + gc.text.len;
    }
    return total;
}

const expansion_default_word = ast.Word{
    .parts = &.{.{ .literal = "fallback" }},
};

const expansion_quoted_parts: []const ast.WordPart = &.{
    .{ .literal = "prefix:" },
    .{ .parameter = .{ .simple = "NAME" } },
    .{ .literal = ":" },
    .{ .parameter = .{ .default = .{
        .name = "UNSET",
        .colon = true,
        .word = expansion_default_word,
    } } },
};

const expansion_word = ast.Word{
    .parts = &.{
        .{ .double_quoted = expansion_quoted_parts },
        .{ .literal = ":" },
        .{ .parameter = .{ .simple = "DATA" } },
        .{ .single_quoted = ":tail" },
    },
};

const expansion_words = [_]ast.Word{expansion_word};
const expansion_source_len = "prefix:${NAME}:${UNSET:-fallback}:${DATA}:tail".len;

const BenchId = enum {
    lexer_script,
    parser_script,
    arithmetic_expr,
    glob_match,
    expansion_fields,
    shell_builtins,
};

const BenchCase = struct {
    id: BenchId,
    name: []const u8,
    description: []const u8,
    bytes_per_iter: u64 = 0,
};

const bench_cases = [_]BenchCase{
    .{
        .id = .lexer_script,
        .name = "lexer/script",
        .description = "Tokenize a compound shell workload",
        .bytes_per_iter = lexer_script.len,
    },
    .{
        .id = .parser_script,
        .name = "parser/script",
        .description = "Parse a repeated compound shell workload",
        .bytes_per_iter = parser_script.len,
    },
    .{
        .id = .arithmetic_expr,
        .name = "arithmetic/expr",
        .description = "Evaluate a variable-heavy arithmetic expression",
        .bytes_per_iter = arithmetic_expression.len,
    },
    .{
        .id = .glob_match,
        .name = "glob/match",
        .description = "Match representative glob patterns",
        .bytes_per_iter = globCaseBytes(),
    },
    .{
        .id = .expansion_fields,
        .name = "expansion/fields",
        .description = "Expand parameters, quoting, and field splitting",
        .bytes_per_iter = expansion_source_len,
    },
    .{
        .id = .shell_builtins,
        .name = "shell/builtins",
        .description = "Run a builtin-only end-to-end script",
        .bytes_per_iter = shell_script.len,
    },
};

const Config = struct {
    list_only: bool = false,
    help: bool = false,
    filter: ?[]const u8 = null,
    min_time_ms: u64 = default_min_time_ms,
    iterations: ?usize = null,
    samples: usize = default_samples,
};

const RunResult = struct {
    elapsed_ns: u64,
    checksum: u64,
};

const BenchResult = struct {
    iterations: usize,
    best_ns: u64,
    checksum: u64,
};

const ArgError = error{
    InvalidArgument,
    MissingValue,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    const config = parseArgs(args[1..]) catch {
        try usage(stdout);
        try stdout.flush();
        std.process.exit(1);
    };

    if (config.help) {
        try usage(stdout);
        try stdout.flush();
        return;
    }

    if (config.list_only) {
        try listBenchmarks(stdout);
        try stdout.flush();
        return;
    }

    if (builtin.mode == .Debug or builtin.mode == .ReleaseSafe) {
        try stdout.print(
            "warning: benchmark results are noisy in {}; use -Doptimize=ReleaseFast for meaningful numbers\n\n",
            .{builtin.mode},
        );
    }

    try stdout.print("zigsh benchmark suite ({})\n", .{builtin.mode});
    if (config.filter) |filter| {
        try stdout.print("filter: {s}\n", .{filter});
    }
    if (config.iterations) |iterations| {
        try stdout.print("fixed iterations: {d}\n", .{iterations});
    } else {
        try stdout.print("target time: {d} ms, samples: {d}\n", .{ config.min_time_ms, config.samples });
    }
    try stdout.print("\n{s:24} {s:>10} {s:>12} {s:>12} {s:>11}\n", .{
        "benchmark",
        "iters",
        "best/op",
        "ops/s",
        "MiB/s",
    });

    var matched: usize = 0;
    for (bench_cases) |bench| {
        if (!matchesFilter(bench, config.filter)) continue;
        matched += 1;

        const result = try benchmarkCase(bench, config);
        try printBenchResult(stdout, bench, result);
        try stdout.flush();
    }

    if (matched == 0) {
        try stdout.print("\nno benchmarks matched the current filter\n", .{});
        try stdout.flush();
        std.process.exit(1);
    }
}

fn parseArgs(args: []const []const u8) ArgError!Config {
    var config = Config{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help")) {
            config.help = true;
        } else if (std.mem.eql(u8, arg, "--list")) {
            config.list_only = true;
        } else if (std.mem.eql(u8, arg, "--filter")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            config.filter = args[i];
        } else if (std.mem.startsWith(u8, arg, "--filter=")) {
            config.filter = arg["--filter=".len..];
        } else if (std.mem.eql(u8, arg, "--iterations")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            config.iterations = std.fmt.parseUnsigned(usize, args[i], 10) catch return error.InvalidArgument;
        } else if (std.mem.startsWith(u8, arg, "--iterations=")) {
            config.iterations = std.fmt.parseUnsigned(usize, arg["--iterations=".len..], 10) catch return error.InvalidArgument;
        } else if (std.mem.eql(u8, arg, "--min-ms")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            config.min_time_ms = std.fmt.parseUnsigned(u64, args[i], 10) catch return error.InvalidArgument;
        } else if (std.mem.startsWith(u8, arg, "--min-ms=")) {
            config.min_time_ms = std.fmt.parseUnsigned(u64, arg["--min-ms=".len..], 10) catch return error.InvalidArgument;
        } else if (std.mem.eql(u8, arg, "--samples")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            config.samples = std.fmt.parseUnsigned(usize, args[i], 10) catch return error.InvalidArgument;
        } else if (std.mem.startsWith(u8, arg, "--samples=")) {
            config.samples = std.fmt.parseUnsigned(usize, arg["--samples=".len..], 10) catch return error.InvalidArgument;
        } else {
            return error.InvalidArgument;
        }
    }

    if (config.min_time_ms == 0) config.min_time_ms = 1;
    if (config.samples == 0) config.samples = 1;
    if (config.iterations) |iterations| {
        if (iterations == 0) config.iterations = 1;
    }
    return config;
}

fn usage(writer: anytype) !void {
    try writer.print(
        \\usage: zig build bench -- [options]
        \\
        \\options:
        \\  --list                 List available benchmarks
        \\  --filter <substring>   Run only matching benchmark names
        \\  --iterations <count>   Use a fixed iteration count per benchmark
        \\  --min-ms <ms>          Target timing window for auto-calibration
        \\  --samples <count>      Timed samples per benchmark
        \\  --help                 Show this help
        \\
        \\example:
        \\  zig build bench -Doptimize=ReleaseFast -- --filter parser
        \\
    , .{});
}

fn listBenchmarks(writer: anytype) !void {
    try writer.print("available benchmarks:\n", .{});
    for (bench_cases) |bench| {
        try writer.print("  {s:18}  {s}\n", .{ bench.name, bench.description });
    }
}

fn matchesFilter(bench: BenchCase, filter: ?[]const u8) bool {
    const needle = filter orelse return true;
    return std.mem.indexOf(u8, bench.name, needle) != null;
}

fn benchmarkCase(bench: BenchCase, config: Config) !BenchResult {
    const iterations = config.iterations orelse try calibrateIterations(bench.id, config.min_time_ms);
    _ = try runBenchIterations(bench.id, @min(iterations, 2));

    var best_ns: u64 = std.math.maxInt(u64);
    var checksum: u64 = 0;
    for (0..config.samples) |_| {
        const sample = try runBenchIterations(bench.id, iterations);
        checksum +%= sample.checksum;
        if (sample.elapsed_ns < best_ns) best_ns = sample.elapsed_ns;
    }

    std.mem.doNotOptimizeAway(checksum);
    return .{
        .iterations = iterations,
        .best_ns = best_ns,
        .checksum = checksum,
    };
}

fn calibrateIterations(id: BenchId, min_time_ms: u64) !usize {
    const target_ns = min_time_ms * std.time.ns_per_ms;

    var probe_iterations: usize = 1;
    var probe = try runBenchIterations(id, probe_iterations);
    while (probe.elapsed_ns < calibration_floor_ns and probe_iterations < max_auto_iterations) {
        probe_iterations = @min(probe_iterations * 10, max_auto_iterations);
        probe = try runBenchIterations(id, probe_iterations);
    }

    if (probe.elapsed_ns == 0) return 1;

    const estimate =
        (@as(u128, probe_iterations) * @as(u128, target_ns) + @as(u128, probe.elapsed_ns) - 1) /
        @as(u128, probe.elapsed_ns);
    var iterations: usize = @intCast(@min(estimate, @as(u128, max_auto_iterations)));
    if (iterations == 0) iterations = 1;
    return iterations;
}

fn runBenchIterations(id: BenchId, iterations: usize) !RunResult {
    var timer = try std.time.Timer.start();
    const checksum = switch (id) {
        .lexer_script => try runLexer(iterations),
        .parser_script => try runParser(iterations),
        .arithmetic_expr => try runArithmetic(iterations),
        .glob_match => try runGlob(iterations),
        .expansion_fields => try runExpansion(iterations),
        .shell_builtins => try runShell(iterations),
    };
    return .{
        .elapsed_ns = timer.read(),
        .checksum = checksum,
    };
}

fn runLexer(iterations: usize) !u64 {
    var total: u64 = 0;
    for (0..iterations) |_| {
        var lex = Lexer.init(lexer_script);
        while (true) {
            const tok = try lex.next();
            total +%= @as(u64, tok.start) + @as(u64, tok.end);
            if (tok.tag == .eof) break;
        }
    }
    return total;
}

fn runParser(iterations: usize) !u64 {
    var total: u64 = 0;
    var buffer: [256 * 1024]u8 = undefined;

    for (0..iterations) |_| {
        var fba = std.heap.FixedBufferAllocator.init(buffer[0..]);
        const alloc = fba.allocator();
        var lex = Lexer.init(parser_script);
        var parser = try Parser.init(alloc, &lex);
        const program = try parser.parseProgram();
        total +%= program.commands.len;
        if (program.commands.len > 0) {
            total +%= program.commands[0].line;
        }
    }
    return total;
}

const ArithmeticLookup = struct {
    fn lookup(name: []const u8) ?[]const u8 {
        if (std.mem.eql(u8, name, "alpha")) return "17";
        if (std.mem.eql(u8, name, "beta")) return "9";
        if (std.mem.eql(u8, name, "gamma")) return "1";
        if (std.mem.eql(u8, name, "delta")) return "29";
        if (std.mem.eql(u8, name, "epsilon")) return "23";
        if (std.mem.eql(u8, name, "zeta")) return "12";
        if (std.mem.eql(u8, name, "eta")) return "41";
        if (std.mem.eql(u8, name, "theta")) return "7";
        return null;
    }
};

fn runArithmetic(iterations: usize) !u64 {
    var total: u64 = 0;
    for (0..iterations) |_| {
        const value = try Arithmetic.evaluate(arithmetic_expression, &ArithmeticLookup.lookup);
        total +%= @as(u64, @bitCast(value));
    }
    return total;
}

fn runGlob(iterations: usize) !u64 {
    var total: u64 = 0;
    for (0..iterations) |_| {
        for (glob_cases) |gc| {
            const matched = if (gc.pathname)
                glob.fnmatchPathname(gc.pattern, gc.text)
            else if (gc.nocase)
                glob.fnmatchNoCase(gc.pattern, gc.text)
            else
                glob.fnmatch(gc.pattern, gc.text);
            total +%= if (matched) 1 else 0;
        }
    }
    return total;
}

fn runExpansion(iterations: usize) !u64 {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var env = Environment.init(gpa);
    defer env.deinit();
    var jobs = JobTable.init(gpa);
    defer jobs.deinit();

    env.options.noglob = true;
    try env.set("NAME", "zigsh", false);
    try env.set("DATA", "alpha beta gamma delta epsilon", false);

    var total: u64 = 0;
    var buffer: [64 * 1024]u8 = undefined;

    for (0..iterations) |_| {
        var fba = std.heap.FixedBufferAllocator.init(buffer[0..]);
        var exp = Expander.init(fba.allocator(), &env, &jobs);
        const fields = try exp.expandWordsToFields(expansion_words[0..]);
        total +%= fields.len;
        for (fields) |field| {
            total +%= field.len;
        }
    }
    return total;
}

fn runShell(iterations: usize) !u64 {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var sh = Shell.init(gpa);
    sh.linkJobTable();
    sh.linkHistory();
    defer sh.deinit();

    sh.env.options.noglob = true;

    var total: u64 = 0;
    for (0..iterations) |_| {
        const status = sh.executeSource(shell_script);
        if (status != 0) return error.BenchmarkFailed;
        total +%= shell_script.len;
    }
    return total;
}

fn printBenchResult(writer: anytype, bench: BenchCase, result: BenchResult) !void {
    const ns_per_op = @as(f64, @floatFromInt(result.best_ns)) / @as(f64, @floatFromInt(result.iterations));
    const ops_per_sec = @as(f64, @floatFromInt(result.iterations)) * @as(f64, std.time.ns_per_s) /
        @as(f64, @floatFromInt(result.best_ns));
    const mib_per_sec = if (bench.bytes_per_iter == 0)
        null
    else
        (@as(f64, @floatFromInt(bench.bytes_per_iter * result.iterations)) * @as(f64, std.time.ns_per_s) /
            @as(f64, @floatFromInt(result.best_ns))) / @as(f64, MiB);

    var duration_buf: [32]u8 = undefined;
    var ops_buf: [32]u8 = undefined;

    const duration = try formatDuration(&duration_buf, ns_per_op);
    const ops_rate = try formatOpsRate(&ops_buf, ops_per_sec);

    try writer.print("{s:24} {d:10} {s:>12} {s:>12} ", .{
        bench.name,
        result.iterations,
        duration,
        ops_rate,
    });
    if (mib_per_sec) |rate| {
        try writer.print("{d:11.1}\n", .{rate});
    } else {
        try writer.print("{s:>11}\n", .{"-"});
    }
}

fn formatDuration(buf: []u8, ns_per_op: f64) ![]const u8 {
    if (ns_per_op < 1_000.0) {
        return std.fmt.bufPrint(buf, "{d:.1} ns", .{ns_per_op});
    }
    if (ns_per_op < 1_000_000.0) {
        return std.fmt.bufPrint(buf, "{d:.2} us", .{ns_per_op / 1_000.0});
    }
    if (ns_per_op < 1_000_000_000.0) {
        return std.fmt.bufPrint(buf, "{d:.2} ms", .{ns_per_op / 1_000_000.0});
    }
    return std.fmt.bufPrint(buf, "{d:.2} s", .{ns_per_op / 1_000_000_000.0});
}

fn formatOpsRate(buf: []u8, ops_per_sec: f64) ![]const u8 {
    if (ops_per_sec >= 1_000_000.0) {
        return std.fmt.bufPrint(buf, "{d:.1} M", .{ops_per_sec / 1_000_000.0});
    }
    if (ops_per_sec >= 1_000.0) {
        return std.fmt.bufPrint(buf, "{d:.1} K", .{ops_per_sec / 1_000.0});
    }
    return std.fmt.bufPrint(buf, "{d:.0}", .{ops_per_sec});
}
