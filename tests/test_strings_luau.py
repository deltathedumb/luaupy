"""Every str method, run under `luau` and diffed against CPython.

Each case in `str_cases.py` is a Luau expression and the Python expression it
must agree with. The Python side is `eval`'d here rather than written out as a
literal, so a case cannot encode an expectation that is wrong in the same way
the implementation is.

Cases are all ASCII. `strings.luau` documents that it operates on bytes rather
than code points, so a non-ASCII case would fail for a reason already recorded
instead of testing anything.
"""
from __future__ import annotations

import pathlib
import subprocess

import pytest

from luaupy.runtime import runtime_luau
from str_cases import CASES
from test_runtime_luau import _binary, needs_luau

_PRELUDE = """
RT.heap(1048576)
local function S(x) return RT.box_str(x) end
local function I(n) return RT.box_int(n) end
local N = RT.apy_none()
local TRUE = RT.box_bool(true)
local function L(xs)
  local l = RT.apy_list_new(0, 0)
  for _, s in ipairs(xs) do RT.apy_seq_push(l, RT.box_str(s)) end
  return l
end
local out = {}
local function emit(k, v)
  if v == 0 then
    -- A failed call sets an error and returns handle 0. Report the type so a
    -- wrong exception is distinguishable from a wrong value.
    local t = RT.as_str(RT.apy_error_type())
    RT.apy_error_clear()
    table.insert(out, k .. "\\t!" .. t)
  else
    table.insert(out, k .. "\\t" .. RT.as_str(RT.apy_repr(v)))
  end
end
"""


@pytest.fixture(scope="module")
def answers(tmp_path_factory) -> dict[str, str]:
    """Run every case once; the runtime is 1900 lines and parsing it per case
    would dominate the runtime of the suite."""
    luau = _binary("luau")
    if luau is None:
        pytest.skip("no luau binary; see test_runtime_luau for the download")
    body = "\n".join(f'emit("{label}", {expr})' for label, expr, _ in CASES)
    script = tmp_path_factory.mktemp("str") / "cases.luau"
    script.write_text(
        "local RT = (function()\n" + runtime_luau() + "\nend)()\n"
        + _PRELUDE + body + "\nprint(table.concat(out, string.char(10)))\n",
        encoding="utf-8",
    )
    proc = subprocess.run([luau, str(script)], capture_output=True, text=True)
    assert proc.returncode == 0, proc.stderr or proc.stdout
    return dict(line.split("\t", 1)
                for line in proc.stdout.splitlines() if "\t" in line)


@needs_luau
@pytest.mark.parametrize("label,expr,python", CASES,
                         ids=[c[0] for c in CASES])
def test_str_method(answers: dict[str, str], label: str, expr: str,
                    python: str):
    assert label in answers, f"no answer produced for {label}"
    assert answers[label] == repr(eval(python)), f"luau: {expr}"


def test_every_case_has_a_unique_label():
    """A duplicate label silently drops a case: the second overwrites the
    first in the answer dict and both then assert on the same value."""
    labels = [c[0] for c in CASES]
    dupes = sorted({x for x in labels if labels.count(x) > 1})
    assert not dupes, f"duplicate case labels: {dupes}"


def test_all_str_symbols_are_implemented():
    """Every apy_str_* in the ABI has a definition in strings.luau.

    Catches the case a caseless function slips through: nothing above would
    notice a symbol that exists in the C and not here, because no case names
    it.
    """
    from asmpython.link.objects import OBJECT_NAMES
    src = (pathlib.Path(__file__).resolve().parent.parent
           / "src" / "luaupy" / "luau" / "strings.luau").read_text("utf-8")
    import re
    defined = set(re.findall(r"function RT\.(apy_str_\w+)", src))
    wanted = {n for n in OBJECT_NAMES if n.startswith("apy_str_")}
    assert not (wanted - defined), sorted(wanted - defined)
