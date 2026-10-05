#!/usr/bin/env python3
"""Runs the headless Godot tests and fails FAST.

A script with a parse or runtime error leaves headless Godot sitting idle forever, so every run is watched live:
the moment a script/parse/compile error appears the process is killed and the error shown. A test that stops
producing output is killed too (--idle, default 20 s), and each test has a hard cap (--cap, default 150 s).

  tools/run_tests.py                 all tests in tests/, in parallel
  tools/run_tests.py seams scoring   just those
  tools/run_tests.py --script /path/to/scratch.gd     any script, same rules (for benchmarks and experiments)
"""
import glob, os, re, signal, subprocess, sys, threading, time

GODOT = os.environ.get("GODOT", os.path.expanduser("~/Downloads/Godot_v4.7.2-stable_linux.x86_64"))
PROJECT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FATAL = re.compile(r"SCRIPT ERROR|Parse Error|Compile Error|Failed to load script|Compilation failed")
NOISE = re.compile(r"leaked|RID allocations|ObjectDB|resources still in use|at: (clear|cleanup|_free)|^Godot Engine|^\s*$|Vulkan|WARNING: ")

def run(name, args, idle, cap, full=False):
    """Returns (ok, summary lines); `full` keeps all of a passing run's output (for scratch scripts)."""
    start = time.time()
    proc = subprocess.Popen([GODOT, "--headless", "--path", PROJECT] + args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            text=True, preexec_fn=os.setsid, env={**os.environ, "SEED": os.environ.get("SEED", "")})
    lines, state = [], {"last": time.time(), "why": None}
    def reader():
        for line in proc.stdout:
            state["last"] = time.time()
            lines.append(line.rstrip())
            if FATAL.search(line) and not state["why"]:
                state["why"] = "script error"
                # let a few follow-up lines (the backtrace) arrive, then stop
                threading.Timer(0.4, lambda: kill(proc)).start()
    t = threading.Thread(target=reader, daemon=True)
    t.start()
    while proc.poll() is None:
        now = time.time()
        if now - state["last"] > idle and not state["why"]:
            state["why"] = "no output for %ds (hung)" % idle
            kill(proc)
        elif now - start > cap and not state["why"]:
            state["why"] = "over the %ds cap" % cap
            kill(proc)
        time.sleep(0.05)
    t.join(timeout=1)
    out = [l for l in lines if not NOISE.search(l)]
    bad = [l for l in out if "TEST FAILED" in l or re.search(r"\bFAILED\b", l)]
    if state["why"]:
        return False, ["%s: %s" % (name, state["why"])] + out[-12:]
    if proc.returncode != 0 or bad:
        return False, ["%s: failed (exit %s)" % (name, proc.returncode)] + (bad or out)[:14]
    return True, (out if full else [out[-1] if out else ""])

def kill(proc):
    try:
        os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
    except ProcessLookupError:
        pass

def refresh_class_cache():
    """New class_name scripts are unknown to other scripts until Godot re-imports; do it only when needed."""
    cache = os.path.join(PROJECT, ".godot", "global_script_class_cache.cfg")
    newest = max((os.path.getmtime(p) for p in glob.glob(PROJECT + "/scripts/*.gd")), default=0)
    if not os.path.exists(cache) or os.path.getmtime(cache) < newest:
        ok, info = run("import", ["--import"], idle=30, cap=90)
        if not ok:
            print("\n".join(info)); sys.exit(1)

def main():
    argv = sys.argv[1:]
    idle, cap = 20, 150
    if "--idle" in argv:
        i = argv.index("--idle"); idle = int(argv[i + 1]); del argv[i:i + 2]
    if "--cap" in argv:
        i = argv.index("--cap"); cap = int(argv[i + 1]); del argv[i:i + 2]
    refresh_class_cache()
    if argv[:1] == ["--script"]:
        ok, info = run(os.path.basename(argv[1]), ["--script", argv[1]], idle, cap, full=True)
        print("\n".join(info)); sys.exit(0 if ok else 1)
    names = argv or sorted(os.path.basename(p)[:-3] for p in glob.glob(PROJECT + "/tests/*.gd"))
    results, lock = {}, threading.Lock()
    def work(n):
        ok, info = run(n, ["--script", "res://tests/%s.gd" % n], idle, cap)
        with lock:
            results[n] = (ok, info)
            print(("PASS " if ok else "FAIL ") + n, flush=True)
    threads = [threading.Thread(target=work, args=(n,)) for n in names]
    for t in threads: t.start()
    for t in threads: t.join()
    failed = [n for n in names if not results[n][0]]
    for n in failed:
        print("\n--- %s ---\n%s" % (n, "\n".join(results[n][1])))
    print("\n%d/%d passed" % (len(names) - len(failed), len(names)))
    sys.exit(1 if failed else 0)

main()
