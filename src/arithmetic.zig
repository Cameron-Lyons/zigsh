const std = @import("std");
const types = @import("types.zig");

pub const ArithError = error{
    InvalidExpression,
    DivisionByZero,
};

pub const Arithmetic = struct {
    expr: []const u8,
    pos: usize,
    lookup: *const fn ([]const u8) ?[]const u8,
    setter: ?*const fn ([]const u8, i64) void,

    pub fn evaluate(expr: []const u8, lookup: *const fn ([]const u8) ?[]const u8) ArithError!i64 {
        return evaluateWithSetter(expr, lookup, null);
    }

    pub fn evaluateWithSetter(expr: []const u8, lookup: *const fn ([]const u8) ?[]const u8, setter: ?*const fn ([]const u8, i64) void) ArithError!i64 {
        var self = Arithmetic{
            .expr = expr,
            .pos = 0,
            .lookup = lookup,
            .setter = setter,
        };
        self.skipWhitespace();
        const result = try self.parseAssign();
        self.skipWhitespace();
        if (self.pos < self.expr.len) return error.InvalidExpression;
        return result;
    }

    fn skipWhitespace(self: *Arithmetic) void {
        while (self.pos < self.expr.len and (self.expr[self.pos] == ' ' or self.expr[self.pos] == '\t')) {
            self.pos += 1;
        }
    }

    fn parseAssign(self: *Arithmetic) ArithError!i64 {
        const saved_pos = self.pos;
        self.skipWhitespace();

        if (self.pos < self.expr.len and types.isNameStart(self.expr[self.pos])) {
            const name_start = self.pos;
            while (self.pos < self.expr.len and types.isNameCont(self.expr[self.pos])) {
                self.pos += 1;
            }
            const name = self.expr[name_start..self.pos];
            self.skipWhitespace();

            const op = self.matchAssignOp();
            if (op) |assign_op| {
                self.skipWhitespace();
                const rhs = try self.parseAssign();
                const old_val = blk: {
                    const v = self.lookup(name) orelse break :blk @as(i64, 0);
                    break :blk std.fmt.parseInt(i64, v, 10) catch 0;
                };
                const new_val: i64 = switch (assign_op) {
                    .eq => rhs,
                    .add_eq => old_val +% rhs,
                    .sub_eq => old_val -% rhs,
                    .mul_eq => old_val *% rhs,
                    .div_eq => if (rhs == 0) return error.DivisionByZero else @divTrunc(old_val, rhs),
                    .mod_eq => if (rhs == 0) return error.DivisionByZero else @rem(old_val, rhs),
                    .shl_eq => old_val << @intCast(@min(@max(rhs, 0), 63)),
                    .shr_eq => old_val >> @intCast(@min(@max(rhs, 0), 63)),
                    .and_eq => old_val & rhs,
                    .or_eq => old_val | rhs,
                    .xor_eq => old_val ^ rhs,
                };
                if (self.setter) |s| s(name, new_val);
                return new_val;
            }

            self.pos = saved_pos;
        }

        return self.parseTernary();
    }

    const AssignOp = enum { eq, add_eq, sub_eq, mul_eq, div_eq, mod_eq, shl_eq, shr_eq, and_eq, or_eq, xor_eq };

    fn matchAssignOp(self: *Arithmetic) ?AssignOp {
        if (self.pos >= self.expr.len) return null;
        if (self.matchStr("<<=")) return .shl_eq;
        if (self.matchStr(">>=")) return .shr_eq;
        if (self.matchStr("+=")) return .add_eq;
        if (self.matchStr("-=")) return .sub_eq;
        if (self.matchStr("*=")) return .mul_eq;
        if (self.matchStr("/=")) return .div_eq;
        if (self.matchStr("%=")) return .mod_eq;
        if (self.matchStr("&=")) return .and_eq;
        if (self.matchStr("|=")) return .or_eq;
        if (self.matchStr("^=")) return .xor_eq;
        if (self.pos < self.expr.len and self.expr[self.pos] == '=' and
            (self.pos + 1 >= self.expr.len or self.expr[self.pos + 1] != '='))
        {
            self.pos += 1;
            return .eq;
        }
        return null;
    }

    fn parseTernary(self: *Arithmetic) ArithError!i64 {
        const cond = try self.parseOr();
        self.skipWhitespace();
        if (self.pos < self.expr.len and self.expr[self.pos] == '?') {
            self.pos += 1;
            self.skipWhitespace();
            const then_val = try self.parseTernary();
            self.skipWhitespace();
            if (self.pos >= self.expr.len or self.expr[self.pos] != ':') return error.InvalidExpression;
            self.pos += 1;
            self.skipWhitespace();
            const else_val = try self.parseTernary();
            return if (cond != 0) then_val else else_val;
        }
        return cond;
    }

    fn parseOr(self: *Arithmetic) ArithError!i64 {
        var left = try self.parseAnd();
        while (true) {
            self.skipWhitespace();
            if (self.matchStr("||")) {
                self.skipWhitespace();
                const right = try self.parseAnd();
                left = if (left != 0 or right != 0) 1 else 0;
            } else break;
        }
        return left;
    }

    fn parseAnd(self: *Arithmetic) ArithError!i64 {
        var left = try self.parseBitOr();
        while (true) {
            self.skipWhitespace();
            if (self.matchStr("&&")) {
                self.skipWhitespace();
                const right = try self.parseBitOr();
                left = if (left != 0 and right != 0) 1 else 0;
            } else break;
        }
        return left;
    }

    fn parseBitOr(self: *Arithmetic) ArithError!i64 {
        var left = try self.parseBitXor();
        while (true) {
            self.skipWhitespace();
            if (self.pos < self.expr.len and self.expr[self.pos] == '|' and
                (self.pos + 1 >= self.expr.len or self.expr[self.pos + 1] != '|'))
            {
                self.pos += 1;
                self.skipWhitespace();
                const right = try self.parseBitXor();
                left = left | right;
            } else break;
        }
        return left;
    }

    fn parseBitXor(self: *Arithmetic) ArithError!i64 {
        var left = try self.parseBitAnd();
        while (true) {
            self.skipWhitespace();
            if (self.pos < self.expr.len and self.expr[self.pos] == '^') {
                self.pos += 1;
                self.skipWhitespace();
                const right = try self.parseBitAnd();
                left = left ^ right;
            } else break;
        }
        return left;
    }

    fn parseBitAnd(self: *Arithmetic) ArithError!i64 {
        var left = try self.parseEquality();
        while (true) {
            self.skipWhitespace();
            if (self.pos < self.expr.len and self.expr[self.pos] == '&' and
                (self.pos + 1 >= self.expr.len or self.expr[self.pos + 1] != '&'))
            {
                self.pos += 1;
                self.skipWhitespace();
                const right = try self.parseEquality();
                left = left & right;
            } else break;
        }
        return left;
    }

    fn parseEquality(self: *Arithmetic) ArithError!i64 {
        var left = try self.parseRelational();
        while (true) {
            self.skipWhitespace();
            if (self.matchStr("==")) {
                self.skipWhitespace();
                const right = try self.parseRelational();
                left = if (left == right) 1 else 0;
            } else if (self.matchStr("!=")) {
                self.skipWhitespace();
                const right = try self.parseRelational();
                left = if (left != right) 1 else 0;
            } else break;
        }
        return left;
    }

    fn parseRelational(self: *Arithmetic) ArithError!i64 {
        var left = try self.parseShift();
        while (true) {
            self.skipWhitespace();
            if (self.matchStr("<=")) {
                self.skipWhitespace();
                const right = try self.parseShift();
                left = if (left <= right) 1 else 0;
            } else if (self.matchStr(">=")) {
                self.skipWhitespace();
                const right = try self.parseShift();
                left = if (left >= right) 1 else 0;
            } else if (self.pos < self.expr.len and self.expr[self.pos] == '<' and
                (self.pos + 1 >= self.expr.len or self.expr[self.pos + 1] != '<'))
            {
                self.pos += 1;
                self.skipWhitespace();
                const right = try self.parseShift();
                left = if (left < right) 1 else 0;
            } else if (self.pos < self.expr.len and self.expr[self.pos] == '>' and
                (self.pos + 1 >= self.expr.len or self.expr[self.pos + 1] != '>'))
            {
                self.pos += 1;
                self.skipWhitespace();
                const right = try self.parseShift();
                left = if (left > right) 1 else 0;
            } else break;
        }
        return left;
    }

    fn parseShift(self: *Arithmetic) ArithError!i64 {
        var left = try self.parseAddSub();
        while (true) {
            self.skipWhitespace();
            if (self.matchStr("<<")) {
                self.skipWhitespace();
                const right = try self.parseAddSub();
                const shift: u6 = @intCast(@min(@max(right, 0), 63));
                left = left << shift;
            } else if (self.matchStr(">>")) {
                self.skipWhitespace();
                const right = try self.parseAddSub();
                const shift: u6 = @intCast(@min(@max(right, 0), 63));
                left = left >> shift;
            } else break;
        }
        return left;
    }

    fn parseAddSub(self: *Arithmetic) ArithError!i64 {
        var left = try self.parseMulDiv();
        while (true) {
            self.skipWhitespace();
            if (self.pos < self.expr.len and self.expr[self.pos] == '+' and
                (self.pos + 1 >= self.expr.len or (self.expr[self.pos + 1] != '+' and self.expr[self.pos + 1] != '=')))
            {
                self.pos += 1;
                self.skipWhitespace();
                const right = try self.parseMulDiv();
                left = left +% right;
            } else if (self.pos < self.expr.len and self.expr[self.pos] == '-' and
                (self.pos + 1 >= self.expr.len or (self.expr[self.pos + 1] != '-' and self.expr[self.pos + 1] != '=')))
            {
                self.pos += 1;
                self.skipWhitespace();
                const right = try self.parseMulDiv();
                left = left -% right;
            } else break;
        }
        return left;
    }

    fn parseMulDiv(self: *Arithmetic) ArithError!i64 {
        var left = try self.parseUnary();
        while (true) {
            self.skipWhitespace();
            if (self.pos < self.expr.len and self.expr[self.pos] == '*') {
                self.pos += 1;
                self.skipWhitespace();
                const right = try self.parseUnary();
                left = left *% right;
            } else if (self.pos < self.expr.len and self.expr[self.pos] == '/') {
                self.pos += 1;
                self.skipWhitespace();
                const right = try self.parseUnary();
                if (right == 0) return error.DivisionByZero;
                left = @divTrunc(left, right);
            } else if (self.pos < self.expr.len and self.expr[self.pos] == '%') {
                self.pos += 1;
                self.skipWhitespace();
                const right = try self.parseUnary();
                if (right == 0) return error.DivisionByZero;
                left = @rem(left, right);
            } else break;
        }
        return left;
    }

    fn parseUnary(self: *Arithmetic) ArithError!i64 {
        self.skipWhitespace();
        if (self.pos < self.expr.len) {
            if (self.pos + 1 < self.expr.len and self.expr[self.pos] == '+' and self.expr[self.pos + 1] == '+') {
                self.pos += 2;
                self.skipWhitespace();
                if (self.pos < self.expr.len and types.isNameStart(self.expr[self.pos])) {
                    const name_start = self.pos;
                    while (self.pos < self.expr.len and types.isNameCont(self.expr[self.pos])) self.pos += 1;
                    const name = self.expr[name_start..self.pos];
                    const old_val = blk: {
                        const v = self.lookup(name) orelse break :blk @as(i64, 0);
                        break :blk std.fmt.parseInt(i64, v, 10) catch 0;
                    };
                    const new_val = old_val +% 1;
                    if (self.setter) |s| s(name, new_val);
                    return new_val;
                }
                return error.InvalidExpression;
            }
            if (self.pos + 1 < self.expr.len and self.expr[self.pos] == '-' and self.expr[self.pos + 1] == '-') {
                self.pos += 2;
                self.skipWhitespace();
                if (self.pos < self.expr.len and types.isNameStart(self.expr[self.pos])) {
                    const name_start = self.pos;
                    while (self.pos < self.expr.len and types.isNameCont(self.expr[self.pos])) self.pos += 1;
                    const name = self.expr[name_start..self.pos];
                    const old_val = blk: {
                        const v = self.lookup(name) orelse break :blk @as(i64, 0);
                        break :blk std.fmt.parseInt(i64, v, 10) catch 0;
                    };
                    const new_val = old_val -% 1;
                    if (self.setter) |s| s(name, new_val);
                    return new_val;
                }
                return error.InvalidExpression;
            }
            if (self.expr[self.pos] == '+') {
                self.pos += 1;
                return self.parseUnary();
            }
            if (self.expr[self.pos] == '-') {
                self.pos += 1;
                const val = try self.parseUnary();
                return -%val;
            }
            if (self.expr[self.pos] == '~') {
                self.pos += 1;
                const val = try self.parseUnary();
                return ~val;
            }
            if (self.expr[self.pos] == '!') {
                self.pos += 1;
                const val = try self.parseUnary();
                return if (val == 0) 1 else 0;
            }
        }
        return self.parsePrimary();
    }

    fn parsePrimary(self: *Arithmetic) ArithError!i64 {
        self.skipWhitespace();
        if (self.pos >= self.expr.len) return error.InvalidExpression;

        if (self.expr[self.pos] == '(') {
            self.pos += 1;
            self.skipWhitespace();
            const val = try self.parseAssign();
            self.skipWhitespace();
            if (self.pos >= self.expr.len or self.expr[self.pos] != ')') return error.InvalidExpression;
            self.pos += 1;
            return val;
        }

        if (self.expr[self.pos] == '0' and self.pos + 1 < self.expr.len and
            (self.expr[self.pos + 1] == 'x' or self.expr[self.pos + 1] == 'X'))
        {
            self.pos += 2;
            return self.parseHexNumber();
        }

        if (self.expr[self.pos] == '0' and self.pos + 1 < self.expr.len and
            self.expr[self.pos + 1] >= '0' and self.expr[self.pos + 1] <= '7')
        {
            return self.parseOctalNumber();
        }

        if (self.expr[self.pos] >= '0' and self.expr[self.pos] <= '9') {
            return self.parseDecimalNumber();
        }

        if (types.isNameStart(self.expr[self.pos])) {
            return self.parseVariable();
        }

        return error.InvalidExpression;
    }

    fn parseDecimalNumber(self: *Arithmetic) ArithError!i64 {
        var val: i64 = 0;
        while (self.pos < self.expr.len and self.expr[self.pos] >= '0' and self.expr[self.pos] <= '9') {
            val = val *% 10 +% @as(i64, self.expr[self.pos] - '0');
            self.pos += 1;
        }
        return val;
    }

    fn parseHexNumber(self: *Arithmetic) ArithError!i64 {
        var val: i64 = 0;
        var has_digit = false;
        while (self.pos < self.expr.len) {
            const ch = self.expr[self.pos];
            if (ch >= '0' and ch <= '9') {
                val = val *% 16 +% @as(i64, ch - '0');
            } else if (ch >= 'a' and ch <= 'f') {
                val = val *% 16 +% @as(i64, ch - 'a' + 10);
            } else if (ch >= 'A' and ch <= 'F') {
                val = val *% 16 +% @as(i64, ch - 'A' + 10);
            } else break;
            has_digit = true;
            self.pos += 1;
        }
        if (!has_digit) return error.InvalidExpression;
        return val;
    }

    fn parseOctalNumber(self: *Arithmetic) ArithError!i64 {
        var val: i64 = 0;
        while (self.pos < self.expr.len and self.expr[self.pos] >= '0' and self.expr[self.pos] <= '7') {
            val = val *% 8 +% @as(i64, self.expr[self.pos] - '0');
            self.pos += 1;
        }
        return val;
    }

    fn parseVariable(self: *Arithmetic) ArithError!i64 {
        const start = self.pos;
        while (self.pos < self.expr.len and types.isNameCont(self.expr[self.pos])) {
            self.pos += 1;
        }
        const name = self.expr[start..self.pos];
        const val = blk: {
            const v = self.lookup(name) orelse break :blk @as(i64, 0);
            break :blk std.fmt.parseInt(i64, v, 10) catch 0;
        };

        if (self.pos + 1 < self.expr.len and self.expr[self.pos] == '+' and self.expr[self.pos + 1] == '+') {
            self.pos += 2;
            if (self.setter) |s| s(name, val +% 1);
            return val;
        }
        if (self.pos + 1 < self.expr.len and self.expr[self.pos] == '-' and self.expr[self.pos + 1] == '-') {
            self.pos += 2;
            if (self.setter) |s| s(name, val -% 1);
            return val;
        }

        return val;
    }

    fn matchStr(self: *Arithmetic, s: []const u8) bool {
        if (self.pos + s.len > self.expr.len) return false;
        if (std.mem.eql(u8, self.expr[self.pos .. self.pos + s.len], s)) {
            self.pos += s.len;
            return true;
        }
        return false;
    }

};

test "basic arithmetic" {
    const lookup = struct {
        fn f(_: []const u8) ?[]const u8 {
            return null;
        }
    }.f;
    try std.testing.expectEqual(@as(i64, 7), try Arithmetic.evaluate("3 + 4", lookup));
    try std.testing.expectEqual(@as(i64, 6), try Arithmetic.evaluate("2 * 3", lookup));
    try std.testing.expectEqual(@as(i64, 2), try Arithmetic.evaluate("7 / 3", lookup));
    try std.testing.expectEqual(@as(i64, 1), try Arithmetic.evaluate("7 % 3", lookup));
    try std.testing.expectEqual(@as(i64, -5), try Arithmetic.evaluate("-5", lookup));
    try std.testing.expectEqual(@as(i64, 14), try Arithmetic.evaluate("2 + 3 * 4", lookup));
    try std.testing.expectEqual(@as(i64, 20), try Arithmetic.evaluate("(2 + 3) * 4", lookup));
}

test "arithmetic comparisons" {
    const lookup = struct {
        fn f(_: []const u8) ?[]const u8 {
            return null;
        }
    }.f;
    try std.testing.expectEqual(@as(i64, 1), try Arithmetic.evaluate("3 == 3", lookup));
    try std.testing.expectEqual(@as(i64, 0), try Arithmetic.evaluate("3 == 4", lookup));
    try std.testing.expectEqual(@as(i64, 1), try Arithmetic.evaluate("3 < 4", lookup));
    try std.testing.expectEqual(@as(i64, 1), try Arithmetic.evaluate("3 != 4", lookup));
    try std.testing.expectEqual(@as(i64, 1), try Arithmetic.evaluate("1 && 1", lookup));
    try std.testing.expectEqual(@as(i64, 0), try Arithmetic.evaluate("1 && 0", lookup));
    try std.testing.expectEqual(@as(i64, 1), try Arithmetic.evaluate("0 || 1", lookup));
}

test "ternary" {
    const lookup = struct {
        fn f(_: []const u8) ?[]const u8 {
            return null;
        }
    }.f;
    try std.testing.expectEqual(@as(i64, 10), try Arithmetic.evaluate("1 ? 10 : 20", lookup));
    try std.testing.expectEqual(@as(i64, 20), try Arithmetic.evaluate("0 ? 10 : 20", lookup));
}

test "variable lookup" {
    const lookup = struct {
        fn f(name: []const u8) ?[]const u8 {
            if (std.mem.eql(u8, name, "x")) return "42";
            if (std.mem.eql(u8, name, "y")) return "10";
            return null;
        }
    }.f;
    try std.testing.expectEqual(@as(i64, 42), try Arithmetic.evaluate("x", &lookup));
    try std.testing.expectEqual(@as(i64, 52), try Arithmetic.evaluate("x + y", &lookup));
    try std.testing.expectEqual(@as(i64, 0), try Arithmetic.evaluate("z", &lookup));
}

test "bitwise ops" {
    const lookup = struct {
        fn f(_: []const u8) ?[]const u8 {
            return null;
        }
    }.f;
    try std.testing.expectEqual(@as(i64, 0xFF), try Arithmetic.evaluate("0xF0 | 0x0F", lookup));
    try std.testing.expectEqual(@as(i64, 0x00), try Arithmetic.evaluate("0xF0 & 0x0F", lookup));
    try std.testing.expectEqual(@as(i64, 0xFF), try Arithmetic.evaluate("0xF0 ^ 0x0F", lookup));
    try std.testing.expectEqual(@as(i64, -1), try Arithmetic.evaluate("~0", lookup));
}

test "shift ops" {
    const lookup = struct {
        fn f(_: []const u8) ?[]const u8 {
            return null;
        }
    }.f;
    try std.testing.expectEqual(@as(i64, 8), try Arithmetic.evaluate("1 << 3", lookup));
    try std.testing.expectEqual(@as(i64, 2), try Arithmetic.evaluate("16 >> 3", lookup));
}

test "unary operators" {
    const lookup = struct {
        fn f(_: []const u8) ?[]const u8 {
            return null;
        }
    }.f;
    try std.testing.expectEqual(@as(i64, 5), try Arithmetic.evaluate("+5", lookup));
    try std.testing.expectEqual(@as(i64, -3), try Arithmetic.evaluate("-3", lookup));
    try std.testing.expectEqual(@as(i64, 1), try Arithmetic.evaluate("!0", lookup));
    try std.testing.expectEqual(@as(i64, 0), try Arithmetic.evaluate("!1", lookup));
    try std.testing.expectEqual(@as(i64, 0), try Arithmetic.evaluate("!42", lookup));
}

test "hex and octal numbers" {
    const lookup = struct {
        fn f(_: []const u8) ?[]const u8 {
            return null;
        }
    }.f;
    try std.testing.expectEqual(@as(i64, 255), try Arithmetic.evaluate("0xFF", lookup));
    try std.testing.expectEqual(@as(i64, 255), try Arithmetic.evaluate("0XFF", lookup));
    try std.testing.expectEqual(@as(i64, 8), try Arithmetic.evaluate("010", lookup));
    try std.testing.expectEqual(@as(i64, 63), try Arithmetic.evaluate("077", lookup));
}

test "division by zero" {
    const lookup = struct {
        fn f(_: []const u8) ?[]const u8 {
            return null;
        }
    }.f;
    try std.testing.expectError(error.DivisionByZero, Arithmetic.evaluate("1 / 0", lookup));
    try std.testing.expectError(error.DivisionByZero, Arithmetic.evaluate("1 % 0", lookup));
}

test "relational operators" {
    const lookup = struct {
        fn f(_: []const u8) ?[]const u8 {
            return null;
        }
    }.f;
    try std.testing.expectEqual(@as(i64, 1), try Arithmetic.evaluate("3 <= 3", lookup));
    try std.testing.expectEqual(@as(i64, 1), try Arithmetic.evaluate("3 >= 3", lookup));
    try std.testing.expectEqual(@as(i64, 0), try Arithmetic.evaluate("4 <= 3", lookup));
    try std.testing.expectEqual(@as(i64, 0), try Arithmetic.evaluate("2 >= 3", lookup));
    try std.testing.expectEqual(@as(i64, 1), try Arithmetic.evaluate("3 > 2", lookup));
    try std.testing.expectEqual(@as(i64, 0), try Arithmetic.evaluate("3 > 3", lookup));
}

test "nested parentheses" {
    const lookup = struct {
        fn f(_: []const u8) ?[]const u8 {
            return null;
        }
    }.f;
    try std.testing.expectEqual(@as(i64, 30), try Arithmetic.evaluate("((2 + 3) * (1 + 2)) * 2", lookup));
}

test "invalid expression" {
    const lookup = struct {
        fn f(_: []const u8) ?[]const u8 {
            return null;
        }
    }.f;
    try std.testing.expectError(error.InvalidExpression, Arithmetic.evaluate("", lookup));
    try std.testing.expectError(error.InvalidExpression, Arithmetic.evaluate("1 +", lookup));
    try std.testing.expectError(error.InvalidExpression, Arithmetic.evaluate("(1 + 2", lookup));
}

test "assignment operators" {
    const S = struct {
        var last_name: [32]u8 = undefined;
        var last_name_len: usize = 0;
        var last_val: i64 = 0;
        var stored_val_buf: [16]u8 = undefined;
        var stored_val: []const u8 = "";

        fn lookup(name: []const u8) ?[]const u8 {
            if (last_name_len > 0 and std.mem.eql(u8, name, last_name[0..last_name_len])) {
                return stored_val;
            }
            if (std.mem.eql(u8, name, "x")) return "5";
            return null;
        }

        fn setter(name: []const u8, val: i64) void {
            @memcpy(last_name[0..name.len], name);
            last_name_len = name.len;
            last_val = val;
            stored_val = std.fmt.bufPrint(&stored_val_buf, "{d}", .{val}) catch "0";
        }
    };
    S.last_name_len = 0;
    try std.testing.expectEqual(@as(i64, 10), try Arithmetic.evaluateWithSetter("x = 10", &S.lookup, &S.setter));
    try std.testing.expectEqual(@as(i64, 10), S.last_val);

    S.last_name_len = 0;
    try std.testing.expectEqual(@as(i64, 8), try Arithmetic.evaluateWithSetter("x += 3", &S.lookup, &S.setter));
}

test "post increment decrement" {
    const S = struct {
        var last_val: i64 = 0;
        fn lookup(name: []const u8) ?[]const u8 {
            if (std.mem.eql(u8, name, "x")) return "5";
            return null;
        }
        fn setter(_: []const u8, val: i64) void {
            last_val = val;
        }
    };
    try std.testing.expectEqual(@as(i64, 5), try Arithmetic.evaluateWithSetter("x++", &S.lookup, &S.setter));
    try std.testing.expectEqual(@as(i64, 6), S.last_val);
}

test "pre increment decrement" {
    const S = struct {
        var last_val: i64 = 0;
        fn lookup(name: []const u8) ?[]const u8 {
            if (std.mem.eql(u8, name, "x")) return "5";
            return null;
        }
        fn setter(_: []const u8, val: i64) void {
            last_val = val;
        }
    };
    try std.testing.expectEqual(@as(i64, 6), try Arithmetic.evaluateWithSetter("++x", &S.lookup, &S.setter));
    try std.testing.expectEqual(@as(i64, 6), S.last_val);
}
