-- `l_exec` and the value bridge, under the open-source luau binary.
--
-- Roblox is not here, so `game` and `Instance` do not exist. What IS exercised
-- is the machinery they depend on: primitives converting rather than wrapping,
-- non-primitives wrapping with stable identity, and attribute access,
-- assignment and calls forwarding through a wrapper. A plain table stands in
-- for an Instance, because indexing, assigning and colon-calling are the same
-- three operations either way.
--
-- Nothing here writes to `_G`: the CLI sandboxes it readonly, and a fixture
-- that fails for that reason reads as a bridge bug.

RT.heap(1048576)

local out = {}
local function say(k: string, v: string) table.insert(out, k .. "\t" .. v) end
local function S(x) return RT.box_str(x) end

-- Handle 0 means an error is set. Reporting it beats indexing it: H(0) is nil,
-- so a bare repr crashes the run and takes every other result with it --
-- stdout is buffered, so a crash loses the output that would say which case
-- broke.
local function R(v: number): string
    if v == 0 then
        local t = RT.as_str(RT.apy_error_type())
        RT.apy_error_clear()
        return "!" .. t
    end
    return RT.as_str(RT.apy_repr(v))
end
local function K(v: number): string
    return if v == 0 then "!error" else RT.kindof(v)
end

-- ── primitives convert, they do not wrap ────────────────────────────────────
-- `l_exec("return 1")` answering an opaque object would make it useless.
say("num_int", R(RT.luau_l_exec(S("return 1 + 2"))))
say("num_float", R(RT.luau_l_exec(S("return 1.5"))))
say("str", R(RT.luau_l_exec(S("return 'hi'"))))
say("bool", R(RT.luau_l_exec(S("return 1 == 1"))))
say("nil", R(RT.luau_l_exec(S("return nil"))))
say("noreturn", R(RT.luau_l_exec(S("local x = 1"))))

-- An integral double becomes an int: 1.0 would print as "1.0" and compare
-- unequal to 1 as a dict key.
say("integral_is_int", K(RT.luau_l_exec(S("return 4 / 2"))))
say("fraction_is_float", K(RT.luau_l_exec(S("return 1 / 4"))))

-- ── non-primitives wrap ─────────────────────────────────────────────────────
say("table_wraps", K(RT.luau_l_exec(S("return {n = 7}"))))
say("function_wraps", K(RT.luau_l_exec(S("return function() return 1 end"))))

-- ── identity is stable ──────────────────────────────────────────────────────
-- `a is a` must hold, so a wrapped value can be a dict key and compare equal.
-- A fresh wrapper per access would break both.
do
    local raw = { n = 7 }
    local a = RT.from_luau(raw)
    local b = RT.from_luau(raw)
    say("identity", R(RT.apy_is(a, b)))
    say("distinct", R(RT.apy_is(a, RT.from_luau({ n = 7 }))))
end

-- ── attribute access and assignment forward ─────────────────────────────────
do
    local raw = { n = 7, label = "thing" }
    local w = RT.from_luau(raw)
    say("getattr_num", R(RT.apy_getattr(w, S("n"))))
    say("getattr_str", R(RT.apy_getattr(w, S("label"))))
    -- A missing key is None, because indexing a Luau table gives nil.
    say("getattr_missing", R(RT.apy_getattr(w, S("nope"))))

    RT.apy_setattr(w, S("n"), RT.box_int(9))
    say("setattr", tostring(raw.n))
    -- A Python value crossing back out arrives as a Luau one.
    RT.apy_setattr(w, S("tag"), S("from-python"))
    say("setattr_str", tostring(raw.tag))
end

-- ── methods keep their receiver ─────────────────────────────────────────────
-- Roblox methods are colon-calls, and losing the receiver is the classic
-- bridge bug: `game.GetService("Players")` passes the string as `self`.
do
    local obj = { name = "thing" }
    function obj:label(suffix) return self.name .. suffix end
    local w = RT.from_luau(obj)
    local method = RT.apy_getattr(w, S("label"))
    say("method_kind", K(method))

    local argv = RT.alloca(8)
    buffer.writeu32(RT.mem(), argv, RT.box_str("!"))
    buffer.writeu32(RT.mem(), argv + 4, 0)
    say("method_call", R(RT.apy_call(method, argv, 0, 1)))
end

-- ── a plain function value is callable ──────────────────────────────────────
do
    local w = RT.luau_l_exec(S("return function(a, b) return a + b end"))
    local argv = RT.alloca(16)
    buffer.writeu32(RT.mem(), argv, RT.box_int(2))
    buffer.writeu32(RT.mem(), argv + 4, 0)
    buffer.writeu32(RT.mem(), argv + 8, RT.box_int(40))
    buffer.writeu32(RT.mem(), argv + 12, 0)
    say("call_function", R(RT.apy_call(w, argv, 0, 2)))
end

-- ── containers cross both ways ──────────────────────────────────────────────
do
    local L = RT.apy_list_new(0, 0)
    RT.apy_seq_push(L, RT.box_int(1))
    RT.apy_seq_push(L, RT.box_str("two"))
    local raw = RT.to_luau(L)
    say("list_to_luau", type(raw) .. ":" .. #raw .. ":" .. tostring(raw[2]))

    local D = RT.apy_dict_new(0, 0)
    RT.apy_dict_set(D, S("k"), RT.box_int(5))
    say("dict_to_luau", tostring(RT.to_luau(D).k))
end

-- ── errors are Python errors, naming the Luau ───────────────────────────────
do
    RT.luau_l_exec(S("this is not luau"))
    say("syntax_error", RT.as_str(RT.apy_error_type()))
    RT.apy_error_clear()

    RT.luau_l_exec(S("error('boom')"))
    say("runtime_error", RT.as_str(RT.apy_error_type()))
    RT.apy_error_clear()

    RT.luau_l_exec(RT.box_int(1))
    say("type_error", RT.as_str(RT.apy_error_type()))
    RT.apy_error_clear()
end

print(table.concat(out, string.char(10)))
