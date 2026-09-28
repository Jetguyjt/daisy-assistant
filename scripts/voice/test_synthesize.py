"""Voice settings, blending, trimming and the serve protocol of synthesize.py, with a stand-in for
the model so nothing heavy loads. Run: python3 scripts/voice/test_synthesize.py"""

import contextlib
import importlib.util
import io
import json
import pathlib
import sys
import tempfile
import wave

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("synthesize", pathlib.Path(__file__).resolve().parent / "synthesize.py")
synthesize = importlib.util.module_from_spec(spec)
spec.loader.exec_module(synthesize)

failures = 0


def check(label, condition):
    global failures
    if not condition:
        failures += 1
        print("FAIL", label)


def rejects(spec, available, fragment):
    try:
        synthesize.parse_voice(spec, available)
    except ValueError as error:
        return fragment in str(error)
    return False


# Voice settings
available = {"af_heart", "af_bella", "bm_george", "bf_emma"}
check("one voice", synthesize.parse_voice("af_heart", available) == [("af_heart", 1.0)])
blended = synthesize.parse_voice("af_heart:0.7,af_bella:0.3", available)
check("the heart/bella blend", [name for name, _ in blended] == ["af_heart", "af_bella"]
      and abs(blended[0][1] - 0.7) < 1e-9 and abs(blended[1][1] - 0.3) < 1e-9)
scaled = synthesize.parse_voice(" af_heart:7 , af_bella:3 ", available)
check("weights are scaled to add up to 1", abs(scaled[0][1] - 0.7) < 1e-9 and abs(sum(w for _, w in scaled) - 1) < 1e-9)
check("no weight counts as 1", synthesize.parse_voice("af_heart,af_bella", available) == [("af_heart", 0.5), ("af_bella", 0.5)])
check("unknown voice", rejects("af_hert", available, "Unknown voice 'af_hert'"))
check("voice missing from the file", rejects("jf_alpha:1", available, "Unknown voice"))
check("empty setting", rejects("", available, "empty entry"))
check("empty entry", rejects("af_heart,,af_bella", available, "empty entry"))
check("zero weight", rejects("af_heart:0", available, "above zero"))
check("negative weight", rejects("af_heart:-1,af_bella:2", available, "above zero"))
check("not a number", rejects("af_heart:lots", available, "not a number"))
check("missing weight after colon", rejects("af_heart:", available, "not a number"))
check("nan", rejects("af_heart:nan", available, "above zero"))
check("infinity", rejects("af_heart:inf", available, "above zero"))
check("listed twice", rejects("af_heart:0.5,af_heart:0.5", available, "listed twice"))
check("semicolons are not separators", rejects("af_heart:0.7;af_bella:0.3", available, "not a number"))
check("American phonemes", synthesize.language([("af_heart", 0.7), ("af_bella", 0.3)]) == "en-us")
check("British phonemes", synthesize.language([("bm_george", 1.0)]) == "en-gb")
check("the heavier voice picks", synthesize.language([("af_heart", 0.3), ("bf_emma", 0.7)]) == "en-gb")
usage = io.StringIO()
try:
    with contextlib.redirect_stderr(usage):
        synthesize.main(["--voice", "af_heart"])
    check("main() without --input/--output should exit", False)
except SystemExit as stop:
    check("main() stops with a usage error before loading the model", stop.code == 2 and "--input and --output" in usage.getvalue())

try:
    import numpy as np
except ImportError:
    np = None
    print("numpy is not installed here; skipping the audio checks")

if np is not None:
    rate = 24000

    # Blending
    rng = np.random.default_rng(1)
    voices = {name: rng.standard_normal((510, 1, 256)).astype(np.float32) for name in available}
    style = synthesize.blend(voices, [("af_heart", 0.7), ("af_bella", 0.3)])
    check("blend is the weighted sum", np.allclose(style, 0.7 * voices["af_heart"] + 0.3 * voices["af_bella"], atol=1e-6))
    check("blend keeps the shape and type", style.shape == (510, 1, 256) and style.dtype == np.float32)
    check("one voice is its own style", np.array_equal(synthesize.blend(voices, [("bm_george", 1.0)]), voices["bm_george"]))

    # Trimming
    tone = (0.5 * np.sin(np.arange(int(rate * 0.5)) * 2 * np.pi * 220 / rate)).astype(np.float32)
    padded = np.concatenate([np.zeros(int(rate * 0.3)), tone, np.zeros(int(rate * 0.6))]).astype(np.float32)
    trimmed = synthesize.trim(padded, rate)
    expected = 0.5 + synthesize.LEAD + synthesize.PAUSE
    check(f"trimmed length {len(trimmed) / rate:.3f}s is lead + tone + pause ({expected:.3f}s)",
          abs(len(trimmed) / rate - expected) <= 0.006)
    first = np.flatnonzero(np.abs(trimmed) > 1e-4)[0] / rate
    check(f"sound starts {first * 1000:.1f} ms in", abs(first - synthesize.LEAD) <= 0.006)
    last = np.flatnonzero(np.abs(trimmed) > 1e-4)[-1] / rate
    check(f"silence after the sound is the pause ({len(trimmed) / rate - last:.3f}s)",
          abs((len(trimmed) / rate - last) - synthesize.PAUSE) <= 0.006)
    check("the tone itself is untouched", np.sum(trimmed ** 2) >= 0.999 * np.sum(tone ** 2) - 1e-3)
    check("the cut is faded in", trimmed[0] == 0.0)
    short_tail = np.concatenate([np.zeros(int(rate * 0.02)), tone, np.zeros(int(rate * 0.05))]).astype(np.float32)
    check("a short tail is padded out to the pause",
          abs(len(synthesize.trim(short_tail, rate)) / rate - (synthesize.LEAD + 0.5 + synthesize.PAUSE)) <= 0.006)
    silence = np.zeros(rate, dtype=np.float32)
    check("pure silence is left alone", np.array_equal(synthesize.trim(silence, rate), silence))
    check("a tiny buffer is left alone", len(synthesize.trim(np.ones(10, dtype=np.float32), rate)) == 10)

    # Serving, with a stand-in engine
    class FakeEngine:
        def __init__(self):
            self.voices = voices
            self.calls = []

        def create(self, text, voice, speed, lang, sentence_pause):
            self.calls.append((text, voice, speed, lang, sentence_pause))
            body = np.concatenate([np.zeros(int(rate * 0.08)), tone[: int(rate * 0.4)], np.zeros(int(rate * 0.25))])
            return body.astype(np.float32), rate

    engine = FakeEngine()
    speaker = synthesize.Speaker(engine)
    with tempfile.TemporaryDirectory() as folder:
        good = pathlib.Path(folder) / "good.wav"
        lines = "\n".join(json.dumps(request) for request in [
            {"text": "Hello there.", "voice": "af_heart:0.7,af_bella:0.3", "speed": 1.0, "output": str(good)},
            {"text": "Hello again.", "voice": "af_hert", "speed": 1.0, "output": str(pathlib.Path(folder) / "bad.wav")},
            {"text": "   ", "output": str(pathlib.Path(folder) / "empty.wav")},
            {"text": "Too fast.", "speed": 2.0, "output": str(pathlib.Path(folder) / "fast.wav")},
            {"text": "Default voice.", "output": str(pathlib.Path(folder) / "default.wav")},
        ]) + "\n"
        replies = io.StringIO()
        synthesize.serve(speaker, io.StringIO(lines), replies)
        answers = [json.loads(line) for line in replies.getvalue().splitlines()]
        check("one reply per request", len(answers) == 5)
        check("blend renders", answers[0].get("ok") is True and good.exists())
        check("unknown voice is a clear error", "Unknown voice 'af_hert'" in answers[1].get("error", ""))
        check("empty text is an error", "1-2200" in answers[2].get("error", ""))
        check("speed is checked", "speed" in answers[3].get("error", ""))
        check("no voice means af_heart", answers[4].get("ok") is True and synthesize.DEFAULT_VOICE == "af_heart")
        text, style, speed, lang, pause = engine.calls[0]
        check("the engine gets the blended style", np.allclose(style, 0.7 * voices["af_heart"] + 0.3 * voices["af_bella"], atol=1e-6))
        check("American phonemes for the blend", lang == "en-us")
        check("sentence pauses match the chunk pause", pause == synthesize.PAUSE)
        check("the default voice is looked up once", len(engine.calls) == 2 and "af_heart" in speaker.styles)
        with wave.open(str(good)) as audio:
            seconds = audio.getnframes() / audio.getframerate()
            check("16-bit mono at the model's rate", audio.getnchannels() == 1 and audio.getsampwidth() == 2 and audio.getframerate() == rate)
            check(f"rendered chunk is trimmed ({seconds:.3f}s)", abs(seconds - (synthesize.LEAD + 0.4 + synthesize.PAUSE)) <= 0.006)

print("synthesize checks:", "ok" if failures == 0 else f"{failures} failed")
sys.exit(1 if failures else 0)
