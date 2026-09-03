# gitmd

`gitmd` is a small, read-only browser for Markdown files and their committed
history in a local Git repository. It reads snapshots directly from local Git
objects, renders GitHub Flavored Markdown, and opens a two-pane localhost view.

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

The browser opens automatically. The sidebar switches between a flat list of
committed `.md`/`.markdown` files, the selected file's history, and a linked
outline of its headings. Use `1`, `2`, and `3` to select those tabs. Click a
commit to view it. Use `←`/`h` and `→`/`l` to select the sidebar or document
pane. In the sidebar, `↑`/`k` and `↓`/`j` move through the active list; in the
document pane they scroll the text. Press `/` to fuzzy-filter the active sidebar list
as you type, and `Esc` to cancel the search. Modifier shortcuts are ignored
except for `⌘B`, which toggles the sidebar, so normal selection and copy
shortcuts continue to work. Drag the divider to resize the sidebar, or focus it
and use the arrow keys. Stop the server with `Ctrl+C`.

## How it works

The CLI lists Markdown files from the committed `HEAD` tree and follows a
selected file's committed renames with `git log`. It resolves and renders only
the visible snapshot, loading older snapshots on demand with `git ls-tree`,
`git cat-file`, and Homebrew's `cmark-gfm` libraries. A minimal Odin
`core:net` HTTP server binds an ephemeral port on `127.0.0.1`. Datastar
morphs cached server-rendered `#preview` HTML fragments when the selected
commit changes.

Datastar v1.0.3 is pinned and embedded in the executable; its license is kept
in [`third_party/datastar/LICENSE.md`](third_party/datastar/LICENSE.md).

`gitmd` never checks out a revision, writes to the repository, or reads file
contents from the working tree. The page has no CDN, telemetry, account, cloud
service, or runtime network dependency. The server is GET-only and reachable
only over the local loopback interface.
