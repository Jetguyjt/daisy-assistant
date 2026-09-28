# shellcheck shell=bash
# computer_act can look at the window again right after it acts (capture_after). Make that follow-up
# read the accessibility tree like computer_look does, instead of Hermes's default screenshot. It's
# the same setting for Hermes's own computer_use tool in the CLI.
config_set computer_use.capture_after_mode ax
