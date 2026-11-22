#!/usr/bin/env python3
"""Keep checksum-addressed runtime originals; never publish or execute their contents."""
import argparse
import base64
import hashlib
import http.client
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request


MAX_UNKNOWN_BYTES = 1024 * 1024 * 1024


class InputError(Exception):
    pass


class TransportError(InputError):
    pass


def shell_inputs(repo):
    source = (repo / "runtime/build-runtime.sh").read_text(encoding="utf-8")
    values = {}
    for name, value in re.findall(r'^([A-Z][A-Z0-9_]*)="([^"\n]*)"', source, re.M):
        default = re.fullmatch(r"\$\{" + name + r":-(.*)\}", value)
        values[name] = default[1] if default else value
    block = re.search(r"^declare -A PIN=\(\n(.*?)^\)", source, re.M | re.S)
    if block is None:
        raise InputError("build-runtime.sh has no supported PIN table")
    pins = {}
    for line in block[1].splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        match = re.fullmatch(r"\s*\[([^\]]+)\]=([0-9a-f]{64})(?:\s+#.*)?\s*", line)
        if match is None:
            raise InputError("unsupported/unparsed PIN entry in build-runtime.sh")
        pins[match[1]] = match[2]
    return values, pins


def add_object(objects, algorithm, digest, urls, ref, size=None):
    if algorithm not in ("sha256", "sha512") or not re.fullmatch(
            "[0-9a-f]{" + str(hashlib.new(algorithm).digest_size * 2) + "}", digest):
        raise InputError("unsupported or malformed input digest")
    key = algorithm + "-" + digest
    row = objects.setdefault(key, {"key": key, "algorithm": algorithm, "digest": digest,
                                   "size": size, "urls": [], "refs": []})
    if size is not None:
        if row["size"] is not None and row["size"] != size:
            raise InputError("conflicting sizes for " + key)
        row["size"] = size
    for url in urls:
        if url not in row["urls"]:
            row["urls"].append(url)
    row["refs"].append(ref)


def lock_label(lock, repo):
    try:
        return str(lock.relative_to(repo))
    except ValueError:
        return str(lock)


def add_npm_lock(objects, lock, repo):
    data = json.loads(lock.read_text(encoding="utf-8"))
    for package_path, package in data["packages"].items():
        if not package_path:
            continue
        if package.get("link"):
            raise InputError("local linked package has no original: " + package_path)
        sri = package.get("integrity", "")
        match = re.fullmatch(r"(sha256|sha512)-([A-Za-z0-9+/]+={0,2})", sri)
        if match is None or not package.get("resolved"):
            raise InputError("missing/unsupported resolved or integrity: " + package_path)
        digest = base64.b64decode(match[2], validate=True).hex()
        add_object(objects, match[1], digest, [package["resolved"]], {
            "kind": "npm", "source": lock_label(lock, repo), "package_path": package_path,
            "name": package_path.rsplit("node_modules/", 1)[-1], "version": package["version"],
            "integrity": sri, "license": package.get("license"),
            "optional": bool(package.get("optional")), "os": package.get("os"),
            "cpu": package.get("cpu"), "libc": package.get("libc"),
        })


def npm_inventory(locks, repo):
    objects = {}
    for lock in locks:
        add_npm_lock(objects, lock, repo)
    return [objects[key] for key in sorted(objects)]


def inventory(repo, npm_locks=None, all_locks=False):
    values, pins = shell_inputs(repo)
    objects = {}
    used_pins = set()

    def pinned(name, urls, abi, role):
        if name not in pins:
            raise InputError("default input has no PIN: " + name)
        used_pins.add(name)
        add_object(objects, "sha256", pins[name], urls, {
            "kind": role, "name": name, "abi": abi,
            "source": "runtime/build-runtime.sh:PIN[" + name + "]",
            "license": None, "license_note": "inspect original copyright/COPYING and corresponding source before redistribution",
        })

    for abi, ubuntu, node, termux in (("arm64-v8a", "arm64", "arm64", "aarch64"),
                                     ("x86_64", "amd64", "x64", "x86_64")):
        name = "ubuntu-base-" + values["UBUNTU_VERSION"] + "-base-" + ubuntu + ".tar.gz"
        pinned(name, [values["UBUNTU_MIRROR"] + "/" + name], abi, "ubuntu_base")
        name = "node-v" + values["NODE_VERSION"] + "-linux-" + node + ".tar.xz"
        pinned(name, [values["NODE_MIRROR"] + "/v" + values["NODE_VERSION"] + "/" + name],
               abi, "node_guest_and_x64_build_host" if node == "x64" else "node_guest")
        name = "cpython-" + values["PYTHON_VERSION"] + "+" + values["PBS_RELEASE"] + "-" + termux + "-unknown-linux-gnu-install_only_stripped.tar.gz"
        pinned(name, [values[key] + "/" + values["PBS_RELEASE"] + "/" + name
                      for key in ("PBS_MIRROR", "PBS_OFFICIAL")], abi, "python")
        for package, version_key, pool in (("proot", "PROOT_VERSION", "p"),
                                           ("libtalloc", "TALLOC_VERSION", "libt"),
                                           ("libandroid-shmem", "SHMEM_VERSION", "liba")):
            name = package + "_" + values[version_key] + "_" + termux + ".deb"
            pinned(name, [values["TERMUX_REPO"] + "/pool/main/" + pool + "/" + package + "/" + name], abi, "termux_jni")
        lock = repo / ("runtime/locks/ubuntu-noble-" + ubuntu + ".json")
        mirror = values["UBUNTU_ARCHIVE_" + ("AMD64" if ubuntu == "amd64" else "ARM64")]
        for index, package in enumerate(json.loads(lock.read_text(encoding="utf-8"))["packages"]):
            name = Path(package["filename"]).name
            urls = [mirror + "/" + package["filename"]]
            if "UBUNTU_DEB_FALLBACK" in values:
                urls.append(values["UBUNTU_DEB_FALLBACK"] + "/" + name)
            add_object(objects, "sha256", package["sha256"], urls, {
                "kind": "ubuntu_deb", "name": name, "version": package["version"], "abi": abi,
                "source": lock_label(lock, repo) + ":packages[" + str(index) + "]",
                "license": None, "license_note": "inspect archive copyright and corresponding source before redistribution",
            }, package["size"])
    name = "proot-v" + values["PROOT_VERSION"] + ".zip"
    pinned(name, ["https://github.com/termux/proot/archive/v" + values["PROOT_VERSION"] + ".zip"],
           "both", "proot_source_for_COPYING")
    uncovered = sorted(set(pins) - used_pins)
    if uncovered:
        raise InputError("unsupported/uncovered PIN entries: " + ", ".join(uncovered))
    if npm_locks:
        locks = npm_locks
    else:
        defaults = [repo / ("runtime/locks/" + name + "/package-lock.json") for name in
                    ("dsh-" + values["DSH_VERSION"], "pnpm-" + values["PNPM_VERSION"])]
        pnpm = json.loads(defaults[1].read_text(encoding="utf-8"))["packages"].get("node_modules/pnpm", {})
        if pnpm.get("version") != values["PNPM_VERSION"] or pnpm.get("integrity") != values["PNPM_INTEGRITY"]:
            raise InputError("current pnpm lock version/integrity does not match source pins")
        defaults.append(repo / "runtime/bridge/dsh-go-bridge/package-lock.json")
        locks = sorted(set(defaults) | set((repo / "runtime/locks").glob("*/package-lock.json"))) if all_locks else defaults
    for lock in locks:
        add_npm_lock(objects, lock, repo)
    return [objects[key] for key in sorted(objects)]


def digest_file(path, algorithm):
    with path.open("rb") as source:
        return hashlib.file_digest(source, algorithm).hexdigest()


def verify_file(path, obj):
    if digest_file(path, obj["algorithm"]) != obj["digest"]:
        raise InputError("checksum mismatch: " + obj["key"])
    if obj["size"] is not None and path.stat().st_size != obj["size"]:
        raise InputError("size mismatch: " + obj["key"])


def store_stream(source, obj, store):
    """Only a fully verified temporary file may replace the flat object name."""
    store.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(prefix=".part-", dir=store, delete=False) as output:
            temporary = Path(output.name)
            digest = hashlib.new(obj["algorithm"])
            size = 0
            limit = obj["size"] if obj["size"] is not None else MAX_UNKNOWN_BYTES
            while True:
                try:
                    chunk = source.read(min(1024 * 1024, limit - size + 1))
                except (OSError, http.client.HTTPException) as error:
                    raise TransportError("input read failed: " + type(error).__name__) from error
                if not chunk:
                    break
                size += len(chunk)
                if size > limit:
                    reason = "size exceeds expected bytes" if obj["size"] is not None else "input exceeds transfer limit"
                    raise InputError(reason + ": " + obj["key"])
                output.write(chunk)
                digest.update(chunk)
            if digest.hexdigest() != obj["digest"]:
                # Bounded HTTP reads can reach EOF without raising IncompleteRead.
                if isinstance(source, http.client.HTTPResponse) and source.length:
                    raise TransportError("input read failed: incomplete HTTP body")
                raise InputError("checksum mismatch: " + obj["key"])
            if obj["size"] is not None and size != obj["size"]:
                raise InputError("size mismatch: " + obj["key"])
            output.flush()
            os.fsync(output.fileno())
        destination = store / obj["key"]
        os.replace(temporary, destination)
        return destination
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def checked_url(url, base=False):
    parsed = urllib.parse.urlsplit(url)
    if parsed.scheme not in ("https", "file") or parsed.username or parsed.password or parsed.fragment:
        raise InputError("input URL must be HTTPS or local file:// without credentials/fragment")
    if parsed.scheme == "https" and not parsed.netloc:
        raise InputError("HTTPS input URL needs a host")
    if parsed.scheme == "file" and (parsed.netloc not in ("", "localhost") or not parsed.path.startswith("/")):
        raise InputError("file:// input URL must name a local absolute path")
    if base and parsed.query:
        raise InputError("mirror base must not contain a query")
    return url.rstrip("/") + "/" if base else url


def collect_one(obj, store, mirror_base=None):
    destination = store / obj["key"]
    if destination.exists():
        verify_file(destination, obj)
        return destination, "cached"
    urls = list(obj["urls"])
    if mirror_base:
        urls.append(checked_url(mirror_base, base=True) + obj["key"])
    failures = []
    for url in urls:
        request = urllib.request.Request(checked_url(url), headers={"User-Agent": "dsh-go-input-store/1"})
        try:
            response = urllib.request.urlopen(request, timeout=30)
        except (OSError, urllib.error.URLError, http.client.HTTPException) as error:
            failures.append(type(error).__name__)
            continue
        with response:
            try:
                return store_stream(response, obj, store), "collected"
            except TransportError as error:
                failures.append(str(error))
        # A checksum, disk-write or atomic-replace error must NOT try another source.
    raise TransportError("unavailable " + obj["key"] + ": " + ", ".join(failures))


def collect_objects(objects, store, mirror_base=None, output=None):
    result = {"objects": len(objects), "cached": 0, "collected": 0, "bytes": 0, "errors": [],
              "self_mirror": "configured" if mirror_base else "自留回落不可用（未配置 --mirror-base）"}
    checksums = {}
    if output is not None:
        output.mkdir(parents=True, exist_ok=True)
    for obj in objects:
        try:
            path, status = collect_one(obj, store, mirror_base)
            result[status] += 1
            result["bytes"] += path.stat().st_size
            if output is not None:
                digest = obj["digest"] if obj["algorithm"] == "sha256" else digest_file(path, "sha256")
                exported = {**obj, "key": "sha256-" + digest, "algorithm": "sha256", "digest": digest}
                with path.open("rb") as source:
                    store_stream(source, exported, output)
                checksums[exported["key"]] = digest
        except TransportError as error:
            result["errors"].append({"key": obj["key"], "error": str(error)})
        except (InputError, OSError) as error:
            result["errors"].append({"key": obj["key"], "error": str(error)})
            result["stopped"] = True
            break
    if output is not None:
        (output / "SHA256SUMS").write_text(
            "".join(checksums[name] + "  " + name + "\n" for name in sorted(checksums)), encoding="utf-8", newline="\n")
        result["exported"] = len(checksums)
    return result


def verify_objects(objects, store):
    result = {"objects": len(objects), "verified": 0, "bytes": 0, "errors": []}
    for obj in objects:
        path = store / obj["key"]
        try:
            verify_file(path, obj)
            result["verified"] += 1
            result["bytes"] += path.stat().st_size
        except (InputError, OSError) as error:
            result["errors"].append({"key": obj["key"], "error": str(error)})
    return result


def import_files(objects, paths, store):
    """Identify originals by bytes, not by a cache's possibly ambiguous filename."""
    wanted = {obj["key"]: obj for obj in objects}
    algorithms = {obj["algorithm"] for obj in objects}
    result = {"files": len(paths), "imported": 0, "cached": 0, "bytes": 0, "errors": []}
    for path in paths:
        try:
            digests = {name: hashlib.new(name) for name in algorithms}
            with path.open("rb") as source:
                while chunk := source.read(1024 * 1024):
                    for digest in digests.values():
                        digest.update(chunk)
            keys = [name + "-" + digest.hexdigest() for name, digest in digests.items()]
            matches = [wanted[key] for key in keys if key in wanted]
            if not matches:
                raise InputError("not a pinned original in the selected inventory")
            for obj in matches:
                destination = store / obj["key"]
                if destination.exists():
                    verify_file(destination, obj)
                    result["cached"] += 1
                else:
                    with path.open("rb") as source:
                        store_stream(source, obj, store)
                    result["imported"] += 1
                result["bytes"] += destination.stat().st_size
        except (InputError, OSError) as error:
            result["errors"].append({"file": str(path), "error": str(error)})
    return result


def warm_npm(lock, repo, store, mirror_base, npm, npm_cache, userconfig, globalconfig):
    """Populate npm's public cache API from verified raw archives; do not run npm ci."""
    before = lock.read_bytes()
    for config in (userconfig, globalconfig):
        if config.read_bytes() != b"":
            raise InputError("npm configuration file must be empty: " + str(config))
    checked_url(mirror_base, base=True)
    objects = npm_inventory([lock], repo)
    result = collect_objects(objects, store, mirror_base)
    result["npm_batches"] = 0
    if result["errors"]:
        return result
    environment = os.environ.copy()
    environment["PATH"] = str(npm.parent) + os.pathsep + environment.get("PATH", "")
    for start in range(0, len(objects), 64):
        # npm infers a directory from extensionless names. Same-filesystem .tgz
        # hard links give its public cache API file specs without copying originals.
        with tempfile.TemporaryDirectory(prefix=".npm-", dir=store) as temporary:
            paths = []
            for obj in objects[start:start + 64]:
                alias = Path(temporary) / (obj["key"] + ".tgz")
                os.link(store / obj["key"], alias)
                paths.append(str(alias))
            command = [str(npm), "cache", "add", *paths, "--offline", "--ignore-scripts",
                       "--no-audit", "--no-fund", "--cache", str(npm_cache),
                       "--prefix", temporary, "--userconfig", str(userconfig),
                       "--globalconfig", str(globalconfig)]
            completed = subprocess.run(command, cwd=temporary, env=environment, stdout=sys.stderr)
        if completed.returncode:
            result["errors"].append({"error": "npm cache add failed", "exit_code": completed.returncode})
            break
        result["npm_batches"] += 1
    if lock.read_bytes() != before:
        raise InputError("lock changed during npm warming; abort before npm ci")
    return result


def parser():
    result = argparse.ArgumentParser(description=__doc__)
    commands = result.add_subparsers(dest="command", required=True)
    for name in ("inventory", "collect", "import", "verify", "warm-npm"):
        command = commands.add_parser(name)
        command.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[2])
        if name != "warm-npm":
            selection = command.add_mutually_exclusive_group()
            selection.add_argument("--npm-lock", type=Path, action="append", help="replace default npm lock selection")
            selection.add_argument("--all-locks", action="store_true", help="include historical npm locks")
        if name != "inventory":
            command.add_argument("--store", type=Path, required=True)
        if name in ("collect", "warm-npm"):
            command.add_argument("--mirror-base", required=name == "warm-npm", help="explicit HTTPS or file:// flat object directory")
        if name == "collect":
            command.add_argument("--output", type=Path, help="copy verified objects as sha256 files with SHA256SUMS")
        if name == "import":
            command.add_argument("files", type=Path, nargs="+")
        if name == "warm-npm":
            for option in ("lock", "npm", "npm-cache", "userconfig", "globalconfig"):
                command.add_argument("--" + option, type=Path, required=True)
    return result


def main(argv=None):
    args = parser().parse_args(argv)
    try:
        repo = args.repo.absolute()
        if args.command == "warm-npm":
            result = warm_npm(args.lock.absolute(), repo, args.store.absolute(), args.mirror_base,
                              args.npm.absolute(), args.npm_cache.absolute(),
                              args.userconfig.absolute(), args.globalconfig.absolute())
        else:
            locks = [path.absolute() for path in args.npm_lock] if args.npm_lock else None
            objects = inventory(repo, locks, args.all_locks)
            if args.command == "inventory":
                result = {"schema": 1, "object_count": len(objects), "objects": objects}
            elif args.command == "collect":
                if args.mirror_base:
                    checked_url(args.mirror_base, base=True)
                result = collect_objects(objects, args.store.absolute(), args.mirror_base,
                                         args.output.absolute() if args.output is not None else None)
            elif args.command == "verify":
                result = verify_objects(objects, args.store.absolute())
            else:
                result = import_files(objects, args.files, args.store.absolute())
    except (InputError, OSError, ValueError, KeyError) as error:
        result = {"errors": [{"error": str(error)}]}
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 1 if result.get("errors") else 0


if __name__ == "__main__":
    sys.exit(main())
