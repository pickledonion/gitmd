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
  const queryId = /^[a-z]\d+(?:\.\d+)*$/i.test(query.trim()) ? identity(query.trim().toUpperCase())?.code : null;
  return targets.map((target, index) => {
    const code = identity(target.label)?.code;
    const fields = [target.label, target.id, target.path, code || ''];
    // A complete ID names its definition, ahead of references and longer IDs.
    let score = queryId && code === queryId ? 1000000 : 0;
    for (const word of words) {
      const scores = fields.map(field => fuzzyScore(field, queryId ? queryId.toLowerCase() : word)).filter(value => value !== null);
      if (!scores.length) return null;
      score += Math.max(...scores);
    }
    return {target, score, index};
  }).filter(Boolean).sort((a, b) => b.score - a.score || a.index - b.index)
    .slice(0, limit).map(result => result.target);
}

// Heading labels retain dotted IDs; generated HTML anchors often remove the dots.
function identity(label) {
  const match = label.match(/^(?:\[[ xX]\]\s*)?([A-Z])(\d+(?:\.\d+)*)(?=$|[\s:.-])/);
  if (!match) return null;
  const numbers = match[2].split('.').map(Number);
  return {code: match[1] + numbers.join('.'), prefix: match[1], numbers,
    title: label.slice(match[0].length).replace(/^[\s:.-]+/, '')};
}

const natural = new Intl.Collator('en', {numeric: true, sensitivity: 'base'});

export function buildIdTree(targets) {
  const core = {key: 'core', title: 'Core docs', children: []};
  const specs = {key: 'specs', title: 'Specs', children: []};
  const nodes = new Map();
  const files = new Map();
  const makeNode = (key, code, title, parent) => {
    const node = {key, code, title, children: []};
    nodes.set(key, node);
    parent.children.push(node);
    return node;
  };
  function semantic(code) {
    if (nodes.has(code)) return nodes.get(code);
    const info = identity(code);
    const {prefix, numbers} = info;
    let parent = specs;
    if (prefix === 'P' && numbers.length > 1) parent = semantic('P' + numbers.slice(0, -1).join('.'));
    else if (prefix === 'S') parent = semantic(numbers.length > 2 ? 'S' + numbers.slice(0, -1).join('.') : 'P' + numbers[0]);
    else if (prefix === 'T') parent = semantic(numbers.length > 3 ? 'T' + numbers.slice(0, -1).join('.') : numbers.length >= 2 ? 'S' + numbers.slice(0, 2).join('.') : 'P' + numbers[0]);
    else if (prefix === 'E') parent = semantic(numbers.length >= 3 ? 'T' + numbers.slice(0, Math.max(3, numbers.length - 1)).join('.') : numbers.length >= 2 ? 'S' + numbers.slice(0, 2).join('.') : 'P' + numbers[0]);
    const node = makeNode(code, code, '', parent);
    node.kind = {P: 'Phase', S: 'Spec', T: 'Task', E: 'Example'}[prefix];
    return node;
  }
  function attach(node, target, title) {
    if (!node.target) {
      node.target = target;
      node.title = title;
    } else {
      // Keep alternate anchors and definitions reachable, with their source in the tooltip.
      node.children.push({key: target.url, title: title || target.path, target, children: []});
    }
  }
  for (const target of targets) {
    const filename = target.path.split('/').pop();
    const fileId = identity(filename.toUpperCase());
    const inSpecs = fileId && ['P', 'S'].includes(fileId.prefix);
    const info = identity(target.label);
    if (inSpecs) {
      const fileRoot = semantic(fileId.code);
      if (info && ['P', 'S', 'T', 'E'].includes(info.prefix)) attach(semantic(info.code), target, info.title);
      else fileRoot.children.push({key: target.url, title: target.label, target, children: []});
    } else {
      if (!files.has(target.path)) {
        const file = makeNode('file:' + target.path, '', filename.replace(/\.md$/i, ''), core);
        file.path = target.path;
        files.set(target.path, file);
      }
      const file = files.get(target.path);
      if (info) {
        const key = target.path + ':' + info.code;
        let parent = file;
        for (let depth = info.numbers.length - 1; depth > 0; depth--) {
          const ancestor = nodes.get(target.path + ':' + info.prefix + info.numbers.slice(0, depth).join('.'));
          if (ancestor) { parent = ancestor; break; }
        }
        const node = nodes.get(key) || makeNode(key, info.code, info.title, parent);
        attach(node, target, info.title);
      } else {
        file.children.push({key: target.url, title: target.label, target, children: []});
      }
    }
  }
  for (const [path, file] of files) {
    const entries = [...nodes.values()].filter(node => node.key.startsWith(path + ':') && node.code);
    for (const node of entries) {
      const info = identity(node.code);
      let parent = file;
      for (let depth = info.numbers.length - 1; depth > 0; depth--) {
        const ancestor = nodes.get(path + ':' + info.prefix + info.numbers.slice(0, depth).join('.'));
        if (ancestor) { parent = ancestor; break; }
      }
      for (const previous of [file, ...entries]) {
        const index = previous.children.indexOf(node);
        if (index >= 0) previous.children.splice(index, 1);
      }
      parent.children.push(node);
    }
  }
  function sort(node) {
    node.children.sort((a, b) => natural.compare(a.code || a.title, b.code || b.title) || natural.compare(a.key, b.key));
    node.children.forEach(sort);
  }
  sort(core);
  sort(specs);
  return [core, specs].filter(node => node.children.length);
}

export function filterIdTree(tree, query) {
  if (!query.trim()) return tree;
  const targets = [];
  const collect = nodes => nodes.forEach(node => { if (node.target) targets.push(node.target); collect(node.children); });
  collect(tree);
  const ranked = rankTargets(targets, query);
  const matched = new Set(ranked);
  const prune = nodes => nodes.flatMap(node => {
    const children = prune(node.children);
    const directMatch = matched.has(node.target);
    return directMatch || children.length ? [{...node, children, directMatch, bestMatch: node.target === ranked[0]}] : [];
  });
  return prune(tree);
}

export function expandIdPath(tree, key, expanded) {
  for (const node of tree) {
    if (node.key === key || expandIdPath(node.children, key, expanded)) {
      if (node.children.length) expanded.add(node.key);
      return true;
    }
  }
  return false;
}

function highlight(element, text, query) {
  const lower = text.toLowerCase();
  const marked = new Set();
  for (const word of query.toLowerCase().trim().split(/\s+/).filter(Boolean)) {
    if (fuzzyScore(text, word) === null) continue;
    let position = lower.indexOf(word);
    if (position >= 0) for (let i = position; i < position + word.length; i++) marked.add(i);
    else {
      position = -1;
      for (const character of word) { position = lower.indexOf(character, position + 1); marked.add(position); }
    }
  }
  Array.from(text).forEach((character, index) => {
    if (marked.has(index)) {
      const mark = document.createElement('mark');
      mark.textContent = character;
      element.append(mark);
    } else element.append(document.createTextNode(character));
  });
}

// Watch patches update the preview and file list while the ID tab stays open.
export function watchIdUpdates(events, refresh) {
  events.addEventListener('datastar-fetch', event => {
    if (event.detail?.type === 'datastar-patch-elements' && event.detail.el?.id === 'watch') refresh();
  });
}

function installIdBrowser() {
  const root = document.querySelector('.id-browser');
  if (!root) return;
  const input = root.querySelector('input');
  const list = root.querySelector('ol');
  const status = root.querySelector('.id-status');
  input.value = new URLSearchParams(location.search).get('id-query') || '';
  let targets = [];
  let tree = [];
  let rows = [];
  const expanded = new Set(['core', 'specs']);
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
    selected = Math.max(0, Math.min(rows.length - 1, index));
    rows.forEach((row, i) => row.control.classList.toggle('selected', i === selected));
    if (rows[selected] && active) rows[selected].control.scrollIntoView({block: 'nearest'});
  }

  function schedulePreview() {
    cancelPreview();
    const row = rows[selected];
    if (active && !loading && !error && row?.node.target) previewTimer = setTimeout(() => row.control.click(), 120);
  }

  function render(shouldPreview = true, selectedKey) {
    cancelPreview();
    const searching = Boolean(input.value.trim());
    const filtered = filterIdTree(tree, input.value);
    const scrollTop = list.scrollTop;
    rows = [];
    list.replaceChildren();
    function appendNodes(nodes, container) {
      for (const node of nodes) {
        const item = document.createElement('li');
        const row = document.createElement('div');
        row.className = 'id-tree-row';
        const open = searching || expanded.has(node.key);
        const toggle = document.createElement('button');
        toggle.type = 'button';
        toggle.className = 'id-tree-toggle';
        toggle.textContent = node.children.length ? (open ? '▾' : '▸') : '';
        toggle.hidden = !node.children.length;
        const toggleBranch = () => {
          if (searching) return;
          if (expanded.has(node.key)) expanded.delete(node.key);
          else expanded.add(node.key);
          render(false, node.key);
          rows.find(entry => entry.node.key === node.key)?.control.focus({preventScroll: true});
        };
        if (node.children.length) {
          toggle.setAttribute('aria-label', `${open ? 'Collapse' : 'Expand'} ${node.code || node.title}`);
          toggle.setAttribute('aria-expanded', String(open));
          toggle.disabled = searching;
          toggle.addEventListener('click', toggleBranch);
        }
        const control = document.createElement(node.target ? 'a' : 'button');
        control.className = 'id-tree-label';
        control.title = [node.kind, node.code, node.title, node.target?.path || node.path].filter(Boolean).join(' · ');
        const index = rows.length;
        rows.push({node, control});
        if (node.target) {
          const url = new URL(node.target.url, location.origin);
          url.searchParams.set('sidebar', 'id');
          if (searching) url.searchParams.set('id-query', input.value);
          control.href = url.pathname + url.search + url.hash;
          control.addEventListener('click', event => {
            if (event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
            event.preventDefault();
            select(index);
            preview(node.target, control.getAttribute('href'));
          });
        } else {
          control.type = 'button';
          control.setAttribute('aria-expanded', String(open));
          control.addEventListener('click', toggleBranch);
        }
        if (node.code) {
          const code = document.createElement('strong');
          highlight(code, node.code, input.value);
          control.append(code);
        }
        if (node.title) {
          const title = document.createElement('span');
          highlight(title, node.title, input.value);
          control.append(title);
        }
        // Paths remain useful when the query matches the source rather than its heading.
        if (searching && node.directMatch && node.target) {
          const path = document.createElement('small');
          highlight(path, node.target.path, input.value);
          control.append(path);
        }
        row.append(toggle, control);
        item.append(row);
        if (node.children.length && open) {
          const children = document.createElement('ol');
          appendNodes(node.children, children);
          item.append(children);
        }
        container.append(item);
      }
    }
    appendNodes(filtered, list);
    status.textContent = loading ? 'Loading IDs…' : error ? 'Could not load IDs. Reopen the tab to retry.'
      : !rows.length ? (searching ? 'No matching IDs' : 'No IDs found') : '';
    if (skipped) status.textContent += ` ${skipped} unreadable file(s) skipped`;
    let current = selectedKey ? rows.findIndex(row => row.node.key === selectedKey) : -1;
    if (current < 0 && searching) current = rows.findIndex(row => row.node.bestMatch);
    if (current < 0) current = rows.findIndex(row => row.node.target?.url === location.pathname + location.hash);
    if (current < 0 && !shouldPreview) {
      current = rows.findIndex(row => row.node.target && new URL(row.node.target.url, location.origin).pathname === location.pathname);
    }
    select(current < 0 ? 0 : current);
    if (selectedKey) list.scrollTop = scrollTop;
    if (shouldPreview) schedulePreview();
  }

  function revealCurrent(nodes, ancestors = []) {
    for (const node of nodes) {
      if (node.target && (node.target.url === location.pathname + location.hash ||
          (!location.hash && new URL(node.target.url, location.origin).pathname === location.pathname))) {
        ancestors.forEach(key => expanded.add(key));
        return true;
      }
      if (revealCurrent(node.children, [...ancestors, node.key])) return true;
    }
    return false;
  }

  async function refresh(background = false) {
    const selectedKey = background ? rows[selected]?.node.key : undefined;
    request?.abort();
    const initialQuery = input.value;
    loading = true;
    error = false;
    skipped = 0;
    render(false, selectedKey);
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
    const queryChanged = input.value !== initialQuery;
    // A file chosen in Files may be excluded by the previous ID query.
    const inCurrentFile = target => new URL(target.url, location.origin).pathname === location.pathname;
    if (!background && !queryChanged && targets.some(inCurrentFile) && !rankTargets(targets, input.value).some(inCurrentFile)) input.value = '';
    tree = buildIdTree(targets);
    revealCurrent(tree);
    render(!background && queryChanged, selectedKey);
  }

  function navigate(key) {
    if (key === 'Enter') rows[selected]?.control.click();
    else {
      select(selected + (key === 'ArrowDown' || key === 'j' ? 1 : -1));
      if (list.contains(document.activeElement)) rows[selected]?.control.focus({preventScroll: true});
      schedulePreview();
    }
  }

  list.addEventListener('keydown', event => {
    if (event.key === 'Enter' || event.key === ' ') event.stopPropagation();
  });
  input.addEventListener('input', () => render());
  input.addEventListener('keydown', event => {
    if (event.isComposing || event.metaKey || event.ctrlKey || event.altKey) return;
    if (['ArrowDown', 'ArrowUp', 'Enter'].includes(event.key)) {
      event.preventDefault();
      event.stopPropagation();
      navigate(event.key);
    }
  });
  document.addEventListener('gitmd-id-clear', () => {
    const key = rows[selected]?.node.key;
    input.value = '';
    if (key) expandIdPath(tree, key, expanded);
    render(true, key);
    rows[selected]?.control.scrollIntoView({block: 'nearest'});
  });
  document.addEventListener('gitmd-id-key', event => navigate(event.detail));
  watchIdUpdates(document, () => {
    if (active) refresh(true);
  });
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
