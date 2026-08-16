"""How an IR value is spelled in Luau.

Luau has exactly one number type: `f64`. Every decision in this file follows
from that, and from the one place it is not enough.

INTEGERS ARE STORED AS RAW BIT PATTERNS
---------------------------------------
An `i32` holding -1 is stored as `4294967295`, not `-1`. Signedness is applied
by the OPERATIONS that care -- signed division, ordered comparison, arithmetic
shift right, widening, and conversion to float -- and by nothing else.

This is worth the surprise because two's complement makes `add`, `sub`, `mul`,
`and`, `or`, `xor` and `shl` bit-identical for signed and unsigned operands. So
the emitter has one rule per opcode instead of two, and the IR's own promise --
"wraps on overflow" at the declared width -- falls out of a single `% 2^n`
rather than a range-shift on every arithmetic instruction.

The alternative, storing signed types in their natural range, needs
`(a + b + 2^31) % 2^32 - 2^31` for every add.

64-BIT INTEGERS DO NOT FIT AND ARE SPLIT
----------------------------------------
`f64` represents integers exactly only to 2^53. `i64` and `u64` therefore
occupy TWO Luau values -- a high and a low 32-bit half, each an exact integer
in [0, 2^32) -- and one IR register becomes two Luau locals, `r5_h` and `r5_l`.

Not optional and not a precision knob. `i64` arithmetic on doubles is silently
wrong above 2^53: the result is plausible, close, and not the number the
program computed. A compiler that rounds is worse than one that refuses.

Everything else -- `i1` through `i32`, `u8` through `u32`, `f32`, `f64`, `ptr`
-- is one Luau value.

POINTERS ARE BUFFER OFFSETS
---------------------------
`ptr` is 64-bit in the IR type system (`types.py` hard-codes it) so the layout
a frontend computes reserves 8 bytes for one. In Luau it is a plain number:
an index into the single heap `buffer`, which is far below 2^32 in any program
Roblox will run. Storing one writes 8 bytes with the high word zero, so the
layout still agrees with what the frontend computed, and `bitcast ptr -> u64`
is the pair `(0, addr)` rather than anything that needs care.
"""
from __future__ import annotations

from asmpython.ir import types as T

#: Types needing two Luau values. The single predicate everything else asks.
WIDE = frozenset({T.I64, T.U64})

#: 2**32, written once. The emitter interpolates it into arithmetic constantly
#: and `4294967296` typed by hand is a transposition away from a wrong mask.
TWO32 = 4294967296


def is_wide(ty: T.Type) -> bool:
    """True if `ty` occupies two Luau values (a high and a low half)."""
    return ty in WIDE


def slots(ty: T.Type) -> int:
    """How many Luau values a value of `ty` occupies: 2 for 64-bit ints, 1
    otherwise, 0 for void."""
    if ty.is_void:
        return 0
    return 2 if is_wide(ty) else 1


def name(reg: int, ty: T.Type) -> str:
    """The Luau local holding `reg`. Raises for a wide type -- ask for halves.

    Deliberately raises rather than returning the low half: a caller that
    forgot a value was 64-bit gets an error at compile time instead of code
    that silently drops the top 32 bits.
    """
    if is_wide(ty):
        raise ValueError(
            f"%{reg} is {ty}, which occupies two locals; "
            f"use hi()/lo(), or names() to get both"
        )
    return f"r{reg}"


def hi(reg: int) -> str:
    """The local holding the high 32 bits of a 64-bit register."""
    return f"r{reg}_h"


def lo(reg: int) -> str:
    """The local holding the low 32 bits of a 64-bit register."""
    return f"r{reg}_l"


def names(reg: int, ty: T.Type) -> list[str]:
    """Every Luau local backing `reg`, in argument order: high then low.

    High first because that is the order a person reads a 64-bit number in,
    and because the alternative -- low first, as the machine stores it -- made
    every hand-written expectation in the test suite read backwards.
    """
    if ty.is_void:
        return []
    if is_wide(ty):
        return [hi(reg), lo(reg)]
    return [name(reg, ty)]


def mask(ty: T.Type) -> int:
    """The modulus that wraps `ty` to its width: 2**bits.

    Only meaningful for the narrow integer types; a 64-bit value is wrapped a
    half at a time and `f64`/`f32` are not wrapped at all.
    """
    return 1 << ty.bits


def sign_bit(ty: T.Type) -> int:
    """The value of `ty`'s sign bit, for the conversions that need it."""
    return 1 << (ty.bits - 1)


def zero(ty: T.Type) -> list[str]:
    """The initialiser for each local backing a register of `ty`.

    Every local is declared and initialised at the top of its function rather
    than at first assignment. Luau scopes a `local` to the block it appears in,
    and the emitter puts blocks inside `if` arms and loop bodies -- so a
    register first assigned inside one arm and read after it would be `nil`,
    which is not a type error in Luau, it is an arithmetic error at a line that
    does not mention the register.
    """
    if ty.is_void:
        return []
    if is_wide(ty):
        return ["0", "0"]
    return ["0"]


# ── identifiers ─────────────────────────────────────────────────────────────

#: Reserved in Luau. `continue` is contextual rather than reserved, but the
#: emitter generates it, and a local named `continue` shadowing the statement is
#: a class of bug nobody should have to find.
KEYWORDS = frozenset("""
and break do else elseif end false for function if in local nil not or
repeat return then true until while continue
""".split())


def ident(sym: str) -> str:
    """A Luau identifier for an IR symbol.

    IR symbols come from Python source and from hand-written IR, so they may
    hold characters Luau does not allow, may collide with a keyword, and may
    begin with a digit. Each needs a different fix: a keyword stops being one
    with any suffix, but suffixing `2fast` gives `2fast_`, which is still not
    an identifier.
    """
    safe = "".join(c if c.isalnum() or c == "_" else "_" for c in sym)
    if safe and safe[0].isdigit():
        safe = "n" + safe
    if safe in KEYWORDS:
        safe += "_"
    return safe or "_"
