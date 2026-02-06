const std = @import("std");
const ast = @import("ast.zig");
const Lexer = @import("lexer.zig").Lexer;
const Parser = @import("parser.zig").Parser;
const Environment = @import("env.zig").Environment;
const Expander = @import("expander.zig").Expander;
const JobTable = @import("jobs.zig").JobTable;
const builtins = @import("builtins.zig");
const redirect = @import("redirect.zig");
const posix = @import("posix.zig");
const types = @import("types.zig");
const glob = @import("glob.zig");
const signals = @import("signals.zig");

pub const Executor = struct {
    env: *Environment,
    jobs: *JobTable,
    alloc: std.mem.Allocator,
    in_err_trap: bool = false,

    pub fn init(alloc: std.mem.Allocator, env: *Environment, jobs: *JobTable) Executor {
        return .{ .env = env, .jobs = jobs, .alloc = alloc };
    }

    pub fn executeProgram(self: *Executor, program: ast.Program) u8 {
        var status: u8 = 0;
        for (program.commands) |cmd| {
            status = self.executeCompleteCommand(cmd);
            if (self.env.should_exit) break;
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
            posix.setpgid(0, 0) catch {};
            posix.exit(self.executeList(list));
        }
        posix.setpgid(pid, pid) catch {};
        self.registerBackground(pid);
        return 0;
    }

    fn executeList(self: *Executor, list: ast.List) u8 {
        var status: u8 = 0;
        const first_bg = list.rest.len > 0 and list.rest[0].op == .amp;
        if (first_bg) {
            status = self.runInBackground(list.first);
        } else {
            status = self.executeAndOr(list.first);
        }

        for (list.rest, 0..) |item, idx| {
            if (self.env.should_exit or self.env.should_return or
                self.env.break_count > 0 or self.env.continue_count > 0) break;
            const next_bg = (idx + 1 < list.rest.len) and list.rest[idx + 1].op == .amp;
            if (next_bg) {
                status = self.runInBackground(item.and_or);
            } else {
                status = self.executeAndOr(item.and_or);
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
            posix.setpgid(0, 0) catch {};
            _ = self.executeAndOr(and_or);
            posix.exit(0);
        }
        posix.setpgid(pid, pid) catch {};
        self.registerBackground(pid);
        return 0;
    }

    fn registerBackground(self: *Executor, pid: posix.pid_t) void {
        self.env.last_bg_pid = pid;
        const job_id = self.jobs.addJob(pid, pid, "background") catch 0;
        var buf: [32]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "[{d}] {d}\n", .{ job_id, pid }) catch "";
        posix.writeAll(2, msg);
    }

    fn executeAndOr(self: *Executor, and_or: ast.AndOr) u8 {
        var status = self.executePipeline(and_or.first);
        for (and_or.rest) |item| {
            if (self.env.should_exit or self.env.should_return or
                self.env.break_count > 0 or self.env.continue_count > 0) break;
            switch (item.op) {
                .and_if => {
                    if (status == 0) {
                        status = self.executePipeline(item.pipeline);
                    }
                },
                .or_if => {
                    if (status != 0) {
                        status = self.executePipeline(item.pipeline);
                    }
                },
            }
        }
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
        if (pipeline.commands.len == 1) {
            const status = self.executeCommand(pipeline.commands[0]);
            if (pipeline.bang) return if (status == 0) 1 else 0;
            return status;
        }

        var prev_read_fd: ?types.Fd = null;
        var last_pid: ?posix.pid_t = null;
        var child_pids: [64]posix.pid_t = undefined;
        var num_children: usize = 0;

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

            const pid = posix.fork() catch {
                posix.writeAll(2, "zigsh: fork failed\n");
                return 1;
            };

            if (pid == 0) {
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
        for (child_pids[0..num_children]) |cpid| {
            const result = posix.waitpid(cpid, 0);
            if (cpid == last_pid) {
                status = posix.statusFromWait(result.status);
            }
        }

        if (pipeline.bang) return if (status == 0) 1 else 0;
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
        var expander = Expander.init(self.alloc, self.env, self.jobs);

        for (simple.assigns) |assign| {
            const value = expander.expandWord(assign.value) catch "";
            if (simple.words.len == 0) {
                self.env.set(assign.name, value, false) catch {};
            }
        }

        if (simple.words.len == 0) return 0;

        const fields = expander.expandWordsToFields(simple.words) catch {
            posix.writeAll(2, "zigsh: expansion error\n");
            return 1;
        };
        if (fields.len == 0) return 0;

        if (self.env.getAlias(fields[0])) |alias_val| {
            var alias_buf: std.ArrayListUnmanaged(u8) = .empty;
            defer alias_buf.deinit(self.alloc);
            alias_buf.appendSlice(self.alloc, alias_val) catch return 1;
            for (fields[1..]) |f| {
                alias_buf.append(self.alloc, ' ') catch return 1;
                alias_buf.appendSlice(self.alloc, f) catch return 1;
            }
            return self.executeInline(alias_buf.items);
        }

        if (self.env.options.xtrace) {
            posix.writeAll(2, "+ ");
            for (fields, 0..) |f, idx| {
                if (idx > 0) posix.writeAll(2, " ");
                posix.writeAll(2, f);
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
            status = self.executeSourceBuiltin(fields);
        } else if (std.mem.eql(u8, cmd_name, "eval")) {
            status = self.executeEvalBuiltin(fields);
        } else if (std.mem.eql(u8, cmd_name, "exec")) {
            status = self.executeExecBuiltin(fields, simple.assigns, &expander);
            redir_state.restore();
            self.env.last_exit_status = status;
            return status;
        } else if (std.mem.eql(u8, cmd_name, "command")) {
            status = self.executeCommandBuiltin(fields, simple.assigns, &expander);
        } else if (builtins.lookup(cmd_name)) |builtin_fn| {
            if (simple.assigns.len > 0 and simple.words.len > 0) {
                for (simple.assigns) |assign| {
                    const value = expander.expandWord(assign.value) catch "";
                    self.env.set(assign.name, value, false) catch {};
                }
            }
            status = builtin_fn(fields, self.env);
        } else if (self.env.functions.get(cmd_name)) |_| {
            status = self.executeFunction(cmd_name, fields);
        } else {
            status = self.executeExternal(fields, simple.assigns, &expander);
        }

        redir_state.restore();
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
            .case_clause => |cc| self.executeCaseClause(cc),
        };

        redir_state.restore();
        return status;
    }

    fn executeFunctionDef(self: *Executor, fd: ast.FunctionDef) u8 {
        const source = self.env.alloc.dupe(u8, fd.source) catch return 1;
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
            if (self.env.options.errexit and status != 0) {
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
            const status = self.executeCompoundList(sub.body);
            posix.exit(status);
        }
        const result = posix.waitpid(pid, 0);
        return posix.statusFromWait(result.status);
    }

    fn executeIfClause(self: *Executor, ic: ast.IfClause) u8 {
        const cond_status = self.executeCompoundList(ic.condition);
        if (cond_status == 0) {
            return self.executeCompoundList(ic.then_body);
        }

        for (ic.elifs) |elif| {
            const elif_status = self.executeCompoundList(elif.condition);
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
            const cond = self.executeCompoundList(wc.condition);
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
            const cond = self.executeCompoundList(uc.condition);
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

    fn executeCaseClause(self: *Executor, cc: ast.CaseClause) u8 {
        var expander = Expander.init(self.alloc, self.env, self.jobs);
        const word_val = expander.expandWord(cc.word) catch return 1;

        for (cc.items) |item| {
            for (item.patterns) |pattern| {
                const pat_val = expander.expandWord(pattern) catch continue;
                if (glob.fnmatch(pat_val, word_val)) {
                    if (item.body) |body| {
                        return self.executeCompoundList(body);
                    }
                    return 0;
                }
            }
        }
        return 0;
    }

    fn executeFunction(self: *Executor, name: []const u8, fields: []const []const u8) u8 {
        const func = self.env.functions.get(name) orelse return 127;

        self.env.pushPositionalParams(fields[1..]) catch return 1;
        defer self.env.popPositionalParams();

        var lexer = Lexer.init(func.source);
        var parser = Parser.init(self.alloc, &lexer) catch return 2;
        const program = parser.parseProgram() catch return 2;

        var status: u8 = 0;
        for (program.commands) |cmd| {
            status = self.executeCompleteCommand(cmd);
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

            posix.execve(path, argv, envp) catch {};
            posix.exit(126);
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
            if (st.mode & posix.S_IFMT == posix.S_IFREG) {
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

    fn applyAstRedirect(self: *Executor, redir: ast.Redirect, state: *redirect.RedirectState, expander: *Expander) !void {
        const fd: types.Fd = redir.fd orelse redirect.defaultFdForOp(astToRedirectOp(redir.op));
        const op = astToRedirectOp(redir.op);

        switch (redir.target) {
            .word => |word| {
                const expanded = expander.expandWord(word) catch return error.RedirectionFailed;
                const path_z = self.alloc.dupeZ(u8, expanded) catch return error.RedirectionFailed;
                try redirect.applyFileRedirect(fd, path_z.ptr, op, state);
            },
            .fd => |target_fd| try redirect.applyDupRedirect(fd, target_fd, state),
            .close => try redirect.applyCloseRedirect(fd, state),
            .heredoc => |hd| {
                const pipe_fds = posix.pipe() catch return error.RedirectionFailed;
                _ = posix.write(pipe_fds[1], hd.body_ptr.*) catch {};
                posix.close(pipe_fds[1]);
                try state.save(fd);
                posix.dup2(pipe_fds[0], fd) catch return error.RedirectionFailed;
                posix.close(pipe_fds[0]);
            },
        }
    }

    fn executeSourceBuiltin(self: *Executor, fields: []const []const u8) u8 {
        if (fields.len < 2) {
            posix.writeAll(2, ".: usage: . filename [arguments]\n");
            return 2;
        }

        const path = fields[1];
        const fd = posix.open(path, posix.oRdonly(), 0) catch {
            posix.writeAll(2, ".: ");
            posix.writeAll(2, path);
            posix.writeAll(2, ": No such file or directory\n");
            return 1;
        };
        defer posix.close(fd);

        var content: std.ArrayListUnmanaged(u8) = .empty;
        defer content.deinit(self.alloc);
        posix.readToEnd(fd, self.alloc, &content) catch return 1;

        if (fields.len > 2) {
            self.env.pushPositionalParams(fields[2..]) catch return 1;
            defer self.env.popPositionalParams();
            return self.executeInline(content.items);
        }
        return self.executeInline(content.items);
    }

    fn executeEvalBuiltin(self: *Executor, fields: []const []const u8) u8 {
        if (fields.len < 2) return 0;

        var eval_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer eval_buf.deinit(self.alloc);
        for (fields[1..], 0..) |f, i| {
            if (i > 0) eval_buf.append(self.alloc, ' ') catch return 1;
            eval_buf.appendSlice(self.alloc, f) catch return 1;
        }

        return self.executeInline(eval_buf.items);
    }

    fn executeExecBuiltin(self: *Executor, fields: []const []const u8, assigns: []const ast.Assignment, expander: *Expander) u8 {
        if (fields.len < 2) return 0;

        for (assigns) |assign| {
            const value = expander.expandWord(assign.value) catch "";
            self.env.set(assign.name, value, true) catch {};
        }

        const path = self.findExecutable(fields[1]) orelse {
            posix.writeAll(2, "exec: ");
            posix.writeAll(2, fields[1]);
            posix.writeAll(2, ": not found\n");
            return 127;
        };

        const envp = self.env.buildEnvp() catch return 1;
        const argv = self.buildArgv(fields[1..]) catch return 1;
        posix.execve(path, argv, envp) catch {};
        posix.writeAll(2, "exec: failed\n");
        return 126;
    }

    fn executeCommandBuiltin(self: *Executor, fields: []const []const u8, assigns: []const ast.Assignment, expander: *Expander) u8 {
        if (fields.len < 2) return 0;

        var start: usize = 1;
        var show_type = false;
        while (start < fields.len) {
            if (std.mem.eql(u8, fields[start], "-v") or std.mem.eql(u8, fields[start], "-V")) {
                show_type = true;
                start += 1;
            } else if (std.mem.eql(u8, fields[start], "-p")) {
                start += 1;
            } else {
                break;
            }
        }
        if (start >= fields.len) return 0;

        if (show_type) {
            const name = fields[start];
            if (builtins.lookup(name) != null) {
                posix.writeAll(1, name);
                posix.writeAll(1, "\n");
                return 0;
            }
            if (self.findExecutable(name)) |path| {
                posix.writeAll(1, std.mem.sliceTo(path, 0));
                posix.writeAll(1, "\n");
                return 0;
            }
            return 1;
        }

        const cmd_name = fields[start];
        if (builtins.lookup(cmd_name)) |builtin_fn| {
            return builtin_fn(fields[start..], self.env);
        }
        return self.executeExternal(fields[start..], assigns, expander);
    }

    fn executeInline(self: *Executor, source: []const u8) u8 {
        var lexer = Lexer.init(source);
        var parser = Parser.init(self.alloc, &lexer) catch return 2;
        const program = parser.parseProgram() catch return 2;
        return self.executeProgram(program);
    }
};

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
    };
}
