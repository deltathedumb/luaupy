"""Declaring this backend's own runtime symbols to the frontend.

WHY A PATCH IS NEEDED AT ALL
----------------------------
`Backend.modules` lets a backend say `from luau import l_exec` resolves. It
does NOT let it introduce the symbol behind it: the frontend declares its
externals from fixed tables -- `_RUNTIME`, `_PLATFORM_IR` and the `apy_*` set
parsed out of `link/objects.py` -- and a symbol missing from all three is
rejected by the verifier with

    call to unknown function 'luau_l_exec'

which reports as a compiler bug. The built-in example works only because
`math.sqrt` names `apy_math_sqrt`, which is already in the C.

So a backend that ships a runtime function of its own has to declare it, and
the extension point for "what the registries do not cover" is a patch. This is
the whole of it: one wrap, appending declarations to the module the frontend
just built.

WHY IT WRAPS RATHER THAN REPLACES
---------------------------------
`wrap` composes -- two plugins wrapping the same function both run, in install
order, neither knowing about the other. `replace` would make luaupy the only
plugin that can ever extend lowering, which is a rule nobody asked for.

WHY AFTER LOWERING AND NOT BEFORE
---------------------------------
The call site is created DURING lowering, from `Backend.modules`, and the
declaration only has to exist before `verify()` runs. Appending afterwards also
steps around the frontend's own pruning of unused externals, which drops
anything not in those same three tables.
"""
from __future__ import annotations

from asmpython.ir import types as T
from asmpython.ir.module import Function, Linkage
from asmpython.plugins import CompilerPatch

#: This backend's runtime functions, as IR signatures.
#:
#: `ptr` is what `apy_value` is at the IR boundary, so a function taking and
#: returning a Python value is `(ptr) -> ptr`. Kept beside `LuauBackend.modules`
#: in spirit and checked against it by a test: a declaration with no module
#: entry is unreachable, and a module entry with no declaration is the error
#: above.
RUNTIME_SYMBOLS: dict[str, tuple[list[T.Type], T.Type]] = {
    "luau_l_exec": ([T.PTR], T.PTR),
}


def _declare(module) -> None:
    """Add any of our symbols the module does not already declare."""
    existing = {f.name for f in module.functions}
    for name, (params, ret) in RUNTIME_SYMBOLS.items():
        if name in existing:
            continue
        fn = Function(name, ret, external=True, linkage=Linkage.IMPORT)
        for i, ty in enumerate(params):
            fn.params.append(i)
            fn.registers[i] = ty
        module.functions.append(fn)


def _wrap_run(original, self):
    module = original(self)
    _declare(module)
    return module


#: Patched on the Lowerer rather than on a free function because that is what
#: the driver actually calls. Patching a name someone imported with
#: `from ... import run` would rebind a module attribute nothing reads.
PATCHES = [
    CompilerPatch(
        "asmpython.frontends.python.lower.Lowerer.run",
        wrap=_wrap_run,
        reason="declare luaupy's own runtime symbols, so `from luau import "
               "l_exec` links",
    ),
]
