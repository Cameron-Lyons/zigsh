const std = @import("std");
const posix = @import("posix.zig");
const types = @import("types.zig");

pub const SavedFd = struct {
    original_fd: types.Fd,
    saved_fd: types.Fd,
    was_closed: bool,
};

pub const RedirectState = struct {
    saved: [16]SavedFd = undefined,
    count: u8 = 0,

    pub fn save(self: *RedirectState, fd: types.Fd) !void {
        if (self.count >= 16) return error.TooManyRedirections;

        const saved_fd = posix.dupHighFd(fd) catch {
            self.saved[self.count] = .{
                .original_fd = fd,
                .saved_fd = -1,
                .was_closed = true,
            };
            self.count += 1;
            return;
        };

        self.saved[self.count] = .{
            .original_fd = fd,
            .saved_fd = saved_fd,
            .was_closed = false,
        };
        self.count += 1;
    }

    pub fn restore(self: *RedirectState) void {
        while (self.count > 0) {
            self.count -= 1;
            const s = self.saved[self.count];
            if (s.was_closed) {
                posix.close(s.original_fd);
            } else {
                posix.dup2(s.saved_fd, s.original_fd) catch {};
                posix.close(s.saved_fd);
            }
        }
    }
};

pub const ApplyError = error{
    RedirectionFailed,
    DupFailed,
    TooManyRedirections,
};

pub const RedirectOp = enum {
    input,
    output,
    append,
    dup_input,
    dup_output,
    read_write,
    clobber,
    heredoc,
    heredoc_strip,
    here_string,
};

pub fn applyFileRedirect(fd: types.Fd, path: [*:0]const u8, op: RedirectOp, state: *RedirectState, noclobber: bool) ApplyError!void {
    try state.save(fd);
    const use_noclobber = if (noclobber and op == .output) blk: {
        const st = posix.stat(path) catch break :blk true;
        break :blk (st.mode & posix.S_IFMT == posix.S_IFREG);
    } else false;
    const flags: posix.OpenFlags = switch (op) {
        .input, .heredoc, .heredoc_strip, .here_string => posix.oRdonly(),
        .output => if (use_noclobber) posix.oWronlyCreatExcl() else posix.oWronlyCreatTrunc(),
        .clobber => posix.oWronlyCreatTrunc(),
        .append => posix.oWronlyCreatAppend(),
        .read_write => posix.oRdwrCreat(),
        .dup_input, .dup_output => posix.oRdonly(),
    };
    const new_fd = posix.openZ(path, flags, 0o644) catch return error.RedirectionFailed;
    if (new_fd != fd) {
        posix.dup2(new_fd, fd) catch return error.DupFailed;
        posix.close(new_fd);
    }
}

pub fn applyDupRedirect(fd: types.Fd, target_fd: types.Fd, state: *RedirectState) ApplyError!void {
    try state.save(fd);
    posix.dup2(target_fd, fd) catch return error.DupFailed;
}

pub fn applyCloseRedirect(fd: types.Fd, state: *RedirectState) ApplyError!void {
    try state.save(fd);
    posix.close(fd);
}

pub fn defaultFdForOp(op: RedirectOp) types.Fd {
    return switch (op) {
        .input, .heredoc, .heredoc_strip, .here_string, .read_write, .dup_input => types.STDIN,
        .output, .append, .dup_output, .clobber => types.STDOUT,
    };
}
