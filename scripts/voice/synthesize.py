"""Local-only Kokoro synthesis.

One-shot: --input text file, --output WAV.
Serve: --serve keeps the model loaded and reads one JSON request per stdin line
({"text", "voice", "speed", "output"}), answering one JSON line per request on stdout.
"""
import argparse
import json
import os
import pathlib
import sys
import time

# Fail closed against any optional runtime library download behavior.
os.environ["HF_HUB_OFFLINE"] = "1"
os.environ["TRANSFORMERS_OFFLINE"] = "1"
os.environ["HF_HUB_DISABLE_TELEMETRY"] = "1"

VOICES = ["bm_george", "bm_fable", "am_michael", "af_heart", "bf_emma"]

parser = argparse.ArgumentParser()
parser.add_argument("--input", type=pathlib.Path)
parser.add_argument("--output", type=pathlib.Path)
parser.add_argument("--voice", choices=VOICES, default="bm_george")
parser.add_argument("--speed", type=float, default=1.0)
parser.add_argument("--serve", action="store_true")
args = parser.parse_args()

# Library chatter must never reach the protocol stream.
protocol_out = sys.stdout
sys.stdout = sys.stderr

import onnxruntime as ort
import soundfile as sf
from kokoro_onnx import Kokoro

root = pathlib.Path(__file__).resolve().parent
options = ort.SessionOptions()
options.intra_op_num_threads = 4
options.inter_op_num_threads = 1
session = ort.InferenceSession(str(root / "kokoro-v1.0.onnx"), sess_options=options, providers=["CPUExecutionProvider"])
engine = Kokoro.from_session(session, str(root / "voices-v1.0.bin"))


def render(text, voice, speed, output):
    if voice not in VOICES:
        raise ValueError("Unsupported voice")
    if not 0.75 <= speed <= 1.3:
        raise ValueError("Voice speed is out of range")
    text = text.strip()
    if not text or len(text) > 2200:
        raise ValueError("Speech text must contain 1-2200 characters")
    samples, rate = engine.create(text, voice=voice, speed=speed, lang="en-gb" if voice.startswith("b") else "en-us")
    sf.write(str(output), samples, rate, subtype="PCM_16")


if args.serve:
    for line in sys.stdin:
        started = time.time()
        try:
            request = json.loads(line)
            render(str(request["text"]), str(request.get("voice", "bm_george")), float(request.get("speed", 1.0)),
                   pathlib.Path(request["output"]))
            reply = {"ok": True, "seconds": round(time.time() - started, 3)}
        except Exception as error:  # keep serving; the app decides what to do
            reply = {"error": str(error)[:200]}
        protocol_out.write(json.dumps(reply) + "\n")
        protocol_out.flush()
else:
    if args.input is None or args.output is None:
        raise SystemExit("--input and --output are required unless --serve is given")
    render(args.input.read_text(encoding="utf-8"), args.voice, args.speed, args.output)
