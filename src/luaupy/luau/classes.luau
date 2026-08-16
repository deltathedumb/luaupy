-- Classes, descriptors, dict views, pattern matching, and the small helpers
-- the frontend emits around them.

local function new_type(name: string): number
    return RT.apy_type_new(RT.box_str(name), 0)
end

-- ── the root types ──────────────────────────────────────────────────────────
-- `object` and `type` are singletons: `type(x) is type(y)` has to hold, so a
-- fresh one per call would answer False.

local OBJECT_CLS = 0
local TYPE_CLS = 0

--- One type object per builtin type name, so `type(1) is type(2)` holds.
local builtin_types: { [string]: number } = {}

function RT.apy_object_class(): number
    if OBJECT_CLS == 0 then OBJECT_CLS = new_type("object") end
    return OBJECT_CLS
end

function RT.apy_type_class(): number
    if TYPE_CLS == 0 then TYPE_CLS = new_type("type") end
    return TYPE_CLS
end

--- type(x) -- the CLASS of a value, not its name.
function RT.apy_type_object(v: number): number
    local o = RT.H(v)
    if o.k == "inst" then return o.cls end
    if o.k == "type" then return RT.apy_type_class() end
    -- A builtin gets a type object made on demand and cached by name, so
    -- `type(1) is type(2)` holds.
    --
    -- The cache is a module local and NOT a field on RT. RT carries a metatable
    -- answering every unknown key with a not-implemented function, so
    -- `RT.cache = RT.cache or {}` never initialises anything: the lookup
    -- returns a function, which is truthy, and the next line indexes it. Any
    -- feature-detection written against RT has the same problem.
    local name = RT.as_str(RT.apy_type_name(v))
    local cached = builtin_types[name]
    if cached == nil then
        cached = new_type(name)
        builtin_types[name] = cached
    end
    return cached
end

--- Tag a class as standing in for a builtin. The frontend emits this so that
--- `class MyList(list)` knows which builtin it is extending.
function RT.apy_type_builtin(cls: number, h: number, l: number): number
    RT.H(cls).builtin = RT.to_number(h, l, true)
    return cls
end

-- ── class construction ──────────────────────────────────────────────────────

--- The namespace a class body executes into. A plain dict; a metaclass with
--- __prepare__ could answer something else, and none here does.
function RT.apy_prepare(meta: number, name: number, bases: number): number
    return RT.apy_dict_new(0, 0)
end

--- Which metaclass to use. `type` unless a base names another, which is the
--- rule that makes a class with an enum base build as an enum.
function RT.apy_meta_for(bases: number, ns: number): number
    if bases ~= 0 and RT.kindof(bases) == "tuple" then
        for _, b in ipairs(RT.items(bases)) do
            if RT.kindof(b) == "type" and RT.H(b).meta ~= nil then
                return RT.H(b).meta
            end
        end
    end
    return RT.apy_type_class()
end

--- PEP 560: a base that is not a class gets to say what it stands for.
--- Nothing here produces one, so the bases pass through unchanged.
function RT.apy_mro_entries(bases: number, ns: number): number
    return bases
end

function RT.apy_type_make(meta: number, name: number, bases: number): number
    local cls = RT.apy_type_new(name, bases)
    RT.H(cls).meta = meta
    return cls
end

--- Build a class from its executed namespace.
---
--- Method resolution is C3 in CPython; this is depth-first left-to-right,
--- which agrees for every hierarchy without diamonds and differs inside one.
--- Recorded rather than silently approximated -- a wrong MRO picks the wrong
--- override, and the symptom is a method that is never called.
function RT.apy_class_build(meta: number, name: number, bases: number,
                            ns: number): number
    return RT.apy_class_build_kw(meta, name, bases, ns, 0)
end

function RT.apy_class_build_kw(meta: number, name: number, bases: number,
                               ns: number, kw: number): number
    local cls = RT.apy_type_make(meta, name, bases)
    local rec = RT.H(cls)
    rec.bases = bases
    if ns ~= 0 and RT.kindof(ns) == "dict" then
        local nso = RT.H(ns)
        for _, key in ipairs(nso.keys) do
            if RT.kindof(key) == "str" then
                rec.methods[RT.as_str(key)] = nso.vals[RT.apy_hash_key(key)]
            end
        end
    end
    RT.apy_set_names(cls)
    RT.apy_init_subclass(cls, bases)
    return cls
end

--- Look a name up through the class and then its bases, depth first.
function RT.class_find(cls: number, name: string): number?
    local rec = RT.H(cls)
    local got = rec.methods[name]
    if got ~= nil then return got end
    local bases = rec.bases
    if bases ~= 0 and bases ~= nil and RT.kindof(bases) == "tuple" then
        for _, b in ipairs(RT.items(bases)) do
            if RT.kindof(b) == "type" then
                local up = RT.class_find(b, name)
                if up ~= nil then return up end
            end
        end
    end
    return nil
end

--- __init_subclass__ on a base, called when a subclass is created. Nothing
--- here defines one, so this finds nothing and returns; it exists so the
--- frontend's emitted call resolves.
function RT.apy_init_subclass(cls: number, bases: number): number
    return RT.apy_none()
end

function RT.apy_exc_register(name: number, base: number): number
    -- Register a user exception class so `except MyError` matches it. Names
    -- only, matching how apy_error_matches works.
    return RT.apy_none()
end

function RT.apy_exc_class_bind(exc: number, cls: number): number
    return exc
end

-- ── super ───────────────────────────────────────────────────────────────────

--- super(type, obj) -- a proxy that starts attribute lookup ABOVE `from`.
function RT.apy_super(from: number, self_: number): number
    if RT.kindof(from) ~= "type" then
        return RT.err("TypeError",
                      "super(type, obj): obj must be an instance or subtype "
                      .. "of type")
    end
    local made = RT.apy_list_new(0, 0)
    local o = RT.H(made)
    o.k = "super"
    o.items = nil
    o.from = from
    o.self_ = self_
    return made
end

-- ── descriptors ─────────────────────────────────────────────────────────────
-- kind: 0 property, 1 classmethod, 2 staticmethod. The frontend passes the
-- number; the names are here so a reader does not have to guess.

function RT.apy_descr_new(fn: number, h: number, l: number): number
    local made = RT.apy_list_new(0, 0)
    local o = RT.H(made)
    o.k = "descr"
    o.items = nil
    o.get = fn
    o.set = 0
    o.del = 0
    o.descr_kind = RT.to_number(h, l, true)
    return made
end

--- @x.setter and friends return a NEW descriptor in CPython, but the frontend
--- rebinds the name either way, so mutating and returning the same one is
--- indistinguishable and keeps the getter attached.
function RT.apy_prop_setter(prop: number, fn: number): number
    RT.H(prop).set = fn
    return prop
end

function RT.apy_prop_getter(prop: number, fn: number): number
    RT.H(prop).get = fn
    return prop
end

function RT.apy_prop_deleter(prop: number, fn: number): number
    RT.H(prop).del = fn
    return prop
end

-- ── dict views ──────────────────────────────────────────────────────────────
-- A VIEW, not a snapshot: `ks = d.keys()` then `d['c'] = 3` and `len(ks)` is 3.
-- What it shows is read when it is asked, which is the whole of the liveness.

function RT.apy_dict_view(d: number, h: number, l: number): number
    if RT.kindof(d) ~= "dict" then
        return RT.err("AttributeError",
                      "'" .. RT.kindof(d) .. "' object has no attribute 'keys'")
    end
    local made = RT.apy_list_new(0, 0)
    local o = RT.H(made)
    o.k = "view"
    o.items = nil
    o.dict = d
    o.part = RT.to_number(h, l, true)
    return made
end

--- The view's contents, read NOW.
function RT.apy_view_items(v: number): number
    if RT.kindof(v) ~= "view" then return v end
    local o = RT.H(v)
    return RT.apy_dict_parts(o.dict, 0, o.part)
end

-- ── pattern matching ────────────────────────────────────────────────────────

function RT.apy_match_seq(v: number): (number, number)
    local k = RT.kindof(v)
    -- A str is a sequence and is deliberately NOT matched as one: `case [x]`
    -- must not destructure "a" into its characters.
    return 0, (if k == "list" or k == "tuple" then 1 else 0)
end

function RT.apy_match_map(v: number): (number, number)
    return 0, (if RT.kindof(v) == "dict" then 1 else 0)
end

--- __match_args__, or an empty tuple when the class has none.
function RT.apy_match_args(cls: number): number
    if RT.kindof(cls) == "type" then
        local got = RT.class_find(cls, "__match_args__")
        if got ~= nil then
            local k = RT.kindof(got)
            if k == "tuple" or k == "list" then return got end
        end
    end
    return RT.apy_tuple_new(0, 0)
end

--- The keys a mapping pattern did NOT bind, for `**rest`.
function RT.apy_match_rest(d: number, used: number): number
    if RT.kindof(d) ~= "dict" then return RT.apy_dict_new(0, 0) end
    local out = RT.apy_dict_new(0, 0)
    local o = RT.H(d)
    for _, key in ipairs(o.keys) do
        local skip = false
        if used ~= 0 and RT.items(used) ~= nil then
            for _, u in ipairs(RT.items(used)) do
                if RT.apy_hash_key(u) == RT.apy_hash_key(key) then
                    skip = true
                    break
                end
            end
        end
        if not skip then
            RT.apy_dict_set(out, key, o.vals[RT.apy_hash_key(key)])
        end
    end
    return out
end

-- ── small helpers the frontend emits ────────────────────────────────────────

--- `got or fallback`, at the handle level: 0 means "not found" here rather
--- than "an error is set", because the caller has already decided a miss is
--- not an error.
function RT.apy_name_or(got: number, fallback: number): number
    return if got ~= 0 then got else fallback
end

--- Reading a global that may not exist. `shown` is the name as the user wrote
--- it, so the message quotes their spelling.
function RT.apy_ns_get(ns: number, key: number, shown: number): number
    if RT.kindof(ns) == "dict" then
        local got = RT.H(ns).vals[RT.apy_hash_key(key)]
        if got ~= nil then return got end
    end
    return RT.err("NameError",
                  "name '" .. RT.as_str(shown) .. "' is not defined")
end

--- Unpacking arity check. `at_least` is set for `a, *rest = xs`, where too
--- many values is fine and too few is not.
function RT.apy_unpack_check(v: number, wh: number, wl: number,
                             ah: number, al: number): number
    local want = RT.to_number(wh, wl, true)
    local at_least = RT.to_number(ah, al, true) ~= 0
    local _, n = RT.apy_raw_len(v)
    if n < want then
        return RT.err("ValueError",
                      "not enough values to unpack (expected "
                      .. (if at_least then "at least " else "") .. want
                      .. ", got " .. n .. ")")
    end
    if not at_least and n > want then
        return RT.err("ValueError",
                      "too many values to unpack (expected " .. want .. ")")
    end
    return RT.apy_none()
end

--- print(*args, sep=..., end=...)
function RT.apy_print_seq_with(args: number, sep: number, fin: number): number
    local parts = {}
    for _, e in ipairs(RT.items(args) or {}) do
        local s = RT.apy_str(e)
        if s == 0 then return 0 end
        table.insert(parts, RT.as_str(s))
    end
    local sepstr = if RT.kindof(sep) == "str" then RT.as_str(sep) else " "
    local endstr = if RT.kindof(fin) == "str" then RT.as_str(fin) else "\n"
    local line = table.concat(parts, sepstr)
    -- The trailing newline is the default and is added by stdout, so an
    -- explicit `end=` that is not a newline has to suppress it.
    if endstr == "\n" then
        RT.stdout(line)
    else
        RT.stdout_raw(line .. endstr)
    end
    return RT.apy_none()
end

function RT.apy_call_spread_kw(f: number, args: number, kw: number): number
    local xs = RT.items(args) or {}
    local argv = RT.alloca(math.max(1, #xs) * 8)
    for i, e in ipairs(xs) do
        buffer.writeu32(RT.mem(), argv + (i - 1) * 8, e)
        buffer.writeu32(RT.mem(), argv + (i - 1) * 8 + 4, 0)
    end
    return RT.apy_call(f, argv, RT.from_number(#xs))
end

function RT.apy_func_kwdefaults(f: number, h: number, l: number): number
    RT.H(f).nkwdefaults = RT.to_number(h, l, true)
    return f
end

--- `@` -- matrix multiplication, which no builtin type implements.
function RT.apy_matmul(a: number, b: number): number
    return RT.err("TypeError",
                  "unsupported operand type(s) for @: '" .. RT.kindof(a)
                  .. "' and '" .. RT.kindof(b) .. "'")
end

function RT.apy_alias_new(origin: number, args: number): number
    local made = RT.apy_list_new(0, 0)
    local o = RT.H(made)
    o.k = "alias"
    o.items = nil
    o.origin = origin
    o.args = args
    return made
end

function RT.apy_dir(v: number): number
    local names = {}
    local o = RT.H(v)
    if o.k == "inst" then
        for name in pairs(o.fields) do table.insert(names, name) end
        for name in pairs(RT.H(o.cls).methods) do table.insert(names, name) end
    elseif o.k == "type" then
        for name in pairs(o.methods) do table.insert(names, name) end
    end
    table.sort(names)
    local out = {}
    for _, n in ipairs(names) do table.insert(out, RT.box_str(n)) end
    return RT.apy_sorted(RT.new_list_from(out))
end

--- `x.split(...)` where x may be an exception GROUP rather than a string. One
--- method name, two receivers, and only the receiver can tell them apart.
function RT.apy_split_of(x: number, arg: number): number
    if RT.kindof(x) == "exc" and RT.H(x).subs ~= nil then
        return RT.apy_group_split(x, arg)
    end
    return RT.apy_str_split(x, arg)
end

function RT.apy_code_of(f: number): number
    return f
end

-- ── source positions, for tracebacks ────────────────────────────────────────
-- The frontend emits a table of these and then an `apy_at` before each
-- statement, so a runtime error can name a line in the user's file.

local pos_tab: { any } = {}
local pos_here = 0

function RT.apy_pos_add(name: number, lh: number, ll: number,
                        eh: number, el: number, ch: number, cl: number,
                        dh: number, dl: number)
    table.insert(pos_tab, {
        fn = name,
        line = RT.to_number(lh, ll, true),
        end_line = RT.to_number(eh, el, true),
        col = RT.to_number(ch, cl, true),
        end_col = RT.to_number(dh, dl, true),
    })
end

function RT.apy_at(h: number, l: number)
    pos_here = RT.to_number(h, l, true)
end

function RT.current_position(): any
    return pos_tab[pos_here + 1]
end

-- ── exception groups (PEP 654) ──────────────────────────────────────────────

function RT.apy_excgroup_new(msg: number, excs: number): number
    local g = RT.apy_make_exc(RT.box_str("ExceptionGroup"), msg)
    RT.H(g).subs = RT.items(excs) or {}
    return g
end

--- split(condition) -> (matching, rest), both groups or None.
function RT.apy_group_split(g: number, cond: number): number
    local subs = RT.H(g).subs or {}
    local hit, miss = {}, {}
    for _, e in ipairs(subs) do
        local name = RT.H(e).exctype
        local want = if RT.kindof(cond) == "str" then RT.as_str(cond)
                     else if RT.kindof(cond) == "type" then RT.H(cond).name
                     else ""
        if name == want then table.insert(hit, e) else table.insert(miss, e) end
    end
    local function group_or_none(list)
        if #list == 0 then return RT.apy_none() end
        local made = RT.apy_make_exc(RT.box_str("ExceptionGroup"),
                                     RT.box_str(RT.H(g).msg or ""))
        RT.H(made).subs = list
        return made
    end
    return RT.new_tuple_from({ group_or_none(hit), group_or_none(miss) })
end

function RT.apy_group_subgroup(g: number, cond: number): number
    local pair = RT.apy_group_split(g, cond)
    if pair == 0 then return 0 end
    return RT.items(pair)[1]
end

function RT.apy_group_dispatch(g: number, handlers: number): number
    return RT.apy_none()
end

-- ── template strings (PEP 750) ──────────────────────────────────────────────

function RT.apy_template_new(strings: number, interps: number,
                             values: number): number
    local made = RT.apy_list_new(0, 0)
    local o = RT.H(made)
    o.k = "template"
    o.items = nil
    o.strings = strings
    o.interps = interps
    o.values = values
    return made
end

function RT.apy_interpolation_new(value: number, expr: number, conv: number,
                                  spec: number): number
    local made = RT.apy_list_new(0, 0)
    local o = RT.H(made)
    o.k = "interpolation"
    o.items = nil
    o.value = value
    o.expression = expr
    o.conversion = conv
    o.format_spec = spec
    return made
end
