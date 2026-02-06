pub const LexError = error{
    UnterminatedSingleQuote,
    UnterminatedDoubleQuote,
    UnterminatedBackquote,
    UnterminatedParenthesis,
    InvalidEscapeSequence,
    UnexpectedEOF,
    InvalidToken,
};

pub const ParseError = error{
    UnexpectedToken,
    ExpectedWord,
    ExpectedName,
    ExpectedIn,
    ExpectedDo,
    ExpectedDone,
    ExpectedThen,
    ExpectedFi,
    ExpectedEsac,
    ExpectedBraceClose,
    ExpectedParenClose,
    ExpectedPattern,
    MissingSemicolon,
    InvalidRedirection,
    InvalidHeredocDelimiter,
    InvalidFunctionName,
    EmptyCommand,
    OutOfMemory,
};

pub const ExpansionError = error{
    UnsetVariable,
    BadSubstitution,
    CommandSubstitutionFailed,
    ArithmeticError,
    PatternError,
    OutOfMemory,
    NulInResult,
};

pub const ExecError = error{
    CommandNotFound,
    PermissionDenied,
    ForkFailed,
    ExecFailed,
    PipeFailed,
    DupFailed,
    RedirectionFailed,
    OutOfMemory,
    SignalError,
};

pub const ShellError = LexError || ParseError || ExpansionError || ExecError || error{
    IoError,
    InternalError,
};
