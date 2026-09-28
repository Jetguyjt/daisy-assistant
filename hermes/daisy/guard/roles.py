"""Per-role tool allowlists: chat (the voice/typed session), worker (read-only background jobs) and
cron (read-only plus a few pre-approved actions with fixed parameters). Anything not on a role's list
is blocked. See docs/research/orchestrator.md, "Recommended design" §5."""
