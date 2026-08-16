--!native
--!optimize 2
-- luaupy runtime. Generated -- edit luaupy/runtime.py.

local RT = {}

-- ── flat memory ─────────────────────────────────────────────────────────────
-- The IR addresses memory as bytes, so the program gets one `buffer` and every
-- load and store is an offset into it. A buffer cannot grow, so the size is
-- fixed at startup: growing would mean replacing the object, and the emitted
-- module holds its own reference to it, which would silently go stale.

local HEAP_BASE = 4096
local mem: buffer? = nil
local brk = HEAP_BASE
local limit = 0

function RT.heap(size: number): buffer
    if mem == nil then
        mem = buffer.create(size)
        limit = size
    end
    return mem :: buffer
end

--- Reserve everything below `addr`, so `alloca` never hands it out.
function RT.reserve(addr: number)
    if addr > brk then brk = addr end
end

function RT.trap(message: string): never
    error("luaupy: " .. message, 0)
end

--- Bump allocation. `alloca` in the IR is frame storage freed on return, but
--- nothing here reclaims it: a returning frame would have to know how much it
--- took, and the IR does not say. Programs that alloca in a loop will exhaust
--- the heap, which is a real limitation and reported as one.
function RT.alloca(size: number): number
    local addr = brk
    brk = (brk + size + 7) // 8 * 8
    if brk > limit then
        RT.trap("out of memory: alloca(" .. size .. ") past the " .. limit ..
                "-byte heap; raise it with --luau-heap")
    end
    return addr
end

function RT.blit(b: buffer, addr: number, s: string)
    buffer.writestring(b, addr, s)
end

-- Byte-width accessors. Named so the emitter builds the name from the IR type
-- rather than matching on it.
function RT.readu8(b, a) return buffer.readu8(b, a) end
function RT.readu16(b, a) return buffer.readu16(b, a) end
function RT.readu32(b, a) return buffer.readu32(b, a) end
function RT.readf32(b, a) return buffer.readf32(b, a) end
function RT.readf64(b, a) return buffer.readf64(b, a) end
function RT.readptr(b, a) return buffer.readu32(b, a) end
function RT.writeu8(b, a, v) buffer.writeu8(b, a, v) end
function RT.writeu16(b, a, v) buffer.writeu16(b, a, v) end
function RT.writeu32(b, a, v) buffer.writeu32(b, a, v) end
function RT.writef32(b, a, v) buffer.writef32(b, a, v) end
function RT.writef64(b, a, v) buffer.writef64(b, a, v) end

--- A pointer occupies 8 bytes so the layout a frontend computed still fits,
--- but only the low word is ever non-zero -- addresses are buffer offsets.
function RT.writeptr(b, a, v)
    buffer.writeu32(b, a, v)
    buffer.writeu32(b, a + 4, 0)
end

function RT.read64(b, a): (number, number)
    return buffer.readu32(b, a + 4), buffer.readu32(b, a)
end

function RT.write64(b, a, h: number, l: number)
    buffer.writeu32(b, a, l)
    buffer.writeu32(b, a + 4, h)
end

-- ── 64-bit integers ─────────────────────────────────────────────────────────
-- A double holds integers exactly only to 2^53, so a 64-bit value is two
-- 32-bit halves, each an exact integer in [0, 2^32). Every function here takes
-- and returns them high-first.

local B32 = 4294967296

function RT.add64(ah, al, bh, bl): (number, number)
    local l = al + bl
    local carry = 0
    if l >= B32 then l -= B32; carry = 1 end
    return (ah + bh + carry) % B32, l
end

function RT.sub64(ah, al, bh, bl): (number, number)
    local l = al - bl
    local borrow = 0
    if l < 0 then l += B32; borrow = 1 end
    return (ah - bh - borrow) % B32, l
end

function RT.neg64(h, l): (number, number)
    return RT.sub64(0, 0, h, l)
end

function RT.not64(h, l): (number, number)
    return 4294967295 - h, 4294967295 - l
end

function RT.and64(ah, al, bh, bl) return bit32.band(ah, bh), bit32.band(al, bl) end
function RT.or64(ah, al, bh, bl)  return bit32.bor(ah, bh),  bit32.bor(al, bl)  end
function RT.xor64(ah, al, bh, bl) return bit32.bxor(ah, bh), bit32.bxor(al, bl) end

--- 32x32 -> low 32, exactly. A direct `a * b` reaches 2^64 and loses precision
--- above 2^53, so the operands are split into 16-bit halves whose partial
--- products each stay well inside what a double represents exactly.
function RT.mul32(a: number, b: number): number
    local ah, al = a // 65536, a % 65536
    local bh, bl = b // 65536, b % 65536
    return (al * bl + ((ah * bl + al * bh) % 65536) * 65536) % B32
end

function RT.mul64(ah, al, bh, bl): (number, number)
    local lo = RT.mul32(al, bl)
    -- The high half takes the carry out of the low product plus the two cross
    -- terms; the ah*bh term overflows 64 bits entirely and is dropped, which
    -- is what wrapping multiplication means.
    local a0, a1 = al % 65536, al // 65536
    local b0, b1 = bl % 65536, bl // 65536
    local carry = ((a0 * b0) // 65536 + (a1 * b0 + a0 * b1) % 65536 * 1) // 65536
    carry = ((a1 * b0 + a0 * b1) + (a0 * b0) // 65536) // 65536 + a1 * b1
    local hi = (RT.mul32(ah, bl) + RT.mul32(al, bh) + carry) % B32
    return hi, lo
end

function RT.eq64(ah, al, bh, bl): boolean
    return ah == bh and al == bl
end

--- Ordered comparison. The high halves decide unless they are equal, and the
--- high half is the only one whose signedness matters -- the low half is
--- always an unsigned magnitude.
function RT.cmp64(ah, al, bh, bl, op: string, signed: boolean): boolean
    local x, y = ah, bh
    if signed then
        if x >= 2147483648 then x -= B32 end
        if y >= 2147483648 then y -= B32 end
    end
    if x ~= y then
        if op == "<" or op == "<=" then return x < y end
        return x > y
    end
    if al == bl then return op == "<=" or op == ">=" end
    if op == "<" or op == "<=" then return al < bl end
    return al > bl
end

function RT.shl64(ah, al, sh, sl): (number, number)
    local n = sl % 64
    if n == 0 then return ah, al end
    if n >= 32 then
        return bit32.lshift(al, n - 32) % B32, 0
    end
    return (bit32.lshift(ah, n) + bit32.rshift(al, 32 - n)) % B32,
           bit32.lshift(al, n) % B32
end

function RT.shr64(ah, al, sh, sl, signed: boolean): (number, number)
    local n = sl % 64
    if n == 0 then return ah, al end
    local fill = 0
    if signed and ah >= 2147483648 then fill = 4294967295 end
    if n >= 32 then
        local h = fill
        local l = if signed then bit32.arshift(ah, n - 32) % B32
                  else bit32.rshift(ah, n - 32)
        return h, l
    end
    local h = if signed then bit32.arshift(ah, n) % B32 else bit32.rshift(ah, n)
    return h, (bit32.rshift(al, n) + bit32.lshift(ah, 32 - n)) % B32
end

--- Unsigned 64-bit division, quotient and remainder together.
---
--- NOT via `to_number`. A double is exact only to 2^53, so converting both
--- operands and dividing loses bits before the division even starts:
--- (2^64-1) / 2 came back as a quotient that multiplies back to 0. The first
--- version of this did exactly that, and a property test comparing q*b + r
--- against a caught it on 1504 of 3000 random inputs.
---
--- The fast path is not an optimisation of the slow one, it is the SAME
--- arithmetic where a double happens to be exact -- both operands under 2^53,
--- which every pointer, length and ordinary Python int satisfies. Everything
--- else takes restoring division, 64 shift-and-subtract steps, which is exact
--- by construction because it never forms a value wider than the register.
function RT.divmod64(ah, al, bh, bl): (number, number, number, number)
    if bh == 0 and bl == 0 then RT.trap("integer division by zero") end

    -- 2^53 = h * 2^32 + l means h < 2^21.
    if ah < 2097152 and bh < 2097152 then
        local a = ah * 4294967296 + al
        local b = bh * 4294967296 + bl
        local q = a // b
        local r = a - q * b
        local qh, ql = RT.from_number(q)
        local rh, rl = RT.from_number(r)
        return qh, ql, rh, rl
    end

    local qh, ql, rh, rl = 0, 0, 0, 0
    for i = 63, 0, -1 do
        -- r <<= 1, then bring down bit i of the dividend. The shift leaves
        -- rl even, so adding the bit cannot carry.
        rh, rl = RT.shl64(rh, rl, 0, 1)
        local b = if i >= 32 then bit32.extract(ah, i - 32, 1)
                  else bit32.extract(al, i, 1)
        rl += b
        if RT.cmp64(rh, rl, bh, bl, ">=", false) then
            rh, rl = RT.sub64(rh, rl, bh, bl)
            if i >= 32 then qh += 2 ^ (i - 32) else ql += 2 ^ i end
        end
    end
    return qh, ql, rh, rl
end

--- Signed division truncates toward zero and the remainder takes the sign of
--- the DIVIDEND, which is what the IR's `rem` specifies and what C does. Lua's
--- `%` floors instead, so neither operator here can be used directly.
local function signed_divmod(ah, al, bh, bl)
    local neg_q, neg_r = false, false
    if ah >= 2147483648 then
        ah, al = RT.neg64(ah, al); neg_q = not neg_q; neg_r = true
    end
    if bh >= 2147483648 then
        bh, bl = RT.neg64(bh, bl); neg_q = not neg_q
    end
    local qh, ql, rh, rl = RT.divmod64(ah, al, bh, bl)
    if neg_q then qh, ql = RT.neg64(qh, ql) end
    if neg_r then rh, rl = RT.neg64(rh, rl) end
    return qh, ql, rh, rl
end

function RT.div64(ah, al, bh, bl, signed: boolean): (number, number)
    if signed then
        local qh, ql = signed_divmod(ah, al, bh, bl)
        return qh, ql
    end
    local qh, ql = RT.divmod64(ah, al, bh, bl)
    return qh, ql
end

function RT.rem64(ah, al, bh, bl, signed: boolean): (number, number)
    if signed then
        local _, _, rh, rl = signed_divmod(ah, al, bh, bl)
        return rh, rl
    end
    local _, _, rh, rl = RT.divmod64(ah, al, bh, bl)
    return rh, rl
end

--- 64-bit to double. Lossy above 2^53 and unavoidably so -- this is what
--- `itof` means, and the loss is the same one the hardware would take.
function RT.to_number(h: number, l: number, signed: boolean?): number
    if signed and h >= 2147483648 then
        return (h - B32) * B32 + l
    end
    return h * B32 + l
end

--- Double to 64-bit halves.
---
--- A negative value is split by magnitude and then negated in INTEGER
--- arithmetic. The obvious `n += 2^64` is wrong: it lands the value above
--- 2^53, where a double no longer represents consecutive integers, so the low
--- bits are gone before the split even happens. `widen(-1705032704)` came back
--- 1024 short that way -- the high half right, the low half quietly rounded.
---
--- Above 2^53 the input has already lost precision and nothing here can
--- recover it; that loss belongs to whoever produced the double.
function RT.from_number(n: number): (number, number)
    if n < 0 then
        local h, l = RT.from_number(-n)
        return RT.neg64(h, l)
    end
    return (n // B32) % B32, n % B32
end

-- ── narrow helpers ──────────────────────────────────────────────────────────

--- Interpret `v` as a signed value `bits` wide. The raw storage is unsigned,
--- so this is where signedness enters for comparison, division and widening.
function RT.sext(v: number, bits: number): number
    local half = 2 ^ (bits - 1)
    if v >= half then return v - half * 2 end
    return v
end

function RT.widen(v: number, bits: number, signed: boolean): (number, number)
    if signed then return RT.from_number(RT.sext(v, bits)) end
    return 0, v
end

--- Truncate toward zero. Luau's `//` floors, which differs for negatives.
function RT.trunc(x: number): number
    if x >= 0 then return math.floor(x) end
    return -math.floor(-x)
end

function RT.fmod(a: number, b: number): number
    return a - RT.trunc(a / b) * b
end

function RT.div32(a, b, bits: number, signed: boolean): number
    if b == 0 then RT.trap("integer division by zero") end
    if signed then
        a, b = RT.sext(a, bits), RT.sext(b, bits)
    end
    return RT.trunc(a / b) % 2 ^ bits
end

function RT.rem32(a, b, bits: number, signed: boolean): number
    if b == 0 then RT.trap("integer remainder by zero") end
    if signed then
        a, b = RT.sext(a, bits), RT.sext(b, bits)
    end
    return (a - RT.trunc(a / b) * b) % 2 ^ bits
end

-- ── float widths and bit patterns ───────────────────────────────────────────
-- One scratch buffer, reused. These are the only way to get at a float's bits
-- in Luau, and creating a buffer per conversion would allocate in the hot path
-- of anything doing float maths.

local scratch = buffer.create(8)

--- Round a double to what an f32 would hold. Luau has no 32-bit float, so an
--- f32 operation computed in a double is too precise until this runs.
function RT.f32(x: number): number
    buffer.writef32(scratch, 0, x)
    return buffer.readf32(scratch, 0)
end

function RT.float_to_bits(x: number, bits: number): (number, number)
    if bits == 32 then
        buffer.writef32(scratch, 0, x)
        return buffer.readu32(scratch, 0)
    end
    buffer.writef64(scratch, 0, x)
    return buffer.readu32(scratch, 4), buffer.readu32(scratch, 0)
end

function RT.bits_to_float(...): number
    local a, b = ...
    if b == nil then
        buffer.writeu32(scratch, 0, a)
        return buffer.readf32(scratch, 0)
    end
    buffer.writeu32(scratch, 4, a)
    buffer.writeu32(scratch, 0, b)
    return buffer.readf64(scratch, 0)
end

function RT.ptr_from64(h: number, l: number): number
    if h ~= 0 then
        RT.trap("pointer " .. h .. ":" .. l .. " does not fit a buffer offset")
    end
    return l
end

-- ── indirect calls ──────────────────────────────────────────────────────────
-- A function pointer is an index into this table, so `call_ptr` is a lookup
-- rather than anything that could reach outside the program.

RT.fn = {}
local fnids: { [any]: number } = {}

function RT.fnid(f): number
    local id = fnids[f]
    if id == nil then
        id = #RT.fn + 1
        RT.fn[id] = f
        fnids[f] = id
    end
    return id
end

-- ── host functions ──────────────────────────────────────────────────────────

local buffered: { string } = {}

function RT.put_int(h: number, l: number)
    table.insert(buffered, tostring(RT.to_number(h, l, true)))
end

function RT.put_float(x: number)
    table.insert(buffered, tostring(x))
end

function RT.put_bool(v: number)
    table.insert(buffered, if v ~= 0 then "True" else "False")
end

function RT.put_none()
    table.insert(buffered, "None")
end

function RT.print_int(h: number, l: number)
    print(RT.to_number(h, l, true))
end

function RT.print_float(x: number) print(x) end

function RT.print_str(addr: number)
    local b = mem :: buffer
    local n = 0
    while buffer.readu8(b, addr + n) ~= 0 do n += 1 end
    print(buffer.readstring(b, addr, n))
end

function RT.putchar(c: number): number
    table.insert(buffered, string.char(c % 256))
    return c
end

-- ── what the object model needs from the machine layer ──────────────────────

--- The heap buffer. The object model reads argument arrays and C strings out
--- of it; it never allocates there, because a Python value is a handle rather
--- than an address.
function RT.mem(): buffer
    return mem :: buffer
end

--- Where `print` goes. A function rather than a direct `print` call so a test
--- can capture output without redefining a global.
function RT.stdout(line: string)
    print(line)
end

--- Output with no newline appended, for `print(..., end="")`. Roblox's `print`
--- always adds one, so a partial line is buffered until something terminates
--- it -- otherwise `print("a", end="")` and `print("b")` land on two lines.
local partial = ""

function RT.stdout_raw(text: string)
    partial ..= text
    local NL = string.char(10)
    local at = string.find(partial, NL, 1, true)
    while at ~= nil do
        print(string.sub(partial, 1, at - 1))
        partial = string.sub(partial, at + 1)
        at = string.find(partial, NL, 1, true)
    end
end

--- Flush whatever `stdout_raw` still holds, so a program ending mid-line
--- still shows it.
function RT.stdout_flush()
    if partial ~= "" then
        print(partial)
        partial = ""
    end
end

-- ── the platform floor ──────────────────────────────────────────────────────
-- Everything a backend must supply that is not IR: a way to emit bytes, a way
-- to stop, and a way to get memory. Three functions, and asmpython's own
-- design document names that number -- an object runtime written in IR still
-- cannot talk to the machine, and this is what it asks through.
--
-- NOTHING HERE KNOWS WHAT A PYTHON VALUE IS. `plat_write` takes bytes. The
-- moment one of these knew what a bool was, every backend would owe the
-- language rather than the machine, and the floor would stop being three
-- functions.

--- `plat_write(fd, buf, n)` -> bytes written, or -1.
---
--- 1 is stdout and 2 is stderr; nothing else need be supported. Not buffered
--- on the caller's behalf -- a runtime that wants buffering builds it in the
--- subset, where every backend gets the same one -- but Roblox's `print`
--- appends a newline of its own, so a write that does not end in one is held
--- until something terminates it. Otherwise a runtime emitting a line in
--- pieces produces one Studio line per piece.
function RT.plat_write(fh: number, fl: number, buf: number,
                       nh: number, nl: number): (number, number)
    local n = RT.to_number(nh, nl, true)
    if n <= 0 then return RT.from_number(0) end
    local fd = RT.to_number(fh, fl, true)
    if fd ~= 1 and fd ~= 2 then return RT.from_number(-1) end
    RT.stdout_raw(buffer.readstring(mem :: buffer, buf, n))
    return RT.from_number(n)
end

--- `plat_exit(code)` -- does not return.
---
--- There is no process to end. Flushing first is not tidiness: a program that
--- exits mid-line would otherwise lose it, and the last line before an exit is
--- usually the one that says why.
function RT.plat_exit(h: number, l: number)
    RT.stdout_flush()
    local code = RT.to_number(h, l, true)
    if code == 0 then
        error("__asmpython_exit_0", 0)
    end
    error("asmpython: exited with status " .. code, 0)
end

--- `plat_heap(n)` -> n more bytes, or null.
---
--- Bump allocation out of the same buffer `alloca` uses, so an IR-written
--- runtime and the emitted code share one address space and a pointer means
--- the same thing to both. Null on exhaustion rather than a trap, because the
--- caller is an allocator and gets to decide what running out means.
function RT.plat_heap(h: number, l: number): number
    local n = RT.to_number(h, l, true)
    if n <= 0 then return 0 end
    local addr = brk
    local next_brk = (brk + n + 7) // 8 * 8
    if next_brk > limit then return 0 end
    brk = next_brk
    return addr
end

--- Compiled functions, by the id `func_addr` handed out. `apy_call` reaches a
--- Python-level call this way: the emitted module registers each function, and
--- the object model only ever holds the id.
function RT.invoke(id: number, args: { number }): number
    local f = RT.fn[id]
    if f == nil then
        return RT.err("TypeError", "call to unregistered function " .. id)
    end
    return f(table.unpack(args))
end

@OBJECTS@


-- ── the surface that is still missing ───────────────────────────────────────
-- Anything not defined above answers with a named error rather than nil, so a
-- program stops at the function it actually needed and says which one. Nil
-- would surface as `attempt to call a nil value` at a line that names nothing.

setmetatable(RT, {
    __index = function(_, key: string)
        return function()
            RT.trap(tostring(key) .. " is not implemented yet")
        end
    end,
})

return RT
