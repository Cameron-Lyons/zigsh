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
};
