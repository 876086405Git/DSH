"""Exercise shutil's real metadata/cross-mount copy and fd-safe cleanup paths."""
import os
from pathlib import Path
import shutil
import tempfile

with tempfile.TemporaryDirectory(dir="/workspace") as workspace:
    target = Path(workspace)
    with tempfile.TemporaryDirectory(dir="/tmp") as temporary:
        source = Path(temporary) / "source"
        source.mkdir()
        file = source / "example.txt"
        file.write_text("ios-python", encoding="utf-8")
        os.chmod(file, 0o640)
        os.utime(file, (1000, 2000))
        shutil.copytree(source, target / "copied")
        copy = target / "copied/example.txt"
        assert copy.read_text(encoding="utf-8") == "ios-python"
        assert copy.stat().st_mode & 0o777 == 0o640
        assert copy.stat().st_mtime == 2000
        # /tmp and /workspace are distinct guest mounts. shutil.move must use
        # its copy2 fallback after EXDEV, preserving metadata and cleaning up.
        moved = target / "moved.txt"
        shutil.move(file, moved)
        assert moved.read_text(encoding="utf-8") == "ios-python"
        assert not file.exists()
        os.utime(moved, None)  # current-time path
        assert moved.stat().st_mtime > 2000

print("PYTHON_FILESYSTEM_OK")
