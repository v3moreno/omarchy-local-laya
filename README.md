# Local Laya for Omarchy

A local decision layer for your AI agents — the [laya](https://github.com/NandhaKishorM/laya)
daemon as an [Omarchy](https://omarchy.org) plugin: one-click install, a
generated systemd user unit, a bar widget with stats and lifecycle
controls, and MCP + hook wiring that puts laya in front of every coding
agent on the machine.

![Local Laya](preview.png)

## What is laya?

Laya is a small encoder model (ModernBERT-class checkpoints) that answers
**typed questions about text** — classify, route, filter, rank, pick,
score yes/no — in a single forward pass:

- **~20 ms on GPU, ~130 ms on CPU** per decision
- **zero generated tokens** — it returns calibrated probabilities, not prose
- **fully local** — plain HTTP on `127.0.0.1`, nothing leaves the machine

It doesn't write text; it *decides*. "Which of these files is relevant?",
"is this shell command dangerous?", "does this request need documents or
reasoning?", "is this email spam?" — each answer is one forward pass.

## Why it saves tokens

Every judgment an agent makes in its head is paid for in tokens: reading
files into context (input) and reasoning about them (output). Laya moves
those judgments off the LLM entirely:

- **Filter before reading** — `laya_filter` scores a whole doc set in one
  call (the bundled `serve.py` adds `POST /v1/systemone/batch`, so N files
  share one forward pass). The agent reads only the keeper instead of
  ingesting every candidate file.
- **Routing and triage for free** — task kind, needs-docs and
  needs-reasoning scores are one HTTP call, not a reasoning step.
- **Hard gates, not vibes** — where the agent supports hooks, doc reads
  stay blocked until laya scores a real file, bash commands scoring
  ≥ 0.85 dangerous are refused, and tool output is screened for prompt
  injection before it reaches the model.
- **Measured** — in the [ask-laya](https://github.com/v3moreno/ask-laya)
  smoke suite, a gated 2B local model filtered then read one file and
  finished doc tasks in 2–5 s, where the same model ungated burned ~3,900
  input tokens wandering for up to 300 s. Remote models save the same
  tokens — they're just billed for them.

## Who it's for

- **Vibe coders** — the agent checks before it acts: destructive commands
  get scored and blocked, document reads get filtered, injected
  instructions in file contents get flagged as DATA. Small local models
  stop thrashing because decisions they fumble become tool calls.
- **Agent harnesses** — one warm daemon serves every agent; no per-agent
  model loading. `omarchy-local-laya agents` wires Claude, Codex,
  OpenCode, Copilot, Hermes, Crush, Pi and OMP in one idempotent pass —
  MCP tools everywhere, blocking hooks/extensions where the agent
  supports them.
- **Regular AI users** — it's just HTTP. `curl -X POST /v1/systemone`
  from a shell script, or the `ask` CLI, gives you classification and
  yes/no scoring without a chat model in the loop at all.

## Bundles with ask-laya

The companion [ask-laya](https://github.com/v3moreno/ask-laya) repo
carries the agent-facing pieces: the `ask` zero-dependency CLI, the
`SKILL.md` prompt rules, and the native pi/omp and opencode extensions.
Clone it next to your laya folder (`~/Projects/ask-laya` beside
`~/Projects/local-laya`) and `omarchy-local-laya agents` picks it up
automatically — pi/omp get a blocking extension, opencode gets its
plugin, claude/hermes get gate hooks, and every MCP-capable agent gets
the `laya_*` tools.

## What the plugin does

- Generates `~/.config/systemd/user/omarchy-local-laya.service` from the
  configured folder and mode (`ExecStart=<folder>/laya-serve <mode>`).
- **Autostart** enables the unit for the user session — laya comes up at login.
- The bar widget shows state, uptime, port, loaded checkpoints and device
  (polled from `GET /health`), and offers **start / stop / restart**,
  a **cpu / gpu mode** switch (restarts the daemon), and an **autostart**
  toggle.
- **Installs laya for you**: with no `laya-serve` in the configured folder
  the widget shows an install card (`Install laya ›`), or run
  `omarchy-local-laya install` — it creates a venv, installs `laya[serve]`
  and `mcp` (uv when present, pip otherwise) and drops the bundled
  tooling (`laya-serve`, `serve.py`, `laya-mcp.py`, `laya-gate.py`,
  `laya-mcp-install`) in place. Existing files are never overwritten,
  so a real checkout keeps its own copies.
- **Agent wiring**: the bundled `laya-serve` runs the extended server
  (`serve.py`, which adds `POST /v1/systemone/batch`), and the
  `agents` verb runs `laya-mcp-install` — it registers the MCP proxy
  (`laya_status`, `laya_route`, `laya_filter`, `laya_triage`,
  `laya_yesno`, `laya_pick`, `laya_decide`) and installs the `laya-gate`
  hooks where the agent supports them. The More page's **AGENTS**
  section shows which of Claude, Codex, OpenCode, Copilot, Hermes,
  Crush, Pi and OMP are wired.
- **Updates**: `update` restores the pinned release (`uv sync` for uv
  projects, `uv pip`/`pip` for bare venvs); `update git` installs the
  pinned upstream commit.
- **Request stats**: the unit puts the plugin's `python/` on `PYTHONPATH`,
  so a `sitecustomize` hook accumulates per-session request count, errors,
  input/output tokens, latency (last + p50 of the last 64 calls), a
  cumulative-token series and per-checkpoint counts into
  `~/.local/state/omarchy/local-laya/stats.json`, plus a lifetime per-day
  rollup in `days.json`. Counters reset on `start`; days never do.
- **The widget** borrows the local-ai layout: a lifetime request grid with
  month labels and per-day hover, the daemon as a card with its cumulative
  token line, and a **More** page with the session graph, six figures
  (avg / p50 / errors / session / week / up), GPU telemetry (nvidia-smi),
  per-checkpoint request counts, and the mode / autostart / folder controls.
- If a manually-run `laya-serve` holds the port, the widget shows
  `external · pid N`; `start`/`stop`/`restart` release it (only when the
  listener is actually laya — a foreign service is left alone).
- `open log` tails `journalctl --user -fu omarchy-local-laya` in a terminal.

## Install

```sh
omarchy plugin add https://github.com/v3moreno/omarchy-local-laya --enable
```

Add the **Local Laya** widget to the bar (right section by default).

## Configuration

Defaults: folder `~/Projects/local-laya`, mode `cpu`, autostart off.

From the CLI (`~/.config/omarchy/plugins/v3moreno.local-laya/bin/omarchy-local-laya`):

```sh
omarchy-local-laya snapshot            # JSON state the widget draws
omarchy-local-laya start | stop | restart
omarchy-local-laya mode cpu            # or gpu — restarts if running
omarchy-local-laya folder ~/code/laya  # must contain an executable laya-serve
omarchy-local-laya autostart on|off
omarchy-local-laya install             # venv + laya[serve] + laya-serve into the folder
omarchy-local-laya update              # restore the pinned laya release
omarchy-local-laya update git          # install the pinned upstream commit
omarchy-local-laya agents              # wire MCP + hooks into every installed agent
omarchy-local-laya agents claude       # or a subset — output saved to agents.txt
omarchy-local-laya env                 # show <folder>/laya.env
omarchy-local-laya env LAYA_THREADS=8  # set a LAYA_* key (restarts if running)
omarchy-local-laya log
```

Config persists at `~/.local/state/omarchy/local-laya/config.json`. A
`LAYA_PORT` in the folder's `laya.env` overrides the per-mode port
(8123 cpu / 8124 gpu) used for the health probe.

## Tuning

`laya-serve` sources `<folder>/laya.env`, so any `LAYA_*` variable applies
(`env` verb edits it):

- `LAYA_THREADS` — torch intra-op threads for CPU inference; keep at or
  under physical cores (default here: 8).
- `LAYA_INTEROP=0` — disables the plugin's `torch.set_num_interop_threads(1)`
  pin. The pin is on by default because laya serves one forward pass per
  call, where upstream's own benchmarks measured idle inter-op parallelism
  costing ~12x latency.
- `LAYA_FAST=1` — runs each checkpoint on the TileLang fast path
  (`laya[fast]`, GPU only) via an `on_load` hook; needs
  `uv pip install --python .venv/bin/python "laya[fast]==0.3.20"` in the folder.
- `LAYA_CPU_AMP=bf16`, `LAYA_MODELS`, `LAYA_AUTO_TASK`, `LAYA_API_KEY` —
  pass through to `laya.serve` unchanged.

IPC:

```sh
qs ipc -n -p "$OMARCHY_PATH/shell" call v3moreno.local-laya menu
```

## Requirements

`systemctl --user`, `curl`, `jq` and `python3` (or `uv`, preferred). The
daemon itself comes from PyPI's `laya[serve]==0.3.20` with `mcp==2.2.0`
(both pinned per plugin release) — `install` fetches them, so no existing
checkout is required. An existing folder works too: point `folder` at
anything containing an executable `laya-serve` that takes `cpu`/`gpu`
(the [local-laya](https://github.com/v3moreno/local-laya) checkout works
as-is). The daemon's `GET /health` is used unauthenticated on
`127.0.0.1`.

## Uninstall

```sh
omarchy-local-laya stop
systemctl --user disable omarchy-local-laya.service
omarchy plugin remove v3moreno.local-laya
```

The generated unit (`~/.config/systemd/user/omarchy-local-laya.service`),
state (`~/.local/state/omarchy/local-laya/`) and the laya folder itself
can then be deleted safely.

## License

MIT
