const std = @import("std");
const types = @import("types.zig");

pub const Program = struct {
    commands: []const CompleteCommand,
};

pub const CompleteCommand = struct {
    list: List,
    bg: bool = false,
    line: u32 = 0,
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
    line: u32 = 0,
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
    arith_for_clause: ArithForClause,
    case_clause: CaseClause,
    if_clause: IfClause,
    while_clause: WhileClause,
    until_clause: UntilClause,
    arith_command: []const u8,
    double_bracket: *DoubleBracketExpr,
};

pub const SimpleCommand = struct {
    assigns: []const Assignment,
    words: []const Word,
    redirects: []const Redirect,
};

pub const Assignment = struct {
    name: []const u8,
    value: Word,
    append: bool = false,
    array_values: ?[]const Word = null,
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
    ansi_c_quoted: []const u8,
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
    pattern_sub: PatternSubOp,
    substring: SubstringOp,
    case_conv: CaseConvOp,
    indirect: []const u8,
    array_keys: PrefixListOp,
    transform: TransformOp,
    prefix_list: PrefixListOp,
    bad_sub: []const u8,
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

pub const PatternSubOp = struct {
    name: []const u8,
    pattern: Word,
    replacement: Word,
    mode: PatSubMode,
};

pub const PatSubMode = enum { first, all, prefix, suffix };

pub const SubstringOp = struct {
    name: []const u8,
    offset: []const u8,
    length: ?[]const u8,
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
    here_string, // <<<
    and_great, // &>
    and_dgreat, // &>>
};

pub const RedirectTarget = union(enum) {
    word: Word,
    fd: i32,
    fd_move: i32,
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

pub const ArithForClause = struct {
    init: []const u8,
    cond: []const u8,
    step: []const u8,
    body: []const CompleteCommand,
};

pub const CaseClause = struct {
    word: Word,
    items: []const CaseItem,
};

pub const CaseItem = struct {
    patterns: []const Word,
    body: ?[]const CompleteCommand,
    terminator: CaseTerminator = .dsemi,
};

pub const CaseTerminator = enum { dsemi, fall_through, continue_testing };

pub const DoubleBracketExpr = union(enum) {
    unary_test: struct { op: []const u8, operand: Word },
    binary_test: struct { lhs: Word, op: []const u8, rhs: Word },
    not_expr: *DoubleBracketExpr,
    and_expr: struct { left: *DoubleBracketExpr, right: *DoubleBracketExpr },
    or_expr: struct { left: *DoubleBracketExpr, right: *DoubleBracketExpr },
};

pub const CaseConvOp = struct {
    name: []const u8,
    mode: CaseConvMode,
    pattern: ?Word,
};

pub const CaseConvMode = enum { upper_first, upper_all, lower_first, lower_all };

pub const TransformOp = struct {
    name: []const u8,
    operator: u8,
};

pub const PrefixListOp = struct {
    prefix: []const u8,
    join: bool,
};

pub const FunctionDef = struct {
    name: []const u8,
    body: CompoundPair,
    source: []const u8,
};
