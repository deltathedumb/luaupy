-- `typing`, and `import`.
--
-- The cheapest group in the runtime, and deliberately so: a type annotation is
-- INERT at run time. A special form is an object a program names and never
-- inspects, and the decorators mark and return. Implementing any of it as
-- anything more would be inventing behaviour Python does not have.
--
-- The exception is `get_origin` / `get_args`, which programs really do call --
-- those read back what `apy_alias_new` recorded.

--- A special form: `Optional`, `Union`, `Literal`, and the rest. It answers
--- itself, so `x: Optional[int]` evaluates and is then dropped.
function RT.apy_typing_form(name: number): number
    local made = RT.apy_list_new(0, 0)
    local o = RT.H(made)
    o.k = "type"
    o.items = nil
    o.name = if RT.kindof(name) == "str" then RT.as_str(name) else "SpecialForm"
    o.methods = {}
    o.special = true
    return made
end

-- @final and @override mark and return. The mark is unobservable at run time
-- and is recorded anyway, so a future `typing.get_overloads` has something.
function RT.apy_typing_final(f: number): number
    if RT.H(f) ~= nil then RT.H(f).final = true end
    return f
end

function RT.apy_typing_override(f: number): number
    if RT.H(f) ~= nil then RT.H(f).override = true end
    return f
end

function RT.apy_typing_mark(f: number): number
    return f
end

--- `type X = int` (PEP 695). The value is lazy in CPython; here it is eager,
--- which differs only for a self-referential alias.
function RT.apy_type_alias(name: number, params: number, value: number): number
    local made = RT.apy_list_new(0, 0)
    local o = RT.H(made)
    o.k = "typealias"
    o.items = nil
    o.name = if RT.kindof(name) == "str" then RT.as_str(name) else "?"
    o.type_params = params
    o.value = value
    return made
end

--- TypeVar. `has_default()` is a METHOD rather than an attribute (PEP 696), so
--- the object needs one; the whole of it is "is the default slot filled".
function RT.apy_typevar(name: number): number
    local made = RT.apy_list_new(0, 0)
    local o = RT.H(made)
    o.k = "typevar"
    o.items = nil
    o.name = if RT.kindof(name) == "str" then RT.as_str(name) else "T"
    o.default = 0
    return made
end

function RT.apy_typevar_default(tv: number, default: number): number
    RT.H(tv).default = default
    return tv
end

--- get_origin(List[int]) -> list. None for anything that is not a subscripted
--- generic, which is what makes it usable as a test.
function RT.apy_get_origin(v: number): number
    local o = RT.H(v)
    if o.k == "alias" then return o.origin end
    return RT.apy_none()
end

--- get_args(List[int]) -> (int,). An empty tuple, never None, for anything
--- else -- so a caller can iterate the result without checking first.
function RT.apy_get_args(v: number): number
    local o = RT.H(v)
    if o.k == "alias" then
        if RT.kindof(o.args) == "tuple" then return o.args end
        return RT.new_tuple_from({ o.args })
    end
    return RT.apy_tuple_new(0, 0)
end

--- `import x`.
---
--- The module object is a namespace whose members the FRONTEND fills in from
--- its own module table -- see `Backend.modules`. This answers a namespace for
--- a name the frontend knows about and raises for anything else, which is what
--- turns `import numpy` into a diagnostic rather than a silent None.
local KNOWN = {
    "math", "sys", "typing", "asyncio", "inspect", "__future__",
    "functools", "itertools", "contextlib", "warnings", "statistics",
    "abc", "enum", "collections", "collections.abc", "fractions",
    "decimal", "tomllib", "pathlib", "dataclasses", "contextvars",
    "numbers", "copy",
}

function RT.apy_import(name: number): number
    if RT.kindof(name) ~= "str" then
        return RT.err("TypeError", "import name must be a string")
    end
    local want = RT.as_str(name)
    for _, known in ipairs(KNOWN) do
        if known == want then
            local made = RT.apy_list_new(0, 0)
            local o = RT.H(made)
            o.k = "module"
            o.items = nil
            o.name = want
            o.methods = {}
            return made
        end
    end
    return RT.err("ModuleNotFoundError", "No module named '" .. want .. "'")
end
