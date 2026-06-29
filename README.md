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
├── scripts/
│   └── yolobox-doctor.sh  # OS-independent read-only diagnostic (run on the host)
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
| manual `workflow_dispatch` | build **+ push**; `refresh_claude` input (default **true**) busts the Claude Code layer so `@latest` is re-pulled |
| daily cron (03:00 UTC) | bump R PPM date + **no-cache** rebuild + push + commit the bump |

**Tags pushed** (default branch): `:latest` (moves every build), `:<git-sha>`
(immutable per commit), `:YYYY-MM-DD` (dated snapshot).

**Daily refresh:** the cron bumps the R PPM date pin to T-7 days, rebuilds with
`no-cache` (so apt / CRAN / PyPI / npm updates actually flow into `:latest`), and
on success commits the date bump back to `main` with `[skip ci]`. See *Bumping the
R snapshot date* below — the cron automates exactly that edit. No secrets are
needed; the per-run `GITHUB_TOKEN` is sufficient for ghcr.io pushes. (T-7 is the
PPM publication-lag safety margin, not the cadence — each daily run still advances
the pin by a day; a full no-cache rebuild every day is CI-minute heavy by design.)

**Updating Claude Code in the published image:** trigger a manual run —
`gh workflow run docker-yolobox.yml` or the *Run workflow* button in the
Actions tab. The dispatch input `refresh_claude` defaults to **true**, which
passes a unique `CLAUDE_CACHE_BUST` build-arg so the Claude Code layer (near
the end of the Dockerfile) is rebuilt and `@latest` re-resolved, while all
earlier layers (texlive, R, …) come from cache — a fast build, no commit
needed. Set the input to false for a pure cached re-run (e.g. after a flaky
build).

### Building locally 

```sh
docker build -t slds-yolobox yolobox
```

Useful build args:

- `CLAUDE_CACHE_BUST` — bump (or pass `$(date +%s)`) to force re-pulling
  `@latest` Claude Code instead of reusing the cached layer.

## Diagnostics (`scripts/yolobox-doctor.sh`)

A single **OS-independent, read-only** diagnostic anyone can run to produce a
categorized `PASS`/`WARN`/`FAIL` report — instead of live-debugging the setup by
hand on each machine.

**Run it from the host.** There is one mode: the host. That's where the launch
toolchain (`yolobox` binary, container runtime, `config.toml`) and the real
`~/.claude` state live — and the host is the only place that can see *all* of it.
To check the things that exist only *inside* the image/container, the doctor
**reaches in itself** rather than asking you to run it in a box: `docker image
inspect` for image identity, and a throwaway `docker run --rm` **probe container**
for the in-image contract and the live-bridge integration test. (If it detects it
was started inside a box it says so and continues best-effort, but the meaningful
report is host-side.)

What it checks:

- **Host launch toolchain** — the `yolobox` binary (+ its own version via the
  `version` subcommand; note `yolobox --version` with dashes forwards to the
  harness and prints e.g. `2.1.170 (Claude Code)`, *not* yolobox's version),
  **Claude Code on the host** (`claude --version`), and a reachable container
  runtime (off Linux, a reminder it must be in Linux-container/WSL2 mode).
- **Host config + state** — `config.toml` (image ref + mounts parsed, dumped
  verbatim), that each **mount source exists on the host** (a missing one is the
  #1 silent cause of a dead bridge), the host `~/.claude` bridge sources, and
  **CRLF line endings** in the shell scripts (the classic Windows breakage — a
  `\r` in the shim's shebang yields `bad interpreter`).
- **Docker image identity** — read straight from the host via `docker image
  inspect`: local digest, created time, OCI labels, and the baked `SLDS_*`
  provenance (the SLDS build revision/date + the upstream `finbarr/yolobox` base
  digest it was layered on; see *Image provenance* below).
- **In-image contract** (probe container) — the default user is `yolo`, the launch
  shim is installed, the launch-chain links exist, the real `claude` entry point
  resolves, the core tool stack is present, `LC_NUMERIC=C`, and the Claude Code
  version shipped in the image.
- **Live host bridge** (probe container, with the real `/host-claude-*` mounts
  attached) — it **reproduces the launch shim's symlink swap** and verifies each
  mount attaches and is writable and the symlink resolves; with `--write-probe` a
  sentinel written *in the container* is confirmed back *on the host* (genuine
  two-way proof). This replaces the old "must already be inside a box" check — the
  bridge can now be integration-tested anytime, from the host.
- **Claude Code version: host vs image** — the doctor is the one place that sees
  *both* numbers (host via `claude --version`, image via the probe), so it compares
  them: **PASS** if equal, **WARN** if they differ (the box shares live
  sessions/history/config with the host, so a skew can muddle that
  shared state). Non-fatal, and skipped unless both versions are known.

It then prints an inventory (informational, never affects the exit code) read from
the host `~/.claude`: the **Claude Code plugins** installed (name@marketplace +
scope) and their marketplaces, and the **skills** available to Claude Code —
standalone (`~/.claude/skills`) plus those bundled in the *currently-installed*
plugin versions. The plugin-skill scan reads only the installed `installPath`s
from the registry, **not** a blanket `plugins/cache` scan (which also holds every
stale cached version), and names each skill by its `SKILL.md` frontmatter `name:`.

```sh
sh scripts/yolobox-doctor.sh               # full host-side report
sh scripts/yolobox-doctor.sh --write-probe # also prove bridge write-through
```

It is POSIX `sh` (runs under dash on WSL2-Ubuntu, bash on macOS, …) and exits
non-zero if any check fails — so it doubles as a CI smoke test. It does not mutate
host state: the image/bridge checks run in a throwaway `docker run --rm` probe
container (ephemeral, auto-removed), and only the opt-in `--write-probe` touches
the host — writing and then removing a single sentinel through the sessions mount
to prove write-through. Run it from the repo root so the host-side line-ending
check can find the scripts.

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
   (`claude-launch-shim.sh`) that live-bridges sessions/memory/history
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
> cache-bust knob (`CLAUDE_CACHE_BUST`, wired to the manual-dispatch
> `refresh_claude` input — see *Triggers* above); the rest re-resolve whenever
> their layer is rebuilt. The daily no-cache cron therefore also moves these tools.

### Image provenance

Because the image's tags float (`:latest`) and the `FROM` base is itself a moving
`:latest`, the image would otherwise record nothing about *which* commit built it
or *which* base it was layered on. The Dockerfile's final layer stamps that
provenance in, supplied by CI as build-args (defaulting to `unknown` so a plain
`docker build yolobox` still works):

| field | meaning | exposed as |
|-------|---------|------------|
| `SLDS_IMAGE_REVISION` | git commit (`github.sha`) the image was built from | env + `org.opencontainers.image.revision` |
| `SLDS_IMAGE_CREATED` | RFC3339 build timestamp | env + `org.opencontainers.image.created` |
| `SLDS_BASE_IMAGE` | upstream base ref (`ghcr.io/finbarr/yolobox:latest`) | env + `org.opencontainers.image.base.name` |
| `SLDS_BASE_DIGEST` | that base's **immutable digest**, resolved once at build time | env + `org.opencontainers.image.base.digest` |

Each value is baked **both** as an `ENV` (so it's readable from *inside* a
container, which has no runtime to inspect its own image) **and** as an OCI `LABEL`
(so it's readable from outside via `docker image inspect`). `yolobox-doctor.sh`
surfaces them in its *Docker image* section by inspecting the configured image ref
on the host. The base digest is resolved once in CI's `prepare` job and shared by
both arch legs, so every per-arch image carries identical provenance.

## R packages — repository policy and date pin

We ship a dedicated small satck or R packages, 
installed by **`install_packages.R`** using `pak` and PPM,
using pre-compiled noble binaries from a **date-pinned snapshot**. 
The pinned date is the  `noble/<DATE>` line in `install_packages.R`.

### Bumping the R snapshot date

The daily cron bumps this pin automatically: it rewrites the `noble/<DATE>`
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
before the real binary on every `claude` invocation. It does three jobs:

1. **Plugin path fixup (two layers).** The snapshot copies plugin *content* in,
   but the registry locates each plugin by an absolute *host* path that doesn't
   exist in the container, so plugins would silently fail to load. The shim
   (a) rewrites those paths to the container `$HOME` — best-effort, since Claude
   regenerates the registry on startup and reintroduces the host paths — and
   (b) creates a regeneration-proof compat symlink (`<host-prefix>/.claude/plugins`
   → `$HOME/.claude/plugins`) via passwordless `sudo`, so the host path resolves
   no matter what the registry says. Without sudo it falls back to (a) alone.
   (Standalone skills under `~/.claude/skills` are dir-scanned and need no fixup.)

2. **Live host bridge.** For the dirs we want two-way, the host bind-mounts them
   read-write *outside* `~/.claude` (so the entrypoint's `rm -rf` can't reach
   them), and the shim swaps each dead snapshot copy for a symlink to the live
   mount:
   - `~/.claude/projects` → `/host-claude-sessions` (sessions **and** per-project memory)
   - `~/.claude/history.jsonl` → `/host-claude-history.jsonl` (prompt history)

   Reads and writes then hit the host both ways — your real history/memory show
   up in the box and survive teardown. (This lives in the shim, not a Claude
   `SessionStart` hook, because `claude --resume` lists sessions *before* any
   hook fires.)

   **Credentials are deliberately *not* bridged.** A single-file bind mount pins
   the inode that existed at container start, but Claude refreshes its OAuth token
   via an atomic rename (write tmp + `rename` over `.credentials.json`), which
   swaps the inode and silently breaks the mount — stale token in-box, lost write
   on the host. So the box simply logs in once per session. For unattended/`-p`
   use, forward a long-lived `CLAUDE_CODE_OAUTH_TOKEN` (`claude setup-token`)
   instead — note it satisfies headless runs but interactive launches may still
   show the login picker until onboarding is completed once.

3. **Host/image version check.** Because the box shares live state with the host
   (the bridge above plus the snapshotted `~/.claude` config), a host and image
   running **different** Claude Code versions can skew that shared state (session
   schema, config migrations). Once per boot the shim compares
   the **image** version (`package.json` of the installed npm package —
   authoritative) against the **host** version (`~/.claude/.last-update-result.json`
   `version_to` on a successful update; this file is host-only because the in-box
   updater is disabled, and it is re-snapshotted every boot). On a mismatch it
   prints a warning and, on an **interactive** launch, waits for you to press
   **Enter** before continuing — headless `claude -p` runs print the warning but
   never block. The check is robust by omission: if either version can't be
   determined it stays silent rather than raise a false alarm.

**Required host config.** The rw staging mounts come from the yolobox
`config.toml` `mounts` list (managed in the sysadmin repo):

```
"/home/<user>/.claude/projects:/host-claude-sessions"
"/home/<user>/.claude/history.jsonl:/host-claude-history.jsonl"
```

Without those mounts the shim is a transparent no-op and the dead snapshot copies
are used as-is. **Not bridged:** plugins (snapshot copy, path-fixed and
compat-symlinked).

**Caveat — the bridge only exists under a `claude` launch.** Because the symlink
swap lives in the shim (and the shim only runs when `claude` is invoked), entering
the box any *other* way — e.g. `yolobox shell` — gives you the boot snapshot but
**no live bridge**: `~/.claude/projects` stays a plain copied directory, writes
land only in the container, and they vanish on teardown. This is the intended
behavior, but it's a trap when *testing* persistence: a sentinel written from a
`yolobox shell` will (correctly) fail to reach the host. To verify the bridge,
test from a **Claude-launched** box — there `~/.claude/projects` is a symlink to
`/host-claude-sessions` and box-side writes show up on the host immediately.

**Launch chain.** `claude` → `/opt/yolobox/bin/claude` (upstream wrapper, adds
`--dangerously-skip-permissions`; strips itself from `PATH`, then re-runs `which
claude`) → `~/.local/bin/claude` (a **symlink to the shim, and the first `claude`
match on `PATH`** — this is why `which -a claude` shows three entries) →
`/usr/local/bin/claude` (this shim) → the real entry point under the npm package
dir. The override must replace `/usr/local/bin/claude` specifically (the symlink's
target); see the Dockerfile's Claude Code block for why. The shim probes the
package for the entry point (it has been renamed across releases) and fails loudly
if none match.

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
