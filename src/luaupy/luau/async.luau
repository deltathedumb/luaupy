-- Generators, coroutines and asyncio.
--
-- HOW A GENERATOR SUSPENDS
-- ------------------------
-- Not with Luau coroutines, even though Luau has real ones. The frontend
-- compiles a generator to a STATE MACHINE: the body returns the suspend token
-- when it yields, having stored the yielded value and the resume state on the
-- frame, and is re-entered to continue. `apy_suspend_value` is that token, and
-- it is a single interned object so the check is an identity compare.
--
-- Following the C rather than switching to coroutines is not a preference. The
-- compiled function returns the token; a coroutine-backed driver would sit
-- there waiting for a `coroutine.yield` that the generated code never calls,
-- and the generator would run to completion on its first step.
--
-- WHAT IS NOT VERIFIED
-- --------------------
-- Nothing here has been run against generator code the frontend emitted,
-- because reaching that needs the rest of the pipeline. The shapes follow the
-- C's, and the pieces that can be checked standalone are checked; the driving
-- itself is the part to exercise first when a generator program compiles.

local SUSPEND = 0

--- The token a suspended frame answers with. One object, so `== SUSPEND` is an
--- identity compare rather than a string comparison on every step.
function RT.apy_suspend_value(): number
    if SUSPEND == 0 then SUSPEND = RT.box_str("<suspend>") end
    return SUSPEND
end

local function gen_new(fn: number): number
    local made = RT.apy_list_new(0, 0)
    local o = RT.H(made)
    o.k = "gen"
    o.items = nil
    o.fn = fn
    o.state = 0          -- 0 not started, >0 suspended at a resume point, <0 done
    o.running = false
    o.sent = RT.apy_none()
    o.yielded = RT.apy_none()
    o.coro = false
    o.agen = false
    return made
end

RT.gen_new = gen_new

--- Mark a generator as a coroutine (`async def`) or an async generator.
--- Marks rather than converts: the frame machinery is identical and only
--- `await`/`async for` care which it is.
function RT.apy_coro_mark(g: number): number
    if RT.kindof(g) == "gen" then RT.H(g).coro = true end
    return g
end

function RT.apy_agen_mark(g: number): number
    if RT.kindof(g) == "gen" then
        RT.H(g).agen = true
        RT.H(g).coro = false
    end
    return g
end

--- Mark a FUNCTION as producing a coroutine when called.
function RT.apy_func_coro(f: number): number
    if RT.kindof(f) == "func" then RT.H(f).coro = true end
    return f
end

--- One step of a generator frame. Returns the yielded value, or the stop
--- sentinel when the frame finished; 0 with an error set on failure.
---
--- `running` is not paranoia: a generator that steps itself would re-enter a
--- frame whose state it is midway through updating, and the corruption would
--- surface far from the cause. Python raises here and so does this.
function RT.gen_step(g: number, sent: number): (number, boolean)
    local o = RT.H(g)
    if o.k ~= "gen" then
        RT.err("TypeError", "'" .. o.k .. "' object is not a generator")
        return 0, false
    end
    if o.running then
        RT.err("ValueError", "generator already executing")
        return 0, false
    end
    if o.state < 0 then return RT.apy_none(), true end

    o.running = true
    o.sent = sent
    local out = RT.invoke(RT.H(o.fn).fnid, { g })
    o.running = false
    if out == 0 then
        o.state = -1
        return 0, false
    end
    if out == RT.apy_suspend_value() then
        return o.yielded, false
    end
    -- Fell out of the bottom: the frame is finished and `out` is its return
    -- value, which `StopIteration.value` would carry in Python.
    o.state = -1
    o.result = out
    return out, true
end

--- `await x` -- step the awaited coroutine once.
function RT.apy_await_step(awaited: number, sent: number): number
    if RT.kindof(awaited) ~= "gen" then
        -- Nearly always a missing call: `await f` where `await f()` was meant,
        -- so naming the kind is the whole diagnostic.
        return RT.err("TypeError",
                      "object " .. RT.kindof(awaited)
                      .. " can't be used in 'await' expression")
    end
    local value, done = RT.gen_step(awaited, sent)
    if value == 0 then return 0 end
    if done then return value end
    return RT.apy_suspend_value()
end

function RT.apy_agen_step(g: number, sent: number): number
    return RT.apy_await_step(g, sent)
end

--- `async for` over an async generator.
function RT.apy_aiter(src: number): number
    if RT.kindof(src) == "gen" and RT.H(src).agen then return src end
    return RT.apy_getiter(src)
end

-- ── the event loop ──────────────────────────────────────────────────────────
-- Single-threaded and cooperative, which is all asyncio promises. A task is a
-- coroutine plus its result; the loop steps every ready task in turn until
-- they are all done.

local ready: { number } = {}

local function task_new(coro: number): number
    local made = RT.apy_list_new(0, 0)
    local o = RT.H(made)
    o.k = "task"
    o.items = nil
    o.coro = coro
    o.done = false
    o.cancelled = false
    o.result = RT.apy_none()
    return made
end

local function step_task(t: number): boolean
    local o = RT.H(t)
    if o.done then return true end
    if o.cancelled then
        o.done = true
        return true
    end
    local value, done = RT.gen_step(o.coro, RT.apy_none())
    if value == 0 then
        o.done = true
        return true
    end
    if done then
        o.done = true
        o.result = value
    end
    return o.done
end

--- asyncio.run(coro) -- drive one coroutine to completion, stepping any tasks
--- it created alongside it.
---
--- The iteration guard is not a timeout: a coroutine that never finishes is a
--- program bug, and answering with a named error beats hanging a Roblox server
--- until the watchdog kills it.
function RT.apy_asyncio_run(coro: number): number
    if RT.kindof(coro) ~= "gen" or not RT.H(coro).coro then
        return RT.err("ValueError",
                      "a coroutine was expected, got " .. RT.kindof(coro))
    end
    local main = task_new(coro)
    table.insert(ready, main)
    for _ = 1, 10000000 do
        local pending = false
        for _, t in ipairs(ready) do
            if not step_task(t) then pending = true end
        end
        if RT.H(main).done then
            ready = {}
            return RT.H(main).result
        end
        if not pending then break end
    end
    ready = {}
    if RT.H(main).done then return RT.H(main).result end
    return RT.err("RuntimeError", "event loop made no progress")
end

--- asyncio.sleep(d) -- a coroutine that finishes immediately.
---
--- There is no clock to wait on here: the loop is cooperative and nothing else
--- runs while it blocks, so a real delay would just stop the program. Yielding
--- once gives other tasks a turn, which is what sleep(0) means and the closest
--- honest reading of the rest.
function RT.apy_asyncio_sleep(delay: number): number
    local g = gen_new(0)
    local o = RT.H(g)
    o.coro = true
    o.state = -1
    o.result = RT.apy_none()
    return g
end

function RT.apy_asyncio_create_task(coro: number): number
    local t = task_new(coro)
    table.insert(ready, t)
    return t
end

function RT.apy_asyncio_gather(coros: number): number
    local xs = RT.items(coros) or {}
    local out = {}
    for _, c in ipairs(xs) do
        if RT.kindof(c) == "gen" then
            local r = RT.apy_asyncio_run(c)
            if r == 0 then return 0 end
            table.insert(out, r)
        else
            table.insert(out, c)
        end
    end
    return RT.new_list_from(out)
end

function RT.apy_asyncio_wait_for(coro: number, timeout: number): number
    return RT.apy_asyncio_run(coro)
end

function RT.apy_asyncio_taskgroup(): number
    local made = RT.apy_list_new(0, 0)
    RT.H(made).k = "taskgroup"
    return made
end

-- ── tasks ───────────────────────────────────────────────────────────────────

function RT.apy_task_cancel(t: number): number
    local o = RT.H(t)
    if not o.done then o.cancelled = true end
    return RT.box_bool(not o.done)
end

--- result() raises if the task is not finished, rather than answering None --
--- an unfinished task has no result, and returning one hides the bug.
function RT.apy_task_result(t: number): number
    local o = RT.H(t)
    if o.cancelled then
        return RT.err("RuntimeError", "task was cancelled")
    end
    if not o.done then
        return RT.err("RuntimeError", "task is not done")
    end
    return o.result
end

function RT.apy_task_done(t: number): number
    return RT.box_bool(RT.H(t).done)
end

function RT.apy_task_cancelled(t: number): number
    return RT.box_bool(RT.H(t).cancelled)
end

-- ── async context managers ──────────────────────────────────────────────────
-- Each answers a COROUTINE, which the caller awaits.

local function immediate(value: number): number
    local g = gen_new(0)
    local o = RT.H(g)
    o.coro = true
    o.state = -1
    o.result = value
    return g
end

function RT.apy_aenter(v: number): number
    local m = RT.apy_getattr(v, RT.box_str("__aenter__"))
    if m == 0 then
        RT.apy_error_clear()
        return immediate(v)
    end
    local argv = RT.alloca(8)
    return RT.apy_call(m, argv, 0, 0)
end

function RT.apy_aexit(v: number, exc: number): number
    local m = RT.apy_getattr(v, RT.box_str("__aexit__"))
    if m == 0 then
        RT.apy_error_clear()
        return immediate(RT.apy_none())
    end
    local argv = RT.alloca(8)
    buffer.writeu32(RT.mem(), argv, exc)
    buffer.writeu32(RT.mem(), argv + 4, 0)
    return RT.apy_call(m, argv, 0, 1)
end

-- ── inspect ─────────────────────────────────────────────────────────────────
-- The three questions a program asks about coroutines, plus the function form.

function RT.apy_inspect_iscoroutine(v: number): number
    return RT.box_bool(RT.kindof(v) == "gen" and RT.H(v).coro)
end

function RT.apy_inspect_isgenerator(v: number): number
    return RT.box_bool(RT.kindof(v) == "gen"
                       and not RT.H(v).coro and not RT.H(v).agen)
end

function RT.apy_inspect_isasyncgen(v: number): number
    return RT.box_bool(RT.kindof(v) == "gen" and RT.H(v).agen == true)
end

function RT.apy_inspect_iscoroutinefunction(v: number): number
    return RT.box_bool(RT.kindof(v) == "func" and RT.H(v).coro == true)
end
