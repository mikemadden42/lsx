//! lsx: list the regular files in one directory, grouped by extension.
//!
//! Names, paths and argv are handled as raw bytes throughout (see spec §8).

use std::collections::BTreeMap;
use std::ffi::{OsStr, OsString};
use std::fs;
use std::io::{self, Write};
use std::os::unix::ffi::OsStrExt;
use std::path::Path;
use std::process::ExitCode;

struct Options {
    path: OsString,
    show_hidden: bool,
}

fn usage(prog: &[u8]) -> Vec<u8> {
    let mut out = Vec::new();
    out.extend_from_slice(b"Usage: ");
    out.extend_from_slice(prog);
    out.extend_from_slice(b" [-a|--all] [-h|--help] [--] [path]\n");
    out.extend_from_slice(
        b"  -a, --all   Include hidden files (those starting with '.')\n\
          \x20 -h, --help  Show this help message\n\
          \x20 --          Treat the following argument as a path, even if it starts with '-'\n\
          \x20 path        Directory to inspect (default: current directory)\n",
    );
    out
}

/// Writes raw bytes to stderr, ignoring failures (there is nowhere left to report them).
fn eprint_bytes(parts: &[&[u8]]) {
    let mut err = io::stderr().lock();
    for part in parts {
        let _ = err.write_all(part);
    }
}

/// The platform's strerror text, without Rust's " (os error N)" suffix.
fn os_reason(e: &io::Error) -> String {
    let text = e.to_string();
    match e.raw_os_error() {
        Some(code) => text
            .strip_suffix(&format!(" (os error {code})"))
            .unwrap_or(&text)
            .to_string(),
        None => text,
    }
}

/// Parses argv per spec §2. On help or a usage error, returns the exit code to use.
fn parse_args() -> Result<Options, ExitCode> {
    let mut args = std::env::args_os();
    let prog = args.next().unwrap_or_else(|| OsString::from("lsx"));
    let prog = prog.as_bytes();

    let mut opts = Options {
        path: OsString::from("."),
        show_hidden: false,
    };
    let mut path_set = false;
    let mut options_done = false;

    for arg in args {
        let bytes = arg.as_bytes();
        if !options_done {
            match bytes {
                b"--" => {
                    options_done = true;
                    continue;
                }
                b"-a" | b"--all" => {
                    opts.show_hidden = true;
                    continue;
                }
                b"-h" | b"--help" => {
                    return Err(write_stdout(|out| out.write_all(&usage(prog))));
                }
                [b'-', ..] => {
                    eprint_bytes(&[b"Unknown option: ", bytes, b"\n", &usage(prog)]);
                    return Err(ExitCode::from(2));
                }
                _ => {}
            }
        }
        if path_set {
            eprint_bytes(&[b"Unexpected argument: ", bytes, b"\n"]);
            return Err(ExitCode::from(2));
        }
        opts.path = arg;
        path_set = true;
    }
    Ok(opts)
}

/// Extension key per spec §5: from the last '.' (inclusive) to the end, or
/// empty when there is no '.' or the only candidate is a leading dot.
fn extension(name: &[u8]) -> &[u8] {
    match name.iter().rposition(|&b| b == b'.') {
        Some(i) if i > 0 => &name[i..],
        _ => b"",
    }
}

type Groups = BTreeMap<Vec<u8>, Vec<Vec<u8>>>;

/// Scans the directory per spec §3–§4, reporting any fatal error to stderr.
fn scan(opts: &Options) -> Result<Groups, ()> {
    let path = Path::new(&opts.path);
    let path_bytes = opts.path.as_bytes();

    match fs::metadata(path) {
        Err(e) => {
            let reason = os_reason(&e);
            eprint_bytes(&[
                b"Error: cannot access path: ",
                path_bytes,
                b": ",
                reason.as_bytes(),
                b"\n",
            ]);
            return Err(());
        }
        Ok(meta) if !meta.is_dir() => {
            eprint_bytes(&[b"Error: not a directory: ", path_bytes, b"\n"]);
            return Err(());
        }
        Ok(_) => {}
    }

    let entries = fs::read_dir(path).map_err(|e| {
        let reason = os_reason(&e);
        eprint_bytes(&[
            b"Error opening directory: ",
            path_bytes,
            b": ",
            reason.as_bytes(),
            b"\n",
        ]);
    })?;

    let mut groups = Groups::new();
    for entry in entries {
        let entry = entry.map_err(|e| {
            let reason = os_reason(&e);
            eprint_bytes(&[
                b"Error reading directory: ",
                path_bytes,
                b": ",
                reason.as_bytes(),
                b"\n",
            ]);
        })?;

        let name = entry.file_name();
        let name = name.as_bytes();
        if name == b"." || name == b".." {
            continue;
        }
        if !opts.show_hidden && name.starts_with(b".") {
            continue;
        }
        // fs::metadata follows symlinks; DirEntry::metadata would not (spec §9.4).
        match fs::metadata(path.join(OsStr::from_bytes(name))) {
            Ok(meta) if meta.is_file() => {}
            _ => continue,
        }
        groups
            .entry(extension(name).to_vec())
            .or_default()
            .push(name.to_vec());
    }

    for names in groups.values_mut() {
        names.sort_unstable();
    }
    Ok(groups)
}

/// Streams the listing per spec §7, so no second copy of it is held in memory.
fn render(groups: &Groups, out: &mut impl Write) -> io::Result<()> {
    for (ext, names) in groups {
        if ext.is_empty() {
            out.write_all(b"No Extension")?;
        } else {
            out.write_all(&ext[1..])?;
        }
        out.write_all(b":\n")?;
        for name in names {
            out.write_all(b"- ")?;
            out.write_all(name)?;
            out.write_all(b"\n")?;
        }
        out.write_all(b"\n")?;
    }
    Ok(())
}

/// Runs `f` against a buffered stdout and flushes it. A write failure exits 1;
/// a closed pipe (e.g. `lsx | head`) does so quietly, like a SIGPIPE'd C program.
fn write_stdout(f: impl FnOnce(&mut io::BufWriter<io::StdoutLock>) -> io::Result<()>) -> ExitCode {
    let mut out = io::BufWriter::new(io::stdout().lock());
    match f(&mut out).and_then(|()| out.flush()) {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) if e.kind() == io::ErrorKind::BrokenPipe => ExitCode::FAILURE,
        Err(e) => {
            let reason = os_reason(&e);
            eprint_bytes(&[b"Error writing output: ", reason.as_bytes(), b"\n"]);
            ExitCode::FAILURE
        }
    }
}

fn main() -> ExitCode {
    let opts = match parse_args() {
        Ok(opts) => opts,
        Err(code) => return code,
    };
    let Ok(groups) = scan(&opts) else {
        return ExitCode::FAILURE;
    };
    write_stdout(|out| render(&groups, out))
}

#[cfg(test)]
mod tests {
    use super::extension;

    #[test]
    fn extension_table() {
        let cases: &[(&[u8], &[u8])] = &[
            (b"notes", b""),
            (b".bashrc", b""),
            (b"a.txt", b".txt"),
            (b"archive.tar.gz", b".gz"),
            (b".hidden.md", b".md"),
            (b"..foo", b".foo"),
            (b"foo.", b"."),
            (b"x..", b"."),
            (b"...", b"."),
            (b"A.JPG", b".JPG"),
        ];
        for (name, want) in cases {
            assert_eq!(
                extension(name),
                *want,
                "name {}",
                String::from_utf8_lossy(name)
            );
        }
    }
}
