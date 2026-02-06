const std = @import("std");
const types = @import("types.zig");

pub const Program = struct {
    commands: []const CompleteCommand,
};

pub const CompleteCommand = struct {
    list: List,
    bg: bool = false,
};

pub const List = struct {
    first: AndOr,
    rest: []const ListRest,
};

pub const ListRest = struct {
    op: ListOp,
    and_or: AndOr,
};

pub const ListOp = enum { semi, amp };

pub const AndOr = struct {
    first: Pipeline,
    rest: []const AndOrRest,
};

pub const AndOrRest = struct {
    op: AndOrOp,
    pipeline: Pipeline,
};

pub const AndOrOp = enum { and_if, or_if };

pub const Pipeline = struct {
    bang: bool = false,
    commands: []const Command,
};

pub const Command = union(enum) {
    simple: SimpleCommand,
    compound: CompoundPair,
    function_def: FunctionDef,
};

pub const CompoundPair = struct {
    body: CompoundCommand,
    redirects: []const Redirect,
};

pub const CompoundCommand = union(enum) {
    brace_group: BraceGroup,
    subshell: Subshell,
    for_clause: ForClause,
    case_clause: CaseClause,
    if_clause: IfClause,
    while_clause: WhileClause,
    until_clause: UntilClause,
};

pub const SimpleCommand = struct {
    assigns: []const Assignment,
    words: []const Word,
    redirects: []const Redirect,
};

pub const Assignment = struct {
    name: []const u8,
    value: Word,
};

pub const Word = struct {
    parts: []const WordPart,
};

pub const WordPart = union(enum) {
    literal: []const u8,
    single_quoted: []const u8,
    double_quoted: []const WordPart,
    parameter: ParameterExp,
    command_sub: CommandSub,
    arith_sub: []const u8,
    backtick_sub: []const u8,
    tilde: []const u8,
};

pub const ParameterExp = union(enum) {
    simple: []const u8,
    special: u8,
    positional: u32,
    length: []const u8,
    default: ParamOp,
    assign: ParamOp,
    error_msg: ParamOp,
    alternative: ParamOp,
    prefix_strip: PatternOp,
    prefix_strip_long: PatternOp,
    suffix_strip: PatternOp,
    suffix_strip_long: PatternOp,
};

pub const ParamOp = struct {
    name: []const u8,
    colon: bool,
    word: Word,
};

pub const PatternOp = struct {
    name: []const u8,
    pattern: Word,
};

pub const CommandSub = struct {
    body: []const u8,
};

pub const Redirect = struct {
    fd: ?i32,
    op: RedirectOp,
    target: RedirectTarget,
};

pub const RedirectOp = enum {
    input, // <
    output, // >
    append, // >>
    dup_input, // <&
    dup_output, // >&
    read_write, // <>
    clobber, // >|
    heredoc, // <<
    heredoc_strip, // <<-
};

pub const RedirectTarget = union(enum) {
    word: Word,
    fd: i32,
    close: void,
    heredoc: HereDoc,
};

pub const HereDoc = struct {
    delimiter: []const u8,
    body_ptr: *[]const u8,
    quoted: bool,
};

pub const BraceGroup = struct {
    body: []const CompleteCommand,
};

pub const Subshell = struct {
    body: []const CompleteCommand,
};

pub const IfClause = struct {
    condition: []const CompleteCommand,
    then_body: []const CompleteCommand,
    elifs: []const ElifClause,
    else_body: ?[]const CompleteCommand,
};

pub const ElifClause = struct {
    condition: []const CompleteCommand,
    body: []const CompleteCommand,
};

pub const WhileClause = struct {
    condition: []const CompleteCommand,
    body: []const CompleteCommand,
};

pub const UntilClause = struct {
    condition: []const CompleteCommand,
    body: []const CompleteCommand,
};

pub const ForClause = struct {
    name: []const u8,
    wordlist: ?[]const Word,
    body: []const CompleteCommand,
};

pub const CaseClause = struct {
    word: Word,
    items: []const CaseItem,
};

pub const CaseItem = struct {
    patterns: []const Word,
    body: ?[]const CompleteCommand,
};

pub const FunctionDef = struct {
    name: []const u8,
    body: CompoundPair,
    source: []const u8,
};
