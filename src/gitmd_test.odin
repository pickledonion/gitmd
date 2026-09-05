package main

import "core:os"
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
	testing.expect(t, !history.commits[0].dirty)
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
	clean_history := render_history(&history, 0)
	testing.expect(t, !strings.contains(clean_history, "Working tree"))
	must_write(t, path, strings.concatenate({history.commits[0].markdown, "\nUncommitted change.\n"}))
	dirty_history, dirty_message, dirty_ok := load_history(path)
	testing.expectf(t, dirty_ok, "load_history failed: %s", dirty_message)
	if dirty_ok {
		testing.expect(t, dirty_history.commits[0].dirty)
		testing.expect(t, strings.contains(render_history(&dirty_history, 0), "Working tree"))
	}
}

@(test)
gfm_extensions_and_safety :: proc(t: ^testing.T) {
	api, message, ok := load_cmark()
	testing.expectf(t, ok, "%s", message)
	if !ok { return }
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
	testing.expect(t, strings.has_prefix(valid.body, `<div id="watch" data-init="@get('/watch?path=&amp;commit=0123456789012345678901234567890123456789', {requestCancellation: 'cleanup'})"></div><article id="preview"`))
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
	testing.expect(t, strings.contains(page, `data-on:popstate__window="window.location.reload()"`))
	testing.expect(t, strings.contains(page, "evt.metaKey"))
	testing.expect(t, strings.contains(page, "$sidebarOpen = !$sidebarOpen"))
	testing.expect(t, strings.contains(page, `['1','2','3'].includes(evt.key)`))
	testing.expect(t, strings.contains(page, `$sidebar = ['files','history','outline'][Number(evt.key) - 1]`))
	testing.expect(t, strings.contains(page, `['ArrowLeft','h','ArrowRight','l'].includes(evt.key)`))
	testing.expect(t, strings.contains(page, `document.querySelector('.sidebar').focus({preventScroll:true})`))
	testing.expect(t, strings.contains(page, `document.querySelector('.preview-pane').focus({preventScroll:true})`))
	testing.expect(t, strings.contains(page, `document.querySelector('.preview-pane').scrollBy(0, previous ? -80 : 80)`))
	testing.expect(t, strings.contains(page, `Array.from(section.querySelectorAll('a')).filter(link => !link.closest('li').hidden)`))
	testing.expect(t, strings.contains(page, `links[next].scrollIntoView({block:'nearest'})`))
	testing.expect(t, strings.contains(page, `let current = links.indexOf(section.querySelector('a.selected'))`))
	testing.expect(t, strings.contains(page, `$fileTimer = setTimeout(() => target.click(), 0)`))
	testing.expect(t, strings.contains(page, `target.focus({preventScroll:true})`))
	testing.expect(t, strings.contains(page, `list.scrollTop += itemRect.bottom - listRect.bottom`))
	testing.expect(t, strings.contains(page, `$historyTimer = setTimeout(() => target.click(), 120)`))
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
	testing.expect(t, strings.contains(page, `@get('/?commit=0123456789012345678901234567890123456789&amp;partial=1')`))
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
		testing.expect(t, history.commits[0].dirty)
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
		fresh_path := test_path(root, "fresh.md")
		must_write(t, fresh_path, "# Fresh\n")
		fresh := route_request("GET", "/fresh.md?partial=1", &history, "page", &repository)
		testing.expect_value(t, fresh.status, 200)
		testing.expect(t, strings.contains(fresh.body, `<h1 id="fresh" class="change-added">Fresh</h1>`))
		testing.expect_value(t, repository.selected_file, 1)
		testing.expect_value(t, repository.files[0], "docs with spaces/new name.md")
		testing.expect_value(t, repository.files[1], "fresh.md")
		testing.expect_value(t, repository.files[2], "notes.markdown")
	}
	_ = path
}

@(test)
repository_keeps_untracked_markdown_in_path_order :: proc(t: ^testing.T) {
	root, _ := make_fixture(t)
	defer os.remove_all(root)
	expected := []string{
		"Z.md",
		"a.markdown",
		"docs with spaces/S00.02-first.md",
		"docs with spaces/S00.03-repository-tools.md",
		"docs with spaces/S00.04-last.md",
		"docs with spaces/new name.md",
	}
	untracked := expected[3]
	for file in expected[:5] {
		if file == untracked { continue }
		must_write(t, test_path(root, file), "# Tracked\n")
		must_git(t, root, []string{"add", "--", file})
	}
	must_write(t, test_path(root, ".gitignore"), "ignored.md\n")
	must_git(t, root, []string{"add", "--", ".gitignore"})
	must_git(t, root, []string{"commit", "-q", "-m", "add surrounding Markdown paths"})
	must_write(t, test_path(root, "ignored.md"), "# Ignored\n")
	contents := "# Repository tools\n\nWorking-tree contents.\n"
	must_write(t, test_path(root, untracked), contents)

	for state in 0 ..< 3 {
		if state == 1 {
			must_git(t, root, []string{"add", "--", untracked})
		} else if state == 2 {
			must_git(t, root, []string{"commit", "-q", "-m", "add repository tools"})
		}
		repository, message, loaded := load_repository(test_path(root, untracked))
		testing.expectf(t, loaded, "load_repository failed: %s", message)
		if !loaded { return }
		if !testing.expect_value(t, len(repository.files), len(expected)) { return }
		for file, index in expected {
			testing.expect_value(t, repository.files[index], file)
		}
		testing.expect_value(t, repository.selected_file, 3)

		startup, startup_message, startup_loaded := load_repository(root)
		testing.expectf(t, startup_loaded, "directory load failed: %s", startup_message)
		if !startup_loaded { return }
		testing.expect_value(t, startup.files[startup.selected_file], expected[0])

		history: History
		response := route_request("GET", "/docs%20with%20spaces/S00.03-repository-tools.md?partial=1", &history, "page", &startup)
		testing.expect_value(t, response.status, 200)
		testing.expect_value(t, startup.selected_file, 3)
		testing.expect(t, strings.contains(response.body, `<h1 id="repository-tools" class="change-added">Repository tools</h1>`))
		testing.expect(t, strings.contains(response.body, `<p class="change-added">Working-tree contents.</p>`))
		if state < 2 {
			if !testing.expect_value(t, len(history.commits), 1) { return }
			testing.expect(t, history.commits[0].working)
			testing.expect(t, history.commits[0].dirty)
			testing.expect_value(t, history.commits[0].markdown, contents)
		}
	}
}

@(test)
working_snapshot_starts_watch_stream_and_formats_updates :: proc(t: ^testing.T) {
	history := History{path = "docs/a guide.md", commits = make([dynamic]Commit, 0)}
	defer delete(history.commits)
	append(&history.commits, Commit{working = true})
	fragment := watch_fragment(&history, 0)
	testing.expect(t, strings.contains(fragment, `id="watch"`))
	testing.expect(t, strings.contains(fragment, `@get('/watch?path=docs%2fa%20guide.md&amp;commit=working', {requestCancellation: 'cleanup'})`))
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
watch_updates_coalesce_and_limit_fragment_scope :: proc(t: ^testing.T) {
	working_request := Watch_Request{path = "docs/guide.md", commit_hash = "working"}
	working, working_rendered, working_kind := render_watch_update(
		&working_request,
		Watch_Changes{contents = true},
		"# Working\n",
		true,
	)
	testing.expect(t, working_rendered)
	testing.expect_value(t, working_kind, "working")
	testing.expect(t, strings.contains(working, `id="preview"`))
	testing.expect(t, strings.contains(working, `id="outline"`))
	testing.expect(t, !strings.contains(working, `id="files"`))
	testing.expect(t, !strings.contains(working, `id="history"`))

	fixed_request := Watch_Request{path = "docs/guide.md", commit_hash = "0123456789abcdef0123456789abcdef01234567"}
	fixed, fixed_rendered, fixed_kind := render_watch_update(
		&fixed_request,
		Watch_Changes{contents = true},
		"# Working\n",
		true,
	)
	testing.expect(t, fixed_rendered)
	testing.expect_value(t, fixed_kind, "fixed-snapshot")
	testing.expect_value(t, len(fixed), 0)

	pending: Watch_Pending
	now := time.tick_now()
	mark_watch_change(&pending, now, Watch_Changes{contents = true})
	mark_watch_change(&pending, now, Watch_Changes{files = true})
	testing.expect(t, pending.dirty)
	testing.expect_value(t, pending.observations, 2)
	testing.expect(t, pending.changes.contents)
	testing.expect(t, pending.changes.files)

	root, _ := make_fixture(t)
	defer os.remove_all(root)
	files_request := Watch_Request{repo_root = root, path = "docs with spaces/new name.md", commit_hash = "working"}
	files, files_rendered, files_kind := render_watch_update(
		&files_request,
		Watch_Changes{files = true},
		"",
		true,
	)
	testing.expect(t, files_rendered)
	testing.expect_value(t, files_kind, "files")
	testing.expect(t, strings.contains(files, `id="files"`))
	testing.expect(t, !strings.contains(files, `id="history"`))
	testing.expect(t, !strings.contains(files, `id="preview"`))
}

@(test)
watch_stream_pushes_changed_file :: proc(t: ^testing.T) {
	root, path := make_fixture(t)
	defer os.remove_all(root)
	must_write(t, test_path(root, "README.md"), "# Readme\n")
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
	must_git(t, root, []string{"add", "--", "docs with spaces/new name.md"})
	must_git(t, root, []string{"commit", "-q", "-m", "watched commit"})
	commit_update, received_commit := receive_until(client, "watched commit")
	testing.expectf(t, received_commit, "commit watch event missing: %s", commit_update)
	must_write(t, test_path(root, "live.md"), "# Live file\n")
	files_update, received_file := receive_until(client, "live.md")
	testing.expectf(t, received_file, "file-list watch event missing: %s", files_update)
	readme_position := strings.index(files_update, `data-path="README.md"`)
	selected_position := strings.index(files_update, `data-path="docs with spaces/new name.md"`)
	live_position := strings.index(files_update, `data-path="live.md"`)
	testing.expect(t, readme_position >= 0 && readme_position < selected_position && selected_position < live_position)
	testing.expect(t, strings.contains(files_update, `id="file-1" class="selected" aria-current="page"`))
}

@(test)
watch_stream_keeps_committed_snapshot_fixed :: proc(t: ^testing.T) {
	root, path := make_fixture(t)
	defer os.remove_all(root)
	history, message, loaded := load_history_snapshots(root, "docs with spaces/new name.md")
	testing.expectf(t, loaded, "load_history_snapshots failed: %s", message)
	if !loaded { return }
	selected_hash := strings.clone(history.commits[1].full_hash)
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
		Watch_Request{socket = server, repo_root = root, path = "docs with spaces/new name.md", commit_hash = selected_hash},
		watch_file,
	)
	defer {
		server_running = false
		thread.join(watcher)
		thread.destroy(watcher)
	}
	initial, received_initial := receive_until(client, "Second snapshot.")
	testing.expectf(t, received_initial, "initial fixed snapshot event missing: %s", initial)
	must_write(t, path, "# Drifting working tree\n")
	must_git(t, root, []string{"add", "--", "docs with spaces/new name.md"})
	must_git(t, root, []string{"commit", "-q", "-m", "commit after fixed selection"})
	update, received_update := receive_until(client, "commit after fixed selection")
	testing.expectf(t, received_update, "fixed snapshot history update missing: %s", update)
	testing.expect(t, strings.contains(update, "Second snapshot."))
	testing.expect(t, !strings.contains(update, "Drifting working tree"))
}

@(test)
repository_page_has_file_and_history_modes :: proc(t: ^testing.T) {
	repository := Repository{repo_root = "/Users/example/project-name", files = make([dynamic]string, 0), selected_file = 1}
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
	modifier_guard := `if (evt.button !== 0 || evt.metaKey || evt.ctrlKey || evt.shiftKey || evt.altKey) return; evt.preventDefault();`
	files := render_files(&repository)
	commits := render_history(&history, 1)
	testing.expect(t, strings.contains(files, modifier_guard))
	testing.expect(t, strings.contains(commits, modifier_guard))
	testing.expect(t, strings.contains(files, `history.pushState(null, '', evt.currentTarget.href)`))
	testing.expect(t, strings.contains(commits, `history.pushState(null, '', evt.currentTarget.href)`))
	testing.expect(t, !strings.contains(files, `history.replaceState`))
	testing.expect(t, !strings.contains(commits, `history.replaceState`))
	testing.expect(t, strings.contains(page, `data-on:popstate__window="window.location.reload()"`))
	testing.expect(t, strings.contains(page, `<title>docs/guide.md · project-name</title>`))
	testing.expect(t, strings.contains(page, `<header><strong>project-name</strong>`))
	testing.expect(t, strings.contains(page, `data-repository-name="project-name"`))
	testing.expect(t, strings.contains(page, `document.title = evt.currentTarget.dataset.path + ' · ' + browser.dataset.repositoryName`))
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
	testing.expect(t, strings.contains(page, `<li class="outline-level-1"><a href="#older-guide"`))
	testing.expect(t, strings.contains(page, `<li class="outline-level-2"><a href="#install"`))
	testing.expect(t, strings.contains(page, `history.pushState(null, '', evt.currentTarget.href); document.getElementById(decodeURIComponent(evt.currentTarget.hash.slice(1)))?.scrollIntoView()`))
	testing.expect(t, strings.contains(STYLESHEET, `.file-browser a:hover,.history a:hover,.outline a:hover`))
	testing.expect(t, strings.contains(STYLESHEET, `.file-browser a.selected,.history a.selected,.outline a.selected { background:var(--selected); }`))
	testing.expect(t, strings.contains(page, "README.md"))
	testing.expect(t, strings.contains(page, "docs/guide.md"))
	testing.expect(t, strings.contains(page, `href="/docs/guide.md"`))
	testing.expect(t, strings.contains(page, `href="/docs/guide.md?commit=aaaaaaa&amp;sidebar=history"`))
	testing.expect(t, strings.contains(page, `aria-current="page"`))
	testing.expect(t, strings.contains(page, `id="file-1" class="selected" aria-current="page" data-init="document.getElementById('file-1').scrollIntoView({block:'nearest'})"`))
	testing.expect(t, strings.contains(page, `evt.currentTarget.focus({preventScroll:true}); evt.currentTarget.scrollIntoView({block:'nearest'})`))
	testing.expect(t, strings.contains(page, `@get('/docs/guide.md?partial=1')`))
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

@(test)
occupied_repository_port_falls_back_to_available_port :: proc(t: ^testing.T) {
	occupied, listen_err := net.listen_tcp({net.IP4_Loopback, 0})
	testing.expect_value(t, listen_err, nil)
	if listen_err != nil { return }
	defer net.close(occupied)
	occupied_endpoint, endpoint_err := net.bound_endpoint(occupied)
	testing.expect_value(t, endpoint_err, nil)
	if endpoint_err != nil { return }

	listener, fallback_err := listen_with_fallback(occupied_endpoint.port)
	testing.expect_value(t, fallback_err, nil)
	if fallback_err != nil { return }
	defer net.close(listener)
	fallback_endpoint, fallback_endpoint_err := net.bound_endpoint(listener)
	testing.expect_value(t, fallback_endpoint_err, nil)
	if fallback_endpoint_err != nil { return }
	testing.expect(t, fallback_endpoint.port != occupied_endpoint.port)
}

comparison_for_test :: proc(t: ^testing.T, current, baseline: string) -> Commit {
	history := History{commits = make([dynamic]Commit)}
	append(&history.commits, Commit{markdown = current, working = true, dirty = true}, Commit{markdown = baseline, blob_loaded = true, short_hash = "baseline"})
	message, ok := render_history_snapshot(&history, 0)
	testing.expectf(t, ok, "%s", message)
	return history.commits[0]
}

@(test)
block_comparison_add_edit_delete_repeat_and_empty :: proc(t: ^testing.T) {
	cases := []struct {current, baseline: string, added: int} {
		{"One.\n\nNew.\n\nTwo.\n", "One.\n\nTwo.\n", 1},
		{"One edited.\n\nTwo.\n", "One.\n\nTwo.\n", 1},
		{"Two.\n", "One.\n\nTwo.\n", 0},
		{"Same.\n\nSame.\n\nSame.\n", "Same.\n\nSame.\n", 1},
		{"Same.\n\nSame.\n", "Same.\n\nSame.\n", 0},
		{"# New\n\nParagraph.\n", "", 2},
		{"", "# Deleted\n", 0},
		{"", "", 0},
		{"# Same\n\n# Same\n", "# Removed\n\n# Same\n\n# Same\n", 0},
		{"**Bold**\n", "__Bold__\n", 0},
	}
	for item in cases {
		commit := comparison_for_test(t, item.current, item.baseline)
		testing.expect_value(t, strings.count(commit.comparison_html, `class="change-added"`), item.added)
		testing.expect(t, !strings.contains(commit.comparison_html, "data-sourcepos"))
		testing.expect(t, !strings.contains(commit.html, "change-added"))
	}
}

@(test)
block_comparison_complex_units_and_safe_links :: proc(t: ^testing.T) {
	baseline := "# Heading\n\n- [ ] item\n  - nested\n\n- unchanged\n\n> old quote\n\n| A |\n|---|\n| old |\n\n```odin\nold\n```\n"
	current := "# Heading\n\n- [x] item\n  - edited nested\n\n- unchanged\n\n> new quote\n\n| A |\n|---|\n| new |\n\n```odin\nnew\n```\n"
	commit := comparison_for_test(t, current, baseline)
	testing.expect_value(t, strings.count(commit.comparison_html, `class="change-added"`), 4)
	for tag in ([]string{"li", "blockquote", "table", "pre"}) {
		testing.expectf(t, strings.contains(commit.comparison_html, strings.concatenate({"<", tag, ` class="change-added">`})), "missing highlight for %s: %s", tag, commit.comparison_html)
	}
	testing.expect(t, strings.contains(commit.comparison_html, `<h1 id="heading">Heading</h1>`))
	testing.expect(t, strings.contains(render_outline(&commit), `href="#heading"`))
	loose := comparison_for_test(t, "- new\n\n  nested paragraph\n", "- old\n\n  nested paragraph\n")
	testing.expect_value(t, strings.count(loose.comparison_html, `class="change-added"`), 1)
	anchors := comparison_for_test(t, "<a id=\"new\"></a> new\n\n<a id=\"safe\"></a> kept\n\n[heading](#heading)\n", "<a id=\"safe\"></a> kept\n\n[heading](#heading)\n")
	testing.expect_value(t, strings.count(anchors.comparison_html, `class="change-added"`), 1)
	testing.expect(t, strings.contains(anchors.comparison_html, `<a id="safe"></a>`))
	testing.expect(t, strings.contains(anchors.comparison_html, `href="#heading"`))
	safe := comparison_for_test(t, "# New\n\n<script>alert(1)</script>\n\n[bad](javascript:alert(1))\n\n<pre>\n<script>literal</script>\n</pre>\n", "")
	testing.expect(t, strings.contains(safe.comparison_html, `<h1 id="new" class="change-added">`))
	testing.expect(t, !strings.contains(safe.comparison_html, "<script>"))
	testing.expect(t, !strings.contains(safe.comparison_html, "javascript:"))
	testing.expect(t, strings.contains(safe.comparison_html, "&lt;script&gt;literal&lt;/script&gt;"))
}

@(test)
comparison_history_baselines_rename_and_failure :: proc(t: ^testing.T) {
	root, _ := make_fixture(t)
	defer os.remove_all(root)
	history, _, loaded := load_history_snapshots(root, "docs with spaces/new name.md")
	testing.expect(t, loaded)
	_, rendered := render_history_snapshot(&history, 1)
	testing.expect(t, rendered)
	testing.expect_value(t, strings.count(history.commits[1].comparison_html, `class="change-added"`), 1)
	testing.expect(t, strings.contains(history.commits[1].comparison_label, history.commits[2].short_hash))
	testing.expect(t, !history.commits[0].rendered && !history.commits[3].blob_loaded)
	_, rendered = render_history_snapshot(&history, 2)
	testing.expect(t, rendered)
	testing.expect_value(t, history.commits[3].path, "docs with spaces/old name.md")
	testing.expect_value(t, history.commits[2].comparison_html, history.commits[2].html)
	_, rendered = render_history_snapshot(&history, 3)
	testing.expect(t, rendered)
	testing.expect_value(t, strings.count(history.commits[3].comparison_html, `class="change-added"`), 2)
	testing.expect(t, strings.contains(history.commits[3].comparison_label, "No previous version"))
	broken := History{repo_root = root, commits = make([dynamic]Commit)}
	append(&broken.commits, Commit{markdown = "# Visible", working = true}, Commit{full_hash = "missing", path = "missing.md"})
	_, rendered = render_history_snapshot(&broken, 0)
	testing.expect(t, rendered)
	testing.expect_value(t, broken.commits[0].comparison_html, broken.commits[0].html)
	testing.expect(t, strings.contains(broken.commits[0].comparison_label, "Comparison unavailable"))
}

@(test)
comparison_live_edits_reuse_baseline_and_refresh_after_commit :: proc(t: ^testing.T) {
	root, path := make_fixture(t)
	defer os.remove_all(root)
	request := Watch_Request{repo_root = root, path = "docs with spaces/new name.md", commit_hash = "working"}
	initial, ok := render_watch_fragments(&request)
	testing.expect(t, ok && request.comparison.ready)
	testing.expect(t, strings.contains(initial, `<p class="change-added">Second snapshot.</p>`))
	old_blob := request.comparison.baseline.blob_hash
	markdown := strings.concatenate({request.comparison.baseline.markdown, "\nLive addition.\n"})
	must_write(t, path, markdown)
	live, live_ok, _ := render_watch_update(&request, Watch_Changes{contents = true}, markdown, true)
	testing.expect(t, live_ok)
	testing.expect(t, strings.contains(live, `<p class="change-added">Live addition.</p>`))
	testing.expect_value(t, request.comparison.baseline.blob_hash, old_blob)
	testing.expect(t, !strings.contains(live, `<p class="change-added">Second snapshot.</p>`))
	testing.expect(t, strings.contains(live, request.comparison.baseline.short_hash))

	// Also cover a watcher opened while dirty, whose older baseline is not loaded.
	dirty_request := Watch_Request{repo_root = root, path = request.path, commit_hash = "working"}
	_, _ = render_watch_fragments(&dirty_request)
	testing.expect_value(t, dirty_request.comparison.baseline.comparison_label, "")
	must_write(t, path, request.comparison.baseline.markdown)
	for watcher in ([]^Watch_Request{&request, &dirty_request}) {
		reverted, reverted_ok, _ := render_watch_update(watcher, Watch_Changes{contents = true}, request.comparison.baseline.markdown, true)
		testing.expect(t, reverted_ok)
		testing.expect(t, strings.contains(reverted, `<p class="change-added">Second snapshot.</p>`))
		testing.expect(t, !strings.contains(reverted, "Live addition."))
	}
	must_write(t, path, markdown)
	must_git(t, root, []string{"add", "--", request.path})
	must_git(t, root, []string{"commit", "-q", "-m", "live addition"})
	refreshed, refresh_ok, _ := render_watch_update(&request, Watch_Changes{head = true}, markdown, true)
	testing.expect(t, refresh_ok)
	testing.expect(t, strings.contains(refreshed, `<p class="change-added">Live addition.</p>`))
	testing.expect(t, !strings.contains(refreshed, `<p class="change-added">Second snapshot.</p>`))
	testing.expect(t, request.comparison.baseline.blob_hash != old_blob)
	new_path := test_path(root, "new.md")
	must_write(t, new_path, "# Untracked\n")
	new_history, _, new_ok := load_history_snapshots(root, "new.md")
	testing.expect(t, new_ok)
	_, new_ok = render_history_snapshot(&new_history, 0)
	testing.expect(t, new_ok)
	testing.expect(t, strings.contains(new_history.commits[0].comparison_html, `class="change-added"`))
}

@(test)
comparison_toggle_is_outside_panels_and_persists_in_tab :: proc(t: ^testing.T) {
	history := History{commits = make([dynamic]Commit)}
	append(&history.commits, Commit{working = true, markdown = "# Heading"})
	_, _ = render_history_snapshot(&history, 0)
	page := initial_page(&history)
	tabs_end := strings.index(page, "</nav>")
	control := strings.index(page, `class="changes-control"`)
	label := strings.index(page, `id="comparison-label"`)
	panel := strings.index(page, `<section id="history"`)
	testing.expect(t, tabs_end < control && control < label && label < panel)
	testing.expect(t, strings.contains(page, "showChanges: false"))
	testing.expect(t, strings.contains(page, "sessionStorage.getItem('gitmd-show-changes')"))
	testing.expect(t, strings.contains(page, "sessionStorage.setItem('gitmd-show-changes'"))
	testing.expect(t, strings.contains(page, `data-class:show-changes="$showChanges"`))
	testing.expect(t, strings.contains(page, `data-bind:show-changes`))
	testing.expect(t, strings.contains(snapshot_fragments(&history, 0), `id="comparison-label"`))
	testing.expect(t, strings.contains(file_fragments(&history, 0), `id="comparison-label"`))
	testing.expect(t, strings.contains(STYLESHEET, "--change-added:#dafbe1"))
	testing.expect(t, strings.contains(STYLESHEET, "--change-added:#173b27"))
	testing.expect(t, strings.contains(STYLESHEET, "--change-deleted:#ffebe9"))
	testing.expect(t, strings.contains(STYLESHEET, "--change-deleted:#4a2024"))
	testing.expect(t, strings.contains(STYLESHEET, "body:not(.show-changes) .markdown-body .change-deleted { display:none; }"))
	testing.expect(t, !strings.contains(page, "deletions hidden"))
}

@(test)
comparison_unborn_repository_and_unreadable_history :: proc(t: ^testing.T) {
	root, err := os.make_directory_temp("", "gitmd-changes-*", context.allocator)
	if err != nil { testing.fail_now(t) }
	defer os.remove_all(root)
	must_git(t, root, []string{"init", "-q"})
	must_write(t, test_path(root, "new.md"), "# New document\n")
	history, _, loaded := load_history_snapshots(root, "new.md")
	testing.expect(t, loaded)
	_, rendered := render_history_snapshot(&history, 0)
	testing.expect(t, rendered)
	testing.expect(t, strings.contains(history.commits[0].comparison_html, `class="change-added"`))
	testing.expect(t, strings.contains(history.commits[0].comparison_label, "No previous version"))

	broken_root, _ := make_fixture(t)
	defer os.remove_all(broken_root)
	oldest := must_git(t, broken_root, []string{"rev-parse", "HEAD~2"})
	hash := trim_command_output(oldest.stdout)
	remove_err := os.remove(test_path(broken_root, ".git", "objects", hash[:2], hash[2:]))
	testing.expect(t, remove_err == nil)
	broken, _, broken_loaded := load_history_snapshots(broken_root, "docs with spaces/new name.md")
	testing.expect(t, broken_loaded && broken.comparison_unavailable)
	_, rendered = render_history_snapshot(&broken, 0)
	testing.expect(t, rendered)
	testing.expect_value(t, broken.commits[0].comparison_html, broken.commits[0].html)
	testing.expect(t, strings.contains(broken.commits[0].comparison_label, "Comparison unavailable"))
}

@(test)
clean_default_comparison_matches_explicit_latest_commit :: proc(t: ^testing.T) {
	root, path := make_fixture(t)
	defer os.remove_all(root)
	repository, _, loaded := load_repository(path)
	testing.expect(t, loaded)
	history: History
	default_response := select_repository_file(&history, &repository, repository.selected_file)
	testing.expect_value(t, default_response.status, 200)
	testing.expect(t, !history.commits[0].dirty)
	default_preview := preview_fragment(&history.commits[0])
	default_label := history.commits[0].comparison_label
	testing.expect(t, strings.contains(default_preview, `<p class="change-added">Second snapshot.</p>`))
	testing.expect(t, strings.contains(default_label, history.commits[2].short_hash))
	testing.expect(t, !strings.contains(default_label, history.commits[1].short_hash))
	testing.expect(t, strings.contains(default_response.body, default_preview))
	latest_hash := history.commits[1].full_hash
	explicit_response := select_repository_file(&history, &repository, repository.selected_file, latest_hash, "history", true)
	testing.expect_value(t, explicit_response.status, 200)
	testing.expect_value(t, preview_fragment(&history.commits[1]), default_preview)
	testing.expect_value(t, history.commits[1].comparison_label, default_label)
}

@(test)
inline_deletions_preserve_block_order :: proc(t: ^testing.T) {
	cases := []struct { current, baseline, expected: string } {
		{"Keep.\n", "First.\n\nKeep.\n", "<p class=\"change-deleted\">First.</p>\n<p>Keep.</p>\n"},
		{"A.\n\nB.\n", "A.\n\nMiddle.\n\nB.\n", "<p>A.</p>\n<p class=\"change-deleted\">Middle.</p>\n<p>B.</p>\n"},
		{"Keep.\n", "Keep.\n\nLast.\n", "<p>Keep.</p>\n<p class=\"change-deleted\">Last.</p>\n"},
		{"New.\n\nKeep.\n", "Old.\n\nKeep.\n", "<p class=\"change-deleted\">Old.</p>\n<p class=\"change-added\">New.</p>\n<p>Keep.</p>\n"},
		{"Same.\n\nEnd.\n", "Same.\n\nSame.\n\nEnd.\n", "<p>Same.</p>\n<p class=\"change-deleted\">Same.</p>\n<p>End.</p>\n"},
		{"", "---\n", "<hr class=\"change-deleted\" />\n"},
		{"", "# Gone\n\nAll gone.\n", "<h1 class=\"change-deleted\">Gone</h1>\n<p class=\"change-deleted\">All gone.</p>\n"},
	}
	for item in cases {
		commit := comparison_for_test(t, item.current, item.baseline)
		testing.expect_value(t, commit.comparison_html, item.expected)
	}
}

@(test)
inline_deletions_lists_and_numbering :: proc(t: ^testing.T) {
	cases := []struct { current, baseline: string, fragments: []string } {
		{"- keep\n", "- first\n- keep\n- last\n", {"<ul>", `<li class="change-deleted">first</li>`, "<li>keep</li>", `<li class="change-deleted">last</li>`, "</ul>"}},
		{"- a\n- c\n", "- a\n- b\n- c\n", {"<li>a</li>", `<li class="change-deleted">b</li>`, "<li>c</li>"}},
		{"- new\n", "- old\n", {"<ul>", `<li class="change-deleted">old</li>`, `<li class="change-added">new</li>`, "</ul>"}},
		{"After.\n", "- gone\n  - nested\n\nAfter.\n", {`<ul class="change-deleted">`, `<li class="change-deleted">gone`, "<ul>", "<li>nested</li>", "</ul>", "</li>", "</ul>", "<p>After.</p>"}},
		{"", "4. gone\n5. also gone\n", {`<ol start="4" class="change-deleted">`, `<li value="4" class="change-deleted">gone</li>`, `<li value="5" class="change-deleted">also gone</li>`, "</ol>"}},
		{"4. a\n5. c\n", "4. a\n5. b\n6. c\n", {`<ol start="4">`, `<li value="4">a</li>`, `<li value="5" class="change-deleted">b</li>`, `<li value="5">c</li>`, "</ol>"}},
		{"- [x] task\n  - new\n", "- [ ] task\n  - old\n", {`<li class="change-deleted">`, `<input type="checkbox" disabled="" />`, "<li>old</li>", `<li class="change-added">`, `<input type="checkbox" checked="" disabled="" />`, "<li>new</li>"}},
		{"- new\n\n  paragraph\n", "- old\n\n  paragraph\n", {`<li class="change-deleted">`, "<p>old</p>", "<p>paragraph</p>", `<li class="change-added">`, "<p>new</p>"}},
		// Merging lists must keep intervening deletions between surviving items.
		{"- a\n- b\n", "- a\n\nBetween.\n\n- b\n", {"<li>a</li>", `<li class="change-deleted change-container">`, `<p class="change-deleted">Between.</p>`, "</li>", "<li>b</li>"}},
		// Splitting a list must leave the old item before the added paragraph.
		{"- a\n\nNew.\n\n- b\n", "- a\n- old\n- b\n", {"<li>a</li>", `<li class="change-deleted">old</li>`, "</ul>", `<p class="change-added">New.</p>`, "<ul>", "<li>b</li>"}},
	}
	for item in cases {
		commit := comparison_for_test(t, item.current, item.baseline)
		position := 0
		for fragment in item.fragments {
			index := strings.index(commit.comparison_html[position:], fragment)
			if !testing.expectf(t, index >= 0, "missing ordered fragment %s in %s", fragment, commit.comparison_html) { break }
			position += index + len(fragment)
		}
		testing.expect(t, !strings.contains(commit.comparison_html, "data-sourcepos"))
	}
}

@(test)
inline_deletions_complex_blocks_ids_and_safety :: proc(t: ^testing.T) {
	baseline := "# Same\n\n<a id=\"explicit\"></a> old\n\n> ## Quoted\n> old\n\n| A |\n|---|\n| old |\n\n```html\n<a id=\"literal\"></a>\n```\n\n<script>alert(1)</script>\n\n[bad](javascript:alert(1))\n\n<pre>\n<script>literal</script>\n</pre>\n"
	current := "# *Same*\n\n<a id=\"explicit\"></a> new\n"
	commit := comparison_for_test(t, current, baseline)
	for tag in ([]string{"h1", "p", "blockquote", "table", "pre"}) {
		testing.expect(t, strings.contains(commit.comparison_html, strings.concatenate({"<", tag, ` class="change-deleted">`})))
	}
	testing.expect_value(t, strings.count(commit.comparison_html, ` id="same"`), 1)
	testing.expect_value(t, strings.count(commit.comparison_html, ` id="explicit"`), 1)
	testing.expect(t, !strings.contains(commit.comparison_html, ` id="quoted"`))
	testing.expect(t, strings.contains(commit.comparison_html, `<h2>Quoted</h2>`))
	testing.expect(t, strings.contains(commit.comparison_html, `<a></a>`))
	testing.expect_value(t, deleted_html(`<pre><code>literal id="keep"</code></pre>`), `<pre class="change-deleted"><code>literal id="keep"</code></pre>`)
	testing.expect(t, !strings.contains(commit.comparison_html, "<script>"))
	testing.expect(t, !strings.contains(commit.comparison_html, "javascript:"))
	testing.expect(t, strings.contains(commit.comparison_html, "&lt;script&gt;literal&lt;/script&gt;"))
	testing.expect(t, strings.contains(render_outline(&commit), `href="#same"`))
	testing.expect(t, !strings.contains(render_outline(&commit), "Quoted"))
}

@(test)
inline_deletions_live_updates_and_history :: proc(t: ^testing.T) {
	root, path := make_fixture(t)
	defer os.remove_all(root)
	request := Watch_Request{repo_root = root, path = "docs with spaces/new name.md", commit_hash = "working"}
	_, ok := render_watch_fragments(&request)
	testing.expect(t, ok)
	must_write(t, path, "# First\n")
	live, live_ok, _ := render_watch_update(&request, Watch_Changes{contents = true}, "# First\n", true)
	testing.expect(t, live_ok)
	testing.expect(t, strings.contains(live, `<p class="change-deleted">Second snapshot.</p>`))
	testing.expect(t, !strings.contains(live, "deletions hidden"))
	must_git(t, root, []string{"add", "--", request.path})
	must_git(t, root, []string{"commit", "-q", "-m", "remove paragraphs"})
	refreshed, refresh_ok, _ := render_watch_update(&request, Watch_Changes{head = true}, "# First\n", true)
	testing.expect(t, refresh_ok)
	testing.expect(t, strings.contains(refreshed, `<p class="change-deleted">Second snapshot.</p>`))
	history, _, loaded := load_history_snapshots(root, request.path)
	testing.expect(t, loaded)
	_, rendered := render_history_snapshot(&history, 1)
	testing.expect(t, rendered)
	testing.expect(t, strings.contains(snapshot_fragments(&history, 1), `<p class="change-deleted">Second snapshot.</p>`))
	_, rendered = render_history_snapshot(&history, 2)
	testing.expect(t, rendered)
	testing.expect(t, !strings.contains(history.commits[2].comparison_html, "change-deleted"))
}
