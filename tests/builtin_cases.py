"""Cases for builtins, sets and the number helpers.

Same contract as `str_cases`: one Luau expression, one Python expression, and
their `repr`s must agree. See `test_strings_luau` for why the Python side is
`eval`'d rather than written out.

Helpers available in the Luau prelude:
    S(x)   box a string        I(n)  box an int      F(x)  box a float
    L{...} a list of ints      LS{}  a list of strings
    SET{}  a set of ints       R(a,b,c) a range
    N      None                TRUE / FALSE
"""
from __future__ import annotations

CASES: list[tuple[str, str, str]] = []


def case(label: str, luau: str, py: str) -> None:
    CASES.append((label, luau, py))


# ── range ───────────────────────────────────────────────────────────────────
case("range_repr", "R(0, 5, 1)", "range(0, 5)")
case("range_step_repr", "R(0, 10, 3)", "range(0, 10, 3)")
case("range_list", "RT.apy_sorted(R(0, 5, 1))", "sorted(range(0, 5))")
case("range_down", "RT.apy_sorted(R(5, 0, -1))", "sorted(range(5, 0, -1))")
case("range_empty", "RT.apy_sorted(R(5, 5, 1))", "sorted(range(5, 5))")
case("range_empty_neg", "RT.apy_sorted(R(0, 5, -1))", "sorted(range(0, 5, -1))")
case("range_len", "RT.apy_len(R(0, 10, 3))", "len(range(0, 10, 3))")
case("range_len_neg", "RT.apy_len(R(10, 0, -3))", "len(range(10, 0, -3))")
case("range_sum", "RT.apy_sum(R(1, 101, 1))", "sum(range(1, 101))")

# ── ordering and reduction ──────────────────────────────────────────────────
case("sorted_ints", "RT.apy_sorted(L({3, 1, 2}))", "sorted([3, 1, 2])")
case("sorted_strs", 'RT.apy_sorted(LS({"b", "a", "c"}))',
     'sorted(["b", "a", "c"])')
case("sorted_empty", "RT.apy_sorted(L({}))", "sorted([])")
case("sorted_dup", "RT.apy_sorted(L({2, 1, 2, 1}))", "sorted([2, 1, 2, 1])")
case("min", "RT.apy_min(L({3, 1, 2}))", "min([3, 1, 2])")
case("max", "RT.apy_max(L({3, 1, 2}))", "max([3, 1, 2])")
case("min_str", 'RT.apy_min(LS({"b", "a"}))', 'min(["b", "a"])')
case("sum", "RT.apy_sum(L({1, 2, 3}))", "sum([1, 2, 3])")
case("sum_empty", "RT.apy_sum(L({}))", "sum([])")

# ── cursors ─────────────────────────────────────────────────────────────────
case("reversed", "RT.apy_sorted(RT.apy_reversed(L({1, 2, 3})))",
     "sorted(reversed([1, 2, 3]))")
case("enumerate", "RT.new_list_from(RT.collect_items("
                  "RT.apy_enumerate(LS({\"a\", \"b\"}), 0, 0)))",
     "list(enumerate(['a', 'b']))")
case("enumerate_start", "RT.new_list_from(RT.collect_items("
                        "RT.apy_enumerate(LS({\"a\", \"b\"}), 0, 5)))",
     "list(enumerate(['a', 'b'], 5))")
case("zip2", "RT.new_list_from(RT.collect_items("
             "RT.apy_zip2(L({1, 2, 3}), LS({\"a\", \"b\"}))))",
     "list(zip([1, 2, 3], ['a', 'b']))")

# ── numbers ─────────────────────────────────────────────────────────────────
case("abs_neg", "RT.apy_abs(I(-5))", "abs(-5)")
case("abs_pos", "RT.apy_abs(I(5))", "abs(5)")
case("abs_float", "RT.apy_abs(F(-2.5))", "abs(-2.5)")
case("abs_big", "RT.apy_abs(RT.apy_neg(RT.apy_pow(I(2), I(80))))",
     "abs(-(2**80))")
# Banker's rounding: the tie goes to even, so round(0.5) is 0 and round(2.5) is 2.
case("round_half_even0", "RT.apy_round(F(0.5))", "round(0.5)")
case("round_half_even1", "RT.apy_round(F(1.5))", "round(1.5)")
case("round_half_even2", "RT.apy_round(F(2.5))", "round(2.5)")
case("round_half_even3", "RT.apy_round(F(-0.5))", "round(-0.5)")
case("round_half_even4", "RT.apy_round(F(-1.5))", "round(-1.5)")
case("round_up", "RT.apy_round(F(1.7))", "round(1.7)")
case("round_down", "RT.apy_round(F(1.2))", "round(1.2)")
case("round_int", "RT.apy_round(I(7))", "round(7)")

case("isinstance_int", 'RT.apy_isinstance(I(1), S("int"))', "isinstance(1, int)")
case("isinstance_bool_is_int", 'RT.apy_isinstance(TRUE, S("int"))',
     "isinstance(True, int)")
case("isinstance_str_no", 'RT.apy_isinstance(I(1), S("str"))',
     "isinstance(1, str)")
case("isinstance_big", 'RT.apy_isinstance(RT.apy_pow(I(2), I(70)), S("int"))',
     "isinstance(2**70, int)")

# ── slicing ─────────────────────────────────────────────────────────────────
# args: seq, start, stop, step, has_start, has_stop
case("slice_basic", "SL(L({1,2,3,4,5}), 1, 4, 1, 1, 1)", "[1,2,3,4,5][1:4]")
case("slice_open_start", "SL(L({1,2,3,4,5}), 0, 3, 1, 0, 1)", "[1,2,3,4,5][:3]")
case("slice_open_stop", "SL(L({1,2,3,4,5}), 2, 0, 1, 1, 0)", "[1,2,3,4,5][2:]")
case("slice_neg", "SL(L({1,2,3,4,5}), -2, 0, 1, 1, 0)", "[1,2,3,4,5][-2:]")
case("slice_step2", "SL(L({1,2,3,4,5}), 0, 0, 2, 0, 0)", "[1,2,3,4,5][::2]")
case("slice_rev", "SL(L({1,2,3,4,5}), 0, 0, -1, 0, 0)", "[1,2,3,4,5][::-1]")
case("slice_rev_bounded", "SL(L({1,2,3,4,5}), 3, 0, -1, 1, 1)",
     "[1,2,3,4,5][3:0:-1]")
case("slice_str", 'SL(S("abcdef"), 1, 4, 1, 1, 1)', '"abcdef"[1:4]')
case("slice_str_rev", 'SL(S("abcdef"), 0, 0, -1, 0, 0)', '"abcdef"[::-1]')
case("slice_out_of_range", "SL(L({1,2,3}), 0, 99, 1, 1, 1)", "[1,2,3][0:99]")
case("slice_range", "SL(R(0, 10, 1), 2, 5, 1, 1, 1)", "list(range(0,10))[2:5]")

# ── list and dict methods ───────────────────────────────────────────────────
case("index_of", "RT.apy_index_of(L({10, 20, 30}), I(20))", "[10,20,30].index(20)")
case("count_of", "RT.apy_count_of(L({1, 2, 1}), I(1))", "[1,2,1].count(1)")
case("count_of_none", "RT.apy_count_of(L({1, 2}), I(9))", "[1,2].count(9)")
case("pop_last", "POP(L({1, 2, 3}))", "([1,2,3].pop())")
case("pop_index", "POPI(L({1, 2, 3}), 0)", "([1,2,3].pop(0))")
case("pop_neg", "POPI(L({1, 2, 3}), -2)", "([1,2,3].pop(-2))")
case("remove_then_repr", "REMOVED(L({1, 2, 3, 2}), I(2))",
     "(lambda x: (x.remove(2), x)[1])([1,2,3,2])")
case("dict_keys", "RT.apy_dict_parts(D(), 0, 0)", "list({'a':1,'b':2}.keys())")
case("dict_values", "RT.apy_dict_parts(D(), 0, 1)", "list({'a':1,'b':2}.values())")
case("dict_items", "RT.apy_dict_parts(D(), 0, 2)", "list({'a':1,'b':2}.items())")
case("dict_get_hit", 'RT.apy_dict_get_or(D(), S("a"), I(-1))',
     "{'a':1,'b':2}.get('a', -1)")
case("dict_get_miss", 'RT.apy_dict_get_or(D(), S("z"), I(-1))',
     "{'a':1,'b':2}.get('z', -1)")
case("dict_pop_or_miss", 'RT.apy_pop_or(D(), S("z"), I(-1))',
     "{'a':1,'b':2}.pop('z', -1)")
case("dict_popitem", "RT.apy_dict_popitem(D())", "{'a':1,'b':2}.popitem()")

# ── sets ────────────────────────────────────────────────────────────────────
case("set_sorted", "RT.apy_sorted(SET({3, 1, 2, 1}))", "sorted({3, 1, 2, 1})")
case("set_len", "RT.apy_len(SET({1, 2, 2, 3}))", "len({1, 2, 2, 3})")
# 1, 1.0 and True are one element, because they hash and compare equal.
case("set_numeric_identity", "RT.apy_len(MIXEDSET())", "len({1, 1.0, True})")
case("set_union", "RT.apy_sorted(RT.apy_set_union(SET({1,2}), SET({2,3})))",
     "sorted({1,2} | {2,3})")
case("set_inter",
     "RT.apy_sorted(RT.apy_set_intersection(SET({1,2,3}), SET({2,3,4})))",
     "sorted({1,2,3} & {2,3,4})")
case("set_diff",
     "RT.apy_sorted(RT.apy_set_difference(SET({1,2,3}), SET({2})))",
     "sorted({1,2,3} - {2})")
case("set_symdiff",
     "RT.apy_sorted(RT.apy_set_symdiff(SET({1,2}), SET({2,3})))",
     "sorted({1,2} ^ {2,3})")
case("set_subset", "RT.apy_set_issubset(SET({1,2}), SET({1,2,3}))",
     "{1,2}.issubset({1,2,3})")
case("set_subset_no", "RT.apy_set_issubset(SET({1,4}), SET({1,2,3}))",
     "{1,4}.issubset({1,2,3})")
case("set_superset", "RT.apy_set_issuperset(SET({1,2,3}), SET({1,2}))",
     "{1,2,3}.issuperset({1,2})")
case("set_disjoint", "RT.apy_set_isdisjoint(SET({1,2}), SET({3,4}))",
     "{1,2}.isdisjoint({3,4})")
case("set_disjoint_no", "RT.apy_set_isdisjoint(SET({1,2}), SET({2,3}))",
     "{1,2}.isdisjoint({2,3})")
case("set_from_list", "RT.apy_sorted(RT.apy_to_set(L({1,2,2,3})))",
     "sorted(set([1,2,2,3]))")
case("set_from_str", 'RT.apy_sorted(RT.apy_to_set(S("aabbc")))',
     'sorted(set("aabbc"))')
case("set_contains", "RT.apy_contains(I(2), SET({1,2,3}))", "(2 in {1,2,3})")
case("set_contains_no", "RT.apy_contains(I(9), SET({1,2,3}))", "(9 in {1,2,3})")
case("copy_list", "RT.apy_copy(L({1,2,3}))", "[1,2,3].copy()")
case("copy_dict", "RT.apy_copy(D())", "{'a':1,'b':2}.copy()")
case("cleared_list", "CLEARED(L({1,2,3}))",
     "(lambda x: (x.clear(), x)[1])([1,2,3])")

# ── bit inspection and base conversion ──────────────────────────────────────
case("bit_length_0", "RT.apy_bit_length(I(0))", "(0).bit_length()")
case("bit_length_5", "RT.apy_bit_length(I(5))", "(5).bit_length()")
case("bit_length_neg", "RT.apy_bit_length(I(-5))", "(-5).bit_length()")
case("bit_length_big", "RT.apy_bit_length(RT.apy_pow(I(2), I(100)))",
     "(2**100).bit_length()")
case("bit_count", "RT.apy_bit_count(I(255))", "(255).bit_count()")
case("bit_count_neg", "RT.apy_bit_count(I(-255))", "(-255).bit_count()")
case("bit_count_big", "RT.apy_bit_count(RT.apy_sub(RT.apy_pow(I(2), I(100)), I(1)))",
     "(2**100 - 1).bit_count()")
# The sign goes BEFORE the prefix.
case("bin", "RT.apy_bin(I(5))", "bin(5)")
case("bin_neg", "RT.apy_bin(I(-5))", "bin(-5)")
case("bin_zero", "RT.apy_bin(I(0))", "bin(0)")
case("oct", "RT.apy_oct(I(64))", "oct(64)")
case("oct_neg", "RT.apy_oct(I(-64))", "oct(-64)")
case("hex", "RT.apy_hex(I(255))", "hex(255)")
case("hex_neg", "RT.apy_hex(I(-255))", "hex(-255)")
case("hex_big", "RT.apy_hex(RT.apy_pow(I(2), I(100)))", "hex(2**100)")
case("bin_big", "RT.apy_bin(RT.apy_pow(I(2), I(70)))", "bin(2**70)")

case("int_base16", 'RT.apy_to_int_base(S("ff"), I(16))', 'int("ff", 16)')
case("int_base16_prefix", 'RT.apy_to_int_base(S("0xff"), I(16))',
     'int("0xff", 16)')
case("int_base2", 'RT.apy_to_int_base(S("1011"), I(2))', 'int("1011", 2)')
case("int_base0_hex", 'RT.apy_to_int_base(S("0x1f"), I(0))', 'int("0x1f", 0)')
case("int_base0_dec", 'RT.apy_to_int_base(S("42"), I(0))', 'int("42", 0)')
case("int_base_neg", 'RT.apy_to_int_base(S("-ff"), I(16))', 'int("-ff", 16)')
case("int_base_underscore", 'RT.apy_to_int_base(S("1_000"), I(10))',
     'int("1_000", 10)')
case("int_base_ws", 'RT.apy_to_int_base(S("  42  "), I(10))',
     'int("  42  ", 10)')
# Long enough to leave the exact range, so it must accumulate through limbs.
case("int_base_long", 'RT.apy_to_int_base(S("' + "9" * 30 + '"), I(10))',
     'int("' + "9" * 30 + '", 10)')

case("divmod", "RT.apy_divmod(I(7), I(2))", "divmod(7, 2)")
case("divmod_neg", "RT.apy_divmod(I(-7), I(2))", "divmod(-7, 2)")
case("divmod_neg2", "RT.apy_divmod(I(7), I(-2))", "divmod(7, -2)")
case("pow3", "RT.apy_pow3(I(2), I(10), I(1000))", "pow(2, 10, 1000)")
case("pow3_big", "RT.apy_pow3(I(7), I(128), I(1000000007))",
     "pow(7, 128, 1000000007)")
case("pow3_none", "RT.apy_pow3(I(2), I(10), N)", "pow(2, 10)")
case("id_stable", "IDSTABLE()", "True")
case("ascii_plain", 'RT.apy_ascii(S("ab"))', 'ascii("ab")')
