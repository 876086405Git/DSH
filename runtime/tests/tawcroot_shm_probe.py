#!/usr/bin/env python3
"""检查运行环境的 /dev/shm 是否跨进程共享同一文件系统。

远端 Linux fixture 或 Android guest：使用待测启动器，将 rootfs 中的
/var/lib/dsh-app/shm 显式绑定到 /dev/shm，再在 guest 内运行：
    python3 /path/to/tawcroot_shm_probe.py

普通 Linux 宿主（不检验绑定，仅自测探针）：
    python3 runtime/tests/tawcroot_shm_probe.py --host-self-test

无需账号、网络或第三方依赖。CI 应给整个启动命令另设超时。
"""

import argparse
import os
import select
import stat
import subprocess
import sys
import uuid


SHM_DIR = "/dev/shm"
BACKING_DIR = "/var/lib/dsh-app/shm"
PIPE_TIMEOUT = 10
PAYLOAD_SIZE = 32


def require_missing(path, *, dir_fd=None):
    try:
        os.stat(path, dir_fd=dir_fd, follow_symlinks=False)
    except FileNotFoundError:
        return
    raise RuntimeError(f"file still exists: {path}")


def child_read(path):
    require_missing(path)
    os.write(sys.stdout.fileno(), b"R")
    if os.read(sys.stdin.fileno(), 1) != b"G":
        raise RuntimeError("reader did not get the read signal")
    with open(path, "rb") as source:
        os.write(sys.stdout.fileno(), source.read(PAYLOAD_SIZE + 1))


def check_file(reader, name, backing_path):
    path = os.path.join(SHM_DIR, name)
    payload = os.urandom(PAYLOAD_SIZE)
    dir_fd = os.open(SHM_DIR, os.O_RDONLY | os.O_DIRECTORY)
    try:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        try:
            with os.fdopen(fd, "wb") as target:
                target.write(payload)
                created = os.fstat(fd)

            if name not in os.listdir(SHM_DIR):
                raise RuntimeError("not listed in /dev/shm")
            fd = os.open(name, os.O_RDONLY, dir_fd=dir_fd)
            with os.fdopen(fd, "rb") as source:
                if source.read(PAYLOAD_SIZE + 1) != payload:
                    raise RuntimeError("dirfd-relative read returned different bytes")
            if backing_path is not None:
                if not os.path.samestat(created, os.stat(backing_path)):
                    raise RuntimeError("/dev/shm and its backing directory disagree on file identity")

            output, _ = reader.communicate(input=b"G", timeout=PIPE_TIMEOUT)
            if reader.returncode != 0:
                raise RuntimeError(f"absolute-path reader exited with status {reader.returncode}")
            if output != payload:
                raise RuntimeError("absolute-path reader returned different bytes")
        finally:
            # 只有独占创建成功后才会走到这里，且只删除本次文件。
            os.unlink(path)
        require_missing(path)
        require_missing(name, dir_fd=dir_fd)
        if backing_path is not None:
            require_missing(backing_path)
    finally:
        os.close(dir_fd)


def probe(host_self_test):
    name = f"dsh-go-shm-probe-{uuid.uuid4().hex}"
    backing_path = None
    if not host_self_test:
        if not stat.S_ISDIR(os.stat(BACKING_DIR).st_mode):
            raise RuntimeError(f"not a directory: {BACKING_DIR}")
        backing_path = os.path.join(BACKING_DIR, name)

    path = os.path.join(SHM_DIR, name)
    reader = subprocess.Popen(
        [sys.executable, os.path.abspath(__file__), "--reader", path],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
    )
    try:
        # 等待独立 exec 后的解释器就绪，再创建文件，不靠时间猜测顺序。
        ready, _, _ = select.select([reader.stdout], [], [], PIPE_TIMEOUT)
        if not ready:
            raise RuntimeError("timed out waiting for reader readiness")
        if os.read(reader.stdout.fileno(), 1) != b"R":
            raise RuntimeError("reader exited before reporting readiness")
        check_file(reader, name, backing_path)
    finally:
        if reader.poll() is None:
            reader.kill()
        reader.stdin.close()
        reader.stdout.close()
        reader.wait(timeout=PIPE_TIMEOUT)


def main():
    try:
        if len(sys.argv) == 3 and sys.argv[1] == "--reader":
            child_read(sys.argv[2])
            return 0
        parser = argparse.ArgumentParser(description=__doc__)
        parser.add_argument("--host-self-test", action="store_true", help="仅自测，不校验绑定源")
        args = parser.parse_args()
        probe(args.host_self_test)
        mode = "host self-test" if args.host_self_test else "explicit bind"
        print(f"shm-probe: OK ({mode})")
        return 0
    except (OSError, RuntimeError, subprocess.TimeoutExpired) as exc:
        print(f"shm-probe: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
