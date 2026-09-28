# Speech in, and Willow Voice

Checked 2026-09-27. The Willow bundle was inspected read-only. Transcript and recording contents were not opened.

## Willow Voice

The willowvoice.com dictation app, not the HeyWillow ESP32 project.

- **Bundle.** `com.seewillow.WillowMac` 2.5.1 at `/Applications/Willow Voice.app`.
- **Transcription.** Cloud by default: a realtime websocket to `api.` and `middleware.willowvoice.com`, and the binary mentions OpenAI and Fireworks.
  - It has an offline mode (whisper.cpp plus a ~3 GB model), but the model isn't downloaded, so it's cloud in practice.
  - It has Silero VAD on disk under `~/Library/Application Support/com.seewillow.WillowMac/VADModel/`.
- **Trigger.** Hold Fn (push-to-talk). There's also a double-tap hands-free mode. No wake word.
- **No way in for another app.** No API, no AppleScript dictionary, no App Intents, no XPC, no local server. The URL schemes only handle login.
- **Terms.** They forbid reverse engineering, and a developer API is Enterprise-only ([pricing](https://willowvoice.com/pricing)).
- **Privacy.** Their policy says audio isn't kept on their servers and history stays on the device ([privacy](https://willowvoice.com/privacy-policy)).

### What works with Daisy

- **Willow as a typing aid:** hold Fn with the Daisy composer focused, and Willow pastes the text. Works today with no code.
  - Still push-to-talk only, and it goes through Willow's cloud.
  - It can reword what I said.
- **Mic conflicts.** Both apps can share the mic. Daisy's wake gate ignores anything that doesn't start with "Hey Daisy". Willow's `autoMuteAudio` setting would mute Daisy's voice, so leave it off.
- **Watching Willow's transcript files, or calling its backend:** fragile or against its terms. No.

## Better speech-in for Daisy

The current `base.en` Whisper model came from huggingface.co, which the school filter now blocks. Anything new from Hugging Face has to be downloaded at home.

| Option | Why | Catch |
| --- | --- | --- |
| **Apple SpeechAnalyzer / SpeechTranscriber** (macOS 26) | Native Swift, streaming, Neural Engine, low RAM. Models come from Apple, not HF. Benchmarks show lower error than whisper.cpp at about 3x the speed ([dev.to](https://dev.to/iravoice/apple-speechanalyzer-vs-whisper-cpp-a-40-speaker-mac-benchmark-40i4), [Inscribe](https://get-inscribe.com/blog/apple-speech-api-benchmark.html)) | New API; not tried here yet. The old SFSpeechRecognizer failed (VALIDATION.md) |
| Parakeet TDT v3 via FluidAudio | Swift, Neural Engine, very fast, includes Silero VAD | Models on HF |
| WhisperKit (large-v3-turbo) | Swift + CoreML, accurate | Models on HF, ~1 GB |
| whisper.cpp small.en / large-v3-turbo | Smallest code change | More RAM and slower per clip; HF |
| OpenAI gpt-4o-transcribe / Deepgram | Most accurate, streaming | Costs money, needs a key, audio leaves the Mac |

**Wake word:**
- openWakeWord has a pretrained `hey_jarvis` model on GitHub releases (not HF), ONNX format.
- Porcupine has a built-in "Daisy" keyword but needs a free access key.
- Either one means Whisper doesn't have to run on every pause.

**Plan:**
1. SpeechTranscriber as the main recognizer, with whisper-server kept as the fallback.
2. Silero VAD in place of the energy endpointer (Willow's MIT copy or FluidAudio's).
3. Try openWakeWord `hey_jarvis`.
4. Keep Willow as a manual push-to-talk option.
