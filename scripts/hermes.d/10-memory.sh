# Learning without /remember. After a turn, Hermes can fork a copy of itself that re-reads the chat
# and saves anything worth keeping (agent/background_review.py). It runs once every
# memory.nudge_interval user turns without a memory write; Hermes ships with 10, which in practice
# meant it never ran. Every 3 turns makes it a habit. Each review is one more model call on the
# ChatGPT plan. What it saves shows up in Daisy's Memory tab under Learned, with Undo.
config_set memory.nudge_interval 3
