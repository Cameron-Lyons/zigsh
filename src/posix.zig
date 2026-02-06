const std = @import("std");
const linux = std.os.linux;
const c = std.c;

pub const fd_t = i32;
pub const pid_t = i32;
pub const mode_t = u32;

pub const O = std.posix.O;
pub const S = std.posix.S;
pub const AT = std.posix.AT;

pub fn pipe() ![2]fd_t {
    var fds: [2]fd_t = undefined;
    const rc = c.pipe(&fds);
    if (rc < 0) return error.PipeFailed;
    return fds;
}

pub fn dup(old: fd_t) !fd_t {
    const rc = c.dup(old);
    if (rc < 0) return error.BadFd;
    return rc;
}

pub fn dup2(old: fd_t, new: fd_t) !void {
    const rc = c.dup2(old, new);
    if (rc < 0) return error.DupFailed;
}

pub fn close(fd: fd_t) void {
    _ = c.close(fd);
}

pub fn fork() !pid_t {
    const rc = c.fork();
    if (rc < 0) return error.ForkFailed;
    return rc;
}

pub fn execve(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) error{ExecFailed} {
    _ = c.execve(path, argv, envp);
    return error.ExecFailed;
}

pub const WaitResult = struct {
    pid: pid_t,
    status: u32,
};

pub fn waitpid(pid: pid_t, flags: u32) WaitResult {
    var status: c_int = 0;
    const result = c.waitpid(pid, &status, @intCast(flags));
    return .{
        .pid = result,
        .status = @bitCast(status),
    };
}

pub const OpenFlags = std.c.O;

pub fn openZ(path: [*:0]const u8, flags: OpenFlags, mode: mode_t) !fd_t {
    const rc = c.open(path, flags, mode);
    if (rc < 0) return error.OpenFailed;
    return rc;
}

pub fn open(path: []const u8, flags: OpenFlags, mode: mode_t) !fd_t {
    const path_z = std.posix.toPosixPath(path) catch return error.NameTooLong;
    return openZ(&path_z, flags, mode);
}

pub fn getcwd(buf: []u8) ![]const u8 {
    const result = c.getcwd(buf.ptr, buf.len);
    if (result == null) return error.GetCwdFailed;
    const ptr: [*:0]const u8 = @ptrCast(result.?);
    return std.mem.sliceTo(ptr, 0);
}

pub fn chdir(path: []const u8) !void {
    const path_z = std.posix.toPosixPath(path) catch return error.NameTooLong;
    return chdirZ(&path_z);
}

pub fn chdirZ(path: [*:0]const u8) !void {
    const rc = c.chdir(path);
    if (rc < 0) return error.ChdirFailed;
}

pub const StatResult = struct {
    mode: u16,
    size: u64,
};

pub fn stat(path: [*:0]const u8) !StatResult {
    var stx: linux.Statx = undefined;
    const rc = linux.statx(
        @as(i32, -100),
        path,
        0,
        .{ .TYPE = true, .MODE = true, .SIZE = true },
        &stx,
    );
    const signed: isize = @bitCast(rc);
    if (signed < 0) return error.StatFailed;
    return .{ .mode = stx.mode, .size = stx.size };
}

pub fn access(path: [*:0]const u8, mode: c_uint) bool {
    return c.access(path, mode) == 0;
}

pub fn read(fd: fd_t, buf: []u8) !usize {
    const result = c.read(fd, buf.ptr, buf.len);
    if (result < 0) return error.ReadFailed;
    return @intCast(result);
}

pub fn write(fd: fd_t, data: []const u8) !usize {
    const result = c.write(fd, data.ptr, data.len);
    if (result < 0) return error.WriteFailed;
    return @intCast(result);
}

pub fn writeAll(fd: fd_t, data: []const u8) void {
    var written: usize = 0;
    while (written < data.len) {
        const result = c.write(fd, data[written..].ptr, data[written..].len);
        if (result < 0) return;
        written += @intCast(result);
    }
}

pub fn setpgid(pid: pid_t, pgid: pid_t) !void {
    const rc = c.setpgid(pid, pgid);
    if (rc < 0) return error.SetPgidFailed;
}

pub fn tcsetpgrp(fd: fd_t, pgrp: pid_t) !void {
    _ = c.tcsetpgrp(fd, pgrp);
}

pub fn tcgetpgrp(fd: fd_t) !pid_t {
    const rc = c.tcgetpgrp(fd);
    if (rc < 0) return error.TcgetpgrpFailed;
    return rc;
}

pub fn getpid() pid_t {
    return c.getpid();
}

pub fn isatty(fd: fd_t) bool {
    return c.isatty(fd) != 0;
}

pub fn fcntl_setfd(fd: fd_t, flags: c_int) !void {
    const rc = c.fcntl(fd, c.F.SETFD, flags);
    if (rc < 0) return error.FcntlFailed;
}

pub const FD_CLOEXEC = 1;

pub fn oRdonly() OpenFlags {
    return .{ .ACCMODE = .RDONLY };
}

pub fn oWronly() OpenFlags {
    return .{ .ACCMODE = .WRONLY };
}

pub fn oRdwr() OpenFlags {
    return .{ .ACCMODE = .RDWR };
}

pub fn oWronlyCreatTrunc() OpenFlags {
    return .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true };
}

pub fn oWronlyCreatAppend() OpenFlags {
    return .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true };
}

pub fn oRdwrCreat() OpenFlags {
    return .{ .ACCMODE = .RDWR, .CREAT = true };
}

pub const S_IFMT: u16 = 0o170000;
pub const S_IFDIR: u16 = 0o040000;
pub const S_IFREG: u16 = 0o100000;

pub fn exit(status: u8) noreturn {
    std.process.exit(status);
}
