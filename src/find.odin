package main

import "core:encoding/json"
import "core:fmt"
import "core:mem/virtual"
import "core:net"
import "core:os"
import "core:strings"

FIND_SCRIPT :: #load("assets/find.mjs")

Find_Target :: struct {
	path: string,
	label: string,
	id: string,
	url: string,
}

Find_Index :: struct {
	targets: [dynamic]Find_Target,
	skipped: int,
}

// Read the renderer's IDs so duplicate headings and explicit anchors jump to
// exactly the same place as the document outline. Code examples are not targets.
append_find_targets :: proc(targets: ^[dynamic]Find_Target, path, html: string) {
	url := repository_url(path)
	seen := make(map[string]bool)
	position := 0
	for position < len(html) {
		relative := strings.index_byte(html[position:], '<')
		if relative < 0 { break }
		start := position + relative
		end := find_byte_from(html, '>', start)
		if end < 0 { break }
		tag := html[start:end + 1]
		position = end + 1
		if tag == "<pre>" || tag == "<code>" || strings.has_prefix(tag, "<pre ") || strings.has_prefix(tag, "<code ") {
			close := "</code>"
			if strings.has_prefix(tag, "<pre") { close = "</pre>" }
			if offset := strings.index(html[position:], close); offset >= 0 {
				position += offset + len(close)
			}
			continue
		}
		heading := len(tag) > 4 && tag[1] == 'h' && tag[2] >= '1' && tag[2] <= '6' && tag[3] == ' '
		if !heading && !strings.has_prefix(tag, "<a ") { continue }
		id_start := strings.index(tag, ` id="`)
		if id_start < 0 { continue }
		id_start += len(` id="`)
		id_end := find_byte_from(tag, '"', id_start)
		if id_end < 0 { continue }
		id := strip_html_tags(tag[id_start:id_end])
		if len(id) == 0 || id in seen { continue }
		seen[id] = true
		label := id
		if heading {
			close := fmt.aprintf("</h%c>", tag[2])
			if offset := strings.index(html[position:], close); offset >= 0 {
				label = strip_html_tags(html[position:position + offset])
			}
		}
		append(targets, Find_Target{
			path = path, label = label, id = id,
			url = strings.concatenate({url, "#", net.percent_encode(id, context.temp_allocator)}),
		})
	}
}

repository_find_response :: proc(repository: ^Repository) -> Http_Response {
	if repository == nil { return not_found() }
	// Searching must not retain every document rendered on every picker opening.
	output_allocator := context.allocator
	arena: virtual.Arena
	if err := virtual.arena_init_growing(&arena); err != nil {
		return {status = 500, reason = "Internal Server Error", content_type = "text/plain; charset=utf-8", body = "Could not allocate repository search.\n"}
	}
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	context.temp_allocator = context.allocator
	api, _, ready := load_cmark()
	files, listed := list_repository_files(repository.repo_root)
	if !ready || !listed {
		return {status = 500, reason = "Internal Server Error", content_type = "text/plain; charset=utf-8", body = "Could not load repository search.\n"}
	}
	index := Find_Index{targets = make([dynamic]Find_Target)}
	for path in files {
		if !is_markdown_path(path) { continue }
		contents, err := os.read_entire_file(filepath_join(repository.repo_root, path), context.allocator)
		if err != nil { index.skipped += 1; continue }
		html, rendered := render_markdown(&api, string(contents))
		if !rendered { index.skipped += 1; continue }
		append_find_targets(&index.targets, path, html)
	}
	data, err := json.marshal(index, allocator = output_allocator)
	if err != nil {
		return {status = 500, reason = "Internal Server Error", content_type = "text/plain; charset=utf-8", body = "Could not encode repository search.\n"}
	}
	return {status = 200, reason = "OK", content_type = "application/json; charset=utf-8", body = string(data)}
}

render_repository_find :: proc() -> string {
	return strings.concatenate({
		`<section id="ids" class="id-browser" aria-label="Repository IDs" data-show="$sidebar === 'id'" data-effect="document.dispatchEvent(new CustomEvent('gitmd-id-tab', {detail:$sidebar === 'id'}))" data-on:gitmd-id-preview__document="$selected = 0; evt.detail.promise = @get(evt.detail.url, {requestCancellation:evt.detail.controller})">`,
		`<form class="sidebar-search" role="search" data-show="$idSearching" data-on:submit="evt.preventDefault()">
<label for="id-search-input" aria-label="Filter IDs">/</label>
<input id="id-search-input" type="search" autocomplete="off" autocapitalize="off" spellcheck="false" aria-label="Filter IDs" data-on:keydown="if (!['Escape','ArrowUp','ArrowDown'].includes(evt.key)) evt.stopPropagation()">
</form>`,
		`<p class="id-status" role="status"></p><ol aria-label="ID destinations"></ol></section>`,
	})
}
