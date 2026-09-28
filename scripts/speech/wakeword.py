"""Daisy's wake word worker: openWakeWord models on onnxruntime, nothing else.

Raw 16 kHz mono int16 audio (little endian) comes in on stdin as one continuous stream. After the
models load, one JSON line says so; then each 80 ms of audio (1280 samples) gets one line on stdout
with the highest wake word score, 0 to 1. EOF on stdin (Daisy quit or let go) ends it.

The feature steps follow openWakeWord's own streaming code (github.com/dscripka/openWakeWord,
Apache 2.0): mel spectrogram of the newest 80 ms plus 30 ms of context, scaled x/10 + 2; an
embedding of the last 76 mel frames; the wake model on the last 16 embeddings; the first five
scores are zero while the buffers fill.

Usage: wakeword.py --melspec melspectrogram.onnx --embedding embedding_model.onnx --model hey_daisy.onnx
"""
import argparse
import json
import sys

import numpy as np
import onnxruntime as ort

FRAME = 1280
CONTEXT = 160 * 3
MEL_WINDOW = 76
MEL_LIMIT = 10 * 97
EMBEDDING_LIMIT = 120


def load(path):
    options = ort.SessionOptions()
    options.inter_op_num_threads = 1
    options.intra_op_num_threads = 1
    return ort.InferenceSession(path, sess_options=options, providers=["CPUExecutionProvider"])


class Features:
    def __init__(self, melspec, embedding):
        self.melspec = load(melspec)
        self.embedding = load(embedding)
        self.embedding_input = self.embedding.get_inputs()[0].name
        self.raw = np.zeros(0, dtype=np.int16)
        self.mels = np.ones((MEL_WINDOW, 32), dtype=np.float32)
        # openWakeWord starts from embeddings of quiet noise so the first windows have full shape.
        noise = np.random.default_rng(0).integers(-1000, 1000, 16000 * 4).astype(np.int16)
        spec = self.spectrogram(noise)
        windows = [spec[i:i + MEL_WINDOW] for i in range(0, spec.shape[0], 8) if spec[i:i + MEL_WINDOW].shape[0] == MEL_WINDOW]
        self.embeddings = self.embed(np.array(windows))

    def spectrogram(self, audio):
        out = self.melspec.run(None, {"input": audio.astype(np.float32)[None, :]})[0]
        return np.squeeze(out) / 10 + 2

    def embed(self, windows):
        batch = windows[:, :, :, None].astype(np.float32)
        return self.embedding.run(None, {self.embedding_input: batch})[0].reshape(len(windows), -1)

    def push(self, frame):
        self.raw = np.concatenate([self.raw, frame])[-(FRAME + CONTEXT):]
        self.mels = np.vstack([self.mels, self.spectrogram(self.raw)])[-MEL_LIMIT:]
        self.embeddings = np.vstack([self.embeddings, self.embed(self.mels[None, -MEL_WINDOW:])])[-EMBEDDING_LIMIT:]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--melspec", required=True)
    parser.add_argument("--embedding", required=True)
    parser.add_argument("--model", action="append", required=True)
    args = parser.parse_args()

    out = sys.stdout
    sys.stdout = sys.stderr  # library chatter must not reach the protocol
    features = Features(args.melspec, args.embedding)
    models = []
    for path in args.model:
        session = load(path)
        entry = session.get_inputs()[0]
        frames = entry.shape[1] if isinstance(entry.shape[1], int) else 16
        models.append((session, entry.name, frames))
    out.write(json.dumps({"ready": True, "models": len(models), "frame": FRAME}) + "\n")
    out.flush()

    source = sys.stdin.buffer
    count = 0
    while True:
        data = source.read(FRAME * 2)
        if len(data) < FRAME * 2:
            return
        features.push(np.frombuffer(data, dtype="<i2"))
        count += 1
        score = 0.0
        if count > 5:
            for session, name, frames in models:
                window = features.embeddings[-frames:][None].astype(np.float32)
                score = max(score, float(np.max(session.run(None, {name: window})[0])))
        out.write(f"{score:.4f}\n")
        out.flush()


if __name__ == "__main__":
    try:
        main()
    except (BrokenPipeError, KeyboardInterrupt):
        pass
