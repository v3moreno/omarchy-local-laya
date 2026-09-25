# Local Laya

An [Omarchy](https://omarchy.org) plugin that runs the [laya](https://github.com/v3moreno/laya)
decision daemon from a folder — `laya-serve cpu` or `laya-serve gpu` — as a
generated systemd user unit, with status and lifecycle controls in the bar.

## What it does

- Generates `~/.config/systemd/user/omarchy-local-laya.service` from the
  configured folder and mode (`ExecStart=<folder>/laya-serve <mode>`).
- **Autostart** enables the unit for the user session — laya comes up at login.
- The bar widget shows state, uptime, port, loaded checkpoints and device
  (polled from `GET /health`), and offers **start / stop / restart**,
  a **cpu / gpu mode** switch (restarts the daemon), and an **autostart**
  toggle.
- **Request stats**: the unit puts the plugin's `python/` on `PYTHONPATH`,
  so a `sitecustomize` hook accumulates per-session request count, errors,
  input/output tokens and latency (last + p50 of the last 64 calls) per
  checkpoint into `~/.local/state/omarchy/local-laya/stats.json`, which the
  widget renders in the STATUS section. Counters reset on `start`.
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
omarchy-local-laya log
```

Config persists at `~/.local/state/omarchy/local-laya/config.json`. A
`LAYA_PORT` in the folder's `laya.env` overrides the per-mode port
(8123 cpu / 8124 gpu) used for the health probe.

IPC:

```sh
qs ipc -n -p "$OMARCHY_PATH/shell" call v3moreno.local-laya menu
```

## Requirements

A folder with an executable `laya-serve` script accepting `cpu`/`gpu`
(the [local-laya](https://github.com/v3moreno/laya) checkout works as-is),
plus `systemctl --user` and `curl`. The daemon's `GET /health` endpoint
is used unauthenticated on `127.0.0.1`.

## License

MIT
