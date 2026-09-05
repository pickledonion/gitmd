package main

import "core:fmt"
import "core:strings"
import "core:strconv"

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

Block_Match :: struct { current, baseline: int }

match_blocks :: proc(current, baseline: []Markdown_Block, matched: ^[dynamic]Block_Match, current_offset := 0, baseline_offset := 0) {
	if len(current) == 0 || len(baseline) == 0 { return }
	if len(current) == 1 {
		for block, index in baseline {
			if current[0].content == block.content {
				append(matched, Block_Match{current_offset, baseline_offset + index})
				break
			}
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
	match_blocks(current[:middle], baseline[:split], matched, current_offset, baseline_offset)
	match_blocks(current[middle:], baseline[split:], matched, current_offset + middle, baseline_offset + split)
}

// These offsets refer to safe cmark output, never to user-provided HTML.
Block_Span :: struct {
	start, end: int,
	list: int,
	number: int,
}
List_Span :: struct {
	start, open_end, close_start, end: int,
	ordered: bool,
}

html_attribute :: proc(tag, name: string) -> string {
	prefix := strings.concatenate({" ", name, `="`})
	defer delete(prefix)
	start := strings.index(tag, prefix)
	if start < 0 { return "" }
	start += len(prefix)
	end := find_byte_from(tag, '"', start)
	if end < 0 { return "" }
	return tag[start:end]
}

comparison_layout :: proc(commit: ^Commit) -> ([]Block_Span, [dynamic]List_Span) {
	spans := make([]Block_Span, len(commit.blocks))
	lists := make([dynamic]List_Span)
	indices := make(map[string]int)
	defer delete(indices)
	for block, index in commit.blocks { indices[block.position] = index }
	Frame :: struct { block, list: int }
	stack := make([dynamic]Frame)
	defer delete(stack)
	html := commit.positioned_html
	position, number := 0, 0
	for position < len(html) {
		relative := strings.index(html[position:], "<")
		if relative < 0 { break }
		start := position + relative
		if strings.has_prefix(html[start:], "<!--") {
			end := strings.index(html[start:], "-->")
			if end < 0 { break }
			position = start + end + 3
			continue
		}
		end := find_byte_from(html, '>', start) + 1
		if end == 0 { break }
		position = end
		tag := html[start:end]
		if strings.has_prefix(tag, "</") {
			if len(stack) == 0 { continue }
			frame := pop(&stack)
			if frame.block >= 0 { spans[frame.block].end = end }
			if frame.list >= 0 {
				lists[frame.list].close_start = start
				lists[frame.list].end = end
			}
			continue
		}
		name_end := 1
		for name_end < len(tag) && tag[name_end] != ' ' && tag[name_end] != '>' { name_end += 1 }
		name := tag[1:name_end]
		frame := Frame{-1, -1}
		if len(stack) == 0 && (name == "ul" || name == "ol") {
			frame.list = len(lists)
			append(&lists, List_Span{start = start, open_end = end, ordered = name == "ol"})
			number = 1
			if value := html_attribute(tag, "start"); len(value) > 0 { number, _ = strconv.parse_int(value) }
		}
		key := fmt.aprintf("%s:%s", name, html_attribute(tag, "data-sourcepos"))
		if index, ok := indices[key]; ok {
			frame.block = index
			list := -1
			if len(stack) == 1 { list = stack[0].list }
			spans[index] = Block_Span{start, end, list, number}
			if list >= 0 { number += 1 }
		}
		delete(key)
		if name != "hr" && name != "br" && name != "img" && name != "input" { append(&stack, frame) }
	}
	return spans, lists
}

// Strip IDs only inside tags; literal code and anchor link destinations survive.
deleted_html :: proc(html: string) -> string {
	clean := mark_block_positions(html, nil)
	defer delete(clean)
	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)
	position := 0
	first := true
	for position < len(clean) {
		relative := strings.index(clean[position:], "<")
		if relative < 0 { break }
		start := position + relative
		end := find_byte_from(clean, '>', start)
		if end < 0 { break }
		strings.write_string(&builder, clean[position:start])
		tag := clean[start:end]
		self_closing := strings.has_suffix(tag, " /")
		if self_closing { tag = tag[:len(tag) - 2] }
		if id_start := strings.index(tag, ` id="`); id_start >= 0 {
			id_end := find_byte_from(tag, '"', id_start + 5)
			strings.write_string(&builder, tag[:id_start])
			strings.write_string(&builder, tag[id_end + 1:])
		} else { strings.write_string(&builder, tag) }
		if first {
			strings.write_string(&builder, ` class="change-deleted"`)
			first = false
		}
		if self_closing { strings.write_string(&builder, " /") }
		strings.write_byte(&builder, '>')
		position = end + 1
	}
	strings.write_string(&builder, clean[position:])
	return strings.clone(strings.to_string(builder))
}

compare_snapshot :: proc(current, baseline: ^Commit, label: string) {
	current.comparison_label = label
	current.comparison_html = current.html
	if !current.rendered { return }
	matched := make([dynamic]Block_Match)
	defer delete(matched)
	if baseline != nil { match_blocks(current.blocks[:], baseline.blocks[:], &matched) }
	changed := make(map[string]bool)
	defer delete(changed)
	for block in current.blocks { changed[block.position] = true }
	for pair in matched { delete_key(&changed, current.blocks[pair.current].position) }
	if baseline == nil || len(matched) == len(baseline.blocks) {
		current.comparison_html = mark_block_positions(current.positioned_html, changed)
		return
	}
	spans, lists := comparison_layout(current)
	old_spans, old_lists := comparison_layout(baseline)
	defer delete(spans)
	defer delete(lists)
	defer delete(old_spans)
	defer delete(old_lists)
	List_Match :: struct { baseline, current: int }
	list_matches := make(map[List_Match]bool)
	defer delete(list_matches)
	for pair in matched {
		old, new := old_spans[pair.baseline].list, spans[pair.current].list
		if old >= 0 && new >= 0 && old_lists[old].ordered == lists[new].ordered {
			list_matches[List_Match{old, new}] = true
		}
	}
	insertions := make(map[int]string)
	defer { for _, value in insertions { delete(value) }; delete(insertions) }
	insert :: proc(insertions: ^map[int]string, position: int, html: string) {
		old := insertions^[position]
		insertions^[position] = strings.concatenate({old, html})
		delete(old)
	}
	// Explicit values keep current ordered-list numbering stable in both views.
	for span in spans {
		if span.list >= 0 && lists[span.list].ordered {
			value := fmt.aprintf(` value="%d"`, span.number)
			insert(&insertions, span.start + 3, value)
			delete(value)
		}
	}
	append(&matched, Block_Match{len(spans), len(old_spans)})
	ci, bi := 0, 0
	for pair in matched {
		if bi < pair.baseline {
			// Insert each gap together so every deletion precedes every addition.
			position, target := len(current.positioned_html), -1
			old_list := old_spans[bi].list
			single_list := old_list >= 0
			for index in bi ..< pair.baseline {
				if old_spans[index].list != old_list { single_list = false }
			}
			if ci < len(spans) {
				position = spans[ci].start
				candidate := spans[ci].list
				if candidate >= 0 {
					position = lists[candidate].start
					// Interior gaps must stay between the surviving list items.
					if ci > 0 && spans[ci - 1].list == candidate {
						target = candidate
					} else if single_list && old_lists[old_list].ordered == lists[candidate].ordered &&
					          (list_matches[List_Match{old_list, candidate}] || ci < pair.current) {
						// This also handles lists whose items were all replaced.
						target = candidate
					}
					if target >= 0 { position = spans[ci].start }
				}
			}
			if target < 0 && single_list && ci > 0 {
				candidate := spans[ci - 1].list
				if candidate >= 0 && list_matches[List_Match{old_list, candidate}] {
					target, position = candidate, lists[candidate].close_start
				}
			}
			builder := strings.builder_make()
			for bi < pair.baseline {
				old := old_spans[bi]
				end := bi + 1
				if old.list >= 0 {
					for end < pair.baseline && old_spans[end].list == old.list { end += 1 }
				}
				inline_items := target >= 0 && old.list >= 0 && old_lists[old.list].ordered == lists[target].ordered &&
				                (single_list || list_matches[List_Match{old.list, target}])
				// A removed block between items of a now-merged list needs a list
				// item container. Hiding that container restores the original list.
				if target >= 0 && !inline_items {
					strings.write_string(&builder, `<li class="change-deleted change-container">`)
				}
				if old.list >= 0 && !inline_items {
					list := old_lists[old.list]
					wrapper := deleted_html(baseline.positioned_html[list.start:list.open_end])
					strings.write_string(&builder, wrapper)
					delete(wrapper)
				}
				for index in bi ..< end {
					span := old_spans[index]
					html := deleted_html(baseline.positioned_html[span.start:span.end])
					if span.list >= 0 && old_lists[span.list].ordered {
						fmt.sbprintf(&builder, `<li value="%d"%s`, span.number, html[3:])
					} else { strings.write_string(&builder, html) }
					strings.write_byte(&builder, '\n')
					delete(html)
				}
				if old.list >= 0 && !inline_items {
					list := old_lists[old.list]
					strings.write_string(&builder, baseline.positioned_html[list.close_start:list.end])
					strings.write_byte(&builder, '\n')
				}
				if target >= 0 && !inline_items { strings.write_string(&builder, "</li>\n") }
				bi = end
			}
			insert(&insertions, position, strings.to_string(builder))
			strings.builder_destroy(&builder)
		}
		ci, bi = pair.current + 1, pair.baseline + 1
	}

	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)
	for position in 0 ..= len(current.positioned_html) {
		if html, ok := insertions[position]; ok { strings.write_string(&builder, html) }
		if position < len(current.positioned_html) { strings.write_byte(&builder, current.positioned_html[position]) }
	}
	current.comparison_html = mark_block_positions(strings.to_string(builder), changed)
}

render_markdown :: proc(api: ^Cmark_API, markdown: string) -> (string, bool) {
	html, _, _, ok := render_markdown_blocks(api, markdown)
	return html, ok
}
