"""IR to Luau source.

The traversal is the one every backend has:

    for each function
        declare the registers
        walk the structured tree      <- structure.py did the hard part
            for each instruction
                switch on ins.op      <- the whole job

`structure.py` has already turned the control-flow graph into `if`/`while`/
`repeat`, so nothing here reasons about blocks or edges. What is left is one
rule per opcode, plus the two places Luau's single number type shows through.

NARROW TYPES INLINE, WIDE TYPES CALL
------------------------------------
`i1` through `i32` fit exactly in a double, so their arithmetic is emitted
inline: `r3 = (r1 + r2) % 4294967296`. `i64` and `u64` do not fit, occupy two
locals (see `values.py`), and delegate to a runtime helper returning two
values: `local r3_h, r3_l = RT.add64(r1_h, r1_l, r2_h, r2_l)`.

Delegating rather than inlining the hi/lo arithmetic keeps this file one line
per opcode either way. The alternative -- open-coding carry propagation at
every 64-bit add -- triples the emitter and puts the same three lines of carry
logic in a dozen places for a call Luau's inliner can take anyway.

SIGNEDNESS IS APPLIED, NEVER STORED
-----------------------------------
Integers are raw bit patterns; an `i32` holding -1 is the number 4294967295.
Only the opcodes whose meaning depends on signedness -- `div`, `rem`, `shr`,
the four ordered comparisons, `extend`, `itof` -- convert, and they read it
from `ins.ty` exactly as the opcode table says to. Everything else is
bit-identical for signed and unsigned operands, which is why there is one rule
for `add` and not two.
"""
from __future__ import annotations

from asmpython.backend import Backend, BackendUnsupported, Option, OptionError
from asmpython.backend.base import ENTRY_SYMBOL
from asmpython.ir import types as T
from asmpython.ir.cfg import ControlFlowGraph
from asmpython.ir.module import Function, Global, Instruction, Module
from asmpython.ir.opcodes import Op
from asmpython.target import Target

from . import runtime, values as V
from .structure import (
    Br, BlockScope, Code, If, Irreducible, LoopScope, Ret, Seq, Structured,
    Switch, Unreachable, structure,
)

#: Luau's arithmetic operators, for the opcodes that are one.
_BIN = {
    Op.ADD: "+", Op.SUB: "-", Op.MUL: "*",
    Op.EQ: "==", Op.NE: "~=", Op.LT: "<", Op.LE: "<=", Op.GT: ">", Op.GE: ">=",
}

#: `bit32` covers the 32-bit bitwise operations exactly, which is what the
#: narrow integer types need. It is undefined above 32 bits, so nothing wide
#: reaches it -- those go to the runtime's own halves-at-a-time versions.
_BIT32 = {
    Op.AND: "bit32.band", Op.OR: "bit32.bor",
    Op.XOR: "bit32.bxor", Op.SHL: "bit32.lshift",
}


class LuauBackend(Backend):
    """IR to Luau source, for Roblox."""

    name = "luau"
    description = "Luau source for Roblox; structured control flow, no bytecode"
    default_target = "roblox"

    #: The emitted tree carries its own runtime -- `runtime.luau` defines the
    #: host functions and the heap -- so there is nothing for a link stage to
    #: supply. Saying otherwise makes the driver look for a runtime object to
    #: link, which for this target does not exist in any form.
    self_contained = True

    #: The opcode table is covered but the 274-function Python object runtime
    #: is not yet ported, so a program doing more than arithmetic will reach an
    #: `apy_*` stub. The driver warns on every build until this flips.
    ready = False

    options = (
        Option("luau-heap",
               "heap size in bytes for the emitted program's flat memory",
               metavar="BYTES"),
        Option("luau-layout",
               "artifact layout: `rojo` (default.project.json + src/) "
               "or `flat` (a single init.luau)",
               metavar="LAYOUT"),
    )

    def __init__(self, *, heap: int = 16 << 20, layout: str = "rojo") -> None:
        self.heap = heap
        self.layout = layout

    def configure(self, values: dict[str, str], sink) -> "LuauBackend":
        """A NEW instance -- the registry holds one shared backend object, and
        flags stored on `self` would leak into the next compilation in the same
        process."""
        heap, layout = self.heap, self.layout
        if "luau-heap" in values:
            raw = values["luau-heap"].strip()
            try:
                heap = int(raw, 0)
            except ValueError:
                raise OptionError(f"heap size must be a number, not {raw!r}") from None
            if heap < (1 << 16):
                raise OptionError(
                    f"heap size {heap} is below the 65536-byte minimum; "
                    f"the runtime's own tables do not fit under it")
        if "luau-layout" in values:
            layout = values["luau-layout"].strip().lower()
            if layout not in ("rojo", "flat"):
                raise OptionError(
                    f"unknown layout {layout!r}\nexpected: rojo, flat")
        return LuauBackend(heap=heap, layout=layout)

    # ── the entry point ─────────────────────────────────────────────────────
    def emit(self, module: Module, target: Target) -> dict[str, bytes]:
        body = _Emitter(module, self.heap).run()
        rt = runtime.runtime_luau()

        if self.layout == "flat":
            # One file, for pasting straight into a Script. The runtime is
            # wrapped in an immediately-called function rather than pasted
            # ahead of the program: it ends in `return RT`, and at the top
            # level that returns from the CHUNK, so everything after it --
            # the entire program -- becomes dead code that never runs and
            # never errors either.
            return {"init.luau": _flat(rt, body).encode("utf-8")}

        # Rojo, first key first: the CLI prints whichever artifact is written
        # first, and the program is more interesting than its project file.
        return {
            "src/init.server.luau": body.encode("utf-8"),
            "src/runtime.luau": rt.encode("utf-8"),
            "default.project.json": _PROJECT_JSON.encode("utf-8"),
        }


#: How the emitted program reaches its runtime. A ModuleScript sibling, because
#: that is the only import Roblox has -- there is no path-based `require`.
_REQUIRE_LINE = "local RT = require(script.Parent.runtime)"

def _flat(rt: str, body: str) -> str:
    """One self-contained chunk: runtime, then program.

    `--!native` and `--!optimize` are file-level directives -- Luau reads them
    only at the very top -- so both halves' copies are stripped and one set is
    written first. Left in place they are inert comments, and the file silently
    loses native codegen, which is exactly the kind of loss that shows up as a
    performance mystery rather than an error.
    """
    def strip_directives(text: str) -> str:
        lines = text.splitlines()
        i = 0
        while i < len(lines) and (lines[i].startswith("--!") or not lines[i]):
            i += 1
        return "\n".join(lines[i:])

    program = strip_directives(body.replace(_REQUIRE_LINE + "\n", ""))
    return (
        "--!native\n--!optimize 2\n"
        "-- Generated by luaupy (flat layout). Paste into a Script.\n\n"
        "local RT = (function()\n"
        + strip_directives(rt)
        + "\nend)()\n\n"
        + program
    )

_PROJECT_JSON = """\
{
  "name": "luaupy-program",
  "tree": {
    "$className": "DataModel",
    "ServerScriptService": {
      "$className": "ServerScriptService",
      "program": {
        "$path": "src"
      }
    }
  }
}
"""


class _Emitter:
    """One module's worth of Luau text.

    Lines are accumulated in a list and joined once. Indentation is tracked
    rather than computed from the tree depth, because the unwind checks are
    emitted after a scope closes and so belong to the enclosing level, not the
    one that just ended.
    """

    def __init__(self, module: Module, heap: int) -> None:
        self.module = module
        self.heap = heap
        self.out: list[str] = []
        self.depth = 0
        #: The scopes open at the current point, innermost last, as
        #: (block, is_loop). Mirrors the structurer's own stack -- it is the
        #: only way to know how many levels a `Br` crosses, and recomputing it
        #: here rather than storing it on the node keeps one source of truth.
        self.scopes: list[tuple[int, bool]] = []
        self.fn: Function | None = None
        self.cfg: ControlFlowGraph | None = None
        self.struct: Structured | None = None

    # ── text ────────────────────────────────────────────────────────────────
    def line(self, text: str = "") -> None:
        self.out.append(("    " * self.depth + text) if text else "")

    def run(self) -> str:
        self.line("--!native")
        self.line("--!optimize 2")
        self.line("-- Generated by luaupy. Do not edit.")
        self.line(f"-- {self.module.name}: "
                  + ", ".join(f"{k}={v}" for k, v in
                              sorted(self.module.statistics().items())))
        self.line()
        self.line(_REQUIRE_LINE)
        self.line(f"local MEM = RT.heap({self.heap})")
        self.line("local bit32 = bit32")
        self.line()

        self._globals()

        # Forward-declare every function, so call order in the module never
        # matters and mutual recursion needs no reordering pass.
        defined = [f for f in self.module.defined_functions()]
        if defined:
            for f in defined:
                self.line(f"local {_fname(f.name)}")
            self.line()

        for f in defined:
            self._function(f)
            self.line()

        entry = self.module.function("main")
        if entry is not None:
            self.line(f"-- The IR's `main`, published under the name the "
                      f"runtime calls.")
            self.line(f"local function {V.ident(ENTRY_SYMBOL)}()")
            self.line(f"    return {_fname('main')}()")
            self.line("end")
            self.line()
            self.line(f"return {V.ident(ENTRY_SYMBOL)}()")
        return "\n".join(self.out) + "\n"

    # ── globals ─────────────────────────────────────────────────────────────
    def _globals(self) -> None:
        """Place every global at a fixed heap offset and write its bytes.

        Laid out here rather than by the frontend because the frontend emits
        `global_addr` by NAME and leaves the address to whoever knows where
        memory starts. Offsets are assigned in declaration order, each aligned
        to its own requirement, starting past the runtime's reserved page.
        """
        if not self.module.globals:
            return
        addr = runtime.HEAP_BASE
        self.line("-- module globals, at fixed heap offsets")
        for g in self.module.globals:
            # `align == 0` means "natural for the size", and the only safe
            # reading of that is the target's maximum: 8. Deriving it from the
            # size instead gives a non-power-of-two for anything whose size is
            # not one -- a 3-byte global aligned to 3, landing at 4098 -- and
            # an alignment that is not a power of two is not an alignment.
            # Over-aligning wastes at most 7 bytes and is never wrong.
            align = g.align or 8
            addr = (addr + align - 1) // align * align
            self.line(f"local {_gname(g.name)} = {addr}")
            if g.data:
                self.line(f"RT.blit(MEM, {addr}, {_bytes_literal(g.data)})")
            addr += max(1, g.size)
        self.line(f"RT.reserve({addr})")
        self.line()

    # ── one function ────────────────────────────────────────────────────────
    def _function(self, fn: Function) -> None:
        self.fn = fn
        self.cfg = ControlFlowGraph.build(fn)
        try:
            self.struct = structure(fn, self.cfg)
        except Irreducible as exc:
            # Not a crash and not the user's fault: the program is valid and
            # this backend does not implement the shape. The driver turns it
            # into a diagnostic naming the backend rather than a traceback.
            raise BackendUnsupported(str(exc)) from None

        params = []
        for p in fn.params:
            params.extend(V.names(p, fn.register_type(p)))
        self.line(f"function {_fname(fn.name)}({', '.join(params)})")
        self.depth += 1

        # Every register is declared and zeroed up front. Luau scopes a
        # `local` to the block it appears in, and this emitter puts blocks
        # inside `if` arms and loop bodies -- so a register first assigned in
        # one arm and read after it would be `nil`, which is not a type error
        # in Luau but an arithmetic one, reported at a line that does not
        # mention the register.
        decls: list[str] = []
        inits: list[str] = []
        for reg in sorted(fn.registers):
            if reg in fn.params:
                continue
            ty = fn.registers[reg]
            decls.extend(V.names(reg, ty))
            inits.extend(V.zero(ty))
        for i in range(0, len(decls), 8):
            chunk, init = decls[i:i + 8], inits[i:i + 8]
            self.line(f"local {', '.join(chunk)} = {', '.join(init)}")

        if self.struct.needs_escape:
            self.line("local esc = 0  -- multi-level break/continue target")

        self._node(self.struct.root)

        self.depth -= 1
        self.line("end")
        self.fn = self.cfg = self.struct = None

    # ── the structured tree ─────────────────────────────────────────────────
    def _node(self, node) -> None:
        match node:
            case Seq(items=items):
                for item in items:
                    self._node(item)

            case Code(block=b):
                assert self.cfg is not None
                for ins in self.cfg.blocks[b].instructions[:-1]:
                    self._instr(ins)

            case LoopScope(id=sid, header=h, body=body):
                assert self.cfg is not None
                self.line(f"while true do  -- {self.cfg.blocks[h].label}")
                self.depth += 1
                self.scopes.append((sid, True))
                self._node(body)
                self.scopes.pop()
                self.depth -= 1
                self.line("end")
                self._unwind_check(sid, is_loop=True)

            case BlockScope(id=sid, target=t, body=body):
                assert self.cfg is not None
                self.line(f"repeat  -- to {self.cfg.blocks[t].label}")
                self.depth += 1
                self.scopes.append((sid, False))
                self._node(body)
                self.scopes.pop()
                self.depth -= 1
                self.line("until true")
                self._unwind_check(sid, is_loop=False)

            case If(cond=c, then_=then_, else_=else_):
                assert self.fn is not None
                self.line(f"if {_truthy(c, self.fn)} then")
                self.depth += 1
                self._node(then_)
                self.depth -= 1
                self.line("else")
                self.depth += 1
                self._node(else_)
                self.depth -= 1
                self.line("end")

            case Switch(value=v, cases=cases, default=default):
                assert self.fn is not None
                keyword = "if"
                for value, arm in cases:
                    self.line(f"{keyword} {self._case_test(v, value)} then")
                    self.depth += 1
                    self._node(arm)
                    self.depth -= 1
                    keyword = "elseif"
                if cases:
                    self.line("else")
                    self.depth += 1
                    self._node(default)
                    self.depth -= 1
                    self.line("end")
                else:
                    self._node(default)

            case Br(scope=target):
                self._br(target)

            case Ret(args=args):
                assert self.fn is not None
                if args:
                    names = V.names(args[0], self.fn.register_type(args[0]))
                    self.line(f"return {', '.join(names)}")
                else:
                    self.line("return")

            case Unreachable(block=b):
                assert self.cfg is not None
                self.line(f'RT.trap("unreachable: '
                          f'{self.cfg.blocks[b].label}")')

            case _:  # pragma: no cover -- the node set is closed
                raise AssertionError(f"no rule for {type(node).__name__}")

    # ── branches and the unwind ─────────────────────────────────────────────
    def _br(self, target: int) -> None:
        """`break`, `continue`, or set `esc` and start unwinding.

        The depth is measured against this emitter's own scope stack rather
        than read off the node. Both stacks are built by the same rules, so
        they agree; storing the number on the node would be a second copy of
        one fact, free to disagree the moment anything rewrites the tree.
        """
        pos = _rindex(self.scopes, target)
        assert pos >= 0, "branch to a scope that is not open"
        depth = len(self.scopes) - 1 - pos
        _, is_loop = self.scopes[pos]
        if depth == 0:
            # The innermost scope, which is what a bare keyword means. A loop
            # is re-entered at its top; a block is left behind.
            self.line("continue" if is_loop else "break")
            return
        self.line(f"esc = {target}")
        self.line("break")

    def _unwind_check(self, sid: int, *, is_loop: bool) -> None:
        """Re-break, or stop, after a scope that an unwind passes through.

        Emitted only for scopes the structurer says are crossed. A function
        whose branches are all depth 0 gets none of this, and no `esc` either.
        """
        assert self.struct is not None
        if sid not in self.struct.check_after:
            return
        # Where we are now: just past `sid`, inside whatever encloses it.
        parent = self.scopes[-1] if self.scopes else None

        self.line("if esc ~= 0 then")
        self.depth += 1
        keyword = "if"
        # Arrived: `sid` was a block target and we are now past its end. A loop
        # target is never reached this way -- it is re-entered at its top, by
        # the arm below -- so it gets no clause here.
        if not is_loop and sid in self.struct.far_targets:
            self.line(f"if esc == {sid} then")
            self.depth += 1
            self.line("esc = 0")
            self.depth -= 1
            keyword = "elseif"
        if parent is not None and parent[1] and parent[0] in self.struct.far_targets:
            # The enclosing loop is the target: land at its top.
            self.line(f"{keyword} esc == {parent[0]} then")
            self.depth += 1
            self.line("esc = 0")
            self.line("continue")
            self.depth -= 1
            keyword = "elseif"
        if parent is not None:
            self.line("else" if keyword != "if" else "if true then")
            self.depth += 1
            self.line("break")
            self.depth -= 1
        if keyword != "if" or parent is not None:
            self.line("end")
        self.depth -= 1
        self.line("end")

    # ── one instruction: the whole job ──────────────────────────────────────
    def _instr(self, ins: Instruction) -> None:
        assert self.fn is not None
        fn, ty = self.fn, ins.ty
        wide = V.is_wide(ty)

        def dst() -> str:
            """The destination locals, named from the REGISTER'S type.

            Not from `ins.ty`. For most opcodes they agree, but a comparison's
            `ty` is the type of its OPERANDS -- the opcode table says so, and
            its result is always `i1`. Naming the destination from `ty` gives
            `r7_h, r7_l = ... and 1 or 0` for an i64 comparison into a
            one-local i1 register, and every later read of `r7` then sees a
            value nothing ever assigned.
            """
            assert ins.dst is not None
            return ", ".join(V.names(ins.dst, fn.register_type(ins.dst)))

        def arg(i: int) -> str:
            reg = ins.args[i]
            return ", ".join(V.names(reg, fn.register_type(reg)))

        def a(i: int) -> str:
            """One narrow operand, by name."""
            return _scalar(ins.args[i], fn)

        match ins.op:
            case Op.CONST:
                self.line(f"{dst()} = {_literal(ty, ins.imm)}")

            case Op.COPY:
                self.line(f"{dst()} = {arg(0)}")

            case Op.GLOBAL_ADDR:
                self.line(f"{dst()} = {_gname(ins.sym or '')}")

            case Op.FUNC_ADDR:
                # A function pointer is an index into the runtime's table, so
                # `call_ptr` is a table lookup rather than anything unsafe.
                self.line(f"{dst()} = RT.fnid({_fname(ins.sym or '')})")

            case Op.ADD | Op.SUB | Op.MUL if wide:
                helper = {Op.ADD: "add64", Op.SUB: "sub64", Op.MUL: "mul64"}[ins.op]
                self.line(f"{dst()} = RT.{helper}({arg(0)}, {arg(1)})")

            case Op.ADD | Op.SUB if ty.is_float:
                self.line(f"{dst()} = {_f32(ty, f'{a(0)} {_BIN[ins.op]} {a(1)}')}")
            case Op.MUL if ty.is_float:
                self.line(f"{dst()} = {_f32(ty, f'{a(0)} * {a(1)}')}")

            case Op.ADD | Op.SUB:
                self.line(f"{dst()} = ({a(0)} {_BIN[ins.op]} {a(1)}) % {V.mask(ty)}")
            case Op.MUL:
                # Two 32-bit operands multiply to as much as 2^64, past the
                # 2^53 a double holds exactly, so the wide case splits. Below
                # 32 bits the product always fits and a plain `*` is exact.
                if ty.bits >= 32:
                    self.line(f"{dst()} = RT.mul32({a(0)}, {a(1)}) % {V.mask(ty)}")
                else:
                    self.line(f"{dst()} = ({a(0)} * {a(1)}) % {V.mask(ty)}")

            case Op.DIV if ty.is_float:
                self.line(f"{dst()} = {_f32(ty, f'{a(0)} / {a(1)}')}")
            case Op.REM if ty.is_float:
                # Luau's `%` is a floored modulo; C's fmod and the IR's `rem`
                # truncate. They differ in sign for mixed operands, so this is
                # not `%`.
                self.line(f"{dst()} = {_f32(ty, f'RT.fmod({a(0)}, {a(1)})')}")

            case Op.DIV | Op.REM if wide:
                helper = ("div64" if ins.op is Op.DIV else "rem64")
                self.line(f"{dst()} = RT.{helper}({arg(0)}, {arg(1)}, "
                          f"{str(ty.is_signed).lower()})")
            case Op.DIV | Op.REM:
                helper = ("div32" if ins.op is Op.DIV else "rem32")
                self.line(f"{dst()} = RT.{helper}({a(0)}, {a(1)}, {ty.bits}, "
                          f"{str(ty.is_signed).lower()})")

            case Op.NEG if ty.is_float:
                self.line(f"{dst()} = -{a(0)}")
            case Op.NEG if wide:
                self.line(f"{dst()} = RT.neg64({arg(0)})")
            case Op.NEG:
                self.line(f"{dst()} = (-{a(0)}) % {V.mask(ty)}")

            case Op.AND | Op.OR | Op.XOR | Op.SHL if wide:
                helper = {Op.AND: "and64", Op.OR: "or64",
                          Op.XOR: "xor64", Op.SHL: "shl64"}[ins.op]
                self.line(f"{dst()} = RT.{helper}({arg(0)}, {arg(1)})")
            case Op.AND | Op.OR | Op.XOR:
                self.line(f"{dst()} = {_BIT32[ins.op]}({a(0)}, {a(1)})")
            case Op.SHL:
                self.line(f"{dst()} = bit32.lshift({a(0)}, {a(1)}) % {V.mask(ty)}")

            case Op.SHR if wide:
                self.line(f"{dst()} = RT.shr64({arg(0)}, {arg(1)}, "
                          f"{str(ty.is_signed).lower()})")
            case Op.SHR:
                # Arithmetic on signed types, logical on unsigned -- read off
                # the type, exactly as the opcode table specifies.
                fnname = "arshift" if ty.is_signed else "rshift"
                if ty.is_signed and ty.bits < 32:
                    # bit32 works at 32 bits, so a narrower signed value has to
                    # be sign-extended into 32 bits first or the shifted-in
                    # bits are zeros where they should be ones.
                    self.line(f"{dst()} = bit32.arshift("
                              f"RT.sext({a(0)}, {ty.bits}), {a(1)}) "
                              f"% {V.mask(ty)}")
                else:
                    self.line(f"{dst()} = bit32.{fnname}({a(0)}, {a(1)})")

            case Op.NOT if wide:
                self.line(f"{dst()} = RT.not64({arg(0)})")
            case Op.NOT:
                self.line(f"{dst()} = {V.mask(ty) - 1} - {a(0)}")

            case Op.EQ | Op.NE if wide:
                op = "==" if ins.op is Op.EQ else "~="
                lhs, rhs = ins.args[0], ins.args[1]
                self.line(f"{dst()} = (RT.eq64({arg(0)}, {arg(1)}) "
                          f"{op} true) and 1 or 0")
            case Op.LT | Op.LE | Op.GT | Op.GE if wide:
                self.line(f"{dst()} = RT.cmp64({arg(0)}, {arg(1)}, "
                          f"\"{_BIN[ins.op]}\", "
                          f"{str(ty.is_signed).lower()}) and 1 or 0")

            case Op.EQ | Op.NE:
                self.line(f"{dst()} = ({a(0)} {_BIN[ins.op]} {a(1)}) and 1 or 0")
            case Op.LT | Op.LE | Op.GT | Op.GE:
                lhs, rhs = a(0), a(1)
                if ty.is_int and ty.is_signed:
                    lhs = f"RT.sext({lhs}, {ty.bits})"
                    rhs = f"RT.sext({rhs}, {ty.bits})"
                self.line(f"{dst()} = ({lhs} {_BIN[ins.op]} {rhs}) and 1 or 0")

            # ── conversions ─────────────────────────────────────────────────
            case Op.TRUNC:
                src = fn.register_type(ins.args[0])
                expr = V.lo(ins.args[0]) if V.is_wide(src) else a(0)
                self.line(f"{dst()} = {expr} % {V.mask(ty)}")

            case Op.EXTEND:
                src = fn.register_type(ins.args[0])
                # The SOURCE decides: sign-extend from a signed source,
                # zero-extend otherwise. Reading the destination instead is the
                # classic way to turn 0xFF:u8 into -1 on the way to i32.
                if wide:
                    self.line(f"{dst()} = RT.widen({a(0)}, {src.bits}, "
                              f"{str(src.is_signed).lower()})")
                elif src.is_signed:
                    self.line(f"{dst()} = RT.sext({a(0)}, {src.bits}) "
                              f"% {V.mask(ty)}")
                else:
                    self.line(f"{dst()} = {a(0)}")

            case Op.FTOI:
                trunc = f"RT.trunc({a(0)})"
                if wide:
                    self.line(f"{dst()} = RT.from_number({trunc})")
                else:
                    self.line(f"{dst()} = {trunc} % {V.mask(ty)}")

            case Op.ITOF:
                src = fn.register_type(ins.args[0])
                if V.is_wide(src):
                    self.line(f"{dst()} = RT.to_number({arg(0)}, "
                              f"{str(src.is_signed).lower()})")
                elif src.is_signed:
                    self.line(f"{dst()} = {_f32(ty, f'RT.sext({a(0)}, {src.bits})')}")
                else:
                    self.line(f"{dst()} = {_f32(ty, a(0))}")

            case Op.FTOF:
                self.line(f"{dst()} = {_f32(ty, a(0))}")

            case Op.BITCAST:
                self._bitcast(ins)

            # ── memory ──────────────────────────────────────────────────────
            case Op.ALLOCA:
                self.line(f"{dst()} = RT.alloca({int(ins.imm or 0)})")
            case Op.LOAD:
                self.line(f"{dst()} = RT.{_mem('read', ty)}(MEM, {a(0)})")
            case Op.STORE:
                # Operands are (value, address) -- the value first, which is
                # the opposite of the order the call takes.
                self.line(f"RT.{_mem('write', ty)}(MEM, {a(1)}, {arg(0)})")
            case Op.OFFSET:
                # The offset is "an integer" -- any width, either signedness --
                # while the pointer is always one local holding a buffer index.
                # Both of the other readings are wrong: a 64-bit offset has two
                # locals and cannot be named as one, and a narrow SIGNED offset
                # is stored as a raw bit pattern, so `p + r1` with r1 = -1:i32
                # would add 4294967295 rather than step back a byte.
                self.line(f"{dst()} = {a(0)} + {self._as_index(ins.args[1])}")

            # ── calls ───────────────────────────────────────────────────────
            case Op.CALL:
                self._call(ins, _callee(ins.sym or "", self.module))
            case Op.CALL_PTR:
                self._call(ins, f"RT.fn[{a(0)}]", skip_first=True)

            case _:  # pragma: no cover
                # Loud, at build time. A new opcode that emitted nothing would
                # produce a program wrong in a way no test names.
                raise NotImplementedError(
                    f"luau backend has no rule for {ins.op.value!r}")

    def _case_test(self, reg: int, value: int) -> str:
        """One arm of a `switch` ladder.

        Two things the obvious `r0 == 3` gets wrong. A 64-bit scrutinee has two
        locals and must be compared a half at a time. And case values arrive as
        signed Python ints while registers hold raw bit patterns, so a `case -1`
        on an i32 has to be matched against 4294967295 or it never fires.
        """
        assert self.fn is not None
        ty = self.fn.register_type(reg)
        if V.is_wide(ty):
            n = value % (1 << 64)
            return (f"{V.hi(reg)} == {n >> 32} and "
                    f"{V.lo(reg)} == {n & 0xFFFFFFFF}")
        return f"{V.name(reg, ty)} == {value % V.mask(ty)}"

    def _as_index(self, reg: int) -> str:
        """An integer register as a plain Luau number, sign applied.

        Used where a value is an amount rather than a bit pattern -- pointer
        arithmetic being the only such place in the opcode set. Everywhere else
        integers stay raw, which is what makes one rule per opcode possible.
        """
        assert self.fn is not None
        ty = self.fn.register_type(reg)
        if V.is_wide(ty):
            return (f"RT.to_number({V.hi(reg)}, {V.lo(reg)}, "
                    f"{str(ty.is_signed).lower()})")
        if ty.is_int and ty.is_signed and ty.bits > 1:
            return f"RT.sext({V.name(reg, ty)}, {ty.bits})"
        return V.name(reg, ty)

    def _bitcast(self, ins: Instruction) -> None:
        assert self.fn is not None
        src = self.fn.register_type(ins.args[0])
        ty = ins.ty
        dst = ", ".join(V.names(ins.dst, ty)) if ins.dst is not None else "_"
        arg = ", ".join(V.names(ins.args[0], src))
        if ty.is_float and src.is_int:
            self.line(f"{dst} = RT.bits_to_float({arg}, {ty.bits})")
        elif ty.is_int and src.is_float:
            self.line(f"{dst} = RT.float_to_bits({arg}, {src.bits})")
        elif ty.is_ptr and V.is_wide(src):
            # Our addresses are buffer offsets and always fit in 32 bits, so
            # the high half must be zero -- checked rather than dropped.
            self.line(f"{dst} = RT.ptr_from64({arg})")
        elif V.is_wide(ty) and src.is_ptr:
            self.line(f"{dst} = 0, {arg}")
        else:
            self.line(f"{dst} = {arg}")

    def _call(self, ins: Instruction, callee: str, *,
              skip_first: bool = False) -> None:
        assert self.fn is not None
        regs = ins.args[1:] if skip_first else ins.args
        args = []
        for r in regs:
            args.extend(V.names(r, self.fn.register_type(r)))
        call = f"{callee}({', '.join(args)})"
        if ins.dst is not None and not ins.ty.is_void:
            names = V.names(ins.dst, self.fn.register_type(ins.dst))
            self.line(f"{', '.join(names)} = {call}")
        else:
            self.line(call)


# ── naming and literals ─────────────────────────────────────────────────────

def _fname(sym: str) -> str:
    """A Luau name for an IR function. Prefixed so it cannot collide with a
    local the emitter generates, or with `RT`, `MEM` or `bit32`."""
    return "f_" + V.ident(sym)


def _gname(sym: str) -> str:
    return "g_" + V.ident(sym)


def _callee(sym: str, module: Module) -> str:
    """Where a call by name goes.

    A function the module defines is a local; anything else is external and
    lives on the runtime table. The runtime raises a named error for the
    `apy_*` entries it does not implement yet, so an unported builtin fails
    saying which one rather than as `attempt to call a nil value`.
    """
    fn = module.function(sym)
    if fn is not None and not fn.external:
        return _fname(sym)
    return f"RT.{V.ident(sym)}"


def _scalar(reg: int, fn: Function) -> str:
    """One narrow register by name, refusing a wide one."""
    return V.name(reg, fn.register_type(reg))


def _truthy(reg: int, fn: Function) -> str:
    """An i1 as a Luau condition. The IR stores it as 0 or 1, and Luau treats
    0 as true, so the comparison is not optional."""
    ty = fn.register_type(reg)
    if V.is_wide(ty):
        return f"(({V.hi(reg)} ~= 0) or ({V.lo(reg)} ~= 0))"
    return f"{V.name(reg, ty)} ~= 0"


def _f32(ty: T.Type, expr: str) -> str:
    """Round through f32 if the type is f32.

    Luau has no 32-bit float, so an `f32` operation computed in a double is too
    precise. `RT.f32` rounds by writing and reading a buffer, which is what the
    hardware would have done.
    """
    return f"RT.f32({expr})" if ty is T.F32 else expr


def _mem(direction: str, ty: T.Type) -> str:
    """The runtime accessor for a load or store of `ty`."""
    if ty.is_float:
        return f"{direction}f{ty.bits}"
    if V.is_wide(ty):
        return f"{direction}64"
    if ty.is_ptr:
        return f"{direction}ptr"
    return f"{direction}u{ty.bits if ty.bits > 1 else 8}"


def _literal(ty: T.Type, value) -> str:
    """A constant, as one Luau expression or as a high/low pair."""
    if ty.is_float:
        f = float(value if value is not None else 0.0)
        if f != f:
            return "(0/0)"
        if f - f != 0.0:
            return "math.huge" if f > 0 else "-math.huge"
        return repr(f)
    n = int(value if value is not None else 0)
    if V.is_wide(ty):
        n %= 1 << 64
        return f"{n >> 32}, {n & 0xFFFFFFFF}"
    return str(n % V.mask(ty))


def _bytes_literal(data: bytes) -> str:
    """Global initialiser bytes, as a Luau string.

    A string rather than a table: `buffer.writestring` copies it in one call,
    and a 4 KB table constructor is 4 KB of Luau the compiler has to parse and
    then execute one `settable` at a time.
    """
    out = []
    for b in data:
        if 32 <= b < 127 and b not in (0x22, 0x5C):
            out.append(chr(b))
        else:
            out.append(f"\\{b}")
    return '"' + "".join(out) + '"'


def _rindex(stack: list[tuple[int, bool]], value: int) -> int:
    """Position of the innermost scope standing for `value`, or -1."""
    for i in range(len(stack) - 1, -1, -1):
        if stack[i][0] == value:
            return i
    return -1

# No `register(LuauBackend())` here, deliberately. Registration is the
# manifest's job (`__init__.py`), and doing it at import time as well would
# register twice -- `backend.register` raises on a duplicate name, and an
# entry-point plugin that raises takes down every asmpython command, not just
# a build. Declaring beats doing: a manifest can be read without changing the
# compiler's state, which is what `asmpython plugin show` needs.
