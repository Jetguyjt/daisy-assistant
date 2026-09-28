"""Which cheaper model the always-on runs use, out of what Hermes lists for the current provider.

  <Hermes's python> models.py list     the provider, the model in use and what Hermes lists for it,
                                       as JSON (the same list `hermes model` shows)
  python3 models.py pick < list.json   three lines: the pick (empty when there's none), the provider,
                                       and why

The rule: a model whose name marks the small tier ("mini"), newest version first, and on a tie the one
Hermes lists first. Never the model already in use, never a large-context variant ("-900k"). If the model
in use is already a mini, or nothing mini is listed, there's no pick and delegation.model is left alone.
Nano-class models are left out on purpose: subagents still call tools.

`list` imports Hermes, so run it with Hermes's own Python. It can make the same network request
`hermes model` does when Hermes's model cache is more than an hour old. `pick` needs nothing but python3.
"""

import json
import re
import sys

SMALL = {"mini"}
_CONTEXT_VARIANT = re.compile(r"^\d+[km]$")
_VERSION = re.compile(r"\d+(?:\.\d+)*")


def words(model):
    """Name parts, without a vendor prefix: "openai/gpt-5.4-mini" -> ["gpt", "5.4", "mini"]."""
    name = str(model or "").strip().lower().rsplit("/", 1)[-1]
    return [part for part in re.split(r"[-_:\s]+", name) if part]


def small(model):
    return bool(SMALL & set(words(model)))


def variant(model):
    return any(_CONTEXT_VARIANT.match(part) for part in words(model)[1:])


def version(model):
    """(5, 4) for gpt-5.4-mini, (4,) for o4-mini, () when there's no number."""
    name = str(model or "").lower().rsplit("/", 1)[-1]
    found = _VERSION.search(name)
    return tuple(int(part) for part in found.group().split(".")) if found else ()


def pick(models, current=""):
    """(model or None, why)."""
    listed = [str(model).strip() for model in models or [] if str(model or "").strip()]
    current = str(current or "").strip()
    if not listed:
        return None, "Hermes didn't list any models for this provider"
    if current and small(current):
        return None, f"{current} is already a mini model"
    candidates = [model for model in listed if small(model) and not variant(model)
                  and model.lower() != current.lower()]
    if not candidates:
        return None, "nothing mini is listed for this provider"
    best = max(candidates, key=lambda model: (version(model), -listed.index(model)))
    return best, f"{best}: the newest mini model Hermes lists" + (f" (the default is {current})" if current else "")


def listing():
    """Only with Hermes's Python: what `hermes model` would offer for the provider in use."""
    from hermes_cli.config import load_config
    from hermes_cli.models import cached_provider_model_ids

    model = (load_config() or {}).get("model") or {}
    if not isinstance(model, dict):
        model = {"default": str(model)}
    provider = str(model.get("provider") or "").strip()
    current = str(model.get("default") or model.get("model") or "").strip()
    models = list(cached_provider_model_ids(provider)) if provider else []
    return {"provider": provider, "current": current, "models": models}


def main(argv):
    command = argv[1] if len(argv) > 1 else ""
    if command == "list":
        print(json.dumps(listing()))
        return 0
    if command == "pick":
        try:
            data = json.loads(sys.stdin.read() or "{}")
        except ValueError:
            data = None
        if not isinstance(data, dict):
            print("\n\nHermes's model list couldn't be read")
            return 0
        chosen, why = pick(data.get("models") or [], data.get("current") or "")
        provider = str(data.get("provider") or "").strip()
        print("\n".join((chosen or "", provider if chosen else "", why)))
        return 0
    print(__doc__.strip(), file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
