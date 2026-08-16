"""Builtins, sets and number helpers, run under `luau` and diffed against CPython.

Same shape as `test_strings_luau`; see `builtin_cases` for the cases and
`test_runtime_luau` for how to get the toolchain.
"""
from __future__ import annotations

import re
import subprocess
from pathlib import Path

import pytest

from builtin_cases import CASES
from luaupy.runtime import runtime_luau
from test_runtime_luau import _binary, needs_luau

_PRELUDE = """
RT.heap(1048576)
local function S(x) return RT.box_str(x) end
local function I(n) return RT.box_int(n) end
local function F(x) return RT.box_float(x) end
local N = RT.apy_none()
local TRUE = RT.box_bool(true)
local FALSE = RT.box_bool(false)
local function L(xs)
  local l = RT.apy_list_new(0, 0)
  for _, n in ipairs(xs) do RT.apy_seq_push(l, RT.box_int(n)) end
  return l
end
local function LS(xs)
  local l = RT.apy_list_new(0, 0)
  for _, s in ipairs(xs) do RT.apy_seq_push(l, RT.box_str(s)) end
  return l
end
local function SET(xs)
  local s = RT.apy_set_new(0, 0)
  for _, n in ipairs(xs) do RT.apy_set_push(s, RT.box_int(n)) end
  return s
end
-- 1, 1.0 and True hash and compare equal, so this must collapse to one member.
local function MIXEDSET()
  local s = RT.apy_set_new(0, 0)
  RT.apy_set_push(s, RT.box_int(1))
  RT.apy_set_push(s, RT.box_float(1.0))
  RT.apy_set_push(s, RT.box_bool(true))
  return s
end
local function R(a, b, c) return RT.apy_range(0, a, 0, b, RT.from_number(c)) end
local function D()
  local d = RT.apy_dict_new(0, 0)
  RT.apy_dict_set(d, S("a"), I(1))
  RT.apy_dict_set(d, S("b"), I(2))
  return d
end
local function SL(seq, a, b, c, hs, he)
  local ah, al = RT.from_number(a)
  local bh, bl = RT.from_number(b)
  local ch, cl = RT.from_number(c)
  return RT.apy_slice(seq, ah, al, bh, bl, ch, cl, 0, hs, 0, he)
end
local function POP(l) return RT.apy_list_pop(l, N, 0, 0) end
local function POPI(l, i) return RT.apy_list_pop(l, I(i), 0, 1) end
local function REMOVED(l, v) RT.apy_list_remove(l, v) return l end
local function CLEARED(l) RT.apy_clear(l) return l end
local function IDSTABLE()
  local x = RT.box_str("q")
  return RT.box_bool(RT.H(RT.apy_id(x)).n == RT.H(RT.apy_id(x)).n)
end
local out = {}
local function emit(k, v)
  if v == 0 then
    local t = RT.as_str(RT.apy_error_type())
    local m = RT.as_str(RT.apy_error_message())
    RT.apy_error_clear()
    table.insert(out, k .. "\\t!" .. t .. ": " .. m)
  else
    table.insert(out, k .. "\\t" .. RT.as_str(RT.apy_repr(v)))
  end
end
"""


@pytest.fixture(scope="module")
def answers(tmp_path_factory) -> dict[str, str]:
    luau = _binary("luau")
    if luau is None:
        pytest.skip("no luau binary; see test_runtime_luau for the download")
    body = "\n".join(f'emit("{label}", {expr})' for label, expr, _ in CASES)
    script = tmp_path_factory.mktemp("builtins") / "cases.luau"
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
@pytest.mark.parametrize("label,expr,python", CASES, ids=[c[0] for c in CASES])
def test_builtin(answers: dict[str, str], label: str, expr: str, python: str):
    assert label in answers, f"no answer produced for {label}"
    assert answers[label] == repr(eval(python)), f"luau: {expr}"


def test_labels_are_unique():
    labels = [c[0] for c in CASES]
    dupes = sorted({x for x in labels if labels.count(x) > 1})
    assert not dupes, f"duplicate case labels: {dupes}"


#: Symbols this group claims, by name. Listed rather than matched by prefix:
#: `apy_set_names` is a DESCRIPTOR function, nothing to do with sets, and a
#: prefix rule reports it as a missing set method forever.
_GROUPS = {
    "sets": """apy_set_new apy_frozenset_new apy_set_push apy_to_set
        apy_to_frozenset apy_set_add apy_set_discard apy_set_union
        apy_set_intersection apy_set_difference apy_set_symdiff
        apy_set_issubset apy_set_issuperset apy_set_isdisjoint apy_update
        apy_clear apy_copy""",
    "builtins": """apy_range apy_sorted apy_min apy_max apy_sum apy_reversed
        apy_enumerate apy_zip2 apy_abs apy_round apy_isinstance apy_slice
        apy_list_pop apy_index_of apy_count_of apy_list_remove apy_dict_parts
        apy_dict_get_or apy_pop_or apy_dict_popitem""",
    "numbers": """apy_pow3 apy_bit_length apy_bit_count apy_bin apy_oct apy_hex
        apy_to_int_base apy_divmod apy_hex_of apy_float_fromhex apy_ascii
        apy_id apy_slice_new apy_slice_indices""",
}


@pytest.mark.parametrize("group", sorted(_GROUPS))
def test_group_is_complete(group: str):
    """Every symbol the group claims is defined SOMEWHERE in the runtime.

    Across all modules rather than one file: which file a function lives in is
    an organisational choice, and the ABI does not care.
    """
    luau_dir = Path(__file__).resolve().parent.parent / "src" / "luaupy" / "luau"
    defined: set[str] = set()
    for path in luau_dir.glob("*.luau"):
        defined |= set(re.findall(r"function RT\.(apy_\w+)",
                                  path.read_text("utf-8")))
    missing = set(_GROUPS[group].split()) - defined
    assert not missing, sorted(missing)
