"""The typed-tool contract: cards are complete, approvals are single-use, reads don't prompt.
Run: python3 hermes/test_daisy_registry.py"""

import importlib.util
import json
import os
import sys
from pathlib import Path


def load():
    os.environ["DAISY_SESSION"] = "1"
    for name in [n for n in sys.modules if n == "daisy_plugin" or n.startswith("daisy_plugin.")]:
        del sys.modules[name]
    folder = Path(__file__).parent / "daisy"
    spec = importlib.util.spec_from_file_location("daisy_plugin", folder / "__init__.py", submodule_search_locations=[str(folder)])
    module = importlib.util.module_from_spec(spec)
    sys.modules["daisy_plugin"] = module
    spec.loader.exec_module(module)
    return module


failures = 0


def check(label, condition):
    global failures
    if not condition:
        failures += 1
        print("FAIL", label)


plugin = load()
registry = plugin.registry
params = {"type": "object", "properties": {"to": {"type": "string"}, "body": {"type": "string"}}, "required": ["to", "body"]}
long_body = "x" * 5000 + " END"

send = registry.add(registry.TypedTool(
    name="fake_send", description="Send a fake message.", parameters=params, risk="send",
    card=lambda a: f"Send a message to {a['to']}\nTo: {a['to']}\nBcc: boss@example.com\n\n{a['body']}",
    run=lambda a: {"sent": True, "to": a["to"]}))
lookup = registry.add(registry.TypedTool(
    name="fake_lookup", description="Look something up.", parameters={"type": "object", "properties": {}}, risk="read",
    card=lambda a: "unused", run=lambda a: {"ok": True}))
broken = registry.add(registry.TypedTool(
    name="fake_broken", description="Always fails.", parameters={"type": "object", "properties": {}}, risk="write",
    card=lambda a: "Break something", run=lambda a: 1 / 0))

first = plugin.on_pre_tool_call(tool_name="fake_send", args={"to": "Dad", "body": long_body})
second = plugin.on_pre_tool_call(tool_name="fake_send", args={"to": "Dad", "body": "hi"})
check("send asks", first and first["action"] == "approve")
check("title comes first", first["message"].startswith("Send a message to Dad — "))
check("card is not truncated", first["message"].endswith(long_body) and "Bcc: boss@example.com" in first["message"])
check("each call gets its own rule key", first["rule_key"] != second["rule_key"])
check("reads don't ask", plugin.on_pre_tool_call(tool_name="fake_lookup", args={}) is None)
check("writes ask", plugin.on_pre_tool_call(tool_name="fake_broken", args={})["action"] == "approve")

check("handler returns JSON", json.loads(registry.handler_for(send)({"to": "Dad", "body": "hi"})) == {"sent": True, "to": "Dad"})
check("handler turns errors into data", "ZeroDivisionError" in json.loads(registry.handler_for(broken)({}))["error"])


class Recorder:
    def __init__(self):
        self.tools = []

    def register_system_prompt_section(self, *a, **k):
        pass

    def register_hook(self, *a, **k):
        pass

    def register_tool(self, name, toolset, schema, handler, **kwargs):
        self.tools.append((name, toolset, schema["name"], schema["parameters"]["type"]))


recorder = Recorder()
plugin.register(recorder)
check("typed tools register into hermes-acp", ("fake_send", "hermes-acp", "fake_send", "object") in recorder.tools)

for bad in [dict(risk="explode"), dict(name="Bad Name"), dict(parameters={"type": "string"})]:
    fields = dict(name="fake_bad", description="", parameters={"type": "object"}, risk="read", card=lambda a: "", run=lambda a: None)
    fields.update(bad)
    try:
        registry.add(registry.TypedTool(**fields))
        check(f"rejects {bad}", False)
    except ValueError:
        pass

picture = registry.add(registry.TypedTool(
    name="fake_picture", description="", parameters={"type": "object"}, risk="read",
    card=lambda a: "Look", run=lambda a: {"_multimodal": True, "content": [], "text_summary": "a window"}))
check("a picture envelope reaches Hermes as is", registry.handler_for(picture)({}) == {"_multimodal": True, "content": [], "text_summary": "a window"})
plain = registry.add(registry.TypedTool(
    name="fake_plain", description="", parameters={"type": "object"}, risk="read", card=lambda a: "Look", run=lambda a: {"a": 1}))
check("any other dict is sent as JSON", registry.handler_for(plain)({}) == '{"a": 1}')

print("registry checks:", "ok" if failures == 0 else f"{failures} failed")
sys.exit(1 if failures else 0)
