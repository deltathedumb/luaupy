-- Builtin functions, and the list/dict methods that live beside them.
--
-- Mostly independent of each other, which is what makes this group the easy
-- part of the runtime. The exceptions are noted where they occur.

--- Every element of an iterable, as a Luau array.
---
--- Goes through the ITERATOR protocol rather than reading `items` directly, so
--- a range, a dict, a string and a lazy cursor all work. Returns nil with an
--- error set on failure -- callers must check, because 0 is a valid handle
--- position in the array they would otherwise build.
local function collect(v: number): { number }?
    local it = RT.apy_getiter(v)
    if it == 0 then return nil end
    local out = {}
    while true do
        local e = RT.apy_step(it)
        if e == 0 then return nil end
        if e == RT.apy_stop() then break end
        table.insert(out, e)
    end
    return out
end

local function new_list(items: { number }): number
    local L = RT.apy_list_new(0, 0)
    for _, e in ipairs(items) do RT.apy_seq_push(L, e) end
    return L
end

local function new_tuple(items: { number }): number
    local T = RT.apy_tuple_new(0, 0)
    for _, e in ipairs(items) do RT.apy_seq_push(T, e) end
    return T
end

-- ── range ───────────────────────────────────────────────────────────────────

function RT.apy_range(sh: number, sl: number, oh: number, ol: number,
                      ph: number, pl: number): number
    local start = RT.to_number(sh, sl, true)
    local stop = RT.to_number(oh, ol, true)
    local step = RT.to_number(ph, pl, true)
    if step == 0 then
        return RT.err("ValueError", "range() arg 3 must not be zero")
    end
    return RT.range_new(start, stop, step)
end

-- ── ordering and reduction ──────────────────────────────────────────────────

--- sorted(): STABLE, because Python guarantees it.
---
--- table.sort is not stable and Luau's is a quicksort, so equal elements would
--- be reordered -- invisible on numbers and very visible on tuples sorted by
--- their first field. Insertion sort is what the C uses here for the same
--- reason, and the sizes a compiled program sorts do not make the difference
--- matter.
function RT.apy_sorted(seq: number): number
    local xs = collect(seq)
    if xs == nil then return 0 end
    for i = 2, #xs do
        local cur = xs[i]
        local j = i - 1
        while j >= 1 do
            local c = RT.cmp_values(xs[j], cur)
            if c == nil then
                return RT.err("TypeError",
                              "'<' not supported between these instances")
            end
            if c <= 0 then break end
            xs[j + 1] = xs[j]
            j -= 1
        end
        xs[j + 1] = cur
    end
    return new_list(xs)
end

local function extreme(seq: number, want: number, name: string): number
    local xs = collect(seq)
    if xs == nil then return 0 end
    if #xs == 0 then
        return RT.err("ValueError", name .. "() arg is an empty sequence")
    end
    local best = xs[1]
    for i = 2, #xs do
        local c = RT.cmp_values(xs[i], best)
        if c == nil then
            return RT.err("TypeError",
                          "'<' not supported between these instances")
        end
        -- Strict comparison, so the FIRST of several equal extremes wins --
        -- which is what Python documents and is observable when the elements
        -- are distinguishable but compare equal.
        if c * want > 0 then best = xs[i] end
    end
    return best
end

function RT.apy_min(seq) return extreme(seq, -1, "min") end
function RT.apy_max(seq) return extreme(seq, 1, "max") end

--- sum() starts at the integer 0, so summing an empty sequence is 0 and
--- summing floats promotes on the first addition.
function RT.apy_sum(seq: number): number
    local xs = collect(seq)
    if xs == nil then return 0 end
    local acc = RT.box_int(0)
    for _, e in ipairs(xs) do
        acc = RT.apy_add(acc, e)
        if acc == 0 then return 0 end
    end
    return acc
end

-- ── cursors ─────────────────────────────────────────────────────────────────

function RT.apy_reversed(seq: number): number
    local xs = collect(seq)
    if xs == nil then return 0 end
    local i = #xs + 1
    return RT.lazy_iter(function()
        i -= 1
        if i < 1 then return nil end
        return xs[i]
    end)
end

--- enumerate(seq, start) -> (index, value) pairs, lazily.
function RT.apy_enumerate(seq: number, h: number, l: number): number
    local src = RT.apy_getiter(seq)
    if src == 0 then return 0 end
    local i = RT.to_number(h, l, true)
    return RT.lazy_iter(function()
        local e = RT.apy_step(src)
        if e == 0 or e == RT.apy_stop() then return nil end
        local pair = new_tuple({ RT.box_int(i), e })
        i += 1
        return pair
    end)
end

--- zip() stops at the SHORTER input, and does not consume from the longer one
--- once the short one is done.
function RT.apy_zip2(a: number, b: number): number
    local ia = RT.apy_getiter(a)
    if ia == 0 then return 0 end
    local ib = RT.apy_getiter(b)
    if ib == 0 then return 0 end
    return RT.lazy_iter(function()
        local x = RT.apy_step(ia)
        if x == 0 or x == RT.apy_stop() then return nil end
        local y = RT.apy_step(ib)
        if y == 0 or y == RT.apy_stop() then return nil end
        return new_tuple({ x, y })
    end)
end

-- ── numbers ─────────────────────────────────────────────────────────────────

function RT.apy_abs(v: number): number
    local k = RT.kindof(v)
    if k == "big" then
        local o = RT.H(v)
        if o.sign < 0 then return RT.apy_neg(v) end
        return v
    end
    if k ~= "int" and k ~= "float" and k ~= "bool" then
        return RT.err("TypeError",
                      "bad operand type for abs(): '" .. k .. "'")
    end
    local n = RT.H(v).n
    if n >= 0 then return v end
    return if k == "float" then RT.box_float(-n) else RT.box_int(-n)
end

--- round() with no digits: BANKER'S ROUNDING, to the nearest even on a tie.
--- round(0.5) is 0 and round(1.5) is 2 in Python, where C's round() answers 1
--- and 2. Getting this wrong is invisible until a total is off by one.
function RT.apy_round(v: number): number
    local k = RT.kindof(v)
    if k == "int" or k == "big" or k == "bool" then
        return if k == "bool" then RT.box_int(RT.H(v).n) else v
    end
    if k ~= "float" then
        return RT.err("TypeError",
                      "type " .. k .. " doesn't define __round__ method")
    end
    local x = RT.H(v).n
    local down = math.floor(x)
    local frac = x - down
    local r
    if frac > 0.5 then
        r = down + 1
    elseif frac < 0.5 then
        r = down
    else
        r = if down % 2 == 0 then down else down + 1
    end
    return RT.box_int(r)
end

function RT.apy_isinstance(v: number, ty: number): number
    local k = RT.kindof(v)
    local want
    if RT.kindof(ty) == "str" then
        want = RT.as_str(ty)
    elseif RT.kindof(ty) == "type" then
        -- A user class: walk the instance's own class chain.
        if k ~= "inst" then return RT.box_bool(false) end
        local cls = RT.H(v).cls
        return RT.box_bool(cls == ty)
    elseif RT.kindof(ty) == "tuple" then
        for _, t in ipairs(RT.items(ty)) do
            local got = RT.apy_isinstance(v, t)
            if got == 0 then return 0 end
            local _, truth = RT.apy_truth(got)
            if truth ~= 0 then return RT.box_bool(true) end
        end
        return RT.box_bool(false)
    else
        return RT.err("TypeError",
                      "isinstance() arg 2 must be a type or tuple of types")
    end
    -- `bool` is a subclass of `int` in Python, so isinstance(True, int) is
    -- True. `big` and `int` are one type from the program's point of view.
    if want == "int" then return RT.box_bool(k == "int" or k == "big" or k == "bool") end
    if want == "float" then return RT.box_bool(k == "float") end
    if want == "bool" then return RT.box_bool(k == "bool") end
    if want == "str" then return RT.box_bool(k == "str") end
    if want == "bytes" then return RT.box_bool(k == "bytes") end
    if want == "list" then return RT.box_bool(k == "list") end
    if want == "tuple" then return RT.box_bool(k == "tuple") end
    if want == "dict" then return RT.box_bool(k == "dict") end
    if want == "set" then return RT.box_bool(k == "set") end
    if want == "frozenset" then return RT.box_bool(k == "frozenset") end
    if want == "range" then return RT.box_bool(k == "range") end
    return RT.box_bool(false)
end

-- ── slicing ─────────────────────────────────────────────────────────────────

--- apy_slice(seq, start, stop, step, has_start, has_stop)
---
--- The two `has_` flags are not redundant with a sentinel value: `xs[:5]` and
--- `xs[0:5]` differ once the step is negative, where an absent start means the
--- END of the sequence rather than index 0.
function RT.apy_slice(seq: number,
                      ah: number, al: number, bh: number, bl: number,
                      ch: number, cl: number, dh: number, dl: number,
                      eh: number, el: number): number
    local start = RT.to_number(ah, al, true)
    local stop = RT.to_number(bh, bl, true)
    local step = RT.to_number(ch, cl, true)
    local has_start = RT.to_number(dh, dl, true) ~= 0
    local has_stop = RT.to_number(eh, el, true) ~= 0
    if step == 0 then
        return RT.err("ValueError", "slice step cannot be zero")
    end

    local o = RT.H(seq)
    local k = o.k
    local n
    if k == "str" or k == "bytes" then
        n = #o.s
    elseif o.items ~= nil then
        n = #o.items
    elseif k == "range" then
        n = RT.range_len(o)
    else
        return RT.err("TypeError",
                      "'" .. k .. "' object is not subscriptable")
    end

    -- Python's slice normalisation, in the order CPython does it.
    local i, j
    if step > 0 then
        i = if has_start then start else 0
        j = if has_stop then stop else n
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
        i = if has_start then start else n - 1
        j = if has_stop then stop else -1
        if i < 0 then
            i += n
            if i < 0 then i = -1 end
        elseif i >= n then
            i = n - 1
        end
        if has_stop then
            if j < 0 then
                j += n
                if j < 0 then j = -1 end
            elseif j >= n then
                j = n - 1
            end
        end
    end

    if k == "str" or k == "bytes" then
        local out = {}
        local p = i
        while (step > 0 and p < j) or (step < 0 and p > j) do
            table.insert(out, string.sub(o.s, p + 1, p + 1))
            p += step
        end
        local made = RT.box_str(table.concat(out))
        if k == "bytes" then RT.H(made).k = "bytes" end
        return made
    end

    local src = if k == "range" then nil else o.items
    local out = {}
    local p = i
    while (step > 0 and p < j) or (step < 0 and p > j) do
        if src ~= nil then
            table.insert(out, src[p + 1])
        else
            table.insert(out, RT.box_int(o.start + p * o.step))
        end
        p += step
    end
    if k == "tuple" then return new_tuple(out) end
    return new_list(out)
end

-- ── list and dict methods ───────────────────────────────────────────────────

--- pop() reaches here for lists AND dicts: one method name, and the frontend
--- cannot know which receiver it has until run time. The dict case takes a
--- KEY where the list case takes an index, so it is split off first.
function RT.apy_list_pop(seq: number, index: number, h: number,
                         l: number): number
    local given = RT.to_number(h, l, true) ~= 0
    local o = RT.H(seq)
    if o.k == "dict" then
        local hk = RT.apy_hash_key(index)
        local got = o.vals[hk]
        if got == nil then
            return RT.err("KeyError", RT.as_str(RT.apy_repr(index)))
        end
        o.vals[hk] = nil
        for idx, key in ipairs(o.keys) do
            if RT.apy_hash_key(key) == hk then
                table.remove(o.keys, idx)
                break
            end
        end
        return got
    end
    if o.items == nil then
        return RT.err("TypeError",
                      "'" .. o.k .. "' object has no attribute 'pop'")
    end
    local n = #o.items
    if n == 0 then
        return RT.err("IndexError", "pop from empty list")
    end
    local i = if given then RT.H(index).n else -1
    if i < 0 then i += n end
    if i < 0 or i >= n then
        return RT.err("IndexError", "pop index out of range")
    end
    return table.remove(o.items, i + 1)
end

function RT.apy_index_of(seq: number, item: number): number
    local xs = collect(seq)
    if xs == nil then return 0 end
    for i, e in ipairs(xs) do
        local got = RT.apy_eq(e, item)
        if got == 0 then return 0 end
        local _, t = RT.apy_truth(got)
        if t ~= 0 then return RT.box_int(i - 1) end
    end
    return RT.err("ValueError", RT.as_str(RT.apy_repr(item))
                  .. " is not in list")
end

function RT.apy_count_of(seq: number, item: number): number
    local xs = collect(seq)
    if xs == nil then return 0 end
    local n = 0
    for _, e in ipairs(xs) do
        local got = RT.apy_eq(e, item)
        if got == 0 then return 0 end
        local _, t = RT.apy_truth(got)
        if t ~= 0 then n += 1 end
    end
    return RT.box_int(n)
end

--- remove() drops the FIRST match only, and raises when there is none.
function RT.apy_list_remove(seq: number, item: number): number
    local o = RT.H(seq)
    if o.items == nil then
        return RT.err("TypeError",
                      "'" .. o.k .. "' object has no attribute 'remove'")
    end
    for i, e in ipairs(o.items) do
        local got = RT.apy_eq(e, item)
        if got == 0 then return 0 end
        local _, t = RT.apy_truth(got)
        if t ~= 0 then
            table.remove(o.items, i)
            return RT.apy_none()
        end
    end
    return RT.err("ValueError", "list.remove(x): x not in list")
end

--- d.keys() / .values() / .items(), by index: 0, 1, 2.
---
--- The C answers a live VIEW; this answers a list. The difference shows only
--- when the dict is mutated while the view is held, and a live view needs a
--- kind of its own that the rest of the runtime would have to understand.
--- Recorded rather than hidden: `ks = d.keys(); d["new"] = 1; len(ks)` is 1
--- here and 2 in Python.
function RT.apy_dict_parts(d: number, h: number, l: number): number
    local which = RT.to_number(h, l, true)
    local o = RT.H(d)
    if o.k ~= "dict" then
        return RT.err("TypeError",
                      "'" .. o.k .. "' object has no keys()/values()/items()")
    end
    local out = {}
    for _, key in ipairs(o.keys) do
        local val = o.vals[RT.apy_hash_key(key)]
        if which == 0 then
            table.insert(out, key)
        elseif which == 1 then
            table.insert(out, val)
        else
            table.insert(out, new_tuple({ key, val }))
        end
    end
    return new_list(out)
end

function RT.apy_dict_get_or(d: number, key: number, fallback: number): number
    local o = RT.H(d)
    if o.k ~= "dict" then
        return RT.err("TypeError", "'" .. o.k .. "' object has no get()")
    end
    local got = o.vals[RT.apy_hash_key(key)]
    return if got == nil then fallback else got
end

--- pop(key, default): the dict form only, and it does NOT raise when the key
--- is missing -- that is what separates it from apy_list_pop's dict branch.
function RT.apy_pop_or(d: number, key: number, fallback: number): number
    local o = RT.H(d)
    if o.k ~= "dict" then
        return RT.err("TypeError",
                      "pop() takes at most 1 argument for '" .. o.k .. "'")
    end
    local hk = RT.apy_hash_key(key)
    local got = o.vals[hk]
    if got == nil then return fallback end
    o.vals[hk] = nil
    for idx, k in ipairs(o.keys) do
        if RT.apy_hash_key(k) == hk then
            table.remove(o.keys, idx)
            break
        end
    end
    return got
end

--- popitem() removes and returns the LAST pair, which is what makes a dict
--- usable as a stack. It was arbitrary before 3.7 and is ordered now.
function RT.apy_dict_popitem(d: number): number
    local o = RT.H(d)
    if o.k ~= "dict" then
        return RT.err("TypeError", "'" .. o.k .. "' object has no popitem()")
    end
    if #o.keys == 0 then
        return RT.err("KeyError", "popitem(): dictionary is empty")
    end
    local key = table.remove(o.keys)
    local hk = RT.apy_hash_key(key)
    local val = o.vals[hk]
    o.vals[hk] = nil
    return new_tuple({ key, val })
end

RT.collect_items = collect
RT.new_list_from = new_list
RT.new_tuple_from = new_tuple
