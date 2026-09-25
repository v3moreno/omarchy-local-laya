"""Request stats collector for omarchy-local-laya.

Auto-imported by the Python interpreter (site.py) whenever the plugin's
python/ directory is on PYTHONPATH — the generated systemd unit sets that
only for the laya.serve process, so nothing else is affected. Registers a
default on_predict_end hook that appends cumulative counters and a latency
ring to LAYA_STATS_FILE, read back by the widget's `snapshot`.

Every code path is wrapped: a stats bug must never fail a decision request.
"""
import json
import os
import tempfile
import threading
import time

_PATH = os.environ.get("LAYA_STATS_FILE")

if _PATH:
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

    def _write_locked():
        directory = os.path.dirname(_PATH)
        fd, tmp = tempfile.mkstemp(dir=directory, prefix=".stats-")
        try:
            with os.fdopen(fd, "w") as f:
                json.dump(dict(_stats, latencies=list(_lat)), f)
            os.replace(tmp, _PATH)
        except BaseException:
            try:
                os.unlink(tmp)
            except OSError:
                pass

    class _StatsHook:
        def on_predict_end(self, ctx):
            try:
                with _lock:
                    _stats["requests"] += 1
                    if getattr(ctx, "error", None) is not None:
                        _stats["errors"] += 1
                    usage = getattr(ctx, "usage", None) or {}
                    _stats["input_tokens"] += int(usage.get("input_tokens") or 0)
                    _stats["output_tokens"] += int(usage.get("output_tokens") or 0)
                    elapsed = getattr(ctx, "elapsed_ms", None)
                    if elapsed is not None:
                        ms = round(float(elapsed), 1)
                        _stats["last_ms"] = ms
                        _lat.append(ms)
                        if len(_lat) > 64:
                            del _lat[:-64]
                    model = getattr(ctx, "model", None) or "unknown"
                    _stats["models"][model] = _stats["models"].get(model, 0) + 1
                    _write_locked()
            except BaseException:
                pass

    try:
        from laya.hooks import add_default_hook
        add_default_hook(_StatsHook())
    except BaseException:
        pass
