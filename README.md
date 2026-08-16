# luaupy

An [asmpython](https://github.com/deltathedumb/asmpython) backend that compiles
Python to **Luau source** for Roblox.

```
python -m pip install -e path/to/asmpython-refactor
python -m pip install -e ".[test]"
python -m asmpython build hello.py --backend luau
#   -> hello/default.project.json
#      hello/src/init.server.luau
#      hello/src/runtime.luau
```

## Why source, not bytecode

Roblox gives no supported path for raw Luau bytecode. `Script.Source` is a
string; `loadstring` is server-only, off by default, and *compiles* text --
there is no `luau_load` exposed to game scripts. So the artifact is `.luau`
text, and Roblox's own compiler runs on it.

That is not purely a tax. Luau's optimiser sees what we emit, so real loops get
inlining and constant folding we would forfeit by shipping bytecode.

## What follows from that

**No `goto`, no labelled `break`.** An IR control-flow graph cannot be
transcribed; it has to be recovered into `if`/`while`/`repeat` first.
`structure.py` does this with Ramsey's dominator-tree algorithm (*Beyond
Relooper*, ICFP 2022). Branches crossing more than one scope use an unwind
variable; the common depth-0 case costs a bare `break`/`continue` and nothing
else. Irreducible graphs are detected and reported rather than mistranslated.

**One number type.** Luau has `f64` and nothing else, exact to 2^53, so `i64`
and `u64` occupy two locals -- a high and a low 32-bit half. This is not a
precision knob: 64-bit arithmetic on doubles is silently wrong above 2^53, and
a compiler that rounds is worse than one that refuses. Everything narrower is
one local, stored as a raw bit pattern with signedness applied only by the
operations that care.

**Flat memory is a `buffer`.** `alloca`/`load`/`store`/`offset` index one
buffer sized by `--luau-heap`. Pointers are offsets into it.

## Status

The opcode table is covered. The Python object model is **not**: asmpython
provides it as 15,000 lines of C that Luau cannot link, so the 274 `apy_*`
functions are still to be ported. Until then a program that does more than
arithmetic and control flow stops at the builtin it needed, naming it:

```
luaupy: apy_str_join is not implemented yet
```

The backend reports `ready = False`, so every build warns.

## Tests

```
python -m pytest -q
```
