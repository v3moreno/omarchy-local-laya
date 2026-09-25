// What the Local Laya widget shows, as data: the backend's snapshot and the widget's ui state in, a view out.
// Panel.qml draws the view and turns its actions ("verb|arg|arg") into backend verbs. No Qt, no side effects.

function k(n) {
  n = n || 0
  return n >= 1e6 ? Math.round(n / 1e5) / 10 + "M" : n >= 1e3 ? Math.round(n / 100) / 10 + "K" : String(n)
}
function ms(v) { return v == null ? "–" : v >= 1000 ? (v / 1000).toFixed(1) + " s" : Math.round(v) + " ms" }
function dur(s) {
  s = Math.max(0, Math.round(s))
  return s < 3600 ? Math.floor(s / 60) + "m" : Math.floor(s / 3600) + ":" + ("0" + Math.floor(s % 3600 / 60)).slice(-2) + "h"
}
// how long ago a unix time was, in the fewest words: now, 12m ago, 10h ago, 3d ago
function ago(t) {
  var s = Date.now() / 1000 - (t || 0)
  return s < 300 ? "now" : s < 3600 ? Math.round(s / 60) + "m ago" : s < 86400 ? Math.floor(s / 3600) + "h ago" : Math.floor(s / 86400) + "d ago"
}
function home(dir) { return (dir || "").replace(/^\/home\/[^\/]+/, "~") }
function up(v) { return (v || "cpu").toUpperCase() }

function parse(text) { try { return JSON.parse(text) } catch (e) { return null } }

// APCA-W3 0.1.9 lightness contrast (Lc) of text on a background. Colors are {r, g, b} in 0..1, as Qt gives them.
// Every text and line color in the panel is picked by the Lc it must reach, so any theme stays readable.
function lum(c) { return 0.2126729 * Math.pow(c.r, 2.4) + 0.7151522 * Math.pow(c.g, 2.4) + 0.072175 * Math.pow(c.b, 2.4) }
function apca(text, bg) {
  var t = lum(text), b = lum(bg)
  if (t < 0.022) t += Math.pow(0.022 - t, 1.414)
  if (b < 0.022) b += Math.pow(0.022 - b, 1.414)
  if (Math.abs(b - t) < 0.0005) return 0
  var s = b > t ? (Math.pow(b, 0.56) - Math.pow(t, 0.57)) * 1.14 : (Math.pow(b, 0.65) - Math.pow(t, 0.62)) * 1.14
  return Math.abs(s) < 0.1 ? 0 : (s > 0 ? s - 0.027 : s + 0.027) * 100
}
function mix(a, b, t) { return { r: a.r + (b.r - a.r) * t, g: a.g + (b.g - a.g) * t, b: a.b + (b.b - a.b) * t, a: 1 } }
// a translucent color as it lands on an opaque one
function over(c, bg) { var a = c.a === undefined ? 1 : c.a; return mix(bg, c, a) }
// the color closest to `from` on the way to `to` that reaches |Lc| >= target on bg; `to` when nothing does
function reach(from, to, bg, target) {
  if (Math.abs(apca(from, bg)) >= target) return mix(from, from, 0)
  if (Math.abs(apca(to, bg)) < target) return mix(to, to, 0)
  var lo = 0, hi = 1
  for (var i = 0; i < 24; i++) {
    var m = (lo + hi) / 2
    if (Math.abs(apca(mix(from, to, m), bg)) >= target) hi = m
    else lo = m
  }
  return mix(from, to, hi)
}
// The panel's tones, all measured on the card surface (the lighter of its two backgrounds, so the worst case):
// ink is for what matters now, value for what a label names, label for every label, rule for lines that are
// not text, alert for problems.
var LC = { ink: 90, value: 80, label: 60, rule: 15, alert: 60 }
function tones(ink, bg, surface, urgent) {
  var card = over(surface, bg), white = { r: 1, g: 1, b: 1 }, black = { r: 0, g: 0, b: 0 }
  var far = Math.abs(apca(white, card)) > Math.abs(apca(black, card)) ? white : black
  var top = reach(over(ink, bg), far, card, LC.ink)
  return { ink: top, value: reach(card, top, card, LC.value), label: reach(card, top, card, LC.label),
    rule: reach(card, top, card, LC.rule), alert: reach(urgent, top, card, LC.alert), alertRule: reach(urgent, top, card, LC.rule) }
}

// ---- reading the snapshot ----

function stats(s) { return s.stats || {} }
function health(s) { return s.health || {} }
function running(s) { return s.running === true }
function busy(s) { return s.active === "activating" || s.active === "deactivating" }
function foreign(s) { return s.foreign === true && s.portPid > 0 }

// the bar mark: failed, busy, ready, foreign or idle
function mark(s) {
  if (foreign(s)) return "foreign"
  if (s.active === "failed") return "failed"
  if (busy(s)) return "busy"
  return running(s) ? "ready" : ""
}

function stateLabel(s) {
  if (!s.folderOk) return "folder missing"
  if (s.active === "failed") return "failed — " + (s.sub || "")
  if (s.active === "activating") return "starting…"
  if (s.active === "deactivating") return "stopping…"
  if (foreign(s)) return "external laya · pid " + s.portPid
  if (running(s)) return up(s.mode) + " · up " + dur(s.uptime)
  return "stopped"
}

// the p50 of the latency ring the hook keeps, plus its mean
function p50(lat) {
  if (!lat || !lat.length) return null
  var s = lat.slice().sort(function(a, b) { return a - b })
  return s[Math.floor((s.length - 1) / 2)]
}
function mean(lat) {
  if (!lat || !lat.length) return null
  var t = 0
  for (var i = 0; i < lat.length; i++) t += lat[i]
  return t / lat.length
}

// Your lifetime as an activity grid: a column a week, a row a weekday (Sunday first), each day shaded in four
// steps by its tokens against your busiest day, the months under their first week, the totals above.
var DAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
var MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
function life(s) {
  var days = (s.days && s.days.days) || {}, keys = Object.keys(days).sort()
  if (!keys.length) return null
  var now = new Date()
  var start = new Date(now.getFullYear(), now.getMonth(), now.getDate() - now.getDay() - 133)
  var out = { tokens: 0, requests: 0, cells: [], labels: [], months: [], since: "" }
  var top = 0, today = -1, last = -1
  for (var i = 0; i < 140; i++) {
    var d = new Date(start.getTime() + i * 86400000)
    var key = d.getFullYear() + "-" + ("0" + (d.getMonth() + 1)).slice(-2) + "-" + ("0" + d.getDate()).slice(-2)
    var e = days[key] || {}
    var v = (e["in"] || 0) + (e.out || 0), r = e.r || 0
    out.tokens += v
    out.requests += r
    if (v > top) top = v
    if (d.toDateString() === now.toDateString()) today = i
    out.cells.push({ v: v, r: r, ms: r > 0 ? (e.ms || 0) / r : 0 })
    out.labels.push(DAYS[d.getDay()] + " " + MONTHS[d.getMonth()] + " " + d.getDate() + "  " +
      (r > 0 ? r + " req · " + k(v) + " tok" : "no requests"))
  }
  // the months under their first week; the first, partial month keeps its name unless the next would crowd it
  for (var c = 0; c * 7 < 140; c++) {
    var m = new Date(start.getTime() + c * 7 * 86400000).getMonth()
    if (m !== last) out.months.push({ col: c, label: MONTHS[m] })
    last = m
  }
  if (out.months.length > 1 && out.months[1].col < 3) out.months.shift()
  out.since = "since " + MONTHS[new Date(keys[0]).getMonth()] + " " + new Date(keys[0]).getDate()
  out.today = today
  return out
}

function activity(s) {
  var l = life(s)
  if (!l || l.requests === 0) return null
  var top = Math.max.apply(null, l.cells.map(function(c) { return c.v }).concat([1]))
  return { type: "life", tokens: k(l.tokens) + " tokens", requests: k(l.requests) + (l.requests === 1 ? " request" : " requests"),
    since: l.since, months: l.months, labels: l.labels,
    cells: l.cells.map(function(c, i) { return i > l.today ? -1 : c.v > 0 ? Math.ceil(c.v / top * 4) : 0 }) }
}

// the service as a running-model card: name, what it runs on, its cumulative token line behind it, a primary
// action (log when it serves, start when it does not) and More
function card(s) {
  var st = stats(s), h = health(s), series = (st.series || {})
  var r = { type: "run", name: "Laya", family: "laya", line: series.v || [], more: "more",
    version: s.layaVersion || "",
    gpu: up(s.mode) + " mode · :" + s.port,
    mem: Array.isArray(h.loaded) ? h.loaded.length + " checkpoints" : "" }
  if (running(s) || busy(s)) {
    r.chips = [{ icon: "speed", text: ms(p50(st.latencies)) + " p50" },
      { icon: "tokens", text: "Σ " + k((st.input_tokens || 0) + (st.output_tokens || 0)) }].filter(function(c) { return !!c.text })
    r.sub = busy(s) ? stateLabel(s) : ""
    r.primary = busy(s)
      ? { label: "Stop", action: "stop", quiet: true }
      : { label: "Open log", action: "log" }
  } else {
    r.sub = stateLabel(s)
    r.primary = foreign(s) ? { label: "Restart", action: "restart" }
      : s.folderOk ? { label: "Start", action: "start" } : { label: "", action: "" }
  }
  return r
}

// the details page: hero (name, chips, cumulative token line), six figures, the GPU, the checkpoints that
// answer, the control rows (mode, autostart, folder), where it answers, and its actions
function moreView(s, ui) {
  var st = stats(s), h = health(s), series = st.series || {}
  var dev = (h.device || "").toUpperCase()
  if (dev === "CUDA") dev = "GPU"
  var facts = [
    { icon: "machine", text: up(s.mode) + " · :" + s.port },
    dev !== up(s.mode) ? { icon: "gpu", text: dev } : null,
    Array.isArray(h.loaded) ? { icon: "weights", text: h.loaded.length + " checkpoints" } : null,
    s.layaVersion ? { icon: "version", text: "laya " + s.layaVersion } : null,
    s.autostart ? { icon: "check", text: "autostart" } : null
  ].filter(function(c) { return c && c.text !== "" })
  var v = { back: true, rows: [], hero: { name: "Laya", family: "laya", chips: facts, sub: stateLabel(s), version: s.layaVersion || "" } }
  var line = series.v || []
  if (line.length > 1) {
    var top = line[line.length - 1]
    v.hero.line = line
    v.hero.top = k(top) + " tokens"
    v.hero.mid = k(Math.round(top / 2))
    v.hero.since = MONTHS[new Date((series.t0 || 0) * 1000).getMonth()] + " " + new Date((series.t0 || 0) * 1000).getDate()
    v.hero.now = ago(series.t1 || 0)
  }
  if (running(s) || (st.requests || 0) > 0) {
    var dmap = (s.days && s.days.days) || {}, week = 0, wnow = new Date()
    for (var i = 0; i < 7; i++) {
      var d = new Date(wnow.getTime() - i * 86400000)
      var key = d.getFullYear() + "-" + ("0" + (d.getMonth() + 1)).slice(-2) + "-" + ("0" + d.getDate()).slice(-2)
      var e = dmap[key]
      if (e) week += (e["in"] || 0) + (e.out || 0)
    }
    v.rows.push({ type: "grid", cells: [
      { v: ms(mean(st.latencies)).split(" ")[0], u: "ms", k: "avg" },
      { v: ms(p50(st.latencies)).split(" ")[0], u: "ms", k: "p50" },
      { v: String(st.errors || 0), u: "", k: "errors" },
      { v: k((st.input_tokens || 0) + (st.output_tokens || 0)), u: "", k: "session" },
      { v: k(week), u: "", k: "week" },
      { v: dur(s.uptime || 0), u: "", k: "up" }] })
  }
  if (s.gpu && s.gpu.name) {
    var g = s.gpu
    v.rows.push({ type: "sec", label: "GPUS" })
    v.rows.push({ type: "gpu", name: g.name.replace(/^NVIDIA GeForce /, ""), bar: true,
      pct: Math.min(100, Math.round((g.usedMiB || 0) / Math.max(1, g.totalMiB || 1) * 100)),
      mem: Math.round((g.usedMiB || 0) / 1024 * 10) / 10 + " / " + Math.round((g.totalMiB || 0) / 1024) + " GB",
      temp: g.tempC != null ? g.tempC + "°" : "" })
  }
  var loaded = Array.isArray(h.loaded) ? h.loaded : []
  var models = st.models || {}
  if (loaded.length) {
    v.rows.push({ type: "sec", label: "CHECKPOINTS" })
    loaded.forEach(function(c) {
      v.rows.push({ type: "field", icon: "weights", label: c, value: models[c] ? models[c] + " req" : "" })
    })
  }
  v.rows.push({ type: "sec", label: "CONTROL" })
  v.rows.push({ type: "field", icon: "mode", label: "mode", value: up(s.mode), action: "pick|mode", drop: true, open: ui.open === "mode" })
  if (ui.open === "mode") ["cpu", "gpu"].forEach(function(m) {
    v.rows.push({ type: "opt", label: up(m), on: (s.mode || "cpu") === m, action: "mode|" + m })
  })
  v.rows.push({ type: "field", icon: "check", label: "autostart", value: s.autostart ? "on" : "off",
    action: "auto|" + (s.autostart ? "off" : "on"), open: false })
  v.rows.push({ type: "field", icon: "folder", label: "folder", value: home(s.folder), action: "pick|folder", drop: true, open: ui.open === "folder" })
  if (ui.open === "folder") v.rows.push({ type: "path" })
  // the laya package version and one-click upgrade; tuning lives in <folder>/laya.env
  var env = s.env || {}, tune = Object.keys(env)
  v.rows.push({ type: "field", icon: "version", label: "laya", value: (s.layaVersion || "?") + "  ›", action: "pick|laya", open: ui.open === "laya" })
  if (ui.open === "laya") {
    v.rows.push({ type: "opt", label: "update from PyPI", value: "uv sync", action: "update" })
    v.rows.push({ type: "opt", label: "update to upstream main", value: "git", action: "update|git" })
  }
  if (tune.length) v.rows.push({ type: "field", icon: "tune", label: "tuning",
    value: tune.map(function(kk) { return kk.replace("LAYA_", "").toLowerCase() + "=" + env[kk] }).join("  ") })
  v.rows.push({ type: "sec", label: "REACH" })
  v.rows.push({ type: "field", icon: "machine", label: "this machine", value: "127.0.0.1:" + s.port })
  if (ui.problem) v.rows.push({ type: "error", label: ui.problem })
  var acts = [{ label: "View logs", action: "log" }]
  if (running(s) || busy(s)) {
    acts.push({ label: "Restart", action: "restart" })
    acts.push({ label: "Stop", action: "stop", danger: true })
  } else if (!s.installed) {
    acts.push({ label: "Install laya ›", action: "install", primary: true })
  } else if (foreign(s)) {
    acts.push({ label: "Restart", action: "restart" })
    acts.push({ label: "Stop", action: "stop", danger: true })
  } else {
    acts.push({ label: s.folderOk ? "Start ›" : "folder missing", action: s.folderOk ? "start" : "", primary: true })
  }
  v.rows.push({ type: "acts", items: acts })
  return v
}

// nothing to serve: a square wave, one line, and the install button
function soonView(s) {
  var f = home(s.folder || "")
  return { type: "soon",
    head: (s.folderOk ? "No laya install in " : "No laya folder at ") + f + " yet",
    action: "install", button: "Install laya ›" }
}

function homeView(s, ui) {
  var rows = ui.problem ? [{ type: "error", label: ui.problem }] : []
  var act = activity(s)
  if (act) rows.push(act)
  rows.push(s.installed ? card(s) : soonView(s))
  return { title: "LOCAL LAYA", version: (s.layaVersion ? "laya " + s.layaVersion : s.version) || "", rows: rows }
}

function build(s, ui) {
  s = s || {}
  var v = ui.view === "more" ? moreView(s, ui) : homeView(s, ui)
  return Object.assign(v, { mark: mark(s) })
}
