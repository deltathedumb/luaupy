-- Foundation smoke test, run by tests/test_runtime_luau.py under the real
-- `luau` binary. The runtime is prepended, so `RT` is already in scope.
--
-- Expected values are Python's, checked in the Python test rather than here --
-- this file only produces the answers.

RT.heap(1048576)

local out = {}
local function say(k: string, v: string)
    table.insert(out, k .. "\t" .. v)
end
local function S(v: number): string return RT.as_str(RT.apy_str(v)) end
local function R(v: number): string return RT.as_str(RT.apy_repr(v)) end

-- ── boxing, repr, str ───────────────────────────────────────────────────────
say("int", R(RT.apy_from_int(0, 42)))
say("int_neg", R(RT.apy_from_int(4294967295, 4294967254)))
say("float_tenth", R(RT.apy_from_float(0.1)))
say("float_big", R(RT.apy_from_float(1e22)))
say("float_third", R(RT.apy_from_float(1 / 3)))
say("float_whole", R(RT.apy_from_float(3.0)))
say("float_tiny", R(RT.apy_from_float(1e-7)))
say("bool", R(RT.apy_from_bool(0, 1)))
say("none", R(RT.apy_none()))
say("str_repr", R(RT.box_str("hi" .. string.char(10) .. "'x'")))
say("str_str", S(RT.box_str("plain")))

-- ── exact integers of any size ──────────────────────────────────────────────
local two = RT.box_int(2)
say("pow64", S(RT.apy_pow(two, RT.box_int(64))))
say("pow128", S(RT.apy_pow(two, RT.box_int(128))))
say("pow128_less1", S(RT.apy_sub(RT.apy_pow(two, RT.box_int(128)), RT.box_int(1))))

local f = RT.box_int(1)
for i = 1, 20 do f = RT.apy_mul(f, RT.box_int(i)) end
say("fact20", S(f))
for i = 21, 30 do f = RT.apy_mul(f, RT.box_int(i)) end
say("fact30", S(f))

-- The boundary that motivates the whole split: 2^53 + 1 is not representable
-- as a double, so an int that reaches it must already be in limbs.
say("2pow53_plus1", S(RT.apy_add(RT.apy_pow(two, RT.box_int(53)), RT.box_int(1))))
say("big_neg", S(RT.apy_neg(RT.apy_pow(two, RT.box_int(80)))))
say("big_sub_to_small", S(RT.apy_sub(RT.apy_pow(two, RT.box_int(64)),
                                     RT.apy_pow(two, RT.box_int(64)))))

-- ── identity and interning ──────────────────────────────────────────────────
say("is_256", R(RT.apy_is(RT.box_int(256), RT.box_int(256))))
say("is_257", R(RT.apy_is(RT.box_int(257), RT.box_int(257))))
say("is_none", R(RT.apy_is(RT.apy_none(), RT.apy_none())))

-- ── containers ──────────────────────────────────────────────────────────────
local L = RT.apy_list_new(0, 0)
for i = 1, 3 do RT.apy_seq_push(L, RT.box_int(i * i)) end
say("list", R(L))
say("list_len", S(RT.apy_len(L)))
say("list_index", S(RT.apy_getitem(L, RT.box_int(-1))))

local T = RT.apy_seq_push(RT.apy_tuple_new(0, 0), RT.box_int(5))
say("tuple1", R(T))

local D = RT.apy_dict_new(0, 0)
RT.apy_dict_set(D, RT.box_str("a"), RT.box_int(1))
RT.apy_dict_set(D, RT.box_str("b"), RT.box_int(2))
RT.apy_dict_set(D, RT.box_str("a"), RT.box_int(9))
say("dict", R(D))
say("dict_len", S(RT.apy_len(D)))
say("dict_get", S(RT.apy_getitem(D, RT.box_str("a"))))

say("concat_str", S(RT.apy_add(RT.box_str("ab"), RT.box_str("cd"))))
say("repeat_str", S(RT.apy_mul(RT.box_str("ab"), RT.box_int(3))))
say("in_list", R(RT.apy_contains(RT.box_int(4), L)))
say("in_str", R(RT.apy_contains(RT.box_str("bc"), RT.box_str("abcd"))))

-- ── floor division and modulo signs ─────────────────────────────────────────
-- Python floors both; C truncates. The two disagree for mixed signs, which is
-- exactly where a runtime ported from C output goes wrong.
say("fdiv_neg", S(RT.apy_floordiv(RT.box_int(-7), RT.box_int(2))))
say("mod_neg_pos", S(RT.apy_mod(RT.box_int(-7), RT.box_int(2))))
say("mod_pos_neg", S(RT.apy_mod(RT.box_int(7), RT.box_int(-2))))
say("truediv", S(RT.apy_truediv(RT.box_int(7), RT.box_int(2))))

-- ── comparison ──────────────────────────────────────────────────────────────
say("cmp_int_float", R(RT.apy_eq(RT.box_int(1), RT.apy_from_float(1.0))))
say("cmp_lists", R(RT.apy_lt(L, L)))
say("cmp_str", R(RT.apy_lt(RT.box_str("abc"), RT.box_str("abd"))))
say("cmp_big", R(RT.apy_lt(RT.apy_pow(two, RT.box_int(64)),
                           RT.apy_pow(two, RT.box_int(65)))))

-- ── errors ──────────────────────────────────────────────────────────────────
local bad = RT.apy_add(RT.box_int(1), RT.box_str("x"))
local _, occurred = RT.apy_error_occurred()
say("err_handle", tostring(bad))
say("err_occurred", tostring(occurred))
say("err_type", RT.as_str(RT.apy_error_type()))
RT.apy_error_clear()
local _, cleared = RT.apy_error_occurred()
say("err_cleared", tostring(cleared))

local _, zde = (function()
    RT.apy_floordiv(RT.box_int(1), RT.box_int(0))
    local t = RT.as_str(RT.apy_error_type())
    RT.apy_error_clear()
    return 0, t
end)()
say("err_zerodiv", zde)

-- ── iteration ───────────────────────────────────────────────────────────────
local it = RT.apy_getiter(L)
local seen = {}
while true do
    local v = RT.apy_step(it)
    if v == RT.apy_stop() then break end
    table.insert(seen, S(v))
end
say("iter_list", table.concat(seen, ","))

local dit = RT.apy_getiter(D)
local dseen = {}
while true do
    local v = RT.apy_step(dit)
    if v == RT.apy_stop() then break end
    table.insert(dseen, S(v))
end
say("iter_dict_keys", table.concat(dseen, ","))

print(table.concat(out, string.char(10)))
