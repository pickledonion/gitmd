package main

import "core:dynlib"
import "core:encoding/entity"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"

Cmark_API :: struct {
	core_library: dynlib.Library,
	ext_library:  dynlib.Library,
	parser_new:   proc "c" (options: i32) -> rawptr,
	parser_free:  proc "c" (parser: rawptr),
	parser_feed:  proc "c" (parser: rawptr, buffer: rawptr, length: uintptr),
	parser_finish: proc "c" (parser: rawptr) -> rawptr,
	parser_attach_syntax_extension: proc "c" (parser, extension: rawptr) -> i32,
	parser_get_syntax_extensions: proc "c" (parser: rawptr) -> rawptr,
	find_syntax_extension: proc "c" (name: cstring) -> rawptr,
	render_html: proc "c" (root: rawptr, options: i32, extensions: rawptr) -> cstring,
	node_free: proc "c" (node: rawptr),
	get_default_mem: proc "c" () -> ^Cmark_Mem,
	ensure_extensions: proc "c" (),
}

Cmark_Mem :: struct {
	calloc:  proc "c" (count, size: uintptr) -> rawptr,
	realloc: proc "c" (pointer: rawptr, size: uintptr) -> rawptr,
	free:    proc "c" (pointer: rawptr),
}

cmark_api: Cmark_API
cmark_api_loaded: bool
cmark_api_mutex: sync.Mutex

load_symbol :: proc(library: dynlib.Library, name: string) -> (rawptr, bool) {
	return dynlib.symbol_address(library, name)
}

load_cmark_from :: proc(core_path, extensions_path: string) -> (Cmark_API, bool) {
	api: Cmark_API
	core, core_ok := dynlib.load_library(core_path, true)
	if !core_ok {
		return {}, false
	}
	ext, ext_ok := dynlib.load_library(extensions_path, true)
	if !ext_ok {
		_ = dynlib.unload_library(core)
		return {}, false
	}
	api.core_library = core
	api.ext_library = ext

	p, ok := load_symbol(core, "cmark_parser_new"); if !ok { return {}, false }; api.parser_new = auto_cast p
	p, ok = load_symbol(core, "cmark_parser_free"); if !ok { return {}, false }; api.parser_free = auto_cast p
	p, ok = load_symbol(core, "cmark_parser_feed"); if !ok { return {}, false }; api.parser_feed = auto_cast p
	p, ok = load_symbol(core, "cmark_parser_finish"); if !ok { return {}, false }; api.parser_finish = auto_cast p
	p, ok = load_symbol(core, "cmark_parser_attach_syntax_extension"); if !ok { return {}, false }; api.parser_attach_syntax_extension = auto_cast p
	p, ok = load_symbol(core, "cmark_parser_get_syntax_extensions"); if !ok { return {}, false }; api.parser_get_syntax_extensions = auto_cast p
	p, ok = load_symbol(core, "cmark_find_syntax_extension"); if !ok { return {}, false }; api.find_syntax_extension = auto_cast p
	p, ok = load_symbol(core, "cmark_render_html"); if !ok { return {}, false }; api.render_html = auto_cast p
	p, ok = load_symbol(core, "cmark_node_free"); if !ok { return {}, false }; api.node_free = auto_cast p
	p, ok = load_symbol(core, "cmark_get_default_mem_allocator"); if !ok { return {}, false }; api.get_default_mem = auto_cast p
	p, ok = load_symbol(ext, "cmark_gfm_core_extensions_ensure_registered"); if !ok { return {}, false }; api.ensure_extensions = auto_cast p
	return api, true
}

load_cmark :: proc() -> (Cmark_API, string, bool) {
	sync.mutex_lock(&cmark_api_mutex)
	defer sync.mutex_unlock(&cmark_api_mutex)
	if cmark_api_loaded {
		return cmark_api, "", true
	}
	if custom := os.get_env("GITMD_CMARK_LIBDIR", context.temp_allocator); len(custom) > 0 {
		core_path := filepath_join(custom, "libcmark-gfm.dylib")
		ext_path := filepath_join(custom, "libcmark-gfm-extensions.dylib")
		api, ok := load_cmark_from(core_path, ext_path)
		if ok {
			api.ensure_extensions()
			cmark_api = api
			cmark_api_loaded = true
			return cmark_api, "", true
		}
	}
	prefixes := []string{"/opt/homebrew/opt/cmark-gfm/lib", "/usr/local/opt/cmark-gfm/lib"}
	for prefix in prefixes {
		api, ok := load_cmark_from(
			filepath_join(prefix, "libcmark-gfm.dylib"),
			filepath_join(prefix, "libcmark-gfm-extensions.dylib"),
		)
		if ok {
			api.ensure_extensions()
			cmark_api = api
			cmark_api_loaded = true
			return cmark_api, "", true
		}
	}
	return {}, "cmark-gfm not found; install it with: brew install cmark-gfm", false
}

filepath_join :: proc(directory, name: string) -> string {
	return strings.concatenate({directory, "/", name})
}

SAFE_ANCHOR_PREFIX :: "GITMD9F3A7SAFEANCHOR"

convert_safe_pre_blocks :: proc(markdown: string) -> string {
	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)
	position := 0
	for position < len(markdown) {
		relative_start := strings.index(markdown[position:], "<pre>")
		if relative_start < 0 { break }
		start := position + relative_start
		content_start := start + len("<pre>")
		relative_end := strings.index(markdown[content_start:], "</pre>")
		if relative_end < 0 { break }
		content_end := content_start + relative_end
		content := markdown[content_start:content_end]
		max_run := 0
		run := 0
		for byte in transmute([]byte)content {
			if byte == '`' {
				run += 1
				if run > max_run { max_run = run }
			} else {
				run = 0
			}
		}
		fence_length := max(3, max_run + 1)
		strings.write_string(&builder, markdown[position:start])
		for _ in 0 ..< fence_length { strings.write_byte(&builder, '`') }
		if len(content) == 0 || content[0] != '\n' { strings.write_byte(&builder, '\n') }
		strings.write_string(&builder, content)
		if len(content) == 0 || content[len(content) - 1] != '\n' { strings.write_byte(&builder, '\n') }
		for _ in 0 ..< fence_length { strings.write_byte(&builder, '`') }
		position = content_end + len("</pre>")
	}
	strings.write_string(&builder, markdown[position:])
	return strings.clone(strings.to_string(builder))
}

protect_safe_anchors :: proc(markdown: string) -> (string, [dynamic]string) {
	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)
	anchors := make([dynamic]string, 0)
	position := 0
	open :: `<a id="`
	close :: `"></a>`
	for position < len(markdown) {
		relative_start := strings.index(markdown[position:], open)
		if relative_start < 0 { break }
		start := position + relative_start
		id_start := start + len(open)
		relative_end := strings.index(markdown[id_start:], close)
		if relative_end < 0 { break }
		id_end := id_start + relative_end
		if id_end == id_start {
			position = id_end + len(close)
			continue
		}
		strings.write_string(&builder, markdown[position:start])
		fmt.sbprintf(&builder, "%s%dX", SAFE_ANCHOR_PREFIX, len(anchors))
		append(&anchors, strings.clone(markdown[id_start:id_end]))
		position = id_end + len(close)
	}
	strings.write_string(&builder, markdown[position:])
	return strings.clone(strings.to_string(builder)), anchors
}

strip_html_tags :: proc(html: string) -> string {
	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)
	in_tag := false
	for byte in transmute([]byte)html {
		if byte == '<' {
			in_tag = true
		} else if byte == '>' {
			in_tag = false
		} else if !in_tag {
			strings.write_byte(&builder, byte)
		}
	}
	text := strings.to_string(builder)
	unescaped, allocated, _ := entity.unescape_html(text)
	if allocated { return unescaped }
	return strings.clone(unescaped)
}

github_heading_slug :: proc(text: string) -> string {
	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)
	for byte in transmute([]byte)text {
		switch byte {
		case 'A'..='Z':
			strings.write_byte(&builder, byte + ('a' - 'A'))
		case 'a'..='z', '0'..='9', '-', '_':
			strings.write_byte(&builder, byte)
		case ' ', '\t', '\n', '\r':
			strings.write_byte(&builder, '-')
		case 0x80..=0xff:
			strings.write_byte(&builder, byte)
		}
	}
	return strings.clone(strings.to_string(builder))
}

add_heading_ids :: proc(html: string) -> string {
	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)
	counts := make(map[string]int)
	defer delete(counts)
	position := 0
	for position < len(html) {
		relative_start := strings.index(html[position:], "<h")
		if relative_start < 0 { break }
		start := position + relative_start
		if start + 3 >= len(html) || html[start + 2] < '1' || html[start + 2] > '6' || html[start + 3] != '>' {
			strings.write_string(&builder, html[position:start + 2])
			position = start + 2
			continue
		}
		level := html[start + 2]
		close := fmt.aprintf("</h%c>", level)
		inner_start := start + 4
		relative_end := strings.index(html[inner_start:], close)
		if relative_end < 0 { break }
		end := inner_start + relative_end
		text := strip_html_tags(html[inner_start:end])
		slug := github_heading_slug(text)
		strings.write_string(&builder, html[position:start])
		if len(slug) == 0 {
			strings.write_string(&builder, html[start:end + len(close)])
		} else {
			count := counts[slug]
			id := slug
			if count > 0 { id = fmt.aprintf("%s-%d", slug, count) }
			if slug not_in counts {
				counts[strings.clone(slug)] = 1
			} else {
				counts[slug] = count + 1
			}
			fmt.sbprintf(&builder, `<h%c id="%s">`, level, html_escape(id))
			strings.write_string(&builder, html[inner_start:end + len(close)])
		}
		position = end + len(close)
	}
	strings.write_string(&builder, html[position:])
	return strings.clone(strings.to_string(builder))
}

render_markdown :: proc(api: ^Cmark_API, markdown: string) -> (string, bool) {
	prepared_markdown := convert_safe_pre_blocks(markdown)
	protected_markdown, anchors := protect_safe_anchors(prepared_markdown)
	parser := api.parser_new(0)
	if parser == nil { return "", false }
	defer api.parser_free(parser)
	extension_names := []cstring{"table", "tasklist", "autolink", "strikethrough", "tagfilter"}
	for extension_name in extension_names {
		extension := api.find_syntax_extension(extension_name)
		if extension == nil || api.parser_attach_syntax_extension(parser, extension) == 0 {
			return "", false
		}
	}
	api.parser_feed(parser, raw_data(protected_markdown), uintptr(len(protected_markdown)))
	document := api.parser_finish(parser)
	if document == nil { return "", false }
	defer api.node_free(document)
	html_c := api.render_html(document, 0, api.parser_get_syntax_extensions(parser))
	if html_c == nil { return "", false }
	html := strings.clone(string(html_c))
	api.get_default_mem().free(rawptr(html_c))
	for id, index in anchors {
		token := fmt.aprintf("%s%dX", SAFE_ANCHOR_PREFIX, index)
		anchor := fmt.aprintf(`<a id="%s"></a>`, html_escape(id))
		html, _ = strings.replace_all(html, token, anchor)
	}
	return add_heading_ids(html), true
}

render_all_snapshots :: proc(history: ^History) -> (string, bool) {
	api, message, loaded := load_cmark()
	if !loaded { return message, false }
	for &commit in history.commits {
		html, rendered := render_markdown(&api, commit.markdown)
		if !rendered {
			return "cmark-gfm failed to render a committed snapshot", false
		}
		commit.html = html
	}
	return "", true
}

render_history_snapshot :: proc(history: ^History, index: int) -> (string, bool) {
	if index < 0 || index >= len(history.commits) {
		return "snapshot does not exist", false
	}
	commit := &history.commits[index]
	if len(commit.html) > 0 {
		return "", true
	}
	if len(commit.markdown) == 0 && !commit.working {
		message, loaded := load_blob(history.repo_root, commit)
		if !loaded {
			return message, false
		}
	}
	api, message, loaded := load_cmark()
	if !loaded { return message, false }
	html, rendered := render_markdown(&api, commit.markdown)
	if !rendered {
		return "cmark-gfm failed to render a committed snapshot", false
	}
	commit.html = html
	return "", true
}
