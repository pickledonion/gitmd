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
			refreshed, _, loaded := load_repository(repository.repo_root)
			if loaded { repository^ = refreshed }
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
	socket:      net.TCP_Socket,
	repo_root:   string,
	path:        string,
	commit_hash: string,
	comparison: ^Watch_Comparison,
}

Watch_Comparison :: struct {
	baseline: Commit,
	ready: bool,
	label: string,
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
		comparison_label_fragment(&Commit{comparison_label = "Comparison unavailable · deletions hidden"}),
		`<article id="preview" class="markdown-body" aria-label="Markdown preview"><p>File is not available in the working tree.</p></article><section id="outline" class="outline" aria-label="Document outline" data-show="$sidebar === 'outline'">`,
		render_sidebar_search("outline"),
		`<ol></ol></section>`,
	})
}

render_working_fragments :: proc(markdown: string, request: ^Watch_Request = nil) -> (string, bool) {
	history := History{commits = make([dynamic]Commit, 0, 1)}
	defer delete(history.commits)
	append(&history.commits, Commit{markdown = markdown, working = true})
	_, rendered := render_history_snapshot(&history, 0)
	if !rendered { return "", false }
	if request != nil {
		if request.comparison == nil { request.comparison = new(Watch_Comparison) }
		if !request.comparison.ready {
			// Normally initialized by the first repository update in the stream.
			_, _ = render_watch_fragments(request)
		}
		if request.comparison.ready {
			baseline := &request.comparison.baseline
			if len(baseline.full_hash) > 0 && markdown == baseline.markdown {
				// Reverting live edits returns to the latest commit's comparison.
				// Its older baseline is loaded only when this view is needed.
				if len(baseline.comparison_label) == 0 {
					return render_watch_fragments(request)
				}
				history.commits[0].comparison_html = baseline.comparison_html
				history.commits[0].comparison_label = baseline.comparison_label
			} else {
				label := request.comparison.label
				if len(baseline.full_hash) > 0 {
					label = fmt.aprintf("Compared with %s · deletions hidden", baseline.short_hash)
				}
				compare_snapshot(&history.commits[0], baseline, label)
			}
		} else {
			history.commits[0].comparison_html = history.commits[0].html
			history.commits[0].comparison_label = "Comparison unavailable · deletions hidden"
		}
	}
	return strings.concatenate({
		preview_fragment(&history.commits[0]),
		render_outline(&history.commits[0]),
		comparison_label_fragment(&history.commits[0]),
	}), true
}

WATCH_POLL_INTERVAL :: 250 * time.Millisecond
WATCH_REPOSITORY_INTERVAL :: 1 * time.Second
WATCH_QUIET_PERIOD :: 200 * time.Millisecond
WATCH_MAX_UPDATE_DELAY :: 1 * time.Second
WATCH_KEEPALIVE_INTERVAL :: 15 * time.Second

Repository_Watch_State :: struct {
	files: string,
	head:  string,
}

repository_watch_state :: proc(repo_root: string) -> (Repository_Watch_State, bool) {
	files_result := run_command(repo_root, []string{
		"/usr/bin/git", "ls-files", "--cached", "--others", "--exclude-standard", "-z",
	})
	if !files_result.ok {
		gitmd_logf("watch repository files failed repo=%s", repo_root)
		return {}, false
	}

	head_result := run_command(repo_root, []string{"/usr/bin/git", "rev-parse", "--verify", "HEAD"})
	head := ""
	if head_result.ok {
		head = strings.clone(trim_command_output(head_result.stdout))
	} else {
		gitmd_logf("watch repository has no readable HEAD repo=%s", repo_root)
	}
	return Repository_Watch_State{files = files_result.stdout, head = head}, true
}

render_watch_fragments :: proc(request: ^Watch_Request) -> (string, bool) {
	if request.comparison == nil { request.comparison = new(Watch_Comparison) }
	request.comparison.ready = false
	repository, _, loaded_repository := load_repository(request.repo_root)
	if !loaded_repository { return "", false }
	repository.selected_file = -1
	for file, index in repository.files {
		if file == request.path {
			repository.selected_file = index
			break
		}
	}
	history, _, loaded_history := load_history_snapshots(request.repo_root, request.path)
	if !loaded_history { return "", false }
	selected_commit := -1
	for commit, index in history.commits {
		if commit.full_hash == request.commit_hash || commit.short_hash == request.commit_hash {
			selected_commit = index
			break
		}
	}
	if selected_commit < 0 && request.commit_hash != "working" {
		for commit, index in history.commits {
			if commit.working {
				selected_commit = index
				break
			}
		}
	}
	if selected_commit < 0 {
		return strings.concatenate({
			render_files(&repository),
			render_history(&history, -1),
			missing_working_fragments(),
		}), true
	}
	_, rendered := render_history_snapshot(&history, selected_commit)
	if !rendered { return "", false }
	if history.commits[selected_commit].working {
		request.comparison.label = history.commits[selected_commit].comparison_label
		request.comparison.baseline = {}
		if selected_commit + 1 < len(history.commits) {
			request.comparison.baseline = history.commits[selected_commit + 1]
		}
		request.comparison.ready = !strings.has_prefix(request.comparison.label, "Comparison unavailable")
	}
	return strings.concatenate({
		render_files(&repository),
		render_history(&history, selected_commit),
		preview_fragment(&history.commits[selected_commit]),
		render_outline(&history.commits[selected_commit]),
		comparison_label_fragment(&history.commits[selected_commit]),
	}), true
}

Watch_Changes :: struct {
	contents: bool,
	files:    bool,
	head:     bool,
}

Watch_Pending :: struct {
	changes:       Watch_Changes,
	first_change:  time.Tick,
	last_change:   time.Tick,
	observations:  int,
	dirty:         bool,
}

mark_watch_change :: proc(pending: ^Watch_Pending, now: time.Tick, changes: Watch_Changes) {
	if !pending.dirty {
		pending.first_change = now
	}
	pending.last_change = now
	pending.observations += 1
	pending.dirty = true
	pending.changes.contents = pending.changes.contents || changes.contents
	pending.changes.files = pending.changes.files || changes.files
	pending.changes.head = pending.changes.head || changes.head
}

render_watch_update :: proc(request: ^Watch_Request, changes: Watch_Changes, markdown: string, exists: bool) -> (fragments: string, rendered: bool, kind: string) {
	if changes.head {
		fragments, rendered = render_watch_fragments(request)
		return fragments, rendered, "repository"
	}

	if changes.files {
		repository, _, loaded := load_repository(request.repo_root)
		if !loaded {
			return "", false, "files-error"
		}
		selected := -1
		for file, index in repository.files {
			if file == request.path {
				selected = index
				break
			}
		}
		if selected < 0 {
			fragments, rendered = render_watch_fragments(request)
			return fragments, rendered, "repository"
		}
		repository.selected_file = selected
		files := render_files(&repository)
		if request.commit_hash == "working" && changes.contents {
			if exists {
				working, working_rendered := render_working_fragments(markdown, request)
				if !working_rendered { return "", false, "files+working-error" }
				return strings.concatenate({files, working}), true, "files+working"
			}
			return strings.concatenate({files, missing_working_fragments()}), true, "files+missing"
		}
		return files, true, "files"
	}

	if changes.contents && request.commit_hash == "working" {
		if exists {
			working, working_rendered := render_working_fragments(markdown, request)
			return working, working_rendered, "working"
		}
		return missing_working_fragments(), true, "missing"
	}

	return "", true, "fixed-snapshot"
}

watch_file :: proc(request: Watch_Request) {
	defer net.close(request.socket)
	gitmd_logf("watch start repo=%s path=%s commit=%s", request.repo_root, request.path, request.commit_hash)
	defer gitmd_logf("watch stop repo=%s path=%s commit=%s", request.repo_root, request.path, request.commit_hash)
	header := "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-store\r\nConnection: keep-alive\r\nX-Accel-Buffering: no\r\nX-Content-Type-Options: nosniff\r\n\r\n"
	if !send_all(request.socket, header) {
		gitmd_logf("watch header send failed path=%s", request.path)
		return
	}
	active_request := request
	if len(active_request.commit_hash) == 0 { active_request.commit_hash = "working" }
	absolute_path, path_err := filepath.join([]string{active_request.repo_root, active_request.path})
	if path_err != nil {
		gitmd_logf("watch path join failed repo=%s path=%s", active_request.repo_root, active_request.path)
		return
	}
	previous_contents := ""
	previous_exists := false
	previous_files := ""
	previous_head := ""
	repository_state_initialized := false
	defer {
		if len(previous_contents) > 0 { delete(previous_contents) }
		if len(previous_files) > 0 { delete(previous_files) }
		if len(previous_head) > 0 { delete(previous_head) }
	}
	last_repository_check: time.Tick
	repository_checked := false
	last_keepalive := time.tick_now()
	pending: Watch_Pending
	for server_running {
		now := time.tick_now()
		state_checked := !repository_checked || time.tick_diff(last_repository_check, now) >= WATCH_REPOSITORY_INTERVAL
		if state_checked {
			state, state_loaded := repository_watch_state(active_request.repo_root)
			if state_loaded {
				files_changed := !repository_state_initialized || state.files != previous_files
				head_changed := !repository_state_initialized || state.head != previous_head
				if files_changed || head_changed {
					mark_watch_change(&pending, now, Watch_Changes{files = files_changed, head = head_changed})
					gitmd_logf(
						"watch change observed path=%s contents=false files=%t head=%t",
						active_request.path, files_changed, head_changed,
					)
				}
				if len(previous_files) > 0 { delete(previous_files) }
				previous_files = strings.clone(state.files)
				if len(previous_head) > 0 { delete(previous_head) }
				previous_head = strings.clone(state.head)
				repository_state_initialized = true
			}
			last_repository_check = now
			repository_checked = true
		}
		contents, read_err := os.read_entire_file(absolute_path, context.allocator)
		exists := read_err == nil
		markdown := ""
		if exists { markdown = string(contents) }
		contents_changed := exists != previous_exists || exists && markdown != previous_contents
		if contents_changed {
			mark_watch_change(&pending, now, Watch_Changes{contents = true})
			gitmd_logf("watch change observed path=%s contents=true files=false head=false", active_request.path)
			if len(previous_contents) > 0 { delete(previous_contents) }
			previous_contents = strings.clone(markdown)
			previous_exists = exists
		}

		if pending.dirty {
			quiet_for := time.tick_diff(pending.last_change, now)
			pending_for := time.tick_diff(pending.first_change, now)
			if quiet_for >= WATCH_QUIET_PERIOD || pending_for >= WATCH_MAX_UPDATE_DELAY {
				changes := pending.changes
				observations := pending.observations
				pending = {}
				gitmd_logf(
					"watch update flush path=%s contents=%t files=%t head=%t observations=%d quiet_ms=%d age_ms=%d",
					active_request.path,
					changes.contents, changes.files, changes.head, observations,
					i64(time.duration_milliseconds(quiet_for)),
					i64(time.duration_milliseconds(pending_for)),
				)
				render_started := time.tick_now()
				fragments, rendered, kind := render_watch_update(&active_request, changes, markdown, exists)
				render_elapsed := time.duration_milliseconds(time.tick_diff(render_started, time.tick_now()))
				if rendered && len(fragments) > 0 {
					payload := sse_patch_elements(fragments)
					gitmd_logf(
						"watch update rendered path=%s kind=%s render_ms=%d bytes=%d",
						active_request.path, kind, i64(render_elapsed), len(payload),
					)
					send_started := time.tick_now()
					sent := send_all(request.socket, payload)
					gitmd_logf(
						"watch update sent path=%s kind=%s send_ms=%d ok=%t",
						active_request.path, kind,
						i64(time.duration_milliseconds(time.tick_diff(send_started, time.tick_now()))), sent,
					)
					if !sent {
						if exists { delete(contents) }
						return
					}
				} else {
					gitmd_logf("watch update skipped path=%s kind=%s render_ms=%d", active_request.path, kind, i64(render_elapsed))
				}
			}
		}
		if exists { delete(contents) }
		if time.tick_diff(last_keepalive, now) >= WATCH_KEEPALIVE_INTERVAL {
			if !send_all(request.socket, ": keepalive\n\n") {
				gitmd_logf("watch keepalive send failed path=%s", active_request.path)
				return
			}
			gitmd_logf("watch keepalive path=%s", active_request.path)
			last_keepalive = now
		}
		time.sleep(WATCH_POLL_INTERVAL)
	}
}

handle_connection :: proc(socket: net.TCP_Socket, history: ^History, page: string, repository: ^Repository = nil) -> bool {
	connection_started := time.tick_now()
	gitmd_logf("http connection start")
	buffer: [16384]byte
	total := 0
	for total < len(buffer) {
		n, err := net.recv_tcp(socket, buffer[total:])
		if err != nil || n <= 0 {
			gitmd_logf(
				"http connection ended before headers elapsed_ms=%d",
				i64(time.duration_milliseconds(time.tick_diff(connection_started, time.tick_now()))),
			)
			return true
		}
		total += n
		request := string(buffer[:total])
		if strings.contains(request, "\r\n\r\n") { break }
	}
	request := string(buffer[:total])
	line_end := strings.index(request, "\r\n")
	if line_end < 0 {
		gitmd_logf("http bad request missing request line")
		send_response(socket, {status = 400, reason = "Bad Request", content_type = "text/plain; charset=utf-8", body = "bad request\n"})
		return true
	}
	parts := strings.split(request[:line_end], " ")
	if len(parts) != 3 || !strings.has_prefix(parts[2], "HTTP/1.") {
		gitmd_logf("http bad request malformed request line")
		send_response(socket, {status = 400, reason = "Bad Request", content_type = "text/plain; charset=utf-8", body = "bad request\n"})
		return true
	}
	gitmd_logf("http request method=%s target=%s", parts[0], parts[1])
	if parts[0] == "GET" && strings.has_prefix(parts[1], "/watch?") {
		if path, valid := watch_request_path(parts[1], repository); valid {
			commit_hash, decoded := net.percent_decode(query_parameter(parts[1], "commit"), context.temp_allocator)
			if !decoded { commit_hash = "working" }
			gitmd_logf("http watch dispatch path=%s commit=%s", path, commit_hash)
			thread.run_with_poly_data(Watch_Request{socket = socket, repo_root = repository.repo_root, path = path, commit_hash = strings.clone(commit_hash)}, watch_file)
			return false
		}
		gitmd_logf("http watch not found target=%s", parts[1])
		send_response(socket, not_found())
		return true
	}
	route_started := time.tick_now()
	response := route_request(parts[0], parts[1], history, page, repository)
	gitmd_logf(
		"http response ready target=%s status=%d bytes=%d route_ms=%d",
		parts[1], response.status, len(response.body),
		i64(time.duration_milliseconds(time.tick_diff(route_started, time.tick_now()))),
	)
	send_started := time.tick_now()
	send_response(socket, response)
	gitmd_logf(
		"http response sent target=%s send_ms=%d total_ms=%d",
		parts[1],
		i64(time.duration_milliseconds(time.tick_diff(send_started, time.tick_now()))),
		i64(time.duration_milliseconds(time.tick_diff(connection_started, time.tick_now()))),
	)
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

listen_with_fallback :: proc(port: int) -> (net.TCP_Socket, net.Network_Error) {
	listener, listen_err := net.listen_tcp({net.IP4_Loopback, port})
	if listen_err != nil && port > 0 {
		return net.listen_tcp({net.IP4_Loopback, 0})
	}
	return listener, listen_err
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
	listener, listen_err := listen_with_fallback(port)
	if listen_err != nil {
		gitmd_logf("server listen failed repo=%s", history.repo_root)
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
		gitmd_logf("server endpoint lookup failed")
		return "could not determine server port", false
	}
	server_url := fmt.aprintf("http://127.0.0.1:%d", endpoint.port)
	initial_url := strings.concatenate({server_url, "/"})
	if repository != nil {
		initial_url = strings.concatenate({server_url, repository_url(repository.files[repository.selected_file])})
	}
	gitmd_logf("server start url=%s repo=%s", initial_url, history.repo_root)
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
	gitmd_logf("server stop")
	return "", true
}
