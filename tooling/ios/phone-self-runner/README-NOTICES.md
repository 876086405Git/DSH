# Native third-party notices

`build-phone-self-runner.sh` uses `cargo metadata --locked --format-version 1`
without `--no-deps` or a platform filter, then collects every returned package.
This includes dependency/build tooling present in that graph, even if a package
does not contribute bytes to a particular architecture. The locked graph, not a
fixed package-count claim, determines the inventory. A missing source text fails
the build before it publishes the enabling xcconfig.

`license_inventory.py` collects LICENSE/LICENCE, COPYING, NOTICE, COPYRIGHT,
AUTHORS, PATENT(S), declared license-file paths, and files inside licenses or
licences directories, including nested source notices. It preserves the original
UTF-8 bytes, line endings and copyright statements. It does not replace all MIT
packages with one generic paragraph. It rejects empty, binary, symlinked or
oversized files; a text is limited to 2 MiB before reading its full contents.

Automatic filename discovery excludes common source-code suffixes, including
`src/license.rs` and `notice.rs`; these cannot supply otherwise-missing license
coverage just because their stems match. This also applies inside licenses
directories. Text suffixes and multiple-license names such as `LICENSE-MIT.md`,
`LICENSE.APACHE` and `COPYING.LESSER` remain eligible, as do actual notice files
under source directories. Explicit Cargo `license_file` paths and pinned
supplement inputs retain their existing path, regular-file, text and hash
checks. This is a filename heuristic, not semantic classification of file
contents. Existing frozen NOTICES artifacts are not rewritten by this change.

The generated `NOTICES.txt` labels each package and original filename, records
the authors declared by Cargo, and reproduces all collected texts. The sanitized
`THIRD_PARTY_CRATES.json` additionally records the complete document's SHA-256 and
every original's offset, byte length and SHA-256. No raw Cargo metadata or local
manifest path is copied into the packaged notices. The collection is deterministic
for identical metadata identities and source bytes.

The resource phase embeds exactly `LICENSE.idevice.txt`, `SOURCE.json`,
`THIRD_PARTY_CRATES.json`, and `NOTICES.txt` in `PhoneSelfRunnerNotices`.
`check-archive.sh` requires all four nonempty files and invokes the same verifier
to check the source pin, package identities, exact package coverage, document
identity and every original byte range. These checks detect missing or changed
notice artifacts relative to their inventory; a hash manifest is not a signature
or a proof of the upstream legal status.

## Explicit pinned supplements

Two published packages lack a complete license file in their crate archives.
Exceptions are narrow and bound in `notice-supplements.json` to the exact
package version, `Cargo.toml.orig` hash, published VCS commit, declared license
and each supplemental document's hash. A dependency update must re-evaluate the
exception; it cannot silently inherit another version's notice.

- `ns-keyed-archive 0.1.5` declares `MIT OR Apache-2.0`. Its published commit is
  `f8cec65e865cb48301d33b2244bec45a2f3d2bc2`. The upstream tree
  `1814f8c12537f5c89e96b579e855c1ee86fbf22b` adds full MIT and Apache originals;
  the shared Rust and Cargo files have the same Git blob identities. We preserve
  both originals, the published manifest and its README attribution. Immutable
  upstream blob URLs and hashes are in the supplement record.
- `plist-macro 0.1.6`, commit `d1d48559ddc8e9bd263f36180bbe1d4f2a3d55e5`,
  declares MIT and names its author in the published manifest, but its published
  archive and checked upstream tree have no separate copyright/license notice.
  We preserve its actual manifest and README, a clearly labeled source-gap note,
  and the unmodified standard MIT text from SPDX v3.27.0 commit
  `d46e94e2c78ceede1cfc63cfa0396472d2798d4c`. The standard template's placeholders
  are not presented as an upstream copyright statement. **The missing upstream
  copyright notice remains a source gap.** Resolving it requires an authoritative
  notice for this version; this tool does not invent a year or borrow another
  repository's copyright line.

This documents the available original texts and the two explicit supplements;
it does not certify that every transitive source file contains no additional
attribution obligation. Notices with nonstandard filenames need an explicit
reviewed `license_file` or pinned supplement. The app's other native/Flutter/Node
dependencies are outside this Cargo collector's scope.

## Verification

```sh
python3 -I -B tooling/ios/phone-self-runner/tests/test_build_inputs.py -v
python3 -I -B tooling/ios/tests/phone-self-runner.test.py -v
python3 -I -B tooling/ios/phone-self-runner/license_inventory.py \
  --verify app/ios/PhoneSelfRunnerNative
```

Portable tests run the real collection and verifier, the real build script with
synthetic compilers, and the real resource-copy script with synthetic files.
They exercise original-byte preservation, nested notices, complete coverage,
tamper rejection, exact supplement binding and failure before publication.
Synthetic compiler output is not an Apple archive. Run the actual native build,
Xcode resource phase and archive gate on the Mac before claiming IPA validation.
