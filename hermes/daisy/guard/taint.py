"""Taint: once a turn has read mail, web or file content, new recipients, new URLs and memory
writes need a card, because that content can carry instructions meant for the agent. See
docs/research/orchestrator.md, "Recommended design" §5."""
