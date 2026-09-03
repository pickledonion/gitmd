# gitmd

`gitmd` is a small, read-only browser for Markdown files in a local Git
repository. It shows the working-tree file alongside its committed history,
renders GitHub Flavored Markdown, and opens a two-pane localhost view.

## Install on macOS

Install the two runtime/build dependencies with Homebrew:

```fish
brew install odin cmark-gfm
make test
```

Define an autoloaded Fish function instead of adding `~/.local/bin` to `PATH`.
Use the absolute path to your `gitmd` checkout:

```fish
function gitmd
    make -C /absolute/path/to/gitmd install
    or return
    command ~/.local/bin/gitmd $argv
end
funcsave gitmd
```

The function rebuilds and installs `gitmd` before every launch. `make install`
uses `~/.local/bin` by default; set `PREFIX` when invoking `make` to choose
another installation directory.

## Use

Serve the repository containing the current directory:

```fish
gitmd
```

You can also pass a repository directory or open a particular Markdown file:

```fish
gitmd /path/to/repository
gitmd docs/S00.01-worker.md
```

The CLI prints the localhost URL to open. The sidebar switches between a flat
list of tracked and untracked `.md`/`.markdown` files, the selected file's
working tree and committed history, and a linked outline of its headings. Use
`1`, `2`, and `3` to select those tabs. The working-tree preview updates
automatically when the displayed file changes on disk; click a commit to view
its fixed snapshot. Use `←`/`h` and `→`/`l` to select the sidebar or document
pane. In the sidebar, `↑`/`k` and `↓`/`j` move through the active list; in the
document pane they scroll the text. Press `/` to fuzzy-filter the active
sidebar list as you type; Files, History, and Outline each retain their own
query and whether their filter is open. Press `Esc` to clear and close the
active search. Modifier shortcuts are ignored except for `⌘B`, which toggles
the sidebar, so normal selection and copy shortcuts continue to work. Drag the
divider to resize the sidebar, or focus it and use the arrow keys. Stop the
server with `Ctrl+C`.

## How it works

The CLI lists tracked and untracked Markdown files with `git ls-files` and
follows a selected file's committed renames with `git log`. It renders the
working-tree file directly and loads older snapshots on demand with
`git ls-tree`, `git cat-file`, and Homebrew's `cmark-gfm` libraries. A minimal
Odin `core:net` HTTP server binds on `127.0.0.1`; the repository path determines
a stable localhost port, allowing multiple repositories to be served at the
same time with repeatable URLs. While the working-tree entry is selected, a
server-sent event stream watches the file and Datastar morphs refreshed
`#preview` and `#outline` fragments into the page.

Datastar v1.0.3 is pinned and embedded in the executable; its license is kept
in [`third_party/datastar/LICENSE.md`](third_party/datastar/LICENSE.md).

`gitmd` never checks out a revision or writes to the repository. It reads only
the listed Markdown files from the working tree. The page has no CDN,
telemetry, account, cloud service, or runtime network dependency. The server is
GET-only and reachable only over the local loopback interface.

## License

`gitmd` is available under the [MIT License](LICENSE).
