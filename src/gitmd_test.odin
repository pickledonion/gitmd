package main

import "core:os"
import "core:dynlib"
import "core:net"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "core:thread"
import "core:time"

test_path :: proc(parts: ..string) -> string {
	path, _ := filepath.join(parts[:])
	return path
}

must_git :: proc(t: ^testing.T, root: string, args: []string) -> Command_Result {
	command := make([dynamic]string, 0, len(args) + 1)
	append(&command, "/usr/bin/git")
	append(&command, ..args)
	result := run_command(root, command[:])
	if !testing.expectf(t, result.ok, "git command failed: %s", result.stderr) {
		testing.fail_now(t)
	}
	return result
}

must_write :: proc(t: ^testing.T, path, contents: string) {
	if err := os.write_entire_file(path, contents); err != nil {
		testing.fail_now(t, "could not write fixture")
	}
}

receive_until :: proc(socket: net.TCP_Socket, needle: string) -> (string, bool) {
	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)
	buffer: [16384]byte
	for _ in 0 ..< 8 {
		n, err := net.recv_tcp(socket, buffer[:])
		if err != nil || n <= 0 { break }
		strings.write_string(&builder, string(buffer[:n]))
		received := strings.to_string(builder)
		if strings.contains(received, needle) {
			return strings.clone(received), true
		}
	}
	return strings.clone(strings.to_string(builder)), false
}

make_fixture :: proc(t: ^testing.T) -> (root, current_path: string) {
	err: os.Error
	root, err = os.make_directory_temp("", "gitmd-tests-*", context.allocator)
	if err != nil { testing.fail_now(t, "could not create fixture") }
	if err = os.make_directory(test_path(root, "docs with spaces")); err != nil {
		testing.fail_now(t, "could not create fixture directory")
	}
	must_git(t, root, []string{"init", "-q"})
	must_git(t, root, []string{"config", "user.name", "Test Author"})
	must_git(t, root, []string{"config", "user.email", "test@example.test"})
	original := test_path(root, "docs with spaces", "old name.md")
	initial := "# First\n\nA deliberately long paragraph keeps Git rename detection deterministic across this fixture. A deliberately long paragraph keeps Git rename detection deterministic across this fixture.\n"
	must_write(t, original, initial)
	must_git(t, root, []string{"add", "--", "docs with spaces/old name.md"})
	must_git(t, root, []string{"commit", "-q", "-m", "first subject"})
	must_git(t, root, []string{"mv", "--", "docs with spaces/old name.md", "docs with spaces/new name.md"})
	must_git(t, root, []string{"commit", "-q", "-m", "rename subject"})
	current_path = test_path(root, "docs with spaces", "new name.md")
	must_write(t, current_path, strings.concatenate({initial, "\nSecond snapshot.\n"}))
	must_git(t, root, []string{"add", "--", "docs with spaces/new name.md"})
	must_git(t, root, []string{"commit", "-q", "-m", "newest subject"})
	return root, current_path
}

@(test)
history_metadata_snapshots_and_rename :: proc(t: ^testing.T) {
	root, path := make_fixture(t)
	defer os.remove_all(root)
	history, message, ok := load_history(path)
	testing.expectf(t, ok, "load_history failed: %s", message)
	if !ok { return }
	testing.expect_value(t, len(history.commits), 4)
	testing.expect(t, history.commits[0].working)
	testing.expect_value(t, history.commits[0].subject, "Working tree")
	testing.expect_value(t, history.commits[1].subject, "newest subject")
	testing.expect_value(t, history.commits[2].subject, "rename subject")
	testing.expect_value(t, history.commits[3].subject, "first subject")
	testing.expect_value(t, history.commits[0].path, "docs with spaces/new name.md")
	testing.expect_value(t, history.commits[3].path, "docs with spaces/old name.md")
	testing.expect(t, strings.contains(history.commits[0].markdown, "Second snapshot."))
	testing.expect(t, !strings.contains(history.commits[3].markdown, "Second snapshot."))
	testing.expect_value(t, len(history.commits[1].full_hash), 40)
	testing.expect(t, len(history.commits[1].author_date) >= 10)
}

@(test)
gfm_extensions_and_safety :: proc(t: ^testing.T) {
	api, message, ok := load_cmark()
	testing.expectf(t, ok, "%s", message)
	if !ok { return }
	defer dynlib.unload_library(api.ext_library)
	defer dynlib.unload_library(api.core_library)
	markdown := "| A | B |\n|---|---|\n| 1 | 2 |\n\n- [x] done\n\n~~gone~~\n\n```odin\nx := 1\n```\n\n<script>alert(1)</script>\n\n[bad](javascript:alert(1))\n"
	html, rendered := render_markdown(&api, markdown)
	testing.expect(t, rendered)
	testing.expect(t, strings.contains(html, "<table>"))
	testing.expect(t, strings.contains(html, "type=\"checkbox\""))
	testing.expect(t, strings.contains(html, "<del>gone</del>"))
	testing.expect(t, strings.contains(html, "<pre><code class=\"language-odin\">"))
	testing.expect(t, !strings.contains(html, "<script>"))
	testing.expect(t, !strings.contains(html, "javascript:"))
}

@(test)
heading_and_explicit_anchor_fragments_are_rendered :: proc(t: ^testing.T) {
	api, message, ok := load_cmark()
	testing.expectf(t, ok, "%s", message)
	if !ok { return }
	defer dynlib.unload_library(api.ext_library)
	defer dynlib.unload_library(api.core_library)
	markdown := "# Hello, World!\n\n# Hello World\n\n- <a id=\"-p01-worker-s01s0001-workermd\"></a> worker\n"
	html, rendered := render_markdown(&api, markdown)
	testing.expect(t, rendered)
	testing.expect(t, strings.contains(html, `<h1 id="hello-world">Hello, World!</h1>`))
	testing.expect(t, strings.contains(html, `<h1 id="hello-world-1">Hello World</h1>`))
	testing.expect(t, strings.contains(html, `<a id="-p01-worker-s01s0001-workermd"></a>`))
}

@(test)
safe_pre_blocks_render_as_literal_code :: proc(t: ^testing.T) {
	api, message, ok := load_cmark()
	testing.expectf(t, ok, "%s", message)
	if !ok { return }
	defer dynlib.unload_library(api.ext_library)
	defer dynlib.unload_library(api.core_library)
	markdown := "<pre>\nline one\n```example\n<script>alert(1)</script>\n```\n</pre>\n"
	html, rendered := render_markdown(&api, markdown)
	testing.expect(t, rendered)
	testing.expect(t, strings.contains(html, "<pre><code>line one"))
	testing.expect(t, strings.contains(html, "&lt;script&gt;alert(1)&lt;/script&gt;"))
	testing.expect(t, !strings.contains(html, "<script>"))
}

@(test)
snapshot_routes_are_fragments :: proc(t: ^testing.T) {
	history := History{commits = make([dynamic]Commit, 0)}
	append(&history.commits, Commit{full_hash = "0123456789012345678901234567890123456789", html = "<h1>Hello</h1>"})
	valid := route_request("GET", "/snapshot/0123456789012345678901234567890123456789", &history, "page")
	testing.expect_value(t, valid.status, 200)
	testing.expect(t, strings.has_prefix(valid.body, `<div id="watch"></div><article id="preview"`))
	testing.expect(t, strings.contains(valid.body, "<h1>Hello</h1>"))
	testing.expect(t, !strings.contains(valid.body, `id="history"`))
	testing.expect(t, strings.contains(valid.body, `id="outline"`))
	testing.expect(t, !strings.contains(valid.body, "<html"))
	invalid := route_request("GET", "/snapshot/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", &history, "page")
	testing.expect_value(t, invalid.status, 404)
	page := initial_page(&history)
	testing.expect(t, !strings.contains(page, "%!("))
	testing.expect(t, strings.contains(page, "data-signals=\"{selected: 0"))
	testing.expect(t, strings.contains(page, "sidebarOpen: true"))
	testing.expect(t, strings.contains(page, "resizing: false"))
	testing.expect(t, strings.contains(page, "filesSearching: false"))
	testing.expect(t, strings.contains(page, "historySearching: false"))
	testing.expect(t, strings.contains(page, "outlineSearching: false"))
	testing.expect(t, strings.contains(page, "panel: 'sidebar'"))
	testing.expect(t, strings.contains(page, "fileTimer: 0"))
	testing.expect(t, strings.contains(page, "evt.metaKey"))
	testing.expect(t, strings.contains(page, "$sidebarOpen = !$sidebarOpen"))
	testing.expect(t, strings.contains(page, `['1','2','3'].includes(evt.key)`))
	testing.expect(t, strings.contains(page, `$sidebar = ['files','history','outline'][Number(evt.key) - 1]`))
	testing.expect(t, strings.contains(page, `['ArrowLeft','h','ArrowRight','l'].includes(evt.key)`))
	testing.expect(t, strings.contains(page, `document.querySelector('.preview-pane').scrollBy(0, previous ? -80 : 80)`))
	testing.expect(t, strings.contains(page, `Array.from(section.querySelectorAll('a')).filter(link => !link.closest('li').hidden)`))
	testing.expect(t, strings.contains(page, `links[next].scrollIntoView({block:'nearest'})`))
	testing.expect(t, strings.contains(page, `let current = links.indexOf(section.querySelector('a.selected'))`))
	testing.expect(t, strings.contains(page, `$fileTimer = setTimeout(() => target.click(), 0)`))
	testing.expect(t, strings.contains(page, `$historyTimer = setTimeout(() => target.click(), 0)`))
	testing.expect(t, strings.contains(page, `evt.key === '/'`))
	testing.expect(t, strings.contains(page, `evt.key === 'Escape'`))
	testing.expect(t, strings.contains(page, `class="sidebar-search"`))
	testing.expect(t, strings.contains(page, `id="history-search-input"`))
	testing.expect(t, strings.contains(page, `id="outline-search-input"`))
	testing.expect(t, strings.contains(page, `data-show="$historySearching"`))
	testing.expect(t, strings.contains(page, `data-show="$outlineSearching"`))
	testing.expect(t, strings.contains(page, `if (!['Escape','ArrowUp','ArrowDown'].includes(evt.key)) evt.stopPropagation()`))
	testing.expect(t, strings.contains(page, `data-on:input="const query = evt.currentTarget.value.toLowerCase()`))
	testing.expect(t, strings.contains(page, `evt.currentTarget.closest('section').querySelectorAll('li')`))
	testing.expect(t, strings.contains(page, `section.querySelectorAll('li').forEach(item => item.hidden = false)`))
	testing.expect(t, strings.contains(page, `Array.from(query).every(character => (position = text.indexOf(character, position + 1)) >= 0)`))
	testing.expect(t, !strings.contains(page, `textContent.toLowerCase().includes(query)`))
	testing.expect(t, strings.contains(page, `@get('/snapshot/0123456789012345678901234567890123456789')`))
	testing.expect(t, strings.contains(page, `data-class:sidebar-hidden="!$sidebarOpen"`))
	testing.expect(t, strings.contains(page, `role="separator" aria-label="Resize sidebar"`))
	testing.expect(t, strings.contains(page, `data-on:pointermove__window="if ($resizing)`))
	testing.expect(t, strings.contains(page, `style.setProperty('--sidebar-width', width + 'px')`))
	testing.expect(t, strings.contains(page, "!evt.metaKey"))
	testing.expect(t, !strings.contains(page, "$evt"))
}

@(test)
git_operations_leave_dirty_tree_unchanged :: proc(t: ^testing.T) {
	root, path := make_fixture(t)
	defer os.remove_all(root)
	must_write(t, path, "dirty working-copy contents\n")
	must_write(t, test_path(root, "untracked file"), "leave me alone\n")
	before := must_git(t, root, []string{"status", "--porcelain=v1", "-z"}).stdout
	history, message, ok := load_history(path)
	testing.expectf(t, ok, "load_history failed: %s", message)
	if ok {
		history.commits[0].html = "<p>cached</p>"
		target := strings.concatenate({"/snapshot/", history.commits[0].full_hash})
		response := route_request("GET", target, &history, "page")
		testing.expect_value(t, response.status, 200)
	}
	after := must_git(t, root, []string{"status", "--porcelain=v1", "-z"}).stdout
	testing.expect_value(t, after, before)
}

@(test)
untracked_markdown_and_invalid_inputs :: proc(t: ^testing.T) {
	root, path := make_fixture(t)
	defer os.remove_all(root)
	untracked := test_path(root, "untracked.md")
	must_write(t, untracked, "nothing committed\n")
	history, message, loaded := load_history(untracked)
	testing.expectf(t, loaded, "load_history failed: %s", message)
	if loaded {
		testing.expect_value(t, len(history.commits), 1)
		testing.expect(t, history.commits[0].working)
		testing.expect_value(t, history.commits[0].markdown, "nothing committed\n")
	}
	outside, err := os.make_directory_temp("", "gitmd-nonrepo-*", context.allocator)
	if err != nil { testing.fail_now(t) }
	defer os.remove_all(outside)
	outside_file := test_path(outside, "file.md")
	must_write(t, outside_file, "no repository\n")
	_, _, repository := load_history(outside_file)
	testing.expect(t, !repository)
	_ = path
}

@(test)
repository_lists_only_markdown_and_selects_requested_file :: proc(t: ^testing.T) {
	root, path := make_fixture(t)
	defer os.remove_all(root)
	second := test_path(root, "notes.markdown")
	ignored := test_path(root, "notes.txt")
	must_write(t, second, "# Notes\n")
	must_write(t, ignored, "not Markdown\n")
	must_git(t, root, []string{"add", "--", "notes.markdown", "notes.txt"})
	must_git(t, root, []string{"commit", "-q", "-m", "add repository files"})
	repository, message, ok := load_repository(second)
	testing.expectf(t, ok, "load_repository failed: %s", message)
	if !ok { return }
	testing.expect_value(t, len(repository.files), 2)
	testing.expect_value(t, repository.files[repository.selected_file], "notes.markdown")
	for file in repository.files {
		testing.expect(t, is_markdown_path(file))
		testing.expect(t, file != "notes.txt")
	}
	history, history_message, history_ok := load_repository_history(&repository, repository.selected_file)
	testing.expectf(t, history_ok, "load_repository_history failed: %s", history_message)
	if history_ok {
		testing.expect_value(t, history.path, "notes.markdown")
		testing.expect(t, history.commits[0].working)
		testing.expect_value(t, history.commits[0].markdown, "# Notes\n")
		render_message, rendered := render_history_snapshot(&history, 0)
		testing.expectf(t, rendered, "render_history_snapshot failed: %s", render_message)
		testing.expect(t, strings.contains(history.commits[0].html, `<h1 id="notes">Notes</h1>`))
		partial := route_request("GET", "/file/0?partial=1", &history, "page", &repository)
		testing.expect_value(t, partial.status, 200)
		testing.expect(t, strings.contains(partial.body, `id="sidebar-path"`))
		testing.expect(t, strings.contains(partial.body, `id="preview"`))
		testing.expect(t, strings.contains(partial.body, `id="history"`))
		testing.expect(t, strings.contains(partial.body, `id="outline"`))
		testing.expect(t, !strings.contains(partial.body, `class="file-browser"`))
		testing.expect(t, !strings.contains(partial.body, "<html"))
	}
	_ = path
}

@(test)
working_snapshot_starts_watch_stream_and_formats_updates :: proc(t: ^testing.T) {
	history := History{path = "docs/a guide.md", commits = make([dynamic]Commit, 0)}
	defer delete(history.commits)
	append(&history.commits, Commit{working = true})
	fragment := watch_fragment(&history, 0)
	testing.expect(t, strings.contains(fragment, `id="watch"`))
	testing.expect(t, strings.contains(fragment, `@get('/watch?path=docs%2fa%20guide.md')`))
	event := sse_patch_elements("<article id=\"preview\">one\ntwo</article>")
	testing.expect_value(t, event, "event: datastar-patch-elements\ndata: elements <article id=\"preview\">one\ndata: elements two</article>\n\n")
	repository := Repository{files = make([dynamic]string, 0)}
	defer delete(repository.files)
	append(&repository.files, "docs/a guide.md")
	path, valid := watch_request_path("/watch?path=docs%2Fa%20guide.md", &repository)
	testing.expect(t, valid)
	testing.expect_value(t, path, "docs/a guide.md")
	_, traversal := watch_request_path("/watch?path=..%2Fsecret.md", &repository)
	testing.expect(t, !traversal)
}

@(test)
watch_stream_pushes_changed_file :: proc(t: ^testing.T) {
	root, path := make_fixture(t)
	defer os.remove_all(root)
	listener, listen_err := net.listen_tcp({net.IP4_Loopback, 0})
	testing.expect_value(t, listen_err, nil)
	if listen_err != nil { return }
	defer net.close(listener)
	endpoint, endpoint_err := net.bound_endpoint(listener)
	testing.expect_value(t, endpoint_err, nil)
	if endpoint_err != nil { return }
	client, dial_err := net.dial_tcp(endpoint)
	testing.expect_value(t, dial_err, nil)
	if dial_err != nil { return }
	defer net.close(client)
	server, _, accept_err := net.accept_tcp(listener)
	testing.expect_value(t, accept_err, nil)
	if accept_err != nil { return }
	net.set_option(client, .Receive_Timeout, 3 * time.Second)
	server_running = true
	watcher := thread.create_and_start_with_poly_data(
		Watch_Request{socket = server, repo_root = root, path = "docs with spaces/new name.md"},
		watch_file,
	)
	defer {
		server_running = false
		thread.join(watcher)
		thread.destroy(watcher)
	}
	initial, received_initial := receive_until(client, "Second snapshot.")
	testing.expectf(t, received_initial, "initial watch event missing: %s", initial)
	must_write(t, path, "# Watched change\n")
	update, received_update := receive_until(client, "Watched change")
	testing.expectf(t, received_update, "changed watch event missing: %s", update)
}

@(test)
repository_page_has_file_and_history_modes :: proc(t: ^testing.T) {
	repository := Repository{files = make([dynamic]string, 0), selected_file = 1}
	append(&repository.files, "README.md", "docs/guide.md")
	history := History{path = "docs/guide.md", commits = make([dynamic]Commit, 0)}
	append(&history.commits, Commit{
		full_hash = "0123456789012345678901234567890123456789",
		short_hash = "0123456",
		author_date = "2026-09-02T12:00:00Z",
		subject = "Guide",
		html = "<h1>Guide</h1>",
	})
	append(&history.commits, Commit{
		full_hash = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
		short_hash = "aaaaaaa",
		author_date = "2026-09-01T12:00:00Z",
		subject = "Older guide",
		html = `<h1 id="older-guide">Older guide</h1><h2 id="install"><code>Install</code> &amp; run</h2>`,
	})
	page := initial_page(&history, &repository, 1)
	testing.expect(t, strings.contains(page, ">Files</button>"))
	testing.expect(t, strings.contains(page, ">History</button>"))
	testing.expect(t, strings.contains(page, ">Outline</button>"))
	testing.expect(t, strings.contains(page, `aria-keyshortcuts="1"`))
	testing.expect(t, strings.contains(page, `aria-keyshortcuts="2"`))
	testing.expect(t, strings.contains(page, `aria-keyshortcuts="3"`))
	testing.expect(t, strings.contains(page, `aria-label="Document outline"`))
	files_position := strings.index(page, `class="file-browser"`)
	search_position := strings.index(page, `id="files-search-input"`)
	list_position := strings.index(page, `<ol>`)
	testing.expect(t, files_position >= 0 && files_position < search_position && search_position < list_position)
	testing.expect(t, strings.contains(page, `id="history-search-input"`))
	testing.expect(t, strings.contains(page, `id="outline-search-input"`))
	testing.expect(t, strings.contains(page, `data-show="$filesSearching"`))
	testing.expect(t, strings.contains(page, `<li class="outline-level-1"><a href="#older-guide">Older guide</a></li>`))
	testing.expect(t, strings.contains(page, `<li class="outline-level-2"><a href="#install">Install &amp; run</a></li>`))
	testing.expect(t, strings.contains(STYLESHEET, `.file-browser a:hover,.history a:hover,.outline a:hover`))
	testing.expect(t, strings.contains(STYLESHEET, `.file-browser a.selected,.history a.selected,.outline a.selected { background:var(--selected); }`))
	testing.expect(t, strings.contains(page, "README.md"))
	testing.expect(t, strings.contains(page, "docs/guide.md"))
	testing.expect(t, strings.contains(page, `href="/docs/guide.md"`))
	testing.expect(t, strings.contains(page, `href="/docs/guide.md?commit=aaaaaaa&amp;sidebar=history"`))
	testing.expect(t, strings.contains(page, `aria-current="page"`))
	testing.expect(t, strings.contains(page, `id="file-1" class="selected" aria-current="page" data-init="document.getElementById('file-1').scrollIntoView({block:'nearest'})"`))
	testing.expect(t, strings.contains(page, `evt.currentTarget.focus({preventScroll:true}); evt.currentTarget.scrollIntoView({block:'nearest'})`))
	testing.expect(t, strings.contains(page, `@get('/file/1?partial=1')`))
	testing.expect(t, strings.contains(page, `id="commit-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" class="selected" aria-current="page"`))
	testing.expect(t, !strings.contains(page, `data-class:selected="$selected === 1"`))
	testing.expect(t, strings.contains(page, `current?.classList.remove('selected')`))
	testing.expect(t, !strings.contains(page, `document.getElementById('commit-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa').scrollIntoView`))
	testing.expect(t, strings.contains(page, `<h1 id="older-guide">Older guide</h1>`))
	testing.expect_value(t, query_parameter("/docs/guide.md?commit=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "commit"), "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
}

@(test)
repository_urls_preserve_directories_and_escape_segments :: proc(t: ^testing.T) {
	testing.expect_value(t, repository_url("docs/a guide.md"), "/docs/a%20guide.md")
}

@(test)
commit_timestamp_uses_compact_local_format :: proc(t: ^testing.T) {
	testing.expect_value(t, display_timestamp("2026-10-31T14:31:52+01:00"), "2026.10.31 14:31")
	testing.expect_value(t, display_timestamp("unknown"), "unknown")
}

@(test)
repository_ports_are_stable_and_path_specific :: proc(t: ^testing.T) {
	first := repository_port("/Users/example/one/gitmd")
	testing.expect_value(t, first, repository_port("/Users/example/one/gitmd"))
	testing.expect(t, first >= 20000 && first < 40000)
	testing.expect(t, first != repository_port("/Users/example/two/gitmd"))
}
