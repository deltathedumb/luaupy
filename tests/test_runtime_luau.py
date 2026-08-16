"""Runs the Luau runtime under the real `luau` binary and diffs it against CPython.

The rest of the suite checks what the backend EMITS. Nothing there can check
whether 1900 lines of hand-written Luau parse, let alone whether they compute
what Python computes -- and the bugs that have actually shipped on this project
were all of the second kind, wrong answers from code that parsed fine.

So this assembles the runtime, runs it, and compares every answer against the
same expression evaluated in Python. The expectations below are not literals
typed from memory; they are `repr(0.1)`, `str(2**53 + 1)`, `str(-7 % 2)`
evaluated here, so the test cannot drift from the language it is checking.

GETTING THE TOOLCHAIN
---------------------
    mkdir .tools && cd .tools
    curl -sSL -o luau.zip \\
      https://github.com/luau-lang/luau/releases/latest/download/luau-windows.zip
    unzip luau.zip

(`luau-linux.zip` / `luau-macos.zip` on the other platforms.) Everything here
skips without it rather than failing, so a checkout with no toolchain still has
a green suite -- but the runtime is then unverified, which is worth knowing.
"""
from __future__ import annotations

import math
import shutil
import subprocess
from pathlib import Path

import pytest

from luaupy.runtime import runtime_luau

ROOT = Path(__file__).resolve().parent.parent
SMOKE = Path(__file__).parent / "luau" / "smoke.luau"


def _binary(name: str) -> str | None:
    for candidate in (ROOT / ".tools" / f"{name}.exe", ROOT / ".tools" / name):
        if candidate.exists():
            return str(candidate)
    return shutil.which(name)


needs_luau = pytest.mark.skipif(
    _binary("luau") is None,
    reason="no `luau` binary; see this module's docstring for the download",
)
needs_compile = pytest.mark.skipif(
    _binary("luau-compile") is None,
    reason="no `luau-compile` binary; see this module's docstring",
)


@pytest.fixture(scope="module")
def assembled(tmp_path_factory) -> Path:
    """The runtime, written where the binaries can reach it."""
    path = tmp_path_factory.mktemp("luau") / "runtime.luau"
    path.write_text(runtime_luau(), encoding="utf-8")
    return path


@needs_compile
def test_the_runtime_is_valid_luau(assembled: Path):
    """It parses. Nothing else in the suite would notice if it did not.

    Worth its own test rather than being implied by the behaviour test below:
    a syntax error there reports as a failure to produce output, which reads
    like a logic bug and sends you looking in the wrong place.
    """
    # stdout is BYTECODE, so it is discarded rather than captured -- decoding it
    # as text raises UnicodeDecodeError on the first byte that is not UTF-8,
    # which reads like a failure of the thing under test.
    proc = subprocess.run(
        [_binary("luau-compile"), "--binary", str(assembled)],
        stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True,
    )
    assert proc.returncode == 0, proc.stderr


@pytest.fixture(scope="module")
def answers(assembled: Path, tmp_path_factory) -> dict[str, str]:
    """Run smoke.luau against the runtime and collect its `key\\tvalue` lines."""
    if _binary("luau") is None:
        pytest.skip("no luau binary")
    script = tmp_path_factory.mktemp("luau_run") / "smoke.luau"
    script.write_text(
        "local RT = (function()\n" + runtime_luau() + "\nend)()\n"
        + SMOKE.read_text(encoding="utf-8"),
        encoding="utf-8",
    )
    proc = subprocess.run([_binary("luau"), str(script)],
                          capture_output=True, text=True)
    assert proc.returncode == 0, proc.stderr or proc.stdout
    return dict(line.split("\t", 1)
                for line in proc.stdout.splitlines() if "\t" in line)


#: What Python says. Evaluated, never typed -- an expectation written by hand is
#: a second implementation of the thing under test, free to be wrong in the same
#: way the code is.
EXPECTED = {
    "int": repr(42),
    "int_neg": repr(-42),
    "float_tenth": repr(0.1),
    "float_big": repr(1e22),
    "float_third": repr(1 / 3),
    "float_whole": repr(3.0),
    "float_tiny": repr(1e-7),
    "bool": repr(True),
    "none": repr(None),
    "str_repr": repr("hi\n'x'"),
    "str_str": "plain",
    "pow64": str(2 ** 64),
    "pow128": str(2 ** 128),
    "pow128_less1": str(2 ** 128 - 1),
    "fact20": str(math.factorial(20)),
    "fact30": str(math.factorial(30)),
    # The value the whole int/big split exists for. A double cannot hold it, so
    # any path that touches one loses the low bit and answers 2**53.
    "2pow53_plus1": str(2 ** 53 + 1),
    "big_neg": str(-(2 ** 80)),
    "big_sub_to_small": "0",
    # `is` on interned integers. CPython caches -5..256, so the boundary is
    # observable and the two answers must differ.
    "is_256": "True",
    "is_257": "False",
    "is_none": "True",
    "list": repr([1, 4, 9]),
    "list_len": "3",
    "list_index": "9",
    "tuple1": repr((5,)),
    "dict": repr({"a": 9, "b": 2}),
    "dict_len": "2",
    "dict_get": "9",
    "concat_str": "abcd",
    "repeat_str": "ababab",
    "in_list": "True",
    "in_str": "True",
    # Python floors, C truncates. They differ only for mixed signs, which is
    # precisely where a runtime transcribed from C goes wrong.
    "fdiv_neg": str(-7 // 2),
    "mod_neg_pos": str(-7 % 2),
    "mod_pos_neg": str(7 % -2),
    "truediv": str(7 / 2),
    "cmp_int_float": "True",
    "cmp_lists": "False",
    "cmp_str": "True",
    "cmp_big": "True",
    "err_handle": "0",
    "err_occurred": "1",
    "err_type": "TypeError",
    "err_cleared": "0",
    "err_zerodiv": "ZeroDivisionError",
    "iter_list": "1,4,9",
    "iter_dict_keys": "a,b",
}


@needs_luau
@pytest.mark.parametrize("key", sorted(EXPECTED))
def test_matches_cpython(answers: dict[str, str], key: str):
    assert key in answers, f"smoke.luau produced no {key!r}"
    assert answers[key] == EXPECTED[key]


@needs_luau
def test_every_answer_is_checked(answers: dict[str, str]):
    """smoke.luau must not grow a case that nothing asserts on."""
    unchecked = sorted(set(answers) - set(EXPECTED))
    assert not unchecked, f"produced but never compared: {unchecked}"
