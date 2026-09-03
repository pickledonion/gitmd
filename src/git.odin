package main

import "core:os"
import "core:path/filepath"
import "core:strings"

Commit :: struct {
	full_hash:  string,
	short_hash: string,
	author_date: string,
	subject:     string,
	path:        string,
	blob_hash:   string,
	markdown:    string,
	html:        string,
	working:     bool,
}

History :: struct {
	repo_root: string,
	path:      string,
	commits:   [dynamic]Commit,
}

Repository :: struct {
	repo_root:     string,
	files:         [dynamic]string,
	selected_file: int,
}

Command_Result :: struct {
	stdout: string,
	stderr: string,
	ok:     bool,
}

run_command :: proc(working_dir: string, command: []string) -> Command_Result {
	state, stdout, stderr, err := os.process_exec(
		{working_dir = working_dir, command = command},
		context.allocator,
	)
	if err != nil {
		return {stderr = strings.clone(err_string(err)), ok = false}
	}
	return {
		stdout = string(stdout),
		stderr = string(stderr),
		ok = state.exited && state.exit_code == 0,
	}
}

err_string :: proc(err: os.Error) -> string {
	if err == nil {
		return ""
	}
	return "could not start subprocess"
}

trim_command_output :: proc(s: string) -> string {
	return strings.trim(s, " \t\r\n")
}

find_byte_from :: proc(s: string, needle: byte, start: int) -> int {
	for i := start; i < len(s); i += 1 {
		if s[i] == needle {
			return i
		}
	}
	return -1
}

starts_with_parent :: proc(path: string) -> bool {
	return path == ".." || strings.has_prefix(path, "../")
}

resolve_repo_path :: proc(input_path: string) -> (repo_root, relative_path, message: string, ok: bool) {
	absolute, abs_err := filepath.abs(input_path)
	if abs_err != nil {
		return "", "", "could not resolve markdown path", false
	}
	directory := filepath.dir(absolute)
	result := run_command(directory, []string{"/usr/bin/git", "rev-parse", "--show-toplevel"})
	if !result.ok {
		return "", "", "not inside a Git repository", false
	}
	repo_root = strings.clone(trim_command_output(result.stdout))
	relative, rel_err := filepath.rel(repo_root, absolute)
	if rel_err != nil || starts_with_parent(relative) {
		return "", "", "markdown path is outside the repository", false
	}
	return repo_root, strings.clone(relative), "", true
}

is_markdown_path :: proc(path: string) -> bool {
	lower := strings.to_lower(path, context.temp_allocator)
	return strings.has_suffix(lower, ".md") || strings.has_suffix(lower, ".markdown")
}

load_repository :: proc(input_path: string) -> (Repository, string, bool) {
	absolute, abs_err := filepath.abs(input_path)
	if abs_err != nil {
		return {}, "could not resolve repository path", false
	}
	is_directory := os.is_dir(absolute)
	working_dir := absolute
	if !is_directory {
		working_dir = filepath.dir(absolute)
	}
	root_result := run_command(working_dir, []string{"/usr/bin/git", "rev-parse", "--show-toplevel"})
	if !root_result.ok {
		return {}, "not inside a Git repository", false
	}
	repo_root := strings.clone(trim_command_output(root_result.stdout))
	listing := run_command(repo_root, []string{
		"/usr/bin/git", "ls-files", "--cached", "--others", "--exclude-standard", "-z",
	})
	if !listing.ok {
		return {}, "could not list repository files", false
	}
	files := make([dynamic]string, 0)
	position := 0
	for position < len(listing.stdout) {
		end := find_byte_from(listing.stdout, 0, position)
		if end < 0 { end = len(listing.stdout) }
		if end > position {
			path := listing.stdout[position:end]
			if is_markdown_path(path) {
				append(&files, strings.clone(path))
			}
		}
		position = end + 1
	}
	if len(files) == 0 {
		return {}, "repository has no Markdown files", false
	}
	selected := 0
	if !is_directory {
		relative, rel_err := filepath.rel(repo_root, absolute)
		if rel_err != nil || starts_with_parent(relative) {
			return {}, "markdown path is outside the repository", false
		}
		found := false
		for path, index in files {
			if path == relative {
				selected = index
				found = true
				break
			}
		}
		if !found {
			return {}, "path is not a Markdown file in the repository", false
		}
	} else {
		for path, index in files {
			if strings.to_lower(path, context.temp_allocator) == "readme.md" {
				selected = index
				break
			}
		}
	}
	return Repository{repo_root = repo_root, files = files, selected_file = selected}, "", true
}

parse_history_log :: proc(output: string) -> ([dynamic]Commit, bool) {
	commits := make([dynamic]Commit, 0)
	position := 0
	for {
		marker := find_byte_from(output, 0x1e, position)
		if marker < 0 {
			break
		}
		next := find_byte_from(output, 0x1e, marker + 1)
		if next < 0 {
			next = len(output)
		}
		record := output[marker + 1:next]
		header_end := find_byte_from(record, 0, 0)
		if header_end < 0 {
			return commits, false
		}
		fields := strings.split(record[:header_end], "\x1f")
		if len(fields) != 4 {
			return commits, false
		}
		path_start := header_end + 1
		for path_start < len(record) && (record[path_start] == '\n' || record[path_start] == '\r') {
			path_start += 1
		}
		path_end := find_byte_from(record, 0, path_start)
		if path_end < 0 {
			path_end = len(record)
		}
		if path_end == path_start {
			return commits, false
		}
		append(&commits, Commit{
			full_hash = strings.clone(fields[0]),
			short_hash = strings.clone(fields[1]),
			author_date = strings.clone(fields[2]),
			subject = strings.clone(fields[3]),
			path = strings.clone(record[path_start:path_end]),
		})
		position = next
	}
	return commits, len(commits) > 0
}

load_commit_list :: proc(repo_root, relative_path: string) -> ([dynamic]Commit, string, bool) {
	args := []string{
		"/usr/bin/git", "log", "--follow", "--find-renames",
		"--format=%x1e%H%x1f%h%x1f%aI%x1f%s", "--name-only", "-z",
		"--", relative_path,
	}
	result := run_command(repo_root, args)
	if !result.ok {
		return nil, "could not read Git history", false
	}
	commits, parsed := parse_history_log(result.stdout)
	if !parsed {
		return nil, "path has no committed snapshots", false
	}
	return commits, "", true
}

load_blob :: proc(repo_root: string, commit: ^Commit) -> (string, bool) {
	listing := run_command(repo_root, []string{
		"/usr/bin/git", "ls-tree", "-z", commit.full_hash, "--", commit.path,
	})
	if !listing.ok || len(listing.stdout) == 0 {
		return "committed path is missing from tree", false
	}
	tab := find_byte_from(listing.stdout, '\t', 0)
	if tab < 0 {
		return "unexpected ls-tree output", false
	}
	metadata := strings.split(listing.stdout[:tab], " ")
	if len(metadata) != 3 || metadata[1] != "blob" {
		return "committed path is not a regular file", false
	}
	commit.blob_hash = strings.clone(metadata[2])
	blob := run_command(repo_root, []string{
		"/usr/bin/git", "cat-file", "blob", commit.blob_hash,
	})
	if !blob.ok {
		return "could not read committed blob", false
	}
	commit.markdown = strings.clone(blob.stdout)
	return "", true
}

load_working_snapshot :: proc(repo_root, relative_path: string) -> (Commit, bool) {
	absolute_path, path_err := filepath.join([]string{repo_root, relative_path})
	if path_err != nil {
		return {}, false
	}
	contents, read_err := os.read_entire_file(absolute_path, context.allocator)
	if read_err != nil {
		return {}, false
	}
	return Commit{
		full_hash = "working",
		short_hash = "working",
		subject = "Working tree",
		path = strings.clone(relative_path),
		markdown = string(contents),
		working = true,
	}, true
}

load_history_snapshots :: proc(repo_root, relative_path: string) -> (History, string, bool) {
	commits, history_message, committed := load_commit_list(repo_root, relative_path)
	working, has_working := load_working_snapshot(repo_root, relative_path)
	if !committed && !has_working {
		return {}, history_message, false
	}
	all := make([dynamic]Commit, 0, len(commits) + 1)
	if has_working {
		append(&all, working)
	}
	append(&all, ..commits[:])
	return History{repo_root = repo_root, path = relative_path, commits = all}, "", true
}

load_history :: proc(input_path: string) -> (History, string, bool) {
	repo_root, relative_path, message, resolved := resolve_repo_path(input_path)
	if !resolved {
		return {}, message, false
	}
	history, history_message, loaded := load_history_snapshots(repo_root, relative_path)
	if !loaded {
		return {}, history_message, false
	}
	for &commit in history.commits {
		if commit.working { continue }
		blob_message, blob_loaded := load_blob(repo_root, &commit)
		if !blob_loaded {
			return {}, blob_message, false
		}
	}
	return history, "", true
}

load_repository_history :: proc(repository: ^Repository, index: int) -> (History, string, bool) {
	if index < 0 || index >= len(repository.files) {
		return {}, "Markdown file does not exist", false
	}
	path := repository.files[index]
	return load_history_snapshots(repository.repo_root, path)
}
