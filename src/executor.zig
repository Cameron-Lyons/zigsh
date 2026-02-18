const std = @import("std");
const ast = @import("ast.zig");
const Lexer = @import("lexer.zig").Lexer;
const Parser = @import("parser.zig").Parser;
const Environment = @import("env.zig").Environment;
const expander_mod = @import("expander.zig");
const Expander = expander_mod.Expander;
const ExpandError = expander_mod.ExpandError;
const JobTable = @import("jobs.zig").JobTable;
const builtins = @import("builtins.zig");
const redirect = @import("redirect.zig");
const posix = @import("posix.zig");
const types = @import("types.zig");
const glob = @import("glob.zig");
const token = @import("token.zig");
const signals = @import("signals.zig");
const Arithmetic = @import("arithmetic.zig").Arithmetic;

pub const Executor = struct {
    env: *Environment,
    jobs: *JobTable,
    alloc: std.mem.Allocator,
    in_err_trap: bool = false,
    bang_reached: bool = false,
    current_line: u32 = 0,

    pub fn init(alloc: std.mem.Allocator, env: *Environment, jobs: *JobTable) Executor {
        return .{ .env = env, .jobs = jobs, .alloc = alloc };
    }

    pub fn executeProgram(self: *Executor, program: ast.Program) u8 {
        var status: u8 = 0;
        for (program.commands) |cmd| {
            self.env.abort_line = null;
            status = self.executeCompleteCommand(cmd);
            if (self.env.should_exit) break;
            if (self.env.options.errexit and status != 0 and self.env.errexit_suppressed == 0 and !self.bang_reached) {
                self.env.should_exit = true;
                self.env.exit_value = status;
                break;
            }
        }
        return status;
    }

    pub fn executeCompleteCommand(self: *Executor, cmd: ast.CompleteCommand) u8 {
        if (cmd.bg) {
            return self.executeBackground(cmd.list);
        }
        return self.executeList(cmd.list);
    }

    fn executeBackground(self: *Executor, list: ast.List) u8 {
        const pid = posix.fork() catch {
            posix.writeAll(2, "zigsh: fork failed\n");
            return 1;
        };
        if (pid == 0) {
            signals.clearTrapsForSubshell();
            posix.setpgid(0, 0) catch {};
            posix.exit(self.executeList(list));
        }
        posix.setpgid(pid, pid) catch {};
        self.registerBackground(pid);
        return 0;
    }

    fn executeList(self: *Executor, list: ast.List) u8 {
        var status: u8 = 0;
        if (!self.env.in_subshell) self.env.command_number += 1;
        const first_bg = list.rest.len > 0 and list.rest[0].op == .amp;
        if (first_bg) {
            status = self.runInBackground(list.first);
        } else {
            status = self.executeAndOr(list.first);
        }
        if (!self.env.in_subshell and self.env.options.history) {
            if (self.env.history) |h| {
                if (h.just_cleared) {
                    h.just_cleared = false;
                } else {
                    h.count += 1;
                }
            }
        }
        if (self.env.options.errexit and status != 0 and self.env.errexit_suppressed == 0 and !self.bang_reached and !self.env.should_exit) {
            self.env.should_exit = true;
            self.env.exit_value = status;
            return status;
        }

        for (list.rest, 0..) |item, idx| {
            if (self.env.should_exit or self.env.should_return or
                self.env.break_count > 0 or self.env.continue_count > 0) break;
            if (self.env.abort_line) |abort_ln| {
                if (item.and_or.line == 0 or item.and_or.line == abort_ln) continue;
                self.env.abort_line = null;
            }
            if (!self.env.in_subshell) self.env.command_number += 1;
            const next_bg = (idx + 1 < list.rest.len) and list.rest[idx + 1].op == .amp;
            if (next_bg) {
                status = self.runInBackground(item.and_or);
            } else {
                status = self.executeAndOr(item.and_or);
            }
            if (!self.env.in_subshell and self.env.options.history) {
                if (self.env.history) |h| {
                    if (h.just_cleared) {
                        h.just_cleared = false;
                    } else {
                        h.count += 1;
                    }
                }
            }
            if (self.env.options.errexit and status != 0 and self.env.errexit_suppressed == 0 and !self.bang_reached and !self.env.should_exit) {
                self.env.should_exit = true;
                self.env.exit_value = status;
                return status;
            }
        }
        return status;
    }

    fn runInBackground(self: *Executor, and_or: ast.AndOr) u8 {
        const pid = posix.fork() catch {
            posix.writeAll(2, "zigsh: fork failed\n");
            return 1;
        };
        if (pid == 0) {
            signals.clearTrapsForSubshell();
            posix.setpgid(0, 0) catch {};
            const status = self.executeAndOr(and_or);
            posix.exit(status);
        }
        posix.setpgid(pid, pid) catch {};
        self.registerBackground(pid);
        return 0;
    }

    fn setPipeStatus(self: *Executor, statuses: []const u8) void {
        var buf: [256]u8 = undefined;
        var pos: usize = 0;
        for (statuses, 0..) |s, idx| {
            if (idx > 0 and pos < buf.len) {
                buf[pos] = ' ';
                pos += 1;
            }
            const written = std.fmt.bufPrint(buf[pos..], "{d}", .{s}) catch break;
            pos += written.len;
        }
        self.env.set("PIPESTATUS", buf[0..pos], false) catch {};
    }

    fn registerBackground(self: *Executor, pid: posix.pid_t) void {
        self.env.last_bg_pid = pid;
        const job_id = self.jobs.addJob(pid, pid, "background") catch 0;
        var buf: [32]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "[{d}] {d}\n", .{ job_id, pid }) catch "";
        posix.writeAll(2, msg);
    }

    fn executeAndOr(self: *Executor, and_or: ast.AndOr) u8 {
        self.bang_reached = false;
        if (and_or.line > 0) {
            self.current_line = and_or.line;
            var buf: [16]u8 = undefined;
            const line_str = std.fmt.bufPrint(&buf, "{d}", .{and_or.line}) catch "0";
            self.env.set("LINENO", line_str, false) catch {};
        }
        if (and_or.rest.len > 0) self.env.errexit_suppressed += 1;
        var status = self.executePipeline(and_or.first);
        if (and_or.rest.len > 0) self.env.errexit_suppressed -= 1;
        var last_ran = and_or.rest.len == 0;
        for (and_or.rest, 0..) |item, idx| {
            if (self.env.should_exit or self.env.should_return or self.env.abort_line != null or
                self.env.break_count > 0 or self.env.continue_count > 0) break;
            const is_last = idx == and_or.rest.len - 1;
            if (!is_last) self.env.errexit_suppressed += 1;
            var ran = false;
            switch (item.op) {
                .and_if => {
                    if (status == 0) {
                        status = self.executePipeline(item.pipeline);
                        ran = true;
                    }
                },
                .or_if => {
                    if (status != 0) {
                        status = self.executePipeline(item.pipeline);
                        ran = true;
                    }
                },
            }
            if (!is_last) self.env.errexit_suppressed -= 1;
            if (is_last) last_ran = ran;
        }
        if (and_or.rest.len > 0 and !last_ran) self.bang_reached = true;
        self.env.last_exit_status = status;
        if (status != 0 and !self.in_err_trap) {
            if (signals.getErrTrap()) |action| {
                self.in_err_trap = true;
                _ = self.executeInline(action);
                self.in_err_trap = false;
            }
        }
        return status;
    }

    fn executePipeline(self: *Executor, pipeline: ast.Pipeline) u8 {
        if (pipeline.bang) self.env.errexit_suppressed += 1;
        defer if (pipeline.bang) {
            self.env.errexit_suppressed -= 1;
        };
        if (pipeline.commands.len == 1) {
            const status = self.executeCommand(pipeline.commands[0]);
            self.setPipeStatus(&[_]u8{status});
            if (pipeline.bang) {
                self.bang_reached = true;
                return if (status == 0) 1 else 0;
            }
            return status;
        }

        var prev_read_fd: ?types.Fd = null;
        var last_pid: ?posix.pid_t = null;
        var child_pids: [64]posix.pid_t = undefined;
        var num_children: usize = 0;

        const use_lastpipe = self.env.shopt.lastpipe and !self.env.options.monitor;
        var lastpipe_status: ?u8 = null;

        for (pipeline.commands, 0..) |cmd, i| {
            const is_last = (i == pipeline.commands.len - 1);
            var pipe_fds: [2]types.Fd = undefined;

            if (!is_last) {
                const fds = posix.pipe() catch {
                    posix.writeAll(2, "zigsh: pipe failed\n");
                    return 1;
                };
                pipe_fds = fds;
            }

            if (is_last and use_lastpipe) {
                var saved_stdin: ?types.Fd = null;
                if (prev_read_fd) |rd| {
                    saved_stdin = posix.dup(types.STDIN) catch null;
                    posix.dup2(rd, types.STDIN) catch {};
                    posix.close(rd);
                }
                lastpipe_status = self.executeCommand(cmd);
                if (saved_stdin) |saved| {
                    posix.dup2(saved, types.STDIN) catch {};
                    posix.close(saved);
                }
                continue;
            }

            const pid = posix.fork() catch {
                posix.writeAll(2, "zigsh: fork failed\n");
                return 1;
            };

            if (pid == 0) {
                signals.clearTrapsForSubshell();
                self.env.in_subshell = true;
                if (prev_read_fd) |rd| {
                    posix.dup2(rd, types.STDIN) catch posix.exit(1);
                    posix.close(rd);
                }
                if (!is_last) {
                    posix.close(pipe_fds[0]);
                    posix.dup2(pipe_fds[1], types.STDOUT) catch posix.exit(1);
                    posix.close(pipe_fds[1]);
                }
                const status = self.executeCommand(cmd);
                posix.exit(status);
            }

            if (num_children < 64) {
                child_pids[num_children] = pid;
                num_children += 1;
            }
            last_pid = pid;

            if (prev_read_fd) |rd| {
                posix.close(rd);
            }
            if (!is_last) {
                posix.close(pipe_fds[1]);
                prev_read_fd = pipe_fds[0];
            }
        }

        var status: u8 = 0;
        var pipefail_status: u8 = 0;
        var pipe_statuses: [64]u8 = undefined;
        for (child_pids[0..num_children], 0..) |cpid, idx| {
            const result = posix.waitpid(cpid, 0);
            const s = posix.statusFromWait(result.status);
            if (idx < 64) pipe_statuses[idx] = s;
            if (s != 0) pipefail_status = s;
            if (cpid == last_pid) {
                status = s;
            }
        }
        if (lastpipe_status) |lps| {
            if (num_children < 64) {
                pipe_statuses[num_children] = lps;
            }
            status = lps;
            if (lps != 0) pipefail_status = lps;
            self.setPipeStatus(pipe_statuses[0 .. num_children + 1]);
        } else {
            self.setPipeStatus(pipe_statuses[0..num_children]);
        }

        if (self.env.options.pipefail) {
            status = if (pipefail_status != 0) pipefail_status else status;
        }

        if (pipeline.bang) {
            self.bang_reached = true;
            return if (status == 0) 1 else 0;
        }
        return status;
    }

    fn executeCommand(self: *Executor, cmd: ast.Command) u8 {
        switch (cmd) {
            .simple => |simple| return self.executeSimpleCommand(simple),
            .compound => |cp| return self.executeCompound(cp),
            .function_def => |fd| return self.executeFunctionDef(fd),
        }
    }

    fn executeSimpleCommand(self: *Executor, simple: ast.SimpleCommand) u8 {
        if (self.env.options.noexec) return 0;

        var expander = Expander.init(self.alloc, self.env, self.jobs);

        if (simple.words.len > 0) {
            const is_declare_cmd = blk: {
                if (simple.words[0].parts.len == 1) {
                    switch (simple.words[0].parts[0]) {
                        .literal => |lit| {
                            break :blk std.mem.eql(u8, lit, "declare") or
                                std.mem.eql(u8, lit, "typeset") or
                                std.mem.eql(u8, lit, "local") or
                                std.mem.eql(u8, lit, "export") or
                                std.mem.eql(u8, lit, "readonly");
                        },
                        else => {},
                    }
                }
                break :blk false;
            };
            if (!is_declare_cmd) {
                for (simple.assigns) |assign| {
                    if (assign.array_values != null) {
                        posix.writeAll(2, "zigsh: ");
                        posix.writeAll(2, assign.name);
                        posix.writeAll(2, ": can't assign array to env binding\n");
                        self.env.last_exit_status = 2;
                        return 2;
                    }
                }
            }
        }

        const saved_exit = self.env.last_exit_status;
        for (simple.assigns) |assign| {
            if (assign.array_values) |arr_words| {
                {
                    var elems: std.ArrayListUnmanaged([]const u8) = .empty;
                    if (assign.append) {
                        if (self.env.getArray(assign.name)) |existing| {
                            elems.appendSlice(self.alloc, existing) catch {};
                        } else if (self.env.get(assign.name)) |scalar| {
                            elems.append(self.alloc, scalar) catch {};
                        }
                    }
                    for (arr_words) |w| {
                        const expanded = expander.expandWordsToFields(&.{w}) catch continue;
                        for (expanded) |field| {
                            elems.append(self.alloc, field) catch {};
                        }
                    }
                    const elements = elems.toOwnedSlice(self.alloc) catch continue;
                    self.env.setArray(assign.name, elements) catch {};
                }
                continue;
            }
            const value = expander.expandWord(assign.value) catch |err| {
                if (err == error.UnsetVariable and self.env.options.nounset) {
                    self.env.abort_line = self.current_line;
                    if (!self.env.options.interactive) {
                        self.env.should_exit = true;
                        self.env.exit_value = 1;
                    }
                    return 1;
                }
                continue;
            };
            if (simple.words.len == 0) {
                if (std.mem.indexOfScalar(u8, assign.name, '[')) |bracket_idx| {
                    const base = assign.name[0..bracket_idx];
                    const rest = assign.name[bracket_idx + 1 ..];
                    const close = blk: {
                        var depth: u32 = 0;
                        for (rest, 0..) |rc, ri| {
                            if (rc == '[') depth += 1;
                            if (rc == ']') {
                                if (depth == 0) break :blk ri;
                                depth -= 1;
                            }
                        }
                        break :blk rest.len;
                    };
                    const subscript = rest[0..close];
                    const idx: usize = blk: {
                        const n = std.fmt.parseInt(i64, subscript, 10) catch {
                            const arith_result = expander.expandArithmetic(subscript) catch break :blk 0;
                            break :blk @intCast(std.fmt.parseInt(i64, arith_result, 10) catch 0);
                        };
                        if (n < 0) {
                            const arr_len = if (self.env.getArray(base)) |elems| elems.len else 0;
                            const neg: usize = @intCast(-n);
                            break :blk if (neg <= arr_len) arr_len - neg else 0;
                        }
                        break :blk @intCast(n);
                    };
                    if (assign.append) {
                        var existing: []const u8 = "";
                        if (self.env.getArray(base)) |elems| {
                            if (idx < elems.len) existing = elems[idx];
                        }
                        const appended = std.fmt.allocPrint(self.alloc, "{s}{s}", .{ existing, value }) catch value;
                        self.env.setArrayElement(base, idx, appended) catch {};
                    } else {
                        self.env.setArrayElement(base, idx, value) catch {};
                    }
                } else {
                    if (self.env.getArray(assign.name) != null) {
                        if (assign.append) {
                            var existing: []const u8 = "";
                            if (self.env.getArray(assign.name)) |elems| {
                                if (elems.len > 0) existing = elems[0];
                            }
                            const appended = std.fmt.allocPrint(self.alloc, "{s}{s}", .{ existing, value }) catch value;
                            self.env.setArrayElement(assign.name, 0, appended) catch {};
                        } else {
                            self.env.setArrayElement(assign.name, 0, value) catch {};
                        }
                    } else {
                        const final_value = if (assign.append) blk: {
                            const existing = self.env.get(assign.name) orelse "";
                            break :blk std.fmt.allocPrint(self.alloc, "{s}{s}", .{ existing, value }) catch value;
                        } else value;
                        self.env.set(assign.name, final_value, false) catch |err| {
                            if (err == error.ReadonlyVariable) {
                                posix.writeAll(2, "zigsh: ");
                                posix.writeAll(2, assign.name);
                                posix.writeAll(2, ": readonly variable\n");
                                if (!self.env.options.interactive) {
                                    self.env.should_exit = true;
                                    self.env.exit_value = 1;
                                }
                                return 1;
                            }
                        };
                    }
                }
            }
        }

        if (simple.words.len == 0) {
            if (simple.redirects.len > 0) {
                var redir_state: redirect.RedirectState = .{};
                for (simple.redirects) |redir| {
                    self.applyAstRedirect(redir, &redir_state, &expander) catch {
                        redir_state.restore();
                        return 1;
                    };
                }
                redir_state.restore();
            }
            if (self.env.last_exit_status != saved_exit) return self.env.last_exit_status;
            return 0;
        }

        const is_assign_builtin = blk: {
            if (simple.words.len > 0 and simple.words[0].parts.len == 1) {
                switch (simple.words[0].parts[0]) {
                    .literal => |lit| {
                        break :blk std.mem.eql(u8, lit, "export") or
                            std.mem.eql(u8, lit, "readonly") or
                            std.mem.eql(u8, lit, "local") or
                            std.mem.eql(u8, lit, "declare") or
                            std.mem.eql(u8, lit, "typeset");
                    },
                    else => {},
                }
            }
            break :blk false;
        };

        var fields = if (is_assign_builtin)
            self.expandAssignBuiltinArgs(&expander, simple.words) catch return 1
        else
            expander.expandWordsToFields(simple.words) catch |err| {
                if (err == error.UnsetVariable) {
                    if (self.env.options.nounset) {
                        self.env.abort_line = self.current_line;
                        if (!self.env.options.interactive) {
                            self.env.should_exit = true;
                            self.env.exit_value = 1;
                        }
                    }
                    return 1;
                } else if (err == error.ArithmeticError) {
                    posix.writeAll(2, "zigsh: arithmetic syntax error\n");
                    if (!self.env.options.interactive) {
                        self.env.should_exit = true;
                        self.env.exit_value = 1;
                    }
                    return 1;
                } else {
                    posix.writeAll(2, "zigsh: expansion error\n");
                }
                return 1;
            };
        if (is_assign_builtin and simple.assigns.len > 0) {
            var extra_names: std.ArrayListUnmanaged([]const u8) = .empty;
            for (simple.assigns) |assign| {
                if (assign.array_values != null) {
                    extra_names.append(self.alloc, assign.name) catch {};
                }
            }
            if (extra_names.items.len > 0) {
                var extended: std.ArrayListUnmanaged([]const u8) = .empty;
                extended.ensureTotalCapacity(self.alloc, fields.len + extra_names.items.len) catch {};
                extended.appendSlice(self.alloc, fields) catch {};
                extended.appendSlice(self.alloc, extra_names.items) catch {};
                fields = extended.items;
            }
        }

        if (fields.len == 0) {
            if (simple.assigns.len > 0 and simple.words.len > 0) {
                for (simple.assigns) |assign| {
                    const value = expander.expandWord(assign.value) catch continue;
                    self.env.set(assign.name, value, false) catch {};
                }
            }
            return self.env.last_exit_status;
        }

        if (self.env.options.xtrace) {
            posix.writeAll(2, self.env.get("PS4") orelse "+ ");
            for (fields, 0..) |f, idx| {
                if (idx > 0) posix.writeAll(2, " ");
                var needs_quote = false;
                for (f) |ch| {
                    if (ch == ' ' or ch == '\t' or ch == '\'' or ch == '"' or
                        ch == '\\' or ch == '$' or ch == '`' or ch == '|' or
                        ch == '&' or ch == ';' or ch == '(' or ch == ')' or
                        ch == '<' or ch == '>' or ch == '*' or ch == '?' or
                        ch == '[' or ch == ']' or ch == '{' or ch == '}' or
                        ch == '~' or ch == '#' or ch == '!' or ch == '\n')
                    {
                        needs_quote = true;
                        break;
                    }
                }
                if (needs_quote and f.len > 0) {
                    posix.writeAll(2, "'");
                    posix.writeAll(2, f);
                    posix.writeAll(2, "'");
                } else {
                    posix.writeAll(2, f);
                }
            }
            posix.writeAll(2, "\n");
        }

        var redir_state: redirect.RedirectState = .{};
        for (simple.redirects) |redir| {
            self.applyAstRedirect(redir, &redir_state, &expander) catch {
                redir_state.restore();
                return 1;
            };
        }

        const cmd_name = fields[0];
        var status: u8 = 0;

        if (std.mem.eql(u8, cmd_name, ".") or std.mem.eql(u8, cmd_name, "source")) {
            for (simple.assigns) |assign| {
                const value = expander.expandWord(assign.value) catch "";
                self.env.set(assign.name, value, false) catch {};
            }
            status = self.executeSourceBuiltin(fields);
        } else if (std.mem.eql(u8, cmd_name, "eval")) {
            for (simple.assigns) |assign| {
                const value = expander.expandWord(assign.value) catch "";
                self.env.set(assign.name, value, false) catch {};
            }
            status = self.executeEvalBuiltin(fields);
        } else if (std.mem.eql(u8, cmd_name, "exec")) {
            var cmd_idx: usize = 1;
            while (cmd_idx < fields.len) {
                if (std.mem.eql(u8, fields[cmd_idx], "--")) {
                    cmd_idx += 1;
                    break;
                } else if (std.mem.eql(u8, fields[cmd_idx], "-a") and cmd_idx + 1 < fields.len) {
                    cmd_idx += 2;
                } else break;
            }
            if (cmd_idx >= fields.len) {
                for (simple.assigns) |assign| {
                    const value = expander.expandWord(assign.value) catch "";
                    self.env.set(assign.name, value, true) catch {};
                }
                self.env.last_exit_status = 0;
                return 0;
            }
            status = self.executeExecBuiltin(fields, simple.assigns, &expander);
            redir_state.restore();
            self.env.last_exit_status = status;
            return status;
        } else if (std.mem.eql(u8, cmd_name, "command")) {
            status = self.executeCommandBuiltin(fields, simple.assigns, &expander);
        } else if (std.mem.eql(u8, cmd_name, "builtin")) {
            if (fields.len < 2) {
                status = 0;
            } else {
                const bname = fields[1];
                if (std.mem.eql(u8, bname, ".") or std.mem.eql(u8, bname, "source")) {
                    status = self.executeSourceBuiltin(fields[1..]);
                } else if (std.mem.eql(u8, bname, "eval")) {
                    status = self.executeEvalBuiltin(fields[1..]);
                } else if (std.mem.eql(u8, bname, "command")) {
                    status = self.executeCommandBuiltin(fields[1..], simple.assigns, &expander);
                } else if (builtins.lookup(bname)) |builtin_fn| {
                    status = builtin_fn(fields[1..], self.env);
                } else {
                    posix.writeAll(2, "builtin: ");
                    posix.writeAll(2, bname);
                    posix.writeAll(2, ": not a shell builtin\n");
                    status = 1;
                }
            }
        } else if (std.mem.eql(u8, cmd_name, "fc")) {
            status = self.executeFcBuiltin(fields);
        } else if (self.env.functions.get(cmd_name) != null and !isSpecialBuiltin(cmd_name)) {
            const has_temp_assigns = simple.assigns.len > 0;
            if (has_temp_assigns) {
                self.env.pushScope() catch {};
                for (simple.assigns) |assign| {
                    const value = expander.expandWord(assign.value) catch "";
                    self.env.declareLocal(assign.name) catch {};
                    self.env.set(assign.name, value, false) catch {};
                }
            }
            status = self.executeFunction(cmd_name, fields);
            if (has_temp_assigns) {
                self.env.popScope();
            }
        } else if (builtins.lookup(cmd_name)) |builtin_fn| {
            const is_special = isSpecialBuiltin(cmd_name);
            const has_temp = simple.assigns.len > 0 and simple.words.len > 0 and !is_special and !is_assign_builtin;
            if (has_temp) {
                self.env.pushScope() catch {};
                for (simple.assigns) |assign| {
                    const value = expander.expandWord(assign.value) catch "";
                    self.env.declareLocal(assign.name) catch {};
                    self.env.set(assign.name, value, false) catch {};
                }
            } else if (simple.assigns.len > 0 and simple.words.len > 0) {
                for (simple.assigns) |assign| {
                    const value = expander.expandWord(assign.value) catch "";
                    self.env.set(assign.name, value, false) catch {};
                }
            }
            status = builtin_fn(fields, self.env);
            if (has_temp) {
                self.env.popScope();
            }
        } else {
            status = self.executeExternal(fields, simple.assigns, &expander);
        }

        redir_state.restore();
        if (fields.len > 0) {
            self.env.set("_", fields[fields.len - 1], false) catch {};
        }
        self.env.last_exit_status = status;
        return status;
    }

    fn executeCompound(self: *Executor, cp: ast.CompoundPair) u8 {
        var expander = Expander.init(self.alloc, self.env, self.jobs);
        var redir_state: redirect.RedirectState = .{};

        for (cp.redirects) |redir| {
            self.applyAstRedirect(redir, &redir_state, &expander) catch {
                redir_state.restore();
                return 1;
            };
        }

        const status = switch (cp.body) {
            .brace_group => |bg| self.executeCompoundList(bg.body),
            .subshell => |sub| self.executeSubshell(sub),
            .if_clause => |ic| self.executeIfClause(ic),
            .while_clause => |wc| self.executeWhileClause(wc),
            .until_clause => |uc| self.executeUntilClause(uc),
            .for_clause => |fc| self.executeForClause(fc),
            .arith_for_clause => |afc| self.executeArithForClause(afc),
            .case_clause => |cc| self.executeCaseClause(cc),
            .arith_command => |expr| self.executeArithCommand(expr),
            .double_bracket => |expr| self.executeDoubleBracket(expr),
        };

        redir_state.restore();
        return status;
    }

    fn executeFunctionDef(self: *Executor, fd: ast.FunctionDef) u8 {
        const special_builtins = [_][]const u8{
            "break",  ":",        "continue", ".",   "eval",  "exec",  "exit",
            "export", "readonly", "return",   "set", "shift", "times", "trap",
            "unset",
        };
        for (special_builtins) |sb| {
            if (std.mem.eql(u8, fd.name, sb)) {
                posix.writeAll(2, "zigsh: ");
                posix.writeAll(2, fd.name);
                posix.writeAll(2, ": is a special builtin\n");
                self.env.should_exit = true;
                self.env.exit_value = 2;
                return 2;
            }
        }
        var has_heredoc = false;
        for (fd.body.redirects) |redir| {
            if (redir.op == .heredoc or redir.op == .heredoc_strip) {
                has_heredoc = true;
                break;
            }
        }
        const source = if (has_heredoc) blk: {
            var src: std.ArrayListUnmanaged(u8) = .empty;
            src.appendSlice(self.env.alloc, fd.source) catch return 1;
            for (fd.body.redirects) |redir| {
                if (redir.op == .heredoc or redir.op == .heredoc_strip) {
                    const hd = redir.target.heredoc;
                    src.append(self.env.alloc, '\n') catch return 1;
                    src.appendSlice(self.env.alloc, hd.body_ptr.*) catch return 1;
                    src.appendSlice(self.env.alloc, hd.delimiter) catch return 1;
                    src.append(self.env.alloc, '\n') catch return 1;
                }
            }
            break :blk src.toOwnedSlice(self.env.alloc) catch return 1;
        } else self.env.alloc.dupe(u8, fd.source) catch return 1;
        const name = self.env.alloc.dupe(u8, fd.name) catch {
            self.env.alloc.free(source);
            return 1;
        };
        self.env.functions.put(name, .{ .source = source }) catch {
            self.env.alloc.free(source);
            self.env.alloc.free(name);
            return 1;
        };
        return 0;
    }

    fn executeCompoundList(self: *Executor, commands: []const ast.CompleteCommand) u8 {
        var status: u8 = 0;
        for (commands) |cmd| {
            status = self.executeCompleteCommand(cmd);
            if (self.env.should_exit or self.env.should_return or
                self.env.break_count > 0 or self.env.continue_count > 0) break;
            if (self.env.options.errexit and status != 0 and self.env.errexit_suppressed == 0 and !self.bang_reached) {
                self.env.should_exit = true;
                self.env.exit_value = status;
                break;
            }
        }
        return status;
    }

    fn executeSubshell(self: *Executor, sub: ast.Subshell) u8 {
        const pid = posix.fork() catch return 1;
        if (pid == 0) {
            signals.clearTrapsForSubshell();
            self.env.loop_depth = 0;
            self.env.in_subshell = true;
            const status = self.executeCompoundList(sub.body);
            posix.exit(status);
        }
        const result = posix.waitpid(pid, 0);
        return posix.statusFromWait(result.status);
    }

    fn executeIfClause(self: *Executor, ic: ast.IfClause) u8 {
        self.env.errexit_suppressed += 1;
        const cond_status = self.executeCompoundList(ic.condition);
        self.env.errexit_suppressed -= 1;
        if (cond_status == 0) {
            return self.executeCompoundList(ic.then_body);
        }

        for (ic.elifs) |elif| {
            self.env.errexit_suppressed += 1;
            const elif_status = self.executeCompoundList(elif.condition);
            self.env.errexit_suppressed -= 1;
            if (elif_status == 0) {
                return self.executeCompoundList(elif.body);
            }
        }

        if (ic.else_body) |else_body| {
            return self.executeCompoundList(else_body);
        }
        return 0;
    }

    const LoopAction = enum { none, break_loop, continue_loop };

    fn checkLoopControl(self: *Executor) LoopAction {
        if (self.env.break_count > 0) {
            self.env.break_count -= 1;
            return .break_loop;
        }
        if (self.env.continue_count > 0) {
            self.env.continue_count -= 1;
            if (self.env.continue_count > 0) return .break_loop;
            return .continue_loop;
        }
        if (self.env.should_return or self.env.should_exit) return .break_loop;
        return .none;
    }

    fn executeWhileClause(self: *Executor, wc: ast.WhileClause) u8 {
        var status: u8 = 0;
        self.env.loop_depth += 1;
        defer self.env.loop_depth -= 1;

        while (true) {
            self.env.errexit_suppressed += 1;
            const cond = self.executeCompoundList(wc.condition);
            self.env.errexit_suppressed -= 1;
            switch (self.checkLoopControl()) {
                .break_loop => break,
                .continue_loop => continue,
                .none => {},
            }
            if (cond != 0) break;
            status = self.executeCompoundList(wc.body);
            switch (self.checkLoopControl()) {
                .break_loop => break,
                .continue_loop => continue,
                .none => {},
            }
        }
        return status;
    }

    fn executeUntilClause(self: *Executor, uc: ast.UntilClause) u8 {
        var status: u8 = 0;
        self.env.loop_depth += 1;
        defer self.env.loop_depth -= 1;

        while (true) {
            self.env.errexit_suppressed += 1;
            const cond = self.executeCompoundList(uc.condition);
            self.env.errexit_suppressed -= 1;
            switch (self.checkLoopControl()) {
                .break_loop => break,
                .continue_loop => continue,
                .none => {},
            }
            if (cond == 0) break;
            status = self.executeCompoundList(uc.body);
            switch (self.checkLoopControl()) {
                .break_loop => break,
                .continue_loop => continue,
                .none => {},
            }
        }
        return status;
    }

    fn executeForClause(self: *Executor, fc: ast.ForClause) u8 {
        var expander = Expander.init(self.alloc, self.env, self.jobs);
        const wordlist = if (fc.wordlist) |wl|
            expander.expandWordsToFields(wl) catch return 1
        else
            self.env.positional_params;

        var status: u8 = 0;
        self.env.loop_depth += 1;
        defer self.env.loop_depth -= 1;

        for (wordlist) |word| {
            self.env.set(fc.name, word, false) catch continue;
            status = self.executeCompoundList(fc.body);
            switch (self.checkLoopControl()) {
                .break_loop => break,
                .continue_loop => continue,
                .none => {},
            }
        }
        return status;
    }

    fn stripArithQuotes(alloc: std.mem.Allocator, expr: []const u8) []const u8 {
        var result: std.ArrayListUnmanaged(u8) = .empty;
        var i: usize = 0;
        while (i < expr.len) {
            if ((expr[i] == '$' and i + 1 < expr.len and (expr[i + 1] == '\'' or expr[i + 1] == '"'))) {
                const quote = expr[i + 1];
                i += 2;
                while (i < expr.len and expr[i] != quote) {
                    result.append(alloc, expr[i]) catch return expr;
                    i += 1;
                }
                if (i < expr.len) i += 1;
            } else if (expr[i] == '\'' or expr[i] == '"') {
                const quote = expr[i];
                i += 1;
                while (i < expr.len and expr[i] != quote) {
                    result.append(alloc, expr[i]) catch return expr;
                    i += 1;
                }
                if (i < expr.len) i += 1;
            } else {
                result.append(alloc, expr[i]) catch return expr;
                i += 1;
            }
        }
        return result.toOwnedSlice(alloc) catch expr;
    }

    fn executeArithForClause(self: *Executor, afc: ast.ArithForClause) u8 {
        const env_ptr = self.env;
        const lookup = struct {
            var env: *Environment = undefined;
            fn f(name: []const u8) ?[]const u8 {
                return env.get(name);
            }
            fn setter(name: []const u8, val: i64) void {
                var buf: [32]u8 = undefined;
                const val_str = std.fmt.bufPrint(&buf, "{d}", .{val}) catch return;
                env.set(name, val_str, false) catch {};
            }
        };
        lookup.env = env_ptr;

        const init_expr = stripArithQuotes(self.alloc, afc.init);
        const cond_expr = stripArithQuotes(self.alloc, afc.cond);
        const step_expr = stripArithQuotes(self.alloc, afc.step);

        if (init_expr.len > 0) {
            _ = Arithmetic.evaluateWithSetter(init_expr, &lookup.f, &lookup.setter) catch return 1;
        }

        var status: u8 = 0;
        self.env.loop_depth += 1;
        defer self.env.loop_depth -= 1;

        while (true) {
            if (cond_expr.len > 0) {
                const cond_val = Arithmetic.evaluateWithSetter(cond_expr, &lookup.f, &lookup.setter) catch return 1;
                if (cond_val == 0) break;
            }

            status = self.executeCompoundList(afc.body);
            switch (self.checkLoopControl()) {
                .break_loop => break,
                .continue_loop => {},
                .none => {},
            }

            if (step_expr.len > 0) {
                _ = Arithmetic.evaluateWithSetter(step_expr, &lookup.f, &lookup.setter) catch return 1;
            }
        }
        return status;
    }

    fn executeArithCommand(self: *Executor, raw_expr: []const u8) u8 {
        const env_ptr = self.env;
        const lookup = struct {
            var env: *Environment = undefined;
            fn f(name: []const u8) ?[]const u8 {
                if (env.getSubscripted(name)) |v| return v;
                if (std.mem.indexOfScalar(u8, name, '[') == null) {
                    if (env.getArray(name)) |elems| {
                        if (elems.len > 0) return elems[0];
                    }
                }
                if (env.options.nounset) {
                    posix.writeAll(2, "zigsh: ");
                    posix.writeAll(2, name);
                    posix.writeAll(2, ": unbound variable\n");
                    env.should_exit = true;
                    env.exit_value = 1;
                }
                return null;
            }
            fn setter(name: []const u8, val: i64) void {
                var buf: [32]u8 = undefined;
                const val_str = std.fmt.bufPrint(&buf, "{d}", .{val}) catch return;
                if (std.mem.indexOfScalar(u8, name, '[') == null) {
                    if (env.getArray(name) != null) {
                        env.setArrayElement(name, 0, val_str) catch {};
                        return;
                    }
                }
                env.setSubscripted(name, val_str) catch {
                    env.set(name, val_str, false) catch {};
                };
            }
        };
        lookup.env = env_ptr;

        var expander = Expander.init(self.alloc, self.env, self.jobs);
        const expr = expander.expandArithmetic(raw_expr) catch {
            if (env_ptr.should_exit) {
                env_ptr.exit_value = 1;
                return 1;
            }
            return 1;
        };
        const result = Arithmetic.evaluateWithSetter(expr, &lookup.f, &lookup.setter) catch {
            if (env_ptr.should_exit) return env_ptr.exit_value;
            return 1;
        };
        if (env_ptr.should_exit) return env_ptr.exit_value;
        return if (result != 0) 0 else 1;
    }

    fn executeDoubleBracket(self: *Executor, expr: *const ast.DoubleBracketExpr) u8 {
        return if (self.evalDbExpr(expr)) 0 else 1;
    }

    fn evalDbExpr(self: *Executor, expr: *const ast.DoubleBracketExpr) bool {
        switch (expr.*) {
            .not_expr => |inner| return !self.evalDbExpr(inner),
            .and_expr => |e| return self.evalDbExpr(e.left) and self.evalDbExpr(e.right),
            .or_expr => |e| return self.evalDbExpr(e.left) or self.evalDbExpr(e.right),
            .unary_test => |t| {
                var expander = Expander.init(self.alloc, self.env, self.jobs);
                const val = expander.expandWord(t.operand) catch "";
                return self.evalDbUnary(t.op, val);
            },
            .binary_test => |t| {
                var expander = Expander.init(self.alloc, self.env, self.jobs);
                const lhs = expander.expandWord(t.lhs) catch "";
                if (std.mem.eql(u8, t.op, "==") or std.mem.eql(u8, t.op, "!=") or std.mem.eql(u8, t.op, "=")) {
                    const rhs = expander.expandPattern(t.rhs) catch "";
                    const matches = if (self.env.shopt.nocasematch) glob.fnmatchNoCase(rhs, lhs) else glob.fnmatch(rhs, lhs);
                    if (std.mem.eql(u8, t.op, "!=")) return !matches;
                    return matches;
                }
                if (std.mem.eql(u8, t.op, "=~")) {
                    const rhs = expander.expandWord(t.rhs) catch "";
                    if (self.env.shopt.nocasematch) {
                        return self.evalRegexMatchNoCase(lhs, rhs);
                    }
                    return self.evalRegexMatch(lhs, rhs);
                }
                const rhs = expander.expandWord(t.rhs) catch "";
                return self.evalDbBinary(t.op, lhs, rhs);
            },
        }
    }

    fn evalDbUnary(self: *Executor, op: []const u8, val: []const u8) bool {
        if (std.mem.eql(u8, op, "-n")) return val.len > 0;
        if (std.mem.eql(u8, op, "-z")) return val.len == 0;
        if (std.mem.eql(u8, op, "-v")) {
            if (std.mem.indexOfScalar(u8, val, '[')) |bracket| {
                if (val.len > bracket + 2 and val[val.len - 1] == ']') {
                    const base = val[0..bracket];
                    const subscript = val[bracket + 1 .. val.len - 1];
                    if (std.mem.eql(u8, subscript, "@") or std.mem.eql(u8, subscript, "*")) {
                        return self.env.getArray(base) != null;
                    }
                    const lookup = struct {
                        var e: *Environment = undefined;
                        fn f(name: []const u8) ?[]const u8 {
                            return e.get(name);
                        }
                    };
                    lookup.e = self.env;
                    const idx = Arithmetic.evaluate(subscript, &lookup.f) catch return false;
                    const elems = self.env.getArray(base) orelse return false;
                    const effective_idx: usize = if (idx < 0) blk: {
                        const neg: usize = @intCast(-idx);
                        if (neg > elems.len) break :blk elems.len;
                        break :blk elems.len - neg;
                    } else @intCast(idx);
                    return effective_idx < elems.len;
                }
            }
            if (self.env.getArray(val)) |elems| {
                return elems.len > 0;
            }
            return self.env.get(val) != null;
        }
        if (std.mem.eql(u8, op, "-o")) {
            if (std.mem.eql(u8, val, "errexit")) return self.env.options.errexit;
            if (std.mem.eql(u8, val, "nounset")) return self.env.options.nounset;
            if (std.mem.eql(u8, val, "xtrace")) return self.env.options.xtrace;
            if (std.mem.eql(u8, val, "verbose")) return self.env.options.verbose;
            if (std.mem.eql(u8, val, "noclobber")) return self.env.options.noclobber;
            if (std.mem.eql(u8, val, "noexec")) return self.env.options.noexec;
            if (std.mem.eql(u8, val, "noglob")) return self.env.options.noglob;
            if (std.mem.eql(u8, val, "allexport")) return self.env.options.allexport;
            return false;
        }
        if (std.mem.eql(u8, op, "-t")) {
            const fd_num = std.fmt.parseInt(posix.fd_t, val, 10) catch return false;
            return posix.isatty(fd_num);
        }
        const path_z = std.posix.toPosixPath(val) catch return false;
        if (std.mem.eql(u8, op, "-a") or std.mem.eql(u8, op, "-e")) {
            _ = posix.stat(&path_z) catch return false;
            return true;
        }
        if (std.mem.eql(u8, op, "-f")) {
            const st = posix.stat(&path_z) catch return false;
            return st.mode & posix.S_IFMT == posix.S_IFREG;
        }
        if (std.mem.eql(u8, op, "-d")) {
            const st = posix.stat(&path_z) catch return false;
            return st.mode & posix.S_IFMT == posix.S_IFDIR;
        }
        if (std.mem.eql(u8, op, "-b")) {
            const st = posix.stat(&path_z) catch return false;
            return st.mode & posix.S_IFMT == posix.S_IFBLK;
        }
        if (std.mem.eql(u8, op, "-c")) {
            const st = posix.stat(&path_z) catch return false;
            return st.mode & posix.S_IFMT == posix.S_IFCHR;
        }
        if (std.mem.eql(u8, op, "-p")) {
            const st = posix.stat(&path_z) catch return false;
            return st.mode & posix.S_IFMT == posix.S_IFIFO;
        }
        if (std.mem.eql(u8, op, "-h") or std.mem.eql(u8, op, "-L")) {
            const st = posix.lstat(&path_z) catch return false;
            return st.mode & posix.S_IFMT == posix.S_IFLNK;
        }
        if (std.mem.eql(u8, op, "-S")) {
            const st = posix.stat(&path_z) catch return false;
            return st.mode & posix.S_IFMT == posix.S_IFSOCK;
        }
        if (std.mem.eql(u8, op, "-g")) {
            const st = posix.stat(&path_z) catch return false;
            return st.mode & posix.S_ISGID != 0;
        }
        if (std.mem.eql(u8, op, "-u")) {
            const st = posix.stat(&path_z) catch return false;
            return st.mode & posix.S_ISUID != 0;
        }
        if (std.mem.eql(u8, op, "-k")) {
            const st = posix.stat(&path_z) catch return false;
            return st.mode & posix.S_ISVTX != 0;
        }
        if (std.mem.eql(u8, op, "-r")) return posix.access(&path_z, posix.R_OK);
        if (std.mem.eql(u8, op, "-w")) return posix.access(&path_z, posix.W_OK);
        if (std.mem.eql(u8, op, "-x")) return posix.access(&path_z, posix.X_OK);
        if (std.mem.eql(u8, op, "-s")) {
            const st = posix.stat(&path_z) catch return false;
            return st.size > 0;
        }
        if (std.mem.eql(u8, op, "-G")) {
            const st = posix.stat(&path_z) catch return false;
            return st.gid == posix.getegid();
        }
        if (std.mem.eql(u8, op, "-O")) {
            const st = posix.stat(&path_z) catch return false;
            return st.uid == posix.geteuid();
        }
        return false;
    }

    fn evalDbBinary(self: *Executor, op: []const u8, lhs: []const u8, rhs: []const u8) bool {
        if (std.mem.eql(u8, op, "<")) return std.mem.order(u8, lhs, rhs) == .lt;
        if (std.mem.eql(u8, op, ">")) return std.mem.order(u8, lhs, rhs) == .gt;
        const env_ptr = self.env;
        const arith_lookup = struct {
            var env: *Environment = undefined;
            fn f(name: []const u8) ?[]const u8 {
                return env.get(name);
            }
        };
        arith_lookup.env = env_ptr;
        const l = Arithmetic.evaluate(lhs, &arith_lookup.f) catch parseShellInt(lhs);
        const r = Arithmetic.evaluate(rhs, &arith_lookup.f) catch parseShellInt(rhs);
        if (std.mem.eql(u8, op, "-eq")) return l == r;
        if (std.mem.eql(u8, op, "-ne")) return l != r;
        if (std.mem.eql(u8, op, "-lt")) return l < r;
        if (std.mem.eql(u8, op, "-gt")) return l > r;
        if (std.mem.eql(u8, op, "-le")) return l <= r;
        if (std.mem.eql(u8, op, "-ge")) return l >= r;
        if (std.mem.eql(u8, op, "-nt") or std.mem.eql(u8, op, "-ot") or std.mem.eql(u8, op, "-ef")) {
            const lpath = std.posix.toPosixPath(lhs) catch return false;
            const rpath = std.posix.toPosixPath(rhs) catch return false;
            const lst = posix.stat(&lpath) catch return false;
            const rst = posix.stat(&rpath) catch return false;
            if (std.mem.eql(u8, op, "-nt")) {
                if (lst.mtime_sec != rst.mtime_sec) return lst.mtime_sec > rst.mtime_sec;
                return lst.mtime_nsec > rst.mtime_nsec;
            }
            if (std.mem.eql(u8, op, "-ot")) {
                if (lst.mtime_sec != rst.mtime_sec) return lst.mtime_sec < rst.mtime_sec;
                return lst.mtime_nsec < rst.mtime_nsec;
            }
            return lst.dev_major == rst.dev_major and lst.dev_minor == rst.dev_minor and lst.ino == rst.ino;
        }
        return false;
    }

    fn parseShellInt(s: []const u8) i64 {
        if (s.len == 0) return 0;
        var str = s;
        var negative = false;
        if (str[0] == '-') {
            negative = true;
            str = str[1..];
        } else if (str[0] == '+') {
            str = str[1..];
        }
        if (str.len == 0) return 0;
        if (std.mem.indexOfScalar(u8, str, '#')) |hash_idx| {
            if (hash_idx > 0) {
                const base_val = std.fmt.parseInt(u8, str[0..hash_idx], 10) catch return 0;
                if (base_val >= 2 and base_val <= 64) {
                    const digits = str[hash_idx + 1 ..];
                    var result: i64 = 0;
                    for (digits) |ch| {
                        const d: i64 = if (ch >= '0' and ch <= '9') ch - '0' else if (ch >= 'a' and ch <= 'z') ch - 'a' + 10 else if (ch >= 'A' and ch <= 'Z') ch - 'A' + 36 else if (ch == '@') 62 else if (ch == '_') 63 else return 0;
                        if (d >= base_val) return 0;
                        result = result * base_val + d;
                    }
                    return if (negative) -result else result;
                }
            }
        }
        var base: u8 = 10;
        if (str.len > 1 and str[0] == '0') {
            if (str[1] == 'x' or str[1] == 'X') {
                base = 16;
                str = str[2..];
            } else {
                base = 8;
            }
        }
        if (str.len == 0) return 0;
        const val = std.fmt.parseInt(i64, str, base) catch return 0;
        return if (negative) -val else val;
    }

    fn evalRegexMatch(_: *Executor, str: []const u8, pattern: []const u8) bool {
        return regexMatch(str, pattern);
    }

    fn evalRegexMatchNoCase(self: *Executor, str: []const u8, pattern: []const u8) bool {
        const lower_str = self.alloc.alloc(u8, str.len) catch return false;
        const lower_pat = self.alloc.alloc(u8, pattern.len) catch return false;
        for (str, 0..) |ch, i| lower_str[i] = std.ascii.toLower(ch);
        for (pattern, 0..) |ch, i| lower_pat[i] = std.ascii.toLower(ch);
        return regexMatch(lower_str, lower_pat);
    }

    fn regexMatch(str: []const u8, pattern: []const u8) bool {
        if (std.mem.eql(u8, str, pattern)) return true;
        if (pattern.len == 0) return str.len == 0;
        const anchored_start = pattern.len > 0 and pattern[0] == '^';
        const pat = if (anchored_start) pattern[1..] else pattern;
        if (anchored_start) {
            return regexMatchAt(str, 0, pat);
        }
        var start: usize = 0;
        while (start <= str.len) : (start += 1) {
            if (regexMatchAt(str, start, pat)) return true;
        }
        return false;
    }

    fn regexMatchAt(str: []const u8, start: usize, pattern: []const u8) bool {
        var si: usize = start;
        var pi: usize = 0;
        while (pi < pattern.len) {
            if (pattern[pi] == '$' and pi + 1 == pattern.len) {
                return si == str.len;
            }
            if (pi + 1 < pattern.len and pattern[pi + 1] == '*') {
                const ch = pattern[pi];
                pi += 2;
                while (true) {
                    if (regexMatchAt(str, si, pattern[pi..])) return true;
                    if (si >= str.len) break;
                    if (ch != '.' and str[si] != ch) break;
                    si += 1;
                }
                return false;
            }
            if (pi + 1 < pattern.len and pattern[pi + 1] == '+') {
                const ch = pattern[pi];
                pi += 2;
                if (si >= str.len) return false;
                if (ch != '.' and str[si] != ch) return false;
                si += 1;
                while (true) {
                    if (regexMatchAt(str, si, pattern[pi..])) return true;
                    if (si >= str.len) break;
                    if (ch != '.' and str[si] != ch) break;
                    si += 1;
                }
                return false;
            }
            if (si >= str.len) return false;
            if (pattern[pi] == '\\' and pi + 1 < pattern.len) {
                pi += 1;
                if (str[si] != pattern[pi]) return false;
                si += 1;
                pi += 1;
            } else if (pattern[pi] == '.') {
                si += 1;
                pi += 1;
            } else if (pattern[pi] == '[') {
                pi += 1;
                const negate = pi < pattern.len and pattern[pi] == '^';
                if (negate) pi += 1;
                var found = false;
                while (pi < pattern.len and pattern[pi] != ']') {
                    if (pi + 2 < pattern.len and pattern[pi + 1] == '-') {
                        if (str[si] >= pattern[pi] and str[si] <= pattern[pi + 2]) found = true;
                        pi += 3;
                    } else {
                        if (str[si] == pattern[pi]) found = true;
                        pi += 1;
                    }
                }
                if (pi < pattern.len) pi += 1;
                if (found == negate) return false;
                si += 1;
            } else {
                if (str[si] != pattern[pi]) return false;
                si += 1;
                pi += 1;
            }
        }
        return true;
    }

    fn executeCaseClause(self: *Executor, cc: ast.CaseClause) u8 {
        var expander = Expander.init(self.alloc, self.env, self.jobs);
        const word_val = expander.expandWord(cc.word) catch return 1;

        var status: u8 = 0;
        var falling_through = false;
        for (cc.items, 0..) |item, idx| {
            var matched = falling_through;
            if (!matched) {
                for (item.patterns) |pattern| {
                    const pat_val = expander.expandPattern(pattern) catch continue;
                    const case_match = if (self.env.shopt.nocasematch) glob.fnmatchNoCase(pat_val, word_val) else glob.fnmatch(pat_val, word_val);
                    if (case_match) {
                        matched = true;
                        break;
                    }
                }
            }
            if (matched) {
                if (item.body) |body| {
                    status = self.executeCompoundList(body);
                } else {
                    status = 0;
                }
                switch (item.terminator) {
                    .dsemi => return status,
                    .fall_through => {
                        falling_through = true;
                        if (idx + 1 >= cc.items.len) return status;
                    },
                    .continue_testing => {
                        falling_through = false;
                    },
                }
            }
        }
        return status;
    }

    fn executeFunction(self: *Executor, name: []const u8, fields: []const []const u8) u8 {
        const func = self.env.functions.get(name) orelse return 127;

        self.env.pushScope() catch return 1;
        defer self.env.popScope();

        self.env.function_name_stack.append(self.alloc, name) catch {};
        defer _ = self.env.function_name_stack.pop();

        self.env.pushPositionalParams(fields[1..]) catch return 1;
        defer self.env.popPositionalParams();

        var lexer = Lexer.init(func.source);
        var parser = Parser.init(self.alloc, &lexer) catch return 2;
        parser.env = self.env;

        var status: u8 = 0;
        while (true) {
            const cmd = parser.parseOneCommand() catch return 2;
            if (cmd == null) break;
            status = self.executeCompleteCommand(cmd.?);
            self.env.last_exit_status = status;
            if (self.env.should_return) {
                status = self.env.return_value;
                self.env.should_return = false;
                break;
            }
            if (self.env.should_exit) break;
        }
        return status;
    }

    fn executeExternal(self: *Executor, fields: []const []const u8, assigns: []const ast.Assignment, expander: *Expander) u8 {
        const cmd_name = fields[0];
        const path = self.findExecutable(cmd_name) orelse {
            posix.writeAll(2, "zigsh: ");
            posix.writeAll(2, cmd_name);
            posix.writeAll(2, ": command not found\n");
            return 127;
        };

        const pid = posix.fork() catch {
            posix.writeAll(2, "zigsh: fork failed\n");
            return 1;
        };

        if (pid == 0) {
            for (assigns) |assign| {
                const value = expander.expandWord(assign.value) catch "";
                self.env.set(assign.name, value, true) catch {};
            }

            const envp = self.env.buildEnvp() catch posix.exit(1);
            const argv = self.buildArgv(fields) catch posix.exit(1);

            posix.execve(path, argv, envp) catch |err| {
                if (err == error.NoExec) {
                    const sh_argv = self.buildShArgv(path, fields) catch posix.exit(126);
                    posix.execve("/bin/sh", sh_argv, envp) catch {};
                }
            };
            const exit_code: u8 = if (posix.stat(path)) |_| 126 else |_| 127;
            posix.exit(exit_code);
        }

        const result = posix.waitpid(pid, 0);
        return posix.statusFromWait(result.status);
    }

    fn findExecutable(self: *Executor, name: []const u8) ?[*:0]const u8 {
        if (std.mem.indexOfScalar(u8, name, '/') != null) {
            const duped = self.alloc.dupeZ(u8, name) catch return null;
            return duped.ptr;
        }

        if (self.env.getCachedCommand(name)) |cached| {
            const duped = self.alloc.dupeZ(u8, cached) catch return null;
            return duped.ptr;
        }

        const path_env = self.env.get("PATH") orelse "/usr/bin:/bin";
        var iter = std.mem.splitScalar(u8, path_env, ':');
        while (iter.next()) |dir| {
            const full_path = std.fmt.allocPrintSentinel(self.alloc, "{s}/{s}", .{ dir, name }, 0) catch continue;
            const st = posix.stat(full_path.ptr) catch continue;
            if (st.mode & posix.S_IFMT == posix.S_IFREG and posix.access(full_path.ptr, posix.X_OK)) {
                self.env.cacheCommand(name, std.mem.sliceTo(full_path, 0)) catch {};
                return full_path.ptr;
            }
        }
        return null;
    }

    fn buildArgv(self: *Executor, fields: []const []const u8) ![:null]const ?[*:0]const u8 {
        var argv: std.ArrayListUnmanaged(?[*:0]const u8) = .empty;
        for (fields) |field| {
            const arg_z = try self.alloc.dupeZ(u8, field);
            try argv.append(self.alloc, arg_z.ptr);
        }
        return argv.toOwnedSliceSentinel(self.alloc, null);
    }

    fn buildShArgv(self: *Executor, path: [*:0]const u8, fields: []const []const u8) ![:null]const ?[*:0]const u8 {
        var argv: std.ArrayListUnmanaged(?[*:0]const u8) = .empty;
        try argv.append(self.alloc, "/bin/sh");
        try argv.append(self.alloc, path);
        if (fields.len > 1) {
            for (fields[1..]) |field| {
                const arg_z = try self.alloc.dupeZ(u8, field);
                try argv.append(self.alloc, arg_z.ptr);
            }
        }
        return argv.toOwnedSliceSentinel(self.alloc, null);
    }

    fn applyAstRedirect(self: *Executor, redir: ast.Redirect, state: *redirect.RedirectState, expander: *Expander) !void {
        if (redir.op == .and_great or redir.op == .and_dgreat) {
            switch (redir.target) {
                .word => |word| {
                    const expanded = expander.expandWord(word) catch return error.RedirectionFailed;
                    const path_z = self.alloc.dupeZ(u8, expanded) catch return error.RedirectionFailed;
                    const file_op: redirect.RedirectOp = if (redir.op == .and_great) .output else .append;
                    try redirect.applyFileRedirect(types.STDOUT, path_z.ptr, file_op, state, self.env.options.noclobber);
                    try redirect.applyDupRedirect(types.STDERR, types.STDOUT, state);
                },
                else => {},
            }
            return;
        }

        const fd: types.Fd = redir.fd orelse redirect.defaultFdForOp(astToRedirectOp(redir.op));
        const op = astToRedirectOp(redir.op);

        if (redir.op == .here_string) {
            switch (redir.target) {
                .word => |word| {
                    const expanded = expander.expandWord(word) catch return error.RedirectionFailed;
                    const pipe_fds = posix.pipe() catch return error.RedirectionFailed;
                    _ = posix.write(pipe_fds[1], expanded) catch {};
                    _ = posix.write(pipe_fds[1], "\n") catch {};
                    posix.close(pipe_fds[1]);
                    try state.save(fd);
                    posix.dup2(pipe_fds[0], fd) catch return error.RedirectionFailed;
                    if (pipe_fds[0] != fd) posix.close(pipe_fds[0]);
                },
                else => {},
            }
            return;
        }

        switch (redir.target) {
            .word => |word| {
                const expanded = expander.expandWord(word) catch return error.RedirectionFailed;
                if (op == .dup_input or op == .dup_output) {
                    if (std.mem.eql(u8, expanded, "-")) {
                        try redirect.applyCloseRedirect(fd, state);
                    } else if (parseFdMove(expanded)) |target_fd| {
                        try redirect.applyDupRedirect(fd, target_fd, state);
                        if (target_fd != fd) posix.close(target_fd);
                    } else if (std.fmt.parseInt(i32, expanded, 10)) |target_fd| {
                        try redirect.applyDupRedirect(fd, target_fd, state);
                    } else |_| {
                        if (redir.op == .dup_output and redir.fd == null) {
                            const path_z = self.alloc.dupeZ(u8, expanded) catch return error.RedirectionFailed;
                            try redirect.applyFileRedirect(types.STDOUT, path_z.ptr, .output, state, self.env.options.noclobber);
                            try redirect.applyDupRedirect(types.STDERR, types.STDOUT, state);
                        } else {
                            return error.RedirectionFailed;
                        }
                    }
                } else if (redir.op == .dup_output and redir.fd == null) {
                    const path_z = self.alloc.dupeZ(u8, expanded) catch return error.RedirectionFailed;
                    try redirect.applyFileRedirect(types.STDOUT, path_z.ptr, .output, state, self.env.options.noclobber);
                    try redirect.applyDupRedirect(types.STDERR, types.STDOUT, state);
                } else {
                    const path_z = self.alloc.dupeZ(u8, expanded) catch return error.RedirectionFailed;
                    try redirect.applyFileRedirect(fd, path_z.ptr, op, state, self.env.options.noclobber);
                }
            },
            .fd => |target_fd| try redirect.applyDupRedirect(fd, target_fd, state),
            .fd_move => |target_fd| {
                try redirect.applyDupRedirect(fd, target_fd, state);
                if (target_fd != fd) posix.close(target_fd);
            },
            .close => try redirect.applyCloseRedirect(fd, state),
            .heredoc => |hd| {
                const pipe_fds = posix.pipe() catch return error.RedirectionFailed;
                var body = if (!hd.quoted)
                    expander.expandHeredocBody(hd.body_ptr.*) catch hd.body_ptr.*
                else
                    hd.body_ptr.*;
                if (redir.op == .heredoc_strip) {
                    body = self.stripHeredocTabs(body) catch body;
                }
                _ = posix.write(pipe_fds[1], body) catch {};
                posix.close(pipe_fds[1]);
                try state.save(fd);
                posix.dup2(pipe_fds[0], fd) catch return error.RedirectionFailed;
                if (pipe_fds[0] != fd) posix.close(pipe_fds[0]);
            },
        }
    }

    fn stripHeredocTabs(self: *Executor, body: []const u8) ![]const u8 {
        var result: std.ArrayListUnmanaged(u8) = .empty;
        var pos: usize = 0;
        while (pos < body.len) {
            while (pos < body.len and body[pos] == '\t') pos += 1;
            const line_end = std.mem.indexOfScalarPos(u8, body, pos, '\n') orelse body.len;
            try result.appendSlice(self.alloc, body[pos..line_end]);
            if (line_end < body.len) {
                try result.append(self.alloc, '\n');
                pos = line_end + 1;
            } else {
                pos = line_end;
            }
        }
        return result.items;
    }

    fn executeSourceBuiltin(self: *Executor, fields: []const []const u8) u8 {
        var arg_start: usize = 1;
        if (arg_start < fields.len and std.mem.eql(u8, fields[arg_start], "--")) {
            arg_start += 1;
        }
        if (arg_start >= fields.len) {
            posix.writeAll(2, ".: usage: . filename [arguments]\n");
            return 2;
        }

        const filename = fields[arg_start];
        const path = self.resolveSourcePath(filename);
        const fd = posix.open(path, posix.oRdonly(), 0) catch {
            posix.writeAll(2, ".: ");
            posix.writeAll(2, filename);
            posix.writeAll(2, ": No such file or directory\n");
            return 1;
        };

        const path_z = std.posix.toPosixPath(path) catch {
            posix.close(fd);
            return 1;
        };
        const st = posix.stat(&path_z) catch {
            posix.close(fd);
            return 1;
        };
        if (st.mode & posix.S_IFMT == posix.S_IFDIR) {
            posix.close(fd);
            posix.writeAll(2, ".: ");
            posix.writeAll(2, filename);
            posix.writeAll(2, ": Is a directory\n");
            return 1;
        }

        defer posix.close(fd);

        var content: std.ArrayListUnmanaged(u8) = .empty;
        defer content.deinit(self.alloc);
        posix.readToEnd(fd, self.alloc, &content) catch return 1;

        var status: u8 = undefined;
        if (arg_start + 1 < fields.len) {
            self.env.pushPositionalParams(fields[arg_start + 1 ..]) catch return 1;
            defer self.env.popPositionalParams();
            status = self.executeInlineSpecial(content.items);
        } else {
            status = self.executeInlineSpecial(content.items);
        }
        if (self.env.should_return) {
            status = self.env.return_value;
            self.env.should_return = false;
        }
        return status;
    }

    fn resolveSourcePath(self: *Executor, filename: []const u8) []const u8 {
        if (std.mem.indexOfScalar(u8, filename, '/') != null) {
            return filename;
        }

        const path_env = self.env.get("PATH") orelse "";
        var path_iter = std.mem.splitScalar(u8, path_env, ':');
        while (path_iter.next()) |dir| {
            const full = std.fmt.allocPrint(self.alloc, "{s}/{s}", .{ dir, filename }) catch continue;
            const full_z = std.posix.toPosixPath(full) catch continue;
            const st = posix.stat(&full_z) catch continue;
            if (st.mode & posix.S_IFMT == posix.S_IFDIR) continue;
            if (posix.access(&full_z, posix.R_OK)) return full;
        }
        return filename;
    }

    fn executeEvalBuiltin(self: *Executor, fields: []const []const u8) u8 {
        var arg_start: usize = 1;
        if (arg_start < fields.len and std.mem.eql(u8, fields[arg_start], "--")) {
            arg_start += 1;
        } else if (arg_start < fields.len and fields[arg_start].len > 1 and fields[arg_start][0] == '-' and fields[arg_start][1] != '-') {
            const opt = fields[arg_start];
            if (opt.len == 1 or !std.ascii.isDigit(opt[1])) {
                posix.writeAll(2, "zigsh: eval: ");
                posix.writeAll(2, opt);
                posix.writeAll(2, ": invalid option\n");
                return 2;
            }
        }
        if (arg_start >= fields.len) return 0;

        var eval_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer eval_buf.deinit(self.alloc);
        for (fields[arg_start..], 0..) |f, i| {
            if (i > 0) eval_buf.append(self.alloc, ' ') catch return 1;
            eval_buf.appendSlice(self.alloc, f) catch return 1;
        }

        return self.executeInlineSpecial(eval_buf.items);
    }

    fn executeExecBuiltin(self: *Executor, fields: []const []const u8, assigns: []const ast.Assignment, expander: *Expander) u8 {
        if (fields.len < 2) return 0;

        for (assigns) |assign| {
            const value = expander.expandWord(assign.value) catch "";
            self.env.set(assign.name, value, true) catch {};
        }

        var cmd_start: usize = 1;
        var argv0_override: ?[]const u8 = null;
        while (cmd_start < fields.len) {
            if (std.mem.eql(u8, fields[cmd_start], "--")) {
                cmd_start += 1;
                break;
            } else if (std.mem.eql(u8, fields[cmd_start], "-a") and cmd_start + 1 < fields.len) {
                argv0_override = fields[cmd_start + 1];
                cmd_start += 2;
            } else break;
        }
        if (cmd_start >= fields.len) {
            return 0;
        }

        const path = self.findExecutable(fields[cmd_start]) orelse {
            posix.writeAll(2, "exec: ");
            posix.writeAll(2, fields[cmd_start]);
            posix.writeAll(2, ": not found\n");
            return 127;
        };

        const envp = self.env.buildEnvp() catch return 1;
        if (argv0_override) |a0| {
            var argv_list: std.ArrayListUnmanaged(?[*:0]const u8) = .empty;
            const a0z = self.alloc.dupeZ(u8, a0) catch return 1;
            argv_list.append(self.alloc, a0z) catch return 1;
            for (fields[cmd_start + 1 ..]) |f| {
                const fz = self.alloc.dupeZ(u8, f) catch return 1;
                argv_list.append(self.alloc, fz) catch return 1;
            }
            argv_list.append(self.alloc, null) catch return 1;
            const argv_items = argv_list.items;
            const argv: [*:null]const ?[*:0]const u8 = @ptrCast(argv_items.ptr);
            posix.execve(path, argv, envp) catch {};
        } else {
            const argv = self.buildArgv(fields[cmd_start..]) catch return 1;
            posix.execve(path, argv, envp) catch {};
        }
        posix.writeAll(2, "exec: failed\n");
        return 126;
    }

    fn executeCommandBuiltin(self: *Executor, fields: []const []const u8, assigns: []const ast.Assignment, expander: *Expander) u8 {
        if (fields.len < 2) return 0;

        const default_path = "/usr/bin:/bin:/usr/sbin:/sbin";
        var start: usize = 1;
        var mode: enum { execute, short, verbose } = .execute;
        var use_default_path = false;
        while (start < fields.len) {
            if (std.mem.eql(u8, fields[start], "-v")) {
                mode = .short;
                start += 1;
            } else if (std.mem.eql(u8, fields[start], "-V")) {
                mode = .verbose;
                start += 1;
            } else if (std.mem.eql(u8, fields[start], "-p")) {
                use_default_path = true;
                start += 1;
            } else {
                break;
            }
        }
        if (start >= fields.len) return 0;

        if (mode == .short) {
            var status: u8 = 0;
            for (fields[start..]) |name| {
                if (self.env.getAlias(name)) |alias_val| {
                    posix.writeAll(1, "alias ");
                    posix.writeAll(1, name);
                    posix.writeAll(1, "='");
                    posix.writeAll(1, alias_val);
                    posix.writeAll(1, "'\n");
                } else if (token.reserved_words.get(name) != null) {
                    posix.writeAll(1, name);
                    posix.writeAll(1, "\n");
                } else if (self.env.functions.get(name) != null) {
                    posix.writeAll(1, name);
                    posix.writeAll(1, "\n");
                } else if (builtins.lookup(name) != null or isSpecialBuiltin(name)) {
                    posix.writeAll(1, name);
                    posix.writeAll(1, "\n");
                } else if (self.findExecutable(name)) |path| {
                    const p = std.mem.sliceTo(path, 0);
                    const st = posix.stat(path) catch {
                        status = 1;
                        continue;
                    };
                    if (st.mode & posix.S_IFMT == posix.S_IFREG and posix.access(path, posix.X_OK)) {
                        posix.writeAll(1, p);
                        posix.writeAll(1, "\n");
                    } else {
                        status = 1;
                    }
                } else {
                    status = 1;
                }
            }
            return status;
        }

        if (mode == .verbose) {
            var status: u8 = 0;
            for (fields[start..]) |name| {
                if (self.env.getAlias(name)) |alias_val| {
                    posix.writeAll(1, name);
                    posix.writeAll(1, " is an alias for \"");
                    posix.writeAll(1, alias_val);
                    posix.writeAll(1, "\"\n");
                } else if (token.reserved_words.get(name) != null) {
                    posix.writeAll(1, name);
                    posix.writeAll(1, " is a shell keyword\n");
                } else if (self.env.functions.get(name) != null) {
                    posix.writeAll(1, name);
                    posix.writeAll(1, " is a function\n");
                } else if (builtins.lookup(name) != null or isSpecialBuiltin(name)) {
                    posix.writeAll(1, name);
                    posix.writeAll(1, " is a shell builtin\n");
                } else if (self.findExecutable(name)) |path| {
                    posix.writeAll(1, name);
                    posix.writeAll(1, " is ");
                    posix.writeAll(1, std.mem.sliceTo(path, 0));
                    posix.writeAll(1, "\n");
                } else {
                    posix.writeAll(2, name);
                    posix.writeAll(2, ": not found\n");
                    status = 1;
                }
            }
            return status;
        }

        const saved_path = if (use_default_path) self.env.get("PATH") else null;
        if (use_default_path) self.env.set("PATH", default_path, true) catch {};
        defer if (use_default_path) {
            if (saved_path) |p| {
                self.env.set("PATH", p, true) catch {};
            } else {
                _ = self.env.unset("PATH");
            }
        };

        const cmd_name = fields[start];
        if (std.mem.eql(u8, cmd_name, "builtin")) {
            if (start + 1 >= fields.len) return 0;
            const bname = fields[start + 1];
            if (std.mem.eql(u8, bname, ".") or std.mem.eql(u8, bname, "source")) {
                return self.executeSourceBuiltin(fields[start + 1 ..]);
            } else if (std.mem.eql(u8, bname, "eval")) {
                return self.executeEvalBuiltin(fields[start + 1 ..]);
            } else if (std.mem.eql(u8, bname, "command")) {
                return self.executeCommandBuiltin(fields[start + 1 ..], assigns, expander);
            } else if (builtins.lookup(bname)) |builtin_fn| {
                return builtin_fn(fields[start + 1 ..], self.env);
            } else {
                posix.writeAll(2, "builtin: ");
                posix.writeAll(2, bname);
                posix.writeAll(2, ": not a shell builtin\n");
                return 1;
            }
        } else if (std.mem.eql(u8, cmd_name, "command")) {
            return self.executeCommandBuiltin(fields[start..], assigns, expander);
        } else if (std.mem.eql(u8, cmd_name, ".") or std.mem.eql(u8, cmd_name, "source")) {
            return self.executeSourceBuiltin(fields[start..]);
        } else if (std.mem.eql(u8, cmd_name, "eval")) {
            return self.executeEvalBuiltin(fields[start..]);
        } else if (builtins.lookup(cmd_name)) |builtin_fn| {
            return builtin_fn(fields[start..], self.env);
        }
        return self.executeExternal(fields[start..], assigns, expander);
    }

    fn executeFcBuiltin(self: *Executor, fields: []const []const u8) u8 {
        var has_s = false;
        var has_e = false;
        var editor: ?[]const u8 = null;
        var arg_start: usize = 1;
        while (arg_start < fields.len) {
            const arg = fields[arg_start];
            if (arg.len == 0 or arg[0] != '-') break;
            if (std.mem.eql(u8, arg, "--")) {
                arg_start += 1;
                break;
            }
            if (std.mem.eql(u8, arg, "-e")) {
                has_e = true;
                arg_start += 1;
                if (arg_start < fields.len) {
                    editor = fields[arg_start];
                    arg_start += 1;
                }
                continue;
            }
            for (arg[1..]) |fc| {
                if (fc == 's') has_s = true;
                if (fc == 'e') has_e = true;
            }
            arg_start += 1;
        }

        if (!has_s and !has_e) {
            return builtins.builtins.get("fc").?(fields, self.env);
        }

        const history = self.env.history orelse {
            posix.writeAll(2, "fc: no history available\n");
            return 1;
        };
        if (history.count == 0) {
            posix.writeAll(2, "fc: no history\n");
            return 1;
        }

        if (has_s) {
            const cmd = builtins.fcGetReexecCommand(fields[arg_start..], history) orelse return 1;
            posix.writeAll(1, cmd);
            posix.writeAll(1, "\n");
            return self.executeInline(cmd);
        }

        const ed = editor orelse self.env.get("FCEDIT") orelse self.env.get("EDITOR") orelse "ed";

        var first: usize = history.count;
        var last: usize = history.count;
        if (arg_start < fields.len) {
            first = builtins.fcResolveNum(fields[arg_start], history.count);
            if (arg_start + 1 < fields.len) {
                last = builtins.fcResolveNum(fields[arg_start + 1], history.count);
            } else {
                last = first;
            }
        }
        if (first < 1) first = 1;
        if (last > history.count) last = history.count;
        if (first > last) {
            const tmp = first;
            first = last;
            last = tmp;
        }

        const tmp_path = "/tmp/.zigsh_fc_edit";
        const tmp_fd = posix.open(tmp_path, posix.oWronlyCreatTrunc(), 0o600) catch {
            posix.writeAll(2, "fc: cannot create temp file\n");
            return 1;
        };
        var ii: usize = first;
        while (ii <= last) : (ii += 1) {
            if (history.entries[ii - 1]) |entry| {
                _ = posix.write(tmp_fd, entry) catch {};
                _ = posix.write(tmp_fd, "\n") catch {};
            }
        }
        posix.close(tmp_fd);

        var ed_cmd_buf: [4096]u8 = undefined;
        const ed_cmd = std.fmt.bufPrint(&ed_cmd_buf, "{s} {s}", .{ ed, tmp_path }) catch {
            posix.writeAll(2, "fc: editor command too long\n");
            return 1;
        };

        _ = self.executeInline(ed_cmd);

        const read_fd = posix.open(tmp_path, posix.oRdonly(), 0) catch {
            posix.writeAll(2, "fc: cannot read temp file\n");
            return 1;
        };
        var content: std.ArrayListUnmanaged(u8) = .empty;
        defer content.deinit(self.alloc);
        posix.readToEnd(read_fd, self.alloc, &content) catch {
            posix.close(read_fd);
            return 1;
        };
        posix.close(read_fd);

        const unlink_path = std.posix.toPosixPath(tmp_path) catch return 1;
        _ = std.c.unlink(&unlink_path);

        if (content.items.len == 0) return 0;
        return self.executeInline(content.items);
    }

    fn executeInline(self: *Executor, source: []const u8) u8 {
        return self.executeInlineInterleaved(source);
    }

    fn executeInlineSpecial(self: *Executor, source: []const u8) u8 {
        return self.executeInlineInterleaved(source);
    }

    fn executeInlineInterleaved(self: *Executor, source: []const u8) u8 {
        var lexer = Lexer.init(source);
        var parser = Parser.init(self.alloc, &lexer) catch return 2;
        parser.env = self.env;
        var status: u8 = 0;
        while (true) {
            const cmd = parser.parseOneCommand() catch return 2;
            if (cmd == null) break;
            status = self.executeCompleteCommand(cmd.?);
            self.env.last_exit_status = status;
            if (self.env.should_exit or self.env.should_return) break;
        }
        return status;
    }

    fn expandTildesInAssignValue(self: *Executor, expanded: []const u8, val_start: usize) ![]const u8 {
        const val = expanded[val_start..];
        var need_expand = false;
        if (val.len > 0 and val[0] == '~') need_expand = true;
        if (!need_expand) {
            if (std.mem.indexOf(u8, val, ":~") != null) need_expand = true;
        }
        if (!need_expand) return expanded;

        var result: std.ArrayListUnmanaged(u8) = .empty;
        try result.appendSlice(self.alloc, expanded[0..val_start]);

        var i: usize = 0;
        while (i < val.len) {
            const at_tilde = (i == 0 or val[i - 1] == ':') and val[i] == '~';
            if (at_tilde) {
                var end = i + 1;
                while (end < val.len and val[end] != '/' and val[end] != ':') : (end += 1) {}
                const tilde_text = val[i..end];
                if (tilde_text.len == 1) {
                    if (self.env.get("HOME")) |home| {
                        try result.appendSlice(self.alloc, home);
                    } else {
                        try result.append(self.alloc, '~');
                    }
                } else {
                    try result.appendSlice(self.alloc, tilde_text);
                }
                i = end;
            } else {
                try result.append(self.alloc, val[i]);
                i += 1;
            }
        }
        return result.toOwnedSlice(self.alloc);
    }

    fn expandAssignBuiltinArgs(self: *Executor, expander: *Expander, words: []const ast.Word) ExpandError![]const []const u8 {
        var fields: std.ArrayListUnmanaged([]const u8) = .empty;
        for (words, 0..) |word, wi| {
            if (wi == 0) {
                const cmd = try expander.expandWord(word);
                try fields.append(self.alloc, cmd);
                continue;
            }
            const is_assign = blk: {
                if (word.parts.len > 0) {
                    switch (word.parts[0]) {
                        .literal => |lit| {
                            if (std.mem.indexOf(u8, lit, "=") != null) break :blk true;
                        },
                        else => {},
                    }
                }
                break :blk false;
            };
            if (is_assign) {
                var expanded = try expander.expandWord(word);
                if (std.mem.indexOf(u8, expanded, "=")) |eq_pos| {
                    expanded = try self.expandTildesInAssignValue(expanded, eq_pos + 1);
                }
                try fields.append(self.alloc, expanded);
            } else {
                const expanded = try expander.expandWordsToFields(&.{word});
                try fields.appendSlice(self.alloc, expanded);
            }
        }
        return fields.toOwnedSlice(self.alloc);
    }
};

fn isSpecialBuiltin(name: []const u8) bool {
    const specials = [_][]const u8{
        ":",      ".",        "break", "continue", "eval",  "exec", "exit",
        "export", "readonly", "set",   "shift",    "unset",
    };
    for (specials) |s| {
        if (std.mem.eql(u8, name, s)) return true;
    }
    return false;
}

fn parseFdMove(s: []const u8) ?i32 {
    if (s.len >= 2 and s[s.len - 1] == '-') {
        return std.fmt.parseInt(i32, s[0 .. s.len - 1], 10) catch return null;
    }
    return null;
}

fn astToRedirectOp(op: ast.RedirectOp) redirect.RedirectOp {
    return switch (op) {
        .input => .input,
        .output => .output,
        .append => .append,
        .dup_input => .dup_input,
        .dup_output => .dup_output,
        .read_write => .read_write,
        .clobber => .clobber,
        .heredoc => .heredoc,
        .heredoc_strip => .heredoc_strip,
        .here_string => .here_string,
        .and_great => .output,
        .and_dgreat => .append,
    };
}
