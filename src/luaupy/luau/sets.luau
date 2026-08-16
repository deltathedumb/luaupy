-- set and frozenset.
--
-- Backed by the same `items` array every other sequence uses, plus a `seen`
-- table keyed by the same hash key a dict uses -- so membership is a lookup
-- rather than a scan, and `items` keeps an order that repr can print.
--
-- WHY NOT A BARE LUAU TABLE
-- -------------------------
-- A Luau table keyed by handle would make `{1} == {1.0}` false and `1 in {1.0}`
-- false, because two equal Python values have different handles. Keying by
-- `apy_hash_key` is what makes 1, 1.0 and True one element, as Python requires.
-- The array alongside it exists because a table has no order to print.

local function is_setlike(v: number): boolean
    local k = RT.kindof(v)
    return k == "set" or k == "frozenset"
end

local function set_make(kind: string): number
    local h = RT.apy_set_new(0, 0)
    RT.H(h).k = kind
    return h
end

--- Add without disturbing an existing member. Returns true if it was new.
local function push(s: number, e: number): boolean
    local o = RT.H(s)
    local hk = RT.apy_hash_key(e)
    if o.seen[hk] ~= nil then return false end
    o.seen[hk] = e
    table.insert(o.items, e)
    return true
end

local function has(s: number, e: number): boolean
    return RT.H(s).seen[RT.apy_hash_key(e)] ~= nil
end

--- The elements of any iterable, or nil with an error set.
local function elements(v: number): { number }?
    if is_setlike(v) then return RT.H(v).items end
    return RT.collect_items(v)
end

--- A set reuses the list record and adds `seen`, the membership index. The
--- capacity argument is ignored: a Luau table grows on its own.
function RT.apy_set_new(h: number, l: number): number
    local made = RT.apy_list_new(0, 0)
    local o = RT.H(made)
    o.k = "set"
    o.seen = {}
    return made
end

function RT.apy_frozenset_new(h: number, l: number): number
    local s = RT.apy_set_new(h, l)
    RT.H(s).k = "frozenset"
    return s
end

--- The builder the frontend emits for a `{1, 2}` literal. Duplicates collapse
--- here rather than at the end, so `{1, 1}` is one element and keeps the
--- position of the FIRST occurrence.
function RT.apy_set_push(s: number, e: number): number
    push(s, e)
    return s
end

local function from_iterable(v: number, kind: string): number
    local xs = elements(v)
    if xs == nil then return 0 end
    local out = set_make(kind)
    for _, e in ipairs(xs) do push(out, e) end
    return out
end

function RT.apy_to_set(v) return from_iterable(v, "set") end
function RT.apy_to_frozenset(v) return from_iterable(v, "frozenset") end

local function reject_frozen(s: number, name: string): boolean
    if RT.kindof(s) == "frozenset" then
        RT.err("AttributeError",
               "'frozenset' object has no attribute '" .. name .. "'")
        return true
    end
    return false
end

function RT.apy_set_add(s: number, e: number): number
    if reject_frozen(s, "add") then return 0 end
    push(s, e)
    return RT.apy_none()
end

--- discard() is remove() that does not raise. The ABI has only this one.
function RT.apy_set_discard(s: number, e: number): number
    if reject_frozen(s, "discard") then return 0 end
    local o = RT.H(s)
    local hk = RT.apy_hash_key(e)
    if o.seen[hk] == nil then return RT.apy_none() end
    o.seen[hk] = nil
    for i, x in ipairs(o.items) do
        if RT.apy_hash_key(x) == hk then
            table.remove(o.items, i)
            break
        end
    end
    return RT.apy_none()
end

-- ── algebra ─────────────────────────────────────────────────────────────────
-- The result takes the LEFT operand's kind, so `frozenset | set` is frozen and
-- `set | frozenset` is not. That asymmetry is Python's.

local function binop(a: number, b: number, name: string, keep): number
    if not is_setlike(a) then
        return RT.err("TypeError",
                      "'" .. RT.kindof(a) .. "' object has no " .. name .. "()")
    end
    local other = elements(b)
    if other == nil then return 0 end
    local rhs = set_make("set")
    for _, e in ipairs(other) do push(rhs, e) end

    local out = set_make(RT.kindof(a))
    for _, e in ipairs(RT.H(a).items) do
        if keep(true, has(rhs, e)) then push(out, e) end
    end
    for _, e in ipairs(RT.H(rhs).items) do
        if keep(false, has(a, e)) then push(out, e) end
    end
    return out
end

--- keep(in_left, in_other) decides membership. Written as a predicate so the
--- four operations differ by one line rather than by four near-copies.
function RT.apy_set_union(a, b)
    return binop(a, b, "union", function(left, other) return true end)
end

function RT.apy_set_intersection(a, b)
    return binop(a, b, "intersection", function(left, other)
        return left and other
    end)
end

function RT.apy_set_difference(a, b)
    return binop(a, b, "difference", function(left, other)
        return left and not other
    end)
end

function RT.apy_set_symdiff(a, b)
    return binop(a, b, "symmetric_difference", function(left, other)
        return not other
    end)
end

-- ── predicates ──────────────────────────────────────────────────────────────

local function pair(a: number, b: number, name: string): (any, any)
    if not is_setlike(a) then
        RT.err("TypeError",
               "'" .. RT.kindof(a) .. "' object has no " .. name .. "()")
        return nil, nil
    end
    local other = elements(b)
    if other == nil then return nil, nil end
    local rhs = set_make("set")
    for _, e in ipairs(other) do push(rhs, e) end
    return RT.H(a).items, rhs
end

function RT.apy_set_issubset(a: number, b: number): number
    local mine, rhs = pair(a, b, "issubset")
    if mine == nil then return 0 end
    for _, e in ipairs(mine) do
        if not has(rhs, e) then return RT.box_bool(false) end
    end
    return RT.box_bool(true)
end

function RT.apy_set_issuperset(a: number, b: number): number
    local mine, rhs = pair(a, b, "issuperset")
    if mine == nil then return 0 end
    for _, e in ipairs(RT.H(rhs).items) do
        if not has(a, e) then return RT.box_bool(false) end
    end
    return RT.box_bool(true)
end

function RT.apy_set_isdisjoint(a: number, b: number): number
    local mine, rhs = pair(a, b, "isdisjoint")
    if mine == nil then return 0 end
    for _, e in ipairs(mine) do
        if has(rhs, e) then return RT.box_bool(false) end
    end
    return RT.box_bool(true)
end

-- ── shared mutators ─────────────────────────────────────────────────────────
-- These three are not set-only: `update`, `clear` and `copy` are dict methods
-- too, and the frontend emits one symbol for each name.

function RT.apy_update(target: number, src: number): number
    local o = RT.H(target)
    if o.k == "dict" then
        local so = RT.H(src)
        if so.k ~= "dict" then
            return RT.err("TypeError",
                          "'" .. so.k .. "' object is not a mapping")
        end
        for _, key in ipairs(so.keys) do
            RT.apy_dict_set(target, key, so.vals[RT.apy_hash_key(key)])
        end
        return RT.apy_none()
    end
    if o.k == "set" then
        local xs = elements(src)
        if xs == nil then return 0 end
        for _, e in ipairs(xs) do push(target, e) end
        return RT.apy_none()
    end
    if o.k == "list" then
        local xs = elements(src)
        if xs == nil then return 0 end
        for _, e in ipairs(xs) do table.insert(o.items, e) end
        return RT.apy_none()
    end
    return RT.err("AttributeError",
                  "'" .. o.k .. "' object has no attribute 'update'")
end

function RT.apy_clear(target: number): number
    local o = RT.H(target)
    if o.k == "dict" then
        o.keys = {}
        o.vals = {}
        return RT.apy_none()
    end
    if o.k == "set" then
        o.items = {}
        o.seen = {}
        return RT.apy_none()
    end
    if o.k == "list" then
        o.items = {}
        return RT.apy_none()
    end
    return RT.err("AttributeError",
                  "'" .. o.k .. "' object has no attribute 'clear'")
end

--- copy() is SHALLOW: the new container holds the same element handles, so
--- mutating an element through either name is visible through both.
function RT.apy_copy(v: number): number
    local o = RT.H(v)
    if o.k == "dict" then
        local out = RT.apy_dict_new(0, 0)
        for _, key in ipairs(o.keys) do
            RT.apy_dict_set(out, key, o.vals[RT.apy_hash_key(key)])
        end
        return out
    end
    if o.k == "set" or o.k == "frozenset" then
        local out = set_make(o.k)
        for _, e in ipairs(o.items) do push(out, e) end
        return out
    end
    if o.k == "list" then
        return RT.new_list_from(o.items)
    end
    if o.k == "tuple" then
        return RT.new_tuple_from(o.items)
    end
    return RT.err("AttributeError",
                  "'" .. o.k .. "' object has no attribute 'copy'")
end
