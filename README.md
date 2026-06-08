# slds-tools Docker images

This repository builds the project's container images. Today that is a single
image — **yolobox** — a data-science / dev sandbox layered on top of the upstream
[`ghcr.io/finbarr/yolobox`](https://github.com/finbarr/yolobox) base.

## Layout

```
.
├── CLAUDE.md              # rules
├── README.md              # this file
├── .github/workflows/     # CI: docker-yolobox.yml (multi-arch build + push)
└── yolobox/
    ├── Dockerfile         # the image definition
    ├── install_packages.R # R package set + PPM date pin (run from the Dockerfile)
    ├── claude-launch-shim.sh  # live session/memory bridge wrapper for Claude Code
    ├── gitconfig          # system-wide git config (delta pager) → /etc/gitconfig
    ├── zshrc              # interactive shell config → /etc/zsh/zshrc.d/10-slds.zsh
    ├── zsh_aliases        # aliases sourced by zshrc → /etc/zsh/zsh_aliases
    └── starship-extra.toml  # prompt overrides, merged with the base preset → /etc/starship.toml
```

## Base image and user model

- Built **`FROM ghcr.io/finbarr/yolobox:latest`**, which already ships a baseline
  of dev tooling (bat, fd, fzf, gh, git, jq, nodejs/npm, ripgrep, vim, …). 
- The build runs as **`root`** (apt / pip / R installs); the final image restores
  the unprivileged **`yolo`** user so containers drop privileges by default.

## Building (autobuilt in CI)

You normally don't build this image by hand — it is built and published by
GitHub Actions in [`.github/workflows/docker-yolobox.yml`](.github/workflows/docker-yolobox.yml).
The workflow builds a **multi-arch** image (`linux/amd64` + `linux/arm64`) on
native runners (no QEMU) and pushes it to
**`ghcr.io/slds-lmu/slds-yolobox`**.

**Two-job pattern:** a matrix `build` job builds each architecture on its matching
native runner and pushes it *by digest only*; a `merge` job then stitches those
digests into one multi-arch manifest under the human-readable tags.

**Triggers:**

| event | what happens |
|-------|--------------|
| push to `main` touching `yolobox/**` or the workflow | build **+ push** |
| pull request to `main` (same path filter) | build **only** (no push — fail fast on either arch) |
| manual `workflow_dispatch` | build **+ push** |
| weekly cron (Sun 03:00 UTC) | bump R PPM date + **no-cache** rebuild + push + commit the bump |

**Tags pushed** (default branch): `:latest` (moves every build), `:<git-sha>`
(immutable per commit), `:YYYY-MM-DD` (dated snapshot).

**Weekly refresh:** the cron bumps the R PPM date pin to T-7 days, rebuilds with
`no-cache` (so apt / CRAN / PyPI / npm updates actually flow into `:latest`), and
on success commits the date bump back to `main` with `[skip ci]`. See *Bumping the
R snapshot date* below — the cron automates exactly that edit. No secrets are
needed; the per-run `GITHUB_TOKEN` is sufficient for ghcr.io pushes.

### Building locally 

```sh
docker build -t slds-yolobox yolobox
```

Useful build args:

- `CLAUDE_CACHE_BUST` — bump (or pass `$(date +%s)`) to force re-pulling
  `@latest` Claude Code instead of reusing the cached layer.

## What's installed

The Dockerfile is organized into commented `RUN` blocks. In order:

1. **CLI / shell tooling** — locales, procps, aggregate, tmux, parallel, bc,
   bats + shellcheck, xz-utils, dtrx, sqlite3, graphviz, git-lfs, git-delta,
   zoxide, tealdeer, hyperfine, plus a C/C++ dev kit (clang/clangd/clang-tidy,
   gdb, valgrind, cppcheck, ccache).
2. **Native dev libraries** — the `-dev` headers needed to compile R/Python
   packages with native code (libcurl, libxml2, fontconfig, freetype, GDAL, GLPK,
   Eigen, …).
3. **LaTeX / document toolchain** — pandoc, tidy, qpdf, poppler-utils, lmodern,
   `texlive-full`.
4. **R** — current R from the CRAN apt repo, then packages via `install_packages.R`
   (see *R packages* below).
5. **Python** — no global library stack; only `copier` as an isolated `uv` tool
   (see *Python packages* below).
6. **Tooling binaries** — `air` (R formatter), `starship` prompt, `yq`, `glow`.
7. **Claude Code** — reinstalled `@latest` via npm, plus the launch shim
   (`claude-launch-shim.sh`) that live-bridges sessions/memory/history/credentials
   from the host under `claude_config=true`; see *Claude Code integration* below.
8. **Shell environment** — zsh + autosuggestions + syntax-highlighting, fzf
   shell-integration, git wiring in `/etc/gitconfig`.
   
   Also wired up in the interactive shell:
   - **Aliases** (`/etc/zsh/zsh_aliases`): `R` = `R --no-save
     --no-restore-data --quiet` (quiet REPL startup), `ll`/`la`, human-readable
     `du`/`df`, `mkdir -p`, and colorized `ls`/`grep`.
   - **`EDITOR` / `VISUAL` = `vim`** — honored by git, crontab, sudoedit, etc.
   - **`LC_NUMERIC=C`** — forces `.` as the decimal separator for R / scripts
     regardless of `LANG`. Set both as a Docker `ENV` (so non-interactive `Rscript`
     / cron inherit it) and re-exported in the zsh config.
   - **`~/.local/bin` prepended to `PATH`** — user-scope installs (`uv tool`, pipx,
     ad-hoc scripts) win over their system equivalents.

> **Reproducibility note.** Only the R package set is date-pinned (PPM snapshot).
> The non-R binaries fetched from upstream releases — `yq`, `air`, `starship`,
> `glow`, and Claude Code — all pull `@latest` / `releases/latest`, so their
> versions float with each (no-cache) rebuild. Of these, only Claude Code has a
> cache-bust knob (`CLAUDE_CACHE_BUST`); the rest re-resolve whenever their
> layer is rebuilt. The weekly no-cache cron therefore also moves these tools.

## R packages — repository policy and date pin

We ship a dedicated small satck or R packages, 
installed by **`install_packages.R`** using `pak` and PPM,
using pre-compiled noble binaries from a **date-pinned snapshot**. 
The pinned date is the  `noble/<DATE>` line in `install_packages.R`.

### Bumping the R snapshot date

The weekly cron bumps this pin automatically: it rewrites the `noble/<DATE>`
line in `install_packages.R` to T-7 days, rebuilds no-cache, and commits the
change back to `main` (see the workflow section above). To bump out of cycle,
edit that line yourself and rebuild.

## Python and Python packages

**Python version.** We don't install Python ourselves: the system interpreter is
whatever Ubuntu noble ships (currently **3.12**), inherited from the base image.
Projects that need a specific (or newer) version pick
it per-project with `uv` (`uv venv --python <X>`, `.python-version`).

The image **does not ship a global scientific Python stack.**
Instead, projects create their own pinned environments — a per-project `uv` venv, or a `.yolobox`
Dockerfile fragment (see *Per-project customization* below).

## Claude Code integration (launch shim & host bridge)

Beyond `npm install`-ing Claude Code, the image wires its on-disk state to the
**host** so work done inside the box isn't lost when the container is torn down.
The container runs under yolobox's `claude_config=true`, so the entrypoint
**snapshots the host `~/.claude` into the container at every boot**
(`rm -rf ~/.claude && cp -a`). That snapshot is a *dead, one-way copy*: without
further wiring, new sessions, per-project memory, and prompt history written in
the box would vanish on teardown (and re-snapshot fresh next launch — they are
**not** preserved by the home volume).

**`claude-launch-shim.sh`** is installed at `/usr/local/bin/claude` and runs
before the real binary on every `claude` invocation. It does two jobs:

1. **Plugin path fixup.** The snapshot copies plugin *content* in, but the plugin
   registry locates each plugin by an absolute *host* path that doesn't exist in
   the container, so the plugins would silently fail to load. The shim rewrites
   those paths to the container `$HOME`. (Standalone skills under
   `~/.claude/skills` are dir-scanned and need no fixup.)

2. **Live host bridge.** For the dirs we want two-way, the host bind-mounts them
   read-write *outside* `~/.claude` (so the entrypoint's `rm -rf` can't reach
   them), and the shim swaps each dead snapshot copy for a symlink to the live
   mount:
   - `~/.claude/projects` → `/host-claude-sessions` (sessions **and** per-project memory)
   - `~/.claude/history.jsonl` → `/host-claude-history.jsonl` (prompt history)
   - `~/.claude/.credentials.json` → `/host-claude-credentials.json` (OAuth token)

   Reads and writes then hit the host both ways — your real history/memory show
   up in the box and survive teardown. (This lives in the shim, not a Claude
   `SessionStart` hook, because `claude --resume` lists sessions *before* any
   hook fires.) Credentials are bridged **read-write** for a specific reason:
   Claude refreshes and may rotate its OAuth token mid-session, and a read-only
   snapshot would lose that write on teardown — so the next boot would re-snapshot
   an aging host token and drop you to `/login`.

**Required host config.** The rw staging mounts come from the yolobox
`config.toml` `mounts` list (managed in the sysadmin repo):

```
"/home/<user>/.claude/projects:/host-claude-sessions"
"/home/<user>/.claude/history.jsonl:/host-claude-history.jsonl"
"/home/<user>/.claude/.credentials.json:/host-claude-credentials.json"
```

Without those mounts the shim is a transparent no-op and the dead snapshot copies
are used as-is. **Not bridged:** plugins (snapshot copy, only path-fixed).

**Launch chain.** `claude` → `/opt/yolobox/bin/claude` (upstream wrapper, adds
`--dangerously-skip-permissions`) → `/usr/local/bin/claude` (this shim) → the
real entry point under the npm package dir. The shim probes the package for the
entry point (it has been renamed across releases) and fails loudly if none match.

## Persistent volume

**`/home/yolo` is a persistent volume**, mounted by yolobox at runtime. It
survives container restarts *and* relaunches onto a freshly-pulled image; the
rest of the container filesystem is ephemeral and resets every launch. So any
state under `$HOME` carries over between sessions — shell history, dotfiles you
create, and tool databases such as **zoxide**'s (`~/.local/share/zoxide/db.zo`,
which is why `z` keeps learning across runs).
The flip side: this empty volume **shadows any dotfile baked into the image**
at `/home/yolo`, which is why our shell/prompt config is installed under `/etc`
instead (see *What's installed → Shell environment*).

> **Note — Claude Code state is the exception.** Claude's sessions / memory /
> history are **not** kept by this volume: the entrypoint re-snapshots `~/.claude`
> from the host on every boot, and the launch shim bridges the live bits back to
> the host.

## Per-project customization (downstream users)

You do **not** need to fork this image to add a few project-specific tools.
yolobox reads a per-project **`.yolobox.toml`** with a `[customize]` section and
builds a cached *derived* image on top of this base:

| field | purpose |
|-------|---------|
| `packages = ["pkg", ...]` | extra **apt** system packages (also `--packages` on the CLI) |
| `dockerfile = ".yolobox.Dockerfile"` | a Dockerfile fragment for anything apt can't express |
| `image = "..."` | point at a fully custom base image |

There is no native Python/pip field, so **project-specific Python deps go through
a Dockerfile fragment**. Since `uv` is already on `PATH`, the whole fragment is
one line — pin with `--exclude-newer <DATE>` for reproducibility:

```dockerfile
# .yolobox.Dockerfile
RUN uv pip install --system --exclude-newer <DATE> <project-packages>
```

See the upstream docs at <https://yolobox.dev/customizing> for the full
customization, rebuild, and upgrade behavior.
