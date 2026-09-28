# New voice and new name

Checked 2026-09-27. Nothing was installed or changed.

If the voice switches from British male to American female, the name has to change too. JARVIS stood for "Just A Rather Very Intelligent System", so the new one should be a female name with a backronym as dumb as that.

## Voice

What's already on this Mac: kokoro-onnx 0.6.1 with `voices-v1.0.bin` (54 voices) in `~/Library/Application Support/Jarvis/Runtime/voice/`.

**Free today: `af_heart`.**
- It's Kokoro's only A-graded voice. `bm_george` is a C.
- `af_bella` is A-. The installed kokoro-onnx accepts a style vector, so a 70/30 heart/bella blend works.
- It's the biggest free upgrade, but Kokoro as a model still sits around Elo 1065, against about 1274 for the top hosted voices. It will sound read-aloud, not witty. The fixes in [voice.md](voice.md) still apply: fragment merging and number cleanup.

**Blind rankings** ([Artificial Analysis](https://artificialanalysis.ai/text-to-speech/leaderboard/provider-voice), 2026):

| Model | Elo |
| --- | --- |
| Cartesia Sonic 3.6 | 1274 |
| Gemini 3.8 Flash TTS | 1265 |
| ElevenLabs v3 Conversational | 1195 |
| OpenAI TTS-1 HD | 1104 |
| Kokoro | 1065 |

### Hosted

| Voice | Why | Cost at 1 hr/day | Cost at 10 min/day |
| --- | --- | --- | --- |
| **Cartesia Sonic 3.6 "Jacqueline"** (or "Skylar") | #1 in the arena, ~40–90 ms, WebSocket streaming | ~$49/mo (Startup) | Pro $5/mo |
| Gemini 3.8 Flash TTS, "Aoede" / "Leda" / "Kore" | #2 in the arena, cheapest of the top models, style prompts | ~$27/mo | a few dollars |
| OpenAI gpt-4o-mini-tts, "marin" | `instructions` field for a "warm, dry wit" persona | ~$27/mo | ~$3–7/mo |

- **ElevenLabs premade voices** (Sarah, Jessica, Matilda…) expire 2026-12-31 and aren't offered to new accounts. A Voice Design voice on v3 is great but runs $80–160/mo at an hour a day.
- **Any hosted voice needs its own API key.** The ChatGPT sign-in can't do TTS.

### Local

| Option | Notes |
| --- | --- |
| Kokoro `af_heart` / heart+bella blend | Installed, near-zero RAM |
| **Qwen3-TTS 1.7B VoiceDesign** | Design the voice once from a text description, save a reference clip, then clone it with 0.6B Base through mlx-audio. Apache-2.0, on ModelScope (gets around the HF block). Speed on this Mac not measured |
| Chatterbox Turbo (350M, MIT) | Clone from the same clip; MLX port claims ~3.8× realtime; emotion tags |
| Pocket TTS, Orpheus "tara", Sesame CSM | HF-only weights, too heavy, or not realtime on an Air |

### Code changes

- **Kokoro:**
  - Change the default voice in `synthesize.py` plus the Swift files that name `bm_george` (`NaturalSpeech.swift`, `AppModel.swift`, `ContentView.swift`, `Check.swift`).
  - For a blend, parse `"af_heart:0.7,af_bella:0.3"` into a style array before `engine.create`.
- **Hosted:**
  - A second synthesizer backend that streams PCM into `SpeechFeed`, one stream per reply.
  - Barge-in closes the stream.
  - Key in the Keychain; Kokoro as the offline fallback.
- **Qwen3 / Chatterbox:** a second persistent Python worker with the same JSON-lines protocol as `synthesize.py`, plus `reference.wav`.

## Name

The name is also the wake word ("Hey ___"), so it needs to be:
- 2 syllables, 3 with "hey"
- made of distinct sounds
- transcribed the same way every time by Whisper
- not already a big AI brand, a Mac product or a controversy

Every common name has some small app using it; that alone doesn't rule a name out.

### Top 3

1. **DAISY: "Definitely An Intelligent System, Yeah."**
   - Same shape as JARVIS, ending on a shrug.
   - Also a nod to HAL 9000 singing "Daisy Bell" in *2001*.
   - Whisper spells it reliably. Only small apps use it.
2. **JANET: "Just A Neural Engine, Technically."**
   - Keeps JARVIS's "Just A…".
   - Janet in *The Good Place* is literally an AI assistant ("not a robot").
   - Distinct J-N-T sounds.
3. **DORIS: "Does Only Reasonably Intelligent Stuff."**
   - The funniest.
   - One small AI receptionist startup ([getdoris.ai](https://www.getdoris.ai/)).
   - "the door is" is the one confusable phrase.

### Ruled out

| Name | Why |
| --- | --- |
| MAVIS | Tencent launched "Mavis", a desktop AI assistant for Mac, in May 2026 ([TechNode](https://technode.com/2026/05/21/tencent-unveils-mavis-ai-assistant-that-turns-pcs-into-conversational-interfaces/)) |
| FRIDAY, EDITH, KAREN | Marvel's Stark AIs; "Friday" false-triggers; "Karen" is a meme |
| ADA | Ada is a $1.2B AI customer-service company; all vowels, confused with "hey there" |
| TESSA | NEDA pulled its Tessa chatbot for giving diet advice to eating-disorder users ([NPR](https://www.npr.org/sections/health-shots/2023/06/08/1180838096/an-eating-disorders-chatbot-offered-dieting-advice-raising-fears-about-ai-in-hea)) |
| NOVA | Amazon Nova models |
| CLARA | Clara Labs, AI scheduling assistant since 2014 |
| VERA | "very"; many AI Veras |
| HAZEL | Hazel is a well-known Mac automation app |
| GLADYS | Gladys Assistant is an open-source voice home assistant |
| IRIS, ROSIE, AGNES, MABEL | Existing AI products or confusable words |

### Wake word

- **Whisper matching (what's there now):** works with any common name right away. Edit the phrase list and regex in `WakePhrase` (`SpeechEndpointer.swift`) and add likely misspellings.
- **openWakeWord:** there's no pretrained model for these names. Its training notebook downloads from huggingface.co, so train "hey daisy" on Colab (about an hour) and copy the `.onnx` file over.

### Rename effort

"Jarvis" appears about 438 times in 69 files.

- **What I see and hear**, about 10 files, roughly an hour:
  - wake phrase
  - display name
  - mic permission text
  - Hermes persona
  - UI strings
  - README
- **Everything else**, half a day or more:
  - bundle ID `com.local.jarvis.desktop`: changing it resets mic and accessibility permissions and saved settings
  - Swift targets `Jarvis*`
  - `hermes/jarvis`, `JARVIS_SESSION`
  - `~/Library/Application Support/Jarvis/` (move the models)
  - repo name

Plan: rename what I see and hear now, and leave the internal names for later.
