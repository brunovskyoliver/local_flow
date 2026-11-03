#!/usr/bin/env python3
"""Server-side rewrite cold-start and warm-latency measurement (028 research R4).

Starts its own MTPLX on 127.0.0.1:18100 from the installed LocalAI venv with the
shipped flags and environment (read only: model-path, api-key), and its own
`flowd serve` on 127.0.0.1:18101. Never touches the production agents and
refuses to run while anything answers on 127.0.0.1:8000.

Modes:
  default            --runs N cold runs. Each starts MTPLX, polls flowd's
                     /v1/rewrite/health every 50 ms from spawn, sends one
                     rewrite as soon as it reports ready, then stops MTPLX
                     and waits until the process is gone.
  --warm             MTPLX stays up; one discarded rewrite, then --runs N
                     timed rewrites through flowd.
  --warm --session-header
                     Prefix-reuse probe (FR-004): rewrite-shaped requests
                     straight to MTPLX chat/completions with flowd's clean
                     system prompt, --runs N per phase (default 20), with and
                     without a constant X-MTPLX-Session-Id, each phase on a
                     fresh MTPLX. Reports median duration, cached tokens from
                     MTPLX's request log, and RSS/footprint before and after.

Run with python3 -I. Raw JSONL and a summary go to --out. Every process the
script starts is stopped on exit, error or Ctrl-C.
"""
import argparse
import json
import os
import re
import signal
import socket
import statistics
import subprocess
import sys
import time
import urllib.request
import uuid
from pathlib import Path

MTPLX_PORT = 18100
FLOWD_PORT = 18101
PROD_PORT = 8000
POLL = 0.05
STATE = Path.home() / "Library/Application Support/LocalFlow/LocalAI"
REPO = Path(__file__).resolve().parent.parent

# About 3 s of speech, 41 words, no names, numbers or disfluency cues, so the
# shield and the spoken rules leave it alone.
FIXTURE = (
    "The quarterly report draft is ready for review. Please read the summary section first and "
    "check whether each chart matches its figures in the appendix. Send any comments before Friday "
    "afternoon, because the printer needs our final version early next week."
)
VARIED = [
    "Please move the weekly planning meeting to the larger room on the second floor because more people are joining this time and the projector there works better.",
    "The new build fixes the crash on startup but the settings page still loads slowly so we should profile it before the release goes out to testers.",
    "Can you check whether the backup job finished last night and let me know if any of the folders were skipped or reported errors in its log.",
    "I think the onboarding flow is too long for most people so let's cut the third screen and move its explanation into a short tooltip instead.",
    "Remind everyone that the office will be closed on Monday for maintenance and that remote access should keep working during the whole day.",
    "The garden needs watering twice a week during summer so please set up the timer for early morning when it is still cool outside.",
    "We should compare both suppliers on price delivery time and support quality before signing anything because last year we picked too quickly.",
    "Our team agreed to keep the old API for six more months while clients migrate and after that we will remove it completely.",
    "Please book a table for four people at that restaurant near the station for Thursday evening and ask if they have vegetarian options.",
    "The library will extend its opening hours during exam season so students can study late and borrow laptops until ten in the evening.",
    "When you finish the translation send it over and I will review the terminology section before we share anything with our partners.",
    "Heating in our north wing keeps switching off overnight, so maintenance should inspect its thermostat and replace that unit when necessary.",
    "Let's write down the decisions from today's call and post them in our project channel so nobody has to rely on memory later.",
    "My flight lands around noon so I can join the afternoon workshop but I will probably miss lunch with everyone else.",
    "The website contact form sends duplicate emails whenever someone presses submit twice so we need to disable that button after the first click.",
    "Please order more printer paper and blue pens for the reception desk because we are almost out and the next delivery is weeks away.",
    "The survey results show that most customers want faster shipping more than lower prices so our next campaign should focus on delivery speed.",
    "Could someone update the wiki page about deployment since the steps changed after we moved to the new hosting provider in spring.",
    "The kids' swimming lessons start next month on Saturday mornings so we need to pack towels goggles and snacks the evening before.",
    "Before the demo tomorrow make sure the laptop is charged the slides are on a USB stick and the projector cable fits.",
]

# Same as apps/macos/LocalFlow/Resources/LocalAI/localflow-mtplx.
MTPLX_ENV = {
    "MTPLX_CLEAR_CACHE_AFTER_REQUEST": "always",
    "MTPLX_MLX_CACHE_LIMIT": "268435456",
    "MTPLX_SESSION_BANK_MAX_ENTRIES": "1",
    "MTPLX_SESSION_BANK_MAX_BYTES": "512M",
    "MTPLX_SESSION_BANK_PER_SESSION_BYTES": "512M",
}
MTPLX_FLAGS = [
    "--model-id", "localflow", "--scheduler-mode", "serial", "--batching-preset", "latency",
    "--ssd-session-cache", "off", "--context-window", "32768", "--fan-mode", "default",
    "--reasoning", "off", "--adaptive-policy", "expected_value", "--no-stats-footer",
    "--unsafe-force-unverified", "--yes",
]

# No proxy from the environment: everything here is loopback.
HTTP = urllib.request.build_opener(urllib.request.ProxyHandler({}))
children = []


class ProductionUp(Exception):
    pass


def log(msg):
    print(msg, flush=True)


def port_open(port):
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=0.2):
            return True
    except OSError:
        return False


def production_up():
    return port_open(PROD_PORT)


def spawn(argv, env, logpath):
    out = open(logpath, "ab")
    p = subprocess.Popen(argv, env=env, stdin=subprocess.DEVNULL, stdout=out, stderr=subprocess.STDOUT,
                         start_new_session=True)
    out.close()
    children.append(p)
    return p


def stop(p, timeout=60):
    """TERM the process group, wait until every member is gone, KILL after timeout."""
    if p is None:
        return
    try:
        os.killpg(p.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        p.poll()
        if p.returncode is not None and not group_alive(p.pid):
            break
        time.sleep(POLL)
    else:
        try:
            os.killpg(p.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        p.wait()
    if p in children:
        children.remove(p)


def group_alive(pgid):
    try:
        os.killpg(pgid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def cleanup(*_):
    for p in list(children):
        stop(p, timeout=20)


def read_secret():
    token = (STATE / "api-key").read_text().strip()
    if not token:
        sys.exit("empty api-key")
    return token


def start_mtplx(ladder, logdir):
    model = (STATE / "model-path").read_text().strip()
    env = {k: v for k, v in os.environ.items() if not k.startswith("MTPLX_")}
    env.update(MTPLX_ENV)
    if ladder == "512":
        env["MTPLX_WARMUP_LADDER"] = "512"
    argv = [str(STATE / "venv/bin/mtplx"), "serve", "--host", "127.0.0.1", "--port", str(MTPLX_PORT),
            "--model", model, "--api-key-file", str(STATE / "api-key"), *MTPLX_FLAGS]
    t0 = time.monotonic()
    return spawn(argv, env, logdir / "mtplx.log"), t0


def start_flowd(flowd, token, logdir):
    env = {k: v for k, v in os.environ.items() if not k.startswith("LOCALFLOW_")}
    env["LOCALFLOW_BACKEND_TOKEN"] = token
    argv = [flowd, "serve", "--listen", f"127.0.0.1:{FLOWD_PORT}",
            "--backend", f"http://127.0.0.1:{MTPLX_PORT}/v1", "--model", "localflow",
            "--log-file", str(logdir / "flowd-request.log")]
    p = spawn(argv, env, logdir / "flowd.log")
    deadline = time.monotonic() + 10
    while not port_open(FLOWD_PORT):
        if p.poll() is not None or time.monotonic() > deadline:
            sys.exit("flowd did not start; see flowd.log")
        time.sleep(POLL)
    return p


def health_state():
    try:
        with HTTP.open(f"http://127.0.0.1:{FLOWD_PORT}/v1/rewrite/health", timeout=5) as r:
            return json.load(r).get("backend", {}).get("state", "?")
    except Exception:
        return "error"


def rewrite(text, mode="clean"):
    body = json.dumps({"schema_version": 1, "request_id": str(uuid.uuid4()), "mode": mode, "text": text,
                       "language_hints": ["en"], "stream_deltas": False}).encode()
    req = urllib.request.Request(f"http://127.0.0.1:{FLOWD_PORT}/v1/rewrite", data=body, method="POST",
                                 headers={"Content-Type": "application/json"})
    t = time.monotonic()
    result = {"ok": False}
    try:
        with HTTP.open(req, timeout=60) as r:
            for line in r:
                ev = json.loads(line)
                if ev.get("event") == "result":
                    result = {"ok": True, "timing": ev.get("timing"), "unchanged": ev.get("unchanged"),
                              "output_words": len(ev.get("text", "").split())}
                elif ev.get("event") == "error":
                    result = {"ok": False, "code": ev.get("code")}
    except urllib.error.HTTPError as e:
        result = {"ok": False, "code": f"http_{e.code}"}
    except Exception as e:
        result = {"ok": False, "code": type(e).__name__}
    result["request_s"] = time.monotonic() - t
    return result


def wait_mtplx_models(token, timeout=180):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            req = urllib.request.Request(f"http://127.0.0.1:{MTPLX_PORT}/v1/models",
                                         headers={"Authorization": "Bearer " + token})
            with HTTP.open(req, timeout=2) as r:
                for m in json.load(r).get("data", []):
                    if m.get("id") == "localflow":
                        return bool((m.get("capabilities") or {}).get("json_schema"))
        except Exception:
            pass
        time.sleep(POLL)
    raise RuntimeError("MTPLX never listed localflow")


def wait_flowd_ready(timeout=180):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if health_state() == "ready":
            return
        time.sleep(POLL)
    raise RuntimeError("flowd never reported ready")


def wait_flowd_not_ready(timeout=15):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if health_state() != "ready":
            return
        time.sleep(POLL)
    raise RuntimeError("flowd still reports ready with MTPLX stopped")


def rss_kb(pgid):
    out = subprocess.run(["ps", "-A", "-o", "pgid=,rss="], capture_output=True, text=True).stdout
    return sum(int(r) for g, r in (l.split() for l in out.splitlines() if l.strip()) if int(g) == pgid)


def footprint_mb(pid):
    out = subprocess.run(["footprint", "-p", str(pid)], capture_output=True, text=True).stdout
    m = re.search(r"Footprint: ([\d.]+) (KB|MB|GB)", out)
    if not m:
        return None
    return float(m.group(1)) * {"KB": 1 / 1024, "MB": 1, "GB": 1024}[m.group(2)]


def stats(xs):
    xs = [x for x in xs if x is not None]
    if not xs:
        return None
    return {"n": len(xs), "median": statistics.median(xs), "min": min(xs), "max": max(xs)}


def fmt(s, scale=1000, unit="ms"):
    if not s:
        return "n/a"
    return f"median {s['median'] * scale:.0f} {unit} (range {s['min'] * scale:.0f}-{s['max'] * scale:.0f}, n={s['n']})"


def cold(args, token, out, raw):
    flowd = start_flowd(args.flowd, token, out)
    runs, discarded = [], []
    i = 0
    while len(runs) < args.runs:
        i += 1
        if production_up():
            raise ProductionUp(f"before run {i}")
        wait_flowd_not_ready()
        mtplx, t0 = start_mtplx(args.ladder, out)
        t_port = t_ready = None
        try:
            deadline = t0 + 180
            while time.monotonic() < deadline:
                if t_port is None and port_open(MTPLX_PORT):
                    t_port = time.monotonic()
                if health_state() == "ready":
                    t_ready = time.monotonic()
                    if t_port is None:
                        t_port = t_ready
                    break
                if mtplx.poll() is not None:
                    raise RuntimeError("MTPLX exited during start; see mtplx.log")
                time.sleep(POLL)
            if t_ready is None:
                raise RuntimeError("flowd never reported ready")
            res = rewrite(FIXTURE)
            t_end = time.monotonic()
        finally:
            stop(mtplx)
        run = {"run": i, "kind": "cold", "flowd": args.flowd, "ladder": args.ladder,
               "spawn_to_port_s": t_port - t0, "port_to_ready_s": t_ready - t_port,
               "spawn_to_ready_s": t_ready - t0, "total_s": t_end - t0, **res}
        if production_up():
            run["discarded"] = "production model on 8000 came up during the run"
            discarded.append(run)
        elif not res["ok"]:
            run["discarded"] = "rewrite failed"
            discarded.append(run)
        else:
            runs.append(run)
        raw.write(json.dumps(run) + "\n")
        raw.flush()
        log(f"cold {i}: port {run['spawn_to_port_s']:.3f}s ready+{run['port_to_ready_s']:.3f}s "
            f"request {res['request_s']:.3f}s total {run['total_s']:.3f}s ok={res['ok']} {run.get('discarded', '')}")
        if len(discarded) > args.runs:
            raise RuntimeError("too many discarded runs")
    stop(flowd)
    return {"mode": "cold", "runs": len(runs), "discarded": len(discarded),
            "discard_reasons": [d["discarded"] for d in discarded],
            "spawn_to_port_s": stats([r["spawn_to_port_s"] for r in runs]),
            "port_to_ready_s": stats([r["port_to_ready_s"] for r in runs]),
            "request_s": stats([r["request_s"] for r in runs]),
            "total_s": stats([r["total_s"] for r in runs])}


def warm(args, token, out, raw):
    flowd = start_flowd(args.flowd, token, out)
    mtplx, t0 = start_mtplx(args.ladder, out)
    runs = []
    try:
        wait_flowd_ready()
        first = rewrite(FIXTURE)
        raw.write(json.dumps({"kind": "warm-discarded-first", **first}) + "\n")
        for i in range(1, args.runs + 1):
            if production_up():
                raise ProductionUp(f"during warm run {i}")
            res = rewrite(FIXTURE)
            run = {"run": i, "kind": "warm", "flowd": args.flowd, "ladder": args.ladder, **res}
            raw.write(json.dumps(run) + "\n")
            raw.flush()
            log(f"warm {i}: request {res['request_s']:.3f}s ok={res['ok']}")
            if res["ok"]:
                runs.append(run)
    finally:
        stop(mtplx)
        stop(flowd)
    return {"mode": "warm", "runs": len(runs), "request_s": stats([r["request_s"] for r in runs])}


def system_prompt():
    """flowd's clean template, read from the Go source (raw string literals)."""
    src = (REPO / "server/internal/rewrite/prompts/prompts.go").read_text()
    common = re.search(r"const common = `([^`]*)`", src).group(1)
    m = re.search(r'"clean":\s*\{(\d+), common \+ `([^`]*)`\}', src)
    constrained = re.search(r'const ConstrainedInstruction = "([^"]*)"', src).group(1)
    return int(m.group(1)), common + m.group(2), constrained


def request_log_lines():
    path = Path.home() / f".mtplx/logs/request-log-{MTPLX_PORT}.jsonl"
    return path, (sum(1 for _ in path.open("rb")) if path.exists() else 0)


LOG_FIELDS = ("prompt_tokens", "cached_tokens", "new_prefill_tokens", "session_cache_hit",
              "cache_miss_reason", "ttft_s", "request_elapsed_s", "prompt_eval_time_s")


def direct(token, system, json_schema, text, session):
    payload = {"model": "localflow", "stream": True, "temperature": 0}
    if json_schema:
        payload["response_format"] = {"type": "json_schema", "json_schema": {
            "name": "rewrite_text", "strict": True, "schema": {"type": "string"}}}
    payload["messages"] = [{"role": "system", "content": system}, {"role": "user", "content": text}]
    headers = {"Authorization": "Bearer " + token, "Content-Type": "application/json",
               "Accept": "text/event-stream"}
    if session:
        headers["X-MTPLX-Session-Id"] = session
    req = urllib.request.Request(f"http://127.0.0.1:{MTPLX_PORT}/v1/chat/completions",
                                 data=json.dumps(payload).encode(), headers=headers, method="POST")
    t = time.monotonic()
    first = None
    with HTTP.open(req, timeout=60) as r:
        for line in r:
            line = line.strip()
            if not line.startswith(b"data:"):
                continue
            data = line[5:].strip()
            if data == b"[DONE]":
                break
            ev = json.loads(data)
            for c in ev.get("choices") or []:
                if (c.get("delta") or {}).get("content") and first is None:
                    first = time.monotonic() - t
    return {"request_s": time.monotonic() - t, "first_token_s": first}


def prefix(args, token, out, raw):
    version, base, constrained = system_prompt()
    session = f"lf-{version}-clean-u{args.user_id}"
    texts = (VARIED * ((args.runs + len(VARIED) - 1) // len(VARIED)))[:args.runs]
    phases = []
    # ABBA order across rounds, so drift over time doesn't favour one phase.
    order = [p for r in range(args.rounds) for p in (("none", "header") if r % 2 == 0 else ("header", "none"))]
    for n, phase in enumerate(order, 1):
        if production_up():
            raise ProductionUp(f"before phase {n}")
        mtplx, t0 = start_mtplx(args.ladder, out)
        try:
            json_schema = wait_mtplx_models(token)
            # Let the background warmup ladder finish so it doesn't land in request 1.
            time.sleep(args.settle)
            system = base + (constrained if json_schema else "")
            rss0, fp0 = rss_kb(mtplx.pid), footprint_mb(mtplx.pid)
            logpath, start_line = request_log_lines()
            reqs = []
            for i, text in enumerate(texts, 1):
                r = direct(token, system, json_schema, text, session if phase == "header" else None)
                reqs.append(r)
            time.sleep(1.0)
            rss1, fp1 = rss_kb(mtplx.pid), footprint_mb(mtplx.pid)
            entries = []
            if logpath.exists():
                with logpath.open() as f:
                    for k, line in enumerate(f):
                        if k >= start_line:
                            d = json.loads(line)
                            entries.append({key: d.get(key) for key in LOG_FIELDS})
            if production_up():
                raise ProductionUp(f"during phase {n}")
        finally:
            stop(mtplx)
        rec = {"phase": phase, "round": n, "session_id": session if phase == "header" else None,
               "json_schema": json_schema, "system_chars": len(system),
               "rss_mb_before": rss0 / 1024, "rss_mb_after": rss1 / 1024,
               "footprint_mb_before": fp0, "footprint_mb_after": fp1,
               "requests": reqs, "request_log": entries}
        raw.write(json.dumps(rec) + "\n")
        raw.flush()
        durs = [r["request_s"] for r in reqs]
        cached = [e["cached_tokens"] for e in entries]
        log(f"phase {n} {phase}: median {statistics.median(durs) * 1000:.0f} ms, median 2..N "
            f"{statistics.median(durs[1:]) * 1000:.0f} ms, cached tokens {cached}, "
            f"RSS {rss0 / 1024:.0f}->{rss1 / 1024:.0f} MB, footprint {fp0}->{fp1} MB")
        phases.append(rec)
    summary = {"mode": "prefix", "session_id": session, "phases": []}
    for phase in ("none", "header"):
        recs = [p for p in phases if p["phase"] == phase]
        durs = [r["request_s"] for p in recs for r in p["requests"]]
        rest = [r["request_s"] for p in recs for r in p["requests"][1:]]
        summary["phases"].append({
            "phase": phase, "rounds": len(recs), "request_s": stats(durs), "request_s_after_first": stats(rest),
            "first_token_s": stats([r["first_token_s"] for p in recs for r in p["requests"]]),
            "cached_tokens": stats([e["cached_tokens"] for p in recs for e in p["request_log"]]),
            "prompt_tokens": stats([e["prompt_tokens"] for p in recs for e in p["request_log"]]),
            "rss_growth_mb": [p["rss_mb_after"] - p["rss_mb_before"] for p in recs],
            "footprint_growth_mb": [(p["footprint_mb_after"] or 0) - (p["footprint_mb_before"] or 0) for p in recs],
            "rss_mb_after": [p["rss_mb_after"] for p in recs],
        })
    return summary


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--flowd", help="flowd binary (cold and --warm modes)")
    ap.add_argument("--ladder", choices=["default", "512"], default="512",
                    help="MTPLX warmup ladder: default leaves MTPLX_WARMUP_LADDER unset")
    ap.add_argument("--runs", type=int, default=10)
    ap.add_argument("--warm", action="store_true")
    ap.add_argument("--session-header", action="store_true", help="with --warm: prefix-reuse probe")
    ap.add_argument("--rounds", type=int, default=1, help="--session-header: rounds of both phases")
    ap.add_argument("--settle", type=float, default=5.0, help="--session-header: seconds after ready")
    ap.add_argument("--user-id", type=int, default=1, help="--session-header: user id in the session id")
    ap.add_argument("--label", default="")
    ap.add_argument("--out", required=True)
    args = ap.parse_args()
    if args.session_header and not args.warm:
        ap.error("--session-header needs --warm")
    if not args.session_header and not args.flowd:
        ap.error("--flowd is required")
    if production_up():
        sys.exit("127.0.0.1:8000 answers: the production model is up. Refusing to run.")
    for port in (MTPLX_PORT, FLOWD_PORT):
        if port_open(port):
            sys.exit(f"127.0.0.1:{port} is already in use.")
    out = Path(args.out).expanduser()
    out.mkdir(parents=True, exist_ok=True)
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    token = read_secret()
    mode = "prefix" if args.session_header else "warm" if args.warm else "cold"
    name = f"{mode}-{args.label or args.ladder}"
    meta = {"mode": mode, "flowd": args.flowd, "ladder": args.ladder, "runs": args.runs,
            "started": time.strftime("%Y-%m-%dT%H:%M:%S%z")}
    try:
        with open(out / f"{name}.jsonl", "a") as raw:
            raw.write(json.dumps({"meta": meta}) + "\n")
            fn = prefix if args.session_header else warm if args.warm else cold
            summary = fn(args, token, out, raw)
    except ProductionUp as e:
        summary = {"aborted": f"production model on 8000 came up {e}"}
    except KeyboardInterrupt:
        summary = {"aborted": "interrupted"}
    finally:
        cleanup()
    summary["meta"] = meta
    (out / f"{name}-summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    log(json.dumps(summary, indent=2))
    if mode != "prefix" and "aborted" not in summary:
        for key in ("spawn_to_port_s", "port_to_ready_s", "request_s", "total_s"):
            if key in summary:
                log(f"{key}: {fmt(summary[key])}")


if __name__ == "__main__":
    main()
