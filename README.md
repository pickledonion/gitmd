# gitmd

- Browse Markdown files in a local Git repository.
- Compare the working-tree file with its committed history.
- Render GitHub Flavored Markdown in a two-pane localhost view.

## Install on macOS

- Install the runtime/build dependencies with Homebrew:

```fish
brew install odin cmark-gfm
make test
```

- Define an autoloaded Fish function instead of adding `~/.local/bin` to
  `PATH`. Use the absolute path to your `gitmd` checkout:

```fish
function gitmd
    make -C /absolute/path/to/gitmd install
    or return
    command ~/.local/bin/gitmd $argv
end
funcsave gitmd
```

- The function rebuilds and installs `gitmd` before every launch.
- `make install` uses `~/.local/bin` by default. Set `PREFIX` when invoking
  `make` to choose another installation directory.

## Use

- Serve the repository containing the current directory:

```fish
gitmd
```

- Pass a repository directory or open a particular Markdown file:

```fish
gitmd /path/to/repository
gitmd docs/S00.01-worker.md
```

- Open the localhost URL printed by the CLI.
- Switch among Files, History, and Outline with `1`, `2`, and `3`.
  - Files lists tracked and untracked `.md` and `.markdown` files.
  - History lists the selected file's working tree and committed revisions.
  - Outline links to the selected file's headings.
- See working-tree changes update automatically, or click a commit to view its
  fixed snapshot.
- Select the sidebar or document pane with `←`/`h` and `→`/`l`.
- In the sidebar, move through the active list with `↑`/`k` and `↓`/`j`.
- In the document pane, scroll with `↑`/`k` and `↓`/`j`.
- Press `/` to fuzzy-filter the active sidebar list as you type. Files,
  History, and Outline each retain their own query and open state.
- Press `Esc` to clear and close the active search.
- Press `⌘B` to toggle the sidebar. Other modifier shortcuts are ignored so
  normal selection and copy shortcuts continue to work.
- Resize the sidebar by dragging the divider or focusing it and using the
  arrow keys.
- Stop the server with `Ctrl+C`.

## How it works

- Lists tracked and untracked Markdown files with `git ls-files`.
- Follows a selected file's committed renames with `git log`.
- Renders the working-tree file directly.
- Loads older snapshots on demand with `git ls-tree`, `git cat-file`, and
  Homebrew's `cmark-gfm` libraries.
- Runs a minimal Odin `core:net` HTTP server on `127.0.0.1`.
- Derives a stable localhost port from the repository path, allowing multiple
  repositories to use repeatable URLs at the same time.
- Watches the selected working-tree file with a server-sent event stream and
  uses Datastar to morph refreshed `#preview` and `#outline` fragments into the
  page.
- Pins and embeds Datastar v1.0.3 in the executable. Its license is stored in
  [`third_party/datastar/LICENSE.md`](third_party/datastar/LICENSE.md).
- Never checks out a revision or writes to the repository.
- Reads only the listed Markdown files from the working tree.
- Has no CDN, telemetry, account, cloud service, or runtime network dependency.
- Serves GET requests only over the local loopback interface.

## License

- Available under the [MIT License](LICENSE).
