# zigsh

A POSIX.1-2017 Shell Command Language implementation written in Zig.

## Building

Requires Zig 0.16+ with libc support.

```
zig build
```

Run tests:

```
zig build test
```

## Usage

```sh
# Interactive mode
./zig-out/bin/zigsh

# Execute a command
./zig-out/bin/zigsh -c 'echo hello world'

# Execute a script
./zig-out/bin/zigsh script.sh

# Read from stdin
echo 'echo hello' | ./zig-out/bin/zigsh -s
```

## Features

### Shell Grammar
- Simple commands with assignments and redirections
- Pipelines and and-or lists (`&&`, `||`)
- Compound commands: `if`/`elif`/`else`, `while`, `until`, `for`, `case`
- Brace groups and subshells
- Functions with positional parameters
- Background execution with `&`
- Here-documents (`<<`, `<<-`)

### Word Expansion
- Parameter expansion: `$var`, `${var}`, `${var:-default}`, `${var:=default}`, `${var:?error}`, `${var:+alt}`, `${#var}`, `${var%pat}`, `${var%%pat}`, `${var#pat}`, `${var##pat}`
- Command substitution: `$(cmd)` and `` `cmd` ``
- Arithmetic expansion: `$((expr))` with full C-like operator precedence
- Tilde expansion
- Pathname expansion (globbing): `*`, `?`, `[...]`
- Field splitting on `$IFS`

### Builtins
`:`, `true`, `false`, `exit`, `cd`, `pwd`, `export`, `unset`, `set`, `shift`,
`return`, `break`, `continue`, `echo`, `test`/`[`, `jobs`, `wait`, `kill`,
`trap`, `readonly`, `read`, `umask`, `type`, `getopts`, `.` (source), `eval`,
`exec`, `command`

### Interactive Mode
- Line editor with raw terminal mode
- Cursor movement, insert, delete (arrow keys, Home, End, Ctrl+A/E/K/U/W/L)
- Command history with up/down arrow navigation
- History persistence (`~/.zigsh_history`)
- `PS1` prompt support
- Job notifications for background processes

### Job Control
- Background jobs with `&`
- `jobs`, `wait`, `kill` builtins
- Signal handling and `trap`

### Shell Options
`set -e` (errexit), `set -u` (nounset), `set -x` (xtrace), `set -f` (noglob),
`set -n` (noexec), `set -a` (allexport), `set -v` (verbose), `set -C` (noclobber),
`set -m` (monitor)

## Project Structure

```
src/
  main.zig          Entry point and argument parsing
  shell.zig         Top-level shell struct and execution loop
  lexer.zig         POSIX 2.3 token recognition
  token.zig         Token types and reserved words
  parser.zig        Recursive descent parser
  ast.zig           AST node definitions
  expander.zig      Word expansion pipeline
  executor.zig      Command execution (fork/exec, pipes, builtins)
  builtins.zig      Builtin command implementations
  env.zig           Environment variables, functions, shell options
  redirect.zig      File descriptor redirection
  arithmetic.zig    Arithmetic expression evaluator
  glob.zig          Pathname expansion
  jobs.zig          Job table management
  signals.zig       Signal handling and traps
  line_editor.zig   Interactive line editor with history
  posix.zig         POSIX/libc wrapper functions
  types.zig         Shared type aliases
  errors.zig        Error types
```
