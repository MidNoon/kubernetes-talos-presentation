const vscode = require('vscode');
const crypto = require('crypto');
const fs = require('fs');
const os = require('os');
const path = require('path');
const status = require('./status');

const VIEW_TYPE = 'labGuide';
const TERMINAL_NAME = 'Lab';
const WATCH_TERMINAL_NAME = 'Watch';
const WATCH_COMMAND = /(^|\s)(--watch|-w)(\s|$)/m;
const HOME = os.homedir();
const README = path.join(HOME, 'README.md');
const CONFIG_DIR = path.join(HOME, '.config', 'talos-lab');
const SEAT_FILE = path.join(CONFIG_DIR, 'seat.json');
const PROGRESS_FILE = path.join(CONFIG_DIR, 'progress.json');
const POLL_MS = 10000;
const STATUS_MARKER = /<!--\s*status:\s*([a-z-]+)\s*-->/;

let panel;
let guide;
let pollTimer;
let polling = false;
let extensionUri;

function readJson(file, fallback) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch {
    return fallback;
  }
}

function slug(text) {
  return text.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '');
}

function splitSteps(markdown) {
  let title = 'Lab guide';
  const sections = [];
  let current = { title: 'Start here', lines: [] };
  for (const line of markdown.split('\n')) {
    const h1 = /^# (.+)/.exec(line);
    const h2 = /^## (.+)/.exec(line);
    if (h1 && sections.length === 0 && current.lines.every((l) => !l.trim())) {
      title = h1[1].trim();
    } else if (h2) {
      if (current.lines.some((l) => l.trim())) sections.push(current);
      current = { title: h2[1].trim(), lines: [] };
    } else {
      current.lines.push(line);
    }
  }
  if (current.lines.some((l) => l.trim())) sections.push(current);
  return {
    title,
    steps: sections.map((section) => {
      const body = section.lines.join('\n');
      const marker = STATUS_MARKER.exec(body);
      return { id: slug(section.title), title: section.title, body, check: marker ? marker[1] : null };
    }),
  };
}

async function loadGuide() {
  const parsed = splitSteps(fs.readFileSync(README, 'utf8'));
  const steps = [];
  for (const step of parsed.steps) {
    const html = await vscode.commands.executeCommand('markdown.api.render', step.body);
    steps.push({ id: step.id, title: step.title, check: step.check, html });
  }
  const seat = readJson(SEAT_FILE, {});
  return { title: parsed.title, seat: { seat: seat.seat, email: seat.email, hasPassword: Boolean(seat.password), links: seat.links || {} }, steps };
}

function checkIds() {
  return guide ? [...new Set(guide.steps.map((s) => s.check).filter((c) => c && status.CHECKS[c]))] : [];
}

async function poll() {
  if (!panel || polling) return;
  polling = true;
  try {
    const results = await status.runChecks(readJson(SEAT_FILE, { links: {} }), checkIds());
    if (panel) panel.webview.postMessage({ type: 'status', results });
  } finally {
    polling = false;
  }
}

function startPolling() {
  if (pollTimer) return;
  poll();
  pollTimer = setInterval(poll, POLL_MS);
}

function stopPolling() {
  clearInterval(pollTimer);
  pollTimer = undefined;
}

function liveTerminal(name) {
  return vscode.window.terminals.find((t) => t.name === name && t.exitStatus === undefined);
}

function labTerminal() {
  return liveTerminal(TERMINAL_NAME) || vscode.window.createTerminal({ name: TERMINAL_NAME, cwd: HOME });
}

function watchTerminal() {
  const existing = liveTerminal(WATCH_TERMINAL_NAME);
  if (existing) {
    existing.sendText('\u0003', false);
    return existing;
  }
  return vscode.window.createTerminal({ name: WATCH_TERMINAL_NAME, cwd: HOME, location: { parentTerminal: labTerminal() } });
}

function saveProgress(progress) {
  fs.mkdirSync(CONFIG_DIR, { recursive: true, mode: 0o700 });
  fs.writeFileSync(PROGRESS_FILE, JSON.stringify(progress));
}

async function onMessage(message) {
  switch (message.type) {
    case 'ready':
      panel.webview.postMessage({ type: 'progress', progress: readJson(PROGRESS_FILE, { current: 0, done: [] }) });
      poll();
      break;
    case 'progress':
      saveProgress(message.progress);
      break;
    case 'run': {
      const terminal = WATCH_COMMAND.test(message.text) ? watchTerminal() : labTerminal();
      terminal.show(true);
      terminal.sendText(message.text.replace(/\s+$/, ''), true);
      setTimeout(poll, 4000);
      break;
    }
    case 'copy': {
      const text = message.field === 'password' ? readJson(SEAT_FILE, {}).password || '' : message.text;
      await vscode.env.clipboard.writeText(text);
      panel.webview.postMessage({ type: 'copied', label: message.label });
      break;
    }
    case 'open':
      if (/^https:\/\//.test(message.url)) await vscode.env.openExternal(vscode.Uri.parse(message.url));
      break;
    case 'refresh':
      poll();
      break;
  }
}

function nonce() {
  return crypto.randomBytes(16).toString('base64');
}

function html(webview) {
  const media = vscode.Uri.joinPath(extensionUri, 'media');
  const script = webview.asWebviewUri(vscode.Uri.joinPath(media, 'guide.js'));
  const style = webview.asWebviewUri(vscode.Uri.joinPath(media, 'guide.css'));
  const token = nonce();
  const data = JSON.stringify(guide).replace(/</g, '\\u003c');
  return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src ${webview.cspSource}; img-src ${webview.cspSource} https: data:; script-src 'nonce-${token}';">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<link rel="stylesheet" href="${style}">
<title>Lab guide</title>
</head>
<body>
<header id="seat"></header>
<div id="layout"><nav id="steps"></nav><main id="step"></main></div>
<div id="toast" role="status"></div>
<script type="application/json" id="guide-data">${data}</script>
<script nonce="${token}" src="${script}"></script>
</body>
</html>`;
}

async function attach(target) {
  panel = target;
  panel.iconPath = vscode.Uri.joinPath(extensionUri, 'media', 'icon.svg');
  panel.webview.options = { enableScripts: true, localResourceRoots: [vscode.Uri.joinPath(extensionUri, 'media')] };
  guide = await loadGuide();
  panel.webview.html = html(panel.webview);
  panel.webview.onDidReceiveMessage(onMessage);
  panel.onDidChangeViewState(() => (panel && panel.visible ? startPolling() : stopPolling()));
  panel.onDidDispose(() => {
    stopPolling();
    panel = undefined;
  });
  if (panel.visible) startPolling();
}

async function open() {
  if (panel) {
    panel.reveal(vscode.ViewColumn.One);
    return;
  }
  await attach(
    vscode.window.createWebviewPanel(VIEW_TYPE, 'Lab guide', vscode.ViewColumn.One, {
      enableScripts: true,
      retainContextWhenHidden: true,
      localResourceRoots: [vscode.Uri.joinPath(extensionUri, 'media')],
    }),
  );
}

function activate(context) {
  extensionUri = context.extensionUri;
  context.subscriptions.push(
    vscode.commands.registerCommand('labGuide.open', open),
    vscode.window.registerWebviewPanelSerializer(VIEW_TYPE, { deserializeWebviewPanel: (restored) => attach(restored) }),
  );
  const item = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Left, 100);
  item.text = '$(book) Lab guide';
  item.command = 'labGuide.open';
  item.show();
  context.subscriptions.push(item);
  setTimeout(() => {
    if (!panel) open();
    if (!vscode.window.terminals.some((t) => t.name === TERMINAL_NAME)) labTerminal().show(true);
  }, 1500);
}

function deactivate() {
  stopPolling();
}

module.exports = { activate, deactivate };
