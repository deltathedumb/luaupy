-- str methods.
--
-- The largest group in the runtime and the most mechanical, which makes it the
-- one most likely to be wrong in small ways nobody notices. Every function here
-- is checked against CPython by tests/luau/strings.luau.
--
-- ASCII ONLY, AND SAID OUT LOUD
-- ----------------------------
-- Python's str is a sequence of unicode code points; a Luau string is bytes.
-- So `len`, the classification predicates, and case conversion agree with
-- Python for ASCII and differ above it: "é".upper() is "É" in Python and
-- unchanged here, and len("é") is 1 there and 2 here. The C reaches a real
-- unicode table (link/unicode_table.py, 909 lines) which is not ported.
--
-- The alternative -- a half-written UTF-8 decoder -- is worse than the gap,
-- because it turns a known limitation into an unknown one.
--
-- LUAU STRING FUNCTIONS TAKE PATTERNS
-- -----------------------------------
-- `string.find(s, sub)` treats `sub` as a pattern, so searching for "a.b"
-- matches "axb" and searching for "(" is an error. Every search here passes
-- `true` as the fourth argument. `string.gsub` has no such escape hatch, so
-- replacement is written by hand rather than delegated to it.

local function str_self(name: string, v: number): string?
    local k = RT.kindof(v)
    if k ~= "str" and k ~= "bytes" then
        RT.err("TypeError", "descriptor '" .. name ..
               "' requires a 'str' object but received a '" ..
               k .. "'")
        return nil
    end
    return RT.H(v).s
end

local function arg_str(name: string, v: number): string?
    local k = RT.kindof(v)
    if k ~= "str" and k ~= "bytes" then
        RT.err("TypeError", name .. "() argument must be str, not " .. k)
        return nil
    end
    return RT.H(v).s
end

local function arg_int(name: string, v: number): number?
    local k = RT.kindof(v)
    if k ~= "int" and k ~= "bool" then
        if k == "big" then
            RT.err("OverflowError", name .. "() argument is too large")
        else
            RT.err("TypeError", name .. "() argument must be an integer")
        end
        return nil
    end
    return RT.H(v).n
end

--- Python's slice bounds, as 0-based half-open [start, stop) clamped to the
--- string. Negative counts from the end; out of range clamps rather than
--- raising, which is what the search and count methods expect and what an
--- index lookup does NOT -- those raise, and are elsewhere.
local function bounds(n: number, start: number?, stop: number?): (number, number)
    local i = start or 0
    local j = if stop == nil then n else stop
    if i < 0 then
        i += n
        if i < 0 then i = 0 end
    elseif i > n then
        i = n
    end
    if j < 0 then
        j += n
        if j < 0 then j = 0 end
    elseif j > n then
        j = n
    end
    return i, j
end

-- ── character classes ───────────────────────────────────────────────────────
-- Written as byte tests rather than Lua character classes because `%a` and
-- friends follow the C locale, which is not guaranteed to be ASCII.

local function is_upper(b: number): boolean return b >= 65 and b <= 90 end
local function is_lower(b: number): boolean return b >= 97 and b <= 122 end
local function is_alpha(b: number): boolean return is_upper(b) or is_lower(b) end
local function is_digit(b: number): boolean return b >= 48 and b <= 57 end
local function is_space(b: number): boolean
    return b == 32 or (b >= 9 and b <= 13)
end
local function to_upper(b: number): number
    return if is_lower(b) then b - 32 else b
end
local function to_lower(b: number): number
    return if is_upper(b) then b + 32 else b
end

-- ── case conversion ─────────────────────────────────────────────────────────

local function map_bytes(s: string, f): string
    local out = table.create(#s)
    for i = 1, #s do out[i] = string.char(f(string.byte(s, i))) end
    return table.concat(out)
end

function RT.apy_str_upper(v: number): number
    local s = str_self("upper", v)
    if s == nil then return 0 end
    return RT.box_str(map_bytes(s, to_upper))
end

function RT.apy_str_lower(v: number): number
    local s = str_self("lower", v)
    if s == nil then return 0 end
    return RT.box_str(map_bytes(s, to_lower))
end

--- casefold is a more aggressive lower() for unicode; for ASCII the two agree.
function RT.apy_str_casefold(v: number): number
    return RT.apy_str_lower(v)
end

function RT.apy_str_swapcase(v: number): number
    local s = str_self("swapcase", v)
    if s == nil then return 0 end
    return RT.box_str(map_bytes(s, function(b)
        if is_upper(b) then return b + 32 end
        if is_lower(b) then return b - 32 end
        return b
    end))
end

function RT.apy_str_capitalize(v: number): number
    local s = str_self("capitalize", v)
    if s == nil then return 0 end
    if #s == 0 then return RT.box_str("") end
    -- The FIRST character up, every other one down -- capitalize() lowercases
    -- the tail, which is what separates it from title() on a single word.
    local out = { string.char(to_upper(string.byte(s, 1))) }
    for i = 2, #s do out[i] = string.char(to_lower(string.byte(s, i))) end
    return RT.box_str(table.concat(out))
end

--- title(): the first cased character of each run is upper, the rest lower.
--- A run is broken by any character that is not a letter, so "it's" titles as
--- "It'S" -- which looks wrong and is what Python does.
function RT.apy_str_title(v: number): number
    local s = str_self("title", v)
    if s == nil then return 0 end
    local out, prev_cased = table.create(#s), false
    for i = 1, #s do
        local b = string.byte(s, i)
        if is_alpha(b) then
            out[i] = string.char(if prev_cased then to_lower(b) else to_upper(b))
            prev_cased = true
        else
            out[i] = string.char(b)
            prev_cased = false
        end
    end
    return RT.box_str(table.concat(out))
end

-- ── classification ──────────────────────────────────────────────────────────
-- All of these answer False on the empty string except isprintable and
-- isascii, which answer True. That asymmetry is Python's and it is deliberate:
-- "every character is X" is vacuously true, but the others additionally
-- require at least one character.

local function all_bytes(s: string, pred): boolean
    if #s == 0 then return false end
    for i = 1, #s do
        if not pred(string.byte(s, i)) then return false end
    end
    return true
end

function RT.apy_str_isalpha(v: number): number
    local s = str_self("isalpha", v)
    if s == nil then return 0 end
    return RT.box_bool(all_bytes(s, is_alpha))
end

function RT.apy_str_isdigit(v: number): number
    local s = str_self("isdigit", v)
    if s == nil then return 0 end
    return RT.box_bool(all_bytes(s, is_digit))
end

-- For ASCII these three coincide; they differ only on unicode digits, which is
-- part of the gap named at the top of this file.
function RT.apy_str_isdecimal(v) return RT.apy_str_isdigit(v) end
function RT.apy_str_isnumeric(v) return RT.apy_str_isdigit(v) end

function RT.apy_str_isalnum(v: number): number
    local s = str_self("isalnum", v)
    if s == nil then return 0 end
    return RT.box_bool(all_bytes(s, function(b)
        return is_alpha(b) or is_digit(b)
    end))
end

function RT.apy_str_isspace(v: number): number
    local s = str_self("isspace", v)
    if s == nil then return 0 end
    return RT.box_bool(all_bytes(s, is_space))
end

--- islower(): at least one cased character, and no uppercase. A string of
--- digits is not lower, which is why this cannot be `s == s:lower()`.
function RT.apy_str_islower(v: number): number
    local s = str_self("islower", v)
    if s == nil then return 0 end
    local seen = false
    for i = 1, #s do
        local b = string.byte(s, i)
        if is_upper(b) then return RT.box_bool(false) end
        if is_lower(b) then seen = true end
    end
    return RT.box_bool(seen)
end

function RT.apy_str_isupper(v: number): number
    local s = str_self("isupper", v)
    if s == nil then return 0 end
    local seen = false
    for i = 1, #s do
        local b = string.byte(s, i)
        if is_lower(b) then return RT.box_bool(false) end
        if is_upper(b) then seen = true end
    end
    return RT.box_bool(seen)
end

function RT.apy_str_istitle(v: number): number
    local s = str_self("istitle", v)
    if s == nil then return 0 end
    local seen, prev_cased = false, false
    for i = 1, #s do
        local b = string.byte(s, i)
        if is_upper(b) then
            if prev_cased then return RT.box_bool(false) end
            seen, prev_cased = true, true
        elseif is_lower(b) then
            if not prev_cased then return RT.box_bool(false) end
            seen, prev_cased = true, true
        else
            prev_cased = false
        end
    end
    return RT.box_bool(seen)
end

function RT.apy_str_isprintable(v: number): number
    local s = str_self("isprintable", v)
    if s == nil then return 0 end
    for i = 1, #s do
        local b = string.byte(s, i)
        if b < 32 or b == 127 then return RT.box_bool(false) end
    end
    return RT.box_bool(true)          -- empty is printable
end

function RT.apy_str_isascii(v: number): number
    local s = str_self("isascii", v)
    if s == nil then return 0 end
    for i = 1, #s do
        if string.byte(s, i) > 127 then return RT.box_bool(false) end
    end
    return RT.box_bool(true)          -- empty is ascii
end

--- isidentifier() does NOT reject keywords -- `"class".isidentifier()` is True
--- in Python. It only checks the shape.
function RT.apy_str_isidentifier(v: number): number
    local s = str_self("isidentifier", v)
    if s == nil then return 0 end
    if #s == 0 then return RT.box_bool(false) end
    local b = string.byte(s, 1)
    if not (is_alpha(b) or b == 95) then return RT.box_bool(false) end
    for i = 2, #s do
        local c = string.byte(s, i)
        if not (is_alpha(c) or is_digit(c) or c == 95) then
            return RT.box_bool(false)
        end
    end
    return RT.box_bool(true)
end

-- ── stripping ───────────────────────────────────────────────────────────────

local function strip_impl(s: string, chars: string?, left: boolean,
                          right: boolean): string
    local i, j = 1, #s
    local function match(b: number): boolean
        if chars == nil then return is_space(b) end
        return string.find(chars, string.char(b), 1, true) ~= nil
    end
    if left then
        while i <= j and match(string.byte(s, i)) do i += 1 end
    end
    if right then
        while j >= i and match(string.byte(s, j)) do j -= 1 end
    end
    return string.sub(s, i, j)
end

function RT.apy_str_strip(v: number): number
    local s = str_self("strip", v)
    if s == nil then return 0 end
    return RT.box_str(strip_impl(s, nil, true, true))
end

function RT.apy_str_lstrip(v: number): number
    local s = str_self("lstrip", v)
    if s == nil then return 0 end
    return RT.box_str(strip_impl(s, nil, true, false))
end

function RT.apy_str_rstrip(v: number): number
    local s = str_self("rstrip", v)
    if s == nil then return 0 end
    return RT.box_str(strip_impl(s, nil, false, true))
end

--- The chars argument is a SET of characters to remove, not a prefix. That is
--- the classic misreading of strip(), and removeprefix() exists because of it.
function RT.apy_str_strip_chars(v: number, c: number): number
    local s = str_self("strip", v)
    if s == nil then return 0 end
    local chars = arg_str("strip", c)
    if chars == nil then return 0 end
    return RT.box_str(strip_impl(s, chars, true, true))
end

function RT.apy_str_lstrip_chars(v: number, c: number): number
    local s = str_self("lstrip", v)
    if s == nil then return 0 end
    local chars = arg_str("lstrip", c)
    if chars == nil then return 0 end
    return RT.box_str(strip_impl(s, chars, true, false))
end

function RT.apy_str_rstrip_chars(v: number, c: number): number
    local s = str_self("rstrip", v)
    if s == nil then return 0 end
    local chars = arg_str("rstrip", c)
    if chars == nil then return 0 end
    return RT.box_str(strip_impl(s, chars, false, true))
end

function RT.apy_str_removeprefix(v: number, p: number): number
    local s = str_self("removeprefix", v)
    if s == nil then return 0 end
    local pre = arg_str("removeprefix", p)
    if pre == nil then return 0 end
    if #pre > 0 and string.sub(s, 1, #pre) == pre then
        return RT.box_str(string.sub(s, #pre + 1))
    end
    return RT.box_str(s)
end

function RT.apy_str_removesuffix(v: number, p: number): number
    local s = str_self("removesuffix", v)
    if s == nil then return 0 end
    local suf = arg_str("removesuffix", p)
    if suf == nil then return 0 end
    if #suf > 0 and string.sub(s, #s - #suf + 1) == suf then
        return RT.box_str(string.sub(s, 1, #s - #suf))
    end
    return RT.box_str(s)
end

-- ── searching ───────────────────────────────────────────────────────────────

--- Leftmost index of `sub` within s[i:j], 0-based, or -1.
---
--- The window is applied by searching the SLICE and adding the offset back,
--- rather than by searching the whole string and filtering, because a match
--- that starts before `i` but ends after it must not be found.
local function find_in(s: string, sub: string, i: number, j: number): number
    local window = string.sub(s, i + 1, j)
    if #sub == 0 then
        -- An empty needle is found at the start of the window, provided the
        -- window exists at all. "abc".find("", 5) is -1; "abc".find("", 3) is 3.
        return if i <= j then i else -1
    end
    local at = string.find(window, sub, 1, true)
    return if at == nil then -1 else i + at - 1
end

local function rfind_in(s: string, sub: string, i: number, j: number): number
    local window = string.sub(s, i + 1, j)
    if #sub == 0 then return if i <= j then j else -1 end
    local best = -1
    local from = 1
    while true do
        local at = string.find(window, sub, from, true)
        if at == nil then break end
        best = i + at - 1
        from = at + 1
    end
    return best
end

local function do_find(v: number, sub: number, a: number?, b: number?,
                       reverse: boolean, name: string): number
    local s = str_self(name, v)
    if s == nil then return 0 end
    local needle = arg_str(name, sub)
    if needle == nil then return 0 end
    local start, stop = nil, nil
    if a ~= nil then
        start = arg_int(name, a)
        if start == nil then return 0 end
    end
    if b ~= nil then
        stop = arg_int(name, b)
        if stop == nil then return 0 end
    end
    local i, j = bounds(#s, start, stop)
    local at = if reverse then rfind_in(s, needle, i, j)
               else find_in(s, needle, i, j)
    return RT.box_int(at)
end

function RT.apy_str_find(v, sub) return do_find(v, sub, nil, nil, false, "find") end
function RT.apy_str_find2(v, sub, a) return do_find(v, sub, a, nil, false, "find") end
function RT.apy_str_find3(v, sub, a, b) return do_find(v, sub, a, b, false, "find") end
function RT.apy_str_rfind(v, sub) return do_find(v, sub, nil, nil, true, "rfind") end
function RT.apy_str_rfind2(v, sub, a) return do_find(v, sub, a, nil, true, "rfind") end
function RT.apy_str_rfind3(v, sub, a, b) return do_find(v, sub, a, b, true, "rfind") end

--- rindex() is rfind() that raises instead of answering -1. index() has no
--- entry in this ABI, which is why only the reverse form appears here.
function RT.apy_str_rindex(v: number, sub: number): number
    local got = do_find(v, sub, nil, nil, true, "rindex")
    if got == 0 then return 0 end
    if RT.H(got).n < 0 then
        return RT.err("ValueError", "substring not found")
    end
    return got
end

local function do_affix(v: number, affix: number, a: number?, b: number?,
                        ends: boolean, name: string): number
    local s = str_self(name, v)
    if s == nil then return 0 end
    local start, stop = nil, nil
    if a ~= nil then
        start = arg_int(name, a)
        if start == nil then return 0 end
    end
    if b ~= nil then
        stop = arg_int(name, b)
        if stop == nil then return 0 end
    end
    local i, j = bounds(#s, start, stop)
    local window = string.sub(s, i + 1, j)

    -- A tuple of candidates is accepted, and any one matching is enough.
    local cands = {}
    if RT.kindof(affix) == "tuple" then
        for _, e in ipairs(RT.items(affix)) do
            local t = arg_str(name, e)
            if t == nil then return 0 end
            table.insert(cands, t)
        end
    else
        local t = arg_str(name, affix)
        if t == nil then return 0 end
        table.insert(cands, t)
    end

    for _, t in ipairs(cands) do
        if #t > #window then continue end
        local got = if ends then string.sub(window, #window - #t + 1)
                    else string.sub(window, 1, #t)
        if got == t then return RT.box_bool(true) end
    end
    return RT.box_bool(false)
end

function RT.apy_str_startswith(v, p) return do_affix(v, p, nil, nil, false, "startswith") end
function RT.apy_str_startswith2(v, p, a) return do_affix(v, p, a, nil, false, "startswith") end
function RT.apy_str_startswith3(v, p, a, b) return do_affix(v, p, a, b, false, "startswith") end
function RT.apy_str_endswith(v, p) return do_affix(v, p, nil, nil, true, "endswith") end
function RT.apy_str_endswith2(v, p, a) return do_affix(v, p, a, nil, true, "endswith") end
function RT.apy_str_endswith3(v, p, a, b) return do_affix(v, p, a, b, true, "endswith") end

local function do_count(v: number, sub: number, a: number?, b: number?): number
    local s = str_self("count", v)
    if s == nil then return 0 end
    local needle = arg_str("count", sub)
    if needle == nil then return 0 end
    local start, stop = nil, nil
    if a ~= nil then
        start = arg_int("count", a)
        if start == nil then return 0 end
    end
    if b ~= nil then
        stop = arg_int("count", b)
        if stop == nil then return 0 end
    end
    local i, j = bounds(#s, start, stop)
    local window = string.sub(s, i + 1, j)
    -- Python counts NON-OVERLAPPING occurrences, so the cursor advances past
    -- the whole match: "aaaa".count("aa") is 2, not 3.
    if #needle == 0 then return RT.box_int(#window + 1) end
    local n, from = 0, 1
    while true do
        local at = string.find(window, needle, from, true)
        if at == nil then break end
        n += 1
        from = at + #needle
    end
    return RT.box_int(n)
end

function RT.apy_str_count2(v, sub, a) return do_count(v, sub, a, nil) end
function RT.apy_str_count3(v, sub, a, b) return do_count(v, sub, a, b) end

-- ── splitting ───────────────────────────────────────────────────────────────

local function list_of(strings: { string }): number
    local L = RT.apy_list_new(0, 0)
    for _, s in ipairs(strings) do RT.apy_seq_push(L, RT.box_str(s)) end
    return L
end

--- split() with no separator: runs of whitespace, with leading and trailing
--- whitespace discarded entirely. "" splits to [], and " " does too -- which
--- is the difference from split(" ") that trips people up.
local function split_ws(s: string, maxsplit: number?): { string }
    local out, i, n = {}, 1, #s
    local splits = 0
    while i <= n do
        while i <= n and is_space(string.byte(s, i)) do i += 1 end
        if i > n then break end
        if maxsplit ~= nil and splits >= maxsplit then
            -- The remainder keeps its internal spacing but loses trailing ws.
            local rest = string.sub(s, i)
            local j = #rest
            while j >= 1 and is_space(string.byte(rest, j)) do j -= 1 end
            table.insert(out, string.sub(rest, 1, j))
            return out
        end
        local start = i
        while i <= n and not is_space(string.byte(s, i)) do i += 1 end
        table.insert(out, string.sub(s, start, i - 1))
        splits += 1
    end
    return out
end

local function split_sep(s: string, sep: string, maxsplit: number?): { string }
    local out, from, splits = {}, 1, 0
    while true do
        if maxsplit ~= nil and splits >= maxsplit then break end
        local at = string.find(s, sep, from, true)
        if at == nil then break end
        table.insert(out, string.sub(s, from, at - 1))
        from = at + #sep
        splits += 1
    end
    table.insert(out, string.sub(s, from))
    return out
end

local function rsplit_sep(s: string, sep: string, maxsplit: number?): { string }
    -- Collect every boundary, then take the LAST maxsplit of them, so the
    -- remainder ends up at the front where rsplit puts it.
    local cuts, from = {}, 1
    while true do
        local at = string.find(s, sep, from, true)
        if at == nil then break end
        table.insert(cuts, at)
        from = at + #sep
    end
    local keep = if maxsplit == nil then #cuts
                 else math.min(maxsplit, #cuts)
    local first = #cuts - keep + 1
    local out, prev = {}, 1
    for i = first, #cuts do
        table.insert(out, string.sub(s, prev, cuts[i] - 1))
        prev = cuts[i] + #sep
    end
    table.insert(out, string.sub(s, prev))
    return out
end

local function empty_sep(): number
    return RT.err("ValueError", "empty separator")
end

function RT.apy_str_split_ws(v: number): number
    local s = str_self("split", v)
    if s == nil then return 0 end
    return list_of(split_ws(s, nil))
end

function RT.apy_str_split(v: number, sep: number): number
    local s = str_self("split", v)
    if s == nil then return 0 end
    local d = arg_str("split", sep)
    if d == nil then return 0 end
    if #d == 0 then return empty_sep() end
    return list_of(split_sep(s, d, nil))
end

function RT.apy_str_split_n(v: number, sep: number, n: number): number
    local s = str_self("split", v)
    if s == nil then return 0 end
    local maxsplit = arg_int("split", n)
    if maxsplit == nil then return 0 end
    -- A negative maxsplit means "no limit", not "zero".
    if maxsplit < 0 then maxsplit = nil end
    if RT.kindof(sep) == "none" then return list_of(split_ws(s, maxsplit)) end
    local d = arg_str("split", sep)
    if d == nil then return 0 end
    if #d == 0 then return empty_sep() end
    return list_of(split_sep(s, d, maxsplit))
end

function RT.apy_str_rsplit_ws(v: number): number
    local s = str_self("rsplit", v)
    if s == nil then return 0 end
    return list_of(split_ws(s, nil))
end

function RT.apy_str_rsplit(v: number, sep: number): number
    local s = str_self("rsplit", v)
    if s == nil then return 0 end
    local d = arg_str("rsplit", sep)
    if d == nil then return 0 end
    if #d == 0 then return empty_sep() end
    return list_of(split_sep(s, d, nil))
end

function RT.apy_str_rsplit_n(v: number, sep: number, n: number): number
    local s = str_self("rsplit", v)
    if s == nil then return 0 end
    local maxsplit = arg_int("rsplit", n)
    if maxsplit == nil then return 0 end
    if maxsplit < 0 then maxsplit = nil end
    if RT.kindof(sep) == "none" then
        -- rsplit on whitespace with a limit keeps the LAST n fields.
        local all = split_ws(s, nil)
        if maxsplit == nil or #all <= maxsplit then return list_of(all) end
        local head = split_ws(s, nil)
        local out = {}
        local keep = maxsplit
        local joined = {}
        for i = 1, #head - keep do table.insert(joined, head[i]) end
        table.insert(out, table.concat(joined, " "))
        for i = #head - keep + 1, #head do table.insert(out, head[i]) end
        return list_of(out)
    end
    local d = arg_str("rsplit", sep)
    if d == nil then return 0 end
    if #d == 0 then return empty_sep() end
    return list_of(rsplit_sep(s, d, maxsplit))
end

--- splitlines(): breaks on \n, \r and \r\n, and a trailing break does NOT
--- produce a final empty field -- which is the difference from split("\n").
local function splitlines(s: string, keepends: boolean): { string }
    local out, i, n = {}, 1, #s
    local start = 1
    while i <= n do
        local b = string.byte(s, i)
        if b == 10 or b == 13 then
            local stop = i
            local nxt = i + 1
            if b == 13 and nxt <= n and string.byte(s, nxt) == 10 then
                nxt += 1
                stop = i + 1
            end
            table.insert(out, string.sub(s, start,
                                         if keepends then stop else i - 1))
            i = nxt
            start = nxt
        else
            i += 1
        end
    end
    if start <= n then table.insert(out, string.sub(s, start)) end
    return out
end

function RT.apy_str_splitlines(v: number): number
    local s = str_self("splitlines", v)
    if s == nil then return 0 end
    return list_of(splitlines(s, false))
end

function RT.apy_str_splitlines_keep(v: number, keep: number): number
    local s = str_self("splitlines", v)
    if s == nil then return 0 end
    local _, t = RT.apy_truth(keep)
    return list_of(splitlines(s, t ~= 0))
end

local function partition(v: number, sep: number, reverse: boolean): number
    local name = if reverse then "rpartition" else "partition"
    local s = str_self(name, v)
    if s == nil then return 0 end
    local d = arg_str(name, sep)
    if d == nil then return 0 end
    if #d == 0 then return empty_sep() end
    local at = if reverse then rfind_in(s, d, 0, #s) else find_in(s, d, 0, #s)
    local T = RT.apy_tuple_new(0, 0)
    if at < 0 then
        -- Not found: partition puts the whole string FIRST, rpartition LAST.
        if reverse then
            RT.apy_seq_push(T, RT.box_str(""))
            RT.apy_seq_push(T, RT.box_str(""))
            RT.apy_seq_push(T, RT.box_str(s))
        else
            RT.apy_seq_push(T, RT.box_str(s))
            RT.apy_seq_push(T, RT.box_str(""))
            RT.apy_seq_push(T, RT.box_str(""))
        end
        return T
    end
    RT.apy_seq_push(T, RT.box_str(string.sub(s, 1, at)))
    RT.apy_seq_push(T, RT.box_str(d))
    RT.apy_seq_push(T, RT.box_str(string.sub(s, at + #d + 1)))
    return T
end

function RT.apy_str_partition(v, sep) return partition(v, sep, false) end
function RT.apy_str_rpartition(v, sep) return partition(v, sep, true) end

-- ── joining and replacing ───────────────────────────────────────────────────

function RT.apy_str_join(v: number, seq: number): number
    local sep = str_self("join", v)
    if sep == nil then return 0 end
    local it = RT.apy_getiter(seq)
    if it == 0 then return 0 end
    local parts = {}
    while true do
        local e = RT.apy_step(it)
        if e == 0 then return 0 end
        if e == RT.apy_stop() then break end
        local k = RT.kindof(e)
        if k ~= "str" and k ~= "bytes" then
            return RT.err("TypeError",
                          "sequence item " .. #parts ..
                          ": expected str instance, " .. k .. " found")
        end
        table.insert(parts, RT.H(e).s)
    end
    return RT.box_str(table.concat(parts, sep))
end

--- Written by hand rather than with gsub, twice over: gsub reads the pattern
--- for magic characters AND reads `%` in the replacement, so replacing "%" or
--- "." with anything goes wrong in two different ways.
local function replace_impl(s: string, old: string, new: string,
                            count: number?): string
    if #old == 0 then
        -- An empty needle inserts between every character and at both ends.
        local out, n = {}, 0
        local limit = count
        for i = 1, #s do
            if limit == nil or n < limit then
                table.insert(out, new)
                n += 1
            end
            table.insert(out, string.sub(s, i, i))
        end
        if limit == nil or n < limit then table.insert(out, new) end
        return table.concat(out)
    end
    local out, from, done = {}, 1, 0
    while true do
        if count ~= nil and done >= count then break end
        local at = string.find(s, old, from, true)
        if at == nil then break end
        table.insert(out, string.sub(s, from, at - 1))
        table.insert(out, new)
        from = at + #old
        done += 1
    end
    table.insert(out, string.sub(s, from))
    return table.concat(out)
end

function RT.apy_str_replace(v: number, old: number, new: number): number
    local s = str_self("replace", v)
    if s == nil then return 0 end
    local a = arg_str("replace", old)
    if a == nil then return 0 end
    local b = arg_str("replace", new)
    if b == nil then return 0 end
    return RT.box_str(replace_impl(s, a, b, nil))
end

function RT.apy_str_replace_n(v: number, old: number, new: number,
                              n: number): number
    local s = str_self("replace", v)
    if s == nil then return 0 end
    local a = arg_str("replace", old)
    if a == nil then return 0 end
    local b = arg_str("replace", new)
    if b == nil then return 0 end
    local count = arg_int("replace", n)
    if count == nil then return 0 end
    if count < 0 then count = nil end       -- negative means "all"
    return RT.box_str(replace_impl(s, a, b, count))
end

-- ── translation ─────────────────────────────────────────────────────────────

--- maketrans(from, to, delete) -> {ordinal: replacement}
--- The two mapping arguments must be the same length; the third is optional
--- and its characters map to None, which translate() drops.
function RT.apy_str_maketrans(a: number, b: number, c: number): number
    local from = arg_str("maketrans", a)
    if from == nil then return 0 end
    local to = arg_str("maketrans", b)
    if to == nil then return 0 end
    if #from ~= #to then
        return RT.err("ValueError",
                      "the first two maketrans arguments must have equal length")
    end
    local D = RT.apy_dict_new(0, 0)
    for i = 1, #from do
        RT.apy_dict_set(D, RT.box_int(string.byte(from, i)),
                        RT.box_int(string.byte(to, i)))
    end
    if c ~= nil and c ~= 0 and RT.kindof(c) ~= "none" then
        local drop = arg_str("maketrans", c)
        if drop == nil then return 0 end
        for i = 1, #drop do
            RT.apy_dict_set(D, RT.box_int(string.byte(drop, i)), RT.apy_none())
        end
    end
    return D
end

--- translate(table): each ordinal is looked up; a missing key leaves the
--- character alone, None deletes it, an int is an ordinal, a str is inserted.
function RT.apy_str_translate(v: number, table_: number): number
    local s = str_self("translate", v)
    if s == nil then return 0 end
    if RT.kindof(table_) ~= "dict" then
        return RT.err("TypeError",
                      "'" .. RT.kindof(table_) .. "' object is not subscriptable")
    end
    local out = {}
    for i = 1, #s do
        local b = string.byte(s, i)
        local key = RT.box_int(b)
        local got = RT.H(table_).vals[RT.apy_hash_key(key)]
        if got == nil then
            table.insert(out, string.char(b))
        else
            local k = RT.kindof(got)
            if k == "none" then
                -- dropped
            elseif k == "int" or k == "bool" then
                table.insert(out, string.char(RT.H(got).n % 256))
            elseif k == "str" then
                table.insert(out, RT.H(got).s)
            else
                return RT.err("TypeError",
                              "character mapping must return integer, None or str")
            end
        end
    end
    return RT.box_str(table.concat(out))
end

--- Give a result the receiver's string type back.
---
--- `b"a b".split()` must produce bytes, not str, and the split itself does not
--- know what it was called on. The C threads this through every method that
--- returns a string or a sequence of them; here it is applied by the ones that
--- do, and is a no-op when the receiver was already str.
function RT.apy_str_like(recv: number, out: number): number
    if out == 0 or RT.kindof(recv) ~= "bytes" then return out end
    local k = RT.kindof(out)
    if k == "str" then
        local made = RT.box_str(RT.H(out).s)
        RT.H(made).k = "bytes"
        return made
    end
    if k == "list" or k == "tuple" then
        local xs = RT.items(out)
        for i, e in ipairs(xs) do xs[i] = RT.apy_str_like(recv, e) end
    end
    return out
end

-- ── justification ───────────────────────────────────────────────────────────

local function pad_arg(name: string, w: number, f: number?): (number?, string?)
    local width = arg_int(name, w)
    if width == nil then return nil, nil end
    local fill = " "
    if f ~= nil then
        local got = arg_str(name, f)
        if got == nil then return nil, nil end
        if #got ~= 1 then
            RT.err("TypeError",
                   "The fill character must be exactly one character long")
            return nil, nil
        end
        fill = got
    end
    return width, fill
end

local function do_just(v: number, w: number, f: number?, name: string,
                       where: string): number
    local s = str_self(name, v)
    if s == nil then return 0 end
    local width, fill = pad_arg(name, w, f)
    if width == nil then return 0 end
    local pad = width - #s
    if pad <= 0 then return RT.box_str(s) end
    if where == "left" then return RT.box_str(s .. string.rep(fill :: string, pad)) end
    if where == "right" then return RT.box_str(string.rep(fill :: string, pad) .. s) end
    -- center(): CPython biases the extra character to the RIGHT, except that
    -- `marg & width & 1` shifts it left when both the margin and the width are
    -- odd. Transcribed rather than reasoned about, because "ab".center(5) is
    -- "  ab " and every intuitive formula gets it the other way round.
    local left = pad // 2 + (if pad % 2 == 1 and width % 2 == 1 then 1 else 0)
    return RT.box_str(string.rep(fill :: string, left) .. s ..
                      string.rep(fill :: string, pad - left))
end

function RT.apy_str_ljust(v, w) return do_just(v, w, nil, "ljust", "left") end
function RT.apy_str_ljust_fill(v, w, f) return do_just(v, w, f, "ljust", "left") end
function RT.apy_str_rjust(v, w) return do_just(v, w, nil, "rjust", "right") end
function RT.apy_str_rjust_fill(v, w, f) return do_just(v, w, f, "rjust", "right") end
function RT.apy_str_center(v, w) return do_just(v, w, nil, "center", "center") end
function RT.apy_str_center_fill(v, w, f) return do_just(v, w, f, "center", "center") end

--- zfill(): zero-pads on the left, but a leading sign stays in front of the
--- zeros -- "-3".zfill(5) is "-0003", not "00-3".
function RT.apy_str_zfill(v: number, w: number): number
    local s = str_self("zfill", v)
    if s == nil then return 0 end
    local width = arg_int("zfill", w)
    if width == nil then return 0 end
    local pad = width - #s
    if pad <= 0 then return RT.box_str(s) end
    local sign = ""
    local body = s
    if #s > 0 then
        local first = string.sub(s, 1, 1)
        if first == "+" or first == "-" then
            sign = first
            body = string.sub(s, 2)
        end
    end
    return RT.box_str(sign .. string.rep("0", pad) .. body)
end
