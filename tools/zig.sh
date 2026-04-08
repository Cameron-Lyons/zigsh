#!/usr/bin/env bash
#
# Resolve a usable Zig binary for this repo and execute it.
#
set -o nounset
set -o pipefail
set -o errexit

REPO_ROOT=$(cd "$(dirname "$0")/.."; pwd)
FETCH_ZIG="$REPO_ROOT/tools/fetch-zig.sh"
ZIG_BIN_ENV=${ZIG_BIN:-}

usage() {
  cat <<'EOF'
Usage:
  tools/zig.sh [--print-path] [zig args...]

Behavior:
  1. Use $ZIG_BIN if set.
  2. Use a matching local toolchain in .toolchains/.
  3. Use zig from PATH.
  4. Download Zig's current "master" toolchain into .toolchains/ and use that.
EOF
}

resolve_zig() {
  if test -n "$ZIG_BIN_ENV"; then
    printf '%s\n' "$ZIG_BIN_ENV"
    return 0
  fi

  if local_zig=$("$FETCH_ZIG" --print-existing-path 2>/dev/null); then
    printf '%s\n' "$local_zig"
    return 0
  fi

  if command -v zig >/dev/null 2>&1; then
    command -v zig
    return 0
  fi

  "$FETCH_ZIG" --print-path
}

print_path=false
while test $# -gt 0; do
  case "$1" in
    --print-path)
      print_path=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    *)
      break
      ;;
  esac
done

resolved_zig=$(resolve_zig)

if test "$print_path" = true; then
  printf '%s\n' "$resolved_zig"
  exit 0
fi

if test $# -eq 0; then
  usage >&2
  exit 2
fi

exec "$resolved_zig" "$@"
