# Wake word

How Daisy hears "Hey Daisy", and how to train a model for it so the recognizer doesn't have to run on every sentence in the room.

## How it works now

With always listening on, the mic stays open and each utterance goes to a streaming recognizer:

- **Apple's recognizer** (SpeechAnalyzer, macOS 26) returns partial text while you talk, so Daisy wakes as soon as "Hey Daisy" shows up in it, not after you stop and the whole sentence is transcribed. On a `say` clip of "Hey Daisy, what time is it in Tokyo right now?" it woke 1.2 s into a 2.7 s sentence.
- **Whisper** is the fallback. It has no partials, so there Daisy wakes when the utterance ends, the way it always did.
- **Silero VAD** decides where utterances start and end when its model is installed; otherwise it's the energy endpointer.

Either way, what follows the wake phrase is the request. "Hey Daisy" on its own makes Daisy wait up to 8 seconds for the rest. Anything without the wake phrase is dropped.

The catch: the recognizer runs on everything anyone says near the Mac. A trained wake word model fixes that.

## A trained "hey daisy" model

openWakeWord listens for one phrase with a tiny model. When `hey_daisy.onnx` is in Daisy's Runtime folder, it becomes the first stage: the recognizer only starts after the model hears the wake word, and only gets the audio after it.

There's no pretrained "hey daisy", so it has to be trained. openWakeWord's training notebook downloads its training data (room echoes, AudioSet noise, music) from huggingface.co, which the school network blocks, so it runs on Google Colab instead.

### Train it on Colab

1. Open the notebook: [openWakeWord training on Colab](https://colab.research.google.com/drive/1q1oe2zOyZp7UsB3jJiQ1IFn8z5YfjwEb?usp=sharing). It's linked from the [openWakeWord README](https://github.com/dscripka/openWakeWord#training-new-models).
2. In step 1, set `target_word` to `hey daisy` and run that cell. Listen to the sample. If it doesn't sound right, spell it the way it sounds with underscores between parts, like `hey_day_zee`. No punctuation.
3. Optional: set **Runtime → Change runtime type** to a GPU; it's much faster.
4. **Runtime → Run all**. Keep the tab open. It takes about an hour on the default runtime.
   - The defaults (1,000 examples, 10,000 steps) give a usable model.
   - 30,000 to 50,000 examples is better, but slower.
   - A higher `false_activation_penalty` wakes less often by mistake, and also misses more when it's noisy.
5. At the end the browser downloads `hey_daisy.onnx` (and a `.tflite`, which Daisy doesn't use). The file name comes from `target_word`, with spaces turned into underscores.

### Install it

```sh
bash scripts/setup-speech.sh     # Silero, openWakeWord's two feature models, the worker script
bash scripts/setup-voice.sh      # only if the voice venv isn't there yet; the worker runs in it
cp ~/Downloads/hey_daisy.onnx ~/Library/Application\ Support/Daisy/Runtime/speech/hey_daisy.onnx
```

Then restart Daisy, or turn always listening off and on.

The model runs in a small Python worker (`scripts/speech/wakeword.py`) using the onnxruntime already in the voice venv. It gets the mic audio and sends back a score every 80 ms. Scores of 0.5 or more wake Daisy, then nothing more for 2 seconds. The threshold can be changed with `speechInput.wakeWordThreshold` in `config.json`. If the worker or any of its files is missing, Daisy goes back to the recognizer gate on its own.

### Check it before trusting it

Play a few "Hey Daisy"s from across the room, and let it run through an evening of TV. openWakeWord's own models aim for under one false wake in two hours and under 5% missed. A quick model trained on the defaults will do worse. If it wakes too often, raise the threshold a little, or retrain with more examples and a higher penalty.

To test the worker on a recording without the app (16 kHz mono WAV):

```sh
cd ~/Library/Application\ Support/Daisy/Runtime/speech
python3 -c "import wave,sys; w=wave.open(sys.argv[1]); sys.stdout.buffer.write(w.readframes(w.getnframes()))" clip.wav \
  | ../voice/venv/bin/python wakeword.py --melspec melspectrogram.onnx --embedding embedding_model.onnx --model hey_daisy.onnx
```

It prints one score per 80 ms. The "Hey Daisy" should reach 0.5 or more; everything else should stay near zero.

### Licenses

openWakeWord's code is Apache 2.0. The training notebook mixes datasets with non-commercial terms, so a model trained with it is for personal use, which is what this is. The same goes for openWakeWord's pretrained models, like the `hey_jarvis` one Daisy's tests use as a stand-in.

## Willow Voice

Willow stays what it is now: a manual push-to-talk typing aid. Hold Fn with the Daisy composer focused and Willow pastes the text in. It never listens for a wake word, and Daisy doesn't talk to it. Keep Willow's `autoMuteAudio` off; it would mute Daisy's voice while you dictate. Both apps can use the mic at the same time.
