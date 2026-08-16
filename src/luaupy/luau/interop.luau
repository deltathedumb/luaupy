-- `from luau import l_exec` -- the escape hatch to plain Luau.
--
-- WHY THIS EXISTS
-- ---------------
-- Compiled Python cannot name a Roblox API. The object model knows int, str,
-- list and the rest; it knows nothing about `game`, `Instance`, `Vector3` or
-- any of the several thousand members Roblox adds and changes without telling
-- anyone. Declaring them all would be a binding generator that is out of date
-- the week it ships.
--
-- So one function crosses the boundary, and what comes back is USABLE rather
-- than merely printable:
--
--     from luau import l_exec
--     players = l_exec("return game:GetService('Players')")
--     print(players.MaxPlayers)              -- attribute access forwards
--     part = l_exec("return Instance.new('Part')")
--     part.Anchored = True                   -- assignment forwards
--     part.Parent = l_exec("return workspace")
--
-- A Luau value that is not a primitive is wrapped in a handle of kind `luau`,
-- and `apy_getattr`, `apy_setattr` and `apy_call` forward through it. The
-- whole Roblox API is then reachable by name, including whatever ships next
-- year, with no declarations anywhere.
--
-- LOADSTRING IS NOT ALWAYS THERE
-- ------------------------------
-- Open-source Luau and Studio's command bar have it. In a Roblox game it is
-- server-only and off unless `ServerScriptService.LoadStringEnabled` is set,
-- and there is no way to switch it on from a script. That is reported by name
-- rather than surfacing as `attempt to call a nil value`, which says nothing
-- about which switch to flip.

--- Identity for wrapped values, so `a is a` holds on the Python side and a
--- wrapped instance can be used as a dict key. Weak, so wrapping something
--- does not keep it alive.
local wrapped = setmetatable({}, { __mode = "kv" })

--- A Luau value as a Python value.
---
--- Primitives are CONVERTED, not wrapped: a number that came back from Luau
--- should be an `int` a program can add to, not an opaque object it has to
--- unwrap. Everything else is wrapped, because there is nothing to convert it
--- into and pretending otherwise loses the thing the caller asked for.
function RT.from_luau(v: any): number
    local t = type(v)
    if v == nil then return RT.apy_none() end
    if t == "boolean" then return RT.box_bool(v) end
    if t == "string" then return RT.box_str(v) end
    if t == "number" then
        -- An integral double becomes an int, because `l_exec("return 1")`
        -- answering 1.0 would print as "1.0" and compare unequal to 1 in a
        -- dict key.
        if v % 1 == 0 and math.abs(v) <= 9007199254740992 then
            return RT.box_int(v)
        end
        return RT.box_float(v)
    end
    local hit = wrapped[v]
    if hit ~= nil then return hit end
    local made = RT.apy_list_new(0, 0)
    local o = RT.H(made)
    o.k = "luau"
    o.items = nil
    o.raw = v
    wrapped[v] = made
    return made
end

--- A Python value as a Luau value. The inverse, and lossy in the same places:
--- a list becomes a Luau array, a dict a Luau table, and anything else stays
--- a handle the Luau side cannot read.
function RT.to_luau(v: number): any
    local o = RT.H(v)
    local k = o.k
    if k == "luau" then return o.raw end
    if k == "none" then return nil end
    if k == "bool" then return o.n ~= 0 end
    if k == "int" or k == "float" then return o.n end
    if k == "big" then return RT.apy_as_float(v) end
    if k == "str" or k == "bytes" then return o.s end
    if k == "list" or k == "tuple" then
        local out = {}
        for i, e in ipairs(o.items) do out[i] = RT.to_luau(e) end
        return out
    end
    if k == "dict" then
        local out = {}
        for _, key in ipairs(o.keys) do
            out[RT.to_luau(key)] = RT.to_luau(o.vals[RT.apy_hash_key(key)])
        end
        return out
    end
    if k == "func" or k == "bound" then
        -- A Python callable crossing into Luau -- an event handler, most of
        -- the time. Re-entering the interpreter from a Luau callback is the
        -- whole point: `part.Touched:Connect(on_touch)` has to work.
        return function(...)
            local args = {}
            for i = 1, select("#", ...) do
                args[i] = RT.from_luau((select(i, ...)))
            end
            local argv = RT.alloca(math.max(1, #args) * 8)
            for i, handle in ipairs(args) do
                buffer.writeu32(RT.mem(), argv + (i - 1) * 8, handle)
                buffer.writeu32(RT.mem(), argv + (i - 1) * 8 + 4, 0)
            end
            local result = RT.apy_call(v, argv, RT.from_number(#args))
            if result == 0 then
                -- An error inside a Python callback must not be swallowed by
                -- whatever Luau called it; raise it where the callback ran.
                local message = RT.as_str(RT.apy_error_message())
                local kind = RT.as_str(RT.apy_error_type())
                RT.apy_error_clear()
                error(kind .. ": " .. message, 0)
            end
            return RT.to_luau(result)
        end
    end
    return v
end

--- `l_exec(source)` -- compile and run plain Luau, and answer what it returns.
function RT.luau_l_exec(src: number): number
    if RT.kindof(src) ~= "str" then
        return RT.err("TypeError", "l_exec() argument must be a string")
    end
    if type(loadstring) ~= "function" then
        return RT.err("RuntimeError",
                      "l_exec() needs loadstring, which this host does not " ..
                      "provide. In a Roblox game it is server-only and off " ..
                      "unless ServerScriptService.LoadStringEnabled is set")
    end
    local chunk, why = loadstring(RT.as_str(src))
    if chunk == nil then
        -- A compile error names the Luau, not the Python that asked for it,
        -- so it is passed through verbatim.
        return RT.err("SyntaxError", tostring(why))
    end
    local ok, result = pcall(chunk)
    if not ok then
        return RT.err("RuntimeError", tostring(result))
    end
    return RT.from_luau(result)
end
