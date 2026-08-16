-- ── the object table ────────────────────────────────────────────────────────
-- Handles index this array. Handle 0 is never allocated: it is NULL, and NULL
-- means an error is set.

local obj = { false }        -- index 1.. ; slot 1 is filled by NONE below
local n_obj = 0

local function new(rec: any): number
    n_obj += 1
    obj[n_obj] = rec
    return n_obj
end

local function H(v: number): any
    return obj[v]
end

local function kindof(v: number): string
    return obj[v].k
end

-- ── singletons ──────────────────────────────────────────────────────────────
-- Allocated before anything else so their handles are small and stable, and so
-- `apy_is` on None or a bool is a plain integer compare.

local NONE = new({ k = "none" })
local FALSE = new({ k = "bool", n = 0 })
local TRUE = new({ k = "bool", n = 1 })
local NOTIMPL = new({ k = "notimplemented" })

--- CPython's small-integer cache range, and the C's. Reproduced rather than
--- chosen: `a = 256; b = 256; a is b` must answer the same here as there, and
--- the boundary is observable from Python.
local SMALL_LO, SMALL_HI = -5, 256
local small: { [number]: number } = {}

-- ── errors ──────────────────────────────────────────────────────────────────
-- One slot, as in the C. `apy_error_occurred` is called by generated code after
-- most runtime calls, so it must stay a plain comparison.

local cur_err = 0            -- a handle to an exc object, or 0 for none

local function exc_new(tyname: string, msg: string): number
    return new({ k = "exc", exctype = tyname, msg = msg, args = {} })
end

--- Set the current error and return 0.
---
--- Returning the failure value rather than only setting it lets every caller
--- write `return err(...)`, which is what makes it hard to set an error and
--- then accidentally return a real value -- the bug this shape exists to stop.
local function err(tyname: string, msg: string): number
    cur_err = exc_new(tyname, msg)
    return 0
end

function RT.apy_error_occurred(): (number, number)
    return 0, (if cur_err ~= 0 then 1 else 0)
end

function RT.apy_error_value(): number
    return cur_err
end

function RT.apy_error_type(): number
    if cur_err == 0 then return NONE end
    return new({ k = "str", s = H(cur_err).exctype })
end

function RT.apy_error_message(): number
    if cur_err == 0 then return NONE end
    return new({ k = "str", s = H(cur_err).msg })
end

function RT.apy_error_clear()
    cur_err = 0
end

--- Stop the program if an error is pending and nothing handled it.
---
--- The frontend emits this where Python would unwind to the top level, so it
--- is the only place an uncaught exception becomes output.
function RT.apy_fatal_if_error()
    if cur_err == 0 then return end
    local e = H(cur_err)
    local msg = e.exctype
    if e.msg ~= nil and e.msg ~= "" then msg ..= ": " .. e.msg end
    cur_err = 0
    RT.trap(msg)
end

function RT.apy_make_exc(ty: number, msg: number): number
    local tyname = if ty ~= 0 and kindof(ty) == "str" then H(ty).s
                   else if ty ~= 0 and kindof(ty) == "type" then H(ty).name
                   else "Exception"
    local text = if msg ~= 0 and kindof(msg) == "str" then H(msg).s else ""
    return exc_new(tyname, text)
end

--- The n-argument form. The C keeps the argument tuple on the exception
--- because `except E as e: e.args` can read it back.
function RT.apy_make_excn(ty: number, argv: number, h: number, l: number): number
    local n = RT.to_number(h, l, true)
    local e = RT.apy_make_exc(ty, 0)
    local rec = H(e)
    for i = 0, n - 1 do
        local a = buffer.readu32(RT.mem(), argv + i * 8)
        table.insert(rec.args, a)
        if i == 0 and kindof(a) == "str" then rec.msg = H(a).s end
    end
    return e
end

function RT.apy_raise(e: number): number
    if e == 0 then return 0 end
    if kindof(e) ~= "exc" then
        -- `raise SomeClass` instantiates it; `raise obj` requires an exception.
        if kindof(e) == "type" then
            cur_err = exc_new(H(e).name, "")
            return 0
        end
        return err("TypeError",
                   "exceptions must derive from BaseException")
    end
    cur_err = e
    return 0
end

--- Does the pending error match this type? Names only: the class hierarchy
--- lives in the C's exception registry, and until that is ported a match is by
--- name plus the handful of bases the frontend actually emits.
local EXC_BASES: { [string]: { string } } = {
    ValueError = { "Exception", "BaseException" },
    TypeError = { "Exception", "BaseException" },
    KeyError = { "LookupError", "Exception", "BaseException" },
    IndexError = { "LookupError", "Exception", "BaseException" },
    LookupError = { "Exception", "BaseException" },
    ZeroDivisionError = { "ArithmeticError", "Exception", "BaseException" },
    OverflowError = { "ArithmeticError", "Exception", "BaseException" },
    ArithmeticError = { "Exception", "BaseException" },
    AttributeError = { "Exception", "BaseException" },
    StopIteration = { "Exception", "BaseException" },
    RuntimeError = { "Exception", "BaseException" },
    NotImplementedError = { "RuntimeError", "Exception", "BaseException" },
    Exception = { "BaseException" },
}

function RT.apy_error_matches(ty: number): (number, number)
    if cur_err == 0 then return 0, 0 end
    local want = if kindof(ty) == "str" then H(ty).s
                 else if kindof(ty) == "type" then H(ty).name else ""
    local have = H(cur_err).exctype
    if have == want then return 0, 1 end
    for _, base in ipairs(EXC_BASES[have] or {}) do
        if base == want then return 0, 1 end
    end
    return 0, 0
end

--- Enter an `except` block: hand the value over and clear the slot, so code
--- inside the handler sees no pending error.
function RT.apy_error_handling(ty: number): number
    local e = cur_err
    cur_err = 0
    return if e == 0 then NONE else e
end

-- ── arbitrary-precision integers ────────────────────────────────────────────
-- Base 2^24, little end first. 24 bits so that a limb product (2^48) plus
-- carries stays exactly representable in a double, which is what lets the
-- schoolbook loops below be written in plain arithmetic.

local LIMB = 16777216        -- 2^24

local function big_norm(limbs)
    while #limbs > 1 and limbs[#limbs] == 0 do table.remove(limbs) end
    return limbs
end

local function big_from_abs(x: number)
    local limbs = {}
    if x < LIMB then return { x } end
    while x > 0 do
        table.insert(limbs, x % LIMB)
        x = (x - x % LIMB) / LIMB
    end
    return big_norm(limbs)
end

local function big_cmp_abs(a, b): number
    if #a ~= #b then return if #a < #b then -1 else 1 end
    for i = #a, 1, -1 do
        if a[i] ~= b[i] then return if a[i] < b[i] then -1 else 1 end
    end
    return 0
end

local function big_add_abs(a, b)
    local r, carry = {}, 0
    local n = math.max(#a, #b)
    for i = 1, n do
        local s = (a[i] or 0) + (b[i] or 0) + carry
        if s >= LIMB then r[i] = s - LIMB; carry = 1 else r[i] = s; carry = 0 end
    end
    if carry > 0 then r[n + 1] = carry end
    return r
end

--- |a| - |b|, requiring |a| >= |b|.
local function big_sub_abs(a, b)
    local r, borrow = {}, 0
    for i = 1, #a do
        local s = a[i] - (b[i] or 0) - borrow
        if s < 0 then r[i] = s + LIMB; borrow = 1 else r[i] = s; borrow = 0 end
    end
    return big_norm(r)
end

local function big_mul_abs(a, b)
    local r = {}
    for i = 1, #a + #b do r[i] = 0 end
    for i = 1, #a do
        local carry = 0
        local ai = a[i]
        if ai ~= 0 then
            for j = 1, #b do
                local k = i + j - 1
                local v = r[k] + ai * b[j] + carry
                r[k] = v % LIMB
                carry = (v - r[k]) / LIMB
            end
            local k = i + #b
            while carry > 0 do
                local v = r[k] + carry
                r[k] = v % LIMB
                carry = (v - r[k]) / LIMB
                k += 1
            end
        end
    end
    return big_norm(r)
end

--- Divide by a single limb; the only division shape the runtime needs so far
--- (base conversion for bin/oct/hex/str). Full big/big division is a gap and
--- is reported as one rather than approximated.
local function big_divmod_small(a, d: number)
    local q, rem = {}, 0
    for i = #a, 1, -1 do
        local cur = rem * LIMB + a[i]
        q[i] = math.floor(cur / d)
        rem = cur - q[i] * d
    end
    return big_norm(q), rem
end

local function big_is_zero(a): boolean
    return #a == 1 and a[1] == 0
end

local function big_bitlen(a): number
    local top = a[#a]
    if #a == 1 and top == 0 then return 0 end
    local bits = (#a - 1) * 24
    while top > 0 do
        bits += 1
        top = math.floor(top / 2)
    end
    return bits
end

local function big_bit(a, i: number): number
    local limb = a[math.floor(i / 24) + 1]
    if limb == nil then return 0 end
    return math.floor(limb / 2 ^ (i % 24)) % 2
end

--- a = a*2 + bit, in place.
local function big_shl1(a, bit: number)
    local carry = bit
    for i = 1, #a do
        local v = a[i] * 2 + carry
        a[i] = v % LIMB
        carry = (v - a[i]) / LIMB
    end
    if carry > 0 then table.insert(a, carry) end
    return a
end

--- |a| divided by |b|: truncated quotient and remainder, both exact.
---
--- Binary long division rather than Knuth's algorithm D. It is slower per bit
--- and it is a dozen lines instead of eighty, and -- the reason that matters
--- here -- it never forms an intermediate wider than the remainder, so there
--- is nowhere for a double to round. `apy_mod` used to convert both operands
--- with `apy_as_float` and pow(7, 128, 1000000007) came back wrong, because
--- squaring a nine-digit modulus lands near 10^18 and 2^53 is 9.0e15.
local function big_divmod_abs(a, b)
    if big_is_zero(b) then return { 0 }, { 0 } end
    if big_cmp_abs(a, b) < 0 then
        local r = {}
        for i, v in ipairs(a) do r[i] = v end
        return { 0 }, r
    end
    local n = big_bitlen(a)
    local q = {}
    for i = 1, math.floor((n - 1) / 24) + 1 do q[i] = 0 end
    local r = { 0 }
    for i = n - 1, 0, -1 do
        big_shl1(r, big_bit(a, i))
        if big_cmp_abs(r, b) >= 0 then
            r = big_sub_abs(r, b)
            local li = math.floor(i / 24) + 1
            q[li] += 2 ^ (i % 24)
        end
    end
    return big_norm(q), big_norm(r)
end

--- A big value, demoted to kind `int` when it fits exactly.
---
--- Demotion is required, not tidiness: the C says a zero-valued big becomes the
--- int 0 on construction, and every comparison here assumes one representation
--- per value.
local function make_int(sign: number, limbs): number
    limbs = big_norm(limbs)
    if big_is_zero(limbs) then sign = 0 end
    -- Decided from the LIMBS, before assembling, because assembling is what
    -- rounds. Reassembling first and then testing the result was wrong at
    -- exactly one value and it is the one that matters: 2^53 + 1 is computed
    -- correctly in limbs, then `x * LIMB + limbs[1]` rounds it back down to
    -- 2^53, and the range test receives a number that is already wrong and
    -- accepts it. `2**53 + 1 == 2**53` was True.
    --
    -- Two limbs reach 2^48 - 1; three with a top limb under 32 stay strictly
    -- below 32 * 2^48 = 2^53, where every integer is still representable. A
    -- value at or above that stays in limbs, which costs nothing: comparison
    -- and printing both handle either form.
    if #limbs <= 2 or (#limbs == 3 and limbs[3] < 32) then
        local x = 0
        for i = #limbs, 1, -1 do x = x * LIMB + limbs[i] end
        return RT.box_int(if sign < 0 then -x else x)
    end
    return new({ k = "big", sign = if sign == 0 then 1 else sign, limbs = limbs })
end

local function as_big(v: number)
    local o = H(v)
    if o.k == "big" then return o.sign, o.limbs end
    local n = o.n
    if n < 0 then return -1, big_from_abs(-n) end
    return (if n == 0 then 0 else 1), big_from_abs(n)
end

local function big_str(sign: number, limbs): string
    if big_is_zero(limbs) then return "0" end
    local parts, cur = {}, limbs
    while not big_is_zero(cur) do
        local q, r = big_divmod_small(cur, 1000000)
        cur = q
        if big_is_zero(cur) then
            table.insert(parts, 1, tostring(r))
        else
            table.insert(parts, 1, string.format("%06d", r))
        end
    end
    return (if sign < 0 then "-" else "") .. table.concat(parts)
end

-- ── boxing ──────────────────────────────────────────────────────────────────

function RT.box_int(n: number): number
    if n >= SMALL_LO and n <= SMALL_HI and n % 1 == 0 then
        local slot = small[n]
        if slot == nil then
            slot = new({ k = "int", n = n })
            small[n] = slot
        end
        return slot
    end
    return new({ k = "int", n = n })
end

function RT.box_float(x: number): number
    return new({ k = "float", n = x })
end

function RT.box_str(s: string): number
    return new({ k = "str", s = s })
end

function RT.box_bool(b: boolean): number
    return if b then TRUE else FALSE
end

function RT.as_str(v: number): string
    return H(v).s
end

function RT.as_num(v: number): number
    return H(v).n
end

function RT.items(v: number)
    return H(v).items
end

function RT.H(v: number) return H(v) end
function RT.kindof(v: number) return kindof(v) end
function RT.err(t: string, m: string) return err(t, m) end
function RT.NONE() return NONE end

-- ── the ABI: boxing and unboxing ────────────────────────────────────────────

function RT.apy_none(): number return NONE end
function RT.apy_notimplemented(): number return NOTIMPL end

function RT.apy_from_bool(h: number, l: number): number
    return if RT.to_number(h, l, true) ~= 0 then TRUE else FALSE
end

function RT.apy_from_int(h: number, l: number): number
    -- Exact for the whole 64-bit range: to_number is lossy above 2^53, so a
    -- value that large is assembled from the halves as limbs instead.
    if h < 2097152 or h >= 4292870144 then
        return RT.box_int(RT.to_number(h, l, true))
    end
    local neg = h >= 2147483648
    if neg then h, l = RT.neg64(h, l) end
    local limbs = big_norm({
        l % LIMB,
        (l - l % LIMB) / LIMB + (h % 65536) * 256,
        (h - h % 65536) / 65536,
    })
    return make_int(if neg then -1 else 1, limbs)
end

function RT.apy_from_float(x: number): number
    return RT.box_float(x)
end

function RT.apy_from_cstr(addr: number): number
    local b = RT.mem()
    local n = 0
    while buffer.readu8(b, addr + n) ~= 0 do n += 1 end
    return RT.box_str(buffer.readstring(b, addr, n))
end

function RT.apy_from_bytes(addr: number, h: number, l: number): number
    local n = RT.to_number(h, l, true)
    return new({ k = "bytes", s = buffer.readstring(RT.mem(), addr, n) })
end

function RT.apy_as_int(v: number): (number, number)
    local o = H(v)
    if o.k == "big" then
        -- Truncating a big to 64 bits is what C's int64_t cast does; the
        -- frontend only emits apy_as_int where it has established the range.
        local x = 0
        for i = math.min(#o.limbs, 3), 1, -1 do x = x * LIMB + o.limbs[i] end
        return RT.from_number(if o.sign < 0 then -x else x)
    end
    if o.k == "float" then return RT.from_number(RT.trunc(o.n)) end
    return RT.from_number(o.n)
end

function RT.apy_as_float(v: number): number
    local o = H(v)
    if o.k == "big" then
        local x = 0
        for i = #o.limbs, 1, -1 do x = x * LIMB + o.limbs[i] end
        return if o.sign < 0 then -x else x
    end
    return o.n + 0.0
end

function RT.apy_as_bool(v: number): (number, number)
    return RT.apy_truth(v)
end

-- ── truthiness ──────────────────────────────────────────────────────────────

function RT.apy_truth(v: number): (number, number)
    local o = H(v)
    local k = o.k
    local t
    if k == "none" then t = false
    elseif k == "bool" or k == "int" or k == "float" then t = o.n ~= 0
    -- A zero-valued big demotes to int 0 on construction, so a big is never
    -- false. That invariant is the C's, and it is why this line is safe.
    elseif k == "big" then t = true
    elseif k == "str" or k == "bytes" then t = #o.s > 0
    elseif k == "list" or k == "tuple" or k == "set" or k == "frozenset" then
        t = #o.items > 0
    elseif k == "dict" then t = #o.keys > 0
    elseif k == "range" then t = RT.range_len(o) > 0
    elseif k == "exc" then t = true
    else t = true
    end
    return 0, (if t then 1 else 0)
end

-- ── type names, repr and str ────────────────────────────────────────────────

local TYPE_NAME = {
    none = "NoneType", bool = "bool", int = "int", big = "int",
    float = "float", str = "str", bytes = "bytes", list = "list",
    tuple = "tuple", dict = "dict", set = "set", frozenset = "frozenset",
    exc = "Exception", type = "type", iter = "iterator", view = "dict_view",
    range = "range", cell = "cell", func = "function", bound = "method",
    slice = "slice", stopiter = "StopIteration",
    notimplemented = "NotImplementedType",
}

function RT.apy_type_name(v: number): number
    local o = H(v)
    if o.k == "inst" then return RT.box_str(H(o.cls).name) end
    if o.k == "type" then return RT.box_str("type") end
    if o.k == "exc" then return RT.box_str(o.exctype) end
    return RT.box_str(TYPE_NAME[o.k] or o.k)
end

--- Python's float repr: the shortest decimal that reads back as the same
--- double, with a trailing `.0` on an integral value and a switch to exponent
--- form at fixed exponents. Luau's tostring is a different rule with a
--- different switch point, so a program's output must not go through it.
local function float_repr(x: number): string
    if x ~= x then return "nan" end
    if x == math.huge then return "inf" end
    if x == -math.huge then return "-inf" end
    if x == 0 then return if 1 / x < 0 then "-0.0" else "0.0" end
    local a = math.abs(x)
    if a >= 1e16 or a < 1e-4 then
        for p = 1, 17 do
            local s = string.format("%." .. p .. "e", x)
            if tonumber(s) == x then
                -- Python writes e+16, not e+016.
                local m, sign, e = string.match(s, "^(.-)e([+-])0*(%d+)$")
                if m then
                    -- No forced `.0` on the mantissa: Python writes 1e+22, not
                    -- 1.0e+22. The trailing zero only appears in the
                    -- non-exponent form, where it is what distinguishes a
                    -- float from an int.
                    if string.find(m, "%.") then
                        m = string.gsub(m, "0+$", "")
                        m = string.gsub(m, "%.$", "")
                    end
                    return m .. "e" .. sign .. (if #e < 2 then "0" .. e else e)
                end
                return s
            end
        end
    end
    for p = 1, 17 do
        local s = string.format("%." .. p .. "g", x)
        if tonumber(s) == x then
            if not (string.find(s, "%.") or string.find(s, "[eE]")) then
                s ..= ".0"
            end
            return s
        end
    end
    return tostring(x)
end

local function str_repr(s: string): string
    local q = if string.find(s, "'", 1, true) and not string.find(s, '"', 1, true)
              then '"' else "'"
    local out = { q }
    for i = 1, #s do
        local c = string.sub(s, i, i)
        local b = string.byte(c)
        if c == q or c == "\\" then table.insert(out, "\\" .. c)
        elseif c == "\n" then table.insert(out, "\\n")
        elseif c == "\r" then table.insert(out, "\\r")
        elseif c == "\t" then table.insert(out, "\\t")
        elseif b < 32 or b == 127 then
            table.insert(out, string.format("\\x%02x", b))
        else table.insert(out, c) end
    end
    table.insert(out, q)
    return table.concat(out)
end

local function to_text(v: number, want_repr: boolean): string
    local o = H(v)
    local k = o.k
    if k == "none" then return "None" end
    if k == "bool" then return if o.n ~= 0 then "True" else "False" end
    if k == "int" then return string.format("%d", o.n) end
    if k == "big" then return big_str(o.sign, o.limbs) end
    if k == "float" then return float_repr(o.n) end
    if k == "str" then return if want_repr then str_repr(o.s) else o.s end
    if k == "bytes" then return "b" .. str_repr(o.s) end
    if k == "notimplemented" then return "NotImplemented" end
    if k == "list" or k == "tuple" or k == "set" or k == "frozenset" then
        local parts = {}
        for _, e in ipairs(o.items) do table.insert(parts, to_text(e, true)) end
        if k == "list" then return "[" .. table.concat(parts, ", ") .. "]" end
        if k == "tuple" then
            -- A one-element tuple keeps its comma, which is the only way the
            -- repr distinguishes it from a parenthesised expression.
            if #parts == 1 then return "(" .. parts[1] .. ",)" end
            return "(" .. table.concat(parts, ", ") .. ")"
        end
        if #parts == 0 then
            return if k == "set" then "set()" else "frozenset()"
        end
        local body = "{" .. table.concat(parts, ", ") .. "}"
        return if k == "set" then body else "frozenset(" .. body .. ")"
    end
    if k == "dict" then
        local parts = {}
        for _, key in ipairs(o.keys) do
            table.insert(parts, to_text(key, true) .. ": " ..
                                to_text(o.vals[RT.apy_hash_key(key)], true))
        end
        return "{" .. table.concat(parts, ", ") .. "}"
    end
    if k == "exc" then
        if want_repr then
            return o.exctype .. "(" .. str_repr(o.msg or "") .. ")"
        end
        return o.msg or ""
    end
    if k == "type" then return "<class '" .. o.name .. "'>" end
    if k == "range" then
        -- repr(range(0, 5)) keeps both bounds and shows the step only when it
        -- is not 1, which is what CPython prints.
        if o.step == 1 then
            return "range(" .. o.start .. ", " .. o.stop .. ")"
        end
        return "range(" .. o.start .. ", " .. o.stop .. ", " .. o.step .. ")"
    end
    if k == "inst" then
        return "<" .. H(o.cls).name .. " object>"
    end
    return "<" .. k .. ">"
end

function RT.apy_repr(v: number): number return RT.box_str(to_text(v, true)) end
function RT.apy_str(v: number): number return RT.box_str(to_text(v, false)) end

--- print(*args): one space between, one newline after, each argument through
--- str(). `items` is an array of handles in the IR's flat memory, one per 8
--- bytes because a ptr is 8 bytes wide there.
function RT.apy_print(items: number, h: number, l: number)
    local n = RT.to_number(h, l, true)
    local b, parts = RT.mem(), {}
    for i = 0, n - 1 do
        table.insert(parts, to_text(buffer.readu32(b, items + i * 8), false))
    end
    RT.stdout(table.concat(parts, " "))
end

-- ── hashing and equality ────────────────────────────────────────────────────
-- A dict key needs a Luau-side key. Strings and exact numbers can be
-- themselves; anything else is keyed by its structure so that equal values
-- collide as Python requires.

function RT.apy_hash_key(v: number): any
    local o = H(v)
    local k = o.k
    if k == "str" then return "s\0" .. o.s end
    if k == "bytes" then return "b\0" .. o.s end
    -- 1 == 1.0 == True must be one key, as in Python.
    if k == "int" or k == "float" or k == "bool" then return o.n end
    if k == "big" then return "i\0" .. big_str(o.sign, o.limbs) end
    if k == "none" then return "\0none" end
    if k == "tuple" or k == "frozenset" then
        local parts = {}
        for _, e in ipairs(o.items) do
            table.insert(parts, tostring(RT.apy_hash_key(e)))
        end
        return "t\0" .. table.concat(parts, "\1")
    end
    return v          -- identity, for unhashable-in-practice values
end

function RT.apy_hash(v: number): number
    local key = RT.apy_hash_key(v)
    if type(key) == "number" then return RT.box_int(RT.trunc(key)) end
    local acc = 0
    local s = tostring(key)
    for i = 1, #s do
        acc = (acc * 31 + string.byte(s, i)) % 2251799813685248
    end
    return RT.box_int(acc)
end

-- ── numeric helpers ─────────────────────────────────────────────────────────

local function is_num(k: string): boolean
    return k == "int" or k == "float" or k == "bool" or k == "big"
end

local function num_of(v: number): number
    local o = H(v)
    if o.k == "big" then return RT.apy_as_float(v) end
    return o.n
end

local function either_float(a: number, b: number): boolean
    return H(a).k == "float" or H(b).k == "float"
end

local function either_big(a: number, b: number): boolean
    return H(a).k == "big" or H(b).k == "big"
end

local function big_add(a: number, b: number, negate_b: boolean): number
    local sa, la = as_big(a)
    local sb, lb = as_big(b)
    if negate_b then sb = -sb end
    if sa == 0 then return make_int(sb, lb) end
    if sb == 0 then return make_int(sa, la) end
    if sa == sb then return make_int(sa, big_add_abs(la, lb)) end
    local c = big_cmp_abs(la, lb)
    if c == 0 then return RT.box_int(0) end
    if c > 0 then return make_int(sa, big_sub_abs(la, lb)) end
    return make_int(sb, big_sub_abs(lb, la))
end

-- ── arithmetic ──────────────────────────────────────────────────────────────

local SAFE = 94906265        -- floor(sqrt(2^53)); products below this are exact
local HALF = 4503599627370496   -- 2^52

--- Is `x + y` exact in a double?
---
--- Asked of the OPERANDS, and that is the whole point. Checking the sum
--- instead is what `int_result` used to do, and it is wrong in the one case
--- that matters: 2^53 + 1 rounds to 2^53 during the addition, so the check
--- receives a value that is already wrong, finds it inside the exact range,
--- and returns it. `2**53 + 1 == 2**53` was True.
---
--- Below 2^52 each, the sum cannot exceed 2^53, where every integer is still
--- representable. Anything larger goes through limbs.
local function exact_sum(x: number, y: number): boolean
    return x >= -HALF and x <= HALF and y >= -HALF and y <= HALF
end

function RT.apy_add(a: number, b: number): number
    local ka, kb = kindof(a), kindof(b)
    if ka == "str" and kb == "str" then return RT.box_str(H(a).s .. H(b).s) end
    if ka == "list" and kb == "list" then
        local out = {}
        for _, e in ipairs(H(a).items) do table.insert(out, e) end
        for _, e in ipairs(H(b).items) do table.insert(out, e) end
        return new({ k = "list", items = out })
    end
    if ka == "tuple" and kb == "tuple" then
        local out = {}
        for _, e in ipairs(H(a).items) do table.insert(out, e) end
        for _, e in ipairs(H(b).items) do table.insert(out, e) end
        return new({ k = "tuple", items = out })
    end
    if not (is_num(ka) and is_num(kb)) then
        return err("TypeError", "unsupported operand type(s) for +: '" ..
                   TYPE_NAME[ka] .. "' and '" .. TYPE_NAME[kb] .. "'")
    end
    if either_float(a, b) then return RT.box_float(num_of(a) + num_of(b)) end
    if either_big(a, b) then return big_add(a, b, false) end
    if exact_sum(H(a).n, H(b).n) then return RT.box_int(H(a).n + H(b).n) end
    return big_add(a, b, false)
end

function RT.apy_iadd(a: number, b: number): number
    -- `+=` on a list mutates in place, which is observable through any other
    -- name bound to it; every other type falls back to `+`.
    if kindof(a) == "list" and (kindof(b) == "list" or kindof(b) == "tuple") then
        for _, e in ipairs(H(b).items) do table.insert(H(a).items, e) end
        return a
    end
    return RT.apy_add(a, b)
end

function RT.apy_sub(a: number, b: number): number
    local ka, kb = kindof(a), kindof(b)
    if not (is_num(ka) and is_num(kb)) then
        return err("TypeError", "unsupported operand type(s) for -: '" ..
                   TYPE_NAME[ka] .. "' and '" .. TYPE_NAME[kb] .. "'")
    end
    if either_float(a, b) then return RT.box_float(num_of(a) - num_of(b)) end
    if either_big(a, b) then return big_add(a, b, true) end
    if exact_sum(H(a).n, H(b).n) then return RT.box_int(H(a).n - H(b).n) end
    return big_add(a, b, true)
end

function RT.apy_mul(a: number, b: number): number
    local ka, kb = kindof(a), kindof(b)
    -- Sequence repetition, both ways round.
    if (ka == "str" or ka == "list" or ka == "tuple") and (kb == "int" or kb == "bool") then
        return RT.seq_repeat(a, H(b).n)
    end
    if (kb == "str" or kb == "list" or kb == "tuple") and (ka == "int" or ka == "bool") then
        return RT.seq_repeat(b, H(a).n)
    end
    if not (is_num(ka) and is_num(kb)) then
        return err("TypeError", "unsupported operand type(s) for *: '" ..
                   TYPE_NAME[ka] .. "' and '" .. TYPE_NAME[kb] .. "'")
    end
    if either_float(a, b) then return RT.box_float(num_of(a) * num_of(b)) end
    if either_big(a, b) then
        local sa, la = as_big(a)
        local sb, lb = as_big(b)
        return make_int(sa * sb, big_mul_abs(la, lb))
    end
    local x, y = H(a).n, H(b).n
    -- Below the square root of 2^53 the product is exact; above it the
    -- multiplication would round before anyone could check the result.
    if math.abs(x) < SAFE and math.abs(y) < SAFE then
        return RT.box_int(x * y)
    end
    local sa = if x < 0 then -1 else 1
    local sb = if y < 0 then -1 else 1
    return make_int(sa * sb, big_mul_abs(big_from_abs(math.abs(x)),
                                         big_from_abs(math.abs(y))))
end

function RT.seq_repeat(s: number, count: number): number
    local o = H(s)
    if count < 0 then count = 0 end
    if o.k == "str" then return RT.box_str(string.rep(o.s, count)) end
    local out = {}
    for _ = 1, count do
        for _, e in ipairs(o.items) do table.insert(out, e) end
    end
    return new({ k = o.k, items = out })
end

function RT.apy_truediv(a: number, b: number): number
    if not (is_num(kindof(a)) and is_num(kindof(b))) then
        return err("TypeError", "unsupported operand type(s) for /")
    end
    local y = num_of(b)
    if y == 0 then return err("ZeroDivisionError", "division by zero") end
    return RT.box_float(num_of(a) / y)
end

--- Floor division and floored modulo on integers of any size.
---
--- Python defines a = b*q + r with q = floor(a/b) and r taking the DIVISOR's
--- sign. Long division gives the truncated pair, so a mixed-sign result is
--- corrected by one: q goes down by one and r moves by b. Skipping that
--- correction is what makes -7//2 come out -3 instead of -4.
local function int_divmod(a: number, b: number): (number?, number?)
    local sa, la = as_big(a)
    local sb, lb = as_big(b)
    local qa, ra = big_divmod_abs(la, lb)
    local qs = sa * sb
    if not big_is_zero(ra) and qs < 0 then
        qa = big_add_abs(qa, { 1 })
        ra = big_sub_abs(lb, ra)
        return make_int(-1, qa), make_int(sb, ra)
    end
    return make_int(qs, qa), make_int(sa, ra)
end

function RT.apy_floordiv(a: number, b: number): number
    if not (is_num(kindof(a)) and is_num(kindof(b))) then
        return err("TypeError", "unsupported operand type(s) for //")
    end
    if either_float(a, b) then
        local y = num_of(b)
        if y == 0 then
            return err("ZeroDivisionError", "float floor division by zero")
        end
        return RT.box_float(math.floor(num_of(a) / y))
    end
    local _, zt = RT.apy_truth(b)
    if zt == 0 then
        return err("ZeroDivisionError", "integer division or modulo by zero")
    end
    local q = int_divmod(a, b)
    return q :: number
end

function RT.apy_mod(a: number, b: number): number
    local ka = kindof(a)
    if ka == "str" then
        return err("NotImplementedError", "printf-style % formatting")
    end
    if not (is_num(ka) and is_num(kindof(b))) then
        return err("TypeError", "unsupported operand type(s) for %")
    end
    if either_float(a, b) then
        local y = num_of(b)
        if y == 0 then
            return err("ZeroDivisionError", "float modulo by zero")
        end
        -- Luau's % is floored and so is Python's, so a float remainder agrees
        -- directly. C's fmod truncates and would differ for mixed signs.
        return RT.box_float(num_of(a) % y)
    end
    local _, zt = RT.apy_truth(b)
    if zt == 0 then
        return err("ZeroDivisionError", "integer division or modulo by zero")
    end
    local _, r = int_divmod(a, b)
    return r :: number
end

function RT.apy_pow(a: number, b: number): number
    if not (is_num(kindof(a)) and is_num(kindof(b))) then
        return err("TypeError", "unsupported operand type(s) for **")
    end
    local x, y = num_of(a), num_of(b)
    if not either_float(a, b) and y >= 0 and y % 1 == 0 then
        -- Integer power stays exact by repeated squaring in limbs.
        local sign, limbs = as_big(a)
        local rs, rl = 1, { 1 }
        local bs, bl = sign, limbs
        local e = y
        while e > 0 do
            if e % 2 == 1 then rs, rl = rs * bs, big_mul_abs(rl, bl) end
            bs, bl = bs * bs, big_mul_abs(bl, bl)
            e = math.floor(e / 2)
        end
        return make_int(rs, rl)
    end
    if x < 0 and y % 1 ~= 0 then
        return err("ValueError", "negative number cannot be raised to a "
                   .. "fractional power")
    end
    return RT.box_float(x ^ y)
end

function RT.apy_neg(v: number): number
    local o = H(v)
    if o.k == "big" then return make_int(-o.sign, o.limbs) end
    if not is_num(o.k) then
        return err("TypeError", "bad operand type for unary -")
    end
    if o.k == "float" then return RT.box_float(-o.n) end
    return RT.box_int(-o.n)
end

function RT.apy_pos(v: number): number
    if not is_num(kindof(v)) then
        return err("TypeError", "bad operand type for unary +")
    end
    return v
end

function RT.apy_invert(v: number): number
    local o = H(v)
    if o.k ~= "int" and o.k ~= "bool" then
        if o.k == "big" then
            -- ~x == -x - 1 holds at any width, so this needs no bit work.
            return RT.apy_sub(RT.apy_neg(v), RT.box_int(1))
        end
        return err("TypeError", "bad operand type for unary ~")
    end
    return RT.box_int(-o.n - 1)
end

--- Bitwise operations, which Python defines on unbounded integers.
---
--- bit32 is 32 bits and these are not, so the work is done a limb at a time
--- through the 64-bit helpers for values that fit and rejected above that --
--- reported rather than truncated, because a silently 32-bit `&` is the exact
--- shape of bug this backend has already produced three times.
local function bitwise(a: number, b: number, op: string, name: string): number
    local ka, kb = kindof(a), kindof(b)
    if not ((ka == "int" or ka == "bool") and (kb == "int" or kb == "bool")) then
        if ka == "big" or kb == "big" then
            return err("OverflowError",
                       "bitwise " .. name .. " on integers beyond 64 bits is "
                       .. "not implemented yet")
        end
        return err("TypeError", "unsupported operand type(s) for " .. name)
    end
    local ah, al = RT.from_number(H(a).n)
    local bh, bl = RT.from_number(H(b).n)
    local rh, rl
    if op == "and" then rh, rl = RT.and64(ah, al, bh, bl)
    elseif op == "or" then rh, rl = RT.or64(ah, al, bh, bl)
    else rh, rl = RT.xor64(ah, al, bh, bl) end
    return RT.box_int(RT.to_number(rh, rl, true))
end

function RT.apy_bitand(a, b) return bitwise(a, b, "and", "&") end
function RT.apy_bitor(a, b) return bitwise(a, b, "or", "|") end
function RT.apy_bitxor(a, b) return bitwise(a, b, "xor", "^") end

function RT.apy_lshift(a: number, b: number): number
    if kindof(b) ~= "int" and kindof(b) ~= "bool" then
        return err("TypeError", "unsupported operand type(s) for <<")
    end
    local n = H(b).n
    if n < 0 then return err("ValueError", "negative shift count") end
    -- Shifting is multiplication by a power of two, which the limb path
    -- already does exactly at any width.
    return RT.apy_mul(a, RT.apy_pow(RT.box_int(2), RT.box_int(n)))
end

function RT.apy_rshift(a: number, b: number): number
    if kindof(b) ~= "int" and kindof(b) ~= "bool" then
        return err("TypeError", "unsupported operand type(s) for >>")
    end
    local n = H(b).n
    if n < 0 then return err("ValueError", "negative shift count") end
    if kindof(a) == "big" then
        return err("OverflowError",
                   ">> on integers beyond 64 bits is not implemented yet")
    end
    return RT.box_int(math.floor(H(a).n / 2 ^ n))
end

-- ── comparison ──────────────────────────────────────────────────────────────

function RT.apy_is(a: number, b: number): number
    return RT.box_bool(a == b)
end

local function eq(a: number, b: number): boolean
    if a == b then return true end
    local oa, ob = H(a), H(b)
    local ka, kb = oa.k, ob.k
    if is_num(ka) and is_num(kb) then
        if ka == "big" or kb == "big" then
            local sa, la = as_big(a)
            local sb, lb = as_big(b)
            return sa == sb and big_cmp_abs(la, lb) == 0
        end
        return oa.n == ob.n
    end
    if (ka == "str" and kb == "str") or (ka == "bytes" and kb == "bytes") then
        return oa.s == ob.s
    end
    if (ka == "list" and kb == "list") or (ka == "tuple" and kb == "tuple") then
        if #oa.items ~= #ob.items then return false end
        for i, e in ipairs(oa.items) do
            if not eq(e, ob.items[i]) then return false end
        end
        return true
    end
    if ka == "dict" and kb == "dict" then
        if #oa.keys ~= #ob.keys then return false end
        for _, k in ipairs(oa.keys) do
            local hk = RT.apy_hash_key(k)
            if ob.vals[hk] == nil then return false end
            if not eq(oa.vals[hk], ob.vals[hk]) then return false end
        end
        return true
    end
    if (ka == "set" or ka == "frozenset") and (kb == "set" or kb == "frozenset") then
        if #oa.items ~= #ob.items then return false end
        for _, e in ipairs(oa.items) do
            local found = false
            for _, f in ipairs(ob.items) do
                if eq(e, f) then
                    found = true
                    break
                end
            end
            if not found then return false end
        end
        return true
    end
    return false
end

function RT.apy_eq(a, b) return RT.box_bool(eq(a, b)) end
function RT.apy_ne(a, b) return RT.box_bool(not eq(a, b)) end

--- Ordered comparison. Returns -1, 0, 1, or nil when the pair is unorderable.
local function cmp(a: number, b: number): number?
    local oa, ob = H(a), H(b)
    local ka, kb = oa.k, ob.k
    if is_num(ka) and is_num(kb) then
        if ka == "big" or kb == "big" then
            local sa, la = as_big(a)
            local sb, lb = as_big(b)
            if sa ~= sb then return if sa < sb then -1 else 1 end
            local c = big_cmp_abs(la, lb)
            return if sa < 0 then -c else c
        end
        if oa.n == ob.n then return 0 end
        return if oa.n < ob.n then -1 else 1
    end
    if (ka == "str" and kb == "str") or (ka == "bytes" and kb == "bytes") then
        if oa.s == ob.s then return 0 end
        return if oa.s < ob.s then -1 else 1
    end
    if (ka == "list" and kb == "list") or (ka == "tuple" and kb == "tuple") then
        -- Lexicographic, element by element, shorter-is-less on a tie.
        local n = math.min(#oa.items, #ob.items)
        for i = 1, n do
            local c = cmp(oa.items[i], ob.items[i])
            if c == nil then return nil end
            if c ~= 0 then return c end
        end
        if #oa.items == #ob.items then return 0 end
        return if #oa.items < #ob.items then -1 else 1
    end
    return nil
end

RT.cmp_values = cmp

local function order(a: number, b: number, want: string, sym: string): number
    local c = cmp(a, b)
    if c == nil then
        return err("TypeError", "'" .. sym .. "' not supported between "
                   .. "instances of '" .. (TYPE_NAME[kindof(a)] or "?")
                   .. "' and '" .. (TYPE_NAME[kindof(b)] or "?") .. "'")
    end
    if want == "lt" then return RT.box_bool(c < 0) end
    if want == "le" then return RT.box_bool(c <= 0) end
    if want == "gt" then return RT.box_bool(c > 0) end
    return RT.box_bool(c >= 0)
end

function RT.apy_lt(a, b) return order(a, b, "lt", "<") end
function RT.apy_le(a, b) return order(a, b, "le", "<=") end
function RT.apy_gt(a, b) return order(a, b, "gt", ">") end
function RT.apy_ge(a, b) return order(a, b, "ge", ">=") end

function RT.apy_contains(needle: number, hay: number): number
    local o = H(hay)
    local k = o.k
    if k == "str" then
        if kindof(needle) ~= "str" then
            return err("TypeError", "'in <string>' requires string as left "
                       .. "operand")
        end
        return RT.box_bool(string.find(o.s, H(needle).s, 1, true) ~= nil)
    end
    if k == "dict" then
        return RT.box_bool(o.vals[RT.apy_hash_key(needle)] ~= nil)
    end
    if k == "list" or k == "tuple" or k == "set" or k == "frozenset" then
        for _, e in ipairs(o.items) do
            if eq(e, needle) then return TRUE end
        end
        return FALSE
    end
    return err("TypeError", "argument of type '" .. (TYPE_NAME[k] or k)
               .. "' is not iterable")
end

-- ── conversions ─────────────────────────────────────────────────────────────

function RT.apy_to_int(v: number): number
    local o = H(v)
    local k = o.k
    if k == "int" or k == "big" then return v end
    if k == "bool" then return RT.box_int(o.n) end
    if k == "float" then
        if o.n ~= o.n or o.n == math.huge or o.n == -math.huge then
            return err("ValueError", "cannot convert float " ..
                       float_repr(o.n) .. " to integer")
        end
        return RT.box_int(RT.trunc(o.n))
    end
    if k == "str" then
        local s = string.match(o.s, "^%s*(.-)%s*$")
        local n = tonumber(s, 10)
        if n == nil or n % 1 ~= 0 then
            return err("ValueError",
                       "invalid literal for int() with base 10: " .. str_repr(o.s))
        end
        return RT.box_int(n)
    end
    return err("TypeError", "int() argument must be a string or a number")
end

function RT.apy_to_float(v: number): number
    local o = H(v)
    local k = o.k
    if k == "float" then return v end
    if k == "int" or k == "bool" or k == "big" then
        return RT.box_float(RT.apy_as_float(v))
    end
    if k == "str" then
        local n = tonumber(string.match(o.s, "^%s*(.-)%s*$"))
        if n == nil then
            return err("ValueError",
                       "could not convert string to float: " .. str_repr(o.s))
        end
        return RT.box_float(n + 0.0)
    end
    return err("TypeError", "float() argument must be a string or a number")
end

function RT.apy_to_bool(v: number): number
    local _, t = RT.apy_truth(v)
    return if t ~= 0 then TRUE else FALSE
end

-- ── sequences and mappings ──────────────────────────────────────────────────

function RT.apy_list_new(h: number, l: number): number
    return new({ k = "list", items = {} })
end

function RT.apy_tuple_new(h: number, l: number): number
    return new({ k = "tuple", items = {} })
end

function RT.apy_seq_push(seq: number, item: number): number
    table.insert(H(seq).items, item)
    return seq
end

function RT.apy_dict_new(h: number, l: number): number
    -- `keys` preserves insertion order, which Python guarantees and a bare
    -- Luau table does not; `vals` is keyed by hash for lookup.
    return new({ k = "dict", keys = {}, vals = {} })
end

function RT.apy_dict_set(d: number, key: number, val: number): number
    local o = H(d)
    local hk = RT.apy_hash_key(key)
    if o.vals[hk] == nil then table.insert(o.keys, key) end
    o.vals[hk] = val
    return d
end

function RT.apy_key_at(d: number, h: number, l: number): number
    local i = RT.to_number(h, l, true)
    local key = H(d).keys[i + 1]
    return if key == nil then 0 else key
end

function RT.apy_raw_len(v: number): (number, number)
    local o = H(v)
    if o.k == "dict" then return RT.from_number(#o.keys) end
    if o.k == "str" or o.k == "bytes" then return RT.from_number(#o.s) end
    if o.items ~= nil then return RT.from_number(#o.items) end
    return RT.from_number(0)
end

function RT.apy_len(v: number): number
    local o = H(v)
    local k = o.k
    if k == "str" or k == "bytes" then return RT.box_int(#o.s) end
    if k == "dict" then return RT.box_int(#o.keys) end
    if k == "range" then return RT.box_int(RT.range_len(o)) end
    if o.items ~= nil then return RT.box_int(#o.items) end
    return err("TypeError", "object of type '" .. (TYPE_NAME[k] or k)
               .. "' has no len()")
end

--- Python's index rules in one place: negative counts from the end, and out of
--- range is an error rather than a clamp. Luau arrays are 1-based, so the +1
--- lives here and nowhere else.
local function seq_index(o: any, idx: number, n: number): number?
    if idx < 0 then idx += n end
    if idx < 0 or idx >= n then return nil end
    return idx + 1
end

function RT.apy_getitem(c: number, key: number): number
    local o = H(c)
    local k = o.k
    if k == "dict" then
        local got = o.vals[RT.apy_hash_key(key)]
        if got == nil then
            return err("KeyError", to_text(key, true))
        end
        return got
    end
    if k == "str" or k == "bytes" then
        if not is_num(kindof(key)) then
            return err("TypeError", "string indices must be integers")
        end
        local i = seq_index(o, H(key).n, #o.s)
        if i == nil then return err("IndexError", "string index out of range") end
        return RT.box_str(string.sub(o.s, i, i))
    end
    if o.items ~= nil then
        if kindof(key) == "slice" then return RT.seq_slice(c, key) end
        if not is_num(kindof(key)) then
            return err("TypeError", (TYPE_NAME[k] or k)
                       .. " indices must be integers")
        end
        local i = seq_index(o, H(key).n, #o.items)
        if i == nil then
            return err("IndexError", (TYPE_NAME[k] or k)
                       .. " index out of range")
        end
        return o.items[i]
    end
    return err("TypeError", "'" .. (TYPE_NAME[k] or k)
               .. "' object is not subscriptable")
end

function RT.apy_setitem(c: number, key: number, val: number): number
    local o = H(c)
    if o.k == "dict" then return RT.apy_dict_set(c, key, val) end
    if o.k == "list" then
        local i = seq_index(o, H(key).n, #o.items)
        if i == nil then
            return err("IndexError", "list assignment index out of range")
        end
        o.items[i] = val
        return c
    end
    if o.k == "tuple" then
        return err("TypeError", "'tuple' object does not support item assignment")
    end
    return err("TypeError", "'" .. (TYPE_NAME[o.k] or o.k)
               .. "' object does not support item assignment")
end

-- ── iteration ───────────────────────────────────────────────────────────────
-- `apy_step` answers the STOP SENTINEL at exhaustion and 0 on error, which are
-- different things: 0 means an error is set and the caller must propagate.

local STOP = new({ k = "stopiter" })

function RT.apy_stop(): number return STOP end

function RT.apy_getiter(v: number): number
    local o = H(v)
    local k = o.k
    if k == "iter" then return v end
    if k == "range" then
        local cur, stop, step = o.start, o.stop, o.step
        return RT.lazy_iter(function()
            if step > 0 then
                if cur >= stop then return nil end
            elseif cur <= stop then
                return nil
            end
            local v2 = RT.box_int(cur)
            cur += step
            return v2
        end)
    end
    if k == "str" or k == "bytes" then
        local chars = {}
        for i = 1, #o.s do
            table.insert(chars, RT.box_str(string.sub(o.s, i, i)))
        end
        return new({ k = "iter", items = chars, i = 0 })
    end
    if k == "dict" then
        -- Iterating a dict walks its KEYS, and reads them when the walk
        -- starts rather than when the iterator was made.
        local keys = {}
        for _, key in ipairs(o.keys) do table.insert(keys, key) end
        return new({ k = "iter", items = keys, i = 0 })
    end
    if o.items ~= nil then
        local copy = {}
        for _, e in ipairs(o.items) do table.insert(copy, e) end
        return new({ k = "iter", items = copy, i = 0 })
    end
    return err("TypeError", "'" .. (TYPE_NAME[k] or k)
               .. "' object is not iterable")
end

function RT.apy_step(it: number): number
    local o = H(it)
    if o.k ~= "iter" then
        return err("TypeError", "'" .. (TYPE_NAME[o.k] or o.k)
                   .. "' object is not an iterator")
    end
    -- A LAZY iterator carries a closure instead of an array. `range(10**9)`
    -- must not allocate a billion handles to be walked once, and `enumerate`
    -- and `zip` are cursors over other iterators rather than copies of them.
    if o.gen ~= nil then
        local v = o.gen()
        if v == nil then return STOP end
        return v
    end
    o.i += 1
    local v = o.items[o.i]
    if v == nil then return STOP end
    return v
end

--- An iterator backed by a closure. `gen` answers the next value, or nil when
--- exhausted; returning handle 0 from it propagates an error as usual.
function RT.lazy_iter(gen): number
    return new({ k = "iter", gen = gen })
end

--- A range, kept lazy. `start`, `stop` and `step` are Luau numbers: the ABI
--- passes them as i64 and a range wider than 2^53 is not a thing a program
--- walks to the end of.
function RT.range_new(start: number, stop: number, step: number): number
    return new({ k = "range", start = start, stop = stop, step = step })
end

--- How many values a range yields. The formula is Python's: an empty range
--- when the step points away from the stop, never a negative length.
function RT.range_len(o: any): number
    if o.step > 0 then
        if o.stop <= o.start then return 0 end
        return math.floor((o.stop - o.start - 1) / o.step) + 1
    end
    if o.stop >= o.start then return 0 end
    return math.floor((o.start - o.stop - 1) / -o.step) + 1
end

-- ── attributes, types and calls ─────────────────────────────────────────────

function RT.apy_getattr(v: number, name: number): number
    local o = H(v)
    local nm = H(name).s
    if o.k == "inst" then
        local got = o.fields[nm]
        if got ~= nil then return got end
        -- Through class_find, so a base class's attributes are reachable.
        local m = RT.class_find(o.cls, nm)
        if m ~= nil then
            -- Bind only what is CALLABLE. A class-level constant reached
            -- through an instance is the value itself, not a method wrapping
            -- it -- `class C: kind = "point"` then `C().kind` is the string.
            local mk = kindof(m)
            if mk == "func" or mk == "bound" then
                return new({ k = "bound", fn = m, self_ = v })
            end
            if mk == "descr" then
                -- A property reads through its getter on every access.
                local d = H(m)
                if d.descr_kind == 0 and d.get ~= 0 then
                    local argv = RT.alloca(8)
                    buffer.writeu32(RT.mem(), argv, v)
                    buffer.writeu32(RT.mem(), argv + 4, 0)
                    return RT.apy_call(d.get, argv, 0, 1)
                end
                return d.get
            end
            return m
        end
        return err("AttributeError", "'" .. H(o.cls).name
                   .. "' object has no attribute '" .. nm .. "'")
    end
    if o.k == "type" then
        local m = RT.class_find(v, nm)
        if m ~= nil then return m end
        return err("AttributeError", "type object '" .. o.name
                   .. "' has no attribute '" .. nm .. "'")
    end
    if o.k == "exc" then
        if nm == "args" then
            return new({ k = "tuple", items = o.args })
        end
    end
    return err("AttributeError", "'" .. (TYPE_NAME[o.k] or o.k)
               .. "' object has no attribute '" .. nm .. "'")
end

function RT.apy_setattr(v: number, name: number, val: number): number
    local o = H(v)
    if o.k == "inst" then
        o.fields[H(name).s] = val
        return NONE
    end
    if o.k == "type" then
        o.methods[H(name).s] = val
        return NONE
    end
    return err("AttributeError", "'" .. (TYPE_NAME[o.k] or o.k)
               .. "' object has no attribute '" .. H(name).s .. "'")
end

-- ── callables, cells and classes ────────────────────────────────────────────
-- The frontend builds a function object before it can call one, so these run
-- in every program's prologue whether or not it defines a function of its own.

--- apy_func_new(code, nparams, name, flags, ndefaults, nfree)
---
--- `code` is a function id from `func_addr`, not a pointer to anything the
--- object model may follow. Keeping it opaque here is what lets the emitter
--- decide how a compiled function is represented.
function RT.apy_func_new(code: number, nph: number, npl: number, name: number,
                         fh: number, fl: number, dh: number, dl: number,
                         ch: number, cl: number): number
    return new({
        k = "func",
        fnid = code,
        nparams = RT.to_number(nph, npl, true),
        name = if name ~= 0 and RT.kindof(name) == "str" then RT.as_str(name)
               else "<anonymous>",
        flags = RT.to_number(fh, fl, true),
        defaults = {},
        params = {},
        cells = {},
    })
end

--- Record a default for parameter i (0-based), counted from the LAST
--- parameter as Python does -- defaults fill from the right.
function RT.apy_func_default(f: number, h: number, l: number,
                             val: number): number
    H(f).defaults[RT.to_number(h, l, true) + 1] = val
    return f
end

function RT.apy_func_param(f: number, h: number, l: number,
                           name: number): number
    H(f).params[RT.to_number(h, l, true) + 1] = RT.as_str(name)
    return f
end

function RT.apy_func_qualname(f: number, name: number): number
    H(f).qualname = RT.as_str(name)
    return f
end

function RT.apy_func_annotate(f: number, ann: number): number
    H(f).annotations = ann
    return f
end

--- Is this function object usable as a type? The frontend asks so that
--- `int(x)` reaches the builtin rather than an ordinary call.
function RT.apy_func_is_type(f: number): number
    H(f).is_type = true
    return f
end

function RT.apy_func_builtin(f: number): number
    H(f).builtin = true
    return f
end

-- Closure cells: a mutable box shared between a closure and its enclosing
-- scope, which is the only way a nested `def` can rebind an outer local.
function RT.apy_cell_new(v: number): number
    return new({ k = "cell", v = v })
end

function RT.apy_cell_get(c: number): number
    return H(c).v
end

function RT.apy_cell_set(c: number, v: number): number
    H(c).v = v
    return NONE
end

function RT.apy_func_cell(f: number, h: number, l: number,
                          cell: number): number
    H(f).cells[RT.to_number(h, l, true) + 1] = cell
    return f
end

function RT.apy_env_cell(f: number, h: number, l: number): number
    local c = H(f).cells[RT.to_number(h, l, true) + 1]
    return if c == nil then NONE else c
end

function RT.apy_type_new(name: number, bases: number): number
    return new({
        k = "type",
        name = if name ~= 0 and RT.kindof(name) == "str" then RT.as_str(name)
               else "object",
        bases = bases,
        methods = {},
    })
end

function RT.apy_type_set(ty: number, name: number, val: number): number
    H(ty).methods[RT.as_str(name)] = val
    return ty
end

function RT.apy_instance_new(ty: number): number
    return new({ k = "inst", cls = ty, fields = {} })
end

--- These two are bookkeeping the C does at class-creation time. Nothing here
--- needs them yet, and returning the class unchanged is correct rather than a
--- stub: __slots__ checking and __set_name__ have no effect on a class that
--- declares neither.
function RT.apy_check_slots(ty: number): number return ty end
function RT.apy_set_names(ty: number): number return ty end

function RT.apy_getattr_default(v: number, name: number,
                                fallback: number): number
    local got = RT.apy_getattr(v, name)
    if got == 0 then
        RT.apy_error_clear()
        return fallback
    end
    return got
end

function RT.apy_is_instance(v: number): (number, number)
    return 0, (if RT.kindof(v) == "inst" then 1 else 0)
end

--- Call a runtime value. `argv` is an array of handles in flat memory.
function RT.apy_call(f: number, argv: number, h: number, l: number): number
    local n = RT.to_number(h, l, true)
    local args = {}
    local b = RT.mem()
    for i = 0, n - 1 do
        table.insert(args, buffer.readu32(b, argv + i * 8))
    end
    local o = H(f)
    if o.k == "func" then
        return RT.invoke(o.fnid, args)
    end
    if o.k == "bound" then
        table.insert(args, 1, o.self_)
        return RT.invoke(H(o.fn).fnid, args)
    end
    if o.k == "type" then
        local inst = new({ k = "inst", cls = f, fields = {} })
        local init = o.methods["__init__"]
        if init ~= nil then
            table.insert(args, 1, inst)
            local r = RT.invoke(H(init).fnid, args)
            if r == 0 then return 0 end
        end
        return inst
    end
    return err("TypeError", "'" .. (TYPE_NAME[o.k] or o.k)
               .. "' object is not callable")
end
