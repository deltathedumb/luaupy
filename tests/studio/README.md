# Studio tests

The Python suite (`python -m pytest`) checks what luaupy *emits*. It cannot
check whether that text is correct Luau, or whether the runtime's arithmetic is
right, because neither runs anywhere a Python test can reach.

These run in Roblox Studio, and everything here was written because reasoning
alone got it wrong. Three bugs shipped past code review and local tests, and
all three were found by executing this:

| Bug | Symptom |
|---|---|
| `div64` routed through `to_number` | exact to 2^53 only; `(2^64-1)/2` gave a quotient that multiplies back to 0 |
| `from_number` negated by adding 2^64 | the addition happens above 2^53, so low bits round away; `widen(-1705032704)` was 1024 short |
| flat layout pasted the runtime ahead of the program | the runtime ends in `return RT`, which at chunk level returns from the whole file, making the program dead code that neither ran nor errored |

## Running them

`runtime_property.luau` is self-contained. Paste it into a Studio command bar
or run it through the MCP `execute_luau` tool. It prints `PASS=n FAIL=n` and
the first few mismatches.

It does **not** compare against precomputed answers. It builds an independent
reference out of 16-bit limbs -- every partial product stays far below 2^53, so
the reference is exact by construction -- and checks `RT` against it. Division
is checked by the identity `q*b + r == a` with the remainder in range, which
catches a quotient that lost precision without needing to know the right answer
in advance.

## Differential testing against the IR interpreter

The stronger check, and the one to reach for when adding an opcode. Build an IR
module, run it through `asmpython.ir.interpreter` (the executable
specification: *"any difference is the backend's bug, localised to one
program"*), compile the same module with `LuauBackend`, run that in Studio, and
compare. `scratchpad/gen_diff.py` in the session that wrote this did exactly
that and found two emitter bugs the property test could not see, because both
were in code generation rather than arithmetic:

* `OFFSET` named its integer operand as a single local, which is wrong for a
  64-bit offset and *silently* wrong for a narrow signed one -- `-1:i32` is
  stored as `4294967295`, so `p + r` added four billion instead of stepping
  back a byte.
* `SWITCH` compared a 64-bit scrutinee as one local, and matched case values
  as signed integers against registers holding raw bit patterns, so `case -1`
  on an `i32` could never fire.

Once the object runtime lands, asmpython's own test suite is the better source
of truth at scale -- it passes under both CPython and asmpython.
