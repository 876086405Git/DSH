"""Exercise the production shell download path with deterministic local transport failures."""
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "build-runtime.sh"


class RuntimeFetchTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.cache = self.root / "cache"
        self.locks = self.root / "locks"
        self.locks.mkdir()
        self.dest = self.cache / "payload.deb"
        self.payload = "locked fixture bytes\n"
        self.sha = self.digest(self.payload)
        self.primary = "https://mirror.invalid/pool/payload.deb"
        self.backup = "https://archive.invalid/payload.deb"
        self.store = "https://store.invalid/runtime"
        self.routes = {}
        curl = self.bin / "curl"
        curl.write_text('''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
root = Path(os.environ["FETCH_TEST_ROOT"])
url = sys.argv[-1]
with (root / "calls.jsonl").open("a") as log:
    log.write(json.dumps(url) + "\\n")
routes = json.loads((root / "routes.json").read_text())
status, body = routes.get(url, [22, "unmapped URL"])
Path(sys.argv[sys.argv.index("-o") + 1]).write_text(body)
sys.exit(status)
''')
        curl.chmod(0o755)

    @staticmethod
    def digest(body):
        return hashlib.sha256(body.encode()).hexdigest()

    def run_shell(self, entry, extra_env=None):
        source, marker, suffix = SCRIPT.read_text().rpartition('\nmain "$@"')
        self.assertTrue(marker and not suffix.strip(), "only omit the final build entrypoint")
        harness = self.root / "exercise.sh"
        harness.write_text(source + '\nCACHE="$FETCH_TEST_ROOT/cache"\n'
                           'LOCKS="$FETCH_TEST_ROOT/locks"\n' + entry + '\n')
        (self.root / "routes.json").write_text(json.dumps(self.routes))
        env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ["PATH"],
                   FETCH_TEST_ROOT=str(self.root), RUNTIME_LAYERS="0", UPDATE_DEB_LOCK="0",
                   UBUNTU_EXTRA="tzdata ca-certificates git", RUNTIME_INPUT_STORE_URL="")
        env.update(extra_env or {})
        return subprocess.run(["bash", str(harness)], env=env, text=True,
                              capture_output=True, timeout=15)

    def fetch_entry(self, expected=None, conditional=False):
        expected = self.sha if expected is None else expected
        call = 'fetch "$PRIMARY" "$FETCH_TEST_ROOT/cache/payload.deb" "$EXPECTED" "$BACKUP"'
        if conditional:
            call = 'if ' + call + '; then printf "published"; fi'
        return call, dict(PRIMARY=self.primary, BACKUP=self.backup, EXPECTED=expected)

    def fetch(self, expected=None, conditional=False, extra_env=None):
        entry, env = self.fetch_entry(expected, conditional)
        env.update(extra_env or {})
        return self.run_shell(entry, env)

    def calls(self):
        path = self.root / "calls.jsonl"
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def npm_fixture(self, kind, locked=True):
        package = "@deepseek-ai/dsh" if kind == "dsh" else "pnpm"
        version = "9.9.9-fixture"
        integrity = "sha512-" + "A" * 86 + "=="
        lock = dict(name="fixture", version="1.0.0", lockfileVersion=3, packages={
            "": dict(dependencies={package: version}),
            "node_modules/" + package: dict(version=version, integrity=integrity,
                                            resolved=f"https://registry.invalid/{kind}.tgz"),
        })
        lockdir = self.locks / f"{kind}-{version}"
        if locked:
            lockdir.mkdir(exist_ok=True)
            (lockdir / "package.json").write_text(json.dumps(lock["packages"][""]))
            (lockdir / "package-lock.json").write_text(json.dumps(lock))
        (self.root / "fixture-lock.json").write_text(json.dumps(lock))
        npm = self.bin / "npm"
        npm.write_text('''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
root = Path(os.environ["FETCH_TEST_ROOT"])
with (root / "npm-events.jsonl").open("a") as log:
    log.write(json.dumps(dict(kind="npm", args=sys.argv[1:])) + "\\n")
prefix = Path(sys.argv[sys.argv.index("--prefix") + 1])
if sys.argv[1] == "install":
    lock = json.loads((root / "fixture-lock.json").read_text())
    (prefix / "package-lock.json").write_text(json.dumps(lock))
    (prefix / "package.json").write_text(json.dumps(lock["packages"][""]))
else:
    lock = json.loads((prefix / "package-lock.json").read_text())
for path, package in lock["packages"].items():
    if path:
        dest = prefix / path / "package.json"
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_text(json.dumps(dict(version=package["version"])))
''')
        npm.chmod(0o755)
        helper = self.root / "lib/input_store.py"
        helper.parent.mkdir(exist_ok=True)
        helper.write_text('''import json, os, sys
from pathlib import Path
root = Path(os.environ["FETCH_TEST_ROOT"])
args = dict(zip(sys.argv[2::2], sys.argv[3::2]))
with (root / "npm-events.jsonl").open("a") as log:
    log.write(json.dumps(dict(kind="warm", command=sys.argv[1], args=args,
        emptyConfigs=all(Path(args[key]).read_bytes() == b"" for key in
                         ("--userconfig", "--globalconfig")))) + "\\n")
if os.environ.get("WARM_FAIL") == "1":
    sys.exit("fixture warm failure")
print('{"ok": true}')
''')
        entry = ('mkdir -p "$WORK"\n'
                 'host_npm() { printf "%s" "$FETCH_TEST_ROOT/bin"; }\n'
                 f'install_{kind} x64 "$FETCH_TEST_ROOT/prefix-{kind}"')
        env = dict(DSH_VERSION=version, PNPM_VERSION=version, PNPM_INTEGRITY=integrity)
        return entry, env, lockdir, helper

    def npm_events(self):
        path = self.root / "npm-events.jsonl"
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def deb_inputs_entry(self):
        source = SCRIPT.read_text()
        start = source.index('  ubuntu_extra_debs "$ubuntu_arch" "$base"')
        end = source.index('  local python;', start)
        # Exercise the shipped caller too: redirect, read the list, reject empty.
        return ('exercise() {\n'
                '  local ubuntu_arch="$TEST_ARCH" base=/unused-base work="$FETCH_TEST_ROOT/work"\n'
                '  mkdir -p "$work"\n' + source[start:end]
                + '  printf "%s\\n" "${extra_debs[@]}"\n}\nexercise')

    def host_node_fixture(self):
        if os.name != "posix" or os.uname().machine != "x86_64":
            self.skipTest("host Node extraction uses an x86_64 Linux host")
        dist = self.cache / "node/vfixture"
        dist.mkdir(parents=True)
        archive = dist / "node-vfixture-linux-x64.tar.xz"
        bodies = {"node": b"lookup-only node fixture\n", "npm": b"lookup-only npm fixture\n" + b"x" * 4096}
        with tarfile.open(archive, "w:xz") as tar:
            for name, body in bodies.items():
                entry = tarfile.TarInfo("node-vfixture-linux-x64/bin/" + name)
                entry.mode = 0o755
                entry.size = len(body)
                tar.addfile(entry, io.BytesIO(body))
        sha = hashlib.sha256(archive.read_bytes()).hexdigest()
        (dist / "SHASUMS256.txt").write_text(f"{sha}  {archive.name}\n")
        host = self.cache / "host-node"
        host.mkdir()
        return host, bodies

    def test_verified_cache_needs_no_network(self):
        self.cache.mkdir()
        self.dest.write_text(self.payload)
        result = self.fetch(extra_env={"RUNTIME_INPUT_STORE_URL": self.store})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls(), [])

    def test_primary_success_does_not_call_backup(self):
        self.routes[self.primary] = [0, self.payload]
        result = self.fetch()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.dest.read_text(), self.payload)
        self.assertEqual(self.calls(), [self.primary])

    def test_transport_failure_uses_backup_with_same_checksum(self):
        self.routes = {self.primary: [22, "partial"], self.backup: [0, self.payload]}
        result = self.fetch()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.dest.read_text(), self.payload)
        self.assertEqual(self.calls(), [self.primary, self.backup])

    def test_all_transports_fail_even_when_called_in_condition(self):
        self.routes = {self.primary: [22, "partial"], self.backup: [22, "also partial"]}
        result = self.fetch(expected="", conditional=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("published", result.stdout)
        self.assertFalse(self.dest.exists())
        self.assertEqual(self.calls(), [self.primary, self.backup])

    def test_wrong_primary_checksum_is_fatal_without_backup(self):
        self.routes = {self.primary: [0, "wrong bytes"], self.backup: [0, self.payload]}
        result = self.fetch()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("sha256 mismatch", result.stderr)
        self.assertFalse(self.dest.exists())
        self.assertEqual(self.calls(), [self.primary])

    def test_wrong_backup_checksum_is_fatal(self):
        self.routes = {self.primary: [22, "partial"], self.backup: [0, "wrong bytes"]}
        result = self.fetch()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("sha256 mismatch", result.stderr)
        self.assertFalse(self.dest.exists())
        self.assertEqual(self.calls(), [self.primary, self.backup])

    def test_store_is_last_fallback_and_only_for_expected_digest(self):
        cas = f"{self.store}/sha256-{self.sha}"
        self.routes = {self.primary: [22, "partial"], self.backup: [22, "partial"],
                       cas: [0, self.payload]}
        result = self.fetch(extra_env={"RUNTIME_INPUT_STORE_URL": self.store + "/"})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls(), [self.primary, self.backup, cas])
        self.assertEqual(self.dest.read_text(), self.payload)
        self.assertFalse(self.dest.with_suffix(".deb.part").exists())
        self.dest.unlink()
        before = len(self.calls())
        result = self.fetch(expected="", extra_env={"RUNTIME_INPUT_STORE_URL": self.store})
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.calls()[before:], [self.primary, self.backup])
        self.assertFalse(self.dest.exists())

    def test_checksum_mismatch_never_falls_through_to_store(self):
        cas = f"{self.store}/sha256-{self.sha}"
        for primary_status in (0, 22):
            with self.subTest(primary_status=primary_status):
                self.routes = {self.primary: [primary_status, "wrong bytes"],
                               self.backup: [0, "wrong bytes"], cas: [0, self.payload]}
                before = len(self.calls())
                result = self.fetch(extra_env={"RUNTIME_INPUT_STORE_URL": self.store})
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("sha256 mismatch", result.stderr)
                self.assertFalse(self.dest.exists())
                expected = [self.primary] + ([self.backup] if primary_status else [])
                self.assertEqual(self.calls()[before:], expected)

    def test_wrong_store_bytes_are_not_published(self):
        cas = f"{self.store}/sha256-{self.sha}"
        self.routes = {self.primary: [22, "partial"], self.backup: [22, "partial"],
                       cas: [0, "wrong bytes"]}
        result = self.fetch(extra_env={"RUNTIME_INPUT_STORE_URL": self.store})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("sha256 mismatch", result.stderr)
        self.assertEqual(self.calls(), [self.primary, self.backup, cas])
        self.assertFalse(self.dest.exists())
        self.assertFalse(self.dest.with_suffix(".deb.part").exists())

    def test_failed_transports_remove_partial_download(self):
        self.routes = {self.primary: [22, "partial"], self.backup: [22, "partial"]}
        result = self.fetch(conditional=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.dest.exists())
        self.assertFalse(self.dest.with_suffix(".deb.part").exists())

    def test_unconfigured_store_is_explicit_only_when_fallback_is_needed(self):
        self.routes[self.primary] = [0, self.payload]
        result = self.fetch()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("自留回落不可用", result.stderr)
        self.dest.unlink()
        self.routes = {self.primary: [22, "missing"], self.backup: [22, "missing"]}
        result = self.fetch()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("自留回落不可用", result.stderr)
        self.assertIn("RUNTIME_INPUT_STORE_URL", result.stderr)
        self.assertEqual(self.calls(), [self.primary, self.primary, self.backup])

    def test_download_is_checked_before_publication(self):
        move = self.bin / "mv"
        move.write_text('''#!/usr/bin/env python3
import os, sys
from pathlib import Path
Path(os.environ["FETCH_TEST_ROOT"], "moved").write_text("published")
os.replace(sys.argv[1], sys.argv[2])
''')
        move.chmod(0o755)
        self.routes[self.primary] = [0, "wrong bytes"]
        result = self.fetch()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("sha256 mismatch", result.stderr)
        self.assertFalse((self.root / "moved").exists())
        self.assertFalse(self.dest.exists())

    def test_file_store_uses_real_local_transport(self):
        if shutil.which("curl") is None:
            self.skipTest("curl is a production host prerequisite")
        (self.bin / "curl").unlink()
        store = self.root / "store with spaces"
        store.mkdir()
        (store / f"sha256-{self.sha}").write_text(self.payload)
        result = self.fetch(extra_env=dict(PRIMARY=(self.root / "missing-primary").as_uri(),
                                           BACKUP="", RUNTIME_INPUT_STORE_URL=store.as_uri()))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.dest.read_text(), self.payload)

    def test_store_requires_explicit_https_or_local_file_url(self):
        for store in ("http://store.invalid", "ftp://store.invalid", "relative/store"):
            with self.subTest(store=store):
                result = self.fetch(extra_env={"RUNTIME_INPUT_STORE_URL": store})
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("RUNTIME_INPUT_STORE_URL", result.stderr)
                self.assertEqual(self.calls(), [])

    def test_pinned_distributions_do_not_require_live_checksum_lists(self):
        cases = []
        for arch in ("arm64", "amd64"):
            name = f"ubuntu-base-24.04.5-base-{arch}.tar.gz"
            cases.append((f"ubuntu_base {arch}", name,
                          f"https://mirrors.tuna.tsinghua.edu.cn/ubuntu-cdimage/ubuntu-base/releases/24.04/release/{name}", None))
        for arch in ("arm64", "x64"):
            name = f"node-v24.22.1-linux-{arch}.tar.xz"
            cases.append((f"node_dist {arch}", name,
                          f"https://npmmirror.com/mirrors/node/v24.22.1/{name}", None))
        for arch in ("aarch64", "x86_64"):
            name = f"cpython-3.12.15+20261021-{arch}-unknown-linux-gnu-install_only_stripped.tar.gz"
            cases.append((f"python_dist {arch}", name,
                          f"https://registry.npmmirror.com/-/binary/python-build-standalone/20261021/{name}",
                          f"https://github.com/astral-sh/python-build-standalone/releases/download/20261021/{name}"))
        for call, name, primary, backup in cases:
            with self.subTest(call=call):
                cas = f"{self.store}/sha256-{self.sha}"
                self.routes = {primary: [22, "missing"], cas: [0, self.payload]}
                if backup:
                    self.routes[backup] = [22, "missing"]
                before = len(self.calls())
                entry = f'PIN["$TEST_NAME"]="$EXPECTED"\nvalue="$({call})"\nprintf "%s" "$value"'
                result = self.run_shell(entry, dict(TEST_NAME=name, EXPECTED=self.sha,
                    UBUNTU_VERSION="24.04.5", NODE_VERSION="24.22.1", PYTHON_VERSION="3.12.15",
                    PBS_RELEASE="20261021", RUNTIME_INPUT_STORE_URL=self.store))
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(Path(result.stdout).read_text(), self.payload)
                self.assertEqual(self.calls()[before:], [primary] + ([backup] if backup else []) + [cas])

    def test_pinned_termux_inputs_do_not_require_live_package_index(self):
        for pkg, version, pool in (("proot", "5.1.107.102", "p"),
                                   ("libtalloc", "2.5.0", "libt"),
                                   ("libandroid-shmem", "0.7", "liba")):
            for arch in ("aarch64", "x86_64"):
                with self.subTest(pkg=pkg, arch=arch):
                    name = f"{pkg}_{version}_{arch}.deb"
                    primary = f"https://packages.termux.dev/apt/termux-main/pool/main/{pool}/{pkg}/{name}"
                    cas = f"{self.store}/sha256-{self.sha}"
                    self.routes = {primary: [22, "404"], cas: [0, self.payload]}
                    before = len(self.calls())
                    entry = ('PIN["$TEST_NAME"]="$EXPECTED"\n'
                             f'value="$(termux_deb {pkg} {version} {arch})"\nprintf "%s" "$value"')
                    result = self.run_shell(entry, dict(TEST_NAME=name, EXPECTED=self.sha,
                                                       RUNTIME_INPUT_STORE_URL=self.store))
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(Path(result.stdout).read_text(), self.payload)
                    self.assertEqual(self.calls()[before:], [primary, cas])

    def test_unknown_overrides_still_resolve_original_metadata(self):
        mirror = "https://mirrors.tuna.tsinghua.edu.cn/ubuntu-cdimage/ubuntu-base/releases/24.04/release"
        name = "ubuntu-base-fixture-base-amd64.tar.gz"
        self.routes = {mirror + "/SHA256SUMS": [0, f"{self.sha}  {name}\n"],
                       mirror + "/" + name: [0, self.payload]}
        result = self.run_shell('value="$(ubuntu_base amd64)"\nprintf "%s" "$value"',
                                dict(UBUNTU_VERSION="fixture", RUNTIME_INPUT_STORE_URL=self.store))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls(), [mirror + "/SHA256SUMS", mirror + "/" + name])
        repo = "https://packages.termux.dev/apt/termux-main"
        index = repo + "/dists/stable/main/binary-x86_64/Packages"
        filename = "pool/main/f/fixture/fixture_1_x86_64.deb"
        self.routes = {index: [0, f"Package: fixture\nVersion: 1\nFilename: {filename}\nSHA256: {self.sha}\n\n"],
                       repo + "/" + filename: [0, self.payload]}
        before = len(self.calls())
        result = self.run_shell('value="$(termux_deb fixture 1 x86_64)"\nprintf "%s" "$value"',
                                {"RUNTIME_INPUT_STORE_URL": self.store})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls()[before:], [index, repo + "/" + filename])

    def test_configured_locked_npm_warms_same_cache_then_runs_offline(self):
        for kind in ("dsh", "pnpm"):
            with self.subTest(kind=kind):
                entry, env, lockdir, _ = self.npm_fixture(kind)
                original = (lockdir / "package-lock.json").read_bytes()
                env["RUNTIME_INPUT_STORE_URL"] = self.store
                before = len(self.npm_events())
                result = self.run_shell(entry, env)
                self.assertEqual(result.returncode, 0, result.stderr)
                events = self.npm_events()[before:]
                self.assertEqual([event["kind"] for event in events], ["warm", "npm"])
                warm, npm = events
                self.assertEqual(warm["command"], "warm-npm")
                self.assertTrue(warm["emptyConfigs"])
                self.assertEqual(warm["args"]["--lock"], str(lockdir / "package-lock.json"))
                self.assertEqual(warm["args"]["--store"], str(self.cache / "input-store"))
                self.assertEqual(warm["args"]["--mirror-base"], self.store)
                self.assertEqual(warm["args"]["--npm"], str(self.bin / "npm"))
                self.assertEqual(warm["args"]["--npm-cache"], str(self.cache / "npm"))
                self.assertEqual(npm["args"][0], "ci")
                self.assertIn("--offline", npm["args"])
                self.assertEqual(npm["args"][npm["args"].index("--cache") + 1], str(self.cache / "npm"))
                self.assertIn("--ignore-scripts", npm["args"])
                self.assertEqual((lockdir / "package-lock.json").read_bytes(), original)

    def test_unconfigured_locked_npm_needs_no_store_helper(self):
        for kind in ("dsh", "pnpm"):
            with self.subTest(kind=kind):
                entry, env, _, helper = self.npm_fixture(kind)
                helper.unlink()
                before = len(self.npm_events())
                result = self.run_shell(entry, env)
                self.assertEqual(result.returncode, 0, result.stderr)
                events = self.npm_events()[before:]
                self.assertEqual([event["kind"] for event in events], ["npm"])
                self.assertEqual(events[0]["args"][0], "ci")
                self.assertNotIn("--offline", events[0]["args"])

    def test_warm_failure_stops_before_npm_even_in_conditional_call(self):
        for kind in ("dsh", "pnpm"):
            with self.subTest(kind=kind):
                entry, env, _, _ = self.npm_fixture(kind)
                setup, call = entry.rsplit("\n", 1)
                env.update(RUNTIME_INPUT_STORE_URL=self.store, WARM_FAIL="1")
                before = len(self.npm_events())
                result = self.run_shell(setup + '\nif ' + call + '; then printf "published"; fi', env)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("fixture warm failure", result.stderr)
                self.assertNotIn("published", result.stdout)
                self.assertEqual([event["kind"] for event in self.npm_events()[before:]], ["warm"])

    def test_unlocked_override_retains_original_online_install(self):
        entry, env, lockdir, _ = self.npm_fixture("pnpm", locked=False)
        env["RUNTIME_INPUT_STORE_URL"] = self.store
        result = self.run_shell(entry, env)
        self.assertEqual(result.returncode, 0, result.stderr)
        events = self.npm_events()
        self.assertEqual([event["kind"] for event in events], ["npm"])
        self.assertEqual(events[0]["args"][0], "install")
        self.assertNotIn("--offline", events[0]["args"])
        self.assertTrue((lockdir / "package-lock.json").is_file())

    def assert_first_lock_retries(self, kind, fault):
        entry, env, lockdir, _ = self.npm_fixture(kind, locked=False)
        expected = (self.root / "fixture-lock.json").read_bytes()
        self.assertGreater(len(expected), 256)
        entry = 'PY=(python3 -I "$LOCK_TEST_RTBUILD")\n' + entry
        env.update(LOCK_TEST_RTBUILD=str(SCRIPT.parent / "lib/rtbuild.py"),
                   LOCK_TEST_DIR=str(lockdir), LOCK_TEST_FAULT=fault,
                   LOCK_TEST_CP=shutil.which("cp"), LOCK_TEST_MV=shutil.which("mv"))
        copy = self.bin / "cp"
        copy.write_text('''#!/usr/bin/env python3
import os, resource, signal, sys
from pathlib import Path
target = Path(sys.argv[-1])
directory = Path(os.environ["LOCK_TEST_DIR"])
if os.environ.get("LOCK_TEST_FAULT") == "copy" and (target == directory or target.parent == directory):
    # Only the real cp child is limited; npm has already produced complete inputs.
    resource.setrlimit(resource.RLIMIT_FSIZE, (256, 256))
    signal.signal(signal.SIGXFSZ, signal.SIG_IGN)
os.execv(os.environ["LOCK_TEST_CP"], ["cp", *sys.argv[1:]])
''')
        copy.chmod(0o755)
        move = self.bin / "mv"
        move.write_text('''#!/usr/bin/env python3
import os, sys
from pathlib import Path
if os.environ.get("LOCK_TEST_FAULT") == "rename" and Path(sys.argv[-1]).parent == Path(os.environ["LOCK_TEST_DIR"]):
    sys.exit(23)  # Rename failure boundary; no real disk-full claim.
os.execv(os.environ["LOCK_TEST_MV"], ["mv", *sys.argv[1:]])
''')
        move.chmod(0o755)
        before = len(self.npm_events())
        lock = lockdir / "package-lock.json"
        pending = lockdir / "package-lock.json.tmp"
        first = self.run_shell(entry, env)
        self.assertNotEqual(first.returncode, 0, first.stderr)
        self.assertFalse(lock.exists(), "a failed first copy must not select npm ci on retry")
        if fault == "copy":
            self.assertEqual(pending.stat().st_size, 256)
        else:
            self.assertEqual(first.returncode, 23)
            self.assertEqual(pending.read_bytes(), expected)
        env["LOCK_TEST_FAULT"] = ""
        retry = self.run_shell(entry, env)
        self.assertEqual(retry.returncode, 0, retry.stderr)
        self.assertEqual(lock.read_bytes(), expected)
        self.assertFalse(pending.exists())
        cached = self.run_shell(entry, env)
        self.assertEqual(cached.returncode, 0, cached.stderr)
        self.assertEqual(lock.read_bytes(), expected)
        events = self.npm_events()[before:]
        self.assertEqual([event["args"][0] for event in events], ["install", "install", "ci"])

    def test_first_lock_short_copy_can_retry_then_reuse_the_committed_pin(self):
        for kind in ("dsh", "pnpm"):
            with self.subTest(kind=kind):
                self.assert_first_lock_retries(kind, "copy")

    def test_first_lock_rename_failure_can_retry_then_reuse_the_committed_pin(self):
        for kind in ("dsh", "pnpm"):
            with self.subTest(kind=kind):
                self.assert_first_lock_retries(kind, "rename")

    def test_existing_locks_use_fixed_basename_for_both_architectures(self):
        for arch, mirror in (("amd64", "https://mirrors.tuna.tsinghua.edu.cn/ubuntu"),
                             ("arm64", "https://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports")):
            with self.subTest(arch=arch):
                packages = []
                expected_calls = []
                expected_paths = []
                for package_arch in ("all", arch):
                    name = f"fixture-{arch}_1_{package_arch}.deb"
                    filename = f"pool/main/f/fixture/{name}"
                    body = f"fixture for {arch} {package_arch}"
                    packages.append(dict(filename=filename, sha256=self.digest(body)))
                    primary = f"{mirror}/{filename}"
                    backup = f"https://launchpad.net/ubuntu/+archive/primary/+files/{name}"
                    self.routes.update({primary: [22, "404"], backup: [0, body]})
                    expected_calls.extend([primary, backup])
                    expected_paths.append(str(self.cache / "ubuntu" / "debs" / name))
                lock = self.locks / f"ubuntu-noble-{arch}.json"
                original = json.dumps(dict(want=["tzdata", "ca-certificates", "git"], packages=packages))
                lock.write_text(original)
                before = self.calls()
                result = self.run_shell(self.deb_inputs_entry(), {"TEST_ARCH": arch})
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.splitlines(), expected_paths)
                self.assertEqual(self.calls()[len(before):], expected_calls)
                self.assertEqual(lock.read_text(), original)

    def test_lock_reader_error_cannot_accept_a_partial_input_list(self):
        cached = self.cache / "ubuntu/debs/first_1_all.deb"
        cached.parent.mkdir(parents=True)
        cached.write_text(self.payload)
        packages = [dict(filename="pool/main/f/fixture/first_1_all.deb", sha256=self.sha),
                    dict(filename="pool/main/f/fixture/missing-hash_1_all.deb")]
        lock = self.locks / "ubuntu-noble-amd64.json"
        original = json.dumps(dict(want=["tzdata", "ca-certificates", "git"], packages=packages))
        lock.write_text(original)
        result = self.run_shell(self.deb_inputs_entry(), {"TEST_ARCH": "amd64"})
        self.assertIn("KeyError: 'sha256'", result.stderr)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertEqual(self.calls(), [])
        self.assertEqual(lock.read_text(), original)

    def test_failed_later_deb_fetch_stops_the_build_caller(self):
        packages = []
        urls = []
        for name in ("first_1_all.deb", "second_1_all.deb"):
            filename = f"pool/main/f/fixture/{name}"
            packages.append(dict(filename=filename, sha256=self.sha))
            urls.append(f"https://mirrors.tuna.tsinghua.edu.cn/ubuntu/{filename}")
        backup = "https://launchpad.net/ubuntu/+archive/primary/+files/second_1_all.deb"
        self.routes = {urls[0]: [0, self.payload], urls[1]: [22, "partial"], backup: [22, "partial"]}
        lock = self.locks / "ubuntu-noble-amd64.json"
        original = json.dumps(dict(want=["tzdata", "ca-certificates", "git"], packages=packages))
        lock.write_text(original)
        result = self.run_shell(self.deb_inputs_entry(), {"TEST_ARCH": "amd64"})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("download failed", result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertEqual(self.calls(), [*urls, backup])
        self.assertEqual(lock.read_text(), original)

    def test_host_node_extraction_failure_cannot_select_system_npm(self):
        host, _ = self.host_node_fixture()
        if os.geteuid() == 0:
            self.skipTest("root bypasses directory write permission failures")
        entry = 'bin="$(host_npm)"\nPATH="$bin:$PATH" command -v npm'
        host.chmod(0o500)
        try:
            result = self.run_shell(entry, {"NODE_VERSION": "fixture"})
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(result.stdout, "")
        finally:
            host.chmod(0o700)
        result = self.run_shell(entry, {"NODE_VERSION": "fixture"})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), str(host / "node-vfixture-linux-x64/bin/npm"))
        self.assertEqual(self.calls(), [])

    def test_interrupted_host_node_cache_is_reextracted_on_retry(self):
        host, bodies = self.host_node_fixture()
        entry = 'bin="$(host_npm)"\nprintf "%s" "$bin"'
        # The real tar writes node first, then hits the child shell's file-size
        # limit during npm. Prime a cache left by an interrupted previous build;
        # the recovery test does not require the new implementation to leave it.
        interrupted = self.run_shell('ulimit -f 1\ntar -xJf "$CACHE/node/vfixture/node-vfixture-linux-x64.tar.xz" '
                                     '-C "$CACHE/host-node"', {"NODE_VERSION": "fixture"})
        self.assertNotEqual(interrupted.returncode, 0)
        node = host / "node-vfixture-linux-x64/bin/node"
        npm = node.with_name("npm")
        self.assertTrue(os.access(node, os.X_OK))
        self.assertNotEqual(npm.read_bytes(), bodies["npm"])
        result = self.run_shell(entry, {"NODE_VERSION": "fixture"})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, str(node.parent))
        self.assertEqual(npm.read_bytes(), bodies["npm"])
        self.assertEqual(self.calls(), [])

    def test_complete_host_node_cache_is_reused(self):
        host, bodies = self.host_node_fixture()
        entry = 'bin="$(host_npm)"\nprintf "%s" "$bin"'
        result = self.run_shell(entry, {"NODE_VERSION": "fixture"})
        self.assertEqual(result.returncode, 0, result.stderr)
        # A cache hit must not extract again: this limit would interrupt npm.
        result = self.run_shell('ulimit -f 1\n' + entry, {"NODE_VERSION": "fixture"})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((host / "node-vfixture-linux-x64/bin/npm").read_bytes(), bodies["npm"])
        self.assertEqual(self.calls(), [])

    def test_failed_metadata_download_cannot_publish_from_command_substitution(self):
        name = "node-vfixture-linux-x64.tar.xz"
        checksums = "https://npmmirror.com/mirrors/node/vfixture/SHASUMS256.txt"
        self.routes = {checksums: [22, f"{self.sha}  {name}\n"],
                       f"https://npmmirror.com/mirrors/node/vfixture/{name}": [0, self.payload]}
        result = self.run_shell('NODE_VERSION=fixture\nvalue="$(node_dist x64)"\nprintf "published:%s" "$value"')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("published", result.stdout)
        self.assertEqual(self.calls(), [checksums])

    def test_python_mirror_still_falls_back_to_official(self):
        name = "cpython-fixture+fixture-x86_64-unknown-linux-gnu-install_only_stripped.tar.gz"
        official = "https://github.com/astral-sh/python-build-standalone/releases/download/fixture"
        primary = "https://registry.npmmirror.com/-/binary/python-build-standalone/fixture/" + name
        self.routes = {official + "/SHA256SUMS": [0, f"{self.sha}  {name}\n"],
                       primary: [22, "partial"], official + "/" + name: [0, self.payload]}
        result = self.run_shell('PYTHON_VERSION=fixture\nPBS_RELEASE=fixture\nvalue="$(python_dist x86_64)"\nprintf "%s" "$value"')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(Path(result.stdout).read_text(), self.payload)
        self.assertEqual(self.calls(), [official + "/SHA256SUMS", primary, official + "/" + name])

    def test_destination_setup_failure_cannot_report_success(self):
        self.cache.write_text("not a directory")
        result = self.fetch(expected="", conditional=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("published", result.stdout)
        self.assertEqual(self.calls(), [])

    def test_failed_move_cannot_report_success(self):
        move = self.bin / "mv"
        move.write_text("#!/bin/sh\nexit 13\n")
        move.chmod(0o755)
        self.routes[self.primary] = [0, self.payload]
        result = self.fetch(expected="", conditional=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("published", result.stdout)
        self.assertFalse(self.dest.exists())


if __name__ == "__main__":
    unittest.main()
