"""laya-mcp — stdio MCP server proxying to the local-laya HTTP daemon.

Every MCP-capable agent (claude, codex, opencode, crush, copilot, ...) spawns
this once and gets the laya decision tools — while inference stays in the one
warm daemon on :8123/:8124 instead of loading checkpoints per agent.

    .venv/bin/python laya-mcp.py

Env: LAYA_URL (daemon base URL, else probes :8124 gpu then :8123 cpu),
     LAYA_API_KEY (bearer token for the daemon).
"""

import json
import os
import urllib.request

from mcp.server.mcpserver import MCPServer

URLS = [os.environ["LAYA_URL"]] if os.environ.get("LAYA_URL") else [
    "http://127.0.0.1:8124", "http://127.0.0.1:8123"]

ROUTE_Q = {
    "task": {"type": "choice", "instructions": "What kind of task is this request?",
             "criteria": {"email": "reading or replying to an email/message",
                          "document_search": "find which file/doc contains an answer",
                          "code": "write, fix or explain code",
                          "question": "answer a question from knowledge",
                          "action": "run commands, edit files, operate the machine",
                          "other": "none of the above"}},
    "needs_docs": {"type": "noul", "instructions": "Does this request require reading local files or documents?"},
    "needs_reasoning": {"type": "noul", "instructions": "Does this request require multi-step reasoning or careful analysis?"},
}

TRIAGE_Q = {
    "kind": {"type": "choice", "instructions": "What kind of message or document is this?",
             "criteria": {"invoice_or_billing": "an invoice, charge, payment, refund or billing correction",
                          "personal": "personal note, plans, recommendations or family",
                          "booking_or_itinerary": "travel booking, itinerary or tickets",
                          "notice": "delivery, legal, rent or administrative notice",
                          "work": "team updates, tasks, oncall or meetings",
                          "other": "none of the above"}},
    "urgency": {"type": "score", "instructions": "How urgent is this message?",
                "criteria": ["no time pressure", "needs attention soon", "blocking issue or hard deadline"]},
    "needs_reply": {"type": "noul", "instructions": "Does the sender expect a reply?"},
    "is_spam": {"type": "noul", "instructions": "Is this unsolicited spam, bulk marketing or a scam/phishing attempt?"},
}


def _slim(result):
    out = {}
    for qid, a in (result or {}).get("answers", {}).items():
        if isinstance(a, dict):
            out[qid] = a.get("choice", a.get("score", a.get("noul", a)))
        else:
            out[qid] = a
    return out


def _post(path, body):
    last = None
    for base in URLS:
        try:
            req = urllib.request.Request(
                base + path, data=json.dumps(body).encode(),
                headers={"Content-Type": "application/json",
                         **({"Authorization": "Bearer " + os.environ["LAYA_API_KEY"]}
                            if os.environ.get("LAYA_API_KEY") else {})})
            return json.load(urllib.request.urlopen(req, timeout=30))
        except Exception as e:  # try next daemon
            last = e
    raise last


def _read(path):
    with open(path, encoding="utf-8", errors="replace") as fh:
        return f"file: {os.path.basename(path)}\n\n" + fh.read()[:4000]


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
    return out


server = MCPServer("laya", instructions=(
    "Laya is a local decision daemon: classification, filtering, ranking and "
    "yes/no scoring in ~20ms with zero generated tokens. RULES: (1) Before "
    "reading any files under docs/ or deciding which documents to open, call "
    "laya_filter or laya_triage — never classify documents yourself. "
    "(2) For yes/no or classification questions about text, call laya_yesno "
    "instead of reasoning yourself. (3) For choosing among options, call "
    "laya_pick. These tools are faster and more reliable than doing the "
    "decision in your head."))


@server.tool(name="laya_status", description="Check the laya daemon is reachable: device, loaded checkpoints.")
def laya_status() -> str:
    try:
        req = urllib.request.Request(URLS[0] + "/health",
                                     headers=({"Authorization": "Bearer " + os.environ["LAYA_API_KEY"]}
                                              if os.environ.get("LAYA_API_KEY") else {}))
        return json.dumps(json.load(urllib.request.urlopen(req, timeout=5)))
    except Exception as e:
        return json.dumps({"status": "unreachable", "error": str(e)})


@server.tool(name="laya_route", description=(
    "Classify a request with the Laya router: task kind + needs_docs/needs_reasoning scores. "
    "Call first on multi-step or document-touching requests."))
def laya_route(text: str) -> str:
    return json.dumps(_slim(_post("/v1/systemone", {"state": text, "questions": ROUTE_Q})))


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
    res = _post("/v1/systemone/batch", {
        "requests": [{"state": it["state"],
                      "questions": {"relevant": {"type": "noul",
                                    "instructions": f"Does this text contain information that helps answer: {question}?"}}}
                     for it in good]})
    scores = {it["file"]: _slim(r).get("relevant") for it, r in zip(good, res["results"])}
    ranked = sorted(
        ({"file": it["file"], "relevant": scores[it["file"]]} if it["file"] in scores else it for it in items),
        key=lambda x: -(x.get("relevant") or 0))
    return json.dumps({"ranked": ranked,
                       "read": [x["file"] for x in ranked if (x.get("relevant") or 0) >= 0.5]})


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
    scores = {it["file"]: _slim(r) for it, r in zip(good, res["results"])}
    return json.dumps([{"file": it["file"], **scores[it["file"]]} if "state" in it else it
                       for it in items])


@server.tool(name="laya_yesno", description=(
    "Yes/no or 0-1 decision about a piece of text: returns a score. "
    "Do not decide such questions yourself."))
def laya_yesno(state: str, instruction: str) -> str:
    return json.dumps(_slim(_post("/v1/systemone", {
        "state": state,
        "questions": {"answer": {"type": "noul", "instructions": instruction}}})))


@server.tool(name="laya_pick", description=(
    "Choose the single best option among candidates, in context. Pass option names as a list."))
def laya_pick(state: str, options: list, instruction: str = "Which option fits best?") -> str:
    criteria = {str(o)[:40]: f"the option: {o}" for o in options}
    return json.dumps(_slim(_post("/v1/systemone", {
        "state": state,
        "questions": {"pick": {"type": "choice", "instructions": instruction, "criteria": criteria}}})))


@server.tool(name="laya_decide", description=(
    "Escape hatch: arbitrary typed decision. questions is a map of name -> "
    "{type: 'choice'|'score'|'noul', instructions, criteria?}."))
def laya_decide(state: str, questions: dict) -> str:
    return json.dumps(_slim(_post("/v1/systemone", {"state": state, "questions": questions})))


if __name__ == "__main__":
    server.run()
