# lukebuildsai's Jarvis

Checked 2026-09-27 from his public profiles and sites. Instagram showed only 2 posts, so most details come from TikTok videos, his bio and his company's docs.

## Who

- **Luke Cutting**, Austin. Instagram [@lukebuildsai](https://www.instagram.com/lukebuildsai/) (~273K), TikTok [@luke.builds.ai](https://www.tiktok.com/@luke.builds.ai).
- **What he builds:** the BibleBreak app, "with J.A.R.V.I.S."
- **His company:** cofounder of [Azaris](https://azaris.ai/).
- **Paid stuff around it:**
  - free email course "JARVIS Agent Crash Course" ([lukebuildsai.com](https://www.lukebuildsai.com/))
  - $97/mo Skool group
- **No public code.** No GitHub, repo or template for his Jarvis.

## What it does

From his own posts and the Azaris docs:

- **Operator agent.** One agent manages specialist agents for content, support and product work.
- **Content agent.** Pulls footage, edits it and posts it daily. He says his app grew about 3x the month he pointed it at marketing.
- **Overnight work.** Handles emails, replies, support and signups before he wakes up.
- **Look.** A dark blue sci-fi dashboard with a central orb and live app stats across 4 monitors. "Hey Jarvis" reads out revenue and signups.
- **Azaris, the product version:**
  - always-on agent for email and calendar
  - a sandboxed cloud browser you can watch
  - memory with approval before saving
  - drafts for anything outgoing
  - Telegram, iMessage, Slack and Discord, plus voice
  - "1,000+ tools"
  - bring-your-own ChatGPT, OpenAI or Claude model

## What it's built on

Azaris's docs say Hermes "is what every Azaris agent runs on" ([vs-hermes](https://azaris.ai/docs/vs-hermes)). That's the same runtime Jarvis uses. Azaris adds hosting, a key vault, a machine per customer, and channels.

His TTS, STT, wake word and dashboard tech aren't public.

## Against this Jarvis

| His feature | Here |
| --- | --- |
| Orb HUD, "Hey Jarvis", voice | Have it. Stat widgets would need a data source (a Hermes tool) |
| Hermes runtime, ChatGPT sign-in | Same |
| Drafts and approval before sending | Have it (guard plugin). Could also gate memory saves |
| Email and calendar | Not yet. See [google.md](google.md) |
| iMessage, Telegram | Hermes `imessage` skill and gateways; mostly config |
| Specialist agents | Hermes `delegate_task` plus cron jobs with defined roles |
| Watchable browser | See [mac-control.md](mac-control.md) |
| 24/7 | His runs on a server; this only runs while the Mac is awake |
| Auto-editing and posting videos | Big job; not a priority |
