"""What the Jarvis guard stops for a yes, and what it lets through. Run: python3 hermes/test_jarvis_guard.py"""

import importlib.util
import os
import sys
from pathlib import Path


def load(active: bool):
    if active:
        os.environ["JARVIS_SESSION"] = "1"
    else:
        os.environ.pop("JARVIS_SESSION", None)
    spec = importlib.util.spec_from_file_location("jarvis_plugin", Path(__file__).parent / "jarvis" / "__init__.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class Recorder:
    def __init__(self):
        self.calls = []

    def register_system_prompt_section(self, name, content, **kwargs):
        self.calls.append(("section", name, content))

    def register_hook(self, name, callback):
        self.calls.append(("hook", name, callback))


failures = 0


def check(label, condition):
    global failures
    if not condition:
        failures += 1
        print("FAIL", label)


plugin = load(active=True)

needs_yes = {
    """imsg send --to "Dad" --text "I'll be home at 6\"""": ("jarvis.send-message", "Send an iMessage to Dad — “I'll be home at 6”"),
    """osascript -e 'tell application "Messages" to send "hi" to buddy "+15551234567"'""": ("jarvis.send-message", None),
    "himalaya message send < draft.eml": ("jarvis.send-email", None),
    "gws gmail users messages send --json '{}'": ("jarvis.send-email", None),
    "gws calendar events insert --params '{}'": ("jarvis.calendar-change", None),
    "rm ~/Desktop/Screenshot.png": ("jarvis.delete", None),
    "cd ~/Downloads && rm -f old.zip": ("jarvis.delete", None),
    "find ~/Downloads -name '*.tmp' -delete": ("jarvis.delete", None),
    "remindctl delete 3": ("jarvis.delete", None),
    "gh issue create --title x --body y": ("jarvis.post", None),
}
for command, (rule, description) in needs_yes.items():
    found = plugin.classify("terminal", {"command": command})
    check(f"needs a yes: {command}", found is not None and found[0] == rule)
    if found and description:
        check(f"description: {command}", found[1] == description)

lets_through = [
    "ls ~/Downloads", "mdfind -name resume", "imsg chats --limit 5", "gws calendar events list --params '{}'",
    "du -sh ~/Documents", "open -a Spotify", "grep -r rmdir notes.txt", "echo remove later", "git status",
]
for command in lets_through:
    check(f"lets through: {command}", plugin.classify("terminal", {"command": command}) is None)

check("python delete", plugin.classify("execute_code", {"code": "import os\nos.remove('x')"})[0] == "jarvis.delete")
check("python math", plugin.classify("execute_code", {"code": "print(37 * 18)"}) is None)
check("mcp send", plugin.classify("mcp_messages_send_message", {"to": "Dad"}) is not None)
check("mcp create event", plugin.classify("mcp_calendar_create_event", {})[0] == "jarvis.calendar-change")
check("mcp list events", plugin.classify("mcp_calendar_list_events", {}) is None)
check("read tools untouched", plugin.classify("read_file", {"path": "/tmp/x"}) is None)

directive = plugin._on_pre_tool_call(tool_name="terminal", args={"command": "imsg send --to Dad --text hi"})
check("hook asks for approval", directive and directive["action"] == "approve" and directive["rule_key"] == "jarvis.send-message")
check("hook passes reads", plugin._on_pre_tool_call(tool_name="terminal", args={"command": "ls"}) is None)

active = Recorder()
plugin.register(active)
check("registers persona and hook under Jarvis", [c[:2] for c in active.calls] == [("section", "jarvis-persona"), ("hook", "pre_tool_call")])
check("persona is bounded", len(plugin._persona()) <= 4000)

idle = Recorder()
load(active=False).register(idle)
check("does nothing outside Jarvis", idle.calls == [])

print("guard checks:", "ok" if failures == 0 else f"{failures} failed")
sys.exit(1 if failures else 0)
