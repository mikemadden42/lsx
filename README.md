# lsx

List the regular files in one directory, grouped by extension.

```
lsx [-a|--all] [-h|--help] [--] [path]
```

Rust port of [`refine`](https://github.com/mikemadden42/refine). File names
are handled as raw bytes, so non-UTF-8 names print unchanged.

## Build and test

```sh
cargo build --release
cargo test
sh tests/run_tests.sh            # defaults to target/release/lsx
```
