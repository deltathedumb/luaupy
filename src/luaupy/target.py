"""The Roblox platform description.

Most of these fields describe a machine, and Luau is not one: there are no
registers to allocate, no calling convention to get wrong, and no object format
to relocate. They are still filled in truthfully rather than left at their
defaults, because `asmpython targets` prints them and because a default that
happens to be harmless today is not a decision anyone recorded.

Two of them are load-bearing, and both would fail in a way that points at the
wrong thing.
"""
from __future__ import annotations

from asmpython.target import Target

#: Roblox, reached through Luau source.
ROBLOX = Target(
    name="roblox",

    # Identity only. Never sniffed -- `target/base.py` records that an earlier
    # version chose the calling convention with `"windows" in target.name` and
    # silently emitted System V code for anything else.
    arch="luau",

    # MUST NOT be "none". The link stage routes `os == "none"` to the baremetal
    # toolchain when no default_toolchain is set, and "roblox" keeps us out of
    # that branch even if the field below is ever cleared by accident.
    os="roblox",

    # A backend-defined convention name. There is nothing to vary: Luau's own
    # calling convention is the only one, so the backend reads this solely to
    # refuse a target it does not implement.
    abi="luau",

    # The documented value for a backend emitting another language. Be aware
    # this does NOT keep a C compiler away from the artifacts -- see
    # `default_toolchain` -- and its only real reader skips `-lm` for anything
    # that is not "elf".
    object_format="source",

    # These describe the IR's flat byte-addressed memory, which this backend
    # implements itself as a Luau `buffer`. They do not describe Luau, which
    # has no addressable memory at all. `ptr` is 64-bit in the IR type system
    # regardless of what is set here, so 8 keeps the layouts a frontend
    # computes consistent with every other target.
    pointer_size=8,
    little_endian=True,

    # No call boundary exists to align. Matches pointer_size so that a frontend
    # rounding a frame size to it produces the same numbers as elsewhere.
    stack_alignment=8,

    object_suffix=".luau",

    # LOAD-BEARING. `NoToolchain` computes
    #     directory = output.parent if output.suffix else output
    # so an EMPTY suffix makes `asmpython build hello.py --backend luau` write
    # the artifact tree into `hello/`. Setting ".luau" here would make the
    # output a file instead, and scatter every artifact into the source's
    # parent directory.
    executable_suffix="",

    # No C driver can produce a Roblox artifact.
    cc_names=(),

    # LOAD-BEARING, AND THE ONE FIELD THAT DECIDES WHETHER `cc` RUNS.
    #
    # `object_format="source"` reads like it should be enough and is not:
    # `Target.is_source` has one consumer in the whole tree, `CcToolchain
    # .supports`, whose body is `return not target.is_source or True` -- always
    # True -- and which nothing calls. `--toolchain` defaults to "cc", and the
    # link stage only overrides that default when the TARGET names a toolchain.
    #
    # Leave this empty and a plain `asmpython build hello.py --backend luau`
    # hands .luau files to gcc, which finds nothing it can compile and reports
    # "the backend produced nothing this toolchain can link" -- an error about
    # the backend, for a mistake in the target. The built-in JVM target sets
    # `default_toolchain="jar"` for exactly this reason.
    default_toolchain="none",
)

#: What else `--target` should accept. "luau" because that is the language and
#: the first thing anyone types; "rbx" because that is what Roblox's own
#: tooling abbreviates itself to.
ALIASES = ("luau", "rbx")
