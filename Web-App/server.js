// server.js — PatternFly-styled viewer (no build step required)
const express = require('express');
const { Pool } = require('pg');

const app = express();
const PORT = process.env.PORT || 8080;

// ---- PG env (injected by your deploy script) ----
const PGHOST = process.env.PGHOST || 'localhost';
const PGPORT = Number(process.env.PGPORT || 8888);
const PGUSER = process.env.PGUSER || 'postgres';
const PGPASSWORD = process.env.PGPASSWORD || '';
const PGDATABASE = process.env.PGDATABASE || 'postgres';

// ---- helpers ----
function maskPassword(pw) {
  if (!pw) return '';
  if (pw.length <= 2) return '*'.repeat(pw.length);
  return pw[0] + '*'.repeat(Math.max(2, pw.length - 2)) + pw[pw.length - 1];
}
function enc(v) { return encodeURIComponent(v || ''); }
function h(s) {
  return String(s ?? '')
    .replace(/&/g,'&amp;').replace(/</g,'&lt;')
    .replace(/>/g,'&gt;').replace(/"/g,'&quot;').replace(/'/g,'&#39;');
}

const PG_DSN_MASKED =
  'postgresql://' + enc(PGUSER) + ':' + maskPassword(PGPASSWORD) + '@' +
  PGHOST + ':' + PGPORT + '/' + enc(PGDATABASE);

const PG_DSN_RAW =
  'postgresql://' + enc(PGUSER) + ':' + enc(PGPASSWORD) + '@' +
  PGHOST + ':' + PGPORT + '/' + enc(PGDATABASE);

// ---- connection pool ----
const pool = new Pool({
  host: PGHOST,
  port: PGPORT,
  user: PGUSER,
  password: PGPASSWORD,
  database: PGDATABASE,
  ssl: false,
  max: 5,
  idleTimeoutMillis: 10_000,
});
pool.on('error', (err) => console.error('[pg] pool error:', err?.message || err));

// quick startup test so you see it in logs
(async () => {
  try {
    await pool.query('SELECT 1');
    console.log('[pg] initial connection OK');
  } catch (e) {
    console.error('[pg] initial connection FAILED:', e.message || e);
  }
})();

app.get('/healthz', (_req, res) => res.status(200).send('OK'));

// Server-side counters
let totalHits = 0;
const bootTime = new Date();

// JSON endpoint for tables (optionally include system schemas)
app.get('/api/tables', async (req, res) => {
  const includeSystem = String(req.query.system || 'false').toLowerCase() === 'true';
  const sql =
    "SELECT table_schema, table_name \
     FROM information_schema.tables \
     WHERE table_type='BASE TABLE' " +
    (includeSystem ? "" :
     "AND table_schema NOT IN ('pg_catalog','information_schema') ") +
    "ORDER BY table_schema, table_name LIMIT 2000";
  try {
    const q = await pool.query(sql);
    res.json(q.rows);
  } catch (e) {
    res.status(500).json({ error: String(e.message || e) });
  }
});

// Small helper to build PF cards
function card(title, bodyHtml) {
  return [
    '<div class="pf-c-card" style="margin-bottom:16px;">',
      '<div class="pf-c-card__title">', h(title), '</div>',
      '<div class="pf-c-card__body">', bodyHtml, '</div>',
    '</div>'
  ].join('');
}

app.get('/', async function (req, res) {
  totalHits++;

  const includeSystem = String(req.query.system || 'false').toLowerCase() === 'true';

  let ok = true;
  let errorMsg = '';
  let info = {};
  let tables = [];

  // session/server info
  try {
    const q = await pool.query(
      'SELECT current_database() AS current_database, ' +
      'inet_server_addr()::text AS server_ip, ' +
      'inet_client_addr()::text AS client_ip, ' +
      'now() AS now, version() AS version'
    );
    info = (q && q.rows && q.rows[0]) || {};
  } catch (err) {
    ok = false;
    errorMsg = (err && err.message) ? String(err.message) : String(err);
  }

  // tables list
  try {
    const qt = await pool.query(
      "SELECT table_schema, table_name \
       FROM information_schema.tables \
       WHERE table_type='BASE TABLE' " +
       (includeSystem ? "" :
        "AND table_schema NOT IN ('pg_catalog','information_schema') ") +
       "ORDER BY table_schema, table_name LIMIT 2000"
    );
    tables = qt.rows || [];
  } catch (e) {
    tables = [{ table_schema: 'ERROR', table_name: e.message || String(e) }];
  }

  const title = process.env.APP_TITLE || 'PostgreSQL Viewer (via E-STAP @ 8888)';

  // ---- page sections ----
  const statusHtml = ok
    ? '<div class="pf-c-alert pf-m-success" aria-label="Success alert"><div class="pf-c-alert__title">Connected ✓</div></div>'
    : '<div class="pf-c-alert pf-m-danger" aria-label="Error alert"><div class="pf-c-alert__title">Failed ✗ — ' + h(errorMsg) + '</div></div>';

  const connTarget = [
    '<dl class="pf-c-description-list pf-m-horizontal">',
      '<div class="pf-c-description-list__group">',
        '<dt class="pf-c-description-list__term">Host</dt>',
        '<dd class="pf-c-description-list__description"><code>', h(PGHOST), '</code></dd>',
      '</div>',
      '<div class="pf-c-description-list__group">',
        '<dt class="pf-c-description-list__term">Port</dt>',
        '<dd class="pf-c-description-list__description"><code>', h(PGPORT), '</code></dd>',
      '</div>',
      '<div class="pf-c-description-list__group">',
        '<dt class="pf-c-description-list__term">Database</dt>',
        '<dd class="pf-c-description-list__description"><code>', h(PGDATABASE), '</code></dd>',
      '</div>',
      '<div class="pf-c-description-list__group">',
        '<dt class="pf-c-description-list__term">User</dt>',
        '<dd class="pf-c-description-list__description"><code>', h(PGUSER), '</code></dd>',
      '</div>',
    '</dl>'
  ].join('');

  const connStrings = [
    '<div style="word-break:break-all"><strong>Masked:</strong><br/><code>', h(PG_DSN_MASKED), '</code></div>',
    '<details style="margin-top:.5rem"><summary>Show full connection string (reveals password)</summary>',
    '<div style="margin-top:.5rem;word-break:break-all"><code>', h(PG_DSN_RAW), '</code></div>',
    '</details>',
    '<div class="pf-u-color-200" style="margin-top:.25rem">Server boot: ', h(bootTime.toISOString()), '</div>'
  ].join('');

  const counters = [
    '<dl class="pf-c-description-list pf-m-horizontal">',
      '<div class="pf-c-description-list__group">',
        '<dt class="pf-c-description-list__term">Server hits since boot</dt>',
        '<dd class="pf-c-description-list__description"><code>', String(totalHits), '</code></dd>',
      '</div>',
      '<div class="pf-c-description-list__group">',
        '<dt class="pf-c-description-list__term">Your refresh count</dt>',
        '<dd class="pf-c-description-list__description"><code id="refreshCount">…</code></dd>',
      '</div>',
    '</dl>'
  ].join('');

  const sessionTable = [
    '<table class="pf-c-table pf-m-grid-md" role="grid">',
      '<thead><tr><th>Key</th><th>Value</th></tr></thead><tbody>',
      '<tr><td>current_database</td><td>', h(info.current_database), '</td></tr>',
      '<tr><td>server_ip</td><td>', h(info.server_ip), '</td></tr>',
      '<tr><td>client_ip</td><td>', h(info.client_ip), '</td></tr>',
      '<tr><td>now</td><td>', h(info.now), '</td></tr>',
      '<tr><td>version</td><td style="word-break:break-word">', h(info.version), '</td></tr>',
      '</tbody></table>'
  ].join('');

  const tablesHeader = [
    '<div class="pf-l-flex pf-m-align-items-center pf-m-justify-content-space-between">',
      '<div>Showing ', includeSystem ? 'all' : 'non-system', ' schemas</div>',
      '<div>',
        includeSystem
          ? '<a class="pf-c-button pf-m-secondary" href="/?system=false">Hide system schemas</a>'
          : '<a class="pf-c-button pf-m-secondary" href="/?system=true">Include system schemas</a>',
        ' <a class="pf-c-button pf-m-link" href="/api/tables', includeSystem ? '?system=true' : '', '" target="_blank" rel="noopener">/api/tables</a>',
      '</div>',
    '</div>'
  ].join('');

  const tablesRows = (tables.length
    ? tables.map(r =>
        '<tr><td><code>' + h(r.table_schema) + '</code></td><td>' + h(r.table_name) + '</td></tr>'
      ).join('')
    : '<tr><td colspan="2"><em>No tables found</em></td></tr>');

  const tablesTable = [
    '<table class="pf-c-table pf-m-grid-md" role="grid">',
      '<thead><tr><th>Schema</th><th>Table</th></tr></thead>',
      '<tbody>', tablesRows, '</tbody>',
    '</table>'
  ].join('');

  // ---- full HTML ----
  
  const html = [
    '<!doctype html>',
    '<html lang="en">',
    '<head>',
      '<meta charset="utf-8"/>',
      '<meta name="viewport" content="width=device-width, initial-scale=1"/>',
      '<title>', h(title), '</title>',
      '<style>',
      ':root{--brand:#2563eb;--bg:#0b1220;--text:#e5e7eb;--muted:#9aa4b2;--card:#111827;--border:rgba(148,163,184,.18);--success:#22c55e;--danger:#ef4444;}',
      '@media (prefers-color-scheme: light){:root{--bg:#f8fafc;--text:#0f172a;--muted:#475569;--card:#ffffff;--border:rgba(15,23,42,.12);}}',
      '*,*:before,*:after{box-sizing:border-box}html,body{height:100%}body{margin:0;background:var(--bg);color:var(--text);font:16px/1.55 ui-sans-serif,system-ui,-apple-system,Segoe UI,Roboto,Ubuntu,Helvetica,Arial,"Apple Color Emoji","Segoe UI Emoji";}',
      'a{color:var(--brand);text-decoration:none}a:hover{text-decoration:underline}',
      '.container{width:min(1600px,96vw);margin:0 auto;padding:24px}',
      '.header{position:sticky;top:0;z-index:10;background:linear-gradient(180deg,rgba(0,0,0,.25),transparent),var(--bg);backdrop-filter:saturate(180%) blur(6px);border-bottom:1px solid var(--border)}',
      '.brand{display:flex;gap:12px;align-items:center; padding:14px 24px}.brand h1{margin:0;font-size:18px;font-weight:650;letter-spacing:.2px}',
      '.badge{display:inline-flex;align-items:center;gap:6px;font-size:12px;padding:4px 8px;border-radius:999px;border:1px solid var(--border);background:rgba(34,197,94,.12);color:#16a34a}.badge.danger{background:rgba(239,68,68,.12);color:#ef4444}',
      '.grid{display:grid;gap:18px}@media(min-width:900px){.cols-2{grid-template-columns:1fr 1fr}}@media(min-width:1400px){.cols-2{grid-template-columns:1.1fr 1fr}}',
      '.card{background:var(--card);border:1px solid var(--border);border-radius:16px;box-shadow:0 12px 24px rgba(0,0,0,.15);padding:20px}',
      '.card h2{margin:0 0 12px;font-size:14px;letter-spacing:.08em;text-transform:uppercase;color:var(--muted)}',
      'dl{display:grid;grid-template-columns:200px 1fr;gap:10px 12px;margin:0}dt{color:var(--muted)}',
      'code{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;background:transparent;border:1px dashed var(--border);padding:2px 6px;border-radius:8px}',
      '.table-wrap{overflow:auto;border:1px solid var(--border);border-radius:14px}table{width:100%;border-collapse:separate;border-spacing:0}',
      'thead th{font-size:12px;text-transform:uppercase;letter-spacing:.08em;color:var(--muted);text-align:left;padding:10px 12px;border-bottom:1px solid var(--border);position:sticky;top:0;background:var(--card)}',
      'tbody td{padding:10px 12px;border-bottom:1px dashed var(--border)}tbody tr:hover{background:rgba(148,163,184,.06)}',
      '.toolbar{display:flex;gap:10px;align-items:center;justify-content:space-between;margin:12px 0}',
      '.btn{display:inline-flex;align-items:center;gap:8px;border:1px solid var(--border);padding:8px 12px;border-radius:12px;background:transparent;color:var(--text);cursor:pointer;text-decoration:none}.btn:hover{background:rgba(148,163,184,.08)}',
      '.search{flex:1;display:flex;align-items:center;gap:8px;border:1px solid var(--border);border-radius:12px;padding:8px 10px}.search input{flex:1;border:0;outline:none;background:transparent;color:var(--text)}',
      '.muted{color:var(--muted)}.mono{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace}',
      '</style>',
    '</head>',
    '<body>',
      '<div class="header"><div class="brand"><div>', ok ? '<span class="badge">Connected ✓</span>' : '<span class="badge danger">Failed ✗</span>', '</div><h1>', h(title), '</h1></div></div>',
      '<div class="container grid cols-2">',
        '<section class="card"><h2>Connection target</h2><dl>',
          '<dt>Host</dt><dd><code>', h(PGHOST), '</code></dd>',
          '<dt>Port</dt><dd><code>', h(PGPORT), '</code></dd>',
          '<dt>Database</dt><dd><code>', h(PGDATABASE), '</code></dd>',
          '<dt>User</dt><dd><code>', h(PGUSER), '</code></dd>',
        '</dl>',
        '<div style="margin-top:12px"><div class="muted" style="margin-bottom:6px">Connection strings</div>',
        '<div style="word-break:break-all;margin-bottom:8px"><span class="muted">Masked:</span><br/><code>', h(PG_DSN_MASKED), '</code></div>',
        '<details><summary class="btn" style="display:inline-flex">Show full connection string (reveals password)</summary><div style="margin-top:8px;word-break:break-all"><code>', h(PG_DSN_RAW), '</code></div></details>',
        '<div class="muted" style="margin-top:8px">Server boot: ', h(bootTime.toISOString()), '</div></div></section>',
        '<section class="card"><h2>Session / Server info</h2>',
          '<div class="table-wrap"><table><thead><tr><th style="width:220px">Key</th><th>Value</th></tr></thead><tbody>',
          '<tr><td>current_database</td><td>', h(info.current_database), '</td></tr>',
          '<tr><td>server_ip</td><td>', h(info.server_ip), '</td></tr>',
          '<tr><td>client_ip</td><td>', h(info.client_ip), '</td></tr>',
          '<tr><td>now</td><td>', h(info.now), '</td></tr>',
          '<tr><td>version</td><td style="word-break:break-word">', h(info.version), '</td></tr>',
          '</tbody></table></div>',
          '<div style="display:flex;gap:20px;margin-top:10px"><div><div class="muted">Server hits since boot</div><div class="mono">', String(totalHits), '</div></div>',
          '<div><div class="muted">Your refresh count</div><div class="mono" id="refreshCount">…</div></div></div>',
        '</section>',
        '<section class="card" style="grid-column:1/-1"><h2>Tables</h2>',
          '<div class="toolbar"><div class="search"><svg width="16" height="16" viewBox="0 0 24 24" fill="none"><path d="M21 21l-4.35-4.35M10 18a8 8 0 1 1 0-16 8 8 0 0 1 0 16Z" stroke="currentColor" stroke-width="2" stroke-linecap="round"/></svg><input id="search" placeholder="Filter by schema or table..."/></div>',
          includeSystem ? '<a class="btn" href="/?system=false">Hide system schemas</a>' : '<a class="btn" href="/?system=true">Include system schemas</a>',
          '</div>',
          '<div class="table-wrap"><table id="tables"><thead><tr><th style="width:220px">Schema</th><th>Table</th></tr></thead><tbody>',
            tables.map(t => '<tr><td><code>'+h(t.table_schema)+'</code></td><td>'+h(t.table_name)+'</td></tr>').join(''),
          '</tbody></table></div></section>',
      '</div>',
      '<script>',
        '(function(){try{var k="pg_viewer_refresh_count";var n=parseInt(localStorage.getItem(k)||"0",10);if(!isFinite(n))n=0;n+=1;localStorage.setItem(k,String(n));var el=document.getElementById("refreshCount");if(el)el.textContent=String(n);}catch(e){}})();',
        '(function(){var input=document.getElementById("search");if(!input)return;var tbody=document.querySelector("#tables tbody");if(!tbody)return;input.addEventListener("input",function(){var q=this.value.toLowerCase();Array.from(tbody.rows).forEach(function(r){var txt=(r.cells[0].innerText+" "+r.cells[1].innerText).toLowerCase();r.style.display=txt.indexOf(q)>=0?"":"none";});});})();',
      '</script>',
      '</body></html>'
  ].join('');


  res.setHeader('Content-Type', 'text/html; charset=utf-8');
  res.end(html);
});

app.listen(PORT, function () {
  console.log('pg-viewer listening on http://0.0.0.0:' + PORT);
  console.log('Target DSN (masked): ' + PG_DSN_MASKED);
});
