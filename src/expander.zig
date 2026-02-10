const std = @import("std");
const ast = @import("ast.zig");
const Lexer = @import("lexer.zig").Lexer;
const Parser = @import("parser.zig").Parser;
const Arithmetic = @import("arithmetic.zig").Arithmetic;
const glob = @import("glob.zig");
const posix = @import("posix.zig");
const types = @import("types.zig");
const Environment = @import("env.zig").Environment;
const signals = @import("signals.zig");

pub const ExpandError = error{
    UnsetVariable,
    BadSubstitution,
    CommandSubstitutionFailed,
    ArithmeticError,
    PatternError,
    OutOfMemory,
};

const JobTable = @import("jobs.zig").JobTable;

const libc = struct {
    extern "c" fn getlogin() ?[*:0]const u8;
    extern "c" fn time(tloc: ?*time_t) time_t;
    extern "c" fn localtime(timer: *const time_t) ?*const Tm;
    extern "c" fn strftime(buf: [*]u8, maxsize: usize, format: [*:0]const u8, tp: *const Tm) usize;
    extern "c" fn ttyname(fd: c_int) ?[*:0]const u8;
    extern "c" fn gethostname(name: [*]u8, len: usize) c_int;

    const time_t = i64;
    const Tm = extern struct {
        sec: c_int,
        min: c_int,
        hour: c_int,
        mday: c_int,
        mon: c_int,
        year: c_int,
        wday: c_int,
        yday: c_int,
        isdst: c_int,
        gmtoff: c_long,
        zone: ?[*:0]const u8,
    };
};

pub const Expander = struct {
    env: *Environment,
    jobs: *JobTable,
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator, env: *Environment, jobs: *JobTable) Expander {
        return .{ .env = env, .jobs = jobs, .alloc = alloc };
    }

    pub fn expandWord(self: *Expander, word: ast.Word) ExpandError![]const u8 {
        var result: std.ArrayListUnmanaged(u8) = .empty;
        for (word.parts) |part| {
            const expanded = try self.expandPart(part);
            try result.appendSlice(self.alloc, expanded);
        }
        return result.toOwnedSlice(self.alloc);
    }

    pub fn expandPattern(self: *Expander, word: ast.Word) ExpandError![]const u8 {
        const info = try self.expandWordWithSplitInfo(word);
        var result: std.ArrayListUnmanaged(u8) = .empty;
        for (info.text, 0..) |ch, idx| {
            if (!info.globbable[idx] and (ch == '[' or ch == '*' or ch == '?' or ch == '\\')) {
                try result.append(self.alloc, '[');
                try result.append(self.alloc, ch);
                try result.append(self.alloc, ']');
            } else {
                try result.append(self.alloc, ch);
            }
        }
        return result.toOwnedSlice(self.alloc);
    }

    pub fn expandFields(self: *Expander, word: ast.Word) ExpandError![]const []const u8 {
        const expanded = try self.expandWord(word);
        if (expanded.len == 0) {
            self.alloc.free(expanded);
            return &.{};
        }
        return self.fieldSplit(expanded);
    }

    pub fn expandWordsToFields(self: *Expander, words: []const ast.Word) ExpandError![]const []const u8 {
        var raw_fields: std.ArrayListUnmanaged([]const u8) = .empty;
        var word_boundaries: std.ArrayListUnmanaged(usize) = .empty;
        const expanded_words = braceExpandWords(self.alloc, words) catch words;
        for (expanded_words) |word| {
            try word_boundaries.append(self.alloc, raw_fields.items.len);
            if (findQuotedAt(word)) |at_info| {
                try self.expandQuotedAtWord(word, at_info, &raw_fields);
                continue;
            }
            if (findUnquotedAtOrStar(word)) |unquoted_info| {
                try self.expandUnquotedAtWord(word, unquoted_info, &raw_fields);
                continue;
            }
            const ew = try self.expandWordWithSplitInfo(word);
            if (ew.text.len == 0) {
                if (hasQuotedParts(word)) {
                    try raw_fields.append(self.alloc, ew.text);
                }
                continue;
            }
            const split_result = try self.fieldSplitWithQuoting(ew.text, ew.splittable, ew.globbable);
            if (!self.env.options.noglob) {
                for (split_result.fields, split_result.globbable, split_result.field_char_globbable) |field, can_glob, char_flags| {
                    if (!can_glob) {
                        try raw_fields.append(self.alloc, field);
                        continue;
                    }
                    const pattern = try self.buildGlobPattern(field, char_flags);
                    const globbed = glob.expand(self.alloc, pattern) catch {
                        if (!self.env.shopt.nullglob) try raw_fields.append(self.alloc, field);
                        continue;
                    };
                    if (globbed.len == 1 and std.mem.eql(u8, globbed[0], pattern)) {
                        if (!self.env.shopt.nullglob) try raw_fields.append(self.alloc, field);
                    } else {
                        try raw_fields.appendSlice(self.alloc, globbed);
                    }
                }
            } else {
                try raw_fields.appendSlice(self.alloc, split_result.fields);
            }
        }
        var fields: std.ArrayListUnmanaged([]const u8) = .empty;
        var prev_sentinel = false;
        var boundary_idx: usize = 0;
        for (raw_fields.items, 0..) |field, fi| {
            while (boundary_idx < word_boundaries.items.len and word_boundaries.items[boundary_idx] <= fi) {
                if (word_boundaries.items[boundary_idx] == fi) prev_sentinel = false;
                boundary_idx += 1;
            }
            if (isSentinelOnly(field)) {
                if (!prev_sentinel) {
                    try fields.append(self.alloc, try self.alloc.dupe(u8, ""));
                }
                prev_sentinel = true;
            } else {
                prev_sentinel = false;
                try fields.append(self.alloc, try stripSentinels(self.alloc, field));
            }
        }
        return fields.toOwnedSlice(self.alloc);
    }

    fn isSentinelOnly(field: []const u8) bool {
        if (field.len == 0) return false;
        for (field) |b| {
            if (b != 0x00) return false;
        }
        return true;
    }

    fn stripSentinels(alloc: std.mem.Allocator, field: []const u8) ExpandError![]const u8 {
        if (std.mem.indexOfScalar(u8, field, 0x00) == null) return field;
        var result: std.ArrayListUnmanaged(u8) = .empty;
        for (field) |b| {
            if (b != 0x00) try result.append(alloc, b);
        }
        return result.toOwnedSlice(alloc);
    }

    fn expandPart(self: *Expander, part: ast.WordPart) ExpandError![]const u8 {
        switch (part) {
            .literal => |lit| return try self.alloc.dupe(u8, lit),
            .single_quoted => |sq| return try self.alloc.dupe(u8, sq),
            .ansi_c_quoted => |aq| return try self.alloc.dupe(u8, aq),
            .double_quoted => |parts| {
                var result: std.ArrayListUnmanaged(u8) = .empty;
                for (parts) |inner| {
                    const expanded = try self.expandPart(inner);
                    try result.appendSlice(self.alloc, expanded);
                    self.alloc.free(expanded);
                }
                return result.toOwnedSlice(self.alloc);
            },
            .parameter => |param| return try self.expandParameter(param),
            .command_sub => |cs| return try self.expandCommandSub(cs),
            .arith_sub => |expr| return try self.expandArithmetic(expr),
            .backtick_sub => |body| {
                const processed = try self.processBacktickBody(body);
                return try self.expandCommandSub(.{ .body = processed });
            },
            .tilde => |tilde_text| return try self.expandTilde(tilde_text),
        }
    }

    fn getParamValue(self: *Expander, name: []const u8) ?[]const u8 {
        if (name.len > 0 and name[0] >= '0' and name[0] <= '9') {
            const n = std.fmt.parseInt(u32, name, 10) catch return null;
            if (n == 0) return self.env.shell_name;
            return self.env.getPositional(n);
        }
        if (self.env.get(name)) |val| return val;
        if (std.mem.eql(u8, name, "@") or std.mem.eql(u8, name, "*")) {
            if (self.env.positional_params.len == 0) return null;
            return "";
        }
        if (std.mem.eql(u8, name, "#")) {
            const count = std.fmt.allocPrint(self.alloc, "{d}", .{self.env.positional_params.len}) catch return null;
            return count;
        }
        if (std.mem.eql(u8, name, "?")) {
            const val = std.fmt.allocPrint(self.alloc, "{d}", .{self.env.last_exit_status}) catch return null;
            return val;
        }
        if (std.mem.eql(u8, name, "$")) {
            const val = std.fmt.allocPrint(self.alloc, "{d}", .{self.env.shell_pid}) catch return null;
            return val;
        }
        return null;
    }

    fn expandParameter(self: *Expander, param: ast.ParameterExp) ExpandError![]const u8 {
        switch (param) {
            .simple => |name| {
                if (name.len > 0 and name[0] >= '0' and name[0] <= '9') {
                    const n = std.fmt.parseInt(u32, name, 10) catch 0;
                    if (n == 0) return try self.alloc.dupe(u8, self.env.shell_name);
                    if (self.env.getPositional(n)) |val| return try self.alloc.dupe(u8, val);
                    if (self.env.options.nounset) {
                        const msg = std.fmt.allocPrint(self.alloc, "zigsh: {s}: parameter not set\n", .{name}) catch return error.OutOfMemory;
                        _ = std.c.write(2, msg.ptr, msg.len);
                        self.alloc.free(msg);
                        return error.UnsetVariable;
                    }
                    return try self.alloc.dupe(u8, "");
                }
                if (self.env.get(name)) |val| return try self.alloc.dupe(u8, val);
                if (self.expandDynamic(name)) |val| return val;
                if (self.env.options.nounset) {
                    const msg = std.fmt.allocPrint(self.alloc, "zigsh: {s}: parameter not set\n", .{name}) catch return error.OutOfMemory;
                    _ = std.c.write(2, msg.ptr, msg.len);
                    self.alloc.free(msg);
                    return error.UnsetVariable;
                }
                return try self.alloc.dupe(u8, "");
            },
            .special => |ch| return try self.expandSpecial(ch),
            .positional => |n| {
                if (n == 0) {
                    return try self.alloc.dupe(u8, self.env.shell_name);
                }
                if (self.env.getPositional(n)) |val| return try self.alloc.dupe(u8, val);
                if (self.env.options.nounset) {
                    const msg = std.fmt.allocPrint(self.alloc, "zigsh: {d}: parameter not set\n", .{n}) catch return error.OutOfMemory;
                    _ = std.c.write(2, msg.ptr, msg.len);
                    self.alloc.free(msg);
                    return error.UnsetVariable;
                }
                return try self.alloc.dupe(u8, "");
            },
            .length => |name| {
                if (std.mem.eql(u8, name, "@") or std.mem.eql(u8, name, "*")) {
                    return try std.fmt.allocPrint(self.alloc, "{d}", .{self.env.positional_params.len});
                }
                if (std.mem.eql(u8, name, "#")) {
                    const count_str = try std.fmt.allocPrint(self.alloc, "{d}", .{self.env.positional_params.len});
                    defer self.alloc.free(count_str);
                    const cp_len = countUtf8Codepoints(count_str);
                    return try std.fmt.allocPrint(self.alloc, "{d}", .{cp_len});
                }
                if (std.mem.eql(u8, name, "?")) {
                    const val_str = try std.fmt.allocPrint(self.alloc, "{d}", .{self.env.last_exit_status});
                    defer self.alloc.free(val_str);
                    const cp_len = countUtf8Codepoints(val_str);
                    return try std.fmt.allocPrint(self.alloc, "{d}", .{cp_len});
                }
                if (self.getParamValue(name)) |val| {
                    const cp_len = countUtf8Codepoints(val);
                    return try std.fmt.allocPrint(self.alloc, "{d}", .{cp_len});
                }
                if (self.env.options.nounset) {
                    const msg = std.fmt.allocPrint(self.alloc, "zigsh: {s}: unbound variable\n", .{name}) catch return error.OutOfMemory;
                    _ = std.c.write(2, msg.ptr, msg.len);
                    self.alloc.free(msg);
                    return error.UnsetVariable;
                }
                return try self.alloc.dupe(u8, "0");
            },
            .default => |op| {
                const val = self.getParamValue(op.name);
                if (val == null or (op.colon and val.?.len == 0)) {
                    return try self.expandWord(op.word);
                }
                return try self.alloc.dupe(u8, val.?);
            },
            .assign => |op| {
                const val = self.getParamValue(op.name);
                if (val == null or (op.colon and val.?.len == 0)) {
                    const new_val = try self.expandWord(op.word);
                    self.env.set(op.name, new_val, false) catch {};
                    return new_val;
                }
                return try self.alloc.dupe(u8, val.?);
            },
            .error_msg => |op| {
                const val = self.getParamValue(op.name);
                if (val == null or (op.colon and val.?.len == 0)) {
                    const msg = try self.expandWord(op.word);
                    if (msg.len > 0) {
                        const err_msg = std.fmt.allocPrint(self.alloc, "zigsh: {s}: {s}\n", .{ op.name, msg }) catch {
                            self.alloc.free(msg);
                            return error.OutOfMemory;
                        };
                        _ = std.c.write(2, err_msg.ptr, err_msg.len);
                        self.alloc.free(err_msg);
                    } else {
                        const err_msg = std.fmt.allocPrint(self.alloc, "zigsh: {s}: parameter null or not set\n", .{op.name}) catch {
                            return error.OutOfMemory;
                        };
                        _ = std.c.write(2, err_msg.ptr, err_msg.len);
                        self.alloc.free(err_msg);
                    }
                    self.alloc.free(msg);
                    if (!self.env.options.interactive) {
                        self.env.should_exit = true;
                        self.env.exit_value = 2;
                    }
                    return error.UnsetVariable;
                }
                return try self.alloc.dupe(u8, val.?);
            },
            .alternative => |op| {
                const val = self.getParamValue(op.name);
                if (val != null and (!op.colon or val.?.len > 0)) {
                    return try self.expandWord(op.word);
                }
                return try self.alloc.dupe(u8, "");
            },
            .prefix_strip => |op| return try self.stripPattern(op.name, op.pattern, .prefix_short),
            .prefix_strip_long => |op| return try self.stripPattern(op.name, op.pattern, .prefix_long),
            .suffix_strip => |op| return try self.stripPattern(op.name, op.pattern, .suffix_short),
            .suffix_strip_long => |op| return try self.stripPattern(op.name, op.pattern, .suffix_long),
            .pattern_sub => |op| return try self.patternSub(op),
            .substring => |op| return try self.expandSubstring(op),
            .case_conv => |op| return try self.expandCaseConv(op),
            .indirect => |name| {
                const var_name = self.env.get(name) orelse "";
                if (var_name.len == 0) return try self.alloc.dupe(u8, "");
                if (self.env.get(var_name)) |val| return try self.alloc.dupe(u8, val);
                if (self.expandDynamic(var_name)) |val| return val;
                return try self.alloc.dupe(u8, "");
            },
            .transform => |op| return try self.expandTransform(op),
        }
    }

    const StripMode = enum { prefix_short, prefix_long, suffix_short, suffix_long };

    fn stripPattern(self: *Expander, name: []const u8, pattern: ast.Word, mode: StripMode) ExpandError![]const u8 {
        const val = self.getParamValue(name) orelse return try self.alloc.dupe(u8, "");
        const pat = try self.expandPattern(pattern);
        defer self.alloc.free(pat);

        switch (mode) {
            .prefix_short => {
                var i: usize = 0;
                while (i <= val.len) {
                    if (glob.fnmatch(pat, val[0..i])) {
                        return try self.alloc.dupe(u8, val[i..]);
                    }
                    if (i >= val.len) break;
                    i += utf8SeqLen(val[i]);
                }
            },
            .prefix_long => {
                var i: usize = val.len;
                while (true) {
                    if (glob.fnmatch(pat, val[0..i])) {
                        return try self.alloc.dupe(u8, val[i..]);
                    }
                    if (i == 0) break;
                    i = prevUtf8Boundary(val, i);
                }
            },
            .suffix_short => {
                var i: usize = val.len;
                while (true) {
                    if (glob.fnmatch(pat, val[i..])) {
                        return try self.alloc.dupe(u8, val[0..i]);
                    }
                    if (i == 0) break;
                    i = prevUtf8Boundary(val, i);
                }
            },
            .suffix_long => {
                var i: usize = 0;
                while (i <= val.len) {
                    if (glob.fnmatch(pat, val[i..])) {
                        return try self.alloc.dupe(u8, val[0..i]);
                    }
                    if (i >= val.len) break;
                    i += utf8SeqLen(val[i]);
                }
            },
        }
        return try self.alloc.dupe(u8, val);
    }

    fn utf8SeqLen(byte: u8) usize {
        if (byte < 0x80) return 1;
        if (byte & 0xE0 == 0xC0) return 2;
        if (byte & 0xF0 == 0xE0) return 3;
        if (byte & 0xF8 == 0xF0) return 4;
        return 1;
    }

    fn prevUtf8Boundary(val: []const u8, pos: usize) usize {
        var p = pos;
        if (p > 0) p -= 1;
        while (p > 0 and val[p] & 0xC0 == 0x80) : (p -= 1) {}
        return p;
    }

    fn patternSub(self: *Expander, op: ast.PatternSubOp) ExpandError![]const u8 {
        const val = self.getParamValue(op.name) orelse "";
        if (val.len == 0) return try self.alloc.dupe(u8, "");
        const pat = try self.expandPattern(op.pattern);
        defer self.alloc.free(pat);
        if (pat.len == 0) return try self.alloc.dupe(u8, val);
        const rep = try self.expandWord(op.replacement);
        defer self.alloc.free(rep);

        switch (op.mode) {
            .prefix => {
                var end: usize = val.len;
                while (end > 0) : (end -= 1) {
                    if (glob.fnmatch(pat, val[0..end])) {
                        var result: std.ArrayListUnmanaged(u8) = .empty;
                        try result.appendSlice(self.alloc, rep);
                        try result.appendSlice(self.alloc, val[end..]);
                        return result.toOwnedSlice(self.alloc);
                    }
                }
                if (glob.fnmatch(pat, val[0..0])) {
                    var result: std.ArrayListUnmanaged(u8) = .empty;
                    try result.appendSlice(self.alloc, rep);
                    try result.appendSlice(self.alloc, val);
                    return result.toOwnedSlice(self.alloc);
                }
                return try self.alloc.dupe(u8, val);
            },
            .suffix => {
                var start: usize = 0;
                while (start < val.len) : (start += 1) {
                    if (glob.fnmatch(pat, val[start..])) {
                        var result: std.ArrayListUnmanaged(u8) = .empty;
                        try result.appendSlice(self.alloc, val[0..start]);
                        try result.appendSlice(self.alloc, rep);
                        return result.toOwnedSlice(self.alloc);
                    }
                }
                if (glob.fnmatch(pat, "")) {
                    var result: std.ArrayListUnmanaged(u8) = .empty;
                    try result.appendSlice(self.alloc, val);
                    try result.appendSlice(self.alloc, rep);
                    return result.toOwnedSlice(self.alloc);
                }
                return try self.alloc.dupe(u8, val);
            },
            .first, .all => {
                var result: std.ArrayListUnmanaged(u8) = .empty;
                var pos: usize = 0;
                while (pos <= val.len) {
                    var matched = false;
                    var end: usize = val.len;
                    while (end > pos) : (end -= 1) {
                        if (glob.fnmatch(pat, val[pos..end])) {
                            try result.appendSlice(self.alloc, rep);
                            pos = end;
                            matched = true;
                            break;
                        }
                    }
                    if (!matched) {
                        if (glob.fnmatch(pat, val[pos..pos])) {
                            try result.appendSlice(self.alloc, rep);
                            if (pos < val.len) {
                                try result.append(self.alloc, val[pos]);
                                pos += 1;
                            } else {
                                break;
                            }
                            matched = true;
                        }
                    }
                    if (!matched) {
                        if (pos < val.len) {
                            try result.append(self.alloc, val[pos]);
                            pos += 1;
                        } else {
                            break;
                        }
                    } else if (op.mode == .first) {
                        try result.appendSlice(self.alloc, val[pos..]);
                        return result.toOwnedSlice(self.alloc);
                    }
                }
                return result.toOwnedSlice(self.alloc);
            },
        }
    }

    fn expandSubstring(self: *Expander, op: ast.SubstringOp) ExpandError![]const u8 {
        if (std.mem.eql(u8, op.name, "@") or std.mem.eql(u8, op.name, "*")) {
            return try self.substringPositionalParams(op);
        }

        const val = self.getParamValue(op.name) orelse blk: {
            if (self.env.options.nounset) {
                const msg = std.fmt.allocPrint(self.alloc, "zigsh: {s}: unbound variable\n", .{op.name}) catch return error.OutOfMemory;
                posix.writeAll(2, msg);
                self.alloc.free(msg);
                return error.UnsetVariable;
            }
            break :blk "";
        };
        const cp_len = countUtf8Codepoints(val);

        const env_ptr = self.env;
        const lookup = struct {
            var env: *Environment = undefined;
            fn f(name: []const u8) ?[]const u8 {
                return env.get(name);
            }
        };
        lookup.env = env_ptr;

        var expanded_offset: std.ArrayListUnmanaged(u8) = .empty;
        {
            var oi: usize = 0;
            while (oi < op.offset.len) {
                if (op.offset[oi] == '$' and oi + 1 < op.offset.len and types.isNameStart(op.offset[oi + 1])) {
                    oi += 1;
                    const start = oi;
                    while (oi < op.offset.len and types.isNameCont(op.offset[oi])) : (oi += 1) {}
                    const name = op.offset[start..oi];
                    const v = self.env.get(name) orelse "0";
                    try expanded_offset.appendSlice(self.alloc, v);
                } else {
                    try expanded_offset.append(self.alloc, op.offset[oi]);
                    oi += 1;
                }
            }
        }
        const offset_str = try expanded_offset.toOwnedSlice(self.alloc);
        defer self.alloc.free(offset_str);

        const raw_offset = Arithmetic.evaluate(offset_str, &lookup.f) catch return error.ArithmeticError;

        var offset: i64 = raw_offset;
        if (offset < 0) {
            offset = @as(i64, @intCast(cp_len)) + offset;
            if (offset < 0) offset = 0;
        }

        const start_cp: usize = if (offset >= 0) @min(@as(usize, @intCast(offset)), cp_len) else 0;

        var end_cp: usize = cp_len;
        if (op.length) |len_str| {
            var expanded_len: std.ArrayListUnmanaged(u8) = .empty;
            {
                var li: usize = 0;
                while (li < len_str.len) {
                    if (len_str[li] == '$' and li + 1 < len_str.len and types.isNameStart(len_str[li + 1])) {
                        li += 1;
                        const start = li;
                        while (li < len_str.len and types.isNameCont(len_str[li])) : (li += 1) {}
                        const name = len_str[start..li];
                        const v = self.env.get(name) orelse "0";
                        try expanded_len.appendSlice(self.alloc, v);
                    } else {
                        try expanded_len.append(self.alloc, len_str[li]);
                        li += 1;
                    }
                }
            }
            const len_eval_str = try expanded_len.toOwnedSlice(self.alloc);
            defer self.alloc.free(len_eval_str);

            const raw_len = Arithmetic.evaluate(len_eval_str, &lookup.f) catch return error.ArithmeticError;
            if (raw_len < 0) {
                const end_from_end = @as(i64, @intCast(cp_len)) + raw_len;
                if (end_from_end < offset) return error.BadSubstitution;
                end_cp = if (end_from_end >= 0) @intCast(end_from_end) else 0;
            } else {
                end_cp = @min(start_cp + @as(usize, @intCast(raw_len)), cp_len);
            }
        }

        if (start_cp >= cp_len) return try self.alloc.dupe(u8, "");
        if (end_cp <= start_cp) return try self.alloc.dupe(u8, "");

        const start_byte = cpToByteOffset(val, start_cp);
        const end_byte = cpToByteOffset(val, end_cp);
        return try self.alloc.dupe(u8, val[start_byte..end_byte]);
    }

    fn substringPositionalParams(self: *Expander, op: ast.SubstringOp) ExpandError![]const u8 {
        const env_ptr = self.env;
        const lookup = struct {
            var env: *Environment = undefined;
            fn f(name: []const u8) ?[]const u8 {
                return env.get(name);
            }
        };
        lookup.env = env_ptr;

        const raw_offset = Arithmetic.evaluate(op.offset, &lookup.f) catch return error.ArithmeticError;
        const params = self.env.positional_params;
        const total: i64 = @intCast(params.len);

        var start: i64 = raw_offset;
        var include_zero = false;
        if (start <= 0) {
            include_zero = true;
            if (start < 0) {
                start = total + 1 + start;
                if (start < 0) start = 0;
                include_zero = false;
            }
        }

        var end: i64 = total + 1;
        if (op.length) |len_str| {
            const raw_len = Arithmetic.evaluate(len_str, &lookup.f) catch return error.ArithmeticError;
            if (raw_len < 0) {
                end = total + 1 + raw_len;
            } else {
                end = start + raw_len;
            }
        }

        var result: std.ArrayListUnmanaged(u8) = .empty;
        var first = true;

        if (include_zero and start == 0) {
            if (end > 0) {
                try result.appendSlice(self.alloc, self.env.shell_name);
                first = false;
                start = 1;
            }
        }

        var idx: i64 = if (start < 1) 1 else start;
        while (idx < end and idx <= total) : (idx += 1) {
            if (!first) try result.append(self.alloc, ' ');
            try result.appendSlice(self.alloc, params[@intCast(idx - 1)]);
            first = false;
        }

        return result.toOwnedSlice(self.alloc);
    }

    fn cpToByteOffset(s: []const u8, cp_target: usize) usize {
        var cp_count: usize = 0;
        var byte_idx: usize = 0;
        while (byte_idx < s.len and cp_count < cp_target) {
            const b = s[byte_idx];
            if (b < 0x80) {
                byte_idx += 1;
            } else if (b & 0xE0 == 0xC0) {
                byte_idx += if (byte_idx + 2 <= s.len) 2 else 1;
            } else if (b & 0xF0 == 0xE0) {
                byte_idx += if (byte_idx + 3 <= s.len) 3 else 1;
            } else if (b & 0xF8 == 0xF0) {
                byte_idx += if (byte_idx + 4 <= s.len) 4 else 1;
            } else {
                byte_idx += 1;
            }
            cp_count += 1;
        }
        return byte_idx;
    }

    fn expandCaseConv(self: *Expander, op: ast.CaseConvOp) ExpandError![]const u8 {
        const val = self.getParamValue(op.name) orelse "";
        if (val.len == 0) return try self.alloc.dupe(u8, val);
        var result: std.ArrayListUnmanaged(u8) = .empty;
        var i: usize = 0;
        var first = true;
        while (i < val.len) {
            const byte_len = std.unicode.utf8ByteSequenceLength(val[i]) catch {
                try result.append(self.alloc, val[i]);
                i += 1;
                first = false;
                continue;
            };
            if (i + byte_len > val.len) {
                try result.append(self.alloc, val[i]);
                i += 1;
                first = false;
                continue;
            }
            const should_convert = switch (op.mode) {
                .upper_first, .lower_first => first,
                .upper_all, .lower_all => true,
            };
            if (should_convert and byte_len == 1) {
                switch (op.mode) {
                    .upper_first, .upper_all => try result.append(self.alloc, std.ascii.toUpper(val[i])),
                    .lower_first, .lower_all => try result.append(self.alloc, std.ascii.toLower(val[i])),
                }
            } else {
                try result.appendSlice(self.alloc, val[i .. i + byte_len]);
            }
            i += byte_len;
            first = false;
        }
        return result.toOwnedSlice(self.alloc);
    }

    fn expandTransform(self: *Expander, op: ast.TransformOp) ExpandError![]const u8 {
        if (std.mem.eql(u8, op.name, "@") or std.mem.eql(u8, op.name, "*")) {
            return self.expandTransformSpecial(op);
        }
        const val = self.getParamValue(op.name) orelse "";
        switch (op.operator) {
            'P' => {
                return self.expandPromptWithShellExpansion(val);
            },
            'Q' => {
                var result: std.ArrayListUnmanaged(u8) = .empty;
                try result.append(self.alloc, '\'');
                for (val) |ch| {
                    if (ch == '\'') {
                        try result.appendSlice(self.alloc, "'\\''");
                    } else {
                        try result.append(self.alloc, ch);
                    }
                }
                try result.append(self.alloc, '\'');
                return result.toOwnedSlice(self.alloc);
            },
            'E' => {
                var result: std.ArrayListUnmanaged(u8) = .empty;
                var i: usize = 0;
                while (i < val.len) {
                    if (val[i] == '\\' and i + 1 < val.len) {
                        i += 1;
                        switch (val[i]) {
                            'n' => try result.append(self.alloc, '\n'),
                            't' => try result.append(self.alloc, '\t'),
                            'r' => try result.append(self.alloc, '\r'),
                            'a' => try result.append(self.alloc, 0x07),
                            'b' => try result.append(self.alloc, 0x08),
                            'e', 'E' => try result.append(self.alloc, 0x1b),
                            '\\' => try result.append(self.alloc, '\\'),
                            else => {
                                try result.append(self.alloc, '\\');
                                try result.append(self.alloc, val[i]);
                            },
                        }
                        i += 1;
                    } else {
                        try result.append(self.alloc, val[i]);
                        i += 1;
                    }
                }
                return result.toOwnedSlice(self.alloc);
            },
            else => return try self.alloc.dupe(u8, val),
        }
    }

    fn expandTransformSpecial(self: *Expander, op: ast.TransformOp) ExpandError![]const u8 {
        const params = self.env.positional_params;
        if (params.len == 0) return try self.alloc.dupe(u8, "");
        const sep: u8 = if (std.mem.eql(u8, op.name, "*")) blk: {
            const ifs = self.env.get("IFS") orelse " \t\n";
            break :blk if (ifs.len > 0) ifs[0] else 0;
        } else ' ';
        var result: std.ArrayListUnmanaged(u8) = .empty;
        for (params, 0..) |param, idx| {
            if (idx > 0 and sep != 0) try result.append(self.alloc, sep);
            switch (op.operator) {
                'P' => {
                    const expanded = try self.expandPromptWithShellExpansion(param);
                    try result.appendSlice(self.alloc, expanded);
                },
                'Q' => {
                    try result.append(self.alloc, '\'');
                    for (param) |ch| {
                        if (ch == '\'') {
                            try result.appendSlice(self.alloc, "'\\''");
                        } else {
                            try result.append(self.alloc, ch);
                        }
                    }
                    try result.append(self.alloc, '\'');
                },
                else => try result.appendSlice(self.alloc, param),
            }
        }
        return result.toOwnedSlice(self.alloc);
    }

    fn expandPromptWithShellExpansion(self: *Expander, input: []const u8) ExpandError![]const u8 {
        const marked = try expandPromptStringMarked(self.alloc, input, self.env, self.jobs);
        var result: std.ArrayListUnmanaged(u8) = .empty;
        var i: usize = 0;
        while (i < marked.len) {
            if (marked[i] == 0x01) {
                i += 1;
                while (i < marked.len and marked[i] != 0x01) {
                    try result.append(self.alloc, marked[i]);
                    i += 1;
                }
                if (i < marked.len) i += 1;
            } else if (marked[i] == '\\' and i + 1 < marked.len) {
                const next = marked[i + 1];
                if (next == '$' or next == '`' or next == '"' or next == '\\' or next == '\n') {
                    try result.append(self.alloc, next);
                    i += 2;
                } else {
                    try result.append(self.alloc, marked[i]);
                    i += 1;
                }
            } else if (marked[i] == '$') {
                i += 1;
                if (i < marked.len and marked[i] == '{') {
                    i += 1;
                    const name_start = i;
                    while (i < marked.len and marked[i] != '}') : (i += 1) {}
                    const name = marked[name_start..i];
                    if (i < marked.len) i += 1;
                    if (self.env.get(name)) |val| {
                        try result.appendSlice(self.alloc, val);
                    }
                } else if (i < marked.len and marked[i] == '(') {
                    i += 1;
                    const cmd_start = i;
                    var depth: u32 = 1;
                    while (i < marked.len and depth > 0) {
                        if (marked[i] == '(') depth += 1;
                        if (marked[i] == ')') depth -= 1;
                        if (depth > 0) i += 1;
                    }
                    const cmd_text = marked[cmd_start..i];
                    if (i < marked.len) i += 1;
                    const cmd_result = self.expandCommandSub(.{ .body = cmd_text }) catch "";
                    try result.appendSlice(self.alloc, cmd_result);
                } else {
                    const name_start = i;
                    while (i < marked.len and (std.ascii.isAlphanumeric(marked[i]) or marked[i] == '_')) : (i += 1) {}
                    const name = marked[name_start..i];
                    if (name.len > 0) {
                        if (self.env.get(name)) |val| {
                            try result.appendSlice(self.alloc, val);
                        }
                    } else {
                        try result.append(self.alloc, '$');
                    }
                }
            } else {
                try result.append(self.alloc, marked[i]);
                i += 1;
            }
        }
        return result.toOwnedSlice(self.alloc);
    }

    fn expandPromptStringMarked(alloc: std.mem.Allocator, input: []const u8, env: *Environment, jobs: *JobTable) ExpandError![]const u8 {
        return expandPromptStringInner(alloc, input, env, jobs, true);
    }

    pub fn expandPromptString(alloc: std.mem.Allocator, input: []const u8, env: *Environment, jobs: *JobTable) ExpandError![]const u8 {
        return expandPromptStringInner(alloc, input, env, jobs, false);
    }

    fn appendLiteral(alloc: std.mem.Allocator, result: *std.ArrayListUnmanaged(u8), ch: u8, mark: bool) !void {
        if (mark) try result.append(alloc, 0x01);
        try result.append(alloc, ch);
        if (mark) try result.append(alloc, 0x01);
    }

    fn appendLiteralSlice(alloc: std.mem.Allocator, result: *std.ArrayListUnmanaged(u8), s: []const u8, mark: bool) !void {
        if (mark) try result.append(alloc, 0x01);
        try result.appendSlice(alloc, s);
        if (mark) try result.append(alloc, 0x01);
    }

    fn expandPromptStringInner(alloc: std.mem.Allocator, input: []const u8, env: *Environment, jobs: *JobTable, mark: bool) ExpandError![]const u8 {
        var result: std.ArrayListUnmanaged(u8) = .empty;
        var i: usize = 0;
        while (i < input.len) {
            if (input[i] == '\\') {
                i += 1;
                if (i >= input.len) {
                    try result.append(alloc,'\\');
                    break;
                }
                switch (input[i]) {
                    'a' => try appendLiteral(alloc, &result, 0x07, mark),
                    'e' => try appendLiteral(alloc, &result, 0x1b, mark),
                    'n' => try appendLiteral(alloc, &result, '\n', mark),
                    'r' => try appendLiteral(alloc, &result, '\r', mark),
                    '\\' => try result.append(alloc, '\\'),
                    '$' => {
                        if (posix.geteuid() == 0)
                            try appendLiteral(alloc, &result, '#', mark)
                        else
                            try appendLiteral(alloc, &result, '$', mark);
                    },
                    '[', ']' => {},
                    'h' => {
                        var hostname_buf: [256]u8 = undefined;
                        const hostname = getHostname(&hostname_buf);
                        if (std.mem.indexOfScalar(u8, hostname, '.')) |dot| {
                            try appendLiteralSlice(alloc, &result, hostname[0..dot], mark);
                        } else {
                            try appendLiteralSlice(alloc, &result, hostname, mark);
                        }
                    },
                    'H' => {
                        var hostname_buf: [256]u8 = undefined;
                        const hostname = getHostname(&hostname_buf);
                        try appendLiteralSlice(alloc, &result, hostname, mark);
                    },
                    'u' => {
                        const user = env.get("USER") orelse blk: {
                            const login = libc.getlogin();
                            break :blk if (login) |l| std.mem.span(l) else "?";
                        };
                        try appendLiteralSlice(alloc, &result, user, mark);
                    },
                    'w' => {
                        const pwd = env.get("PWD") orelse "?";
                        const home = env.get("HOME");
                        if (home) |h| {
                            if (std.mem.startsWith(u8, pwd, h)) {
                                try appendLiteral(alloc, &result, '~', mark);
                                try appendLiteralSlice(alloc, &result, pwd[h.len..], mark);
                            } else {
                                try appendLiteralSlice(alloc, &result, pwd, mark);
                            }
                        } else {
                            try appendLiteralSlice(alloc, &result, pwd, mark);
                        }
                    },
                    'W' => {
                        const pwd = env.get("PWD") orelse "?";
                        const home = env.get("HOME");
                        if (home) |h| {
                            if (std.mem.eql(u8, pwd, h)) {
                                try appendLiteral(alloc, &result, '~', mark);
                            } else {
                                const base = std.fs.path.basename(pwd);
                                try appendLiteralSlice(alloc, &result, base, mark);
                            }
                        } else {
                            const base = std.fs.path.basename(pwd);
                            try appendLiteralSlice(alloc, &result, base, mark);
                        }
                    },
                    't' => {
                        const buf = strftimeAlloc(alloc, "%H:%M:%S") catch try alloc.dupe(u8, "??:??:??");
                        try appendLiteralSlice(alloc, &result, buf, mark);
                    },
                    'T' => {
                        const buf = strftimeAlloc(alloc, "%I:%M:%S") catch try alloc.dupe(u8, "??:??:??");
                        try appendLiteralSlice(alloc, &result, buf, mark);
                    },
                    '@' => {
                        const buf = strftimeAlloc(alloc, "%I:%M %p") catch try alloc.dupe(u8, "??:?? ??");
                        try appendLiteralSlice(alloc, &result, buf, mark);
                    },
                    'A' => {
                        const buf = strftimeAlloc(alloc, "%H:%M") catch try alloc.dupe(u8, "??:??");
                        try appendLiteralSlice(alloc, &result, buf, mark);
                    },
                    'd' => {
                        const buf = strftimeAlloc(alloc, "%a %b %d") catch try alloc.dupe(u8, "??? ??? ??");
                        try appendLiteralSlice(alloc, &result, buf, mark);
                    },
                    'D' => {
                        i += 1;
                        if (i < input.len and input[i] == '{') {
                            i += 1;
                            const fmt_start = i;
                            while (i < input.len and input[i] != '}') : (i += 1) {}
                            const fmt = input[fmt_start..i];
                            if (i < input.len) i += 1;
                            const fmt_str = if (fmt.len == 0) "%X" else fmt;
                            var fmt_buf: [128]u8 = undefined;
                            if (fmt_str.len < fmt_buf.len) {
                                @memcpy(fmt_buf[0..fmt_str.len], fmt_str);
                                fmt_buf[fmt_str.len] = 0;
                                const fmt_z: [*:0]const u8 = fmt_buf[0..fmt_str.len :0];
                                const buf = strftimeAlloc(alloc, fmt_z) catch try alloc.dupe(u8, "");
                                try appendLiteralSlice(alloc, &result, buf, mark);
                            }
                        }
                        continue;
                    },
                    's' => try appendLiteralSlice(alloc, &result, "zigsh", mark),
                    'v' => try appendLiteralSlice(alloc, &result, "0.1", mark),
                    'V' => try appendLiteralSlice(alloc, &result, "0.1.0", mark),
                    'j' => {
                        const buf = std.fmt.allocPrint(alloc, "{d}", .{jobs.count}) catch return error.OutOfMemory;
                        try appendLiteralSlice(alloc, &result, buf, mark);
                    },
                    'l' => {
                        const tty_ptr = libc.ttyname(0);
                        if (tty_ptr) |ptr| {
                            const tty = std.mem.span(ptr);
                            const base = std.fs.path.basename(tty);
                            try appendLiteralSlice(alloc, &result, base, mark);
                        } else {
                            try appendLiteralSlice(alloc, &result, "tty", mark);
                        }
                    },
                    '!' => {
                        if (env.history) |h| {
                            const num = h.count + 1;
                            const buf = std.fmt.allocPrint(alloc, "{d}", .{num}) catch return error.OutOfMemory;
                            try appendLiteralSlice(alloc, &result, buf, mark);
                        } else {
                            try appendLiteral(alloc, &result, '0', mark);
                        }
                    },
                    '#' => {
                        const num = env.command_number;
                        const buf = std.fmt.allocPrint(alloc, "{d}", .{num}) catch return error.OutOfMemory;
                        try appendLiteralSlice(alloc, &result, buf, mark);
                    },
                    '0'...'7' => {
                        var octal: u32 = input[i] - '0';
                        var count: usize = 1;
                        while (count < 3 and i + 1 < input.len and input[i + 1] >= '0' and input[i + 1] <= '7') {
                            i += 1;
                            octal = octal * 8 + (input[i] - '0');
                            count += 1;
                        }
                        try appendLiteral(alloc, &result, @intCast(octal & 0xFF), mark);
                    },
                    else => {
                        try appendLiteral(alloc, &result, '\\', mark);
                        try appendLiteral(alloc, &result, input[i], mark);
                    },
                }
                i += 1;
            } else {
                try result.append(alloc, input[i]);
                i += 1;
            }
        }
        return result.toOwnedSlice(alloc);
    }

    fn getHostname(buf: *[256]u8) []const u8 {
        const rc = libc.gethostname(buf, buf.len);
        if (rc != 0) return "localhost";
        return std.mem.sliceTo(buf, 0);
    }

    fn strftimeAlloc(alloc: std.mem.Allocator, fmt: [*:0]const u8) ![]const u8 {
        var now: libc.time_t = undefined;
        _ = libc.time(&now);
        const tm = libc.localtime(&now);
        if (tm == null) return error.OutOfMemory;
        var buf: [128]u8 = undefined;
        const len = libc.strftime(&buf, buf.len, fmt, tm.?);
        if (len == 0) return error.OutOfMemory;
        return try alloc.dupe(u8, buf[0..len]);
    }

    fn expandDynamic(self: *Expander, name: []const u8) ?[]const u8 {
        if (std.mem.eql(u8, name, "RANDOM")) {
            var ts: std.c.timespec = undefined;
            _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
            const seed: u64 = @bitCast(ts.nsec);
            var rng = std.Random.DefaultPrng.init(seed);
            const val = rng.random().intRangeLessThan(u16, 0, 32768);
            return std.fmt.allocPrint(self.alloc, "{d}", .{val}) catch null;
        }
        if (std.mem.eql(u8, name, "BASHPID")) {
            return std.fmt.allocPrint(self.alloc, "{d}", .{posix.getpid()}) catch null;
        }
        if (std.mem.eql(u8, name, "UID")) {
            return std.fmt.allocPrint(self.alloc, "{d}", .{std.c.getuid()}) catch null;
        }
        if (std.mem.eql(u8, name, "EUID")) {
            return std.fmt.allocPrint(self.alloc, "{d}", .{posix.geteuid()}) catch null;
        }
        if (std.mem.eql(u8, name, "HOSTNAME")) {
            var buf: [256]u8 = undefined;
            const rc = libc.gethostname(&buf, buf.len);
            if (rc == 0) {
                const len = std.mem.indexOfScalar(u8, &buf, 0) orelse buf.len;
                return self.alloc.dupe(u8, buf[0..len]) catch null;
            }
            return null;
        }
        if (std.mem.eql(u8, name, "OSTYPE")) {
            return self.alloc.dupe(u8, "linux-gnu") catch null;
        }
        if (std.mem.eql(u8, name, "BASH_VERSION") or std.mem.eql(u8, name, "BASH_VERSINFO")) {
            return self.alloc.dupe(u8, "5.2.0") catch null;
        }
        if (std.mem.eql(u8, name, "SECONDS")) {
            var ts: std.c.timespec = undefined;
            _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
            return std.fmt.allocPrint(self.alloc, "{d}", .{ts.sec}) catch null;
        }
        if (std.mem.eql(u8, name, "EPOCHREALTIME")) {
            var ts: std.c.timespec = undefined;
            _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
            const usec: u64 = @intCast(@divTrunc(ts.nsec, 1000));
            return std.fmt.allocPrint(self.alloc, "{d}.{d:0>6}", .{ ts.sec, usec }) catch null;
        }
        return null;
    }

    fn expandSpecial(self: *Expander, c: u8) ExpandError![]const u8 {
        switch (c) {
            '?' => return try std.fmt.allocPrint(self.alloc, "{d}", .{self.env.last_exit_status}),
            '$' => return try std.fmt.allocPrint(self.alloc, "{d}", .{self.env.shell_pid}),
            '#' => return try std.fmt.allocPrint(self.alloc, "{d}", .{self.env.positional_params.len}),
            '!' => {
                if (self.env.last_bg_pid) |pid| {
                    return try std.fmt.allocPrint(self.alloc, "{d}", .{pid});
                }
                return try self.alloc.dupe(u8, "");
            },
            '-' => return try self.alloc.dupe(u8, self.env.options.toFlagString()),
            '@', '*' => {
                var result: std.ArrayListUnmanaged(u8) = .empty;
                for (self.env.positional_params, 0..) |param, i| {
                    if (i > 0) {
                        if (c == '*') {
                            if (self.env.ifs.len > 0) try result.append(self.alloc, self.env.ifs[0]);
                        } else {
                            try result.append(self.alloc, ' ');
                        }
                    }
                    try result.appendSlice(self.alloc, param);
                }
                return result.toOwnedSlice(self.alloc);
            },
            '0' => return try self.alloc.dupe(u8, self.env.shell_name),
            else => return try self.alloc.dupe(u8, ""),
        }
    }

    pub fn expandHeredocBody(self: *Expander, body: []const u8) ExpandError![]const u8 {
        var result: std.ArrayListUnmanaged(u8) = .empty;
        var i: usize = 0;
        while (i < body.len) {
            if (body[i] == '\\' and i + 1 < body.len) {
                const next_ch = body[i + 1];
                if (next_ch == '$' or next_ch == '`' or next_ch == '\\') {
                    try result.append(self.alloc, next_ch);
                    i += 2;
                    continue;
                }
                try result.append(self.alloc, body[i]);
                i += 1;
            } else if (body[i] == '$' and i + 1 < body.len) {
                if (body[i + 1] == '(') {
                    if (i + 2 < body.len and body[i + 2] == '(') {
                        const arith_start = i + 3;
                        var depth: usize = 1;
                        var j = arith_start;
                        while (j + 1 < body.len) {
                            if (body[j] == '(' and body[j + 1] == '(') { depth += 1; j += 2; continue; }
                            if (body[j] == ')' and body[j + 1] == ')') {
                                depth -= 1;
                                if (depth == 0) break;
                                j += 2;
                                continue;
                            }
                            j += 1;
                        }
                        const expr = body[arith_start..j];
                        const val = try self.expandArithmetic(expr);
                        try result.appendSlice(self.alloc, val);
                        self.alloc.free(val);
                        i = if (j + 1 < body.len) j + 2 else body.len;
                    } else {
                        const cmd_start = i + 2;
                        var depth: usize = 1;
                        var j = cmd_start;
                        while (j < body.len) {
                            if (body[j] == '(') { depth += 1; }
                            else if (body[j] == ')') {
                                depth -= 1;
                                if (depth == 0) break;
                            }
                            j += 1;
                        }
                        const cmd_body = body[cmd_start..j];
                        const val = try self.expandCommandSub(.{ .body = cmd_body });
                        try result.appendSlice(self.alloc, val);
                        self.alloc.free(val);
                        i = if (j < body.len) j + 1 else body.len;
                    }
                } else if (body[i + 1] == '{') {
                    const brace_start = i + 2;
                    var j = brace_start;
                    while (j < body.len and body[j] != '}') : (j += 1) {}
                    const name = body[brace_start..j];
                    if (self.env.get(name)) |val| {
                        try result.appendSlice(self.alloc, val);
                    } else if (self.env.options.nounset) {
                        const msg = std.fmt.allocPrint(self.alloc, "zigsh: {s}: parameter not set\n", .{name}) catch return error.OutOfMemory;
                        _ = std.c.write(2, msg.ptr, msg.len);
                        self.alloc.free(msg);
                        return error.UnsetVariable;
                    }
                    i = if (j < body.len) j + 1 else body.len;
                } else if (types.isNameStart(body[i + 1])) {
                    var j = i + 1;
                    while (j < body.len and types.isNameCont(body[j])) : (j += 1) {}
                    const name = body[i + 1 .. j];
                    if (self.env.get(name)) |val| {
                        try result.appendSlice(self.alloc, val);
                    } else if (self.env.options.nounset) {
                        const msg = std.fmt.allocPrint(self.alloc, "zigsh: {s}: parameter not set\n", .{name}) catch return error.OutOfMemory;
                        _ = std.c.write(2, msg.ptr, msg.len);
                        self.alloc.free(msg);
                        return error.UnsetVariable;
                    }
                    i = j;
                } else if (body[i + 1] >= '1' and body[i + 1] <= '9') {
                    const digit: u32 = body[i + 1] - '0';
                    const val = self.env.getPositional(digit) orelse "";
                    try result.appendSlice(self.alloc, val);
                    i += 2;
                } else {
                    const special = body[i + 1];
                    const val = switch (special) {
                        '?' => std.fmt.allocPrint(self.alloc, "{d}", .{self.env.last_exit_status}) catch return error.OutOfMemory,
                        '$' => std.fmt.allocPrint(self.alloc, "{d}", .{self.env.shell_pid}) catch return error.OutOfMemory,
                        '#' => std.fmt.allocPrint(self.alloc, "{d}", .{self.env.positional_params.len}) catch return error.OutOfMemory,
                        '!' => blk: {
                            if (self.env.last_bg_pid) |pid| {
                                break :blk std.fmt.allocPrint(self.alloc, "{d}", .{pid}) catch return error.OutOfMemory;
                            }
                            break :blk try self.alloc.dupe(u8, "");
                        },
                        '-' => try self.alloc.dupe(u8, self.env.options.toFlagString()),
                        '@', '*' => blk: {
                            var params: std.ArrayListUnmanaged(u8) = .empty;
                            for (self.env.positional_params, 0..) |param, pi| {
                                if (pi > 0) try params.append(self.alloc, ' ');
                                try params.appendSlice(self.alloc, param);
                            }
                            break :blk try params.toOwnedSlice(self.alloc);
                        },
                        '0' => try self.alloc.dupe(u8, "zigsh"),
                        else => blk: {
                            try result.append(self.alloc, '$');
                            i += 1;
                            break :blk null;
                        },
                    };
                    if (val) |v| {
                        try result.appendSlice(self.alloc, v);
                        self.alloc.free(v);
                        i += 2;
                    }
                }
            } else if (body[i] == '`') {
                const bt_start = i + 1;
                var j = bt_start;
                while (j < body.len and body[j] != '`') : (j += 1) {}
                const cmd_body = body[bt_start..j];
                const val = try self.expandCommandSub(.{ .body = cmd_body });
                try result.appendSlice(self.alloc, val);
                self.alloc.free(val);
                i = if (j < body.len) j + 1 else body.len;
            } else {
                try result.append(self.alloc, body[i]);
                i += 1;
            }
        }
        return result.toOwnedSlice(self.alloc);
    }

    fn expandTilde(self: *Expander, text: []const u8) ExpandError![]const u8 {
        if (text.len == 1 and text[0] == '~') {
            if (self.env.get("HOME")) |home| return try self.alloc.dupe(u8, home);
            return try self.alloc.dupe(u8, text);
        }
        if (text.len == 2 and text[0] == '~' and text[1] == '+') {
            if (self.env.get("PWD")) |pwd| return try self.alloc.dupe(u8, pwd);
            return try self.alloc.dupe(u8, text);
        }
        if (text.len == 2 and text[0] == '~' and text[1] == '-') {
            if (self.env.get("OLDPWD")) |oldpwd| return try self.alloc.dupe(u8, oldpwd);
            return try self.alloc.dupe(u8, text);
        }
        if (text.len > 1 and text[0] == '~') {
            const username = text[1..];
            const username_z = self.alloc.dupeZ(u8, username) catch return error.OutOfMemory;
            defer self.alloc.free(username_z);
            if (posix.getpwnam(username_z.ptr)) |home_dir| {
                return try self.alloc.dupe(u8, std.mem.sliceTo(home_dir, 0));
            }
        }
        return try self.alloc.dupe(u8, text);
    }

    fn processBacktickBody(self: *Expander, body: []const u8) ExpandError![]const u8 {
        var result: std.ArrayListUnmanaged(u8) = .empty;
        var i: usize = 0;
        while (i < body.len) {
            if (body[i] == '\\' and i + 1 < body.len) {
                const next = body[i + 1];
                if (next == '$' or next == '`' or next == '\\') {
                    try result.append(self.alloc, next);
                    i += 2;
                } else if (next == '\n') {
                    i += 2;
                } else {
                    try result.append(self.alloc, '\\');
                    i += 1;
                }
            } else {
                try result.append(self.alloc, body[i]);
                i += 1;
            }
        }
        return result.toOwnedSlice(self.alloc);
    }

    fn expandCommandSub(self: *Expander, cs: ast.CommandSub) ExpandError![]const u8 {
        const trimmed = std.mem.trim(u8, cs.body, " \t\n\r");
        if (trimmed.len > 2 and trimmed[0] == '<' and (trimmed[1] == ' ' or trimmed[1] == '\t')) {
            const filename_raw = std.mem.trim(u8, trimmed[2..], " \t\n\r");
            if (std.mem.indexOfAny(u8, filename_raw, "|&;()") == null) {
                var fn_buf: std.ArrayListUnmanaged(u8) = .empty;
                var fi: usize = 0;
                while (fi < filename_raw.len) {
                    if (filename_raw[fi] == '$' and fi + 1 < filename_raw.len) {
                        if (types.isNameStart(filename_raw[fi + 1])) {
                            fi += 1;
                            const start = fi;
                            while (fi < filename_raw.len and types.isNameCont(filename_raw[fi])) fi += 1;
                            const val = self.env.get(filename_raw[start..fi]) orelse "";
                            fn_buf.appendSlice(self.alloc, val) catch break;
                        } else {
                            fn_buf.append(self.alloc, filename_raw[fi]) catch break;
                            fi += 1;
                        }
                    } else if (filename_raw[fi] == '~' and fi == 0) {
                        const home = self.env.get("HOME") orelse "";
                        fn_buf.appendSlice(self.alloc, home) catch break;
                        fi += 1;
                    } else {
                        fn_buf.append(self.alloc, filename_raw[fi]) catch break;
                        fi += 1;
                    }
                }
                const filename = fn_buf.items;
                if (filename.len > 0) {
                    if (posix.open(filename, posix.oRdonly(), 0)) |fd| {
                        var output: std.ArrayListUnmanaged(u8) = .empty;
                        var buf: [4096]u8 = undefined;
                        while (true) {
                            const n = posix.read(fd, &buf) catch break;
                            if (n == 0) break;
                            output.appendSlice(self.alloc, buf[0..n]) catch break;
                        }
                        posix.close(fd);
                        while (output.items.len > 0 and output.items[output.items.len - 1] == '\n') {
                            _ = output.pop();
                        }
                        return output.toOwnedSlice(self.alloc);
                    } else |_| {}
                }
            }
        }

        const pipe_fds = posix.pipe() catch return error.CommandSubstitutionFailed;

        const pid = posix.fork() catch {
            posix.close(pipe_fds[0]);
            posix.close(pipe_fds[1]);
            return error.CommandSubstitutionFailed;
        };

        if (pid == 0) {
            signals.clearTrapsForSubshell();
            self.env.in_subshell = true;
            posix.close(pipe_fds[0]);
            posix.dup2(pipe_fds[1], 1) catch posix.exit(1);
            posix.close(pipe_fds[1]);

            var lexer = Lexer.init(cs.body);
            var parser = Parser.init(self.alloc, &lexer) catch posix.exit(2);
            const program = parser.parseProgram() catch posix.exit(2);

            const Executor = @import("executor.zig").Executor;
            var executor = Executor.init(self.alloc, self.env, self.jobs);
            const status = executor.executeProgram(program);
            posix.exit(status);
        }

        posix.close(pipe_fds[1]);

        var output: std.ArrayListUnmanaged(u8) = .empty;
        var buf: [4096]u8 = undefined;
        while (true) {
            const n = posix.read(pipe_fds[0], &buf) catch break;
            if (n == 0) break;
            output.appendSlice(self.alloc, buf[0..n]) catch break;
        }
        posix.close(pipe_fds[0]);

        const wait_result = posix.waitpid(pid, 0);
        self.env.last_exit_status = posix.statusFromWait(wait_result.status);

        while (output.items.len > 0 and output.items[output.items.len - 1] == '\n') {
            _ = output.pop();
        }

        return output.toOwnedSlice(self.alloc);
    }

    fn buildTmpWord(self: *Expander, text: []const u8) ast.WordPart {
        var lexer = Lexer.init(text);
        var parser = Parser.init(self.alloc, &lexer) catch return .{ .literal = text };
        const word = parser.buildWord(text) catch return .{ .literal = text };
        if (word.parts.len > 0) return word.parts[0];
        return .{ .literal = text };
    }

    pub fn expandArithmetic(self: *Expander, expr: []const u8) ExpandError![]const u8 {
        var expanded_expr: std.ArrayListUnmanaged(u8) = .empty;
        var i: usize = 0;
        while (i < expr.len) {
            if (expr[i] == '$' and i + 1 < expr.len) {
                if (expr[i + 1] == '(') {
                    if (i + 2 < expr.len and expr[i + 2] == '(') {
                        var depth: usize = 2;
                        var j = i + 3;
                        while (j < expr.len and depth > 0) : (j += 1) {
                            if (j + 1 < expr.len and expr[j] == ')' and expr[j + 1] == ')') {
                                depth -= 2;
                                if (depth == 0) { j += 2; break; }
                                j += 1;
                            } else if (expr[j] == '(') {
                                depth += 1;
                            } else if (expr[j] == ')') {
                                if (depth > 0) depth -= 1;
                            }
                        }
                        const inner = expr[i..j];
                        const word = self.buildTmpWord(inner);
                        const val = self.expandPart(word) catch |e| return e;
                        try expanded_expr.appendSlice(self.alloc, val);
                        i = j;
                    } else {
                        var depth: usize = 1;
                        var j = i + 2;
                        while (j < expr.len and depth > 0) : (j += 1) {
                            if (expr[j] == '(') depth += 1 else if (expr[j] == ')') depth -= 1;
                        }
                        const inner = expr[i..j];
                        const val = self.expandCommandSub(.{ .body = inner[2 .. inner.len - 1] }) catch return error.CommandSubstitutionFailed;
                        try expanded_expr.appendSlice(self.alloc, val);
                        i = j;
                    }
                } else if (expr[i + 1] == '{') {
                    var depth: usize = 1;
                    var j = i + 2;
                    while (j < expr.len and depth > 0) : (j += 1) {
                        if (expr[j] == '{') depth += 1 else if (expr[j] == '}') depth -= 1;
                    }
                    const inner = expr[i..j];
                    const word = self.buildTmpWord(inner);
                    const val = self.expandPart(word) catch |e| return e;
                    try expanded_expr.appendSlice(self.alloc, val);
                    i = j;
                } else if (types.isNameStart(expr[i + 1])) {
                    i += 1;
                    const start = i;
                    while (i < expr.len and types.isNameCont(expr[i])) : (i += 1) {}
                    const name = expr[start..i];
                    const val = self.env.get(name) orelse "0";
                    try expanded_expr.appendSlice(self.alloc, val);
                } else if (expr[i + 1] >= '0' and expr[i + 1] <= '9') {
                    i += 1;
                    const digit = expr[i] - '0';
                    i += 1;
                    const val = if (digit == 0) "0" else self.env.getPositional(@intCast(digit)) orelse "0";
                    try expanded_expr.appendSlice(self.alloc, val);
                } else if (expr[i + 1] == '#') {
                    i += 2;
                    var num_buf: [16]u8 = undefined;
                    const val = std.fmt.bufPrint(&num_buf, "{d}", .{self.env.positional_params.len}) catch "0";
                    try expanded_expr.appendSlice(self.alloc, val);
                } else if (expr[i + 1] == '?') {
                    i += 2;
                    var num_buf: [16]u8 = undefined;
                    const val = std.fmt.bufPrint(&num_buf, "{d}", .{self.env.last_exit_status}) catch "0";
                    try expanded_expr.appendSlice(self.alloc, val);
                } else if (expr[i + 1] == '$') {
                    i += 2;
                    var num_buf: [16]u8 = undefined;
                    const val = std.fmt.bufPrint(&num_buf, "{d}", .{self.env.shell_pid}) catch "0";
                    try expanded_expr.appendSlice(self.alloc, val);
                } else if (expr[i + 1] == '*' or expr[i + 1] == '@') {
                    i += 2;
                    const sep: []const u8 = if (self.env.get("IFS")) |ifs| (if (ifs.len > 0) ifs[0..1] else "") else " ";
                    for (self.env.positional_params, 0..) |p, idx| {
                        if (idx > 0) try expanded_expr.appendSlice(self.alloc, sep);
                        try expanded_expr.appendSlice(self.alloc, p);
                    }
                } else {
                    try expanded_expr.append(self.alloc, expr[i]);
                    i += 1;
                }
            } else if (expr[i] == '`') {
                i += 1;
                const start = i;
                while (i < expr.len and expr[i] != '`') {
                    if (expr[i] == '\\') i += 1;
                    i += 1;
                }
                const body = expr[start..i];
                if (i < expr.len) i += 1;
                const val = self.expandCommandSub(.{ .body = body }) catch return error.CommandSubstitutionFailed;
                try expanded_expr.appendSlice(self.alloc, val);
            } else {
                try expanded_expr.append(self.alloc, expr[i]);
                i += 1;
            }
        }
        const final_expr = try expanded_expr.toOwnedSlice(self.alloc);
        defer self.alloc.free(final_expr);

        const env_ptr = self.env;
        const lookup = struct {
            var env: *Environment = undefined;
            fn f(name: []const u8) ?[]const u8 {
                if (env.get(name)) |v| return v;
                if (env.options.nounset) {
                    posix.writeAll(2, "zigsh: ");
                    posix.writeAll(2, name);
                    posix.writeAll(2, ": unbound variable\n");
                    env.should_exit = true;
                    env.exit_value = 2;
                }
                return null;
            }
            fn setter(name: []const u8, val: i64) void {
                var buf: [32]u8 = undefined;
                const val_str = std.fmt.bufPrint(&buf, "{d}", .{val}) catch return;
                env.set(name, val_str, false) catch {};
            }
        };
        lookup.env = env_ptr;
        const result = Arithmetic.evaluateWithSetter(final_expr, &lookup.f, &lookup.setter) catch return error.ArithmeticError;
        if (env_ptr.should_exit) return error.ArithmeticError;
        return std.fmt.allocPrint(self.alloc, "{d}", .{result});
    }

    const SplitInfo = struct {
        text: []const u8,
        splittable: []const bool,
        globbable: []const bool,
    };

    fn makeSplitInfoUniform(self: *Expander, expanded: []const u8, is_splittable: bool, is_globbable: bool) ExpandError!SplitInfo {
        const s = try self.alloc.alloc(bool, expanded.len);
        const g = try self.alloc.alloc(bool, expanded.len);
        @memset(s, is_splittable);
        @memset(g, is_globbable);
        return .{ .text = expanded, .splittable = s, .globbable = g };
    }

    fn expandPartWithSplitInfo(self: *Expander, part: ast.WordPart) ExpandError!SplitInfo {
        switch (part) {
            .parameter => |param| return try self.expandParameterWithSplitInfo(param),
            .command_sub, .arith_sub, .backtick_sub => {
                const expanded = try self.expandPart(part);
                return self.makeSplitInfoUniform(expanded, true, true);
            },
            .literal => {
                const expanded = try self.expandPart(part);
                return self.makeSplitInfoUniform(expanded, false, true);
            },
            .single_quoted, .ansi_c_quoted => {
                const expanded = try self.expandPart(part);
                return self.makeSplitInfoUniform(expanded, false, false);
            },
            .double_quoted => |parts| {
                var text: std.ArrayListUnmanaged(u8) = .empty;
                var splittable: std.ArrayListUnmanaged(bool) = .empty;
                var globbable: std.ArrayListUnmanaged(bool) = .empty;
                for (parts) |inner| {
                    const info = try self.expandPartWithSplitInfo(inner);
                    try text.appendSlice(self.alloc, info.text);
                    for (info.splittable) |_| {
                        try splittable.append(self.alloc, false);
                    }
                    for (info.globbable) |_| {
                        try globbable.append(self.alloc, false);
                    }
                }
                return .{
                    .text = try text.toOwnedSlice(self.alloc),
                    .splittable = try splittable.toOwnedSlice(self.alloc),
                    .globbable = try globbable.toOwnedSlice(self.alloc),
                };
            },
            .tilde => {
                const expanded = try self.expandPart(part);
                return self.makeSplitInfoUniform(expanded, false, false);
            },
        }
    }

    fn expandParameterWithSplitInfo(self: *Expander, param: ast.ParameterExp) ExpandError!SplitInfo {
        switch (param) {
            .default => |op| {
                const val = self.getParamValue(op.name);
                if (val == null or (op.colon and val.?.len == 0)) {
                    return try self.expandWordWithSplitInfoParamContext(op.word);
                }
                const v = try self.alloc.dupe(u8, val.?);
                return self.makeSplitInfoUniform(v, true, true);
            },
            .assign => |op| {
                const val = self.getParamValue(op.name);
                if (val == null or (op.colon and val.?.len == 0)) {
                    const info = try self.expandWordWithSplitInfoParamContext(op.word);
                    self.env.set(op.name, info.text, false) catch {};
                    return info;
                }
                const v = try self.alloc.dupe(u8, val.?);
                return self.makeSplitInfoUniform(v, true, true);
            },
            .alternative => |op| {
                const val = self.getParamValue(op.name);
                if (val != null and (!op.colon or val.?.len > 0)) {
                    return try self.expandWordWithSplitInfoParamContext(op.word);
                }
                const v = try self.alloc.dupe(u8, "");
                return self.makeSplitInfoUniform(v, false, false);
            },
            else => {
                const expanded = try self.expandParameter(param);
                return self.makeSplitInfoUniform(expanded, true, true);
            },
        }
    }

    fn expandPartWithSplitInfoParamContext(self: *Expander, part: ast.WordPart) ExpandError!SplitInfo {
        switch (part) {
            .literal => {
                const expanded = try self.expandPart(part);
                return self.makeSplitInfoUniform(expanded, true, true);
            },
            .double_quoted => |parts| {
                var text: std.ArrayListUnmanaged(u8) = .empty;
                var sp: std.ArrayListUnmanaged(bool) = .empty;
                var gl: std.ArrayListUnmanaged(bool) = .empty;
                for (parts) |inner| {
                    const expanded = try self.expandPart(inner);
                    try text.appendSlice(self.alloc, expanded);
                    const is_expansion = switch (inner) {
                        .parameter => |p| switch (p) {
                            .special => |ch| ch == '@' or ch == '*',
                            else => false,
                        },
                        else => false,
                    };
                    for (0..expanded.len) |_| {
                        try sp.append(self.alloc, is_expansion);
                        try gl.append(self.alloc, false);
                    }
                }
                return .{
                    .text = try text.toOwnedSlice(self.alloc),
                    .splittable = try sp.toOwnedSlice(self.alloc),
                    .globbable = try gl.toOwnedSlice(self.alloc),
                };
            },
            .single_quoted, .ansi_c_quoted => {
                const expanded = try self.expandPart(part);
                return self.makeSplitInfoUniform(expanded, false, false);
            },
            else => return try self.expandPartWithSplitInfo(part),
        }
    }

    fn expandWordWithSplitInfoParamContext(self: *Expander, word: ast.Word) ExpandError!SplitInfo {
        var text: std.ArrayListUnmanaged(u8) = .empty;
        var splittable: std.ArrayListUnmanaged(bool) = .empty;
        var globbable: std.ArrayListUnmanaged(bool) = .empty;

        for (word.parts) |part| {
            const info = try self.expandPartWithSplitInfoParamContext(part);
            try text.appendSlice(self.alloc, info.text);
            try splittable.appendSlice(self.alloc, info.splittable);
            try globbable.appendSlice(self.alloc, info.globbable);
        }

        return .{
            .text = try text.toOwnedSlice(self.alloc),
            .splittable = try splittable.toOwnedSlice(self.alloc),
            .globbable = try globbable.toOwnedSlice(self.alloc),
        };
    }

    fn expandWordWithSplitInfo(self: *Expander, word: ast.Word) ExpandError!SplitInfo {
        var text: std.ArrayListUnmanaged(u8) = .empty;
        var splittable: std.ArrayListUnmanaged(bool) = .empty;
        var globbable: std.ArrayListUnmanaged(bool) = .empty;

        for (word.parts) |part| {
            const info = try self.expandPartWithSplitInfo(part);
            if (info.text.len == 0 and isQuotedPart(part)) {
                try text.append(self.alloc, 0x00);
                try splittable.append(self.alloc, false);
                try globbable.append(self.alloc, false);
            } else {
                try text.appendSlice(self.alloc, info.text);
                try splittable.appendSlice(self.alloc, info.splittable);
                try globbable.appendSlice(self.alloc, info.globbable);
            }
        }

        return .{
            .text = try text.toOwnedSlice(self.alloc),
            .splittable = try splittable.toOwnedSlice(self.alloc),
            .globbable = try globbable.toOwnedSlice(self.alloc),
        };
    }

    const SplitResult = struct {
        fields: []const []const u8,
        globbable: []const bool,
        field_char_globbable: []const []const bool,
    };

    fn fieldSplitWithQuoting(self: *Expander, text: []const u8, splittable: []const bool, globbable_chars: []const bool) ExpandError!SplitResult {
        var fields: std.ArrayListUnmanaged([]const u8) = .empty;
        var glob_flags: std.ArrayListUnmanaged(bool) = .empty;
        var char_glob_flags: std.ArrayListUnmanaged([]const bool) = .empty;
        const ifs = self.env.ifs;
        var i: usize = 0;

        skipIfsWhitespace(text, splittable, ifs, &i);

        while (i < text.len) {
            var field: std.ArrayListUnmanaged(u8) = .empty;
            var field_glob: std.ArrayListUnmanaged(bool) = .empty;
            var has_glob = false;

            while (i < text.len) {
                if (splittable[i] and isIfsChar(text[i], ifs)) break;
                if (globbable_chars[i] and (text[i] == '*' or text[i] == '?' or text[i] == '[')) {
                    has_glob = true;
                }
                try field.append(self.alloc, text[i]);
                try field_glob.append(self.alloc, globbable_chars[i]);
                i += 1;
            }

            try fields.append(self.alloc, try field.toOwnedSlice(self.alloc));
            try glob_flags.append(self.alloc, has_glob);
            try char_glob_flags.append(self.alloc, try field_glob.toOwnedSlice(self.alloc));

            if (i >= text.len) break;

            var saw_nonws = false;
            while (i < text.len and splittable[i] and isIfsChar(text[i], ifs)) {
                if (!isIfsWhitespace(text[i], ifs)) {
                    if (saw_nonws) {
                        try fields.append(self.alloc, try self.alloc.dupe(u8, ""));
                        try glob_flags.append(self.alloc, false);
                        try char_glob_flags.append(self.alloc, try self.alloc.alloc(bool, 0));
                    }
                    saw_nonws = true;
                }
                i += 1;
            }
        }

        return .{
            .fields = try fields.toOwnedSlice(self.alloc),
            .globbable = try glob_flags.toOwnedSlice(self.alloc),
            .field_char_globbable = try char_glob_flags.toOwnedSlice(self.alloc),
        };
    }

    fn buildGlobPattern(self: *Expander, field: []const u8, char_flags: []const bool) ExpandError![]const u8 {
        var pattern: std.ArrayListUnmanaged(u8) = .empty;
        for (field, 0..) |ch, idx| {
            if (idx < char_flags.len and !char_flags[idx] and isGlobSpecial(ch)) {
                try pattern.append(self.alloc, '\\');
            } else if (ch == '[' and idx < char_flags.len and char_flags[idx]) {
                if (!isBracketExprFullyGlobbable(field, char_flags, idx)) {
                    try pattern.append(self.alloc, '\\');
                }
            }
            try pattern.append(self.alloc, ch);
        }
        return pattern.toOwnedSlice(self.alloc);
    }

    fn isBracketExprFullyGlobbable(field: []const u8, char_flags: []const bool, open: usize) bool {
        var j = open + 1;
        if (j < field.len and field[j] == '!' or (j < field.len and field[j] == ']')) j += 1;
        while (j < field.len) : (j += 1) {
            if (field[j] == ']' and j > open + 1) {
                if (j < char_flags.len and char_flags[j]) return true;
                return false;
            }
            if (j < char_flags.len and !char_flags[j]) return false;
        }
        return true;
    }

    fn isGlobSpecial(ch: u8) bool {
        return ch == '*' or ch == '?' or ch == '[' or ch == ']' or ch == '\\' or ch == '-';
    }

    fn isIfsWhitespace(ch: u8, ifs: []const u8) bool {
        if (ch != ' ' and ch != '\t' and ch != '\n') return false;
        return std.mem.indexOfScalar(u8, ifs, ch) != null;
    }

    fn skipIfsWhitespace(text: []const u8, splittable: []const bool, ifs: []const u8, i: *usize) void {
        while (i.* < text.len and splittable[i.*] and isIfsWhitespace(text[i.*], ifs)) : (i.* += 1) {}
    }

    fn fieldSplit(self: *Expander, input: []const u8) ExpandError![]const []const u8 {
        var fields: std.ArrayListUnmanaged([]const u8) = .empty;
        const ifs = self.env.ifs;
        var i: usize = 0;

        while (i < input.len) {
            while (i < input.len and isIfsChar(input[i], ifs)) : (i += 1) {}
            if (i >= input.len) break;

            const start = i;
            while (i < input.len and !isIfsChar(input[i], ifs)) : (i += 1) {}

            try fields.append(self.alloc, try self.alloc.dupe(u8, input[start..i]));
        }

        self.alloc.free(input);
        return fields.toOwnedSlice(self.alloc);
    }

    fn isIfsChar(ch: u8, ifs: []const u8) bool {
        return std.mem.indexOfScalar(u8, ifs, ch) != null;
    }

    const QuotedAtInfo = struct {
        part_index: usize,
        inner_index: usize,
    };

    fn findQuotedAt(word: ast.Word) ?QuotedAtInfo {
        for (word.parts, 0..) |part, pi| {
            switch (part) {
                .double_quoted => |inner_parts| {
                    for (inner_parts, 0..) |inner, ii| {
                        switch (inner) {
                            .parameter => |param| {
                                switch (param) {
                                    .special => |ch| {
                                        if (ch == '@') return .{ .part_index = pi, .inner_index = ii };
                                    },
                                    else => {},
                                }
                            },
                            else => {},
                        }
                    }
                },
                else => {},
            }
        }
        return null;
    }

    fn expandQuotedAtWord(self: *Expander, word: ast.Word, at_info: QuotedAtInfo, fields: *std.ArrayListUnmanaged([]const u8)) ExpandError!void {
        const params = self.env.positional_params;
        if (params.len == 0) return;

        const dq_parts = word.parts[at_info.part_index].double_quoted;

        var prefix: std.ArrayListUnmanaged(u8) = .empty;
        for (word.parts[0..at_info.part_index]) |part| {
            const expanded = try self.expandPart(part);
            try prefix.appendSlice(self.alloc, expanded);
        }
        for (dq_parts[0..at_info.inner_index]) |inner| {
            const expanded = try self.expandPart(inner);
            try prefix.appendSlice(self.alloc, expanded);
        }

        var suffix: std.ArrayListUnmanaged(u8) = .empty;
        for (dq_parts[at_info.inner_index + 1 ..]) |inner| {
            const expanded = try self.expandPart(inner);
            try suffix.appendSlice(self.alloc, expanded);
        }
        for (word.parts[at_info.part_index + 1 ..]) |part| {
            const expanded = try self.expandPart(part);
            try suffix.appendSlice(self.alloc, expanded);
        }

        for (params, 0..) |param, i| {
            var field: std.ArrayListUnmanaged(u8) = .empty;
            if (i == 0) try field.appendSlice(self.alloc, prefix.items);
            try field.appendSlice(self.alloc, param);
            if (i == params.len - 1) try field.appendSlice(self.alloc, suffix.items);
            try fields.append(self.alloc, try field.toOwnedSlice(self.alloc));
        }
    }

    const UnquotedAtInfo = struct {
        part_index: usize,
    };

    fn findUnquotedAtOrStar(word: ast.Word) ?UnquotedAtInfo {
        for (word.parts, 0..) |part, pi| {
            switch (part) {
                .parameter => |param| {
                    switch (param) {
                        .special => |ch| {
                            if (ch == '@' or ch == '*') return .{ .part_index = pi };
                        },
                        else => {},
                    }
                },
                else => {},
            }
        }
        return null;
    }

    fn expandUnquotedAtWord(self: *Expander, word: ast.Word, info: UnquotedAtInfo, fields: *std.ArrayListUnmanaged([]const u8)) ExpandError!void {
        const params = self.env.positional_params;

        var prefix: std.ArrayListUnmanaged(u8) = .empty;
        for (word.parts[0..info.part_index]) |part| {
            try prefix.appendSlice(self.alloc, try self.expandPart(part));
        }

        var suffix: std.ArrayListUnmanaged(u8) = .empty;
        for (word.parts[info.part_index + 1 ..]) |part| {
            try suffix.appendSlice(self.alloc, try self.expandPart(part));
        }

        if (params.len == 0) {
            if (prefix.items.len > 0 or suffix.items.len > 0) {
                try prefix.appendSlice(self.alloc, suffix.items);
                const combined = try self.alloc.dupe(u8, prefix.items);
                const split = try self.fieldSplit(combined);
                try fields.appendSlice(self.alloc, split);
            }
            return;
        }

        for (params, 0..) |param, i| {
            var field: std.ArrayListUnmanaged(u8) = .empty;
            if (i == 0) try field.appendSlice(self.alloc, prefix.items);
            try field.appendSlice(self.alloc, param);
            if (i == params.len - 1) try field.appendSlice(self.alloc, suffix.items);

            const field_text = try field.toOwnedSlice(self.alloc);

            if (field_text.len == 0) {
                self.alloc.free(field_text);
                continue;
            }

            if (self.env.ifs.len == 0) {
                try fields.append(self.alloc, field_text);
            } else {
                const split = try self.fieldSplit(field_text);
                try fields.appendSlice(self.alloc, split);
            }
        }
    }

    fn hasQuotedParts(word: ast.Word) bool {
        for (word.parts) |part| {
            if (isQuotedPart(part)) return true;
        }
        return false;
    }

    fn isQuotedPart(part: ast.WordPart) bool {
        return switch (part) {
            .single_quoted, .double_quoted, .ansi_c_quoted => true,
            else => false,
        };
    }
    fn countUtf8Codepoints(s: []const u8) usize {
        var count: usize = 0;
        var i: usize = 0;
        while (i < s.len) {
            const byte = s[i];
            if (byte < 0x80) {
                i += 1;
            } else if (byte & 0xE0 == 0xC0) {
                i += if (i + 2 <= s.len) 2 else 1;
            } else if (byte & 0xF0 == 0xE0) {
                i += if (i + 3 <= s.len) 3 else 1;
            } else if (byte & 0xF8 == 0xF0) {
                i += if (i + 4 <= s.len) 4 else 1;
            } else {
                i += 1;
            }
            count += 1;
        }
        return count;
    }
};

const FlatElem = union(enum) {
    literal_char: u8,
    part_ref: ast.WordPart,
};

fn flattenWord(alloc: std.mem.Allocator, parts: []const ast.WordPart) ![]const FlatElem {
    var result: std.ArrayListUnmanaged(FlatElem) = .empty;
    for (parts) |part| {
        switch (part) {
            .literal => |lit| {
                for (lit) |ch| {
                    try result.append(alloc, .{ .literal_char = ch });
                }
            },
            else => {
                try result.append(alloc, .{ .part_ref = part });
            },
        }
    }
    return result.toOwnedSlice(alloc);
}

fn unflattenToParts(alloc: std.mem.Allocator, elems: []const FlatElem) ![]const ast.WordPart {
    var parts: std.ArrayListUnmanaged(ast.WordPart) = .empty;
    var lit_start: ?usize = null;
    for (elems, 0..) |elem, i| {
        switch (elem) {
            .literal_char => {
                if (lit_start == null) lit_start = i;
            },
            .part_ref => |part| {
                if (lit_start) |start| {
                    var buf: std.ArrayListUnmanaged(u8) = .empty;
                    for (elems[start..i]) |e| {
                        buf.append(alloc, e.literal_char) catch {};
                    }
                    try parts.append(alloc, .{ .literal = buf.toOwnedSlice(alloc) catch "" });
                    lit_start = null;
                }
                try parts.append(alloc, part);
            },
        }
    }
    if (lit_start) |start| {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        for (elems[start..]) |e| {
            buf.append(alloc, e.literal_char) catch {};
        }
        try parts.append(alloc, .{ .literal = buf.toOwnedSlice(alloc) catch "" });
    }
    return parts.toOwnedSlice(alloc);
}

const BracePattern = struct {
    open_idx: usize,
    close_idx: usize,
    comma_count: usize,
};

fn findBracePattern(elems: []const FlatElem) ?BracePattern {
    var depth: i32 = 0;
    var open_idx: ?usize = null;
    var comma_count: usize = 0;
    for (elems, 0..) |elem, i| {
        switch (elem) {
            .literal_char => |ch| {
                if (ch == '{' and depth == 0) {
                    open_idx = i;
                    depth = 1;
                    comma_count = 0;
                } else if (ch == '{') {
                    depth += 1;
                } else if (ch == '}' and depth == 1) {
                    if (open_idx) |oi| {
                        if (comma_count > 0 or hasDoubleDot(elems[oi + 1 .. i])) {
                            return .{
                                .open_idx = oi,
                                .close_idx = i,
                                .comma_count = comma_count,
                            };
                        }
                    }
                    depth = 0;
                    open_idx = null;
                } else if (ch == '}' and depth > 1) {
                    depth -= 1;
                } else if (ch == ',' and depth == 1) {
                    comma_count += 1;
                }
            },
            .part_ref => {},
        }
    }
    return null;
}

fn hasDoubleDot(elems: []const FlatElem) bool {
    if (elems.len < 3) return false;
    for (0..elems.len - 1) |i| {
        if (elems[i] == .literal_char and elems[i].literal_char == '.' and
            elems[i + 1] == .literal_char and elems[i + 1].literal_char == '.')
        {
            return true;
        }
    }
    return false;
}

fn braceExpandWord(alloc: std.mem.Allocator, word: ast.Word) ![]const ast.Word {
    const flat = try flattenWord(alloc, word.parts);
    if (flat.len == 0) {
        var result = try alloc.alloc(ast.Word, 1);
        result[0] = word;
        return result;
    }

    const pattern = findBracePattern(flat) orelse {
        var result = try alloc.alloc(ast.Word, 1);
        result[0] = word;
        return result;
    };

    const prefix = flat[0..pattern.open_idx];
    const suffix = flat[pattern.close_idx + 1 ..];
    const inner = flat[pattern.open_idx + 1 .. pattern.close_idx];

    if (pattern.comma_count > 0) {
        var results: std.ArrayListUnmanaged(ast.Word) = .empty;
        var start: usize = 0;
        var depth: i32 = 0;
        var i: usize = 0;
        while (i < inner.len) : (i += 1) {
            switch (inner[i]) {
                .literal_char => |ch| {
                    if (ch == '{') {
                        depth += 1;
                    } else if (ch == '}') {
                        depth -= 1;
                    } else if (ch == ',' and depth == 0) {
                        const alt = inner[start..i];
                        var combined: std.ArrayListUnmanaged(FlatElem) = .empty;
                        try combined.appendSlice(alloc, prefix);
                        try combined.appendSlice(alloc, alt);
                        try combined.appendSlice(alloc, suffix);
                        const new_parts = try unflattenToParts(alloc, combined.toOwnedSlice(alloc) catch &.{});
                        const new_word = ast.Word{ .parts = new_parts };
                        const sub = try braceExpandWord(alloc, new_word);
                        try results.appendSlice(alloc, sub);
                        start = i + 1;
                    }
                },
                .part_ref => {},
            }
        }
        const alt = inner[start..];
        var combined: std.ArrayListUnmanaged(FlatElem) = .empty;
        try combined.appendSlice(alloc, prefix);
        try combined.appendSlice(alloc, alt);
        try combined.appendSlice(alloc, suffix);
        const new_parts = try unflattenToParts(alloc, combined.toOwnedSlice(alloc) catch &.{});
        const new_word = ast.Word{ .parts = new_parts };
        const sub = try braceExpandWord(alloc, new_word);
        try results.appendSlice(alloc, sub);
        return results.toOwnedSlice(alloc);
    }

    const range_result = try expandRange(alloc, inner, prefix, suffix);
    if (range_result) |result| return result;

    var result = try alloc.alloc(ast.Word, 1);
    result[0] = word;
    return result;
}

fn extractLiteralText(alloc: std.mem.Allocator, elems: []const FlatElem) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    for (elems) |e| {
        switch (e) {
            .literal_char => |ch| try buf.append(alloc, ch),
            .part_ref => return error.OutOfMemory,
        }
    }
    return buf.toOwnedSlice(alloc);
}

fn expandRange(alloc: std.mem.Allocator, inner: []const FlatElem, prefix: []const FlatElem, suffix: []const FlatElem) !?[]const ast.Word {
    const text = extractLiteralText(alloc, inner) catch return null;

    var dot1: ?usize = null;
    var dot2: ?usize = null;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (i + 1 < text.len and text[i] == '.' and text[i + 1] == '.') {
            if (dot1 == null) {
                dot1 = i;
                i += 1;
            } else if (dot2 == null) {
                dot2 = i;
                i += 1;
            } else {
                return null;
            }
        }
    }

    const d1 = dot1 orelse return null;
    const start_str = text[0..d1];
    const end_idx = if (dot2) |d2| d2 else text.len;
    const end_str = text[d1 + 2 .. end_idx];
    const step_str = if (dot2) |d2| text[d2 + 2 ..] else null;

    if (start_str.len == 0 or end_str.len == 0) return null;

    if (start_str.len == 1 and end_str.len == 1 and
        isAlpha(start_str[0]) and isAlpha(end_str[0]))
    {
        return try expandCharRange(alloc, start_str[0], end_str[0], step_str, prefix, suffix);
    }

    const start_num = std.fmt.parseInt(i64, start_str, 10) catch return null;
    const end_num = std.fmt.parseInt(i64, end_str, 10) catch return null;
    var step: i64 = if (start_num <= end_num) 1 else -1;
    if (step_str) |ss| {
        step = std.fmt.parseInt(i64, ss, 10) catch return null;
        if (step == 0) return null;
        if (start_num < end_num and step < 0) return null;
        if (start_num > end_num and step > 0) return null;
    }

    const pad_width = blk: {
        var max_w: usize = 0;
        if (start_str.len > 1 and start_str[0] == '0') max_w = start_str.len;
        if (start_str.len > 1 and start_str[0] == '-' and start_str.len > 2 and start_str[1] == '0') max_w = start_str.len;
        if (end_str.len > 1 and end_str[0] == '0') max_w = @max(max_w, end_str.len);
        if (end_str.len > 1 and end_str[0] == '-' and end_str.len > 2 and end_str[1] == '0') max_w = @max(max_w, end_str.len);
        break :blk max_w;
    };

    var results: std.ArrayListUnmanaged(ast.Word) = .empty;
    var cur = start_num;
    while ((step > 0 and cur <= end_num) or (step < 0 and cur >= end_num)) {
        const num_str = try formatPaddedInt(alloc, cur, pad_width);
        var combined: std.ArrayListUnmanaged(FlatElem) = .empty;
        try combined.appendSlice(alloc, prefix);
        for (num_str) |ch| {
            try combined.append(alloc, .{ .literal_char = ch });
        }
        try combined.appendSlice(alloc, suffix);
        const parts = try unflattenToParts(alloc, try combined.toOwnedSlice(alloc));
        try results.append(alloc, .{ .parts = parts });
        cur += step;
    }
    const slice = try results.toOwnedSlice(alloc);
    return @as(?[]const ast.Word, slice);
}

fn expandCharRange(alloc: std.mem.Allocator, start: u8, end: u8, step_str: ?[]const u8, prefix: []const FlatElem, suffix: []const FlatElem) ![]const ast.Word {
    if (std.ascii.isUpper(start) != std.ascii.isUpper(end) and
        std.ascii.isLower(start) != std.ascii.isLower(end))
        return error.OutOfMemory;

    var step: i64 = if (start <= end) 1 else -1;
    if (step_str) |ss| {
        step = std.fmt.parseInt(i64, ss, 10) catch return error.OutOfMemory;
        if (step == 0) return error.OutOfMemory;
        if (@as(i64, start) < @as(i64, end) and step < 0) return error.OutOfMemory;
        if (@as(i64, start) > @as(i64, end) and step > 0) return error.OutOfMemory;
    }

    var results: std.ArrayListUnmanaged(ast.Word) = .empty;
    var cur: i64 = @intCast(start);
    const end_i: i64 = @intCast(end);
    while ((step > 0 and cur <= end_i) or (step < 0 and cur >= end_i)) {
        var combined: std.ArrayListUnmanaged(FlatElem) = .empty;
        try combined.appendSlice(alloc, prefix);
        try combined.append(alloc, .{ .literal_char = @intCast(@as(u64, @bitCast(cur))) });
        try combined.appendSlice(alloc, suffix);
        const parts = try unflattenToParts(alloc, try combined.toOwnedSlice(alloc));
        try results.append(alloc, .{ .parts = parts });
        cur += step;
    }
    return results.toOwnedSlice(alloc);
}

fn isAlpha(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}

fn formatPaddedInt(alloc: std.mem.Allocator, val: i64, min_width: usize) ![]const u8 {
    var buf: [32]u8 = undefined;
    const abs_val = if (val < 0) @as(u64, @bitCast(-val)) else @as(u64, @bitCast(val));
    const is_neg = val < 0;

    var digit_buf: [20]u8 = undefined;
    var digit_len: usize = 0;
    var v = abs_val;
    if (v == 0) {
        digit_buf[0] = '0';
        digit_len = 1;
    } else {
        while (v > 0) {
            digit_buf[digit_len] = @intCast('0' + (v % 10));
            digit_len += 1;
            v /= 10;
        }
    }

    const total_digits = digit_len + @as(usize, if (is_neg) 1 else 0);
    var pos: usize = 0;
    if (is_neg) {
        buf[pos] = '-';
        pos += 1;
    }
    if (min_width > total_digits) {
        const padding = min_width - total_digits;
        for (0..padding) |_| {
            buf[pos] = '0';
            pos += 1;
        }
    }
    var j: usize = digit_len;
    while (j > 0) {
        j -= 1;
        buf[pos] = digit_buf[j];
        pos += 1;
    }

    return alloc.dupe(u8, buf[0..pos]);
}

fn braceExpandWords(alloc: std.mem.Allocator, words: []const ast.Word) ![]const ast.Word {
    var result: std.ArrayListUnmanaged(ast.Word) = .empty;
    for (words) |word| {
        const expanded = try braceExpandWord(alloc, word);
        try result.appendSlice(alloc, expanded);
    }
    return result.toOwnedSlice(alloc);
}

test "expand literal word" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = @import("env.zig").Environment.init(alloc);
    var jobs = JobTable.init(alloc);
    var exp = Expander.init(alloc, &env, &jobs);

    const word = ast.Word{
        .parts = &.{.{ .literal = "hello" }},
    };
    const result = try exp.expandWord(word);
    try std.testing.expectEqualStrings("hello", result);
}

test "expand parameter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = @import("env.zig").Environment.init(alloc);
    try env.set("FOO", "bar", false);
    var jobs = JobTable.init(alloc);
    var exp = Expander.init(alloc, &env, &jobs);

    const word = ast.Word{
        .parts = &.{.{ .parameter = .{ .simple = "FOO" } }},
    };
    const result = try exp.expandWord(word);
    try std.testing.expectEqualStrings("bar", result);
}

test "expand default value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = @import("env.zig").Environment.init(alloc);
    var jobs = JobTable.init(alloc);
    var exp = Expander.init(alloc, &env, &jobs);

    const default_word = ast.Word{
        .parts = &.{.{ .literal = "default" }},
    };
    const word = ast.Word{
        .parts = &.{.{ .parameter = .{ .default = .{
            .name = "UNSET",
            .colon = true,
            .word = default_word,
        } } }},
    };
    const result = try exp.expandWord(word);
    try std.testing.expectEqualStrings("default", result);
}

test "expand single quoted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env_inst = @import("env.zig").Environment.init(alloc);
    var jobs = JobTable.init(alloc);
    var exp = Expander.init(alloc, &env_inst, &jobs);

    const word = ast.Word{ .parts = &.{.{ .single_quoted = "hello world" }} };
    const result = try exp.expandWord(word);
    try std.testing.expectEqualStrings("hello world", result);
}

test "expand special param question mark" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env_inst = @import("env.zig").Environment.init(alloc);
    env_inst.last_exit_status = 42;
    var jobs = JobTable.init(alloc);
    var exp = Expander.init(alloc, &env_inst, &jobs);

    const word = ast.Word{ .parts = &.{.{ .parameter = .{ .special = '?' } }} };
    const result = try exp.expandWord(word);
    try std.testing.expectEqualStrings("42", result);
}

test "expand special param hash" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env_inst = @import("env.zig").Environment.init(alloc);
    const params: []const []const u8 = &.{ "a", "b", "c" };
    env_inst.positional_params = params;
    var jobs = JobTable.init(alloc);
    var exp = Expander.init(alloc, &env_inst, &jobs);

    const word = ast.Word{ .parts = &.{.{ .parameter = .{ .special = '#' } }} };
    const result = try exp.expandWord(word);
    try std.testing.expectEqualStrings("3", result);
}

test "expand positional param" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env_inst = @import("env.zig").Environment.init(alloc);
    const params: []const []const u8 = &.{ "first", "second" };
    env_inst.positional_params = params;
    var jobs = JobTable.init(alloc);
    var exp = Expander.init(alloc, &env_inst, &jobs);

    const word = ast.Word{ .parts = &.{.{ .parameter = .{ .positional = 1 } }} };
    const result = try exp.expandWord(word);
    try std.testing.expectEqualStrings("first", result);

    const word2 = ast.Word{ .parts = &.{.{ .parameter = .{ .positional = 2 } }} };
    const result2 = try exp.expandWord(word2);
    try std.testing.expectEqualStrings("second", result2);

    const word3 = ast.Word{ .parts = &.{.{ .parameter = .{ .positional = 3 } }} };
    const result3 = try exp.expandWord(word3);
    try std.testing.expectEqualStrings("", result3);
}

test "expand length" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env_inst = @import("env.zig").Environment.init(alloc);
    try env_inst.set("MSG", "hello", false);
    var jobs = JobTable.init(alloc);
    var exp = Expander.init(alloc, &env_inst, &jobs);

    const word = ast.Word{ .parts = &.{.{ .parameter = .{ .length = "MSG" } }} };
    const result = try exp.expandWord(word);
    try std.testing.expectEqualStrings("5", result);
}

test "expand length unset" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env_inst = @import("env.zig").Environment.init(alloc);
    var jobs = JobTable.init(alloc);
    var exp = Expander.init(alloc, &env_inst, &jobs);

    const word = ast.Word{ .parts = &.{.{ .parameter = .{ .length = "NOPE" } }} };
    const result = try exp.expandWord(word);
    try std.testing.expectEqualStrings("0", result);
}

test "expand alternative value set" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env_inst = @import("env.zig").Environment.init(alloc);
    try env_inst.set("X", "val", false);
    var jobs = JobTable.init(alloc);
    var exp = Expander.init(alloc, &env_inst, &jobs);

    const alt_word = ast.Word{ .parts = &.{.{ .literal = "alt" }} };
    const word = ast.Word{ .parts = &.{.{ .parameter = .{ .alternative = .{
        .name = "X",
        .colon = false,
        .word = alt_word,
    } } }} };
    const result = try exp.expandWord(word);
    try std.testing.expectEqualStrings("alt", result);
}

test "expand alternative value unset" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env_inst = @import("env.zig").Environment.init(alloc);
    var jobs = JobTable.init(alloc);
    var exp = Expander.init(alloc, &env_inst, &jobs);

    const alt_word = ast.Word{ .parts = &.{.{ .literal = "alt" }} };
    const word = ast.Word{ .parts = &.{.{ .parameter = .{ .alternative = .{
        .name = "NOPE",
        .colon = false,
        .word = alt_word,
    } } }} };
    const result = try exp.expandWord(word);
    try std.testing.expectEqualStrings("", result);
}

test "expand assign value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env_inst = @import("env.zig").Environment.init(alloc);
    var jobs = JobTable.init(alloc);
    var exp = Expander.init(alloc, &env_inst, &jobs);

    const assign_word = ast.Word{ .parts = &.{.{ .literal = "assigned" }} };
    const word = ast.Word{ .parts = &.{.{ .parameter = .{ .assign = .{
        .name = "NEW",
        .colon = true,
        .word = assign_word,
    } } }} };
    const result = try exp.expandWord(word);
    try std.testing.expectEqualStrings("assigned", result);
    try std.testing.expectEqualStrings("assigned", env_inst.get("NEW").?);
}

test "expand tilde" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env_inst = @import("env.zig").Environment.init(alloc);
    try env_inst.set("HOME", "/home/test", false);
    var jobs = JobTable.init(alloc);
    var exp = Expander.init(alloc, &env_inst, &jobs);

    const word = ast.Word{ .parts = &.{.{ .tilde = "~" }} };
    const result = try exp.expandWord(word);
    try std.testing.expectEqualStrings("/home/test", result);
}

test "expand double quoted parts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env_inst = @import("env.zig").Environment.init(alloc);
    try env_inst.set("NAME", "world", false);
    var jobs = JobTable.init(alloc);
    var exp = Expander.init(alloc, &env_inst, &jobs);

    const inner_parts: []const ast.WordPart = &.{
        .{ .literal = "hello " },
        .{ .parameter = .{ .simple = "NAME" } },
    };
    const word = ast.Word{ .parts = &.{.{ .double_quoted = inner_parts }} };
    const result = try exp.expandWord(word);
    try std.testing.expectEqualStrings("hello world", result);
}

test "field splitting" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env_inst = @import("env.zig").Environment.init(alloc);
    try env_inst.set("VAR", "one two three", false);
    var jobs = JobTable.init(alloc);
    var exp = Expander.init(alloc, &env_inst, &jobs);

    const word = ast.Word{ .parts = &.{.{ .parameter = .{ .simple = "VAR" } }} };
    const fields = try exp.expandFields(word);
    try std.testing.expectEqual(@as(usize, 3), fields.len);
    try std.testing.expectEqualStrings("one", fields[0]);
    try std.testing.expectEqualStrings("two", fields[1]);
    try std.testing.expectEqualStrings("three", fields[2]);
}

test "no field split on literal plus single quoted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env_inst = @import("env.zig").Environment.init(alloc);
    var jobs = JobTable.init(alloc);
    var exp = Expander.init(alloc, &env_inst, &jobs);

    const word = ast.Word{ .parts = &.{
        .{ .literal = "ll=" },
        .{ .single_quoted = "ls -l" },
    } };
    const fields = try exp.expandWordsToFields(&.{word});
    try std.testing.expectEqual(@as(usize, 1), fields.len);
    try std.testing.expectEqualStrings("ll=ls -l", fields[0]);
}

test "field split only unquoted expansion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env_inst = @import("env.zig").Environment.init(alloc);
    try env_inst.set("FOO", "a b", false);
    var jobs = JobTable.init(alloc);
    var exp = Expander.init(alloc, &env_inst, &jobs);

    const word = ast.Word{ .parts = &.{
        .{ .parameter = .{ .simple = "FOO" } },
        .{ .single_quoted = "bar" },
    } };
    const fields = try exp.expandWordsToFields(&.{word});
    try std.testing.expectEqual(@as(usize, 2), fields.len);
    try std.testing.expectEqualStrings("a", fields[0]);
    try std.testing.expectEqualStrings("bbar", fields[1]);
}

test "expand default when var is set" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env_inst = @import("env.zig").Environment.init(alloc);
    try env_inst.set("X", "existing", false);
    var jobs = JobTable.init(alloc);
    var exp = Expander.init(alloc, &env_inst, &jobs);

    const default_word = ast.Word{ .parts = &.{.{ .literal = "default" }} };
    const word = ast.Word{ .parts = &.{.{ .parameter = .{ .default = .{
        .name = "X",
        .colon = true,
        .word = default_word,
    } } }} };
    const result = try exp.expandWord(word);
    try std.testing.expectEqualStrings("existing", result);
}
