package main

import "core:encoding/json"
import "core:os"
import "core:strings"
import "core:testing"

@(test)
find_targets_use_rendered_definitions :: proc(t: ^testing.T) {
	api, message, loaded := load_cmark()
	if !testing.expectf(t, loaded, "%s", message) { return }
	html, rendered := render_markdown(&api, "# Task *T-01*\n\n# Task *T-01*\n\n<a id=\"spec & detail\"></a>\n\n```md\n# Example only\n<a id=\"fake\"></a>\n```\n\n`<a id=\"inline-fake\"></a>`\n")
	if !testing.expect(t, rendered) { return }
	targets := make([dynamic]Find_Target)
	append_find_targets(&targets, "docs/a #guide.md", html)
	if !testing.expect_value(t, len(targets), 3) { return }
	testing.expect_value(t, targets[0].label, "Task T-01")
	testing.expect_value(t, targets[0].id, "task-t-01")
	testing.expect_value(t, targets[1].id, "task-t-01-1")
	testing.expect_value(t, targets[2].id, "spec & detail")
	testing.expect_value(t, targets[2].url, "/docs/a%20%23guide.md#spec%20%26%20detail")
}

@(test)
repository_find_reads_current_markdown_without_changing_selection :: proc(t: ^testing.T) {
	root, path := make_fixture(t)
	defer os.remove_all(root)
	repository, _, loaded := load_repository(path)
	if !testing.expect(t, loaded) { return }
	selected := repository.selected_file
	must_write(t, path, "# Edited task T-42\n")
	must_write(t, test_path(root, "untracked.markdown"), "# Spec S-99\n")
	must_write(t, test_path(root, ".gitignore"), "ignored.md\n")
	must_write(t, test_path(root, "ignored.md"), "# Ignored\n")
	must_write(t, test_path(root, "plain.txt"), "# Not Markdown\n")
	history := History{}
	response := route_request("GET", "/find", &history, "", &repository)
	if !testing.expect_value(t, response.status, 200) { return }
	defer delete(response.body)
	index: Find_Index
	if !testing.expect_value(t, json.unmarshal(transmute([]byte)response.body, &index), nil) { return }
	testing.expect_value(t, len(index.targets), 2)
	testing.expect_value(t, index.skipped, 0)
	testing.expect(t, strings.contains(response.body, "Edited task T-42"))
	testing.expect(t, strings.contains(response.body, "Spec S-99"))
	testing.expect(t, !strings.contains(response.body, "Ignored"))
	testing.expect(t, !strings.contains(response.body, "Not Markdown"))
	testing.expect_value(t, repository.selected_file, selected)
	testing.expect_value(t, len(repository.files), 1)
	testing.expect_value(t, len(history.commits), 0)
	_ = os.remove(test_path(root, "untracked.markdown"))
	updated := repository_find_response(&repository)
	defer delete(updated.body)
	testing.expect(t, !strings.contains(updated.body, "Spec S-99"))
	testing.expect_value(t, route_request("POST", "/find", &history, "", &repository).status, 405)
	testing.expect_value(t, route_request("GET", "/find", &history, "").status, 404)
	testing.expect_value(t, route_request("GET", "/find.js", &history, "").body, string(FIND_SCRIPT))
	_ = os.remove(path)
	empty := repository_find_response(&repository)
	defer delete(empty.body)
	testing.expect_value(t, empty.status, 200)
	testing.expect(t, strings.contains(empty.body, `"targets":[]`))
}
