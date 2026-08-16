-- Integer inspection, base conversion, and the slice object.
--
-- The group Luau punishes most, because every one of these is about a value's
-- BITS and Luau's only number type is a double. Anything that would go through
-- one above 2^53 works from the limbs instead.

--- An integer's magnitude, as base-2^24 limbs, plus its sign.
--- Returns nil with an error set when the value is not an integer.
local function int_limbs(v: number): (any, number?)
    local o = RT.H(v)
    if o.k == "big" then return o.limbs, o.sign end
    if o.k ~= "int" and o.k ~= "bool" then
        RT.err("TypeError",
               "'" .. RT.kindof(v) .. "' object cannot be interpreted as an "
               .. "integer")
        return nil, nil
    end
    local n = o.n
    local sign = if n < 0 then -1 else (if n == 0 then 0 else 1)
    local x = math.abs(n)
    local limbs = {}
    if x < 16777216 then
        limbs = { x }
    else
        while x > 0 do
            table.insert(limbs, x % 16777216)
            x = (x - x % 16777216) / 16777216
        end
    end
    return limbs, sign
end

--- bit_length(): the number of bits needed for the MAGNITUDE, so it ignores
--- the sign entirely -- (-5).bit_length() is 3, the same as 5.
function RT.apy_bit_length(v: number): number
    local limbs = int_limbs(v)
    if limbs == nil then return 0 end
    local top = limbs[#limbs]
    if #limbs == 1 and top == 0 then return RT.box_int(0) end
    local bits = (#limbs - 1) * 24
    while top > 0 do
        bits += 1
        top = math.floor(top / 2)
    end
    return RT.box_int(bits)
end

--- bit_count(): population count of the MAGNITUDE, again ignoring the sign.
function RT.apy_bit_count(v: number): number
    local limbs = int_limbs(v)
    if limbs == nil then return 0 end
    local n = 0
    for _, limb in ipairs(limbs) do
        local x = limb
        while x > 0 do
            n += x % 2
            x = math.floor(x / 2)
        end
    end
    return RT.box_int(n)
end

-- ── base conversion ─────────────────────────────────────────────────────────

local DIGITS = "0123456789abcdefghijklmnopqrstuvwxyz"

--- Divide a limb array by a small number, in place-safe fashion.
local function divmod_small(limbs, d: number)
    local q, rem = {}, 0
    for i = #limbs, 1, -1 do
        local cur = rem * 16777216 + limbs[i]
        q[i] = math.floor(cur / d)
        rem = cur - q[i] * d
    end
    while #q > 1 and q[#q] == 0 do table.remove(q) end
    return q, rem
end

local function is_zero(limbs): boolean
    return #limbs == 1 and limbs[1] == 0
end

--- The digits of a magnitude in `base`, most significant first.
local function digits_in(limbs, base: number): string
    if is_zero(limbs) then return "0" end
    local out, cur = {}, limbs
    while not is_zero(cur) do
        local q, r = divmod_small(cur, base)
        table.insert(out, 1, string.sub(DIGITS, r + 1, r + 1))
        cur = q
    end
    return table.concat(out)
end

--- bin/oct/hex put the sign BEFORE the prefix: bin(-5) is '-0b101', not
--- '0b-101'. Every implementation that concatenates in the obvious order gets
--- this backwards.
local function based(v: number, base: number, prefix: string): number
    local limbs, sign = int_limbs(v)
    if limbs == nil then return 0 end
    local body = digits_in(limbs, base)
    local minus = if sign == -1 then "-" else ""
    return RT.box_str(minus .. prefix .. body)
end

function RT.apy_bin(v) return based(v, 2, "0b") end
function RT.apy_oct(v) return based(v, 8, "0o") end
function RT.apy_hex(v) return based(v, 16, "0x") end

--- int(s, base). Accepts the matching prefix, an optional sign, underscores
--- as digit separators, and surrounding whitespace -- all of which Python
--- accepts and none of which `tonumber` handles the same way.
function RT.apy_to_int_base(s: number, b: number): number
    if RT.kindof(s) ~= "str" then
        return RT.err("TypeError",
                      "int() can't convert non-string with explicit base")
    end
    local base = RT.H(b).n
    if base ~= 0 and (base < 2 or base > 36) then
        return RT.err("ValueError", "int() base must be >= 2 and <= 36, or 0")
    end
    local text = RT.as_str(s)
    local body = string.match(text, "^%s*(.-)%s*$")
    local sign = 1
    local first = string.sub(body, 1, 1)
    if first == "-" then
        sign = -1
        body = string.sub(body, 2)
    elseif first == "+" then
        body = string.sub(body, 2)
    end
    local prefixes = { [2] = "0b", [8] = "0o", [16] = "0x" }
    local lower = string.lower(body)
    if base == 0 then
        -- base 0 means "read the prefix", and a bare leading zero is only
        -- legal as the literal 0.
        base = 10
        for b2, pre in pairs(prefixes) do
            if string.sub(lower, 1, 2) == pre then
                base = b2
                body = string.sub(body, 3)
                break
            end
        end
    elseif prefixes[base] ~= nil
        and string.sub(lower, 1, 2) == prefixes[base] then
        body = string.sub(body, 3)
    end
    body = string.gsub(body, "_", "")
    if #body == 0 then
        return RT.err("ValueError",
                      "invalid literal for int() with base " .. base
                      .. ": " .. RT.as_str(RT.apy_repr(s)))
    end
    -- Accumulated through apy_mul/apy_add so a long literal promotes to limbs
    -- instead of rounding: int("1" * 30) is exact.
    local acc = RT.box_int(0)
    local B = RT.box_int(base)
    for i = 1, #body do
        local c = string.lower(string.sub(body, i, i))
        local d = string.find(DIGITS, c, 1, true)
        if d == nil or d - 1 >= base then
            return RT.err("ValueError",
                          "invalid literal for int() with base " .. base
                          .. ": " .. RT.as_str(RT.apy_repr(s)))
        end
        acc = RT.apy_add(RT.apy_mul(acc, B), RT.box_int(d - 1))
        if acc == 0 then return 0 end
    end
    if sign < 0 then return RT.apy_neg(acc) end
    return acc
end

-- ── divmod and three-argument pow ───────────────────────────────────────────

--- divmod(a, b) -> (a // b, a % b), computed once rather than twice, and
--- agreeing with the floor division and floored modulo defined in objects.luau.
function RT.apy_divmod(a: number, b: number): number
    local q = RT.apy_floordiv(a, b)
    if q == 0 then return 0 end
    local r = RT.apy_mod(a, b)
    if r == 0 then return 0 end
    return RT.new_tuple_from({ q, r })
end

--- pow(base, exp, mod) -- modular exponentiation by repeated squaring.
---
--- Reducing at every step is the whole point: `pow(2, 4096, m)` is instant
--- this way and would otherwise build a 4096-bit intermediate that the limb
--- multiplier would have to carry through every squaring.
function RT.apy_pow3(base: number, exp: number, mod: number): number
    local mk = RT.kindof(mod)
    if mk == "none" then return RT.apy_pow(base, exp) end
    local e = RT.H(exp)
    if e.k == "big" then
        return RT.err("OverflowError",
                      "pow() exponent beyond 2^53 is not implemented yet")
    end
    if e.k ~= "int" and e.k ~= "bool" then
        return RT.err("TypeError", "pow() arguments must be integers")
    end
    if e.n < 0 then
        return RT.err("ValueError",
                      "pow() 2nd argument cannot be negative when 3rd "
                      .. "argument specified")
    end
    local zero = RT.box_int(0)
    local iszero = RT.apy_eq(mod, zero)
    local _, t = RT.apy_truth(iszero)
    if t ~= 0 then
        return RT.err("ValueError", "pow() 3rd argument cannot be 0")
    end

    local result = RT.box_int(1)
    local b = RT.apy_mod(base, mod)
    if b == 0 then return 0 end
    local n = e.n
    while n > 0 do
        if n % 2 == 1 then
            result = RT.apy_mod(RT.apy_mul(result, b), mod)
            if result == 0 then return 0 end
        end
        b = RT.apy_mod(RT.apy_mul(b, b), mod)
        if b == 0 then return 0 end
        n = math.floor(n / 2)
    end
    return result
end

-- ── miscellaneous ───────────────────────────────────────────────────────────

--- ascii(): repr() with every non-ASCII byte escaped. Since strings here are
--- bytes, that is repr with \xNN for anything above 126.
function RT.apy_ascii(v: number): number
    local r = RT.apy_repr(v)
    if r == 0 then return 0 end
    local s = RT.as_str(r)
    local out = {}
    for i = 1, #s do
        local b = string.byte(s, i)
        if b > 126 then
            table.insert(out, string.format("\\x%02x", b))
        else
            table.insert(out, string.sub(s, i, i))
        end
    end
    return RT.box_str(table.concat(out))
end

--- id(): the handle. Stable for the life of the value and unique among live
--- values, which is everything `id` promises.
function RT.apy_id(v: number): number
    return RT.box_int(v)
end

--- bytes.hex(sep) / float.hex(). Two unrelated methods sharing a symbol,
--- split on the receiver as the C does.
function RT.apy_hex_of(x: number, sep: number): number
    local k = RT.kindof(x)
    if k == "float" then
        return RT.err("NotImplementedError",
                      "float.hex() needs an exact binary-exponent formatter")
    end
    if k ~= "bytes" and k ~= "str" then
        return RT.err("TypeError", "'" .. k .. "' object has no hex()")
    end
    local s = RT.as_str(x)
    local sepstr = ""
    if sep ~= nil and sep ~= 0 and RT.kindof(sep) == "str" then
        sepstr = RT.as_str(sep)
    end
    local out = {}
    for i = 1, #s do
        table.insert(out, string.format("%02x", string.byte(s, i)))
    end
    return RT.box_str(table.concat(out, sepstr))
end

function RT.apy_float_fromhex(s: number): number
    return RT.err("NotImplementedError",
                  "float.fromhex() needs an exact binary-exponent parser")
end

-- ── slice objects ───────────────────────────────────────────────────────────
-- A slice reaches a user class as an OBJECT, because `c[1:2]` is
-- `c.__getitem__(slice(1, 2, None))` and the class decides what that means.

function RT.apy_slice_new(start: number, stop: number, step: number): number
    local made = RT.apy_list_new(0, 0)
    local o = RT.H(made)
    o.k = "slice"
    o.items = nil
    o.start = start
    o.stop = stop
    o.step = step
    return made
end

--- slice.indices(len) -> (start, stop, step), normalised the way a sequence
--- would apply them.
function RT.apy_slice_indices(sl: number, len: number): number
    local o = RT.H(sl)
    if o.k ~= "slice" then
        return RT.err("TypeError", "'" .. o.k .. "' object is not a slice")
    end
    local n = RT.H(len).n
    local step = if RT.kindof(o.step) == "none" then 1 else RT.H(o.step).n
    if step == 0 then
        return RT.err("ValueError", "slice step cannot be zero")
    end
    local i, j
    if step > 0 then
        i = if RT.kindof(o.start) == "none" then 0 else RT.H(o.start).n
        j = if RT.kindof(o.stop) == "none" then n else RT.H(o.stop).n
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
    else
        i = if RT.kindof(o.start) == "none" then n - 1 else RT.H(o.start).n
        j = if RT.kindof(o.stop) == "none" then -1 else RT.H(o.stop).n
        if i < 0 then
            i += n
            if i < 0 then i = -1 end
        elseif i >= n then
            i = n - 1
        end
        if RT.kindof(o.stop) ~= "none" then
            if j < 0 then
                j += n
                if j < 0 then j = -1 end
            elseif j >= n then
                j = n - 1
            end
        end
    end
    return RT.new_tuple_from({ RT.box_int(i), RT.box_int(j), RT.box_int(step) })
end
