const std = @import("std");
const Lexer = @import("lexer.zig").Lexer;
const Parser = @import("parser.zig").Parser;
const Executor = @import("executor.zig").Executor;
const Environment = @import("env.zig").Environment;
const JobTable = @import("jobs.zig").JobTable;
const LineEditor = @import("line_editor.zig").LineEditor;
const signals = @import("signals.zig");
const posix = @import("posix.zig");
const Expander = @import("expander.zig").Expander;
const ast = @import("ast.zig");

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
        signals.clearActiveState();
        self.history.saveFile();
        self.history.deinit();
        self.jobs.deinit();
        for (&self.env.signal_state.trap_handlers) |*handler| {
            if (handler.*) |h| {
                self.gpa.free(h);
                handler.* = null;
            }
        }
        self.env.deinit();
    }

    fn executeTrap(self: *Shell, action: []const u8) void {
        const saved_status = self.env.last_exit_status;
        const saved_should_exit = self.env.should_exit;
        const saved_exit_value = self.env.exit_value;
        const saved_should_return = self.env.should_return;
        const saved_return_value = self.env.return_value;

        self.env.should_exit = false;
        self.env.should_return = false;
        _ = self.executeSource(action);

        if (!self.env.should_exit) {
            self.env.last_exit_status = saved_status;
            self.env.should_exit = saved_should_exit;
            self.env.exit_value = saved_exit_value;
            self.env.should_return = saved_should_return;
            self.env.return_value = saved_return_value;
        }
    }

    fn checkSignalTraps(self: *Shell) void {
        while (signals.checkPendingSignals(&self.env.signal_state)) |sig| {
            if (sig == signals.SIGINT and !self.env.options.interactive) {
                continue;
            }
            if (self.env.signal_state.trap_handlers[@intCast(sig)]) |action| {
                self.executeTrap(action);
            }
        }
    }

    pub fn runExitTrap(self: *Shell) void {
        if (signals.getExitTrap(&self.env.signal_state)) |action| {
            signals.setExitTrap(&self.env.signal_state, null);
            const saved_status = self.env.last_exit_status;
            const saved_exit = self.env.should_exit;
            const saved_value = self.env.exit_value;
            const saved_should_return = self.env.should_return;
            const saved_return_value = self.env.return_value;
            self.env.should_exit = false;
            self.env.should_return = false;
            _ = self.executeSource(action);
            if (self.env.should_exit) {} else {
                self.env.last_exit_status = saved_status;
                self.env.should_exit = saved_exit;
                self.env.exit_value = saved_value;
                self.env.should_return = saved_should_return;
                self.env.return_value = saved_return_value;
            }
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
        parser.env = &self.env;

        var executor = Executor.init(alloc, &self.env, &self.jobs);
        var status: u8 = 0;

        while (true) {
            const cmd = parser.parseOneCommand() catch |err| {
                self.reportError("syntax error", err);
                return 2;
            };
            if (cmd == null) break;
            const result = executor.executeCompleteCommandTyped(cmd.?);
            status = result.status;
            self.env.last_exit_status = result.status;
            if (!self.env.should_exit and !self.env.should_return) {
                self.checkSignalTraps();
            }
            switch (result.flow) {
                .none => {},
                else => break,
            }
        }

        return status;
    }

    fn isIncompleteError(err: anyerror) bool {
        return err == error.UnexpectedEOF or
            err == error.UnterminatedSingleQuote or
            err == error.UnterminatedDoubleQuote or
            err == error.UnterminatedBackquote or
            err == error.UnterminatedParenthesis or
            err == error.ExpectedDo or
            err == error.ExpectedDone or
            err == error.ExpectedThen or
            err == error.ExpectedFi or
            err == error.ExpectedEsac or
            err == error.ExpectedBraceClose or
            err == error.ExpectedIn;
    }

    const AccumulationResult = union(enum) {
        executed: u8,
        incomplete,
        retry,
    };

    fn executeParsedProgram(self: *Shell, alloc: std.mem.Allocator, program: ast.Program) u8 {
        var executor = Executor.init(alloc, &self.env, &self.jobs);
        var status: u8 = 0;

        for (program.commands) |cmd| {
            const result = executor.executeCompleteCommandTyped(cmd);
            status = result.status;
            self.env.last_exit_status = result.status;
            if (!self.env.should_exit and !self.env.should_return) {
                self.checkSignalTraps();
            }
            switch (result.flow) {
                .none => {},
                else => break,
            }
        }

        return status;
    }

    fn executeAccumulated(self: *Shell, source: []const u8) AccumulationResult {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const alloc = arena.allocator();

        var lexer = Lexer.init(source);
        var parser = Parser.init(alloc, &lexer) catch return .retry;
        parser.env = &self.env;
        if (parser.parseProgram()) |program| {
            return .{ .executed = self.executeParsedProgram(alloc, program) };
        } else |err| {
            if (isIncompleteError(err)) return .incomplete;
            return .{ .executed = self.executeSource(source) };
        }
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
        self.runExitTrap();
        if (self.env.should_exit) return self.env.exit_value;
        return status;
    }

    pub fn runInteractive(self: *Shell) u8 {
        self.interactive = true;
        signals.setActiveState(&self.env.signal_state);
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

            const ps1_raw = self.env.get("PS1") orelse "$ ";
            const prompt_expanded = Expander.expandPromptString(self.gpa, ps1_raw, &self.env, &self.jobs) catch null;
            defer if (prompt_expanded) |p| self.gpa.free(p);
            const prompt = prompt_expanded orelse ps1_raw;
            const line = editor.readLine(prompt) orelse break;
            if (line.len == 0) continue;

            var accum: std.ArrayListUnmanaged(u8) = .empty;
            defer accum.deinit(self.gpa);
            accum.appendSlice(self.gpa, line) catch continue;

            while (true) {
                switch (self.executeAccumulated(accum.items)) {
                    .executed => |status| {
                        self.env.last_exit_status = status;
                        break;
                    },
                    .incomplete => {
                        const ps2_raw = self.env.get("PS2") orelse "> ";
                        const ps2_expanded = Expander.expandPromptString(self.gpa, ps2_raw, &self.env, &self.jobs) catch null;
                        defer if (ps2_expanded) |p| self.gpa.free(p);
                        const ps2 = ps2_expanded orelse ps2_raw;
                        const cont = editor.readLine(ps2) orelse break;
                        accum.append(self.gpa, '\n') catch break;
                        accum.appendSlice(self.gpa, cont) catch break;
                    },
                    .retry => break,
                }
            }
        }
        self.runExitTrap();
        if (self.env.should_exit) return self.env.exit_value;
        return self.env.last_exit_status;
    }

    fn runSimple(self: *Shell) u8 {
        var read_buf: [4096]u8 = undefined;
        var pending: std.ArrayListUnmanaged(u8) = .empty;
        defer pending.deinit(self.gpa);

        while (!self.env.should_exit) {
            self.jobs.updateJobStatus();
            self.jobs.notifyDoneJobs();
            self.checkSignalTraps();

            const n = posix.read(0, &read_buf) catch break;
            if (n == 0) break;
            pending.appendSlice(self.gpa, read_buf[0..n]) catch break;
            self.drainStreamBuffer(&pending, false);
            if (self.env.should_return) break;
        }

        if (!self.env.should_exit and !self.env.should_return) {
            self.drainStreamBuffer(&pending, true);
        }
        self.runExitTrap();
        if (self.env.should_exit) return self.env.exit_value;
        return self.env.last_exit_status;
    }

    fn drainStreamBuffer(self: *Shell, pending: *std.ArrayListUnmanaged(u8), eof: bool) void {
        while (pending.items.len > 0 and !self.env.should_exit and !self.env.should_return) {
            var arena = std.heap.ArenaAllocator.init(self.gpa);
            defer arena.deinit();
            const alloc = arena.allocator();

            var lexer = Lexer.init(pending.items);
            var parser = Parser.init(alloc, &lexer) catch {
                if (eof) {
                    self.reportError("syntax error", error.UnexpectedEOF);
                    self.env.last_exit_status = 2;
                    pending.clearRetainingCapacity();
                }
                return;
            };
            parser.env = &self.env;

            const cmd = parser.parseOneCommand() catch |err| {
                if (!eof and isIncompleteError(err)) {
                    return;
                }
                self.reportError("syntax error", err);
                self.env.last_exit_status = 2;
                pending.clearRetainingCapacity();
                return;
            };
            if (cmd == null) {
                pending.clearRetainingCapacity();
                return;
            }

            var executor = Executor.init(alloc, &self.env, &self.jobs);
            const result = executor.executeCompleteCommandTyped(cmd.?);
            self.env.last_exit_status = result.status;
            if (!self.env.should_exit and !self.env.should_return) {
                self.checkSignalTraps();
            }
            switch (result.flow) {
                .none => {},
                else => return,
            }

            const consumed: usize = @intCast(parser.lexer.pos);
            if (consumed == 0 or consumed > pending.items.len) {
                pending.clearRetainingCapacity();
                return;
            }

            const remaining = pending.items[consumed..];
            if (remaining.len > 0) {
                std.mem.copyForwards(u8, pending.items[0..remaining.len], remaining);
            }
            pending.items.len = remaining.len;
        }
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
