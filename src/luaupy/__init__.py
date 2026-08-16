"""luaupy: an asmpython backend that emits Luau source for Roblox.

Roblox accepts SOURCE and nothing else. `Script.Source` is a string, and
`loadstring` -- server-only and off by default -- compiles text rather than
loading bytecode. So this backend's artifacts are `.luau` files, and every
design decision downstream follows from that one fact:

  * Structured control flow only. Luau has no `goto` and no labelled `break`,
    so an IR control-flow graph has to be recovered into `if`/`while`/`repeat`
    before it can be written down at all. That is `structure.py`.
  * Luau's own optimiser runs on what we emit, which is a reason to emit real
    loops rather than a dispatch ladder -- we get its inliner and constant
    folder for free, and we would lose both by emitting bytecode even if
    Roblox would take it.

This package lives outside the asmpython tree on purpose. `Backend` and
`Target` are both registered through the same public calls a built-in uses, so
nothing here requires an edit to the compiler.
"""
from __future__ import annotations

from . import structure

__all__ = ["structure"]
__version__ = "0.1.0"
