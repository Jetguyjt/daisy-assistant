# A better voice

Checked 2026-09-27. Prices and latencies come from vendor pages unless marked. Nothing was installed.

Right now Daisy speaks with Kokoro-82M (`bm_george`) through a Python worker, one sentence at a time. It sounds flat.

## Why it sounds bad (cheap fixes first)

1. **The voice.** Kokoro's own VOICES.md grades `bm_george` and `bm_fable` C. British males are its weakest voices; the best British voice is `bf_emma` (B-).
2. **Echo cancellation on playback.** Playback goes through AVAudioEngine with voice processing on (`MicrophoneInput.swift:77`). That can thin out and duck the output (from memory, not measured). A/B test the same WAV through plain AVAudioPlayer.
3. **Pronunciation.** kokoro-onnx uses espeak-ng. The official Kokoro uses misaki with a British lexicon, and its output can be fed to kokoro-onnx. Needs checking.
4. **One sentence at a time.** Intonation resets at every sentence and very short fragments sound weak. Merge short fragments and trim silence.
5. **No text cleanup.** No number, time or abbreviation expansion, and `sentences()` splits on every "." ("3.5", "e.g.").

## Hosted

The ChatGPT/Codex sign-in only works for the Codex backend, not the public API, so any OpenAI voice needs its own paid API key. Hermes's TTS docs say the same.

| Option | Quality | First audio | Cost | Notes |
| --- | --- | --- | --- | --- |
| **ElevenLabs v3 Conversational** | Most expressive; Voice Design for an original voice | ~280 ms | $0.10/1K chars; Starter $6/mo ≈ 1 hr | WebSocket streaming; Hermes supports it |
| ElevenLabs Flash v2.5 | Very good, less emotive | ~75 ms | $0.05/1K chars | Low-latency mode |
| **Cartesia Sonic-3.6** | Top of the Artificial Analysis arena (Aug 2026) | ~90 ms claimed, ~180 ms measured | Pro $5/mo ≈ 133 min | Best value |
| OpenAI gpt-4o-mini-tts | Good, steerable by instructions; no native British voice | Low | ≈ $0.015/min (estimate) | Needs an API key |
| OpenAI gpt-realtime-2 | Speech-to-speech | Very low | $64/1M audio-out tokens | It's its own brain and would bypass Hermes. No |
| Hume Octave, Deepgram Aura-2, Azure, Gemini TTS | OK to good | Varies | Varies | Nothing better for this |

## Local

The school filter blocks huggingface.co. Qwen3-TTS is also on ModelScope. Anything else has to be downloaded at home. The Mac is an Air with Chrome using ~12 GB.

| Option | Quality | Speed / RAM | License |
| --- | --- | --- | --- |
| **Qwen3-TTS 0.6B** (mlx-audio) | High; VoiceDesign makes a voice from a description | RTF 0.55 on an M2 Max; ~3 GB at 8-bit; not measured on the M3 Air | Apache-2.0 |
| **Kyutai Pocket TTS** | Good; clones from 5 s of audio | ~200 ms, CPU only, tiny RAM | MIT |
| Chatterbox Turbo | Expressive; emotion dial | Unmeasured on M-series | MIT |
| Orpheus, Sesame CSM, Dia, F5, XTTS, Piper | Too heavy, restrictively licensed, or robotic | | |

## Don't clone Paul Bettany

ElevenLabs forbids cloning a voice without consent, and Tennessee's ELVIS Act covers imitated voices. Design an original older British butler voice instead.

## Plan

1. **Now, free:**
   - Try `bf_emma` and a george/fable blend.
   - A/B test playback with echo cancellation on and off.
   - Merge short fragments.
   - Add number and abbreviation cleanup.
2. **Best sound: ElevenLabs.** Design one original voice. Stream v3 Conversational into the existing sentence feed, and cancel the stream on barge-in. Flash v2.5 when speed matters. Cartesia is the cheaper second choice.
3. **Best local:** Qwen3-TTS 0.6B from ModelScope. Design the voice once, save a reference clip, and measure it on this Mac. If it's too heavy, Pocket TTS cloned from the same clip.
4. **Offline fallback:** Kokoro stays for when the hosted voice fails.
