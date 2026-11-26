'use strict';

const $ = id => document.getElementById(id);
const SETTINGS = ['req_humid', 'max_temp', 'req_temp_days'];
const HISTORY_STEP = 60;
const BASE = location.pathname.replace(/[^/]*$/, '');   // works behind a proxy sub-path
let state = null;
let history = [];
let editing = null;   // slider being dragged, don't overwrite it

const fmtTime = t => t ? new Date(t * 1000).toLocaleString([], {dateStyle: 'short', timeStyle: 'short'}) : '–';

function fmtDuration(secs) {
  secs = Math.max(0, Math.round(secs));
  const h = Math.floor(secs / 3600), m = Math.floor(secs % 3600 / 60), s = secs % 60;
  return h ? `${h}h ${m}m` : m ? `${m}m ${s}s` : `${s}s`;
}

async function api(method, path, body) {
  const res = await fetch(BASE + 'api' + path, {
    method,
    headers: body ? {'Content-Type': 'application/json'} : {},
    body: body ? JSON.stringify(body) : undefined,
  });
  const json = await res.json().catch(() => ({}));
  if (!res.ok) { alert((json.errors || [res.statusText]).join('\n')); return; }
  render(json);
}

function render(s) {
  state = s;
  const r = s.reading;
  $('temp').textContent = r ? r.temperature.toFixed(1) + '°' : '–';
  $('humid').textContent = r ? r.humidity.toFixed(1) + '%' : '–';
  $('stale').hidden = !(r && r.stale) || s.stage === 'ready';
  $('max-temp-sub').textContent = s.settings.max_temp;
  $('req-humid-sub').textContent = s.settings.req_humid;
  $('eta').hidden = !s.eta;
  if (s.eta) $('eta').textContent = s.eta - s.now < 60 ? 'ETA: any moment'
    : `ETA ≈ ${fmtDuration(s.eta - s.now)} (${new Date(s.eta * 1000).toLocaleTimeString([], {hour: '2-digit', minute: '2-digit'})})`;

  for (const li of $('stages').children) li.classList.toggle('active', li.dataset.stage === s.stage);
  $('start').disabled = s.stage === 'heating';
  $('stop').disabled = s.stage === 'ready';

  for (const name of SETTINGS) {
    if (editing !== name) $(name).value = s.settings[name];
    $(name + '-out').textContent = $(name).value;
  }

  const timers = $('timers');
  timers.replaceChildren(...s.timers.map(t => {
    const li = document.createElement('li');
    const pct = Math.min(100, 100 * t.temp_days / t.req_temp_days);
    li.innerHTML =
      `<strong>#${t.id}</strong> ${t.temp_days.toFixed(2)} / ${t.req_temp_days} degree-days` +
      `<div class="bar"><span style="width:${pct}%"></span></div>` +
      `<span class="muted">Started ${fmtTime(t.started)} · ETC ${fmtTime(t.etc)}` +
      (t.next_warning ? ` · next: ${escapeHtml(t.next_warning.text)}` : '') + '</span>';
    return li;
  }));
  if (!s.timers.length) timers.innerHTML = '<li class="muted">No active timers.</li>';
  $('remove-newest').disabled = $('remove-oldest').disabled = !s.timers.length;

  $('notices').replaceChildren(...s.notices.map(n => {
    const li = document.createElement('li');
    li.innerHTML = `<time>${fmtTime(n.time)}</time><strong>${escapeHtml(n.title)}</strong>\n${escapeHtml(n.body)}`;
    return li;
  }));
  if (!s.notices.length) $('notices').innerHTML = '<li class="muted">Nothing yet.</li>';

  if (r && !r.stale) {
    const last = history[history.length - 1];
    if (!last || Math.floor(last[0] / HISTORY_STEP) !== Math.floor(r.time / HISTORY_STEP)) {
      history.push([r.time, r.temperature, r.humidity]);
      history = history.filter(p => p[0] > r.time - 86400);
      drawChart();
    }
  }
  tickStageTime();
}

function escapeHtml(text) {
  return String(text).replace(/[&<>"']/g, c => ({'&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'}[c]));
}

function tickStageTime() {
  if (state) $('stage-time').textContent = fmtDuration(Date.now() / 1000 - state.stage_since);
}

function drawChart() {
  const svg = $('chart'), W = 600, H = 220, top = 10, bottom = 20;
  if (history.length < 2) { svg.innerHTML = '<text x="300" y="110" text-anchor="middle">Collecting data…</text>'; return; }
  const t0 = history[0][0], t1 = history[history.length - 1][0];
  const x = t => (t - t0) / Math.max(1, t1 - t0) * W;
  const y = v => top + (1 - v / 100) * (H - top - bottom);   // both series on a 0–100 scale
  const line = i => history.map(p => `${x(p[0]).toFixed(1)},${y(p[i]).toFixed(1)}`).join(' ');
  const grid = [0, 25, 50, 75, 100].map(v =>
    `<line x1="0" x2="${W}" y1="${y(v)}" y2="${y(v)}"/><text x="2" y="${y(v) - 2}">${v}</text>`).join('');
  svg.innerHTML = grid +
    `<polyline class="temp" points="${line(1)}"/><polyline class="humid" points="${line(2)}"/>` +
    `<text x="${W - 2}" y="${H - 4}" text-anchor="end">${fmtTime(t1)}</text>` +
    `<text x="2" y="${H - 4}">${fmtTime(t0)}</text>`;
}

function connect() {
  const ws = new WebSocket(location.origin.replace(/^http/, 'ws') + BASE + 'ws');
  ws.onopen = () => { $('conn').textContent = 'live'; $('conn').className = 'conn online'; };
  ws.onmessage = e => render(JSON.parse(e.data));
  ws.onclose = () => {
    $('conn').textContent = 'offline'; $('conn').className = 'conn offline';
    setTimeout(connect, 3000);
  };
}

$('start').onclick = () => api('POST', '/heat/start');
$('stop').onclick = () => api('POST', '/heat/stop');
$('add-timer').onclick = () => api('POST', '/timers');
$('remove-newest').onclick = () => confirm('Remove the newest timer?') && api('DELETE', '/timers/newest');
$('remove-oldest').onclick = () => confirm('Remove the oldest timer?') && api('DELETE', '/timers/oldest');

for (const name of SETTINGS) {
  const input = $(name);
  input.oninput = () => { editing = name; $(name + '-out').textContent = input.value; };
  input.onchange = () => { editing = null; api('PUT', '/settings', {[name]: Number(input.value)}); };
}

fetch(BASE + 'api/history').then(r => r.json()).then(h => { history = h; drawChart(); });
setInterval(tickStageTime, 1000);
connect();
