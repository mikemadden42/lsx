#!/bin/sh
# Black-box tests for lsx.
#
# Usage: run_tests.sh [path-to-lsx-binary]
# Defaults to target/release/lsx relative to the repo root.
#
# Each test builds a controlled fixture directory, runs the binary, and
# compares the exit code, stdout (byte for byte) and, on error paths, the
# start of stderr against expected values.

set -u

LSX=${1:-}
if [ -z "$LSX" ]; then
    script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
    LSX="$script_dir/../target/release/lsx"
fi

if [ ! -x "$LSX" ]; then
    echo "error: lsx binary not found or not executable: $LSX" >&2
    echo "build it first, e.g.: cargo build --release" >&2
    exit 2
fi

tests_run=0
tests_failed=0

# Each test runs "$LSX ARGS..." with stdout in $work/out and stderr in
# $work/err, then applies expect_* assertions between begin and end.
# Files are compared byte for byte: $(...) would strip trailing newlines and
# hide a missing or extra blank line at the end of the listing.
begin() {
    name=$1
    tests_run=$((tests_run + 1))
    ok=1
}

fail() {
    ok=0
    printf 'FAIL %s: %s\n' "$name" "$1"
}

end() {
    if [ "$ok" = 1 ]; then
        printf 'PASS %s\n' "$name"
    else
        tests_failed=$((tests_failed + 1))
    fi
}

expect_exit() {
    [ "$actual_exit" = "$1" ] || fail "exit $actual_exit, expected $1"
}

expect_stdout() {
    if ! cmp -s "$1" "$work/out"; then
        fail "stdout mismatch (diff expected actual)"
        diff "$1" "$work/out" | sed 's/^/    /'
    fi
}

expect_stderr_prefix() {
    first=$(head -n 1 "$work/err")
    case $first in
        "$1"*) ;;
        *) fail "stderr line 1 is \"$first\", expected prefix \"$1\"" ;;
    esac
}

# check NAME EXPECTED_EXIT EXPECTED_STDOUT_FILE -- ARGS...
# Asserts the exit code and exact stdout.
check() {
    begin "$1"
    expected_exit=$2
    expected_out=$3
    shift 4  # drop name, exit, out-file, and the literal "--"
    "$LSX" "$@" >"$work/out" 2>"$work/err"
    actual_exit=$?
    expect_exit "$expected_exit"
    expect_stdout "$expected_out"
    end
}

# check_err NAME EXPECTED_EXIT STDERR_PREFIX -- ARGS...
# For error paths: asserts the exit code, empty stdout, and that the first
# stderr line starts with STDERR_PREFIX.
check_err() {
    begin "$1"
    expected_exit=$2
    prefix=$3
    shift 4  # drop name, exit, prefix, and the literal "--"
    "$LSX" "$@" >"$work/out" 2>"$work/err"
    actual_exit=$?
    expect_exit "$expected_exit"
    expect_stdout "$work/expected_empty"
    expect_stderr_prefix "$prefix"
    end
}

# check_write_failure NAME -- ARGS...
# Runs with stdout on /dev/full; the failed write must exit 1 with an error.
check_write_failure() {
    begin "$1"
    shift 2  # drop name and the literal "--"
    "$LSX" "$@" >/dev/full 2>"$work/err"
    actual_exit=$?
    expect_exit 1
    expect_stderr_prefix "Error writing output: "
    end
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Fixture: a mix of extensions, a no-extension file, a dotfile, a subdir.
fixture="$work/fixture"
mkdir -p "$fixture/subdir"
touch "$fixture/b.txt" "$fixture/a.txt" "$fixture/c.md" \
      "$fixture/notes" "$fixture/.hidden" "$fixture/archive.tar.gz"

# Expected default output: dotfile excluded, subdir excluded (not regular),
# groups sorted by extension (No Extension first), names sorted within a group.
cat >"$work/expected_default" <<'EOF'
No Extension:
- notes

gz:
- archive.tar.gz

md:
- c.md

txt:
- a.txt
- b.txt

EOF

# With -a the dotfile appears under No Extension (leading dot is not an ext).
cat >"$work/expected_all" <<'EOF'
No Extension:
- .hidden
- notes

gz:
- archive.tar.gz

md:
- c.md

txt:
- a.txt
- b.txt

EOF

# Empty directory produces no output.
mkdir "$work/empty"
: >"$work/expected_empty"

# Help text is exact and names the program as invoked.
cat >"$work/expected_help" <<EOF
Usage: $LSX [-a|--all] [-h|--help] [--] [path]
  -a, --all   Include hidden files (those starting with '.')
  -h, --help  Show this help message
  --          Treat the following argument as a path, even if it starts with '-'
  path        Directory to inspect (default: current directory)
EOF

check "default grouping"   0 "$work/expected_default" -- "$fixture"
check "include hidden -a"  0 "$work/expected_all"     -- -a "$fixture"
check "include hidden --all" 0 "$work/expected_all"   -- --all "$fixture"
check "empty directory"    0 "$work/expected_empty"   -- "$work/empty"

# "--" ends option parsing; the following argument is treated as a path.
check "separator before path"     0 "$work/expected_default" -- -- "$fixture"
check "options before separator"  0 "$work/expected_all"     -- -a -- "$fixture"

# A directory literally named like an option is reachable only after "--".
dashdir="$work/-weird"
mkdir "$dashdir"
touch "$dashdir/x.txt"
cat >"$work/expected_dashdir" <<'EOF'
txt:
- x.txt

EOF
check "dash-prefixed path via --"  0 "$work/expected_dashdir" -- -- "$dashdir"

# Entries whose stat() fails are skipped silently, even when nothing follows
# them (regression: a stale errno was misreported as a directory read error).
brokendir="$work/broken"
mkdir "$brokendir"
ln -s "$work/nowhere" "$brokendir/dangling.txt"
check "dangling symlink only"      0 "$work/expected_empty"   -- "$brokendir"

check "help -h"                  0 "$work/expected_help"    -- -h
check "help --help"              0 "$work/expected_help"    -- --help
check_err "nonexistent path"     1 "Error: cannot access path: $work/does-not-exist: " -- "$work/does-not-exist"
check_err "not a directory"      1 "Error: not a directory: $fixture/a.txt" -- "$fixture/a.txt"
# Usage on the error path goes to stderr, so stdout stays empty.
check_err "unknown option"       2 "Unknown option: --bogus" -- --bogus
# The usage block follows the error line, also on stderr ($work/err is from
# the run above).
begin "unknown option usage on stderr"
{ printf 'Unknown option: --bogus\n'; cat "$work/expected_help"; } | cmp -s - "$work/err" ||
    fail "stderr is not the error line followed by usage"
end
check_err "extra argument"       2 "Unexpected argument: $fixture" -- "$fixture" "$fixture"
check_err "dash path needs --"   2 "Unknown option: -weird" -- -weird
check_err "extra arg after --"   2 "Unexpected argument: $fixture" -- -- "$fixture" "$fixture"

# --- Additional cases from the lsx porting spec (§12) ---

# Symlinks are followed: a link to a regular file is listed under the link's
# name and extension; a link to a directory is not listed.
linkdir="$work/links"
mkdir "$linkdir"
touch "$work/target-file"
ln -s "$work/target-file" "$linkdir/link.txt"
ln -s "$fixture/subdir" "$linkdir/dirlink.md"
cat >"$work/expected_links" <<'EOF'
txt:
- link.txt

EOF
check "symlink to file listed"     0 "$work/expected_links"   -- "$linkdir"

# Trailing-dot names have the bare "." key: empty header, sorted second.
# "..foo" groups under foo; it and "..." only appear with -a.
dotsdir="$work/dots"
mkdir "$dotsdir"
touch "$dotsdir/foo." "$dotsdir/x.." "$dotsdir/..." "$dotsdir/..foo" \
      "$dotsdir/plain" "$dotsdir/a.txt"
cat >"$work/expected_dots" <<'EOF'
No Extension:
- plain

:
- foo.
- x..

txt:
- a.txt

EOF
cat >"$work/expected_dots_all" <<'EOF'
No Extension:
- plain

:
- ...
- foo.
- x..

foo:
- ..foo

txt:
- a.txt

EOF
check "trailing-dot names"         0 "$work/expected_dots"     -- "$dotsdir"
check "trailing-dot names -a"      0 "$work/expected_dots_all" -- -a "$dotsdir"

# Bytewise, case-sensitive ordering of groups and names.
casedir="$work/case"
mkdir "$casedir"
touch "$casedir/A.JPG" "$casedir/b.jpg" "$casedir/B.txt" "$casedir/a.txt" \
      "$casedir/file10" "$casedir/file2"
cat >"$work/expected_case" <<'EOF'
No Extension:
- file10
- file2

JPG:
- A.JPG

jpg:
- b.jpg

txt:
- B.txt
- a.txt

EOF
check "bytewise case-sensitive order" 0 "$work/expected_case" -- "$casedir"

# Non-UTF-8 names are printed as identical raw bytes.
bytesdir="$work/bytes"
mkdir "$bytesdir"
# Some filesystems (e.g. APFS on macOS) reject such names; skip there.
if touch "$bytesdir/$(printf 'caf\351.txt')" "$bytesdir/cafe.txt" 2>/dev/null; then
    printf 'txt:\n- cafe.txt\n- caf\351.txt\n\n' >"$work/expected_bytes"
    check "non-UTF-8 name"         0 "$work/expected_bytes"   -- "$bytesdir"
else
    printf 'SKIP %s: filesystem rejects non-UTF-8 names\n' "non-UTF-8 name"
fi

# Argument parsing edge cases.
check_err "no bundling -ah"       2 "Unknown option: -ah" -- -ah
check "help before bad opt"       0 "$work/expected_help" -- -h --bogus
check_err "bad opt before help"   2 "Unknown option: --bogus" -- --bogus -h
check_err "bare dash"             2 "Unknown option: -" -- -
check_err "-- then -a is a path"  1 "Error: cannot access path: -a: " -- -- -a
check_err "empty path"            1 "Error: cannot access path: : " -- ""
check "option after path"          0 "$work/expected_all"     -- "$fixture" -a

# A directory with only subdirs and dotfiles prints nothing.
onlydirs="$work/onlydirs"
mkdir -p "$onlydirs/sub"
touch "$onlydirs/.dot"
check "dirs and dotfiles only"     0 "$work/expected_empty"   -- "$onlydirs"

# An unreadable directory fails to open (skipped as root, who can read it).
if [ "$(id -u)" != 0 ]; then
    lockdir="$work/locked"
    mkdir "$lockdir"
    chmod 000 "$lockdir"
    check_err "unreadable directory" 1 "Error opening directory: $lockdir: " -- "$lockdir"
    chmod 700 "$lockdir"
fi

# A failed stdout write must not report success (needs Linux's /dev/full).
if [ -w /dev/full ]; then
    check_write_failure "write failure (listing)" -- "$fixture"
    check_write_failure "write failure (help)"    -- -h
else
    printf 'SKIP %s: no /dev/full\n' "write failure"
fi

# A trailing slash on the path is accepted.
check "trailing slash"             0 "$work/expected_default" -- "$fixture/"

# FIFOs are not regular files, even with a file-like name.
fifodir="$work/fifo"
mkdir "$fifodir"
touch "$fifodir/a.txt"
mkfifo "$fifodir/pipe.txt"
cat >"$work/expected_fifo" <<'EOF'
txt:
- a.txt

EOF
check "fifo not listed"            0 "$work/expected_fifo"    -- "$fifodir"

# Readable but not searchable: every per-entry stat fails, which must be a
# silent skip, not a read error (spec 9.1). Root can search it, so skip.
if [ "$(id -u)" != 0 ]; then
    nosearch="$work/nosearch"
    mkdir "$nosearch"
    touch "$nosearch/f.txt"
    chmod 400 "$nosearch"
    check "readable, not searchable"   0 "$work/expected_empty"   -- "$nosearch"
    chmod 700 "$nosearch"
fi

echo
printf '%s test(s) run, %s failed\n' "$tests_run" "$tests_failed"
[ "$tests_failed" = 0 ]
