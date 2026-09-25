"""Download public model assets at setup time; runtime synthesis never downloads."""
import hashlib
import json
import pathlib
import sys
import urllib.request

root = pathlib.Path(sys.argv[1])
release = "https://api.github.com/repos/thewh1teagle/kokoro-onnx/releases/tags/model-files-v1.1"
with urllib.request.urlopen(release, timeout=60) as response:
    assets = {item["name"]: item for item in json.load(response)["assets"]}
manifest = {}
for name in ("kokoro-v1.0.onnx", "voices-v1.0.bin"):
    asset = assets[name]
    destination = root / name
    if not destination.exists() or destination.stat().st_size != asset["size"]:
        staging = destination.with_suffix(destination.suffix + ".download")
        print(f"Downloading {name} ({asset['size'] / 1e6:.1f} MB)", flush=True)
        with urllib.request.urlopen(asset["browser_download_url"], timeout=120) as response, staging.open("wb") as output:
            while block := response.read(1024 * 1024):
                output.write(block)
        staging.replace(destination)
    digest = hashlib.sha256(destination.read_bytes()).hexdigest()
    expected = asset.get("digest")
    if expected and expected != "sha256:" + digest:
        raise SystemExit(f"Hash verification failed for {name}")
    manifest[name] = {"sha256": digest, "bytes": destination.stat().st_size, "source": asset["browser_download_url"]}
(root / "model-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
print("Verified voice assets", flush=True)
