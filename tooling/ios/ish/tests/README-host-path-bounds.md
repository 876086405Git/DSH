# Patched host path bounds regression

`../test-host-path-bounds.py` is an offline Linux host unit regression for the
pinned iSH path changes. It runs 45 cases at each synthetic host capacity,
`PATH_MAX=1024` and `PATH_MAX=4096`. The guest path constant remains
`MAX_PATH=4096` in both configurations. **The 1024 configuration is a synthetic
capacity test on Linux; it is not an Apple build or Apple execution.**

## Run

From the repository root, use an existing local copy of the pinned source archive:

```sh
python3 tooling/ios/ish/test-host-path-bounds.py \
  --archive /absolute/path/c5c264da19148512167aa493d7bd4e50aae1b74e.tar.gz \
  --evidence-dir /absolute/path/host-path-test-evidence
```

The runner needs Python 3, a local Linux C compiler (`cc` by default), `patch`,
and enough free space for a fresh extraction. `--cc /path/to/compiler` selects a
compiler executable. It does not accept a shell command or extra compiler flags.
If `--archive` is omitted, the runner checks the normal iSH cache path from
`build.py`. It never downloads a missing archive. Omitting `--evidence-dir` uses
an automatically removed temporary directory. Prefer scratch storage over a
space-constrained RAM filesystem for retained extractions.

Optional `--compare-source /absolute/path/to/candidate-functions` additionally
requires the freshly patched full `fake.c`, `real.c`, and `path.c` files to be
byte-identical to that directory's files. Those files are comparison evidence;
they are never the source of compiled functions.

Every command in a retained run has an exit code and separate stdout/stderr logs
in `receipt.json`. The receipt also records the repository HEAD, compiler, archive
pin, input hashes, freshly patched file hashes, extracted function hashes, test
results, and the checks that repository inputs still matched at the end. An
invocation succeeds only when both compilations and both test executions exit 0.

## Source binding and execution boundary

The archive is pinned independently of the patch being tested:

| Field | Required value |
| --- | --- |
| iSH commit | `c5c264da19148512167aa493d7bd4e50aae1b74e` |
| Archive bytes | `3025227` |
| Archive SHA256 | `046e17769c9978e21060d465c0610a27a033dba2af92f58f42e7d8bcb6bb36ad` |

The runner verifies this pin against `source.lock.json`, checks the archive bytes
and digest, calls `build.py.extract_source` to validate and freshly extract the
archive, checks every locked build input, and then applies snapshots of
`build.patch` and `job-runtime.patch` in that order with
`patch --batch --fuzz=0 -p1`. No original, unpatched implementation is compiled or
executed.

The complete definitions of `fakefs_mount`, `fakefs_readdir`, Linux `getpath`,
`__path_normalize`, and its pure helper `path_is_normalized` are extracted from
those patched files. A brace scanner skips comments and string/character
literals. Definition bytes, including comments, are copied without rewriting
into a generated header. `#line` directives preserve source locations. The
header redirects libc `readlink` around `getpath` only; filesystem callback
members retain their original names. A recording `strcat` adapter observes
whether concatenation was reached. Known guard text and its ordering are
checked before compilation as a patched-only execution prerequisite. These
source checks are separate from the behavioral oracle.

The fixture supplies minimal structs and recording adapters for mounting,
metadata initialization, directory iteration, path lookup, bind translation,
metadata transactions, inode lookup, mount acquisition/release, stat, access
checks, and readlink. It verifies the constants it models against the pinned
headers. All long paths are memory strings. No tested iSH function opens a real
directory, database, descriptor, device, or network connection. The Python
runner performs ordinary local archive/source/log I/O and invokes the local
compiler and patch tool; the C executable does not call host filesystem services.

This is function-level validation with modeled dependencies. Apple compilation,
complete iSH execution, N-API, real filesystem/database behavior, device tests,
and full guest initialization remain **UNRUN**.

## Independent expectations

The fixture's expected results come from these byte budgets and directory
protocol rules. They are literal tables in the fixture, not values calculated by
the tested implementation.

### Mount source and metadata path — 11 cases

A valid source ends in the component `data` after a slash. Its prefix includes
that slash. The replacement `meta.db` occupies 7 bytes plus a terminating NUL.
The existing source can fit while its metadata sibling cannot.

| Host capacity | Prefix bytes | Metadata bytes including NUL | Expected result |
| ---: | ---: | ---: | --- |
| 1024 | 1016 | 1024 | Success, one mount and one DB-init call |
| 1024 | 1017 | 1025 | `_ENAMETOOLONG`, neither adapter called |
| 4096 | 4088 | 4096 | Success, one mount and one DB-init call |
| 4096 | 4089 | 4097 | `_ENAMETOOLONG`, neither adapter called |

The normal `/fixture/root/data` case records `/fixture/root/meta.db`. Six malformed
cases cover a missing slash, an empty source, a different terminal component, a
trailing slash, an empty final component, and `database`. They return `_EINVAL`
before either adapter. Separate cases preserve underlying mount/DB-init errors
and verify that a failed operation does not publish `g_fakefs_mount`.

### Directory entries — 18 cases

Directory iteration returns **1** for an entry, **0** for EOF, and a negative
error on failure. A successful `getpath` returns 0 and must not overwrite the
iteration success value. A failing `getpath` must return immediately, before
concatenation, translation, or database lookup. Tests cover both `-1` and `_EIO`.

`entry_path` has 4097 bytes (`MAX_PATH + 1`), independently of the synthetic host
capacity. An ordinary entry needs `directory + '/' + filename + NUL`:

| Directory bytes | Filename bytes | Required bytes including NUL | Expected result |
| ---: | ---: | ---: | --- |
| 4094 | 1 | 4097 | Return 1 and record the complete metadata path |
| 4095 | 1 | 4098 | `_ENAMETOOLONG`, no concatenation or metadata lookup |
| 3840 | 255 | 4097 | Return 1 and record the complete metadata path |
| 3841 | 255 | 4098 | `_ENAMETOOLONG`, no concatenation or metadata lookup |

`.` retains the directory path; `..` removes one component. Both are tested in a
nested directory and at the empty internal root path. Hook-backed entries retain
the host inode. Missing metadata retries the next entry and can reach either a
visible entry or EOF. Bind metadata can supply the inode or leave the retry in
place. Transaction adapters also check balanced begin/commit calls.

### Linux descriptor spelling — 3 cases

`getpath(0)` must pass `/proc/self/fd/0` to the recording readlink adapter.
`getpath(INT_MAX)` must pass `/proc/self/fd/2147483647`; the fixture explicitly
requires a 32-bit `int`. Readlink receives capacity 4095. A successful reply is
terminated at the returned byte count, and a failing readlink returns -1. No high
file descriptor is opened and `/proc` is not read.

### Symlink expansion and release protocol — 13 cases

The guest output/expansion capacity is 4096 bytes in both host configurations.
A readlink reply needs one additional byte for NUL. When readlink fills its entire
offered capacity, the function must reject it before writing that terminator.

| Input | Readlink reply bytes | Offered capacity | Expected result | Releases |
| --- | ---: | ---: | --- | ---: |
| `/link` | 4095 | 4095 | `_ENAMETOOLONG` | 1 |
| `/base/link` | 4090 | 4090 | `_ENAMETOOLONG` | 2 |

For expansion with the remainder `x`, a new slash and NUL take two more bytes.
An absolute target replaces the prefix. A relative target retains `/base/`
(6 bytes):

| Form | Target bytes | Expanded bytes including NUL | Expected result | Releases |
| --- | ---: | ---: | --- | ---: |
| Absolute `/link/x` | 4093 | 4096 | Success, `/root/x` | 3 |
| Absolute `/link/x` | 4094 | 4097 | `_ENAMETOOLONG` | 1 |
| Relative `/base/link/x` | 4087 | 4096 | Success, `/base/dest/x` | 5 |
| Relative `/base/link/x` | 4088 | 4097 | `_ENAMETOOLONG` | 2 |

These boundary targets contain repeated separators after a short `/root` or
`dest` prefix. Normalization reduces those separators, so the test isolates the
expansion append budget from the component walker's existing conservative output
length limit. This is a synthetic buffer boundary, not a real deep filesystem.
Rejected expansions reach no `strcat`; successful expansions reach exactly two.
All cases check balanced mount acquisition/release and unchanged bytes around
the output buffer.

Other cases cover ordinary relative and absolute targets, terminal nofollow,
`_ELOOP` at the recursion limit, `_ENOTDIR`, and access-check `_EACCES`. An `_EINVAL`
readlink probe on a regular component retains the existing non-symlink behavior.
The fixture does not claim that every negative readlink probe is propagated as
an error by the existing normalizer.

## Backend preflight: source proof only

`guest_backend.c` is inspected without compiling or executing
`dsh_guest_initialize`. `backend-capacity-review.json` records its exact
`PATH_MAX` declaration, root-length rejection block, `/data` append, and the full
source digest in the receipt. The gate must precede the append.

The reserved `/meta.db` suffix is 8 bytes plus NUL. `/data` is 5 bytes plus NUL.
Therefore these independent budgets apply:

| Host capacity | Largest accepted root length | Root + `/meta.db` + NUL | Root + `/data` + NUL | Next root's metadata bytes |
| ---: | ---: | ---: | ---: | ---: |
| 1024 | 1015 | 1024 | 1021 | 1025 |
| 4096 | 4087 | 4096 | 4093 | 4097 |

This proves the observed length gate reserves the metadata sibling's buffer
budget. It is explicitly **SOURCE_REVIEW_ONLY_NOT_EXECUTED** and does not validate
realpath, mutex behavior, crash records, full initialization, or kernel entry.
