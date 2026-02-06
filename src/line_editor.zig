const std = @import("std");
const posix = @import("posix.zig");

const c = std.c;

const Termios = extern struct {
    iflag: u32,
    oflag: u32,
    cflag: u32,
    lflag: u32,
    line: u8,
    cc: [32]u8,
    ispeed: u32,
    ospeed: u32,
};

extern "c" fn tcgetattr(fd: c_int, termios: *Termios) c_int;
extern "c" fn tcsetattr(fd: c_int, action: c_int, termios: *const Termios) c_int;

const TCSAFLUSH = 2;
const ICANON: u32 = 0o000002;
const ECHO_FLAG: u32 = 0o000010;
const ISIG: u32 = 0o000001;
const IXON: u32 = 0o002000;
const IEXTEN: u32 = 0o100000;
const ICRNL: u32 = 0o000400;
const OPOST: u32 = 0o000001;
const VMIN = 6;
const VTIME = 5;

pub const LineEditor = struct {
    buf: [4096]u8 = undefined,
    len: usize = 0,
    cursor: usize = 0,
    orig_termios: Termios = undefined,
    raw_mode: bool = false,
    history: *History,
    history_idx: usize = 0,
    saved_line: [4096]u8 = undefined,
    saved_len: usize = 0,
    prompt: []const u8 = "$ ",

    pub const History = struct {
        entries: [1024]?[]const u8,
        count: usize,
        alloc: std.mem.Allocator,
        file_path: ?[]const u8,

        pub fn init(alloc: std.mem.Allocator) History {
            return .{
                .entries = [_]?[]const u8{null} ** 1024,
                .count = 0,
                .alloc = alloc,
                .file_path = null,
            };
        }

        pub fn deinit(self: *History) void {
            for (&self.entries) |*entry| {
                if (entry.*) |e| {
                    self.alloc.free(e);
                    entry.* = null;
                }
            }
            if (self.file_path) |fp| {
                self.alloc.free(fp);
            }
        }

        pub fn add(self: *History, line: []const u8) void {
            if (line.len == 0) return;
            if (self.count > 0) {
                if (self.entries[self.count - 1]) |last| {
                    if (std.mem.eql(u8, last, line)) return;
                }
            }
            const duped = self.alloc.dupe(u8, line) catch return;
            if (self.count < self.entries.len) {
                self.entries[self.count] = duped;
                self.count += 1;
            } else {
                if (self.entries[0]) |first| {
                    self.alloc.free(first);
                }
                for (0..self.entries.len - 1) |i| {
                    self.entries[i] = self.entries[i + 1];
                }
                self.entries[self.entries.len - 1] = duped;
            }
        }

        pub fn get(self: *const History, idx: usize) ?[]const u8 {
            if (idx < self.count) return self.entries[idx];
            return null;
        }

        pub fn loadFile(self: *History, path: []const u8) void {
            if (self.file_path) |fp| self.alloc.free(fp);
            self.file_path = self.alloc.dupe(u8, path) catch return;
            const fd = posix.open(path, posix.oRdonly(), 0) catch return;
            defer posix.close(fd);
            var file_buf: [65536]u8 = undefined;
            var content: std.ArrayListUnmanaged(u8) = .empty;
            defer content.deinit(self.alloc);
            while (true) {
                const n = posix.read(fd, &file_buf) catch break;
                if (n == 0) break;
                content.appendSlice(self.alloc, file_buf[0..n]) catch return;
            }
            var iter = std.mem.splitScalar(u8, content.items, '\n');
            while (iter.next()) |line| {
                if (line.len > 0) self.add(line);
            }
        }

        pub fn saveFile(self: *const History) void {
            const path = self.file_path orelse return;
            const fd = posix.openZ(
                (self.alloc.dupeZ(u8, path) catch return).ptr,
                posix.oWronlyCreatTrunc(),
                0o644,
            ) catch return;
            defer posix.close(fd);
            for (0..self.count) |i| {
                if (self.entries[i]) |entry| {
                    _ = posix.write(fd, entry) catch {};
                    _ = posix.write(fd, "\n") catch {};
                }
            }
        }
    };

    pub fn init(history: *History) LineEditor {
        return .{
            .history = history,
        };
    }

    pub fn readLine(self: *LineEditor, prompt: []const u8) ?[]const u8 {
        self.len = 0;
        self.cursor = 0;
        self.history_idx = self.history.count;
        self.saved_len = 0;
        self.prompt = prompt;

        if (!posix.isatty(0)) {
            return self.readSimpleLine();
        }

        self.enableRawMode();
        defer self.disableRawMode();

        posix.writeAll(2, prompt);

        while (true) {
            var ch_buf: [1]u8 = undefined;
            const n = posix.read(0, &ch_buf) catch return null;
            if (n == 0) {
                if (self.len == 0) return null;
                break;
            }
            const ch = ch_buf[0];

            switch (ch) {
                '\r', '\n' => {
                    posix.writeAll(2, "\n");
                    break;
                },
                4 => {
                    if (self.len == 0) return null;
                },
                127, 8 => self.backspace(),
                1 => self.moveHome(),
                5 => self.moveEnd(),
                2 => self.moveLeft(),
                6 => self.moveRight(),
                11 => self.killToEnd(),
                21 => self.killToBeginning(),
                23 => self.killWord(),
                12 => self.clearScreen(),
                16 => self.historyPrev(),
                14 => self.historyNext(),
                27 => self.handleEscape(),
                3 => {
                    posix.writeAll(2, "^C\n");
                    self.len = 0;
                    self.cursor = 0;
                    posix.writeAll(2, self.prompt);
                },
                else => {
                    if (ch >= 32) {
                        self.insertChar(ch);
                    }
                },
            }
        }

        const line = self.buf[0..self.len];
        self.history.add(line);
        return line;
    }

    fn readSimpleLine(self: *LineEditor) ?[]const u8 {
        var total: usize = 0;
        while (total < self.buf.len) {
            const n = posix.read(0, self.buf[total..]) catch return null;
            if (n == 0) {
                if (total == 0) return null;
                break;
            }
            total += n;
            if (std.mem.indexOfScalar(u8, self.buf[total - n .. total], '\n')) |nl| {
                total = total - n + nl;
                break;
            }
        }
        return self.buf[0..total];
    }

    fn enableRawMode(self: *LineEditor) void {
        if (tcgetattr(0, &self.orig_termios) < 0) return;
        var raw = self.orig_termios;
        raw.iflag &= ~(ICRNL | IXON);
        raw.oflag &= ~OPOST;
        raw.lflag &= ~(ECHO_FLAG | ICANON | IEXTEN | ISIG);
        raw.cc[VMIN] = 1;
        raw.cc[VTIME] = 0;
        _ = tcsetattr(0, TCSAFLUSH, &raw);
        self.raw_mode = true;
    }

    fn disableRawMode(self: *LineEditor) void {
        if (self.raw_mode) {
            _ = tcsetattr(0, TCSAFLUSH, &self.orig_termios);
            self.raw_mode = false;
        }
    }

    fn insertChar(self: *LineEditor, ch: u8) void {
        if (self.len >= self.buf.len - 1) return;
        if (self.cursor < self.len) {
            std.mem.copyBackwards(u8, self.buf[self.cursor + 1 .. self.len + 1], self.buf[self.cursor .. self.len]);
        }
        self.buf[self.cursor] = ch;
        self.len += 1;
        self.cursor += 1;
        self.refreshLine();
    }

    fn backspace(self: *LineEditor) void {
        if (self.cursor == 0) return;
        std.mem.copyForwards(u8, self.buf[self.cursor - 1 .. self.len - 1], self.buf[self.cursor .. self.len]);
        self.cursor -= 1;
        self.len -= 1;
        self.refreshLine();
    }

    fn deleteChar(self: *LineEditor) void {
        if (self.cursor >= self.len) return;
        std.mem.copyForwards(u8, self.buf[self.cursor .. self.len - 1], self.buf[self.cursor + 1 .. self.len]);
        self.len -= 1;
        self.refreshLine();
    }

    fn moveLeft(self: *LineEditor) void {
        if (self.cursor > 0) {
            self.cursor -= 1;
            posix.writeAll(2, "\x1b[D");
        }
    }

    fn moveRight(self: *LineEditor) void {
        if (self.cursor < self.len) {
            self.cursor += 1;
            posix.writeAll(2, "\x1b[C");
        }
    }

    fn moveHome(self: *LineEditor) void {
        self.cursor = 0;
        self.refreshLine();
    }

    fn moveEnd(self: *LineEditor) void {
        self.cursor = self.len;
        self.refreshLine();
    }

    fn killToEnd(self: *LineEditor) void {
        self.len = self.cursor;
        posix.writeAll(2, "\x1b[K");
    }

    fn killToBeginning(self: *LineEditor) void {
        std.mem.copyForwards(u8, self.buf[0 .. self.len - self.cursor], self.buf[self.cursor .. self.len]);
        self.len -= self.cursor;
        self.cursor = 0;
        self.refreshLine();
    }

    fn killWord(self: *LineEditor) void {
        if (self.cursor == 0) return;
        var end = self.cursor;
        while (end > 0 and self.buf[end - 1] == ' ') : (end -= 1) {}
        while (end > 0 and self.buf[end - 1] != ' ') : (end -= 1) {}
        const removed = self.cursor - end;
        std.mem.copyForwards(u8, self.buf[end .. self.len - removed], self.buf[self.cursor .. self.len]);
        self.len -= removed;
        self.cursor = end;
        self.refreshLine();
    }

    fn clearScreen(self: *LineEditor) void {
        posix.writeAll(2, "\x1b[H\x1b[2J");
        self.refreshLine();
    }

    fn refreshLine(self: *LineEditor) void {
        posix.writeAll(2, "\r\x1b[K");
        posix.writeAll(2, self.prompt);
        posix.writeAll(2, self.buf[0..self.len]);
        if (self.cursor < self.len) {
            var move_buf: [16]u8 = undefined;
            const move = std.fmt.bufPrint(&move_buf, "\x1b[{d}D", .{self.len - self.cursor}) catch return;
            posix.writeAll(2, move);
        }
    }

    fn handleEscape(self: *LineEditor) void {
        var seq: [2]u8 = undefined;
        const n1 = posix.read(0, seq[0..1]) catch return;
        if (n1 == 0) return;
        if (seq[0] != '[' and seq[0] != 'O') return;
        const n2 = posix.read(0, seq[1..2]) catch return;
        if (n2 == 0) return;

        switch (seq[1]) {
            'A' => self.historyPrev(),
            'B' => self.historyNext(),
            'C' => self.moveRight(),
            'D' => self.moveLeft(),
            'H' => self.moveHome(),
            'F' => self.moveEnd(),
            '3' => {
                var extra: [1]u8 = undefined;
                _ = posix.read(0, &extra) catch {};
                if (extra[0] == '~') self.deleteChar();
            },
            '1', '7' => {
                var extra: [1]u8 = undefined;
                _ = posix.read(0, &extra) catch {};
                if (extra[0] == '~') self.moveHome();
            },
            '4', '8' => {
                var extra: [1]u8 = undefined;
                _ = posix.read(0, &extra) catch {};
                if (extra[0] == '~') self.moveEnd();
            },
            else => {},
        }
    }

    fn historyPrev(self: *LineEditor) void {
        if (self.history.count == 0) return;
        if (self.history_idx == 0) return;

        if (self.history_idx == self.history.count) {
            @memcpy(self.saved_line[0..self.len], self.buf[0..self.len]);
            self.saved_len = self.len;
        }

        self.history_idx -= 1;
        if (self.history.get(self.history_idx)) |entry| {
            const copy_len = @min(entry.len, self.buf.len - 1);
            @memcpy(self.buf[0..copy_len], entry[0..copy_len]);
            self.len = copy_len;
            self.cursor = copy_len;
            self.refreshLine();
        }
    }

    fn historyNext(self: *LineEditor) void {
        if (self.history_idx >= self.history.count) return;

        self.history_idx += 1;
        if (self.history_idx == self.history.count) {
            @memcpy(self.buf[0..self.saved_len], self.saved_line[0..self.saved_len]);
            self.len = self.saved_len;
            self.cursor = self.saved_len;
            self.refreshLine();
            return;
        }

        if (self.history.get(self.history_idx)) |entry| {
            const copy_len = @min(entry.len, self.buf.len - 1);
            @memcpy(self.buf[0..copy_len], entry[0..copy_len]);
            self.len = copy_len;
            self.cursor = copy_len;
            self.refreshLine();
        }
    }
};
