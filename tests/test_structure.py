"""Structuring tests: IR control-flow graphs in, structured trees out.

These assert on `structure.dump()` rather than on emitted Luau. A structuring
bug and a code-generation bug look alike when the only thing you can observe is
the final source, and they are fixed in different files.
"""
from __future__ import annotations

import pytest

from asmpython.ir import types as T
from asmpython.ir.module import Block, Function, Instruction
from asmpython.ir.opcodes import Op

from luaupy.structure import Irreducible, dump, structure


# ── building IR by hand ─────────────────────────────────────────────────────
# Directly rather than through ir.builder: these are control-flow shapes, and
# the point is to write the graph down exactly, including the ones a frontend
# would never produce.

def jump(to: str) -> Instruction:
    return Instruction(Op.JUMP, T.VOID, labels=[to])


def branch(cond: int, then_: str, else_: str) -> Instruction:
    return Instruction(Op.BRANCH, T.I1, args=[cond], labels=[then_, else_])


def switch(value: int, cases: list[tuple[int, str]], default: str) -> Instruction:
    return Instruction(Op.SWITCH, T.I64, args=[value],
                       labels=[default], cases=cases)


def ret(reg: int | None = 1) -> Instruction:
    return Instruction(Op.RET, T.I64, args=[] if reg is None else [reg])


def fn(name: str, blocks: dict[str, list[Instruction]]) -> Function:
    f = Function(name=name, ret=T.I64)
    f.registers = {0: T.I1, 1: T.I64, 2: T.I64}
    f.blocks = [Block(label=label, instructions=list(instrs))
                for label, instrs in blocks.items()]
    return f


def tree(f: Function) -> str:
    """The structured tree, rendered with block labels rather than indices."""
    return dump(structure(f).root, [b.label for b in f.blocks])


# ── the shapes a frontend actually emits ────────────────────────────────────

def test_straight_line_has_no_scopes():
    """Two blocks in a row inline into each other: no loop, no block, no br."""
    out = tree(fn("straight", {
        "entry": [jump("second")],
        "second": [ret()],
    }))
    assert out == "code entry\ncode second\nret %1"


def test_diamond_places_the_join_in_a_block_scope():
    """if/else meeting at a merge point.

    The join has two forward predecessors, so it cannot be inlined at either
    arm; it goes after a block scope that encloses both.
    """
    out = tree(fn("diamond", {
        "entry": [branch(0, "then", "else")],
        "then": [jump("join")],
        "else": [jump("join")],
        "join": [ret()],
    }))
    assert out == "\n".join([
        "block join:",
        "  code entry",
        "  if %0:",
        "    code then",
        "    br join",
        "  else:",
        "    code else",
        "    br join",
        "code join",
        "ret %1",
    ])


def test_while_loop_becomes_a_loop_scope():
    out = tree(fn("while_loop", {
        "entry": [jump("head")],
        "head": [branch(0, "body", "exit")],
        "body": [jump("head")],
        "exit": [ret()],
    }))
    assert out == "\n".join([
        "code entry",
        "loop head:",
        "  code head",
        "  if %0:",
        "    code body",
        "    br head",
        "  else:",
        "    code exit",
        "    ret %1",
    ])


def test_if_without_else_still_inlines_the_tail():
    """A one-armed `if` whose tail has two predecessors is still a merge."""
    out = tree(fn("if_only", {
        "entry": [branch(0, "body", "tail")],
        "body": [jump("tail")],
        "tail": [ret()],
    }))
    assert "block tail:" in out
    assert out.count("br tail") == 2


def test_switch_becomes_a_ladder_with_a_default():
    out = tree(fn("sw", {
        "entry": [switch(1, [(1, "one"), (2, "two")], "other")],
        "one": [jump("join")],
        "two": [jump("join")],
        "other": [jump("join")],
        "join": [ret()],
    }))
    assert "switch %1:" in out
    assert "case 1:" in out and "case 2:" in out and "default:" in out
    assert out.count("br join") == 3


# ── the escape machinery ────────────────────────────────────────────────────

def test_depth_zero_branches_need_no_escape_variable():
    """The common case pays nothing: no `esc`, no unwind checks."""
    s = structure(fn("diamond", {
        "entry": [branch(0, "then", "else")],
        "then": [jump("join")],
        "else": [jump("join")],
        "join": [ret()],
    }))
    assert not s.needs_escape
    assert s.far_targets == set()
    assert s.check_after == set()


def test_break_out_of_two_loops_records_every_crossed_scope():
    """The case that `far_targets` alone gets wrong.

    `inner_body` branches to `done` (crossing the inner loop) and `inner`
    branches to `outer` (crossing both the inner loop and the `done` block).
    Nothing targets the inner loop, but control passes out through it, so its
    close still needs an unwind check -- otherwise execution falls into the
    code after it with `esc` still set. That is the case an emitter driven by
    `far_targets` alone gets wrong, and it is why both sets exist.
    """
    f = fn("nested_break", {
        "entry": [jump("outer")],
        "outer": [branch(0, "inner", "done")],
        "inner": [branch(0, "inner_body", "outer")],
        "inner_body": [branch(0, "done", "inner")],
        "done": [ret()],
    })
    s = structure(f)
    label = {b.label: i for i, b in enumerate(f.blocks)}

    assert s.needs_escape
    # Targeted from a distance: the outer loop and the `done` merge.
    assert s.far_targets == {label["outer"], label["done"]}
    # Checked on close: the `done` block, which is exited to reach it, and the
    # inner loop, which is only ever passed through. The OUTER loop is targeted
    # but never exited -- a `continue` re-enters it at the top -- so it is not
    # part of any break chain and needs no check of its own.
    assert s.check_after == {label["done"], label["inner"]}
    assert label["inner"] not in s.far_targets
    assert label["outer"] not in s.check_after


def test_a_loop_target_does_not_unwind_its_own_scope():
    """`continue` re-enters a loop at its top, so the loop's own scope is
    crossed but never exited -- one fewer level than a block target."""
    f = fn("continue_outer", {
        "entry": [jump("outer")],
        "outer": [branch(0, "mid", "done")],
        "mid": [branch(0, "inner", "outer")],
        "inner": [branch(0, "outer", "mid")],   # continue the OUTER loop
        "done": [ret()],
    })
    s = structure(f)
    label = {b.label: i for i, b in enumerate(f.blocks)}
    assert label["outer"] in s.far_targets
    # The outer loop is re-entered, not left, so it is not in the break chain.
    assert label["outer"] not in s.check_after


# ── the graphs that have no structured form ─────────────────────────────────

def test_irreducible_loop_is_detected_not_mistranslated():
    """Two entries into one loop. Reported, so a backend can fall back."""
    f = fn("irreducible", {
        "entry": [branch(0, "a", "b")],
        "a": [jump("b")],
        "b": [branch(0, "a", "exit")],
        "exit": [ret()],
    })
    with pytest.raises(Irreducible) as caught:
        structure(f)
    assert caught.value.function == "irreducible"
    assert ("b", "a") in caught.value.edges


def test_unreachable_blocks_are_reported_rather_than_emitted():
    f = fn("with_dead", {
        "entry": [ret()],
        "dead": [jump("entry")],
    })
    s = structure(f)
    assert s.unreachable == [1]
    assert "dead" not in dump(s.root, [b.label for b in f.blocks])


def test_empty_function_structures_to_nothing():
    f = Function(name="empty", ret=T.VOID)
    s = structure(f)
    assert dump(s.root) == ""
    assert not s.needs_escape
