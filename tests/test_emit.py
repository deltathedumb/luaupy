"""Code generation: hand-built IR in, Luau text out.

Assertions are on the emitted text. That is brittle by nature, so they check
the ONE line each test is about rather than whole functions -- a formatting
change should not fail a test about integer width.
"""
from __future__ import annotations

import pytest

from asmpython.backend import BackendUnsupported
from asmpython.ir import types as T
from asmpython.ir.module import Block, Function, Global, Instruction, Module
from asmpython.ir.opcodes import Op

from luaupy.emit import LuauBackend
from luaupy.target import ROBLOX


def build(name: str, ret: T.Type, regs: dict[int, T.Type],
          blocks: dict[str, list[Instruction]],
          params: list[int] | None = None) -> Module:
    f = Function(name=name, ret=ret)
    f.registers = dict(regs)
    f.params = list(params or [])
    f.blocks = [Block(label=k, instructions=list(v)) for k, v in blocks.items()]
    m = Module(name="t")
    m.functions.append(f)
    return m


def luau(module: Module, **kw) -> str:
    art = LuauBackend(**kw).emit(module, ROBLOX)
    key = "init.luau" if kw.get("layout") == "flat" else "src/init.server.luau"
    return art[key].decode("utf-8")


# ── the bug that shipped in the first build ─────────────────────────────────

def test_comparison_names_its_destination_from_the_register_not_ins_ty():
    """A comparison's `ty` is the type of its OPERANDS; its result is `i1`.

    Naming the destination from `ins.ty` gave `r2_h, r2_l = ...` for an i64
    comparison into a one-local i1 register, and every later read of `r2` saw
    a value nothing had assigned -- so a `while i < n` loop exited at once.
    """
    src = luau(build(
        "cmp", T.I1, {0: T.I64, 1: T.I64, 2: T.I1},
        {"entry": [
            Instruction(Op.LT, T.I64, dst=2, args=[0, 1]),
            Instruction(Op.RET, T.I1, args=[2]),
        ]},
        params=[0, 1],
    ))
    assert "r2 = RT.cmp64(r0_h, r0_l, r1_h, r1_l" in src
    assert "r2_h" not in src and "r2_l" not in src


def test_call_returning_i1_declares_one_local():
    """The same rule on the call path, which had its own copy of it."""
    m = build("c", T.I1, {0: T.I1},
              {"entry": [
                  Instruction(Op.CALL, T.I1, dst=0, sym="probe"),
                  Instruction(Op.RET, T.I1, args=[0]),
              ]})
    m.functions.append(Function(name="probe", ret=T.I1, external=True))
    src = luau(m)
    assert "r0 = RT.probe()" in src


# ── widths ──────────────────────────────────────────────────────────────────

def test_i64_occupies_two_locals_and_narrower_types_one():
    src = luau(build(
        "w", T.VOID, {0: T.I64, 1: T.I32, 2: T.F64},
        {"entry": [
            Instruction(Op.CONST, T.I64, dst=0, imm=1),
            Instruction(Op.CONST, T.I32, dst=1, imm=2),
            Instruction(Op.CONST, T.F64, dst=2, imm=3.5),
            Instruction(Op.RET, T.VOID),
        ]},
    ))
    assert "r0_h, r0_l = 0, 1" in src
    assert "r1 = 2" in src
    assert "r2 = 3.5" in src


def test_negative_i32_constant_is_stored_as_a_raw_bit_pattern():
    """Integers are unsigned bit patterns; signedness is applied by the
    operations that care, never stored."""
    src = luau(build(
        "n", T.VOID, {0: T.I32},
        {"entry": [Instruction(Op.CONST, T.I32, dst=0, imm=-1),
                   Instruction(Op.RET, T.VOID)]},
    ))
    assert "r0 = 4294967295" in src


def test_narrow_add_wraps_at_its_declared_width():
    src = luau(build(
        "a", T.VOID, {0: T.I8, 1: T.I8, 2: T.I8},
        {"entry": [Instruction(Op.ADD, T.I8, dst=2, args=[0, 1]),
                   Instruction(Op.RET, T.VOID)]},
    ))
    assert "r2 = (r0 + r1) % 256" in src


def test_32_bit_multiply_does_not_use_a_bare_star():
    """Two 32-bit operands reach 2^64, past what a double holds exactly."""
    src = luau(build(
        "m", T.VOID, {0: T.U32, 1: T.U32, 2: T.U32},
        {"entry": [Instruction(Op.MUL, T.U32, dst=2, args=[0, 1]),
                   Instruction(Op.RET, T.VOID)]},
    ))
    assert "RT.mul32(r0, r1)" in src


def test_signed_comparison_sign_extends_both_operands():
    src = luau(build(
        "s", T.VOID, {0: T.I16, 1: T.I16, 2: T.I1},
        {"entry": [Instruction(Op.LT, T.I16, dst=2, args=[0, 1]),
                   Instruction(Op.RET, T.VOID)]},
    ))
    assert "RT.sext(r0, 16) < RT.sext(r1, 16)" in src


def test_unsigned_comparison_does_not():
    src = luau(build(
        "u", T.VOID, {0: T.U16, 1: T.U16, 2: T.I1},
        {"entry": [Instruction(Op.LT, T.U16, dst=2, args=[0, 1]),
                   Instruction(Op.RET, T.VOID)]},
    ))
    assert "r2 = (r0 < r1) and 1 or 0" in src


# ── control flow reaches the emitter intact ─────────────────────────────────

def test_a_loop_emits_a_real_while_and_a_continue():
    src = luau(build(
        "l", T.VOID, {0: T.I1},
        {
            "entry": [Instruction(Op.JUMP, T.VOID, labels=["head"])],
            "head": [Instruction(Op.BRANCH, T.I1, args=[0],
                                 labels=["body", "out"])],
            "body": [Instruction(Op.JUMP, T.VOID, labels=["head"])],
            "out": [Instruction(Op.RET, T.VOID)],
        },
    ))
    assert "while true do" in src
    assert "continue" in src
    assert "esc" not in src          # depth 0 costs nothing


def test_irreducible_becomes_a_diagnostic_not_a_traceback():
    m = build("irr", T.VOID, {0: T.I1}, {
        "entry": [Instruction(Op.BRANCH, T.I1, args=[0], labels=["a", "b"])],
        "a": [Instruction(Op.JUMP, T.VOID, labels=["b"])],
        "b": [Instruction(Op.BRANCH, T.I1, args=[0], labels=["a", "out"])],
        "out": [Instruction(Op.RET, T.VOID)],
    })
    with pytest.raises(BackendUnsupported) as caught:
        luau(m)
    assert "irreducible" in str(caught.value)


# ── artifacts ───────────────────────────────────────────────────────────────

def test_rojo_layout_names_three_artifacts_program_first():
    """NoToolchain reports the first key written, and the program is more
    interesting to a reader than its project file."""
    art = LuauBackend().emit(build("e", T.VOID, {}, {
        "entry": [Instruction(Op.RET, T.VOID)]}), ROBLOX)
    assert list(art) == ["src/init.server.luau", "src/runtime.luau",
                         "default.project.json"]


def test_flat_layout_is_one_self_contained_file():
    art = LuauBackend(layout="flat").emit(build("e", T.VOID, {}, {
        "entry": [Instruction(Op.RET, T.VOID)]}), ROBLOX)
    assert list(art) == ["init.luau"]
    text = art["init.luau"].decode()
    assert "require(script.Parent.runtime)" not in text
    assert "function RT.add64" in text


def test_globals_get_fixed_offsets_and_their_bytes_blitted():
    m = build("g", T.VOID, {}, {"entry": [Instruction(Op.RET, T.VOID)]})
    m.globals.append(Global(name="msg", size=3, data=b"hi\x00"))
    src = luau(m)
    assert "local g_msg = 4096" in src
    assert 'RT.blit(MEM, 4096, "hi\\0")' in src


def test_luau_keywords_in_ir_symbols_are_mangled():
    m = build("main", T.VOID, {}, {"entry": [Instruction(Op.RET, T.VOID)]})
    m.globals.append(Global(name="end", size=1))
    src = luau(m)
    assert "local g_end_ = " in src


def test_heap_size_is_configurable_and_has_a_floor():
    from asmpython.backend import OptionError
    assert "RT.heap(65536)" in luau(
        build("h", T.VOID, {}, {"entry": [Instruction(Op.RET, T.VOID)]}),
        heap=65536)
    with pytest.raises(OptionError):
        LuauBackend().configure({"luau-heap": "1024"}, None)


def test_configure_returns_a_new_instance():
    """The registry holds one shared backend object; flags stored on `self`
    would leak into the next compilation in the same process."""
    base = LuauBackend()
    tuned = base.configure({"luau-layout": "flat"}, None)
    assert tuned is not base
    assert base.layout == "rojo" and tuned.layout == "flat"
