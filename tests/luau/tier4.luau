-- Classes, descriptors, views, match and typing: behaviour that the
-- expression-pair harness cannot express, because it needs several statements.
--
-- Each check prints `key<TAB>value`; test_tier4_luau.py holds the expectations.

RT.heap(1048576)
local out = {}
local function say(k: string, v: string) table.insert(out, k .. "\t" .. v) end
local function S(x) return RT.box_str(x) end
local function I(n) return RT.box_int(n) end
local function R(v) return RT.as_str(RT.apy_repr(v)) end

-- ── dict views are LIVE ─────────────────────────────────────────────────────
-- The whole point of a view: it reads the dict when asked, not when made.
do
    local d = RT.apy_dict_new(0, 0)
    RT.apy_dict_set(d, S("a"), I(1))
    local ks = RT.apy_dict_view(d, 0, 0)
    say("view_before", R(RT.apy_view_items(ks)))
    RT.apy_dict_set(d, S("b"), I(2))
    say("view_after", R(RT.apy_view_items(ks)))
    say("view_values", R(RT.apy_view_items(RT.apy_dict_view(d, 0, 1))))
    say("view_items", R(RT.apy_view_items(RT.apy_dict_view(d, 0, 2))))
end

-- ── type identity ───────────────────────────────────────────────────────────
-- type(1) is type(2) has to hold, which means the type object is cached.
do
    local t1 = RT.apy_type_object(I(1))
    local t2 = RT.apy_type_object(I(2))
    say("type_is_stable", R(RT.apy_is(t1, t2)))
    say("type_name", R(RT.apy_type_name(I(1))))
    say("type_of_str", R(RT.apy_is(RT.apy_type_object(S("a")),
                                   RT.apy_type_object(S("b")))))
    say("type_int_vs_str", R(RT.apy_is(RT.apy_type_object(I(1)),
                                       RT.apy_type_object(S("a")))))
    say("object_class_stable",
        R(RT.apy_is(RT.apy_object_class(), RT.apy_object_class())))
end

-- ── classes ─────────────────────────────────────────────────────────────────
do
    local ns = RT.apy_dict_new(0, 0)
    RT.apy_dict_set(ns, S("kind"), S("point"))
    local cls = RT.apy_class_build(RT.apy_type_class(), S("Point"),
                                   RT.apy_tuple_new(0, 0), ns)
    say("class_repr", R(cls))
    say("class_attr", R(RT.apy_getattr(cls, S("kind"))))
    local inst = RT.apy_instance_new(cls)
    say("inst_attr_from_class", R(RT.apy_getattr(inst, S("kind"))))
    RT.apy_setattr(inst, S("x"), I(3))
    say("inst_own_attr", R(RT.apy_getattr(inst, S("x"))))
    say("inst_type_name", R(RT.apy_type_name(inst)))

    -- Inheritance is depth-first over the bases tuple.
    local bases = RT.apy_seq_push(RT.apy_tuple_new(0, 0), cls)
    local ns2 = RT.apy_dict_new(0, 0)
    RT.apy_dict_set(ns2, S("extra"), I(9))
    local sub = RT.apy_class_build(RT.apy_type_class(), S("Point3"), bases, ns2)
    say("subclass_own", R(RT.apy_getattr(sub, S("extra"))))
    say("subclass_inherited", tostring(RT.class_find(sub, "kind") ~= nil))
    say("subclass_missing", tostring(RT.class_find(sub, "nope") == nil))
end

-- ── descriptors ─────────────────────────────────────────────────────────────
do
    local getter = S("<get>")
    local p = RT.apy_descr_new(getter, 0, 0)
    say("descr_kind_property", tostring(RT.H(p).descr_kind))
    RT.apy_prop_setter(p, S("<set>"))
    say("descr_has_setter", tostring(RT.H(p).set ~= 0))
    local cm = RT.apy_descr_new(getter, 0, 1)
    say("descr_kind_classmethod", tostring(RT.H(cm).descr_kind))
end

-- ── super ───────────────────────────────────────────────────────────────────
do
    local cls = RT.apy_type_new(S("C"), 0)
    local inst = RT.apy_instance_new(cls)
    local sup = RT.apy_super(cls, inst)
    say("super_kind", RT.kindof(sup))
    local bad = RT.apy_super(I(1), inst)
    say("super_rejects_nontype", tostring(bad == 0))
    RT.apy_error_clear()
end

-- ── match ───────────────────────────────────────────────────────────────────
do
    local L = RT.apy_list_new(0, 0)
    local _, is_seq_list = RT.apy_match_seq(L)
    say("match_seq_list", tostring(is_seq_list))
    local _, is_seq_str = RT.apy_match_seq(S("ab"))
    -- A str is a sequence and deliberately does NOT match one: `case [x]`
    -- must not destructure "a" into characters.
    say("match_seq_str", tostring(is_seq_str))
    local _, is_map = RT.apy_match_map(RT.apy_dict_new(0, 0))
    say("match_map_dict", tostring(is_map))
    local _, is_map2 = RT.apy_match_map(L)
    say("match_map_list", tostring(is_map2))
    say("match_args_empty", R(RT.apy_match_args(RT.apy_type_new(S("X"), 0))))

    local d = RT.apy_dict_new(0, 0)
    RT.apy_dict_set(d, S("a"), I(1))
    RT.apy_dict_set(d, S("b"), I(2))
    local used = RT.apy_seq_push(RT.apy_tuple_new(0, 0), S("a"))
    say("match_rest", R(RT.apy_match_rest(d, used)))
end

-- ── unpacking arity ─────────────────────────────────────────────────────────
do
    local three = RT.apy_list_new(0, 0)
    for i = 1, 3 do RT.apy_seq_push(three, I(i)) end
    say("unpack_ok", tostring(RT.apy_unpack_check(three, 0, 3, 0, 0) ~= 0))
    local few = RT.apy_unpack_check(three, 0, 5, 0, 0)
    say("unpack_too_few", RT.as_str(RT.apy_error_message()))
    RT.apy_error_clear()
    local many = RT.apy_unpack_check(three, 0, 2, 0, 0)
    say("unpack_too_many", RT.as_str(RT.apy_error_message()))
    RT.apy_error_clear()
    say("unpack_at_least", tostring(RT.apy_unpack_check(three, 0, 2, 0, 1) ~= 0))
end

-- ── name lookup ─────────────────────────────────────────────────────────────
do
    local ns = RT.apy_dict_new(0, 0)
    RT.apy_dict_set(ns, S("x"), I(7))
    say("ns_get_hit", R(RT.apy_ns_get(ns, S("x"), S("x"))))
    RT.apy_ns_get(ns, S("y"), S("y"))
    say("ns_get_miss", RT.as_str(RT.apy_error_type()) .. ": "
        .. RT.as_str(RT.apy_error_message()))
    RT.apy_error_clear()
    say("name_or_hit", R(RT.apy_name_or(I(1), I(2))))
    say("name_or_fallback", R(RT.apy_name_or(0, I(2))))
end

-- ── typing ──────────────────────────────────────────────────────────────────
do
    local alias = RT.apy_alias_new(RT.apy_type_object(RT.apy_list_new(0, 0)),
                                   RT.apy_seq_push(RT.apy_tuple_new(0, 0),
                                                   RT.apy_type_object(I(1))))
    -- The origin's OWN name. apy_type_name would answer "type" here, which is
    -- correct -- type(list) is type -- and not what get_origin is asked for.
    say("get_origin_name", RT.H(RT.apy_get_origin(alias)).name)
    say("get_args_len", R(RT.apy_len(RT.apy_get_args(alias))))
    -- Not a generic: origin is None and args is an EMPTY TUPLE, never None,
    -- so a caller can iterate without checking.
    say("get_origin_plain", R(RT.apy_get_origin(I(1))))
    say("get_args_plain", R(RT.apy_get_args(I(1))))

    local tv = RT.apy_typevar(S("T"))
    say("typevar_name", RT.H(tv).name)
    RT.apy_typevar_default(tv, I(0))
    say("typevar_has_default", tostring(RT.H(tv).default ~= 0))

    say("import_known", RT.H(RT.apy_import(S("math"))).name)
    RT.apy_import(S("numpy"))
    say("import_unknown", RT.as_str(RT.apy_error_type()))
    RT.apy_error_clear()
end

-- ── inspect and coroutine marks ─────────────────────────────────────────────
do
    local g = RT.gen_new(0)
    say("is_generator", R(RT.apy_inspect_isgenerator(g)))
    say("is_coroutine_no", R(RT.apy_inspect_iscoroutine(g)))
    RT.apy_coro_mark(g)
    say("is_coroutine_yes", R(RT.apy_inspect_iscoroutine(g)))
    say("is_generator_now_no", R(RT.apy_inspect_isgenerator(g)))
    local ag = RT.apy_agen_mark(RT.gen_new(0))
    say("is_asyncgen", R(RT.apy_inspect_isasyncgen(ag)))
    say("await_rejects_nongen", tostring(RT.apy_await_step(I(1), I(0)) == 0))
    RT.apy_error_clear()
end

-- ── asyncio ─────────────────────────────────────────────────────────────────
do
    -- A coroutine that is already finished: asyncio.run must answer its
    -- result rather than spin.
    local slept = RT.apy_asyncio_sleep(RT.box_float(0))
    say("sleep_is_coro", R(RT.apy_inspect_iscoroutine(slept)))
    say("run_sleep", R(RT.apy_asyncio_run(slept)))
    RT.apy_asyncio_run(I(1))
    say("run_rejects_nonstop", RT.as_str(RT.apy_error_type()))
    RT.apy_error_clear()

    local t = RT.apy_asyncio_create_task(RT.apy_asyncio_sleep(RT.box_float(0)))
    say("task_done_before", R(RT.apy_task_done(t)))
    RT.apy_task_result(t)
    say("task_result_unfinished", RT.as_str(RT.apy_error_type()))
    RT.apy_error_clear()
end

-- ── exception groups ────────────────────────────────────────────────────────
do
    local a = RT.apy_make_exc(S("ValueError"), S("bad"))
    local b = RT.apy_make_exc(S("TypeError"), S("worse"))
    local excs = RT.apy_seq_push(RT.apy_seq_push(RT.apy_list_new(0, 0), a), b)
    local g = RT.apy_excgroup_new(S("two"), excs)
    say("group_subs", tostring(#RT.H(g).subs))
    local pair = RT.apy_group_split(g, S("ValueError"))
    say("group_split_hit", tostring(#(RT.H(RT.items(pair)[1]).subs or {})))
    say("group_split_miss", tostring(#(RT.H(RT.items(pair)[2]).subs or {})))
end

-- ── print with sep and end ──────────────────────────────────────────────────
do
    local args = RT.apy_list_new(0, 0)
    RT.apy_seq_push(args, I(1))
    RT.apy_seq_push(args, I(2))
    say("print_seq_returns",
        R(RT.apy_print_seq_with(args, S("-"), S(string.char(10)))))
end

print(table.concat(out, string.char(10)))
