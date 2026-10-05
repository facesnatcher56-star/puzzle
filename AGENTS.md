# Instructions for every agent working in this repo

## Running Godot: always through `tools/run_tests.py`

**Never run `godot --headless ... --script` directly, and never wait on a shell `timeout`.** A script with a parse or
runtime error leaves headless Godot sitting idle forever, so a bare run just burns minutes before the timeout fires.
`tools/run_tests.py` watches the output live: it **kills the process the instant a script/parse/compile error
appears**, kills a run that stops producing output (`--idle`, default 20 s), and enforces a hard cap per run
(`--cap`, default 150 s). Failures print the error and its backtrace at once.

```bash
tools/run_tests.py                       # every test in tests/, in parallel (about 30 s)
tools/run_tests.py seams scoring         # just those (names are tests/<name>.gd)
tools/run_tests.py --script /path/x.gd   # any scratch script (benchmarks, screenshots...) with the same fail-fast rules
tools/run_tests.py --idle 5 --cap 30 --script /path/x.gd    # tighter limits for a quick experiment
```

It exits non-zero if anything fails, so it can be used in a loop: fix, rerun the one failing test, then run everything.
It also re-imports the project by itself when a new `class_name` script has appeared (otherwise other scripts report
"Identifier X not declared").

Rules that follow from this:
- Keep scratch scripts **small and quick**: few iterations, no multi-minute benchmarks. If something needs a long
  loop, lower the count first and scale up only if it is fast. Put scratch files outside the repo (a temp dir).
- Windowed runs (screenshots, frame-rate checks) use `tools/run_tests.py --windowed --script x.gd` (needs a display, same
  fail-fast watchdog); the script must `quit()` on its own.
- On Windows the runner needs `GODOT` set to a `*_console.exe` build (e.g. unzip `Godot_v4.7-stable_win64.exe.zip`); it
  also looks in `~/Downloads`. Never fall back to a bare `timeout`: always use the runner so errors kill the run at once.
- When adding a test, make it `quit(1)` on any failure and call `quit()` when done, and never leave an `await`
  that can wait forever (use a deadline, as `tests/power_zones_network.gd` does).
- Tests that open network ports must use their own port (see the ports already used in `tests/*.gd`); they run in parallel.

## Project conventions

- Effect/UI sprites in `assets/fx/` are rendered by Blender: `blender -b -P tools/render_fx.py` (commit the PNGs). `UiStyle`
  (9-patch panels/buttons/gem) and `BoardFx` (ring, flash, rays, confetti, sparkles) are the only users of them.

- Godot 4.7, GDScript. The binary is `~/Downloads/Godot_v4.7.2-stable_linux.x86_64` (override with the `GODOT` env var).
- `scripts/main.gd` is only the composition root. Logic lives in controllers (`PuzzleSession`, `PuzzleBoard`,
  `PuzzleInputController`, `PowerController`, `ClusterSurgeController`, `RunScoring`, ...); presentation in views.
  Do not grow `main.gd`.
- Multiplayer is host-authoritative (`NetworkSession`). Anything that decides randomness, scoring or moves pieces runs
  only on the solo player or the host; clients are told what happened. Add a loopback test for new networked behaviour.
- Every change that touches puzzle geometry, snapping or scoring needs tests; `tests/seams.gd` checks every puzzle format
  and size for solvability, so run it after touching `PuzzleGenerator` or `PuzzleManager`.
- Saves must stay loadable: add new fields with defaults and read them with `.get(key, default)`.
- Commit only when asked. Commit messages end with the attribution line given by the session, and pushes go to `main`.
