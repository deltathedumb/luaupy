"""Put `tests/` on the import path.

The suite uses a flat `tests/` with no package, so `str_cases` and helpers in
`test_runtime_luau` are imported by name. Doing this here rather than with a
sys.path line inside each test keeps one copy of it -- and keeps it OUT of any
script run from another directory, where `tests` is a relative name that can
resolve to a different project's tests entirely. asmpython-refactor has its own
`tests/asmpython` package, and putting a bare "tests" on sys.path from the
wrong cwd shadows the real asmpython with it.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent / "tests"))
