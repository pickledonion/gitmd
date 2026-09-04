package main

import "core:fmt"
import "core:os"
import "core:sync"
import "core:time"

gitmd_log_mutex: sync.Mutex
gitmd_log_file: ^os.File
gitmd_log_enabled: bool
gitmd_log_started: time.Tick

gitmd_log_init :: proc() {
	gitmd_log_started = time.tick_now()
	path := os.get_env("GITMD_LOG", context.temp_allocator)
	if len(path) == 0 {
		return
	}

	if path == "stderr" || path == "-" {
		gitmd_log_file = os.stderr
	} else {
		file, err := os.open(path, {.Write, .Append, .Create}, os.Permissions_Default_File)
		if err != nil {
			fmt.eprintln("gitmd: could not open GITMD_LOG")
			return
		}
		gitmd_log_file = file
	}
	gitmd_log_enabled = true
	gitmd_logf("log started target=%s", path)
}

gitmd_logf :: proc(format: string, args: ..any) {
	if !gitmd_log_enabled || gitmd_log_file == nil {
		return
	}

	message := fmt.aprintf(format, ..args)
	line := fmt.aprintf(
		"[+%dms] %s\n",
		i64(time.duration_milliseconds(time.tick_since(gitmd_log_started))),
		message,
	)
	sync.mutex_lock(&gitmd_log_mutex)
	_, err := os.write_string(gitmd_log_file, line)
	if err == nil {
		_ = os.flush(gitmd_log_file)
	}
	sync.mutex_unlock(&gitmd_log_mutex)
	delete(message)
	delete(line)
}
