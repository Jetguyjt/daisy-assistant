"""Install downloaded assets in app data; never remove source or existing models."""
import pathlib
import shutil
import subprocess
import sys

source, destination = map(pathlib.Path, sys.argv[1:3])
for relative in (pathlib.Path("models/ggml-base.en.bin"), pathlib.Path("ollama/models")):
    root = source / relative
    if not root.exists():
        raise SystemExit(f"Missing {root}; run scripts/download-models.sh first.")
    files = [root] if root.is_file() else root.rglob("*")
    for item in files:
        if not item.is_file() or item.is_symlink():
            continue
        target = destination / item.relative_to(source)
        target.parent.mkdir(parents=True, exist_ok=True)
        if target.exists() and target.stat().st_size == item.stat().st_size:
            if "blobs" in item.parts or target.read_bytes() == item.read_bytes():
                continue
        # APFS clones avoid duplicating multi-GB blobs; copy fallback handles other volumes.
        result = subprocess.run(["/bin/cp", "-c", str(item), str(target)], capture_output=True)
        if result.returncode:
            shutil.copy2(item, target)
print(f"Installed runtime models in {destination}")
