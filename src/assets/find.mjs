// Exact and contiguous matches rank ahead of ordered, non-contiguous matches.
export function fuzzyScore(text, query) {
  text = text.toLowerCase();
  query = query.toLowerCase();
  if (!query) return 0;
  if (text === query) return 10000;
  const substring = text.indexOf(query);
  if (substring >= 0) return (substring === 0 ? 5000 : 3000) - substring - text.length / 1000;
  let best = null;
  for (let start = text.indexOf(query[0]); start >= 0; start = text.indexOf(query[0], start + 1)) {
    let position = start;
    let matched = true;
    for (let i = 1; i < query.length; i++) {
      position = text.indexOf(query[i], position + 1);
      if (position < 0) { matched = false; break; }
    }
    if (matched) {
      const score = 1000 - (position - start + 1 - query.length) * 10 - start - text.length / 1000;
      best = best === null ? score : Math.max(best, score);
    }
  }
  return best;
}

export function rankTargets(targets, query, limit = Infinity) {
  const words = query.trim().toLowerCase().split(/\s+/).filter(Boolean);
  return targets.map((target, index) => {
    const fields = [target.label, target.id, target.path];
    let score = 0;
    for (const word of words) {
      const scores = fields.map(field => fuzzyScore(field, word)).filter(value => value !== null);
      if (!scores.length) return null;
      score += Math.max(...scores);
    }
    return {target, score, index};
  }).filter(Boolean).sort((a, b) => b.score - a.score || a.index - b.index)
    .slice(0, limit).map(result => result.target);
}

function installIdBrowser() {
  const root = document.querySelector('.id-browser');
  if (!root) return;
  const input = root.querySelector('input');
  const list = root.querySelector('ol');
  const status = root.querySelector('.id-status');
  input.value = new URLSearchParams(location.search).get('id-query') || '';
  let targets = [];
  let matches = [];
  let selected = 0;
  let request;
  let active = false;
  let loading = false;
  let error = false;
  let skipped = 0;
  let previewTimer;
  let previewRequest;

  function cancelPreview() {
    clearTimeout(previewTimer);
    previewRequest?.abort();
    previewRequest = undefined;
  }

  async function preview(target, href) {
    cancelPreview();
    const current = new AbortController();
    previewRequest = current;
    const url = new URL(href, location.origin);
    try {
      if (location.pathname !== url.pathname || new URLSearchParams(location.search).has('commit')) {
        const detail = {url: `${url.pathname}?partial=1`, controller: current};
        document.dispatchEvent(new CustomEvent('gitmd-id-preview', {detail}));
        if (!detail.promise) throw new Error('Preview unavailable');
        await detail.promise;
      }
      if (current.signal.aborted) return;
      const destination = document.getElementById(target.id);
      if (!destination) throw new Error('Definition unavailable');
      if (location.pathname + location.search + location.hash !== href) history.pushState(null, '', href);
      document.body.dataset.pageUrl = location.pathname + location.search;
      const files = document.querySelector('.file-browser');
      files?.querySelectorAll('a').forEach(link => {
        const selectedFile = link.dataset.path === target.path;
        link.classList.toggle('selected', selectedFile);
        if (selectedFile) link.setAttribute('aria-current', 'page');
        else link.removeAttribute('aria-current');
      });
      if (files) document.title = `${target.path} · ${files.dataset.repositoryName}`;
      destination.scrollIntoView();
      status.textContent = '';
    } catch {
      if (!current.signal.aborted) status.textContent = 'Could not preview this ID. Reopen the tab to refresh.';
    }
  }

  function select(index) {
    selected = Math.max(0, Math.min(matches.length - 1, index));
    Array.from(list.children).forEach((item, i) => {
      item.firstElementChild.classList.toggle('selected', i === selected);
    });
    const link = list.children[selected]?.firstElementChild;
    if (link && active) link.scrollIntoView({block: 'nearest'});
  }

  function schedulePreview() {
    cancelPreview();
    const link = list.children[selected]?.firstElementChild;
    if (active && !loading && !error && link) previewTimer = setTimeout(() => link.click(), 120);
  }

  function render() {
    cancelPreview();
    matches = rankTargets(targets, input.value);
    list.replaceChildren();
    matches.forEach((target, index) => {
      const item = document.createElement('li');
      const link = document.createElement('a');
      const url = new URL(target.url, location.origin);
      url.searchParams.set('sidebar', 'id');
      if (input.value) url.searchParams.set('id-query', input.value);
      link.href = url.pathname + url.search + url.hash;
      const label = document.createElement('span');
      label.textContent = target.label;
      const path = document.createElement('small');
      path.textContent = target.path;
      link.title = target.id;
      link.append(label, path);
      link.addEventListener('click', event => {
        if (event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
        event.preventDefault();
        select(index);
        preview(target, link.getAttribute('href'));
      });
      item.append(link);
      list.append(item);
    });
    status.textContent = loading ? 'Loading IDs…' : error ? 'Could not load IDs. Reopen the tab to retry.'
      : !matches.length ? (input.value ? 'No matching IDs' : 'No IDs found') : '';
    if (skipped) status.textContent += ` ${skipped} unreadable file(s) skipped`;
    const current = matches.findIndex(target => target.url === location.pathname + location.hash);
    select(current < 0 ? 0 : current);
    schedulePreview();
  }

  async function refresh() {
    request?.abort();
    loading = true;
    error = false;
    skipped = 0;
    render();
    request = new AbortController();
    const current = request;
    try {
      const response = await fetch('/find', {signal: current.signal});
      if (!response.ok) throw new Error('IDs unavailable');
      const result = await response.json();
      if (current !== request) return;
      targets = result.targets;
      skipped = result.skipped;
    } catch {
      if (current !== request) return;
      targets = [];
      error = true;
    }
    loading = false;
    render();
  }

  function navigate(key) {
    if (key === 'Enter') list.children[selected]?.firstElementChild.click();
    else {
      select(selected + (key === 'ArrowDown' || key === 'j' ? 1 : -1));
      schedulePreview();
    }
  }

  input.addEventListener('input', render);
  input.addEventListener('keydown', event => {
    if (event.isComposing || event.metaKey || event.ctrlKey || event.altKey) return;
    if (['ArrowDown', 'ArrowUp', 'Enter'].includes(event.key)) {
      event.preventDefault();
      event.stopPropagation();
      navigate(event.key);
    }
  });
  document.addEventListener('gitmd-id-key', event => navigate(event.detail));
  document.addEventListener('gitmd-id-tab', event => {
    const entering = event.detail && !active;
    active = event.detail;
    if (!active) cancelPreview();
    if (entering) refresh();
  });
  // The initial Datastar effect may run before this module attaches listeners.
  requestAnimationFrame(() => {
    if (!active && getComputedStyle(root).display !== 'none') {
      active = true;
      refresh();
    }
  });
}

if (typeof document !== 'undefined') installIdBrowser();
