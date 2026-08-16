"""Recovering structured control flow, for a target with no `goto`.

The IR's control flow is a graph: `jump`, `branch` and `switch` name blocks by
label and any block may name any other. Luau has no `goto` and no labelled
`break`, so a backend cannot transcribe that graph. It has `if`, `while`,
`repeat`, and `break`/`continue` that bind to the INNERMOST enclosing loop --
and nothing else. This module turns the graph back into that.

WHY NOT A DISPATCH LOOP
-----------------------
The always-correct alternative is one `while true do ... end` around an
`if b == 0 then ... elseif b == 1 then ...` ladder, assigning `b` in place of
every branch. It is about forty lines and it is what a backend falls back to
when this module raises `Irreducible`.

It is not the default because Roblox compiles the SOURCE we emit. Every loop
that survives as a real `while` is a loop Luau's optimiser can see: it hoists
invariants out of it, it fuses the comparison into the jump, it keeps values in
registers across it. A dispatch ladder hides all of that behind an integer
compare per block edge, and hides it from an optimiser we do not own and cannot
patch. Emitting structure is the only chance we get to hand Luau something it
can work with.

THE ALGORITHM
-------------
Ramsey, "Beyond Relooper: Recursive Translation of Unstructured Control Flow to
Structured Control Flow" (ICFP 2022). It walks the DOMINATOR TREE rather than
discovering regions by pattern-matching the way Emscripten's original relooper
does, which makes it short enough to read in one sitting and removes the whole
category of "the pattern matcher did not recognise this shape" bug.

Two facts drive every decision:

  * A block that is the target of a BACK EDGE is a loop header. Its translation
    is wrapped in a loop scope, and a branch to it is a `continue`.
  * A block with two or more FORWARD predecessors is a merge point. It cannot
    be inlined at either predecessor, so it is placed after a block scope that
    encloses everything branching to it, and a branch to it is a `break`.

Everything else -- one forward predecessor, no back edge -- is dominated by
that predecessor and is emitted inline at the branch. That is the common case,
and it is why the output looks like code a person wrote.

WHY MERGE CHILDREN NEST LATEST-OUTERMOST
----------------------------------------
`_node_within` opens a block scope per merge child, and the order is not a
detail: a block may only branch FORWARD to a scope that encloses it. Sorting
the merge children by reverse-postorder position descending puts the latest one
outermost, so anything emitted earlier -- including the subtrees of the earlier
merge children -- sits inside it and can reach it. Sorting the other way
produces a tree that is well-formed and in which some branches have no scope to
name, which surfaces as a `KeyError` here rather than as bad Luau, but only on
the graphs that happen to exercise it.

WHAT COMES OUT
--------------
A tree of `Node`s. `LoopScope` and `BlockScope` carry an id; `Br` names the id
it targets. The emitter keeps its own stack of open scopes and turns a `Br`
into `break`, `continue`, or an unwind -- the protocol is specified below,
because the structurer and the emitter must agree on it exactly and two
documents that must agree are one document.

IRREDUCIBLE GRAPHS
------------------
A loop entered at two different blocks has no structured form without
duplicating code or adding a dispatch variable. `structure()` detects this and
raises `Irreducible`; the backend falls back to a dispatch loop for that one
function, and the rest of the module is unaffected.

Python cannot produce one -- it has no `goto`, so every CFG built from
`while`/`for`/`if`/`try`/`break`/`continue` is reducible -- so this is a path
for hand-written IR and for future passes that rewrite edges, not something the
Python frontend reaches. It is detected rather than assumed because "cannot
happen" and "is not checked" together is how a backend emits silently wrong
code.

THE UNWIND PROTOCOL
-------------------
Luau's `break` leaves the innermost enclosing loop, and both scope kinds are
loops to Luau (`BlockScope` emits `repeat ... until true`). So a `Br` whose
target is the innermost open scope is one keyword:

    Br -> BlockScope at depth 0     `break`      -- land after the scope's end
    Br -> LoopScope  at depth 0     `continue`   -- land at the loop's top

Crossing more than one scope needs a variable, because no single Luau keyword
will do it. The emitter declares `local esc = 0` in any function that needs
one, and:

  * to reach a `BlockScope` T at depth d, set `esc = <T>` and `break`. Every
    scope closing between here and T re-`break`s; T's own close clears `esc`.
    That is d+1 breaks in total.
  * to reach a `LoopScope` T at depth d, set `esc = <T>` and `break`. That is d
    breaks, landing INSIDE T, whose body then sees `esc == <T>`, clears it and
    `continue`s. A loop is re-entered at its top, never past its end, which is
    why the two kinds unwind a different number of levels.

`Structured.far_targets` names every scope id ever reached from depth > 0, so
the emitter emits unwind checks for those and nothing for the rest. A function
whose branches are all depth 0 -- the overwhelming majority -- gets no `esc`
variable and no checks at all.
"""
from __future__ import annotations

from dataclasses import dataclass, field

from asmpython.ir.cfg import ControlFlowGraph
from asmpython.ir.module import Function, Instruction, Register
from asmpython.ir.opcodes import Op


class Irreducible(Exception):
    """This function's CFG has no structured form.

    Carries the offending edges so a backend can report which ones forced the
    fallback, rather than only that something did.
    """

    def __init__(self, function: str, edges: list[tuple[str, str]]) -> None:
        self.function = function
        self.edges = edges
        listed = ", ".join(f"{a} -> {b}" for a, b in edges)
        super().__init__(
            f"{function}: irreducible control flow; "
            f"loop entered other than at its header via {listed}"
        )


# ── the output tree ─────────────────────────────────────────────────────────
# Deliberately not a single node type with a `kind` field. The emitter matches
# on these, and a match over a closed set of classes is checked by a type
# checker where a match over string tags is not.

class Node:
    """Base for the structured tree. Never instantiated."""

    __slots__ = ()


@dataclass(slots=True)
class Seq(Node):
    """Statements in order. Flattened on construction, so nothing nests
    pointlessly and the emitter never has to look through a one-element Seq."""

    items: list[Node] = field(default_factory=list)


@dataclass(slots=True)
class Code(Node):
    """Emit `block`'s instructions, excluding its terminator.

    The terminator became control flow and is represented by the nodes around
    this one; emitting it again would duplicate a jump.
    """

    block: int


@dataclass(slots=True)
class LoopScope(Node):
    """`while true do <body> end`. A `Br` here means `continue`.

    The loop never falls out of the bottom: every path through `body` ends in a
    terminator, so the emitter appends nothing. `header` is kept for readable
    output -- it names the block in a comment.
    """

    id: int
    header: int
    body: Node


@dataclass(slots=True)
class BlockScope(Node):
    """`repeat <body> until true`. A `Br` here means `break`.

    `repeat ... until true` rather than `while true do ... break end` because it
    is one construct that runs its body exactly once and that `break` leaves,
    with no way to accidentally loop if a path does fall through the bottom.
    """

    id: int
    target: int
    body: Node


@dataclass(slots=True)
class If(Node):
    """`if <cond> then <then_> else <else_> end`. `cond` is an i1 register."""

    cond: Register
    then_: Node
    else_: Node


@dataclass(slots=True)
class Switch(Node):
    """An if/elseif ladder on an integer register.

    Not a jump table: Luau has no `switch`, and a ladder is what the language
    offers. Left as one node rather than desugared here so the emitter can pick
    its own shape -- a dense ladder, or a table of closures if it ever pays.
    """

    value: Register
    cases: list[tuple[int, Node]]
    default: Node


@dataclass(slots=True)
class Br(Node):
    """Transfer to an enclosing scope. The emitter computes the depth.

    Depth is NOT stored: it is a property of where this node ends up, and the
    emitter walking its own scope stack always knows it. Storing it here would
    be a second copy of a fact the emitter already has, free to disagree with
    the first the moment anything rewrites the tree.
    """

    scope: int


@dataclass(slots=True)
class Ret(Node):
    """`return` -- with the terminator's operands, so the emitter names the
    registers without going back to the block."""

    args: list[Register] = field(default_factory=list)


@dataclass(slots=True)
class Unreachable(Node):
    """Control never arrives. The emitter traps."""

    block: int


@dataclass(slots=True)
class Structured:
    """One function's structured form, and what the emitter needs alongside."""

    root: Node
    #: Scope ids reached from depth > 0. The emitter needs these to know which
    #: `esc` values it must compare against.
    far_targets: set[int]
    #: Scope ids after whose close the emitter must emit an unwind check.
    #:
    #: NOT the same set as `far_targets`, and the difference is the whole
    #: reason both exist. An unwind BREAKS OUT OF every scope between the
    #: branch and its target, and each of those has to re-break as it closes --
    #: including scopes nothing ever targets. In a `break` out of two nested
    #: loops the inner loop is crossed by every escape and targeted by none, so
    #: an emitter driven by `far_targets` alone would let control fall into the
    #: code after it with `esc` still set.
    check_after: set[int]
    #: Blocks never emitted because nothing reaches them. Reported rather than
    #: dropped silently: unreachable IR usually means a frontend bug, and a
    #: backend that swallows it is where that bug goes to hide.
    unreachable: list[int]

    @property
    def needs_escape(self) -> bool:
        return bool(self.far_targets)


# ── the structurer ──────────────────────────────────────────────────────────

def structure(fn: Function, cfg: ControlFlowGraph | None = None) -> Structured:
    """Structured form of `fn`, or raise `Irreducible`.

    `cfg` is accepted so a caller that already built one does not pay for a
    second -- dominators are the expensive part and every backend stage wants
    them.
    """
    cfg = cfg or ControlFlowGraph.build(fn)
    if not fn.blocks:
        return Structured(Seq([]), set(), set(), [])
    return _Structurer(fn, cfg).run()


class _Structurer:
    """Holds the per-function state the recursion threads through.

    A class rather than nested functions with `nonlocal`: the recursion is deep
    enough on real code that the closure captures stop being obvious, and every
    piece of state here is read by more than one method.
    """

    def __init__(self, fn: Function, cfg: ControlFlowGraph) -> None:
        self.fn = fn
        self.cfg = cfg
        self.rpo = cfg.reverse_postorder
        #: RPO position, for "is this edge forward?". Only reachable blocks
        #: appear -- an unreachable one is never asked about because it is
        #: never visited.
        self.position = {b: i for i, b in enumerate(self.rpo)}
        self.back_edges = set(cfg.back_edges)
        self.headers = {head for _, head in self.back_edges}
        self.far_targets: set[int] = set()
        self.check_after: set[int] = set()
        #: The scopes open at the current point, innermost last, as
        #: (block, is_loop). Ids are block indices: every scope stands for
        #: exactly one block, so a separate counter would only be a second name
        #: for one. The kind rides alongside because a branch unwinds a
        #: different number of levels for each -- see the module docstring.
        self.stack: list[tuple[int, bool]] = []
        self._check_reducible()

    # ── the reducibility check ──────────────────────────────────────────────
    def _check_reducible(self) -> None:
        """Every retreating edge must be a back edge.

        A RETREATING edge goes to an earlier position in reverse postorder; a
        BACK edge additionally has its target dominating its source. Where the
        two sets differ, some loop is entered at a block that does not dominate
        it -- the definition of irreducible.
        """
        bad: list[tuple[str, str]] = []
        for i in self.rpo:
            for j in self.cfg.successors[i]:
                if j not in self.position:
                    continue
                retreating = self.position[j] <= self.position[i]
                if retreating and (i, j) not in self.back_edges:
                    bad.append((self.cfg.blocks[i].label,
                                self.cfg.blocks[j].label))
        if bad:
            raise Irreducible(self.fn.name, bad)

    # ── entry point ─────────────────────────────────────────────────────────
    def run(self) -> Structured:
        root = self._do_tree(self.rpo[0])
        return Structured(root, self.far_targets, self.check_after,
                          self.cfg.unreachable)

    # ── is this block a merge point? ────────────────────────────────────────
    def _forward_pred_count(self, node: int) -> int:
        """Predecessors reaching `node` other than by a back edge.

        Back edges are excluded because a loop header with one forward
        predecessor is not a merge: its body arrives by `continue`, which is
        the loop scope's job, not a block scope's. Counting them would wrap
        every loop header in a redundant `repeat ... until true`.
        """
        return sum(1 for p in self.cfg.predecessors[node]
                   if (p, node) not in self.back_edges and p in self.position)

    def _is_merge(self, node: int) -> bool:
        return self._forward_pred_count(node) >= 2

    # ── the dominator-tree walk ─────────────────────────────────────────────
    def _do_tree(self, node: int) -> Node:
        """Translate `node` and everything it dominates."""
        merges = sorted(
            (c for c in self.cfg.dominator_children.get(node, ())
             if self._is_merge(c)),
            key=lambda c: self.position[c],
            reverse=True,          # latest outermost -- see the module docstring
        )
        if node in self.headers:
            self.stack.append((node, True))
            body = self._node_within(node, merges)
            self.stack.pop()
            return LoopScope(id=node, header=node, body=body)
        return self._node_within(node, merges)

    def _node_within(self, node: int, merges: list[int]) -> Node:
        """`node`'s own code, wrapped in a block scope per pending merge child.

        Recursion rather than a loop because each scope has to enclose the
        translation of the next, and the innermost thing is `node` itself.
        """
        if not merges:
            return self._translate(node)
        head, rest = merges[0], merges[1:]
        self.stack.append((head, False))
        inner = self._node_within(node, rest)
        self.stack.pop()
        return Seq(_flatten([
            BlockScope(id=head, target=head, body=inner),
            self._do_tree(head),
        ]))

    # ── one block's terminator ──────────────────────────────────────────────
    def _translate(self, node: int) -> Node:
        term = self.cfg.blocks[node].terminator
        # verify() guarantees a terminator on every block, so this is a real
        # invariant and not a case to handle.
        assert term is not None, f"{self.fn.name}: block {node} has no terminator"
        body = Code(node)

        match term.op:
            case Op.JUMP:
                return Seq(_flatten([body, self._do_branch(node, term, 0)]))
            case Op.BRANCH:
                return Seq(_flatten([body, If(
                    cond=term.args[0],
                    then_=self._do_branch(node, term, 0),
                    else_=self._do_branch(node, term, 1),
                )]))
            case Op.SWITCH:
                return Seq(_flatten([body, Switch(
                    value=term.args[0],
                    cases=[(v, self._do_edge(node, label))
                           for v, label in term.cases],
                    default=self._do_branch(node, term, 0),
                )]))
            case Op.RET:
                return Seq(_flatten([body, Ret(list(term.args))]))
            case Op.UNREACHABLE:
                return Seq(_flatten([body, Unreachable(node)]))
            case _:  # pragma: no cover -- TERMINATORS is a closed set
                raise AssertionError(
                    f"{self.fn.name}: {term.op.value!r} is not a terminator")

    def _do_branch(self, source: int, term: Instruction, which: int) -> Node:
        return self._do_edge(source, term.labels[which])

    def _do_edge(self, source: int, label: str) -> Node:
        """One CFG edge: either a jump to a scope, or the target inlined here.

        This is the whole of Ramsey's `doBranch`, and the two questions it asks
        are the two facts in the module docstring.
        """
        target = self.cfg.index_of[label]
        backward = self.position[target] <= self.position[source]
        if backward or self._is_merge(target):
            return self._br(target)
        # Sole forward predecessor and no back edge: `source` dominates
        # `target`, so it can be emitted right here.
        return self._do_tree(target)

    def _br(self, target: int) -> Br:
        """A jump to the scope standing for `target`, recording what it crosses.

        The depth is not stored on the node -- the emitter recomputes it from
        its own stack -- but it IS measured here, because only the structurer
        sees every branch, and the question "does this function need an `esc`
        variable, and which scopes have to check it" is answerable only over
        all of them at once.
        """
        pos = _rindex(self.stack, target)
        if pos < 0:  # pragma: no cover -- a well-formed walk cannot
            raise AssertionError(
                f"{self.fn.name}: branch to {self.cfg.blocks[target].label} "
                f"with no scope open for it; merge children are mis-ordered"
            )
        top = len(self.stack) - 1
        depth = top - pos
        if depth == 0:
            # The innermost scope: one bare `break` or `continue`, no state.
            return Br(scope=target)

        self.far_targets.add(target)
        # Which scopes this unwind breaks out of. A loop is re-entered at its
        # top, so its own scope is NOT exited -- the branch lands inside it and
        # `continue`s. A block is left behind entirely, so it is. Getting this
        # boundary wrong is off-by-one in generated code: one level too few
        # leaves `esc` set inside a scope that then runs on, one too many skips
        # the code the branch was aiming at.
        _, target_is_loop = self.stack[pos]
        lowest = pos + 1 if target_is_loop else pos
        for i in range(lowest, top + 1):
            self.check_after.add(self.stack[i][0])
        return Br(scope=target)


# ── helpers ─────────────────────────────────────────────────────────────────

def _rindex(stack: list[tuple[int, bool]], value: int) -> int:
    """Position of the INNERMOST scope standing for block `value`, or -1.

    Innermost, not outermost: a block that is both a loop header and a merge
    point has two scopes open for it at once -- the block scope its dominator
    opened, and the loop scope wrapping its own body -- and a branch always
    means the nearer. Searching from the bottom finds the block scope, and the
    result is valid Luau that unwinds one level too far and skips the loop.
    """
    for i in range(len(stack) - 1, -1, -1):
        if stack[i][0] == value:
            return i
    return -1


def _flatten(items: list[Node]) -> list[Node]:
    """Splice nested `Seq`s and drop empty ones."""
    out: list[Node] = []
    for item in items:
        if isinstance(item, Seq):
            out.extend(_flatten(item.items))
        else:
            out.append(item)
    return out


# ── debugging ───────────────────────────────────────────────────────────────

def dump(node: Node, labels: list[str] | None = None, indent: int = 0) -> str:
    """A readable rendering of the tree, for tests and for `--print-structure`.

    Tests assert on this rather than on emitted Luau: it isolates a structuring
    bug from a code-generation bug, and the two fail in ways that look alike
    when the only observable is the final source.
    """
    def name(i: int) -> str:
        return labels[i] if labels else str(i)

    pad = "  " * indent
    match node:
        case Seq(items=items):
            return "\n".join(dump(i, labels, indent) for i in items)
        case Code(block=b):
            return f"{pad}code {name(b)}"
        case LoopScope(header=h, body=body):
            return (f"{pad}loop {name(h)}:\n"
                    f"{dump(body, labels, indent + 1)}")
        case BlockScope(target=t, body=body):
            return (f"{pad}block {name(t)}:\n"
                    f"{dump(body, labels, indent + 1)}")
        case If(cond=c, then_=t, else_=e):
            return (f"{pad}if %{c}:\n{dump(t, labels, indent + 1)}\n"
                    f"{pad}else:\n{dump(e, labels, indent + 1)}")
        case Switch(value=v, cases=cases, default=d):
            parts = [f"{pad}switch %{v}:"]
            for val, arm in cases:
                parts.append(f"{pad}  case {val}:")
                parts.append(dump(arm, labels, indent + 2))
            parts.append(f"{pad}  default:")
            parts.append(dump(d, labels, indent + 2))
            return "\n".join(parts)
        case Br(scope=s):
            return f"{pad}br {name(s)}"
        case Ret(args=args):
            return f"{pad}ret" + (f" %{args[0]}" if args else "")
        case Unreachable():
            return f"{pad}unreachable"
        case _:  # pragma: no cover
            raise AssertionError(f"no dump rule for {type(node).__name__}")
