"""Classes, descriptors, views, match, typing and async, run under `luau`.

These need several statements each, so they live in `tests/luau/tier4.luau`
rather than in the expression-pair harness the other suites use. The
expectations are here.

Where a value is what CPython would print, the expectation is `repr(...)`
evaluated in this process, as everywhere else. Where it is a runtime detail
with no Python equivalent -- a descriptor's kind number, whether a slot is
filled -- it is a literal, and the case name says which.
"""
from __future__ import annotations

import subprocess
from pathlib import Path

import pytest

from luaupy.runtime import runtime_luau
from test_runtime_luau import _binary, needs_luau

SCRIPT = Path(__file__).parent / "luau" / "tier4.luau"


@pytest.fixture(scope="module")
def answers(tmp_path_factory) -> dict[str, str]:
    luau = _binary("luau")
    if luau is None:
        pytest.skip("no luau binary; see test_runtime_luau for the download")
    path = tmp_path_factory.mktemp("tier4") / "tier4.luau"
    path.write_text(
        "local RT = (function()\n" + runtime_luau() + "\nend)()\n"
        + SCRIPT.read_text(encoding="utf-8"),
        encoding="utf-8",
    )
    proc = subprocess.run([luau, str(path)], capture_output=True, text=True)
    assert proc.returncode == 0, proc.stderr or proc.stdout
    return dict(line.split("\t", 1)
                for line in proc.stdout.splitlines() if "\t" in line)


EXPECTED = {
    # A view reads the dict when ASKED, not when made. This pair is the whole
    # point of having views at all, and the earlier list-returning version got
    # `view_after` wrong.
    "view_before": repr(["a"]),
    "view_after": repr(["a", "b"]),
    "view_values": repr([1, 2]),
    "view_items": repr([("a", 1), ("b", 2)]),

    # type(1) is type(2) must hold, so the type object is cached by name.
    "type_is_stable": "True",
    "type_name": repr("int"),
    "type_of_str": "True",
    "type_int_vs_str": "False",
    "object_class_stable": "True",

    "class_repr": "<class 'Point'>",
    "class_attr": repr("point"),
    # A class-level CONSTANT reached through an instance is the value, not a
    # bound method wrapping it.
    "inst_attr_from_class": repr("point"),
    "inst_own_attr": "3",
    "inst_type_name": repr("Point"),
    "subclass_own": "9",
    "subclass_inherited": "true",
    "subclass_missing": "true",

    "descr_kind_property": "0",
    "descr_has_setter": "true",
    "descr_kind_classmethod": "1",

    "super_kind": "super",
    "super_rejects_nontype": "true",

    # A str IS a sequence and deliberately does not match as one, or `case [x]`
    # would destructure "a" into its characters.
    "match_seq_list": "1",
    "match_seq_str": "0",
    "match_map_dict": "1",
    "match_map_list": "0",
    "match_args_empty": repr(()),
    "match_rest": repr({"b": 2}),

    "unpack_ok": "true",
    "unpack_too_few": "not enough values to unpack (expected 5, got 3)",
    "unpack_too_many": "too many values to unpack (expected 2)",
    "unpack_at_least": "true",

    "ns_get_hit": "7",
    "ns_get_miss": "NameError: name 'y' is not defined",
    "name_or_hit": "1",
    "name_or_fallback": "2",

    "get_origin_name": "list",
    "get_args_len": "1",
    # Not a generic: origin is None and args is an EMPTY TUPLE rather than
    # None, so a caller can iterate the result without checking first.
    "get_origin_plain": repr(None),
    "get_args_plain": repr(()),
    "typevar_name": "T",
    "typevar_has_default": "true",
    "import_known": "math",
    "import_unknown": "ModuleNotFoundError",

    "is_generator": "True",
    "is_coroutine_no": "False",
    "is_coroutine_yes": "True",
    "is_generator_now_no": "False",
    "is_asyncgen": "True",
    "await_rejects_nongen": "true",

    "sleep_is_coro": "True",
    "run_sleep": repr(None),
    "run_rejects_nonstop": "ValueError",
    "task_done_before": "False",
    # An unfinished task has no result, and answering None would hide the bug.
    "task_result_unfinished": "RuntimeError",

    "group_subs": "2",
    "group_split_hit": "1",
    "group_split_miss": "1",

    "print_seq_returns": repr(None),
}


@needs_luau
@pytest.mark.parametrize("key", sorted(EXPECTED))
def test_tier4(answers: dict[str, str], key: str):
    assert key in answers, f"tier4.luau produced no {key!r}"
    assert answers[key] == EXPECTED[key]


@needs_luau
def test_every_answer_is_checked(answers: dict[str, str]):
    unchecked = sorted(set(answers) - set(EXPECTED))
    assert not unchecked, f"produced but never compared: {unchecked}"


def test_the_whole_abi_is_implemented():
    """Every exported apy_* symbol has a definition somewhere in the runtime.

    The backend's promise: a compiled program cannot reach the
    not-implemented metatable for a symbol asmpython exports.
    """
    import re
    from asmpython.link.objects import OBJECT_NAMES
    luau_dir = Path(__file__).resolve().parent.parent / "src" / "luaupy" / "luau"
    defined: set[str] = set()
    for path in luau_dir.glob("*.luau"):
        defined |= set(re.findall(r"function RT\.(apy_\w+)",
                                  path.read_text("utf-8")))
    missing = set(OBJECT_NAMES) - defined
    assert not missing, f"{len(missing)} unimplemented: {sorted(missing)}"
