(function () {
  const vscode = acquireVsCodeApi();
  const guide = JSON.parse(document.getElementById('guide-data').textContent);
  const steps = guide.steps;
  let progress = { current: 0, done: [] };
  let statuses = {};
  let toastTimer;

  function el(tag, props, children) {
    const node = document.createElement(tag);
    Object.assign(node, props || {});
    for (const child of children || []) node.append(child);
    return node;
  }

  function button(label, className, onClick, title) {
    const node = el('button', { type: 'button', className, textContent: label, title: title || '' });
    node.addEventListener('click', onClick);
    return node;
  }

  function isDone(step) {
    return progress.done.includes(step.id) || Boolean(step.check && statuses[step.check] && statuses[step.check].done);
  }

  function save() {
    vscode.postMessage({ type: 'progress', progress });
  }

  function toast(text) {
    const node = document.getElementById('toast');
    node.textContent = text;
    node.classList.add('show');
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => node.classList.remove('show'), 2500);
  }

  function copy(text, label) {
    vscode.postMessage({ type: 'copy', text, label });
  }

  function openLink(url) {
    vscode.postMessage({ type: 'open', url });
  }

  function renderHeader() {
    const seat = guide.seat;
    const header = document.getElementById('seat');
    header.replaceChildren();
    const doneCount = steps.filter(isDone).length;
    const bar = el('div', { className: 'bar' }, [el('div', { className: 'fill' })]);
    bar.firstChild.style.width = `${Math.round((doneCount / steps.length) * 100)}%`;
    const links = el('div', { className: 'links' });
    for (const [label, key] of [['Omni', 'omni'], ['Proxmox', 'proxmox'], ['Your site', 'site']]) {
      if (seat.links[key]) links.append(button(`${label} ↗`, 'link', () => openLink(seat.links[key]), seat.links[key]));
    }
    if (seat.email) links.append(button('Copy email', 'secondary', () => copy(seat.email, 'Email copied'), seat.email));
    if (seat.hasPassword) {
      links.append(
        button('Copy password', 'secondary', () => vscode.postMessage({ type: 'copy', field: 'password', label: 'Password copied' }), 'Copies your seat password'),
      );
    }
    header.append(
      el('div', { className: 'title' }, [
        el('h1', { textContent: guide.title }),
        el('span', { className: 'who', textContent: seat.seat ? `Seat ${seat.seat} · ${seat.email || ''}` : '' }),
      ]),
      links,
      el('div', { className: 'progress' }, [bar, el('span', { textContent: `${doneCount} of ${steps.length} steps done` })]),
    );
    document.documentElement.style.setProperty('--header', `${header.offsetHeight}px`);
  }

  function renderNav() {
    const nav = document.getElementById('steps');
    nav.replaceChildren();
    steps.forEach((step, index) => {
      const item = button('', `step${index === progress.current ? ' current' : ''}${isDone(step) ? ' done' : ''}`, () => go(index));
      item.append(
        el('span', { className: 'mark', textContent: isDone(step) ? '✓' : String(index + 1) }),
        el('span', { className: 'label', textContent: step.title }),
      );
      nav.append(item);
    });
  }

  function statusLine(step) {
    if (!step.check) return null;
    const result = statuses[step.check];
    const state = !result ? 'checking' : result.done ? 'ok' : 'waiting';
    const text = !result ? 'Checking…' : result.text;
    return el('div', { className: `status ${state}` }, [
      el('span', { className: 'dot' }),
      el('span', { className: 'text', textContent: text }),
      button('Check again', 'ghost', () => {
        vscode.postMessage({ type: 'refresh' });
        toast('Checking…');
      }),
    ]);
  }

  function enhance(container) {
    for (const pre of container.querySelectorAll('pre')) {
      const code = pre.querySelector('code');
      const text = (code || pre).textContent;
      const language = code ? (/language-(\w+)/.exec(code.className) || [])[1] : '';
      const tools = el('div', { className: 'tools' });
      if (!language || language === 'bash' || language === 'sh') {
        tools.append(button('▶ Run in terminal', 'primary small', () => vscode.postMessage({ type: 'run', text })));
      }
      tools.append(button('Copy', 'secondary small', () => copy(text, 'Copied')));
      const block = el('div', { className: 'code' });
      pre.replaceWith(block);
      block.append(pre, tools);
    }
    for (const code of container.querySelectorAll('code')) {
      if (code.closest('pre')) continue;
      const text = code.textContent;
      if (/^https:\/\/\S+$/.test(text)) {
        code.classList.add('url');
        code.title = 'Open in a new tab';
        code.addEventListener('click', () => openLink(text));
      } else {
        code.classList.add('copyable');
        code.title = 'Click to copy';
        code.addEventListener('click', () => copy(text, `Copied ${text}`));
      }
    }
    for (const anchor of container.querySelectorAll('a[href]')) {
      anchor.addEventListener('click', (event) => {
        event.preventDefault();
        openLink(anchor.href);
      });
    }
  }

  function renderStep() {
    const main = document.getElementById('step');
    const step = steps[progress.current];
    const content = el('div', { className: 'content' });
    content.innerHTML = step.html;
    enhance(content);
    const last = progress.current === steps.length - 1;
    const footer = el('footer', {}, [
      progress.current > 0 ? button('← Back', 'secondary', () => go(progress.current - 1)) : el('span'),
      isDone(step)
        ? button(last ? 'All done' : 'Next →', 'primary', () => go(Math.min(progress.current + 1, steps.length - 1)))
        : button(last ? 'Mark done' : 'Mark done and continue →', 'primary', () => complete(step)),
    ]);
    main.replaceChildren(
      el('div', { className: 'counter', textContent: `Step ${progress.current + 1} of ${steps.length}` }),
      el('h2', { textContent: step.title }),
      ...[statusLine(step)].filter(Boolean),
      content,
      footer,
    );
  }

  function render() {
    renderHeader();
    renderNav();
    renderStep();
  }

  function go(index) {
    progress.current = Math.max(0, Math.min(index, steps.length - 1));
    save();
    render();
    document.getElementById('step').scrollTop = 0;
    window.scrollTo(0, 0);
  }

  function complete(step) {
    if (!progress.done.includes(step.id)) progress.done.push(step.id);
    go(Math.min(progress.current + 1, steps.length - 1));
  }

  function refreshStatus() {
    renderHeader();
    renderNav();
    const main = document.getElementById('step');
    const step = steps[progress.current];
    const line = main.querySelector('.status');
    const fresh = statusLine(step);
    if (line && fresh) line.replaceWith(fresh);
    const footerButton = main.querySelector('footer .primary');
    if (footerButton && isDone(step) && footerButton.textContent.startsWith('Mark done')) renderStep();
  }

  window.addEventListener('message', (event) => {
    const message = event.data;
    if (message.type === 'progress') {
      progress = { current: 0, done: [], ...message.progress };
      progress.current = Math.max(0, Math.min(progress.current, steps.length - 1));
      progress.done = progress.done.filter((id) => steps.some((s) => s.id === id));
      render();
    } else if (message.type === 'status') {
      statuses = message.results;
      refreshStatus();
    } else if (message.type === 'copied') {
      toast(message.label);
    }
  });

  window.addEventListener('resize', renderHeader);
  render();
  vscode.postMessage({ type: 'ready' });
})();
