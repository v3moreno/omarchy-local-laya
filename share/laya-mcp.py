"""laya-mcp — stdio MCP server proxying to the local-laya HTTP daemon.

Every MCP-capable agent (claude, codex, opencode, crush, copilot, ...) spawns
this once and gets the laya decision tools — while inference stays in the one
warm daemon on :8123/:8124 instead of loading checkpoints per agent.

    .venv/bin/python laya-mcp.py

Env: LAYA_URL (daemon base URL, else probes :8124 gpu then :8123 cpu),
     LAYA_API_KEY (bearer token; else read from laya.env next to this script).
"""

import json
import os
import urllib.request

from mcp.server.mcpserver import MCPServer

MAX_FILES = 64  # the daemon's batch limit

# questions + thresholds shared with laya-gate.py, the pi extension and ask CLI
with open(os.path.join(os.path.dirname(os.path.realpath(__file__)), "shared.json")) as _fh:
    SHARED = json.load(_fh)
ROUTE_Q = SHARED["route"]
TRIAGE_Q = SHARED["triage"]


def _own_listener(port):
    """True when a TCP listener on 127.0.0.1/::1:<port> belongs to this user —
    another local user's process squatting the default port must never see
    our prompts or answer for the daemon."""
    for table in ("/proc/net/tcp", "/proc/net/tcp6"):
        try:
            with open(table) as fh:
                rows = fh.read().splitlines()[1:]
        except OSError:
            continue
        for row in rows:
            f = row.split()
            if len(f) > 7 and f[3] == "0A" and int(f[1].rsplit(":", 1)[1], 16) == port \
                    and int(f[7]) == os.getuid():
                return True
    return False


def _urls():
    # an explicit LAYA_URL is the user's choice; the default ports must be ours
    if os.environ.get("LAYA_URL"):
        return [os.environ["LAYA_URL"]]
    return [f"http://127.0.0.1:{p}" for p in (8124, 8123) if _own_listener(p)]


def _api_key():
    # env first; else the laya.env next to this script (laya-serve generates
    # the key there, 0600, so only this uid can read it back)
    if os.environ.get("LAYA_API_KEY"):
        return os.environ["LAYA_API_KEY"]
    try:
        env = os.path.join(os.path.dirname(os.path.realpath(__file__)), "laya.env")
        with open(env) as fh:
            for line in fh:
                k, _, v = line.partition("=")
                if k.strip() == "LAYA_API_KEY":
                    return v.strip()
    except OSError:
        pass
    return None


def _answers(result, questions):
    """Only typed values reach the agent: a choice must be one of the question's
    criteria keys, a score/noul must be a number. Anything else becomes None,
    so a misbehaving daemon can't smuggle text into the agent's context."""
    ans = result.get("answers") if isinstance(result, dict) else None
    ans = ans if isinstance(ans, dict) else {}
    out = {}
    for qid, q in questions.items():
        a = ans.get(qid)
        v = a.get("choice", a.get("score", a.get("noul"))) if isinstance(a, dict) else a
        crit = q.get("criteria") if isinstance(q, dict) else None
        if isinstance(q, dict) and q.get("type") == "choice":
            out[qid] = v if isinstance(v, str) and isinstance(crit, dict) and v in crit else None
        else:
            out[qid] = float(v) if isinstance(v, (int, float)) and not isinstance(v, bool) else None
    return out


def _post(path, body):
    last = OSError("no laya daemon owned by this user on :8124/:8123 (set LAYA_URL to override)")
    for base in _urls():
        try:
            req = urllib.request.Request(
                base + path, data=json.dumps(body).encode(),
                headers={"Content-Type": "application/json",
                         **({"Authorization": "Bearer " + _api_key()}
                            if _api_key() else {})})
            return json.load(urllib.request.urlopen(req, timeout=30))
        except Exception as e:  # try next daemon
            last = e
    raise last


def _results(res):
    r = res.get("results") if isinstance(res, dict) else None
    return r if isinstance(r, list) else []


def _read(path):
    # regular files only: opening a fifo/device could block the server forever
    if not os.path.isfile(path):
        raise OSError("not a regular file")
    with open(path, encoding="utf-8", errors="replace") as fh:
        return f"file: {os.path.basename(path)}\n\n" + fh.read(4000)


def _expand(files):
    """Expand globs and ~ in the files list; keep order, drop dupes.
    Empty/None defaults to docs/* — models fumble glob arrays often."""
    import glob as _g
    if not files:
        files = ["docs/*"]
    out, seen = [], set()
    for f in files or []:
        hits = sorted(_g.glob(os.path.expanduser(str(f)))) if _g.has_magic(str(f)) else [os.path.expanduser(str(f))]
        for h in hits or [os.path.expanduser(str(f))]:
            if h not in seen:
                seen.add(h)
                out.append(h)
                if len(out) >= MAX_FILES:
                    return out
    return out


server = MCPServer("laya", instructions=(
    "Laya is a local decision daemon: classification, filtering, ranking and "
    "yes/no scoring in ~20ms with zero generated tokens. RULES: (1) Before "
    "reading any files under docs/, call laya_filter with the user's question "
    "— only files it keeps can be read. To say what documents are, call "
    "laya_triage — never classify documents yourself. "
    "(2) For yes/no or classification questions about text, call laya_yesno "
    "instead of reasoning yourself. (3) For choosing among options, call "
    "laya_pick. These tools are faster and more reliable than doing the "
    "decision in your head."))


@server.tool(name="laya_status", description="Check the laya daemon is reachable: device, loaded checkpoints.")
def laya_status() -> str:
    try:
        urls = _urls()
        if not urls:
            raise OSError("no laya daemon owned by this user on :8124/:8123")
        req = urllib.request.Request(urls[0] + "/health",
                                     headers=({"Authorization": "Bearer " + _api_key()}
                                              if _api_key() else {}))
        h = json.load(urllib.request.urlopen(req, timeout=5))
        h = h if isinstance(h, dict) else {}
        loaded = h.get("loaded") if isinstance(h.get("loaded"), list) else []
        # fixed shape, bounded strings: health text never reaches the agent verbatim
        return json.dumps({"status": "ok" if h.get("status") == "ok" else "unexpected",
                           "device": str(h.get("device", ""))[:16],
                           "loaded": [str(m)[:40] for m in loaded[:16]]})
    except Exception as e:
        return json.dumps({"status": "unreachable", "error": str(e)[:200]})


@server.tool(name="laya_route", description=(
    "Classify a request with the Laya router: task kind + needs_web/needs_docs/needs_reasoning scores. "
    "Call first on multi-step or document-touching requests."))
def laya_route(text: str) -> str:
    return json.dumps(_answers(_post("/v1/systemone", {"state": text, "questions": ROUTE_Q}), ROUTE_Q))


@server.tool(name="laya_filter", description=(
    "Score which of the given file paths are relevant to a question (0-1, ranked). "
    "Pass file paths, not contents — the server reads them. Only open files listed under 'read'."))
def laya_filter(question: str, files: list) -> str:
    items = []
    for f in _expand(files):
        try:
            items.append({"file": f, "state": _read(f)})
        except OSError as e:
            items.append({"file": f, "error": str(e)})
    good = [it for it in items if "state" in it]
    if not good:
        return json.dumps({"ranked": items, "read": []})
    q = {"relevant": {"type": "noul", "instructions": SHARED["relevant"].format(question=question)}}
    res = _post("/v1/systemone/batch", {"requests": [{"state": it["state"], "questions": q} for it in good]})
    scores = {it["file"]: _answers(r, q)["relevant"] for it, r in zip(good, _results(res))}
    ranked = sorted(
        ({"file": it["file"], "relevant": scores[it["file"]]} if it["file"] in scores else it for it in items),
        key=lambda x: -(x.get("relevant") or 0))
    return json.dumps({"ranked": ranked,
                       "read": [x["file"] for x in ranked if (x.get("relevant") or 0) >= SHARED["keep"]]})


@server.tool(name="laya_triage", description=(
    "Classify document files without reading them: per file returns kind, urgency, "
    "needs_reply, is_spam. Pass file paths. Never classify documents yourself."))
def laya_triage(files: list) -> str:
    items = []
    for f in _expand(files):
        try:
            items.append({"file": f, "state": _read(f)})
        except OSError as e:
            items.append({"file": f, "error": str(e)})
    good = [it for it in items if "state" in it]
    res = _post("/v1/systemone/batch",
                {"requests": [{"state": it["state"], "questions": TRIAGE_Q} for it in good]}) if good else {"results": []}
    scores = {it["file"]: _answers(r, TRIAGE_Q) for it, r in zip(good, _results(res))}
    return json.dumps([{"file": it["file"], **scores[it["file"]]} if "state" in it else it
                       for it in items])


@server.tool(name="laya_yesno", description=(
    "Yes/no or 0-1 decision about a piece of text: returns a score. "
    "Do not decide such questions yourself."))
def laya_yesno(state: str, instruction: str) -> str:
    q = {"answer": {"type": "noul", "instructions": instruction}}
    return json.dumps(_answers(_post("/v1/systemone", {"state": state, "questions": q}), q))


@server.tool(name="laya_pick", description=(
    "Choose the single best option among candidates, in context. Pass option names as a list."))
def laya_pick(state: str, options: list, instruction: str = "Which option fits best?") -> str:
    criteria = {str(o)[:40]: f"the option: {o}" for o in options}
    q = {"pick": {"type": "choice", "instructions": instruction, "criteria": criteria}}
    return json.dumps(_answers(_post("/v1/systemone", {"state": state, "questions": q}), q))


@server.tool(name="laya_decide", description=(
    "Escape hatch: arbitrary typed decision. questions is a map of name -> "
    "{type: 'choice'|'score'|'noul', instructions, criteria?}."))
def laya_decide(state: str, questions: dict) -> str:
    if not isinstance(questions, dict):
        return json.dumps({"error": "questions must be an object"})
    return json.dumps(_answers(_post("/v1/systemone", {"state": state, "questions": questions}), questions))


if __name__ == "__main__":
    server.run()
