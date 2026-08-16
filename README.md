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

The opcode table is covered, and all **274** exported `apy_*` symbols are
implemented in `src/luaupy/luau/`. What remains is verification against real
compiled programs rather than against the ABI in isolation.

Known gaps, each recorded where it lives rather than papered over:

* **str is bytes, not code points.** Case conversion and the classification
  predicates agree with Python for ASCII and differ above it. The C reaches a
  909-line unicode table that is not ported.
* **MRO is depth-first**, not C3. The two agree for every hierarchy without
  diamonds.
* **`float.hex` / `float.fromhex` raise.** They need an exact
  binary-exponent formatter, and the whole reason those methods exist is that
  a decimal approximation loses bits.
* **Generator driving is unverified.** The state-machine protocol follows the
  C's shape, but nothing has run generator code the frontend emitted.

The backend still reports `ready = False`.

## Tests

```
python -m pytest -q          # 518 tests
```

The Luau is executed, not just generated. `tests/test_*_luau.py` assembles the
runtime, runs it under the real `luau` binary, and compares every answer to the
same expression evaluated in CPython — expectations are computed, never typed,
so a case cannot encode an expectation that is wrong in the same way the code
is. Get the toolchain with:

```
mkdir .tools && cd .tools
curl -sSL -o luau.zip   https://github.com/luau-lang/luau/releases/latest/download/luau-windows.zip
unzip luau.zip
```

Without it those tests skip, and the runtime is then unverified.
