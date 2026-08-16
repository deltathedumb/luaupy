"""`from luau import l_exec` -- the escape hatch to the host language.

Roblox is not available to this suite, so `game` and `Instance` cannot be
touched. What is asserted is the machinery they depend on, with a plain Luau
table standing in for an Instance: indexing, assigning and colon-calling are
the same three operations either way, and they are the ones a bridge gets
wrong.
"""
from __future__ import annotations

import subprocess
from pathlib import Path

import pytest

from luaupy.runtime import runtime_luau
from test_runtime_luau import _binary, needs_luau

SCRIPT = Path(__file__).parent / "luau" / "interop.luau"


@pytest.fixture(scope="module")
def answers(tmp_path_factory) -> dict[str, str]:
    luau = _binary("luau")
    if luau is None:
        pytest.skip("no luau binary; see test_runtime_luau for the download")
    path = tmp_path_factory.mktemp("interop") / "interop.luau"
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
    # Primitives CONVERT. `l_exec("return 1")` answering an opaque object
    # would make the whole escape hatch useless.
    "num_int": "3",
    "num_float": "1.5",
    "str": repr("hi"),
    "bool": "True",
    "nil": "None",
    "noreturn": "None",
    # An integral double becomes an int: 1.0 prints as "1.0" and compares
    # unequal to 1 as a dict key.
    "integral_is_int": "int",
    "fraction_is_float": "float",

    "table_wraps": "luau",
    "function_wraps": "luau",

    # `a is a` has to hold, or a wrapped Instance cannot be a dict key and
    # cannot be compared. A fresh wrapper per access breaks both.
    "identity": "True",
    "distinct": "False",

    "getattr_num": "7",
    "getattr_str": repr("thing"),
    # Indexing a Luau table gives nil, so a missing member is None.
    "getattr_missing": "None",
    "setattr": "9",
    "setattr_str": "from-python",

    # THE CLASSIC BRIDGE BUG. Roblox methods are colon-calls; a wrapper that
    # forgets the receiver turns `game.GetService("Players")` into a call with
    # the string as `self`, which fails somewhere unhelpful.
    "method_kind": "luau_method",
    "method_call": repr("thing!"),
    "call_function": "42",

    "list_to_luau": "table:2:two",
    "dict_to_luau": "5",

    # Luau failures arrive as the Python exception a program can catch.
    "syntax_error": "SyntaxError",
    "runtime_error": "RuntimeError",
    "type_error": "TypeError",
}


@needs_luau
@pytest.mark.parametrize("key", sorted(EXPECTED))
def test_interop(answers: dict[str, str], key: str):
    assert key in answers, f"interop.luau produced no {key!r}"
    assert answers[key] == EXPECTED[key]


@needs_luau
def test_every_answer_is_checked(answers: dict[str, str]):
    unchecked = sorted(set(answers) - set(EXPECTED))
    assert not unchecked, f"produced but never compared: {unchecked}"


def test_the_backend_declares_the_module():
    """`from luau import l_exec` only resolves if the backend says it exists.

    The frontend reads `Backend.modules` both to know the name exists and to
    lower the call, so a runtime function with no entry here is unreachable
    from Python and a entry with no runtime function fails at link.
    """
    from luaupy.emit import LuauBackend
    assert "luau" in LuauBackend.modules
    assert LuauBackend.modules["luau"]["l_exec"] == ("call", "luau_l_exec", 1)

    import re
    src = (Path(__file__).resolve().parent.parent / "src" / "luaupy" / "luau"
           / "interop.luau").read_text("utf-8")
    assert re.search(r"function RT\.luau_l_exec\b", src), \
        "declared in modules but not defined in the runtime"
