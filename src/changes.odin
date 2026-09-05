package main

import "core:fmt"
import "core:strings"

CMARK_OPT_SOURCEPOS :: 1 << 1

Markdown_Block :: struct {
	content: string,
	position: string,
}

restore_block_anchors :: proc(html: string, anchors: []string) -> string {
	result := html
	for id, index in anchors {
		token := fmt.aprintf("%s%dX", SAFE_ANCHOR_PREFIX, index)
		anchor := fmt.aprintf(`<a id="%s"></a>`, html_escape(id))
		result, _ = strings.replace_all(result, token, anchor)
	}
	return result
}

// Only lists are traversed: each outer list item owns all its nested content.
// Quotes, tables and code blocks likewise remain indivisible units.
collect_markdown_blocks :: proc(api: ^Cmark_API, parent, extensions: rawptr, anchors: []string, blocks: ^[dynamic]Markdown_Block) {
	for node := api.node_first_child(parent); node != nil; node = api.node_next(node) {
		kind := string(api.node_get_type_string(node))
		if kind == "list" {
			collect_markdown_blocks(api, node, extensions, anchors, blocks)
			continue
		}
		html_c := api.render_html(node, 0, extensions)
		if html_c == nil { continue }
		content := restore_block_anchors(strings.clone(string(html_c)), anchors)
		api.get_default_mem().free(rawptr(html_c))
		tag_end := 1
		for tag_end < len(content) && content[tag_end] != ' ' && content[tag_end] != '>' { tag_end += 1 }
		if tag_end >= len(content) || content[0] != '<' || content[1] == '!' { continue }
		position := fmt.aprintf("%s:%d:%d-%d:%d", content[1:tag_end], api.node_get_start_line(node), api.node_get_start_column(node), api.node_get_end_line(node), api.node_get_end_column(node))
		append(blocks, Markdown_Block{content = content, position = position})
	}
}

// Strip cmark's internal positions, replacing only unmatched block positions
// with a class. Existing tags, heading IDs and inline content stay in place.
mark_block_positions :: proc(html: string, changed: map[string]bool) -> string {
	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)
	position := 0
	attribute :: ` data-sourcepos="`
	for position < len(html) {
		relative := strings.index(html[position:], attribute)
		if relative < 0 { break }
		start := position + relative
		value_start := start + len(attribute)
		end := find_byte_from(html, '"', value_start)
		if end < 0 { break }
		strings.write_string(&builder, html[position:start])
		tag_start := start - 1
		for tag_start >= 0 && html[tag_start] != '<' { tag_start -= 1 }
		tag_end := tag_start + 1
		for tag_end < start && html[tag_end] != ' ' && html[tag_end] != '>' { tag_end += 1 }
		key := fmt.aprintf("%s:%s", html[tag_start + 1:tag_end], html[value_start:end])
		if changed[key] {
			strings.write_string(&builder, ` class="change-added"`)
		}
		delete(key)
		position = end + 1
	}
	strings.write_string(&builder, html[position:])
	return strings.clone(strings.to_string(builder))
}

// Hirschberg LCS keeps memory linear even for documents with many blocks.
lcs_lengths :: proc(current, baseline: []Markdown_Block, reverse: bool) -> []int {
	row := make([]int, len(baseline) + 1)
	for i in 0 ..< len(current) {
		previous := 0
		ci := i
		if reverse { ci = len(current) - 1 - i }
		for j in 0 ..< len(baseline) {
			bj := j
			if reverse { bj = len(baseline) - 1 - j }
			old := row[j + 1]
			if current[ci].content == baseline[bj].content {
				row[j + 1] = previous + 1
			} else {
				row[j + 1] = max(row[j], row[j + 1])
			}
			previous = old
		}
	}
	return row
}

match_blocks :: proc(current, baseline: []Markdown_Block, matched: []bool) {
	if len(current) == 0 || len(baseline) == 0 { return }
	if len(current) == 1 {
		for block in baseline {
			if current[0].content == block.content { matched[0] = true; break }
		}
		return
	}
	middle := len(current) / 2
	left := lcs_lengths(current[:middle], baseline, false)
	right := lcs_lengths(current[middle:], baseline, true)
	split, best := 0, -1
	for j in 0 ..= len(baseline) {
		length := left[j] + right[len(baseline) - j]
		if length > best { split, best = j, length }
	}
	delete(left)
	delete(right)
	match_blocks(current[:middle], baseline[:split], matched[:middle])
	match_blocks(current[middle:], baseline[split:], matched[middle:])
}

compare_snapshot :: proc(current, baseline: ^Commit, label: string) {
	matched := make([]bool, len(current.blocks))
	defer delete(matched)
	if baseline != nil { match_blocks(current.blocks[:], baseline.blocks[:], matched) }
	changed := make(map[string]bool)
	defer delete(changed)
	for block, index in current.blocks {
		if !matched[index] { changed[block.position] = true }
	}
	current.comparison_html = current.html
	if current.rendered { current.comparison_html = mark_block_positions(current.positioned_html, changed) }
	current.comparison_label = label
}

render_markdown :: proc(api: ^Cmark_API, markdown: string) -> (string, bool) {
	html, _, _, ok := render_markdown_blocks(api, markdown)
	return html, ok
}
