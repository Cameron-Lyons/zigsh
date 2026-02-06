const std = @import("std");
const posix = @import("posix.zig");
const signals = @import("signals.zig");

pub const JobState = enum {
    running,
    stopped,
    done,
};

pub const Job = struct {
    id: u32,
    pgid: posix.pid_t,
    command: []const u8,
    state: JobState,
    pid: posix.pid_t,
    status: u8,
    notified: bool,
};

pub const MAX_JOBS = 64;

pub const JobTable = struct {
    jobs: *[MAX_JOBS]?Job,
    count: u32,
    next_id: u32,
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) JobTable {
        const jobs = alloc.create([MAX_JOBS]?Job) catch @panic("failed to allocate job table");
        jobs.* = [_]?Job{null} ** MAX_JOBS;
        return .{
            .jobs = jobs,
            .count = 0,
            .next_id = 1,
            .alloc = alloc,
        };
    }

    pub fn deinit(self: *JobTable) void {
        for (&self.jobs.*) |*slot| {
            if (slot.*) |job| {
                self.alloc.free(job.command);
                slot.* = null;
            }
        }
        self.alloc.destroy(self.jobs);
    }

    pub fn addJob(self: *JobTable, pgid: posix.pid_t, pid: posix.pid_t, command: []const u8) !u32 {
        for (&self.jobs.*) |*slot| {
            if (slot.* == null) {
                const id = self.next_id;
                self.next_id += 1;
                self.count += 1;
                slot.* = .{
                    .id = id,
                    .pgid = pgid,
                    .command = try self.alloc.dupe(u8, command),
                    .state = .running,
                    .pid = pid,
                    .status = 0,
                    .notified = false,
                };
                return id;
            }
        }
        return error.TooManyJobs;
    }

    pub fn findByPgid(self: *JobTable, pgid: posix.pid_t) ?*Job {
        for (&self.jobs.*) |*slot| {
            if (slot.*) |*job| {
                if (job.pgid == pgid) return job;
            }
        }
        return null;
    }

    pub fn findById(self: *JobTable, id: u32) ?*Job {
        for (&self.jobs.*) |*slot| {
            if (slot.*) |*job| {
                if (job.id == id) return job;
            }
        }
        return null;
    }

    pub fn findByPid(self: *JobTable, pid: posix.pid_t) ?*Job {
        for (&self.jobs.*) |*slot| {
            if (slot.*) |*job| {
                if (job.pid == pid) return job;
            }
        }
        return null;
    }

    pub fn removeJob(self: *JobTable, id: u32) void {
        for (&self.jobs.*) |*slot| {
            if (slot.*) |job| {
                if (job.id == id) {
                    self.alloc.free(job.command);
                    slot.* = null;
                    self.count -= 1;
                    return;
                }
            }
        }
    }

    pub fn updateJobStatus(self: *JobTable) void {
        while (true) {
            const result = posix.waitpid(-1, 1 | 2);
            if (result.pid <= 0) break;

            if (self.findByPid(result.pid)) |job| {
                if (result.status & 0x7f == 0) {
                    job.state = .done;
                    job.status = @truncate((result.status >> 8) & 0xff);
                    job.notified = false;
                } else if (result.status & 0xff == 0x7f) {
                    job.state = .stopped;
                    job.notified = false;
                }
            }
        }
    }

    pub fn notifyDoneJobs(self: *JobTable) void {
        for (&self.jobs.*) |*slot| {
            if (slot.*) |*job| {
                if (job.state == .done and !job.notified) {
                    posix.writeAll(2, "[");
                    var buf: [16]u8 = undefined;
                    const id_str = std.fmt.bufPrint(&buf, "{d}", .{job.id}) catch "";
                    posix.writeAll(2, id_str);
                    posix.writeAll(2, "]  Done\t\t");
                    posix.writeAll(2, job.command);
                    posix.writeAll(2, "\n");
                    job.notified = true;
                    self.alloc.free(job.command);
                    slot.* = null;
                    self.count -= 1;
                }
            }
        }
    }

    pub fn currentJob(self: *JobTable) ?*Job {
        var best: ?*Job = null;
        for (&self.jobs.*) |*slot| {
            if (slot.*) |*job| {
                if (job.state != .done) {
                    if (best == null or job.id > best.?.id) {
                        best = job;
                    }
                }
            }
        }
        return best;
    }

    pub fn previousJob(self: *JobTable) ?*Job {
        const current = self.currentJob() orelse return null;
        var best: ?*Job = null;
        for (&self.jobs.*) |*slot| {
            if (slot.*) |*job| {
                if (job.state != .done and job.id != current.id) {
                    if (best == null or job.id > best.?.id) {
                        best = job;
                    }
                }
            }
        }
        return best;
    }

    pub fn parseJobSpec(self: *JobTable, spec: []const u8) ?*Job {
        if (spec.len == 0 or std.mem.eql(u8, spec, "%%") or std.mem.eql(u8, spec, "%+")) {
            return self.currentJob();
        }
        if (std.mem.eql(u8, spec, "%-")) {
            return self.previousJob();
        }
        if (spec[0] == '%') {
            if (spec.len > 1) {
                if (std.fmt.parseInt(u32, spec[1..], 10)) |id| {
                    return self.findById(id);
                } else |_| {
                    const prefix = spec[1..];
                    for (&self.jobs.*) |*slot| {
                        if (slot.*) |*job| {
                            if (job.state != .done and job.command.len >= prefix.len and
                                std.mem.eql(u8, job.command[0..prefix.len], prefix))
                            {
                                return job;
                            }
                        }
                    }
                }
            }
            return null;
        }
        if (std.fmt.parseInt(u32, spec, 10)) |id| {
            return self.findById(id);
        } else |_| {}
        return null;
    }
};

test "parseJobSpec by id" {
    var jt = JobTable.init(std.testing.allocator);
    defer jt.deinit();

    const id1 = try jt.addJob(100, 100, "sleep 10");
    const id2 = try jt.addJob(101, 101, "cat file");

    const j1 = jt.parseJobSpec("%1");
    try std.testing.expect(j1 != null);
    try std.testing.expectEqual(id1, j1.?.id);

    const j2 = jt.parseJobSpec("%2");
    try std.testing.expect(j2 != null);
    try std.testing.expectEqual(id2, j2.?.id);

    try std.testing.expect(jt.parseJobSpec("%99") == null);
}

test "currentJob and previousJob" {
    var jt = JobTable.init(std.testing.allocator);
    defer jt.deinit();

    try std.testing.expect(jt.currentJob() == null);
    try std.testing.expect(jt.previousJob() == null);

    _ = try jt.addJob(100, 100, "job1");
    const id2 = try jt.addJob(101, 101, "job2");

    const cur = jt.currentJob().?;
    try std.testing.expectEqual(id2, cur.id);

    const prev = jt.previousJob().?;
    try std.testing.expect(prev.id != cur.id);
}

test "parseJobSpec empty and %% return current" {
    var jt = JobTable.init(std.testing.allocator);
    defer jt.deinit();

    const id = try jt.addJob(100, 100, "sleep 5");

    const j1 = jt.parseJobSpec("");
    try std.testing.expect(j1 != null);
    try std.testing.expectEqual(id, j1.?.id);

    const j2 = jt.parseJobSpec("%%");
    try std.testing.expect(j2 != null);
    try std.testing.expectEqual(id, j2.?.id);
}

test "parseJobSpec by prefix" {
    var jt = JobTable.init(std.testing.allocator);
    defer jt.deinit();

    _ = try jt.addJob(100, 100, "sleep 10");
    _ = try jt.addJob(101, 101, "cat file");

    const j = jt.parseJobSpec("%sle");
    try std.testing.expect(j != null);
    try std.testing.expectEqualStrings("sleep 10", j.?.command);

    try std.testing.expect(jt.parseJobSpec("%xyz") == null);
}
