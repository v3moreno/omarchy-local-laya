"""Request stats collector for omarchy-local-laya.

Auto-imported by the Python interpreter (site.py) whenever the plugin's
python/ directory is on PYTHONPATH — the generated systemd unit sets that
only for the laya.serve process, so nothing else is affected. Registers a
default on_predict_end hook that writes two files next to each other:

  LAYA_STATS_FILE  session counters (tokens, latency ring, per-model counts)
                   — reset by the backend on every `start`
  days.json        lifetime per-day rollup {req, tokens in/out, ms sum, err}
                   keyed by local date — the widget's activity grid

Every code path is wrapped: a stats bug must never fail a decision request.
"""
import json
import os
import tempfile
import threading
import time

_PATH = os.environ.get("LAYA_STATS_FILE")

if _PATH:
    _DAYS_PATH = os.path.join(os.path.dirname(_PATH), "days.json")
    _lock = threading.Lock()
    _lat = []
    _stats = {
        "started_at": int(time.time()),
        "requests": 0,
        "errors": 0,
        "input_tokens": 0,
        "output_tokens": 0,
        "models": {},
        "last_ms": None,
        "latencies": _lat,
    }

    def _atomic_write(path, payload):
        fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".tmp-")
        try:
            with os.fdopen(fd, "w") as f:
                json.dump(payload, f)
            os.replace(tmp, path)
        except BaseException:
            try:
                os.unlink(tmp)
            except OSError:
                pass

    def _read_json(path, fallback):
        try:
            with open(path) as f:
                return json.load(f)
        except BaseException:
            return fallback

    class _StatsHook:
        def on_predict_end(self, ctx):
            try:
                with _lock:
                    usage = getattr(ctx, "usage", None) or {}
                    itok = int(usage.get("input_tokens") or 0)
                    otok = int(usage.get("output_tokens") or 0)
                    elapsed = getattr(ctx, "elapsed_ms", None)
                    ms = round(float(elapsed), 1) if elapsed is not None else None
                    err = getattr(ctx, "error", None) is not None
                    model = getattr(ctx, "model", None) or "unknown"

                    _stats["requests"] += 1
                    if err:
                        _stats["errors"] += 1
                    _stats["input_tokens"] += itok
                    _stats["output_tokens"] += otok
                    if ms is not None:
                        _stats["last_ms"] = ms
                        _lat.append(ms)
                        if len(_lat) > 64:
                            del _lat[:-64]
                    _stats["models"][model] = _stats["models"].get(model, 0) + 1
                    _atomic_write(_PATH, dict(_stats, latencies=list(_lat)))

                    days = _read_json(_DAYS_PATH, {"days": {}})
                    entry = days["days"].setdefault(
                        time.strftime("%Y-%m-%d"),
                        {"r": 0, "in": 0, "out": 0, "ms": 0.0, "err": 0})
                    entry["r"] += 1
                    entry["in"] += itok
                    entry["out"] += otok
                    if ms is not None:
                        entry["ms"] += ms
                    if err:
                        entry["err"] += 1
                    _atomic_write(_DAYS_PATH, days)
            except BaseException:
                pass

    try:
        from laya.hooks import add_default_hook
        add_default_hook(_StatsHook())
    except BaseException:
        pass
