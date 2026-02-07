const std = @import("std");
const Lexer = @import("lexer.zig").Lexer;
const Parser = @import("parser.zig").Parser;
const Executor = @import("executor.zig").Executor;
const Environment = @import("env.zig").Environment;
const JobTable = @import("jobs.zig").JobTable;
const LineEditor = @import("line_editor.zig").LineEditor;
const signals = @import("signals.zig");
const posix = @import("posix.zig");

pub const Shell = struct {
    env: Environment,
    jobs: JobTable,
    history: LineEditor.History,
    gpa: std.mem.Allocator,
    interactive: bool,

    pub fn init(gpa: std.mem.Allocator) Shell {
        return .{
            .env = Environment.init(gpa),
            .jobs = JobTable.init(gpa),
            .history = LineEditor.History.init(gpa),
            .gpa = gpa,
            .interactive = false,
        };
    }

    pub fn linkJobTable(self: *Shell) void {
        self.env.job_table = &self.jobs;
    }

    pub fn linkHistory(self: *Shell) void {
        self.env.history = &self.history;
    }

    pub fn loadEnvFile(self: *Shell) void {
        if (self.env.get("ENV")) |env_path| {
            _ = self.executeFile(env_path);
        }
    }

    pub fn deinit(self: *Shell) void {
        self.history.saveFile();
        self.history.deinit();
        self.jobs.deinit();
        for (&signals.trap_handlers) |*handler| {
            if (handler.*) |h| {
                self.gpa.free(h);
                handler.* = null;
            }
        }
        self.env.deinit();
    }

    fn executeTrap(self: *Shell, action: []const u8) void {
        _ = self.executeSource(action);
    }

    fn checkSignalTraps(self: *Shell) void {
        while (signals.checkPendingSignals()) |sig| {
            if (signals.trap_handlers[@intCast(sig)]) |action| {
                self.executeTrap(action);
            }
        }
    }

    fn executeExitTrap(self: *Shell) void {
        if (signals.getExitTrap()) |action| {
            signals.setExitTrap(null);
            self.executeTrap(action);
            self.gpa.free(action);
        }
    }

    pub fn executeSource(self: *Shell, source: []const u8) u8 {
        if (self.env.options.verbose) {
            posix.writeAll(2, source);
            if (source.len > 0 and source[source.len - 1] != '\n') {
                posix.writeAll(2, "\n");
            }
        }

        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const alloc = arena.allocator();

        var lexer = Lexer.init(source);
        var parser = Parser.init(alloc, &lexer) catch return 2;
        const program = parser.parseProgram() catch |err| {
            self.reportError("syntax error", err);
            return 2;
        };

        var executor = Executor.init(alloc, &self.env, &self.jobs);
        const status = executor.executeProgram(program);
        self.env.last_exit_status = status;
        return status;
    }

    pub fn executeFile(self: *Shell, path: []const u8) u8 {
        const fd = posix.open(path, posix.oRdonly(), 0) catch {
            posix.writeAll(2, "zigsh: ");
            posix.writeAll(2, path);
            posix.writeAll(2, ": No such file or directory\n");
            return 127;
        };
        defer posix.close(fd);

        var content: std.ArrayListUnmanaged(u8) = .empty;
        defer content.deinit(self.gpa);
        posix.readToEnd(fd, self.gpa, &content) catch return 1;

        const status = self.executeSource(content.items);
        self.executeExitTrap();
        return status;
    }

    pub fn runInteractive(self: *Shell) u8 {
        self.interactive = true;
        const is_tty = posix.isatty(0);
        if (is_tty) {
            signals.setupInteractiveSignals();
            self.loadHistory();
        }

        if (is_tty) {
            return self.runWithLineEditor();
        } else {
            return self.runSimple();
        }
    }

    fn runWithLineEditor(self: *Shell) u8 {
        var editor = LineEditor.init(&self.history);

        while (!self.env.should_exit) {
            self.jobs.updateJobStatus();
            self.jobs.notifyDoneJobs();
            self.checkSignalTraps();

            const prompt = self.env.get("PS1") orelse "$ ";
            const line = editor.readLine(prompt) orelse break;
            if (line.len == 0) continue;

            if (self.env.options.verbose) {
                posix.writeAll(2, line);
                posix.writeAll(2, "\n");
            }
            _ = self.executeSource(line);
        }
        self.executeExitTrap();
        return self.env.exit_value;
    }

    fn runSimple(self: *Shell) u8 {
        var buf: [4096]u8 = undefined;

        while (!self.env.should_exit) {
            self.jobs.updateJobStatus();
            self.jobs.notifyDoneJobs();
            self.checkSignalTraps();

            const prompt = self.env.get("PS1") orelse "$ ";
            posix.writeAll(2, prompt);

            const n = posix.read(0, &buf) catch break;
            if (n == 0) break;
            const line = buf[0..n];

            if (self.env.options.verbose) {
                posix.writeAll(2, line);
                if (line.len > 0 and line[line.len - 1] != '\n') {
                    posix.writeAll(2, "\n");
                }
            }
            _ = self.executeSource(line);
        }
        self.executeExitTrap();
        return self.env.exit_value;
    }

    fn loadHistory(self: *Shell) void {
        if (self.env.get("HISTFILE")) |path| {
            self.history.loadFile(path);
        } else if (self.env.get("HOME")) |home| {
            var path_buf: [4096]u8 = undefined;
            const path = std.fmt.bufPrint(&path_buf, "{s}/.zigsh_history", .{home}) catch return;
            self.history.loadFile(path);
            self.env.set("HISTFILE", path, false) catch {};
        }
    }

    fn reportError(_: *Shell, prefix: []const u8, _: anyerror) void {
        posix.writeAll(2, "zigsh: ");
        posix.writeAll(2, prefix);
        posix.writeAll(2, "\n");
    }
};
