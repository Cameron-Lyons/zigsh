#!/usr/bin/env bash
#
# Download a matching Zig toolchain into .toolchains/.
#
set -o nounset
set -o pipefail
set -o errexit

REPO_ROOT=$(cd "$(dirname "$0")/.."; pwd)
TOOLCHAINS_DIR="$REPO_ROOT/.toolchains"
INDEX_URL=${ZIG_INDEX_URL:-https://ziglang.org/download/index.json}
CHANNEL=${ZIG_DOWNLOAD_CHANNEL:-master}

usage() {
  cat <<'EOF'
Usage:
  tools/fetch-zig.sh [--channel KEY] [--print-path | --print-existing-path]

Options:
  --channel KEY          Download key from Zig's index.json (default: master)
  --print-path           Ensure a matching toolchain exists, then print its zig path
  --print-existing-path  Print an existing matching toolchain path without downloading
  -h, --help             Show this help text
EOF
}

detect_host_os() {
  local os
  os=$(uname -s 2>/dev/null || echo unknown)
  case "$os" in
    Linux)
      printf 'linux\n'
      ;;
    Darwin)
      printf 'macos\n'
      ;;
    FreeBSD)
      printf 'freebsd\n'
      ;;
    NetBSD)
      printf 'netbsd\n'
      ;;
    OpenBSD)
      printf 'openbsd\n'
      ;;
    DragonFly)
      printf 'dragonfly\n'
      ;;
    SunOS)
      printf 'solaris\n'
      ;;
    *)
      echo "unsupported host OS: $os" >&2
      return 1
      ;;
  esac
}

detect_host_arch() {
  local arch
  arch=$(uname -m 2>/dev/null || echo unknown)
  case "$arch" in
    x86_64|amd64)
      printf 'x86_64\n'
      ;;
    aarch64|arm64)
      printf 'aarch64\n'
      ;;
    i386|i486|i586|i686)
      printf 'x86\n'
      ;;
    armv7l|armv7)
      printf 'armv7a\n'
      ;;
    riscv64)
      printf 'riscv64\n'
      ;;
    loongarch64)
      printf 'loongarch64\n'
      ;;
    powerpc64le|ppc64le)
      printf 'powerpc64le\n'
      ;;
    *)
      echo "unsupported host arch: $arch" >&2
      return 1
      ;;
  esac
}

find_python() {
  if command -v python3 >/dev/null 2>&1; then
    command -v python3
    return 0
  fi
  if command -v python >/dev/null 2>&1; then
    command -v python
    return 0
  fi

  echo "python3 or python is required to parse Zig's download index" >&2
  return 1
}

find_local_zig() {
  local target=$1
  local candidate

  for candidate in "$TOOLCHAINS_DIR"/zig-"$target"-*/zig; do
    test -e "$candidate" || continue
    if "$candidate" version >/dev/null 2>&1; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  return 1
}

resolve_tarball() {
  local channel=$1
  local target=$2
  local python_bin

  python_bin=$(find_python)
  "$python_bin" - "$INDEX_URL" "$channel" "$target" <<'PY'
import json
import sys
import urllib.request

index_url, channel, target = sys.argv[1:]

with urllib.request.urlopen(index_url) as response:
    index = json.load(response)

entry = index.get(channel)
if not isinstance(entry, dict):
    raise SystemExit(f"download channel not found: {channel}")

target_entry = entry.get(target)
if not isinstance(target_entry, dict):
    raise SystemExit(f"target not available for {channel}: {target}")

version = entry.get("version")
tarball = target_entry.get("tarball")
if not version or not tarball:
    raise SystemExit(f"incomplete download metadata for {channel}: {target}")

print(version)
print(tarball)
PY
}

download_and_extract() {
  local url=$1
  local target=$2
  local tmp_dir
  local archive_path
  local extracted_dir
  local dest_dir

  mkdir -p "$TOOLCHAINS_DIR"
  tmp_dir=$(mktemp -d "$TOOLCHAINS_DIR/.fetch.XXXXXX")
  archive_path="$tmp_dir/$(basename "$url")"

  trap 'rm -rf "$tmp_dir"' EXIT

  curl -fL "$url" -o "$archive_path"
  tar -C "$tmp_dir" -xf "$archive_path"

  extracted_dir=$(find "$tmp_dir" -mindepth 1 -maxdepth 1 -type d -name "zig-$target-*" | head -n 1 || true)
  if test -z "$extracted_dir"; then
    echo "failed to locate extracted Zig toolchain" >&2
    return 1
  fi

  dest_dir="$TOOLCHAINS_DIR/$(basename "$extracted_dir")"
  rm -rf "$dest_dir"
  mv "$extracted_dir" "$dest_dir"

  trap - EXIT
  rm -rf "$tmp_dir"

  printf '%s\n' "$dest_dir/zig"
}

print_mode=download
while test $# -gt 0; do
  case "$1" in
    --channel)
      if test $# -lt 2; then
        echo "missing value for --channel" >&2
        exit 2
      fi
      CHANNEL=$2
      shift 2
      ;;
    --channel=*)
      CHANNEL=${1#*=}
      shift
      ;;
    --print-path)
      print_mode=download
      shift
      ;;
    --print-existing-path)
      print_mode=existing
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

target="$(detect_host_arch)-$(detect_host_os)"

if local_zig=$(find_local_zig "$target" 2>/dev/null); then
  printf '%s\n' "$local_zig"
  exit 0
fi

if test "$print_mode" = existing; then
  exit 1
fi

mapfile -t resolved_metadata < <(resolve_tarball "$CHANNEL" "$target")
if test "${#resolved_metadata[@]}" -lt 2; then
  echo "failed to resolve Zig download metadata" >&2
  exit 1
fi

tarball_url=${resolved_metadata[1]}

downloaded_zig=$(download_and_extract "$tarball_url" "$target")
if ! "$downloaded_zig" version >/dev/null 2>&1; then
  echo "downloaded Zig toolchain is not executable: $downloaded_zig" >&2
  exit 1
fi

printf '%s\n' "$downloaded_zig"
