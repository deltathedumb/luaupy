"""Cases for the str methods: one Luau call, one Python expression.

Both sides are written once, here. The Luau is executed by the real `luau`
binary against the runtime; the Python is `eval`'d in this process; the two
`repr`s must match. Nothing is a typed-out literal, so a case cannot encode a
wrong expectation that happens to agree with a wrong implementation.

ASCII ONLY, on purpose. `strings.luau` documents that it works on bytes rather
than code points, so a case with "é" in it would fail for a reason already
known and recorded rather than testing anything.
"""
from __future__ import annotations

#: (label, luau expression, python expression)
#: `S` boxes a string, `I` an int, `L` a list of strings, `N` is None.
CASES: list[tuple[str, str, str]] = []


def case(label: str, luau: str, py: str) -> None:
    CASES.append((label, luau, py))


# ── case conversion ─────────────────────────────────────────────────────────
case("upper", 'RT.apy_str_upper(S("aBc1!"))', '"aBc1!".upper()')
case("lower", 'RT.apy_str_lower(S("aBc1!"))', '"aBc1!".lower()')
case("swapcase", 'RT.apy_str_swapcase(S("aBc1!"))', '"aBc1!".swapcase()')
case("casefold", 'RT.apy_str_casefold(S("AbC"))', '"AbC".casefold()')
case("capitalize", 'RT.apy_str_capitalize(S("hELLO wORLD"))',
     '"hELLO wORLD".capitalize()')
case("capitalize_empty", 'RT.apy_str_capitalize(S(""))', '"".capitalize()')
case("title", 'RT.apy_str_title(S("hello world"))', '"hello world".title()')
case("title_apostrophe", 'RT.apy_str_title(S("it\'s a test"))',
     '"it\'s a test".title()')
case("title_digits", 'RT.apy_str_title(S("a1b c2d"))', '"a1b c2d".title()')

# ── classification ──────────────────────────────────────────────────────────
for lbl, s in [("alpha", "abc"), ("alnum", "ab1"), ("digitonly", "123"),
               ("mixed", "a1!"), ("empty", ""), ("space", "  \t"),
               ("upperstr", "ABC"), ("lowerstr", "abc"), ("titlestr", "Ab Cd"),
               ("nottitle", "AB Cd"), ("ident", "_x1"), ("notident", "1x"),
               ("printable", "a b"), ("ctrl", "a\\nb")]:
    py = s.replace("\\n", "\n")
    for meth in ("isalpha", "isdigit", "isalnum", "isspace", "islower",
                 "isupper", "istitle", "isprintable", "isidentifier",
                 "isascii", "isdecimal", "isnumeric"):
        case(f"{meth}_{lbl}", f'RT.apy_str_{meth}(S("{s}"))',
             f'{py!r}.{meth}()')

# ── stripping ───────────────────────────────────────────────────────────────
case("strip", 'RT.apy_str_strip(S("  ab  "))', '"  ab  ".strip()')
case("lstrip", 'RT.apy_str_lstrip(S("  ab  "))', '"  ab  ".lstrip()')
case("rstrip", 'RT.apy_str_rstrip(S("  ab  "))', '"  ab  ".rstrip()')
case("strip_all", 'RT.apy_str_strip(S("   "))', '"   ".strip()')
case("strip_chars", 'RT.apy_str_strip_chars(S("xxabyy"), S("xy"))',
     '"xxabyy".strip("xy")')
case("lstrip_chars", 'RT.apy_str_lstrip_chars(S("xxabyy"), S("xy"))',
     '"xxabyy".lstrip("xy")')
case("rstrip_chars", 'RT.apy_str_rstrip_chars(S("xxabyy"), S("xy"))',
     '"xxabyy".rstrip("xy")')
case("strip_chars_none", 'RT.apy_str_strip_chars(S("abc"), S("z"))',
     '"abc".strip("z")')
case("removeprefix", 'RT.apy_str_removeprefix(S("foobar"), S("foo"))',
     '"foobar".removeprefix("foo")')
case("removeprefix_no", 'RT.apy_str_removeprefix(S("foobar"), S("bar"))',
     '"foobar".removeprefix("bar")')
case("removesuffix", 'RT.apy_str_removesuffix(S("foobar"), S("bar"))',
     '"foobar".removesuffix("bar")')
case("removesuffix_no", 'RT.apy_str_removesuffix(S("foobar"), S("foo"))',
     '"foobar".removesuffix("foo")')

# ── searching, including the pattern-magic characters ───────────────────────
case("find", 'RT.apy_str_find(S("abcabc"), S("bc"))', '"abcabc".find("bc")')
case("find_missing", 'RT.apy_str_find(S("abc"), S("z"))', '"abc".find("z")')
case("find_dot", 'RT.apy_str_find(S("axb"), S("a.b"))', '"axb".find("a.b")')
case("find_paren", 'RT.apy_str_find(S("a(b"), S("("))', '"a(b".find("(")')
case("find_percent", 'RT.apy_str_find(S("a%b"), S("%"))', '"a%b".find("%")')
case("find_empty", 'RT.apy_str_find(S("abc"), S(""))', '"abc".find("")')
case("find2", 'RT.apy_str_find2(S("abcabc"), S("bc"), I(2))',
     '"abcabc".find("bc", 2)')
case("find2_neg", 'RT.apy_str_find2(S("abcabc"), S("bc"), I(-3))',
     '"abcabc".find("bc", -3)')
case("find3", 'RT.apy_str_find3(S("abcabc"), S("bc"), I(0), I(3))',
     '"abcabc".find("bc", 0, 3)')
case("find3_cut", 'RT.apy_str_find3(S("abcabc"), S("bc"), I(0), I(2))',
     '"abcabc".find("bc", 0, 2)')
case("rfind", 'RT.apy_str_rfind(S("abcabc"), S("bc"))', '"abcabc".rfind("bc")')
case("rfind_missing", 'RT.apy_str_rfind(S("abc"), S("z"))', '"abc".rfind("z")')
case("rfind3", 'RT.apy_str_rfind3(S("abcabc"), S("bc"), I(0), I(4))',
     '"abcabc".rfind("bc", 0, 4)')
case("rindex", 'RT.apy_str_rindex(S("abcabc"), S("bc"))',
     '"abcabc".rindex("bc")')
case("count2", 'RT.apy_str_count2(S("aaaa"), S("aa"), I(0))',
     '"aaaa".count("aa", 0)')
case("count2_overlap", 'RT.apy_str_count2(S("abab"), S("ab"), I(0))',
     '"abab".count("ab", 0)')
case("count3", 'RT.apy_str_count3(S("aaaa"), S("a"), I(1), I(3))',
     '"aaaa".count("a", 1, 3)')
case("count_empty", 'RT.apy_str_count2(S("abc"), S(""), I(0))',
     '"abc".count("", 0)')
case("startswith", 'RT.apy_str_startswith(S("foobar"), S("foo"))',
     '"foobar".startswith("foo")')
case("startswith_no", 'RT.apy_str_startswith(S("foobar"), S("bar"))',
     '"foobar".startswith("bar")')
case("startswith2", 'RT.apy_str_startswith2(S("foobar"), S("bar"), I(3))',
     '"foobar".startswith("bar", 3)')
case("startswith3", 'RT.apy_str_startswith3(S("foobar"), S("oo"), I(1), I(3))',
     '"foobar".startswith("oo", 1, 3)')
case("endswith", 'RT.apy_str_endswith(S("foobar"), S("bar"))',
     '"foobar".endswith("bar")')
case("endswith3", 'RT.apy_str_endswith3(S("foobar"), S("oo"), I(0), I(3))',
     '"foobar".endswith("oo", 0, 3)')

# ── splitting ───────────────────────────────────────────────────────────────
case("split_ws", 'RT.apy_str_split_ws(S("  a  b  c "))', '"  a  b  c ".split()')
case("split_ws_empty", 'RT.apy_str_split_ws(S("   "))', '"   ".split()')
case("split", 'RT.apy_str_split(S("a,b,,c"), S(","))', '"a,b,,c".split(",")')
case("split_none", 'RT.apy_str_split(S("abc"), S(","))', '"abc".split(",")')
case("split_lead", 'RT.apy_str_split(S(",a,"), S(","))', '",a,".split(",")')
case("split_dot", 'RT.apy_str_split(S("a.b.c"), S("."))', '"a.b.c".split(".")')
case("split_n", 'RT.apy_str_split_n(S("a,b,c,d"), S(","), I(2))',
     '"a,b,c,d".split(",", 2)')
case("split_n_neg", 'RT.apy_str_split_n(S("a,b,c"), S(","), I(-1))',
     '"a,b,c".split(",", -1)')
case("split_n_ws", 'RT.apy_str_split_n(S("a b c d"), N, I(2))',
     '"a b c d".split(None, 2)')
case("rsplit", 'RT.apy_str_rsplit(S("a,b,c"), S(","))', '"a,b,c".rsplit(",")')
case("rsplit_n", 'RT.apy_str_rsplit_n(S("a,b,c,d"), S(","), I(2))',
     '"a,b,c,d".rsplit(",", 2)')
case("rsplit_n_ws", 'RT.apy_str_rsplit_n(S("a b c d"), N, I(2))',
     '"a b c d".rsplit(None, 2)')
case("splitlines", 'RT.apy_str_splitlines(S("a\\nb\\nc"))',
     '"a\\nb\\nc".splitlines()')
case("splitlines_trail", 'RT.apy_str_splitlines(S("a\\nb\\n"))',
     '"a\\nb\\n".splitlines()')
case("splitlines_crlf", 'RT.apy_str_splitlines(S("a\\r\\nb"))',
     '"a\\r\\nb".splitlines()')
case("splitlines_keep", 'RT.apy_str_splitlines_keep(S("a\\nb\\n"), TRUE)',
     '"a\\nb\\n".splitlines(True)')
case("partition", 'RT.apy_str_partition(S("a=b=c"), S("="))',
     '"a=b=c".partition("=")')
case("partition_missing", 'RT.apy_str_partition(S("abc"), S("="))',
     '"abc".partition("=")')
case("rpartition", 'RT.apy_str_rpartition(S("a=b=c"), S("="))',
     '"a=b=c".rpartition("=")')
case("rpartition_missing", 'RT.apy_str_rpartition(S("abc"), S("="))',
     '"abc".rpartition("=")')

# ── joining and replacing ───────────────────────────────────────────────────
case("join", 'RT.apy_str_join(S("-"), L({"a","b","c"}))', '"-".join(["a","b","c"])')
case("join_empty", 'RT.apy_str_join(S("-"), L({}))', '"-".join([])')
case("join_one", 'RT.apy_str_join(S("-"), L({"a"}))', '"-".join(["a"])')
case("replace", 'RT.apy_str_replace(S("aXbXc"), S("X"), S("-"))',
     '"aXbXc".replace("X", "-")')
case("replace_dot", 'RT.apy_str_replace(S("a.b"), S("."), S("!"))',
     '"a.b".replace(".", "!")')
case("replace_percent", 'RT.apy_str_replace(S("a%b"), S("%"), S("$"))',
     '"a%b".replace("%", "$")')
case("replace_into_percent", 'RT.apy_str_replace(S("ab"), S("b"), S("%1"))',
     '"ab".replace("b", "%1")')
case("replace_empty", 'RT.apy_str_replace(S("ab"), S(""), S("-"))',
     '"ab".replace("", "-")')
case("replace_n", 'RT.apy_str_replace_n(S("aaaa"), S("a"), S("b"), I(2))',
     '"aaaa".replace("a", "b", 2)')
case("replace_n_neg", 'RT.apy_str_replace_n(S("aaa"), S("a"), S("b"), I(-1))',
     '"aaa".replace("a", "b", -1)')

# ── translation ─────────────────────────────────────────────────────────────
case("translate", 'RT.apy_str_translate(S("abc"), '
                  'RT.apy_str_maketrans(S("ab"), S("xy"), N))',
     '"abc".translate(str.maketrans("ab", "xy"))')
case("translate_delete", 'RT.apy_str_translate(S("abc"), '
                         'RT.apy_str_maketrans(S("a"), S("x"), S("c")))',
     '"abc".translate(str.maketrans("a", "x", "c"))')

# ── justification ───────────────────────────────────────────────────────────
case("ljust", 'RT.apy_str_ljust(S("ab"), I(5))', '"ab".ljust(5)')
case("ljust_fill", 'RT.apy_str_ljust_fill(S("ab"), I(5), S("."))',
     '"ab".ljust(5, ".")')
case("ljust_short", 'RT.apy_str_ljust(S("abcdef"), I(3))', '"abcdef".ljust(3)')
case("rjust", 'RT.apy_str_rjust(S("ab"), I(5))', '"ab".rjust(5)')
case("rjust_fill", 'RT.apy_str_rjust_fill(S("ab"), I(5), S("0"))',
     '"ab".rjust(5, "0")')
# center's bias is the classic off-by-one; both parities are covered.
case("center_odd", 'RT.apy_str_center(S("ab"), I(5))', '"ab".center(5)')
case("center_even", 'RT.apy_str_center(S("ab"), I(6))', '"ab".center(6)')
case("center_odd2", 'RT.apy_str_center(S("abc"), I(6))', '"abc".center(6)')
case("center_even2", 'RT.apy_str_center(S("abc"), I(7))', '"abc".center(7)')
case("center_fill", 'RT.apy_str_center_fill(S("ab"), I(6), S("*"))',
     '"ab".center(6, "*")')
case("zfill", 'RT.apy_str_zfill(S("42"), I(5))', '"42".zfill(5)')
case("zfill_neg", 'RT.apy_str_zfill(S("-42"), I(5))', '"-42".zfill(5)')
case("zfill_plus", 'RT.apy_str_zfill(S("+42"), I(5))', '"+42".zfill(5)')
case("zfill_short", 'RT.apy_str_zfill(S("12345"), I(3))', '"12345".zfill(3)')
