"""The Python object model — see `luau/objects.luau`.

This module exists only so the Luau can be reached from Python. The
implementation, and the commentary explaining it, lives in the `.luau` file
where an editor and `luau-lsp` can read it.

WHAT IS IMPLEMENTED THERE
-------------------------
asmpython specifies the object model in C — `link/objects.py`, some 15,600
lines — and links it into compiled programs. Luau cannot link C, so
`objects.luau` is a second implementation of the same ABI.
`ir/objects_host.py` is a third, in Python, for the reference interpreter;
where the three disagree the C is the specification and the interpreter is the
adjudicator.

A Python value is an INTEGER HANDLE into a Luau table, exactly as
`objects_host.py` uses an index into a Python list, and for the same reason:
the host language's own values do the work, so string behaviour and container
semantics come from Luau rather than being restated. Handle 0 is NULL and means
an error is set — that is the C's convention, and generated code tests it.
"""
from __future__ import annotations

from .runtime import _read


def objects_luau() -> str:
    """The object model's Luau source."""
    return _read("objects.luau")


def __getattr__(name: str) -> str:
    if name == "OBJECTS_LUAU":
        return objects_luau()
    raise AttributeError(name)
