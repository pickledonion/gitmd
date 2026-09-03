# gitmd

- Browse Markdown files in a local Git repository.
- Compare the working-tree file with its committed history.
- Render GitHub Flavored Markdown in a two-pane localhost view.

## Build locally on macOS

- Install the runtime/build dependencies with Homebrew:

```fish
brew install odin cmark-gfm
```

- Clean any previous build:

```fish
make clean
```

- Compile the app if needed, then run it:

```fish
make
```

- Run the existing build, compiling it first if needed:

```fish
make run
```

- Run the tests:

```fish
make test
```

## Optional Fish function

- Install an autoloaded Fish function to make `gitmd` available globally:

```fish
make fish
```

- The function compiles the app in the current `gitmd` checkout if needed,
  then runs that binary from your current directory.

## Use

- Serve the repository containing the current directory:

```fish
./build/gitmd
```

- Pass a repository directory or open a particular Markdown file:

```fish
./build/gitmd /path/to/repository
./build/gitmd docs/S00.01-worker.md
```

- After running `make fish`, use `gitmd` from any directory. Arguments are
  passed through to the app.

- Open the localhost URL printed by the CLI.
- Switch among Files, History, and Outline with `1`, `2`, and `3`.
  - Files lists tracked and untracked `.md` and `.markdown` files.
  - History lists the selected file's working tree and committed revisions.
  - Outline links to the selected file's headings.
- See working-tree changes, commits, and Markdown file-list changes update
  automatically, or click a commit to view its fixed snapshot.
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
- Watches repository state and the selected file with a server-sent event
  stream and uses Datastar to morph refreshed Files, History, `#preview`, and
  `#outline` fragments into the page.
- Pins and embeds Datastar v1.0.3 in the executable. Its license is stored in
  [`third_party/datastar/LICENSE.md`](third_party/datastar/LICENSE.md).
- Never checks out a revision or writes to the repository.
- Reads only the listed Markdown files from the working tree.
- Has no CDN, telemetry, account, cloud service, or runtime network dependency.
- Serves GET requests only over the local loopback interface.

## License

- Available under the [MIT License](LICENSE).
