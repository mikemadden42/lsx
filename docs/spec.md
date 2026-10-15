# lsx — Porting Specification

Version: 1.2 (2026-10-15). 1.1 was derived from `refine.c` at commit `2553c22`
and verified against the built binary on 2026-10-14. 1.2 adds the
write-failure exit status (§10) and describes the stricter test suite (§3, §12).

`lsx` is the new name for this tool. The C reference implementation is still
called `refine` (repo `mikemadden42/refine`). Mentions of `refine` below refer
to that implementation and its history. Everything else describes the `lsx`
contract.

`lsx` lists the **regular files** in **one directory** (non-recursive),
grouped by file extension, with groups and names sorted bytewise. This
document is the contract a port must satisfy. §9 records C pitfalls that
have been fixed or that a port must avoid.

---

## 1. Synopsis

```
lsx [-a|--all] [-h|--help] [--] [path]
```

| Argument       | Meaning                                                          |
| -------------- | ---------------------------------------------------------------- |
| `-a`, `--all`  | Include hidden entries (names beginning with `.`).              |
| `-h`, `--help` | Print usage to stdout and exit 0.                                |
| `--`           | End of options; every later argument is positional.             |
| `path`         | Directory to inspect. Default: `.` (current directory).          |

---

## 2. Argument parsing

Process `argv[1..]` strictly left to right, one argument at a time. There is
no option bundling, no `--opt=value` form, and no reordering.

State: `path = "."`, `show_hidden = false`, `path_set = false`,
`options_done = false`.

For each argument `arg`, apply the **first** matching rule:

1. `!options_done && arg == "--"` → `options_done = true`.
2. `!options_done && arg ∈ {"-a", "--all"}` → `show_hidden = true`
   (repeating it is fine).
3. `!options_done && arg ∈ {"-h", "--help"}` → print usage to **stdout**,
   exit **0** immediately. Later arguments are never looked at, even invalid ones.
4. `!options_done && arg` starts with `-` (this includes a bare `-`) →
   print `Unknown option: <arg>\n` to **stderr**, then print usage to
   **stderr**, exit **2** immediately.
5. `!path_set` → `path = arg`, `path_set = true`.
6. Otherwise → print `Unexpected argument: <arg>\n` to **stderr** (no
   usage), exit **2** immediately.

Consequences the port must preserve:

| Invocation               | Result                                                |
| ------------------------ | ----------------------------------------------------- |
| `lsx -ah`                | `Unknown option: -ah`, exit 2 (no bundling)           |
| `lsx --bogus -h`         | exit 2 (the error comes first)                        |
| `lsx -h --bogus`         | help, exit 0                                          |
| `lsx dir -a`             | valid; options may follow the path                    |
| `lsx -- -weird`          | path is `-weird`                                      |
| `lsx -- --`              | path is `--` (a second `--` is positional)            |
| `lsx -- -a`              | path is `-a`; hidden files are **not** enabled        |
| `lsx a b`                | `Unexpected argument: b`, exit 2                      |
| `lsx -- a b`             | `Unexpected argument: b`, exit 2                      |
| `lsx ""`                 | path is the empty string → fails in §3, exit 1        |

Arguments are byte strings, not necessarily valid UTF-8. A port must not
reject or mangle a non-UTF-8 path argument (see §8).

### 2.1 Usage text

Exact text. `<prog>` is `argv[0]` exactly as invoked (e.g. `./build/lsx`),
not a hard-coded name:

```
Usage: <prog> [-a|--all] [-h|--help] [--] [path]
  -a, --all   Include hidden files (those starting with '.')
  -h, --help  Show this help message
  --          Treat the following argument as a path, even if it starts with '-'
  path        Directory to inspect (default: current directory)
```

Every line ends in `\n`. Column alignment uses spaces.

---

## 3. Path validation

1. `stat(path)`. This **follows symlinks**, so a symlink to a directory is
   accepted. On failure:
   `Error: cannot access path: <path>: <os error message>\n` → stderr, exit 1.
2. If the result is not a directory:
   `Error: not a directory: <path>\n` → stderr, exit 1.
3. Open the directory for listing. On failure (e.g. no read permission):
   `Error opening directory: <path>: <os error message>\n` → stderr, exit 1.

`<os error message>` is the platform's `strerror` text, e.g.
`No such file or directory` or `Permission denied`. The test suite checks
each message up to and including the `: ` before the reason, but not the
reason itself, so a port may use its runtime's equivalent text. Keep the
prefixes above exactly and give a human-readable OS reason.

`<path>` is echoed exactly as given (no canonicalization). A trailing slash
(`dir/`) is valid.

---

## 4. Directory scan

Iterate over the entries of `path`, one level only (no recursion). For each
entry name `name`:

1. Skip `.` and `..` always. (In C, rule 2 hides them in default mode. With
   `-a` they are directories, so rule 3 drops them. A port whose directory
   API returns them should still never list them. Most APIs don't return them.)
2. If `!show_hidden` and `name` starts with `.` → skip.
3. `stat(path + "/" + name)`, **following symlinks**. Keep the entry only if
   that succeeds and the target is a **regular file**. Otherwise skip it
   **silently**, which covers:
   - directories and symlinks to directories
   - broken/dangling symlinks
   - FIFOs, sockets, device nodes
   - entries whose stat fails for any reason (EACCES, a race-deleted file, …)
4. A symlink to a regular file **is** listed, under the **link's** name, and
   its extension comes from the link's name, not the target's.
5. Add `name` to the group keyed by `extension(name)` (§5).

If the directory iteration itself fails partway (a real read error from the
directory stream, not a per-entry stat failure):
`Error reading directory: <path>: <os error message>\n` → stderr, exit 1, and
**nothing** is printed to stdout. Output happens only after a complete scan.

---

## 5. Extension rule

`extension(name)` works on the **bare file name**, as bytes:

- Find the **last** `.` in `name`.
- If there is no `.`, or the last `.` is at index 0 → extension is `""` (none).
- Otherwise → extension is the substring **from that `.` to the end, including
  the dot**.

This matches `std::filesystem::path::extension()` for ordinary names. Do
**not** swap in a language's stock helper without checking it against this
table, because many differ (Python's `os.path.splitext` treats leading dots
differently, Go's `filepath.Ext(".bashrc")` returns `.bashrc`, and Rust's
`Path::extension` returns `None` for `foo.`):

| name          | extension key | group header   |
| ------------- | ------------- | -------------- |
| `notes`       | `""`          | `No Extension` |
| `.bashrc`     | `""`          | `No Extension` |
| `a.txt`       | `.txt`        | `txt`          |
| `archive.tar.gz` | `.gz`      | `gz`           |
| `.hidden.md`  | `.md`         | `md`           |
| `..foo`       | `.foo`        | `foo`          |
| `foo.`        | `.`           | *(empty)*, i.e. the line is `:` |
| `x..`         | `.`           | *(empty)*      |
| `...`         | `.`           | *(empty)*      |
| `A.JPG`       | `.JPG`        | `JPG`          |

Extensions are **case-sensitive**: `.JPG` and `.jpg` are separate groups.

---

## 6. Ordering

- **Groups** are sorted by their extension key (dot included) using plain
  **bytewise lexicographic** comparison (`strcmp`/`memcmp` order; a shorter
  prefix sorts first).
  - So `""` (No Extension) is always first. The sort uses the empty key, not the
    string "No Extension".
  - Every other key starts with `.`, so the bare `.` key (empty header) is
    always second when present.
  - Uppercase sorts before lowercase (`JPG` < `gz` < `jpg`).
- **Names within a group** are sorted the same bytewise way: case-sensitive,
  no locale, no natural/numeric sorting (`B.txt` < `a.txt`, `file10` < `file2`).
- Names are unique within a directory, so sort stability doesn't matter.

Do not use locale-aware collation or Unicode normalization. Compare raw
bytes. (For UTF-8 data, bytewise order equals code-point order, so Rust's
`Vec<u8>`/`OsStr` ordering, Go's string `<`, and Zig's `std.mem.order(u8, …)`
all qualify. Python `str` `<` qualifies for valid UTF-8 but not for
surrogate-escaped bytes, so sort `bytes` there.)

---

## 7. Output format

For each group in order, write to **stdout**:

```
<header>:\n
- <name>\n          (one line per name, in sorted order)
\n                  (blank line after EVERY group, including the last)
```

`<header>` is `No Extension` for the `""` key, otherwise the key without its
leading dot (which can be the empty string, giving a line that is just `:`).

- An empty directory, or one with no qualifying files, prints **nothing**
  and exits 0.
- Names are written as raw bytes, with no quoting or escaping, even if they
  contain spaces, non-UTF-8 bytes, or control characters. (A name containing
  `\n` will break the line-oriented format. That's accepted behavior.)

Example (`tests/run_tests.sh` default fixture:
`b.txt a.txt c.md notes .hidden archive.tar.gz subdir/`):

```
No Extension:
- notes

gz:
- archive.tar.gz

md:
- c.md

txt:
- a.txt
- b.txt

```

With `-a`, `.hidden` appears under `No Extension` before `notes`.

---

## 8. Byte-string handling (the main porting trap)

POSIX file names and argv entries are arbitrary bytes except `/` and NUL.
The C tool round-trips them untouched. A port must also:

- **Rust:** use `OsString`/`OsStr` (`std::os::unix::ffi::OsStrExt::as_bytes`)
  for names and paths. Don't call `.to_str().unwrap()` or `to_string_lossy()`
  for anything printed or compared. Write with `stdout().write_all(bytes)`.
  Read args with `std::env::args_os()`, because `std::env::args()` panics on
  non-UTF-8.
- **Go:** `string` holds arbitrary bytes, so `os.ReadDir` + `os.Stat` are fine
  as long as you don't run names through `utf8`-validating code.
- **Zig:** names are `[]const u8` already; just don't validate them.
- **Python:** pass `bytes` paths (`os.listdir(b'.')`, `os.fsencode(arg)`) or use
  `surrogateescape` throughout and write via `sys.stdout.buffer`.

Verified case: a file named `caf\xE9.txt` (Latin-1 byte, invalid UTF-8) must
print as that exact byte sequence and sort by byte value 0xE9.

---

## 9. C pitfalls (history and porting traps)

### 9.1 errno leak caused false "Error reading directory" (fixed in `aa6e8df`)

*The fix clears `errno` right before every `readdir()` call. It is covered by
the `dangling symlink only` test. The details are kept here so ports avoid the
same trap.*

Before the fix, the C loop reset `errno = 0` only after a file was **added**. If a per-entry
`stat` failed (broken symlink → `ENOENT`, unsearchable dir → `EACCES`) and no
later entry got added, `readdir` returned `NULL` at the end with the stale
errno still set. The program then misreported a read error and exited 1.

Reproductions (old = before `aa6e8df`):

```sh
mkdir b && ln -s nowhere b/x.txt && refine b
# Old:  Error reading directory: b: No such file or directory   (exit 1)
# Spec: (no output)                                             (exit 0)

mkdir r && touch r/f && chmod 400 r && refine r     # readable, not searchable
# Old:  Error reading directory: r: Permission denied           (exit 1)
# Spec: (no output)                                             (exit 0)
```

Whether it triggered depended on `readdir` order, so it was nondeterministic
across filesystems. **Intended behavior:** per-entry stat failures are always
silent skips (§4.3). Only a genuine directory-stream error is fatal. Ports
that use native error values instead of a global errno get this right
without trying.

### 9.2 Usage on unknown option goes to stderr (changed in `2553c22`)

The C version used to print the usage block to stdout after an unknown-option
error. It now goes to **stderr** (exit 2). `-h`/`--help` still prints to
**stdout** (exit 0). The `unknown option` test checks that stdout is empty.

### 9.3 Not defects, just inherited constraints

- Out-of-memory prints `Error: out of memory` and exits 1. A managed-runtime
  port may simply abort. Not tested.
- Path joining is a literal `path + "/" + name`. `dir/` becomes `dir//name`,
  which POSIX treats the same. Use the language's join, or stat via the
  directory handle (`fstatat`/`DirEntry::metadata` **with symlink following**,
  see below).
- The original C++ ancestor (`declutter`/`dcl`) reported a missing path as
  `Error: path does not exist:`. the `cannot access path: …: <reason>`
  wording is the one to keep.

### 9.4 Symlink-following pitfall in ports

Many directory APIs give you **lstat** semantics by default:

- Rust: `DirEntry::file_type()` and `DirEntry::metadata()` do **not** follow
  symlinks. Use `std::fs::metadata(entry.path())`.
- Go: `DirEntry.Type()` / `.Info()` do not follow. Use `os.Stat(filepath.Join(dir, name))`.
- Python: `DirEntry.is_file()` follows by default (OK). `is_file(follow_symlinks=False)` does not.
- Zig: `Dir.Iterator` `kind` is the link's own kind. Use `dir.statFile(name)`,
  which follows.

Getting this wrong silently drops symlinked files from the output.

---

## 10. Exit status

| Code | When                                                               |
| ---- | ------------------------------------------------------------------ |
| 0    | Success (including empty output), or help displayed.               |
| 1    | Path can't be stat'ed, isn't a directory, can't be opened, a directory read error, or a failed write to stdout. |
| 2    | Unknown option or extra positional argument.                       |

**Write failures (lsx extension).** If writing or flushing stdout fails (for
the listing or the help text), e.g. on a full disk, print
`Error writing output: <os error message>\n` to stderr and exit 1. If the
reader has closed the pipe (`EPIPE`, as in `lsx | head`), exit 1 without a
message. The C reference ignores write errors: it exits 0, or is killed by
`SIGPIPE` on a closed pipe.

stdout carries only listing output or help/usage text. Every diagnostic line
goes to stderr.

---

## 11. Non-goals

Don't add these unless you're deliberately extending the tool: recursion,
case-folding, locale sorting, colors, counts/sizes, multiple paths, bundled
short options, or `-x=y` syntax.

---

## 12. Conformance tests

`tests/run_tests.sh <binary>` is a black-box suite of 36 cases. Point it at
the port's binary (`sh tests/run_tests.sh ./lsx`) and it must pass them all. In this
repository `cargo test` also runs it, against the freshly built binary
(`tests/conformance.rs`).

The first 16 cases come from `refine`'s suite. They keep their inputs, but
the checks are stricter:

- stdout is compared **byte for byte** (`cmp`), so a missing or extra blank
  line at the end of the listing fails. Capturing with `$(...)`, as the
  original did, strips trailing newlines and hides that.
- Error paths require empty stdout and a first stderr line that starts with
  the prefix from §2/§3, e.g. `Error: cannot access path: -a: `.
- Help tests compare the exact usage text (§2.1); `--bogus` also checks that
  the full usage block follows the error line on stderr.

Some cases skip themselves where they can't run: the non-UTF-8 name on
filesystems that reject it (APFS on macOS), the write-failure cases where
there is no `/dev/full`, and the permission cases when run as root.

The remaining cases cover the behaviors pinned down above:

| Case                                  | Expect                                         |
| ------------------------------------- | ---------------------------------------------- |
| symlink → regular file `link.txt`     | listed under `txt` as `link.txt`               |
| symlink → directory                   | not listed                                     |
| `foo.`, `x..` (and `...` with `-a`)   | group header line `:`, sorted 2nd after No Extension |
| `..foo` with `-a`                     | group `foo`                                    |
| `A.JPG`, `b.jpg`                      | separate groups, `JPG` before `jpg`            |
| `B.txt`, `a.txt`                      | `B.txt` before `a.txt`                         |
| non-UTF-8 name `caf\xE9.txt`          | printed as identical raw bytes                 |
| `lsx -ah`                             | exit 2                                         |
| `lsx -h --bogus`                      | exit 0                                         |
| `lsx -- -a` (no dir `-a`)             | exit 1, `cannot access path: -a: …`            |
| `lsx ""`                              | exit 1                                         |
| `lsx dir -a`                          | same output as `lsx -a dir`                    |
| `chmod 000` dir                       | exit 1, `Error opening directory: …`           |
| `chmod 400` dir with a file (§9.1)    | no output, exit 0                              |
| empty dir / dirs-and-dotfiles only    | no output, exit 0                              |
| path with a trailing slash (`dir/`)   | same output as `dir`                           |
| FIFO named `pipe.txt`                 | not listed                                     |
| stdout on `/dev/full` (listing, `-h`) | exit 1, `Error writing output: …`              |
