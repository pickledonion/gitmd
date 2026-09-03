package main

import "core:fmt"
import "core:os"

main :: proc() {
	args := os.args
	if len(args) > 2 {
		fmt.eprintln("usage: gitmd [repository-or-markdown-path]")
		os.exit(2)
	}
	target := "."
	if len(args) == 2 { target = args[1] }
	repository, message, loaded := load_repository(target)
	if !loaded {
		fmt.eprintf("gitmd: %s\n", message)
		os.exit(1)
	}
	history, history_message, history_loaded := load_repository_history(&repository, repository.selected_file)
	if !history_loaded {
		fmt.eprintf("gitmd: %s\n", history_message)
		os.exit(1)
	}
	render_message, rendered := render_history_snapshot(&history, 0)
	if !rendered {
		fmt.eprintf("gitmd: %s\n", render_message)
		os.exit(1)
	}
	serve_message, served := serve(&history, true, &repository)
	if !served {
		fmt.eprintf("gitmd: %s\n", serve_message)
		os.exit(1)
	}
}
