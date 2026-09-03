package main

import "core:os"
import "core:dynlib"
import "core:path/filepath"
import "core:strings"
import "core:testing"

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
	testing.expect_value(t, len(history.commits), 3)
	testing.expect_value(t, history.commits[0].subject, "newest subject")
	testing.expect_value(t, history.commits[1].subject, "rename subject")
	testing.expect_value(t, history.commits[2].subject, "first subject")
	testing.expect_value(t, history.commits[0].path, "docs with spaces/new name.md")
	testing.expect_value(t, history.commits[2].path, "docs with spaces/old name.md")
	testing.expect(t, strings.contains(history.commits[0].markdown, "Second snapshot."))
	testing.expect(t, !strings.contains(history.commits[2].markdown, "Second snapshot."))
	testing.expect_value(t, len(history.commits[0].full_hash), 40)
	testing.expect(t, len(history.commits[0].author_date) >= 10)
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
	testing.expect(t, strings.has_prefix(valid.body, "<article id=\"preview\""))
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
	testing.expect(t, strings.contains(page, "searching: false"))
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
	testing.expect(t, strings.contains(page, `if (!['Escape','ArrowUp','ArrowDown'].includes(evt.key)) evt.stopPropagation()`))
	testing.expect(t, strings.contains(page, `data-on:input="const query = evt.currentTarget.value.toLowerCase()`))
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
invalid_inputs_are_rejected :: proc(t: ^testing.T) {
	root, path := make_fixture(t)
	defer os.remove_all(root)
	untracked := test_path(root, "untracked.md")
	must_write(t, untracked, "nothing committed\n")
	_, _, tracked := load_history(untracked)
	testing.expect(t, !tracked)
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
		testing.expect_value(t, history.commits[0].markdown, "")
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
	testing.expect(t, strings.contains(page, `<li class="outline-level-1"><a href="#older-guide">Older guide</a></li>`))
	testing.expect(t, strings.contains(page, `<li class="outline-level-2"><a href="#install">Install &amp; run</a></li>`))
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
