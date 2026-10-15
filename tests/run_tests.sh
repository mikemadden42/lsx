#!/bin/sh
# Black-box tests for lsx.
#
# Usage: run_tests.sh [path-to-lsx-binary]
# Defaults to target/release/lsx relative to the repo root.
#
# Each test builds a controlled fixture directory, runs the binary, and
# compares stdout and the exit code against expected values.

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

# check NAME EXPECTED_EXIT EXPECTED_STDOUT_FILE -- ARGS...
# Runs "$LSX ARGS..." and compares exit code + stdout.
check() {
    name=$1
    expected_exit=$2
    expected_out=$3
    shift 4  # drop name, exit, out-file, and the literal "--"

    actual_out=$("$LSX" "$@" 2>/dev/null)
    actual_exit=$?

    tests_run=$((tests_run + 1))
    ok=1

    if [ "$actual_exit" != "$expected_exit" ]; then
        ok=0
        printf 'FAIL %s: exit %s, expected %s\n' "$name" "$actual_exit" "$expected_exit"
    fi

    if [ "$actual_out" != "$(cat "$expected_out")" ]; then
        ok=0
        printf 'FAIL %s: stdout mismatch\n' "$name"
        printf -- '--- expected ---\n%s\n--- actual ---\n%s\n' \
            "$(cat "$expected_out")" "$actual_out"
    fi

    if [ "$ok" = 1 ]; then
        printf 'PASS %s\n' "$name"
    else
        tests_failed=$((tests_failed + 1))
    fi
}

# check_exit NAME EXPECTED_EXIT -- ARGS...
# Like check but only asserts the exit code (for help/error paths).
check_exit() {
    name=$1
    expected_exit=$2
    shift 3  # drop name, exit, and the literal "--"

    "$LSX" "$@" >/dev/null 2>&1
    actual_exit=$?

    tests_run=$((tests_run + 1))
    if [ "$actual_exit" = "$expected_exit" ]; then
        printf 'PASS %s\n' "$name"
    else
        tests_failed=$((tests_failed + 1))
        printf 'FAIL %s: exit %s, expected %s\n' "$name" "$actual_exit" "$expected_exit"
    fi
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

check_exit "help -h"            0 -- -h
check_exit "help --help"        0 -- --help
check_exit "nonexistent path"   1 -- "$work/does-not-exist"
check_exit "not a directory"    1 -- "$fixture/a.txt"
# Usage on the error path goes to stderr, so stdout stays empty.
check "unknown option"           2 "$work/expected_empty"   -- --bogus
check_exit "extra argument"     2 -- "$fixture" "$fixture"
check_exit "dash path needs --" 2 -- -weird
check_exit "extra arg after --" 2 -- -- "$fixture" "$fixture"

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
check_exit "no bundling -ah"       2 -- -ah
check_exit "help before bad opt"   0 -- -h --bogus
check_exit "bad opt before help"   2 -- --bogus -h
check_exit "bare dash"             2 -- -
check_exit "-- then -a is a path"  1 -- -- -a
check_exit "empty path"            1 -- ""
check "option after path"          0 "$work/expected_all"     -- "$fixture" -a

# Help text is exact and names the program as invoked.
cat >"$work/expected_help" <<EOF
Usage: $LSX [-a|--all] [-h|--help] [--] [path]
  -a, --all   Include hidden files (those starting with '.')
  -h, --help  Show this help message
  --          Treat the following argument as a path, even if it starts with '-'
  path        Directory to inspect (default: current directory)
EOF
check "help text on stdout"        0 "$work/expected_help"    -- --help

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
    check_exit "unreadable directory" 1 -- "$lockdir"
    chmod 700 "$lockdir"
fi

# A failed stdout write must not report success (needs Linux's /dev/full).
if [ -w /dev/full ]; then
    for args in "$fixture" "-h"; do
        "$LSX" $args >/dev/full 2>/dev/null
        actual_exit=$?
        tests_run=$((tests_run + 1))
        if [ "$actual_exit" = 1 ]; then
            printf 'PASS %s\n' "write failure ($args)"
        else
            tests_failed=$((tests_failed + 1))
            printf 'FAIL %s: exit %s, expected 1\n' "write failure ($args)" "$actual_exit"
        fi
    done
else
    printf 'SKIP %s: no /dev/full\n' "write failure"
fi

echo
printf '%s test(s) run, %s failed\n' "$tests_run" "$tests_failed"
[ "$tests_failed" = 0 ]
