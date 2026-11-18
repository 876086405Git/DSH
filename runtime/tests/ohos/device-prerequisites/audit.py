#!/usr/bin/env python3
"""Offline source/BPF audit. Never installs filters or invokes renameat2.

Requires a fixed-source cache (or --fetch) and an output directory outside source.
The only executed upstream program is the SHA-checked official policy generator.
"""
import argparse
import ast
import hashlib
import importlib.util
import json
import operator
import re
import shutil
import struct
import subprocess
import sys
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
CONSTANTS = {
    "AUDIT_ARCH_ARM": 0x40000028,
    "AUDIT_ARCH_AARCH64": 0xc00000b7,
    "AUDIT_ARCH_RISCV64": 0xc00000f3,
    "SECCOMP_RET_ALLOW": 0x7fff0000,
    "SECCOMP_RET_TRAP": 0x00030000,
    "APP_UID_START": 10000,
}
FLAGS = [0, 1, 2, 4, 7, 0xffffffff, 0x100000000, 0xfeedface00000001]
FILTERS = [
    ("appspawn", "spawn", "system"),
    ("app", "app", "app"),
    ("app_atomic", "app_atomic", "app"),
    ("app_custom", "app_custom", "app"),
    ("app_allow_iouring", "app_allow_iouring", "app"),
    ("app_privilege", "app_privilege", "system"),
]


def digest(data):
    return hashlib.sha256(data).hexdigest()


def canonical(data):
    return json.dumps(data, sort_keys=True, separators=(",", ":")).encode()


def expression(value):
    # Generator casts constants to a 64-bit unsigned long for the ARM64 path.
    # Accept this one fixed cast; unfamiliar C syntax remains an error.
    value = value.replace("(unsigned long)", "")
    operations = {ast.Add: operator.add, ast.Sub: operator.sub, ast.BitOr: operator.or_,
                  ast.BitAnd: operator.and_, ast.LShift: operator.lshift,
                  ast.RShift: operator.rshift}
    def visit(node):
        if isinstance(node, ast.Constant) and type(node.value) is int:
            return node.value
        if isinstance(node, ast.Name) and node.id in CONSTANTS:
            return CONSTANTS[node.id]
        if isinstance(node, ast.BinOp) and type(node.op) in operations:
            return operations[type(node.op)](visit(node.left), visit(node.right))
        if isinstance(node, ast.UnaryOp) and isinstance(node.op, ast.USub):
            return -visit(node.operand)
        raise ValueError("Unsupported expression on executed BPF path: " + value)
    return visit(ast.parse(value, mode="eval").body)


def parse_program(source):
    rows = []
    for line in source.splitlines():
        match = re.fullmatch(r"\s*BPF_(STMT|JUMP)\((.*)\),\s*", line)
        if match:
            arguments = [s.strip() for s in match[2].split(",")]
            expected = 2 if match[1] == "STMT" else 4
            if len(arguments) != expected:
                raise ValueError("Unexpected macro shape")
            rows.append((match[1], arguments))
    if not rows:
        raise ValueError("Empty generated program")
    return rows


def execute(program, syscall_nr, flags=0, arch=0xc00000b7, first_arg=0):
    # seccomp_data: nr:int32, arch:uint32, IP:uint64, six uint64 arguments.
    data = struct.pack("<iI7Q", syscall_nr, arch, 0, first_arg, 0, 0, 0, flags, 0)
    accumulator, pc = 0, 0
    memory, trace, loads = {}, [], []
    for _ in range(8192):
        if not 0 <= pc < len(program):
            raise ValueError("BPF branch outside program")
        kind, args = program[pc]
        code, operand = args[:2]
        trace.append(pc)
        value = expression(operand)
        if kind == "STMT":
            if code == "BPF_LD|BPF_W|BPF_ABS":
                if value < 0 or value + 4 > len(data):
                    raise ValueError("BPF load outside seccomp_data")
                accumulator = struct.unpack_from("<I", data, value)[0]
                loads.append(value)
            elif code == "BPF_LD|BPF_MEM":
                accumulator = memory[value]
            elif code == "BPF_ST":
                memory[value] = accumulator
            elif code == "BPF_ALU|BPF_AND|BPF_K":
                accumulator &= value
            elif code == "BPF_RET|BPF_K":
                return {"action": value, "actionName": next(
                    (k for k, v in CONSTANTS.items() if k.startswith("SECCOMP_RET_") and v == value),
                    hex(value)), "pc": trace, "loads": loads}
            else:
                raise ValueError("Unsupported executed BPF statement " + code)
            pc += 1
        elif code == "BPF_JMP|BPF_JA":
            pc += 1 + value
        else:
            conditions = {"BPF_JMP|BPF_JEQ|BPF_K": accumulator == value,
                          "BPF_JMP|BPF_JGE|BPF_K": accumulator >= value,
                          "BPF_JMP|BPF_JGT|BPF_K": accumulator > value,
                          "BPF_JMP|BPF_JSET|BPF_K": bool(accumulator & value)}
            if code not in conditions:
                raise ValueError("Unsupported executed BPF jump " + code)
            pc += 1 + expression(args[2 if conditions[code] else 3])
    raise ValueError("BPF instruction budget exhausted")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cache", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--cc", default="cc")
    parser.add_argument("--fetch", action="store_true")
    options = parser.parse_args()
    manifest = json.loads((HERE / "sources.json").read_text())
    options.cache.mkdir(parents=True, exist_ok=True)
    options.output.mkdir(parents=True, exist_ok=True)
    source = {}
    for item in manifest["sources"]:
        path = options.cache / item["name"]
        if not path.exists() and options.fetch:
            with urllib.request.urlopen(item["url"], timeout=30) as response:
                payload = response.read()
            if digest(payload) != item["sha256"]:
                raise ValueError("Downloaded source hash mismatch: " + item["name"])
            path.write_bytes(payload)
        payload = path.read_bytes()
        if len(payload) != item["bytes"] or digest(payload) != item["sha256"]:
            raise ValueError("Source identity mismatch: " + item["name"])
        source[item["name"]] = path
    assert re.search(r"#define\s+APP_UID_START\s+\(10000\)", source["seccomp-policy-constants.h"].read_text())
    # Verify the constants and data layout against the pinned target UAPI.
    audit_header = source["kernel-uapi-audit.h"].read_text()
    elf_header = source["kernel-uapi-elf-em.h"].read_text()
    seccomp_header = source["kernel-uapi-seccomp.h"].read_text()
    for literal in ["EM_AARCH64", "__AUDIT_ARCH_64BIT", "__AUDIT_ARCH_LE"]:
        assert literal in audit_header
    assert re.search(r"#define\s+EM_AARCH64\s+183", elf_header)
    assert re.search(r"#define\s+__AUDIT_ARCH_64BIT\s+0x80000000", audit_header)
    assert re.search(r"#define\s+__AUDIT_ARCH_LE\s+0x40000000", audit_header)
    assert re.search(r"#define\s+SECCOMP_RET_ALLOW\s+0x7fff0000", seccomp_header)
    assert re.search(r"#define\s+SECCOMP_RET_TRAP\s+0x00030000", seccomp_header)
    assert re.search(r"__u64\s+args\[6\]", seccomp_header)
    out = options.output
    includes = out / "include"
    for arch in ["arm", "arm64", "riscv"]:
        destination = includes / ("asm-" + arch) / "asm"
        destination.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source["uapi-" + arch + "-unistd.h"], destination / "unistd.h")
        names = ["unistd-eabi.h", "unistd-common.h"] if arch == "arm" else ["bitsperlong.h"]
        for name in names:
            shutil.copyfile(source["uapi-" + arch + "-" + name], destination / name)
    destination = includes / "asm-generic"
    destination.mkdir(parents=True, exist_ok=True)
    for name in ["unistd.h", "bitsperlong.h"]:
        shutil.copyfile(source["uapi-generic-" + name], destination / name)
    table_paths, commands = [], []
    for arch in ["arm", "arm64", "riscv64"]:
        path = out / ("libsyscall_to_nr_" + arch)
        include_arch = "riscv" if arch == "riscv64" else arch
        command = [options.cc, "-I", str(includes / ("asm-" + include_arch)),
                   "-I", str(includes), "-dD", "-E", "-Wall", "-nostdinc", "-o", str(path),
                   str(source["gen_syscall_name_nrs.c"])]
        result = subprocess.run(command, capture_output=True, text=True)
        commands.append({"command": command, "exitCode": result.returncode,
                         "stdout": result.stdout, "stderr": result.stderr})
        result.check_returncode()
        table_paths.append(path)
    specification = importlib.util.spec_from_file_location("pinned_oh_policy", source["seccomp-generator.py"])
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    tables = {path.name.removeprefix("libsyscall_to_nr_"): module.parse_syscall_file(str(path))
              for path in table_paths}
    assert tables["arm64"]["renameat2"] == 276
    assert tables["arm64"]["flock"] == 32
    assert tables["arm64"]["fsetxattr"] == 7
    assert tables["arm64"]["fgetxattr"] == 10
    programs, generated, results = {}, [], []
    for name, policy, kind in FILTERS:
        target = out / (name + "_filter.c")
        command = [sys.executable, str(source["seccomp-generator.py"])]
        for path in table_paths + [source[policy + ".seccomp.policy"]]:
            command += ["--src-files", str(path)]
        command += ["--blocklist-file", str(source[kind + ".blocklist.seccomp.policy"]),
                    "--keyprocess-file", str(source["privileged_process.seccomp.policy"]),
                    "--dst-file", str(target), "--filter-name", name,
                    "--target-cpu", "arm64", "--is-debug", "false"]
        result = subprocess.run(command, capture_output=True, text=True)
        commands.append({"command": command, "exitCode": result.returncode,
                         "stdout": result.stdout, "stderr": result.stderr})
        result.check_returncode()
        program = parse_program(target.read_text())
        programs[name] = program
        generated.append({"name": name, "processType": kind, "source": policy + ".seccomp.policy",
                          "blocklist": kind + ".blocklist.seccomp.policy", "keyprocess": "privileged_process.seccomp.policy",
                          "targetCpu": "arm64", "debug": False, "uidFilterAdded": False,
                          "sha256": digest(target.read_bytes()), "instructions": len(program)})
        for flags in FLAGS:
            observation = execute(program, 276, flags)
            assert observation["action"] == CONSTANTS["SECCOMP_RET_ALLOW"], (name, flags, observation)
            assert not any(offset >= 16 for offset in observation["loads"]), (name, flags, observation)
            results.append({"case": "renameat2", "filter": name, "flags": hex(flags), **observation})
        for case, nr, arch, expected in [
            ("wrong-arch", 276, 0, "SECCOMP_RET_TRAP"),
            ("unknown-syscall", 999999, 0xc00000b7,
             "SECCOMP_RET_ALLOW" if name == "appspawn" else "SECCOMP_RET_TRAP")]:
            observation = execute(program, nr, arch=arch)
            assert observation["action"] == CONSTANTS[expected], (name, case, observation)
            results.append({"case": case, "filter": name, **observation})
    for uid, expected in [(0, "SECCOMP_RET_TRAP"), (10000, "SECCOMP_RET_ALLOW")]:
        observation = execute(programs["appspawn"], tables["arm64"]["setuid"], first_arg=uid)
        assert observation["action"] == CONSTANTS[expected], (uid, observation)
        results.append({"case": "spawn-setuid", "uid": uid, **observation})
    chains = []
    profiles = []
    for name, _, _ in FILTERS[1:]:
        # SECCOMP_PRIVILEGE compiles out the appspawn UID/GID filter.
        # The app_privilege selection itself requires that same macro.
        if name != "app_privilege":
            profiles.append((name, False, ["appspawn", name]))
        profiles.append((name, True, [name]))
    for name, privilege_build, chain in profiles:
        for flags in FLAGS:
            # init explicitly skips appspawn; extra ancestor/vendor/runtime filters
            # are not modeled. Child name is the result of the selection branches.
            actions = [execute(programs[layer], 276, flags)["action"] for layer in chain]
            assert all(action == CONSTANTS["SECCOMP_RET_ALLOW"] for action in actions)
            chains.append({"selectedPolicy": name, "WITH_SECCOMP": True,
                           "SECCOMP_PRIVILEGE": privilege_build,
                           "layers": chain, "flags": hex(flags), "actions": actions,
                           "knownLayersAction": "ALLOW", "effectiveDeviceAction": "NOT_RUN"})
    report = {"scope": "offline fixed-source audit; no filter installation or syscall execution",
              "deviceStatus": "NOT_RUN", "sourceManifestSHA256": digest((HERE / "sources.json").read_bytes()),
              "compiler": subprocess.run([options.cc, "--version"], capture_output=True, text=True).stdout.splitlines()[0],
              "compilerScope": "Host C preprocessor using official fixed UAPI; not an OHOS toolchain build",
              "tables": {arch: {"entries": len(table), "canonicalSHA256": digest(canonical(table)),
                                   "renameat2": table["renameat2"]} for arch, table in tables.items()},
              "generated": generated, "cases": results, "knownChains": chains,
              "caseCount": len(results), "chainCount": len(chains), "pass": True}
    (out / "commands.json").write_text(json.dumps(commands, indent=2) + "\n")
    (out / "audit.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({"pass": True, "cases": len(results), "chains": len(chains),
                      "device": "NOT_RUN", "output": str(out / "audit.json")}))


if __name__ == "__main__":
    main()
