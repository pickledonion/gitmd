package main

import "core:os"
import "core:strings"
import "core:testing"

@(test)
repository_omits_unstaged_deleted_and_renamed_paths :: proc(t: ^testing.T) {
	root, path := make_fixture(t)
	defer os.remove_all(root)
	deleted := test_path(root, "deleted.md")
	must_write(t, deleted, "# Deleted\n")
	must_git(t, root, []string{"add", "--", "deleted.md"})
	must_git(t, root, []string{"commit", "-q", "-m", "add deleted fixture"})
	before, before_ok := repository_watch_state(root)
	testing.expect(t, before_ok)
	if !testing.expect_value(t, os.remove(deleted), nil) { return }
	after_delete, delete_ok := repository_watch_state(root)
	testing.expect(t, delete_ok)
	testing.expect(t, before.files != after_delete.files)
	testing.expect_value(t, before.head, after_delete.head)

	renamed := test_path(root, "docs with spaces/renamed.md")
	if !testing.expect_value(t, os.rename(path, renamed), nil) { return }
	repository, message, loaded := load_repository(renamed)
	if !testing.expectf(t, loaded, "load_repository failed: %s", message) { return }
	if !testing.expect_value(t, len(repository.files), 1) { return }
	testing.expect_value(t, repository.files[repository.selected_file], "docs with spaces/renamed.md")
	_, _, old_loaded := load_repository(path)
	testing.expect(t, !old_loaded)
	after_rename, rename_ok := repository_watch_state(root)
	testing.expect(t, rename_ok)
	testing.expect(t, after_rename.files != after_delete.files)
	testing.expect_value(t, before.head, after_rename.head)

	request := Watch_Request{repo_root = root, path = "docs with spaces/new name.md", commit_hash = "working"}
	fragments, rendered, _ := render_watch_update(&request, Watch_Changes{files = true, contents = true}, "", false)
	testing.expect(t, rendered)
	testing.expect(t, strings.contains(fragments, `data-path="docs with spaces/renamed.md"`))
	testing.expect(t, !strings.contains(fragments, `data-path="docs with spaces/new name.md"`))
	testing.expect(t, !strings.contains(fragments, `data-path="deleted.md"`))
	testing.expect(t, strings.contains(fragments, "File is not available in the working tree."))

	must_git(t, root, []string{"add", "-A"})
	after_stage, stage_ok := repository_watch_state(root)
	testing.expect(t, stage_ok)
	testing.expect_value(t, after_stage.files, after_rename.files)
	must_write(t, deleted, "# Restored\n")
	after_restore, restore_ok := repository_watch_state(root)
	testing.expect(t, restore_ok)
	testing.expect(t, after_restore.files != after_stage.files)
	testing.expect(t, strings.contains(after_restore.files, "deleted.md"))
}

@(test)
watch_removes_last_markdown_file :: proc(t: ^testing.T) {
	root, path := make_fixture(t)
	defer os.remove_all(root)
	if !testing.expect_value(t, os.remove(path), nil) { return }
	request := Watch_Request{repo_root = root, path = "docs with spaces/new name.md", commit_hash = "working"}
	fragments, rendered, _ := render_watch_update(&request, Watch_Changes{files = true, contents = true}, "", false)
	testing.expect(t, rendered)
	testing.expect(t, strings.contains(fragments, `id="files"`))
	testing.expect(t, !strings.contains(fragments, `data-path=`))
	testing.expect(t, strings.contains(fragments, "File is not available in the working tree."))
	_, _, loaded := load_repository(root)
	testing.expect(t, !loaded)

	// A selected untracked file has no history to load after it disappears.
	must_write(t, test_path(root, "untracked.md"), "# Untracked\n")
	request.path = "untracked.md"
	if !testing.expect_value(t, os.remove(test_path(root, "untracked.md")), nil) { return }
	untracked, untracked_rendered, _ := render_watch_update(&request, Watch_Changes{files = true, contents = true}, "", false)
	testing.expect(t, untracked_rendered)
	testing.expect(t, strings.contains(untracked, `id="files"`))
	testing.expect(t, !strings.contains(untracked, `data-path=`))
	testing.expect(t, strings.contains(untracked, "File is not available in the working tree."))
}
