# Using Daisy from my phone

Checked 2026-09-28 against Hermes 0.21 (code and `website/docs`). Read-only; nothing was installed or started.

## What Hermes already has

| Surface | What I can do from the phone | Catch |
| --- | --- | --- |
| **Telegram bot** (gateway) | Text, images, files. Voice notes get transcribed locally (faster-whisper, no key). Replies can come back as voice. Approvals are inline buttons (Allow once / session / always, Deny). Scheduled-job results show up there | The voice is Hermes's TTS (Edge Aria), not Kokoro `af_heart`, unless Kokoro gets added as a Hermes TTS provider |
| **Web dashboard** (`hermes dashboard`, port 9119) | Sessions, cron, logs, pairing, channels, config; a Chat tab | The chat tab is the Hermes TUI in a browser terminal, clunky on a phone. Anything other than localhost won't start without a login set up |
| **API server** (port 8642, bearer key) | For a custom app later | Counts as unattended: dangerous actions auto-deny |
| iMessage (BlueBubbles), WhatsApp, Signal, Discord, Slack, SMS, ntfy | Same idea as Telegram | iMessage is awkward when the Mac and the phone use the same Apple ID |

Phone chats are their own sessions. They share memory and `state.db` with Daisy on the Mac, but they aren't the same conversation as the HUD.

## Guard on the phone

- The `daisy` plugin's `pre_tool_call` guard loads in every Hermes process, the gateway included. So approvals should turn into Telegram buttons. This still needs testing.
- The persona and the typed tools (Gmail, iMessage, etc.) only load with `DAISY_SESSION`. On the phone, Daisy is plain Hermes plus the guard.
- The Telegram prompt shows the guard's `reason` text, not the Mac's card. So `reason` has to spell out the exact recipient and message.
- `approvals.timeout: 60` is short for a phone.
- Never tap "Always" for sends. It writes a permanent allow rule.

## Reaching it

- **Telegram:** nothing to open. The gateway polls Telegram outbound.
- **Dashboard:** over Tailscale only (bind to the tailnet IP, or `tailscale serve` with `dashboard.public_url`), and always with the basic-auth login. Never on `0.0.0.0` on school or public wifi.
- **The Mac has to be awake.** With the lid closed on battery it sleeps. Keep it plugged in (clamshell), or move the gateway to a home box or VPS later, with its own device-code login. Never copy `auth.json`.
- The school filter might block Telegram or Tailscale (not checked). Cellular works either way.

## State on this Mac

- **Not set up yet:**
  - gateway not installed (no launchd job)
  - no Telegram token set up
  - Tailscale and BlueBubbles not installed
- **Already there:**
  - `stt.provider: local`
  - `tts.provider: edge`
  - `approvals.mode: manual`
  - ffmpeg

## Plan

1. **Telegram bot through the gateway.** Text, voice notes, approval buttons, cron results. I do:
   1. @BotFather → `/newbot` → token. Get my numeric user ID from @userinfobot.
   2. `hermes gateway setup` → Telegram. Token, plus `TELEGRAM_ALLOWED_USERS=<my id>`. No pairing, no groups.
   3. `hermes gateway install` (launchd `ai.hermes.gateway`), then `hermes gateway status`.
   4. DM the bot: send text, a voice note, and something the guard stops, to see the buttons.
   5. Set it as the home channel for scheduled jobs. `/voice tts` if I want spoken replies.
2. **Dashboard over Tailscale.** For sessions, scheduled jobs and logs, not chat:
   1. Install Tailscale on the Mac and the phone.
   2. Set `dashboard.basic_auth` (a scrypt hash plus a secret).
   3. Run `hermes dashboard --host <tailscale ip> --no-open`.
3. **Later:** a real iPhone app or web app on the API server's `/v1/runs` and approval endpoint, with Kokoro.

## Code and config changes

- Test the guard in the gateway:
  - an approval comes up as buttons
  - a button press resolves it
  - it blocks if the plugin crashes
- Guard `reason` includes the full action (recipient, body, file, share target).
- A short phone persona for gateway sessions (no HUD or voice talk).
- Decide whether the typed tools load on the phone.
- Raise `approvals.timeout` for phone sessions.
- Optional: show phone sessions in the HUD (from `state.db` by source).
- Optional: Kokoro as a Hermes TTS provider, so Telegram voice replies sound like Daisy.

## Security

- Telegram: allowlist by numeric ID, no pairing, no groups.
- Dashboard and API: never public. Tailscale plus login only.
- Never set `unattended_mode: approve`.
- If the bot token leaks, revoke it in @BotFather. With the allowlist, someone holding it can read the chat but can't run tools (inferred).
