"""Tool families (chrome.py, google.py, contacts.py, computer.py, ...). Each module adds its typed
tools to the registry when imported, and this package imports every module in it, so adding a
family is just adding a file."""

import importlib
import pkgutil

for _module in pkgutil.iter_modules(__path__):
    if not _module.name.startswith(("_", "test")):
        importlib.import_module(f"{__name__}.{_module.name}")
