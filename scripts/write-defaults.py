"""Write non-secret runtime paths into the development app bundle."""
import json
import pathlib
import shutil
import sys

repo = pathlib.Path(sys.argv[1]).resolve()
runtime = pathlib.Path.home() / "Library/Application Support/Daisy/Runtime"
config = {
    "model": "qwen3.5:4b",
    "whisperExecutable": shutil.which("whisper-cli") or "/opt/homebrew/bin/whisper-cli",
    "whisperModel": str(runtime / "models/ggml-base.en.bin"),
    "ollamaExecutable": shutil.which("ollama") or "/opt/homebrew/bin/ollama",
    "ollamaModels": str(runtime / "ollama/models"),
    "speakResponses": True,
    "allowFileSearch": True,
    "voice": "Samantha",
    "naturalVoice": "bm_george",
    "speechRate": 1.0,
    "browserNode": shutil.which("node") or str(pathlib.Path.home() / ".local/bin/node"),
}
pathlib.Path(sys.argv[2]).write_text(json.dumps(config, indent=2) + "\n")
