package main

import "core:encoding/entity"
import "core:fmt"
import "core:net"
import "core:strings"

DATSTAR_BUNDLE :: #load("assets/datastar-1.0.3.js")

html_escape :: proc(value: string) -> string {
	escaped, allocated := entity.escape_html(value)
	if allocated {
		return escaped
	}
	return strings.clone(escaped)
}

preview_fragment :: proc(commit: ^Commit) -> string {
	return fmt.aprintf(
		`<article id="preview" class="markdown-body" aria-label="Markdown preview">%s</article>`,
		commit.html,
	)
}

watch_fragment :: proc(history: ^History, selected_commit: int) -> string {
	path := net.percent_encode(history.path, context.temp_allocator)
	commit_hash := history.commits[selected_commit].full_hash
	if history.commits[selected_commit].working { commit_hash = "working" }
	commit := net.percent_encode(commit_hash, context.temp_allocator)
	return fmt.aprintf(`<div id="watch" data-init="@get('/watch?path=%s&amp;commit=%s', {{requestCancellation: 'cleanup'}})"></div>`, path, commit)
}

sse_patch_elements :: proc(elements: string) -> string {
	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)
	strings.write_string(&builder, "event: datastar-patch-elements\n")
	for line in strings.split(elements, "\n") {
		strings.write_string(&builder, "data: elements ")
		strings.write_string(&builder, line)
		strings.write_byte(&builder, '\n')
	}
	strings.write_byte(&builder, '\n')
	return strings.clone(strings.to_string(builder))
}

sidebar_path_fragment :: proc(path: string) -> string {
	return fmt.aprintf(`<span id="sidebar-path">%s</span>`, html_escape(path))
}

render_sidebar_search :: proc(panel: string) -> string {
	return fmt.aprintf(`<form class="sidebar-search" role="search" data-show="$%sSearching" data-on:submit="evt.preventDefault()">
<label for="%s-search-input" aria-label="Filter %s">/</label>
<input id="%s-search-input" type="search" autocomplete="off" autocapitalize="off" spellcheck="false" aria-label="Filter %s" data-on:keydown="if (!['Escape','ArrowUp','ArrowDown'].includes(evt.key)) evt.stopPropagation()" data-on:input="const query = evt.currentTarget.value.toLowerCase(); evt.currentTarget.closest('section').querySelectorAll('li').forEach(item => {{ const text = item.textContent.toLowerCase(); let position = -1; item.hidden = !Array.from(query).every(character => (position = text.indexOf(character, position + 1)) >= 0) }})">
</form>`, panel, panel, panel, panel, panel)
}

repository_url :: proc(path: string) -> string {
	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)
	strings.write_byte(&builder, '/')
	parts := strings.split(path, "/")
	for part, index in parts {
		if index > 0 { strings.write_byte(&builder, '/') }
		strings.write_string(&builder, net.percent_encode(part, context.temp_allocator))
	}
	return strings.clone(strings.to_string(builder))
}

render_hashes :: proc(history: ^History) -> string {
	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)
	strings.write_byte(&builder, '[')
	for commit, index in history.commits {
		if index > 0 { strings.write_byte(&builder, ',') }
		fmt.sbprintf(&builder, "'%s'", commit.short_hash)
	}
	strings.write_byte(&builder, ']')
	return strings.clone(strings.to_string(builder))
}

display_timestamp :: proc(author_date: string) -> string {
	if len(author_date) < 16 || author_date[4] != '-' || author_date[7] != '-' || author_date[10] != 'T' || author_date[13] != ':' {
		return author_date
	}
	return fmt.aprintf(
		"%s.%s.%s %s",
		author_date[:4],
		author_date[5:7],
		author_date[8:10],
		author_date[11:16],
	)
}

render_outline :: proc(commit: ^Commit) -> string {
	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)
	strings.write_string(&builder, `<section id="outline" class="outline" aria-label="Document outline" data-show="$sidebar === 'outline'">`)
	strings.write_string(&builder, render_sidebar_search("outline"))
	strings.write_string(&builder, `<ol>`)
	position := 0
	for position < len(commit.html) {
		relative_start := strings.index(commit.html[position:], "<h")
		if relative_start < 0 { break }
		start := position + relative_start
		if start + 8 >= len(commit.html) || commit.html[start + 2] < '1' || commit.html[start + 2] > '6' || commit.html[start + 3:start + 8] != ` id="` {
			position = start + 2
			continue
		}
		level := commit.html[start + 2]
		id_start := start + 8
		id_relative_end := strings.index(commit.html[id_start:], `">`)
		if id_relative_end < 0 { break }
		id_end := id_start + id_relative_end
		inner_start := id_end + 2
		close := fmt.aprintf("</h%c>", level)
		inner_relative_end := strings.index(commit.html[inner_start:], close)
		if inner_relative_end < 0 { break }
		inner_end := inner_start + inner_relative_end
		text := strip_html_tags(commit.html[inner_start:inner_end])
		fmt.sbprintf(
			&builder,
			`<li class="outline-level-%c"><a href="#%s">%s</a></li>`,
			level,
			commit.html[id_start:id_end],
			html_escape(text),
		)
		position = inner_end + len(close)
	}
	strings.write_string(&builder, "</ol></section>")
	return strings.clone(strings.to_string(builder))
}

render_history :: proc(history: ^History, selected_commit: int) -> string {
	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)
	strings.write_string(&builder, `<section id="history" class="history" aria-label="Commit history" data-show="$sidebar === 'history'">`)
	strings.write_string(&builder, render_sidebar_search("history"))
	strings.write_string(&builder, `<ol>`)
	for commit, index in history.commits {
		date := display_timestamp(commit.author_date)
		selected_class := ""
		if index == selected_commit {
			selected_class = ` class="selected" aria-current="page"`
		}
		url := repository_url(history.path)
		fmt.sbprintf(&builder, `
<li><a id="commit-%s"%s href="%s?commit=%s&amp;sidebar=history" data-index="%d" data-on:click="evt.preventDefault(); clearTimeout($historyTimer); const current = evt.currentTarget.closest('.history').querySelector('a.selected'); if (current !== evt.currentTarget) {{ current?.classList.remove('selected'); current?.removeAttribute('aria-current'); evt.currentTarget.classList.add('selected'); evt.currentTarget.setAttribute('aria-current', 'page') }}; $selected = %d; @get('%s?commit=%s&amp;partial=1'); history.replaceState(null, '', evt.currentTarget.href)">
<span class="commit-subject">%s</span><span class="commit-meta"><code>%s</code><time datetime="%s">%s</time></span>
</a></li>`, commit.full_hash, selected_class, url, commit.short_hash, index, index, url, commit.full_hash, html_escape(commit.subject), commit.short_hash, html_escape(commit.author_date), date)
	}
	strings.write_string(&builder, "\n</ol></section>")
	return strings.clone(strings.to_string(builder))
}

render_files :: proc(repository: ^Repository) -> string {
	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)
	strings.write_string(&builder, `<section id="files" class="file-browser" aria-label="Markdown files" data-show="$sidebar === 'files'">
`)
	strings.write_string(&builder, render_sidebar_search("files"))
	strings.write_string(&builder, `<ol>`)
	for file, index in repository.files {
		selected_class := ""
		if index == repository.selected_file {
			selected_class = fmt.aprintf(
				` class="selected" aria-current="page" data-init="document.getElementById('file-%d').scrollIntoView({{block:'nearest'}})"`,
				index,
			)
		}
		url := repository_url(file)
		fmt.sbprintf(&builder, `
<li><a id="file-%d"%s href="%s" data-path="%s" data-on:click="evt.preventDefault(); const current = evt.currentTarget.closest('.file-browser').querySelector('a.selected'); if (current !== evt.currentTarget) {{ current?.classList.remove('selected'); current?.removeAttribute('aria-current'); evt.currentTarget.classList.add('selected'); evt.currentTarget.setAttribute('aria-current', 'page') }}; evt.currentTarget.focus({{preventScroll:true}}); evt.currentTarget.scrollIntoView({{block:'nearest'}}); $selected = 0; @get('%s?partial=1'); history.replaceState(null, '', evt.currentTarget.href); document.title = evt.currentTarget.dataset.path + ' · gitmd'"><span class="file-icon" aria-hidden="true">#</span>%s</a></li>`, index, selected_class, url, html_escape(file), url, html_escape(file))
	}
	strings.write_string(&builder, "\n</ol></section>")
	return strings.clone(strings.to_string(builder))
}

snapshot_fragments :: proc(history: ^History, selected_commit: int) -> string {
	return strings.concatenate({
		watch_fragment(history, selected_commit),
		preview_fragment(&history.commits[selected_commit]),
		render_outline(&history.commits[selected_commit]),
	})
}

file_fragments :: proc(history: ^History, selected_commit: int) -> string {
	return strings.concatenate({
		sidebar_path_fragment(history.path),
		watch_fragment(history, selected_commit),
		preview_fragment(&history.commits[selected_commit]),
		render_history(history, selected_commit),
		render_outline(&history.commits[selected_commit]),
	})
}

initial_page :: proc(history: ^History, repository: ^Repository = nil, selected_commit := 0, sidebar_mode := "") -> string {
	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)
	hashes := render_hashes(history)
	path := html_escape(history.path)
	sidebar := sidebar_mode
	if sidebar != "files" && sidebar != "history" && sidebar != "outline" {
		sidebar = "files"
		if repository == nil { sidebar = "history" }
	}
	if repository == nil && sidebar == "files" { sidebar = "history" }
	fmt.sbprintf(&builder, `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>%s · gitmd</title>
<link rel="stylesheet" href="/style.css">
<script type="module" src="/datastar.js"></script>
</head>
<body data-signals="{{selected: %d, hashes: %s, sidebar: '%s', sidebarOpen: true, resizing: false, filesSearching: false, historySearching: false, outlineSearching: false, panel: 'sidebar', fileTimer: 0, historyTimer: 0}}"
 data-on:keydown__window="if ((($sidebar === 'files' && $filesSearching) || ($sidebar === 'history' && $historySearching) || ($sidebar === 'outline' && $outlineSearching)) && evt.key === 'Escape') {{ evt.preventDefault(); const section = document.querySelector($sidebar === 'files' ? '.file-browser' : $sidebar === 'history' ? '.history' : '.outline'); const input = section.querySelector('.sidebar-search input'); input.value = ''; section.querySelectorAll('li').forEach(item => item.hidden = false); if ($sidebar === 'files') $filesSearching = false; else if ($sidebar === 'history') $historySearching = false; else $outlineSearching = false; document.querySelector('.sidebar').focus() }} else if (!evt.metaKey && !evt.ctrlKey && !evt.altKey && !evt.shiftKey && evt.key === '/') {{ evt.preventDefault(); $sidebarOpen = true; $panel = 'sidebar'; if ($sidebar === 'files') $filesSearching = true; else if ($sidebar === 'history') $historySearching = true; else $outlineSearching = true; setTimeout(() => document.querySelector($sidebar === 'files' ? '.file-browser' : $sidebar === 'history' ? '.history' : '.outline').querySelector('.sidebar-search input').focus()) }} else if (evt.metaKey && !evt.ctrlKey && !evt.altKey && !evt.shiftKey && evt.key === 'b') {{ evt.preventDefault(); $sidebarOpen = !$sidebarOpen; $panel = $sidebarOpen ? 'sidebar' : 'main' }} else if (!evt.metaKey && !evt.ctrlKey && !evt.altKey && !evt.shiftKey && ['1','2','3'].includes(evt.key)) {{ evt.preventDefault(); $sidebar = ['files','history','outline'][Number(evt.key) - 1]; $sidebarOpen = true; $panel = 'sidebar' }} else if (!evt.metaKey && !evt.ctrlKey && !evt.altKey && !evt.shiftKey && ['ArrowLeft','h','ArrowRight','l'].includes(evt.key)) {{ evt.preventDefault(); if (['ArrowLeft','h'].includes(evt.key)) {{ $sidebarOpen = true; $panel = 'sidebar'; setTimeout(() => document.querySelector('.sidebar').focus()) }} else {{ $panel = 'main'; document.querySelector('.preview-pane').focus() }} }} else if (!evt.metaKey && !evt.ctrlKey && !evt.altKey && !evt.shiftKey && ['ArrowUp','k','ArrowDown','j'].includes(evt.key)) {{ evt.preventDefault(); const previous = ['ArrowUp','k'].includes(evt.key); if ($panel === 'main') {{ document.querySelector('.preview-pane').scrollBy(0, previous ? -80 : 80) }} else {{ const section = document.querySelector($sidebar === 'files' ? '.file-browser' : $sidebar === 'history' ? '.history' : '.outline'); const links = section ? Array.from(section.querySelectorAll('a')).filter(link => !link.closest('li').hidden) : []; if (links.length) {{ let current = links.indexOf(section.querySelector('a.selected')); if (current < 0) current = links.indexOf(document.activeElement); if (current < 0) current = links.findIndex(link => link.getAttribute('aria-current') === 'page' || (location.hash && link.hash === location.hash)); const next = Math.max(0, Math.min(links.length - 1, current + (previous ? -1 : 1))); if (next !== current) {{ if ($sidebar === 'history') {{ const selected = section.querySelector('a.selected'); selected?.classList.remove('selected'); selected?.removeAttribute('aria-current'); links[next].classList.add('selected'); links[next].setAttribute('aria-current', 'page'); $selected = Number(links[next].dataset.index); links[next].scrollIntoView({{block:'nearest'}}); clearTimeout($historyTimer); const target = links[next]; $historyTimer = setTimeout(() => target.click(), 0) }} else if ($sidebar === 'files') {{ const selected = section.querySelector('a.selected'); selected?.classList.remove('selected'); selected?.removeAttribute('aria-current'); links[next].classList.add('selected'); links[next].setAttribute('aria-current', 'page'); links[next].focus({{preventScroll:true}}); links[next].scrollIntoView({{block:'nearest'}}); clearTimeout($fileTimer); const target = links[next]; $fileTimer = setTimeout(() => target.click(), 0) }} else links[next].click() }} if ($sidebar === 'outline' || next === current) links[next].focus() }} }} }}">
<main class="layout" data-class:sidebar-hidden="!$sidebarOpen" data-class:resizing="$resizing">
<aside class="sidebar" tabindex="-1" data-class:panel-selected="$panel === 'sidebar'" data-on:pointerdown="$panel = 'sidebar'">
<header><strong>gitmd</strong><span id="sidebar-path">%s</span></header>
<nav class="sidebar-tabs" aria-label="Sidebar mode">
<button type="button" aria-keyshortcuts="1" data-class:selected="$sidebar === 'files'" data-on:click="$sidebar = 'files'; $panel = 'sidebar'">Files</button>
<button type="button" aria-keyshortcuts="2" data-class:selected="$sidebar === 'history'" data-on:click="$sidebar = 'history'; $panel = 'sidebar'">History</button>
<button type="button" aria-keyshortcuts="3" data-class:selected="$sidebar === 'outline'" data-on:click="$sidebar = 'outline'; $panel = 'sidebar'">Outline</button>
</nav>`, path, selected_commit, hashes, sidebar, path)
	if repository != nil {
		strings.write_string(&builder, "\n")
		strings.write_string(&builder, render_files(repository))
	}
	strings.write_string(&builder, render_history(history, selected_commit))
	strings.write_string(&builder, render_outline(&history.commits[selected_commit]))
	strings.write_string(&builder, watch_fragment(history, selected_commit))
	strings.write_string(&builder, `</aside>
<div class="sidebar-resizer" role="separator" aria-label="Resize sidebar" aria-orientation="vertical" aria-valuemin="160" aria-valuemax="640" aria-valuenow="260" tabindex="0"
 data-on:pointerdown="evt.preventDefault(); $resizing = true"
 data-on:pointermove__window="if ($resizing) { const width = Math.max(160, Math.min(640, Math.min(evt.clientX, window.innerWidth - 160))); document.documentElement.style.setProperty('--sidebar-width', width + 'px'); document.querySelector('.sidebar-resizer').setAttribute('aria-valuenow', Math.round(width)) }"
 data-on:pointerup__window="$resizing = false"
 data-on:pointercancel__window="$resizing = false"
 data-on:keydown="if (['ArrowLeft','ArrowRight'].includes(evt.key)) { evt.preventDefault(); evt.stopPropagation(); const width = Math.max(160, Math.min(640, parseFloat(getComputedStyle(document.querySelector('.sidebar')).width) + (evt.key === 'ArrowLeft' ? -20 : 20))); document.documentElement.style.setProperty('--sidebar-width', width + 'px'); evt.currentTarget.setAttribute('aria-valuenow', Math.round(width)) }"></div>
<section class="preview-pane" tabindex="-1" data-class:panel-selected="$panel === 'main'" data-on:pointerdown="$panel = 'main'">`)
	strings.write_string(&builder, preview_fragment(&history.commits[selected_commit]))
	strings.write_string(&builder, "</section>\n</main>\n</body>\n</html>\n")
	return strings.clone(strings.to_string(builder))
}

STYLESHEET :: `:root { color-scheme: light dark; --bg:#fff; --fg:#1f2328; --muted:#656d76; --border:#d0d7de; --subtle:#f6f8fa; --selected:#ddf4ff; --accent:#0969da; --sidebar-width:minmax(260px,23vw); }
@media (prefers-color-scheme:dark) { :root { --bg:#0d1117; --fg:#e6edf3; --muted:#8d96a0; --border:#30363d; --subtle:#161b22; --selected:#122d42; --accent:#58a6ff; } }
* { box-sizing:border-box; }
html, body { height:100%; margin:0; }
body { background:var(--bg); color:var(--fg); font:14px -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif; overflow:hidden; }
.layout { display:grid; grid-template-columns:var(--sidebar-width) 6px minmax(0,1fr); height:100vh; }
.layout.sidebar-hidden { grid-template-columns:1fr; }
.layout.sidebar-hidden .sidebar,.layout.sidebar-hidden .sidebar-resizer { display:none; }
.layout.sidebar-hidden .preview-pane { grid-column:1; }
.layout.resizing { cursor:col-resize; user-select:none; }
.sidebar { display:flex; min-height:0; flex-direction:column; overflow:hidden; user-select:none; background:var(--subtle); }
.sidebar-resizer { position:relative; cursor:col-resize; touch-action:none; background:var(--bg); }
.sidebar-resizer::after { position:absolute; inset:0 2px; content:""; background:var(--border); }
.sidebar-resizer:hover::after,.sidebar-resizer:focus-visible::after,.layout.resizing .sidebar-resizer::after { background:var(--accent); }
.sidebar.panel-selected { background:color-mix(in srgb,var(--selected) 28%,var(--subtle)); }
.preview-pane.panel-selected { background:color-mix(in srgb,var(--selected) 18%,var(--bg)); }
.sidebar:focus,.preview-pane:focus { outline:none; }
.sidebar header { display:flex; flex-direction:column; gap:4px; padding:16px; border-bottom:1px solid var(--border); }
.sidebar header strong { font-size:18px; }.sidebar header span { color:var(--muted); overflow-wrap:anywhere; }
.sidebar-tabs { display:grid; flex:none; grid-template-columns:repeat(3,1fr); padding:8px; gap:6px; border-bottom:1px solid var(--border); background:var(--subtle); }
.sidebar-tabs button { padding:7px; border:1px solid transparent; border-radius:6px; background:transparent; color:var(--muted); cursor:pointer; font-weight:600; }.sidebar-tabs button:hover { color:var(--fg); }.sidebar-tabs button.selected { color:var(--fg); border-color:var(--border); background:var(--bg); }
.file-browser,.history,.outline { display:flex; flex:1; min-height:0; flex-direction:column; overflow:hidden; }
.file-browser>ol,.history>ol,.outline>ol { flex:1; min-height:0; overflow:auto; overflow-anchor:none; scroll-padding-block:1px; }
.file-browser ol { list-style:none; padding:8px; margin:0; }.file-browser a { display:flex; gap:8px; align-items:center; padding:8px; border-radius:6px; color:inherit; text-decoration:none; overflow-wrap:anywhere; }.file-icon { color:var(--muted); font-family:ui-monospace,SFMono-Regular,Consolas,monospace; }
.history ol { list-style:none; padding:0; margin:0; }
.history a { display:block; width:100%; padding:12px 16px; border-bottom:1px solid var(--border); color:inherit; text-align:left; text-decoration:none; cursor:pointer; }
.commit-subject { display:block; margin-bottom:6px; font-weight:600; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
.commit-meta { display:flex; justify-content:space-between; gap:8px; color:var(--muted); font-size:12px; }.commit-meta code { color:var(--accent); }
.outline ol { list-style:none; padding:8px; margin:0; }.outline a { display:block; padding:7px 8px; border-radius:6px; color:inherit; text-decoration:none; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }.outline-level-2 a { padding-left:20px; }.outline-level-3 a { padding-left:32px; }.outline-level-4 a { padding-left:44px; }.outline-level-5 a { padding-left:56px; }.outline-level-6 a { padding-left:68px; }
.file-browser a:hover,.history a:hover,.outline a:hover,.file-browser a:focus-visible,.history a:focus-visible,.outline a:focus-visible { background:color-mix(in srgb,var(--selected) 55%,transparent); outline:none; }
.file-browser a.selected,.history a.selected,.outline a.selected { background:var(--selected); }
.sidebar-search { display:flex; flex:none; align-items:center; gap:6px; padding:8px 12px; border-bottom:1px solid var(--border); background:var(--subtle); }.sidebar-search label { color:var(--muted); font:14px ui-monospace,SFMono-Regular,Consolas,monospace; }.sidebar-search input { min-width:0; width:100%; padding:6px 8px; border:1px solid var(--border); border-radius:5px; outline:none; background:var(--bg); color:var(--fg); font:14px ui-monospace,SFMono-Regular,Consolas,monospace; }.sidebar-search input:focus { border-color:var(--accent); box-shadow:0 0 0 1px var(--accent); }
#watch { display:none; }
.preview-pane { grid-column:3; overflow:auto; user-select:text; }.markdown-body { max-width:980px; margin:0 auto; padding:40px 48px 80px; font-size:16px; line-height:1.5; overflow-wrap:break-word; }
.markdown-body h1,.markdown-body h2 { border-bottom:1px solid var(--border); padding-bottom:.3em; }.markdown-body h1 { font-size:2em; }.markdown-body h2 { font-size:1.5em; }
.markdown-body a { color:var(--accent); }.markdown-body img { max-width:100%; }.markdown-body blockquote { margin:0; padding:0 1em; color:var(--muted); border-left:.25em solid var(--border); }
.markdown-body code { padding:.2em .4em; border-radius:6px; background:var(--subtle); font:85% ui-monospace,SFMono-Regular,Consolas,monospace; }
.markdown-body pre { overflow:auto; padding:16px; border-radius:6px; background:var(--subtle); }.markdown-body pre code { padding:0; background:transparent; font-size:100%; }
.markdown-body table { display:block; width:max-content; max-width:100%; overflow:auto; border-spacing:0; border-collapse:collapse; }.markdown-body th,.markdown-body td { padding:6px 13px; border:1px solid var(--border); }.markdown-body tr:nth-child(2n) { background:var(--subtle); }
.markdown-body hr { height:.25em; padding:0; margin:24px 0; background:var(--border); border:0; }.markdown-body input[type=checkbox] { margin:0 .5em 0 0; }
@media (max-width:700px) { :root { --sidebar-width:190px; }.markdown-body { padding:24px 20px 60px; } }
`
