"""luaupy: an asmpython backend that emits Luau source for Roblox.

Roblox accepts SOURCE and nothing else. `Script.Source` is a string, and
`loadstring` -- server-only, off by default -- compiles text rather than
loading bytecode. Every design decision here follows from that one fact:

  * Structured control flow only. Luau has no `goto` and no labelled `break`,
    so an IR control-flow graph has to be recovered into `if`/`while`/`repeat`
    before it can be written down at all. That is `structure.py`.
  * Emitting real loops rather than a dispatch ladder, because Roblox compiles
    what we hand it and its optimiser can only work with structure it can see.
    We would lose that by emitting bytecode even if Roblox would take it.
  * 64-bit integers are two values, not one. Luau's only number type is `f64`,
    which is exact to 2^53, and an `i64` add that rounds is worse than one that
    refuses. See `values.py`.

This package lives outside the asmpython tree and requires no edit to it. The
manifest below is read by `asmpython.plugins.load_all()` via the
`asmpython.plugins` entry point declared in `pyproject.toml`.
"""
from __future__ import annotations

from asmpython.plugins import Plugin

from . import emit, structure, target, values

__all__ = ["emit", "structure", "target", "values", "plugin"]
__version__ = "0.1.0"

#: What this package contributes. DECLARED, not done: building this object
#: registers nothing, so `asmpython plugin show luaupy` can report what we
#: provide without letting us change the compiler's state to find out.
plugin = Plugin(
    name="luaupy",
    version=__version__,
    description="Luau source for Roblox",
)
# Targets are registered before backends by `register_all`, which is what
# `LuauBackend.default_target = "roblox"` depends on when one package ships
# both -- a listing that resolved the default would otherwise fail.
plugin.add_target(target.ROBLOX, aliases=target.ALIASES)
plugin.backends.append(emit.LuauBackend())

#: The name `plugins.load()` looks for. A module without one is assumed to have
#: registered itself at import time, which still works and is the older way.
__asmpython_plugin__ = plugin
