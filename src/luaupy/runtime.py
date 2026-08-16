"""Loads the Luau runtime from `luau/*.luau`.

The runtime is Luau, so it is written in Luau files rather than held in a
Python string. That is worth the packaging cost: at nineteen hundred lines it
needs an editor that knows the language, `luau-lsp` needs a real file to check,
and a syntax error inside a Python string is a runtime surprise in Roblox
rather than a red underline while writing it.

asmpython keeps its C runtime the other way round, as a string in
`link/runtime.py`. That is the right call for a file nobody edits by hand and
the wrong one here.

WHAT GETS ASSEMBLED
-------------------
    runtime.luau    the machine layer -- flat memory, 64-bit integers, the
                    conversions that need a bit pattern, indirect calls
    objects.luau    the Python object model, spliced in at `@OBJECTS@`

Spliced rather than concatenated, because `objects.luau` defines
`function RT.apy_*` and has to land INSIDE the module: after `local RT = {}`
and before `return RT`. Appending it would put every definition after the
module had already returned, which raises nothing at all and leaves every
`apy_*` reaching the not-implemented metatable.
"""
from __future__ import annotations

from functools import lru_cache
from pathlib import Path

#: Where module globals start. Below this the runtime keeps its own
#: bookkeeping, and address 0 stays unmapped so a null dereference is an error
#: rather than a read of whatever happens to be first.
HEAP_BASE = 4096

_LUAU = Path(__file__).parent / "luau"

#: The marker `runtime.luau` carries where the object model belongs.
_OBJECTS_MARKER = "@OBJECTS@"

#: The object model, in load order. Split by area rather than kept in one file
#: because `objects.luau` alone is already fourteen hundred lines, and because
#: a group is the unit that gets written, tested against CPython, and argued
#: about.
#:
#: ORDER MATTERS ONLY FOR LOCALS. Every module defines `function RT.apy_*`,
#: which is late-bound, so a later module may call an earlier one's ABI freely.
#: What it may NOT do is reach a `local` from another file -- those are per
#: chunk, and the shared ones are published on RT by `objects.luau`.
_MODULES = (
    "objects.luau",     # the foundation: handles, errors, numbers, containers
    "strings.luau",     # str methods
    "builtins.luau",    # range, sorted, min/max/sum, cursors, list/dict methods
    "sets.luau",        # set and frozenset, plus update/clear/copy
    "numbers.luau",     # bit inspection, base conversion, divmod, slice objects
    "classes.luau",     # classes, descriptors, dict views, match, misc helpers
    "typing.luau",      # the inert typing surface, and import
    "async.luau",       # generators, coroutines, asyncio, inspect
)


def _read(name: str) -> str:
    path = _LUAU / name
    try:
        return path.read_text(encoding="utf-8")
    except FileNotFoundError:
        raise FileNotFoundError(
            f"{path} is missing. The .luau sources are package data; an "
            f"install that dropped them produces a backend that emits a "
            f"program with no runtime beside it."
        ) from None


@lru_cache(maxsize=1)
def runtime_luau() -> str:
    """The complete runtime: machine layer with the object model spliced in.

    Cached because `emit()` asks for it once per compilation and the answer
    never varies within a process.
    """
    shell = _read("runtime.luau")
    if _OBJECTS_MARKER not in shell:
        raise AssertionError(
            f"runtime.luau lost its {_OBJECTS_MARKER} marker; the object "
            f"model has nowhere to go and every apy_* would fall through to "
            f"the not-implemented metatable"
        )
    body = "\n".join(_read(name) for name in _MODULES)
    return shell.replace(_OBJECTS_MARKER, body)


def sources() -> dict[str, str]:
    """Every .luau file, by name. For tests that check them individually."""
    return {p.name: p.read_text(encoding="utf-8")
            for p in sorted(_LUAU.glob("*.luau"))}


def __getattr__(name: str) -> str:
    """`RUNTIME_LUAU` kept working as a module attribute.

    A function is the honest interface now that this reads files, but the
    emitter and its tests spell it as a constant, and a module-level
    `__getattr__` costs one line rather than a rename across three files.
    """
    if name == "RUNTIME_LUAU":
        return runtime_luau()
    raise AttributeError(name)
