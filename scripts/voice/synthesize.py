"""Local-only Kokoro synthesis.

One-shot: --input text file, --output WAV.
Serve: --serve keeps the model loaded and reads one JSON request per stdin line
({"text", "voice", "speed", "output"}), answering one JSON line per request on stdout.

A voice is one Kokoro voice ("af_heart") or a blend of several ("af_heart:0.7,af_bella:0.3"),
checked against the voices file; blend weights are scaled to add up to 1, and a voice with no
weight counts as 1. Each rendered chunk has the silence at both ends cut and the same short pause
put back at the end, so chunks played back to back join the way sentences inside one chunk do.
--models is the folder holding kokoro-v1.0.onnx and voices-v1.0.bin (default: next to this script).
"""
import argparse
import json
import math
import os
import pathlib
import sys
import time
import wave

# Fail closed against any optional runtime library download behavior.
os.environ["HF_HUB_OFFLINE"] = "1"
os.environ["TRANSFORMERS_OFFLINE"] = "1"
os.environ["HF_HUB_DISABLE_TELEMETRY"] = "1"

DEFAULT_VOICE = "af_heart"
# Seconds of silence between sentences inside a chunk and after every chunk, so both joins match.
PAUSE = 0.2
# Seconds kept before the first sound, enough not to clip the attack.
LEAD = 0.01
# Seconds kept after the last sound for the release, before the pause is added.
RELEASE = 0.03
# A frame this far below the loudest frame counts as silence when trimming.
QUIET_DB = -50.0


def parse_voice(spec, available):
    """'af_heart' or 'af_heart:0.7,af_bella:0.3' as [(name, weight)] with the weights adding up to 1."""
    parts = []
    for item in str(spec).split(","):
        name, colon, weight = (piece.strip() for piece in item.partition(":"))
        if not name:
            raise ValueError(f"Voice {spec!r} has an empty entry")
        if name not in available:
            raise ValueError(f"Unknown voice {name!r}")
        if any(name == seen for seen, _ in parts):
            raise ValueError(f"Voice {name!r} is listed twice")
        try:
            value = float(weight) if colon else 1.0
        except ValueError:
            raise ValueError(f"Weight {weight!r} for {name} is not a number") from None
        if not math.isfinite(value) or value <= 0:
            raise ValueError(f"Weight for {name} must be above zero")
        parts.append((name, value))
    total = sum(value for _, value in parts)
    return [(name, value / total) for name, value in parts]


def language(parts):
    """British phonemes when the heaviest voice is British, American otherwise."""
    name = max(parts, key=lambda part: part[1])[0]
    return "en-gb" if name.startswith("b") else "en-us"


def blend(voices, parts):
    """One style array: the weighted sum of the named voices' arrays."""
    import numpy as np

    style = sum(weight * np.asarray(voices[name], dtype=np.float32) for name, weight in parts)
    return np.asarray(style, dtype=np.float32)


def trim(samples, rate, pause=PAUSE, lead=LEAD, release=RELEASE, quiet_db=QUIET_DB):
    """Cuts the silence before the first sound and after the last, then ends on `pause` seconds of silence."""
    import numpy as np

    samples = np.asarray(samples, dtype=np.float32)
    frame = max(1, int(rate * 0.005))
    count = len(samples) // frame
    if count == 0:
        return samples
    loudness = np.sqrt((samples[: count * frame].astype(np.float64).reshape(count, frame) ** 2).mean(axis=1))
    peak = loudness.max()
    if peak <= 0:
        return samples
    heard = np.flatnonzero(loudness > peak * 10 ** (quiet_db / 20))
    last = (heard[-1] + 1) * frame
    start = max(0, heard[0] * frame - int(rate * lead))
    end = min(len(samples), last + int(rate * release))
    kept = samples[start:end].copy()
    # A short fade where the cut lands, so it can't click.
    fade = min(len(kept), int(rate * 0.005))
    if fade and start > 0:
        kept[:fade] *= np.linspace(0.0, 1.0, fade, dtype=np.float32)
    if fade and end < len(samples):
        kept[-fade:] *= np.linspace(1.0, 0.0, fade, dtype=np.float32)
    padding = max(0, int(rate * pause) - (end - last))
    return np.concatenate([kept, np.zeros(padding, dtype=np.float32)])


def write_wav(path, samples, rate):
    """16-bit mono WAV."""
    import numpy as np

    pcm = np.round(np.clip(np.asarray(samples, dtype=np.float32), -1.0, 1.0) * 32767).astype("<i2")
    with wave.open(str(path), "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(int(rate))
        output.writeframes(pcm.tobytes())


class Speaker:
    """The loaded model, plus the style arrays already built for each voice setting."""

    def __init__(self, engine):
        self.engine = engine
        self.styles = {}

    @classmethod
    def load(cls, models):
        import onnxruntime as ort
        from kokoro_onnx import Kokoro

        options = ort.SessionOptions()
        options.intra_op_num_threads = 4
        options.inter_op_num_threads = 1
        session = ort.InferenceSession(str(models / "kokoro-v1.0.onnx"), sess_options=options,
                                       providers=["CPUExecutionProvider"])
        return cls(Kokoro.from_session(session, str(models / "voices-v1.0.bin")))

    def render(self, text, voice, speed, output):
        if not 0.75 <= speed <= 1.3:
            raise ValueError("Voice speed is out of range")
        text = text.strip()
        if not text or len(text) > 2200:
            raise ValueError("Speech text must contain 1-2200 characters")
        parts = parse_voice(voice, self.engine.voices)
        if voice not in self.styles:
            self.styles[voice] = blend(self.engine.voices, parts)
        samples, rate = self.engine.create(text, voice=self.styles[voice], speed=speed, lang=language(parts),
                                           sentence_pause=PAUSE)
        write_wav(output, trim(samples, rate), rate)


def serve(speaker, requests, replies):
    for line in requests:
        started = time.time()
        try:
            request = json.loads(line)
            speaker.render(str(request["text"]), str(request.get("voice", DEFAULT_VOICE)),
                           float(request.get("speed", 1.0)), pathlib.Path(request["output"]))
            reply = {"ok": True, "seconds": round(time.time() - started, 3)}
        except Exception as error:  # keep serving; the app decides what to do
            reply = {"error": str(error)[:200]}
        replies.write(json.dumps(reply) + "\n")
        replies.flush()


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", type=pathlib.Path)
    parser.add_argument("--output", type=pathlib.Path)
    parser.add_argument("--voice", default=DEFAULT_VOICE)
    parser.add_argument("--speed", type=float, default=1.0)
    parser.add_argument("--serve", action="store_true")
    parser.add_argument("--models", type=pathlib.Path, default=pathlib.Path(__file__).resolve().parent)
    args = parser.parse_args(argv)
    if not args.serve and (args.input is None or args.output is None):
        parser.error("--input and --output are required unless --serve is given")

    # Library chatter must never reach the protocol stream.
    protocol_out = sys.stdout
    sys.stdout = sys.stderr
    # Local, so the model is released when main returns rather than during interpreter shutdown.
    speaker = Speaker.load(args.models)
    if args.serve:
        serve(speaker, sys.stdin, protocol_out)
        return
    failure = None
    try:
        speaker.render(args.input.read_text(encoding="utf-8"), args.voice, args.speed, args.output)
    except ValueError as error:
        failure = f"synthesize.py: {error}"
    del speaker
    if failure:
        raise SystemExit(failure)


if __name__ == "__main__":
    main()
