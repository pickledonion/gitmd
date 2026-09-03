package main

import "core:fmt"
import "core:net"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sys/posix"
import "core:thread"
import "core:time"

Http_Response :: struct {
	status:       int,
	reason:       string,
	content_type: string,
	body:         string,
}

not_found :: proc() -> Http_Response {
	return {status = 404, reason = "Not Found", content_type = "text/plain; charset=utf-8", body = "not found\n"}
}

query_parameter :: proc(target, name: string) -> string {
	query_start := strings.index_byte(target, '?')
	if query_start < 0 { return "" }
	for field in strings.split(target[query_start + 1:], "&") {
		equals := strings.index_byte(field, '=')
		if equals > 0 && field[:equals] == name {
			return field[equals + 1:]
		}
	}
	return ""
}

select_repository_file :: proc(history: ^History, repository: ^Repository, index: int, commit_hash := "", sidebar := "", partial := false) -> Http_Response {
	next_history, message, loaded := load_repository_history(repository, index)
	if !loaded {
		return {status = 500, reason = "Internal Server Error", content_type = "text/plain; charset=utf-8", body = strings.concatenate({message, "\n"})}
	}
	selected_commit := 0
	if len(commit_hash) > 0 {
		found := false
		for commit, commit_index in next_history.commits {
			if commit.full_hash == commit_hash || commit.short_hash == commit_hash {
				selected_commit = commit_index
				found = true
				break
			}
		}
		if !found { return not_found() }
	}
	render_message, rendered := render_history_snapshot(&next_history, selected_commit)
	if !rendered {
		return {status = 500, reason = "Internal Server Error", content_type = "text/plain; charset=utf-8", body = strings.concatenate({render_message, "\n"})}
	}
	history^ = next_history
	repository.selected_file = index
	if partial {
		return {status = 200, reason = "OK", content_type = "text/html; charset=utf-8", body = file_fragments(history, selected_commit)}
	}
	return {status = 200, reason = "OK", content_type = "text/html; charset=utf-8", body = initial_page(history, repository, selected_commit, sidebar)}
}

route_request :: proc(method, target: string, history: ^History, page: string, repository: ^Repository = nil) -> Http_Response {
	if method != "GET" {
		return {status = 405, reason = "Method Not Allowed", content_type = "text/plain; charset=utf-8", body = "method not allowed\n"}
	}
	path := target
	commit_hash := query_parameter(target, "commit")
	sidebar := query_parameter(target, "sidebar")
	partial := query_parameter(target, "partial") == "1"
	if query := strings.index_byte(path, '?'); query >= 0 {
		path = path[:query]
	}
	switch path {
	case "/":
		if repository != nil {
			return {status = 200, reason = "OK", content_type = "text/html; charset=utf-8", body = initial_page(history, repository, 0, sidebar)}
		}
		return {status = 200, reason = "OK", content_type = "text/html; charset=utf-8", body = page}
	case "/datastar.js":
		return {status = 200, reason = "OK", content_type = "text/javascript; charset=utf-8", body = string(DATSTAR_BUNDLE)}
	case "/style.css":
		return {status = 200, reason = "OK", content_type = "text/css; charset=utf-8", body = STYLESHEET}
	}
	file_prefix :: "/file/"
	if repository != nil && strings.has_prefix(path, file_prefix) {
		requested := path[len(file_prefix):]
		for _, index in repository.files {
			if requested == fmt.aprintf("%d", index) {
				return select_repository_file(history, repository, index, commit_hash, sidebar, partial)
			}
		}
		return not_found()
	}
	prefix :: "/snapshot/"
	if strings.has_prefix(path, prefix) {
		hash := path[len(prefix):]
		for &commit, index in history.commits {
			if commit.full_hash == hash {
				render_message, rendered := render_history_snapshot(history, index)
				if !rendered {
					return {status = 500, reason = "Internal Server Error", content_type = "text/plain; charset=utf-8", body = strings.concatenate({render_message, "\n"})}
				}
				return {
					status = 200,
					reason = "OK",
					content_type = "text/html; charset=utf-8",
					body = snapshot_fragments(history, index),
				}
			}
		}
	}
	if repository != nil && strings.has_prefix(path, "/") {
		relative_path, decoded := net.percent_decode(path[1:], context.temp_allocator)
		if decoded {
			for file, index in repository.files {
				if file == relative_path {
					return select_repository_file(history, repository, index, commit_hash, sidebar, partial)
				}
			}
		}
	}
	return not_found()
}

send_all :: proc(socket: net.TCP_Socket, data: string) -> bool {
	sent := 0
	bytes := transmute([]byte)data
	for sent < len(bytes) {
		n, err := net.send_tcp(socket, bytes[sent:])
		if err != nil || n <= 0 { return false }
		sent += n
	}
	return true
}

send_response :: proc(socket: net.TCP_Socket, response: Http_Response) {
	header := fmt.aprintf(
		"HTTP/1.1 %d %s\r\nContent-Type: %s\r\nContent-Length: %d\r\nConnection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nContent-Security-Policy: default-src 'self'; connect-src 'self'; img-src 'self' data:; script-src 'self' 'unsafe-eval'; style-src 'self' 'unsafe-inline'; base-uri 'none'; frame-ancestors 'none'\r\n\r\n",
		response.status, response.reason, response.content_type, len(response.body),
	)
	if send_all(socket, header) {
		_ = send_all(socket, response.body)
	}
}

Watch_Request :: struct {
	socket:    net.TCP_Socket,
	repo_root: string,
	path:      string,
}

watch_request_path :: proc(target: string, repository: ^Repository) -> (string, bool) {
	if repository == nil { return "", false }
	raw_path := query_parameter(target, "path")
	path, decoded := net.percent_decode(raw_path, context.temp_allocator)
	if !decoded { return "", false }
	for file in repository.files {
		if file == path { return file, true }
	}
	return "", false
}

missing_working_fragments :: proc() -> string {
	return strings.concatenate({
		`<article id="preview" class="markdown-body" aria-label="Markdown preview"><p>File is not available in the working tree.</p></article><section id="outline" class="outline" aria-label="Document outline" data-show="$sidebar === 'outline'">`,
		render_sidebar_search("outline"),
		`<ol></ol></section>`,
	})
}

render_working_fragments :: proc(markdown: string) -> (string, bool) {
	history := History{commits = make([dynamic]Commit, 0, 1)}
	defer delete(history.commits)
	append(&history.commits, Commit{markdown = markdown, working = true})
	_, rendered := render_history_snapshot(&history, 0)
	if !rendered { return "", false }
	return strings.concatenate({
		preview_fragment(&history.commits[0]),
		render_outline(&history.commits[0]),
	}), true
}

watch_file :: proc(request: Watch_Request) {
	defer net.close(request.socket)
	header := "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-store\r\nConnection: keep-alive\r\nX-Accel-Buffering: no\r\nX-Content-Type-Options: nosniff\r\n\r\n"
	if !send_all(request.socket, header) { return }
	absolute_path, path_err := filepath.join([]string{request.repo_root, request.path})
	if path_err != nil { return }
	previous := ""
	previous_exists := false
	defer if len(previous) > 0 { delete(previous) }
	checks := 0
	for server_running {
		contents, read_err := os.read_entire_file(absolute_path, context.allocator)
		if read_err == nil {
			markdown := string(contents)
			if !previous_exists || markdown != previous {
				fragments, rendered := render_working_fragments(markdown)
				if rendered && !send_all(request.socket, sse_patch_elements(fragments)) {
					delete(contents)
					return
				}
				if len(previous) > 0 { delete(previous) }
				previous = strings.clone(markdown)
				previous_exists = true
			}
			delete(contents)
		} else if previous_exists {
			if !send_all(request.socket, sse_patch_elements(missing_working_fragments())) { return }
			previous_exists = false
		}
		checks += 1
		if checks >= 60 {
			if !send_all(request.socket, ": keepalive\n\n") { return }
			checks = 0
		}
		time.sleep(250 * time.Millisecond)
	}
}

handle_connection :: proc(socket: net.TCP_Socket, history: ^History, page: string, repository: ^Repository = nil) -> bool {
	buffer: [16384]byte
	total := 0
	for total < len(buffer) {
		n, err := net.recv_tcp(socket, buffer[total:])
		if err != nil || n <= 0 { return true }
		total += n
		request := string(buffer[:total])
		if strings.contains(request, "\r\n\r\n") { break }
	}
	request := string(buffer[:total])
	line_end := strings.index(request, "\r\n")
	if line_end < 0 {
		send_response(socket, {status = 400, reason = "Bad Request", content_type = "text/plain; charset=utf-8", body = "bad request\n"})
		return true
	}
	parts := strings.split(request[:line_end], " ")
	if len(parts) != 3 || !strings.has_prefix(parts[2], "HTTP/1.") {
		send_response(socket, {status = 400, reason = "Bad Request", content_type = "text/plain; charset=utf-8", body = "bad request\n"})
		return true
	}
	if parts[0] == "GET" && strings.has_prefix(parts[1], "/watch?") {
		if path, valid := watch_request_path(parts[1], repository); valid {
			thread.run_with_poly_data(Watch_Request{socket = socket, repo_root = repository.repo_root, path = path}, watch_file)
			return false
		}
		send_response(socket, not_found())
		return true
	}
	send_response(socket, route_request(parts[0], parts[1], history, page, repository))
	return true
}

server_running: bool
server_listener: net.TCP_Socket = -1

repository_port :: proc(repo_root: string) -> int {
	hash: u64 = 14695981039346656037
	for byte in transmute([]byte)repo_root {
		hash ~= u64(byte)
		hash *= 1099511628211
	}
	return 20000 + int(hash % 20000)
}

interrupt_handler :: proc "c" (_: posix.Signal) {
	server_running = false
	if server_listener >= 0 {
		_ = posix.close(posix.FD(server_listener))
		server_listener = -1
	}
}

serve :: proc(history: ^History, open_browser := true, repository: ^Repository = nil) -> (string, bool) {
	port := 0
	if repository != nil {
		port = repository_port(repository.repo_root)
	}
	listener, listen_err := net.listen_tcp({net.IP4_Loopback, port})
	if listen_err != nil {
		if port > 0 {
			return fmt.aprintf("could not bind repository port %d", port), false
		}
		return "could not bind loopback server", false
	}
	server_listener = listener
	defer {
		if server_listener >= 0 {
			net.close(server_listener)
			server_listener = -1
		}
	}
	endpoint, endpoint_err := net.bound_endpoint(listener)
	if endpoint_err != nil {
		return "could not determine server port", false
	}
	server_url := fmt.aprintf("http://127.0.0.1:%d", endpoint.port)
	initial_url := strings.concatenate({server_url, "/"})
	if repository != nil {
		initial_url = strings.concatenate({server_url, repository_url(repository.files[repository.selected_file])})
	}
	fmt.println(initial_url)
	if open_browser {
		opened := run_command("", []string{"/usr/bin/open", initial_url})
		if !opened.ok {
			fmt.eprintln("warning: could not open browser; use the URL above")
		}
	}
	page := initial_page(history, repository)
	server_running = true
	_ = posix.signal(.SIGINT, interrupt_handler)
	for server_running {
		client, _, accept_err := net.accept_tcp(listener)
		if accept_err != nil {
			if !server_running { break }
			continue
		}
		if handle_connection(client, history, page, repository) {
			net.close(client)
		}
	}
	return "", true
}
