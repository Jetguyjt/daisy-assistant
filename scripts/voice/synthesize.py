"""Local-only Kokoro synthesis from a private text file to a private WAV file."""
import argparse
import os
import pathlib

# Fail closed against any optional runtime library download behavior.
os.environ["HF_HUB_OFFLINE"] = "1"
os.environ["TRANSFORMERS_OFFLINE"] = "1"
os.environ["HF_HUB_DISABLE_TELEMETRY"] = "1"

parser = argparse.ArgumentParser()
parser.add_argument("--input", type=pathlib.Path, required=True)
parser.add_argument("--output", type=pathlib.Path, required=True)
parser.add_argument("--voice", choices=["bm_george", "bm_fable", "am_michael", "af_heart", "bf_emma"], default="bm_george")
parser.add_argument("--speed", type=float, default=1.0)
args = parser.parse_args()
if not 0.75 <= args.speed <= 1.3:
    raise SystemExit("Voice speed is out of range")
text = args.input.read_text(encoding="utf-8").strip()
if not text or len(text) > 2200:
    raise SystemExit("Speech text must contain 1–2200 characters")

import onnxruntime as ort
import soundfile as sf
from kokoro_onnx import Kokoro

root = pathlib.Path(__file__).resolve().parent
options = ort.SessionOptions()
options.intra_op_num_threads = 4
options.inter_op_num_threads = 1
session = ort.InferenceSession(str(root / "kokoro-v1.0.onnx"), sess_options=options, providers=["CPUExecutionProvider"])
engine = Kokoro.from_session(session, str(root / "voices-v1.0.bin"))
samples, rate = engine.create(text, voice=args.voice, speed=args.speed, lang="en-gb" if args.voice.startswith("b") else "en-us")
sf.write(str(args.output), samples, rate, subtype="PCM_16")
