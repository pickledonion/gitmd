package main

import "core:fmt"
import "core:os"

main :: proc() {
	gitmd_log_init()
	args := os.args
	if len(args) > 2 {
		gitmd_logf("startup rejected argument_count=%d", len(args) - 1)
		fmt.eprintln("usage: gitmd [repository-or-markdown-path]")
		os.exit(2)
	}
	target := "."
	if len(args) == 2 { target = args[1] }
	gitmd_logf("startup target=%s", target)
	repository, message, loaded := load_repository(target)
	if !loaded {
		gitmd_logf("startup repository load failed target=%s message=%s", target, message)
		fmt.eprintf("gitmd: %s\n", message)
		os.exit(1)
	}
	history, history_message, history_loaded := load_repository_history(&repository, repository.selected_file)
	if !history_loaded {
		gitmd_logf("startup history load failed path=%s message=%s", repository.files[repository.selected_file], history_message)
		fmt.eprintf("gitmd: %s\n", history_message)
		os.exit(1)
	}
	render_message, rendered := render_history_snapshot(&history, 0)
	if !rendered {
		gitmd_logf("startup render failed path=%s message=%s", history.path, render_message)
		fmt.eprintf("gitmd: %s\n", render_message)
		os.exit(1)
	}
	gitmd_logf("startup ready repo=%s path=%s files=%d history=%d", repository.repo_root, history.path, len(repository.files), len(history.commits))
	serve_message, served := serve(&history, false, &repository)
	if !served {
		gitmd_logf("server failed message=%s", serve_message)
		fmt.eprintf("gitmd: %s\n", serve_message)
		os.exit(1)
	}
}
