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
| manual `workflow_dispatch` | build **+ push** (cached re-run; for a fully fresh rebuild use the daily no-cache cron) |
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

**Updating Claude Code in the published image:** there is nothing image-specific
to do — Claude Code is inherited from the base `finbarr/yolobox` image as-is (no
reinstall, no version management; see *Claude Code* below). The image version
refreshes whenever the base image does, which a no-cache rebuild picks up (the
daily cron, or a manual dispatch followed by the next cron). The in-box
self-updater is also left enabled, so a running box keeps itself current
independently of the image — version drift between image and box is allowed.

### Building locally 

```sh
docker build -t slds-yolobox yolobox
```

(No image-specific build args beyond the `SLDS_*` provenance stamps CI passes;
see *Image provenance*. Those default to `unknown`, so a plain `docker build`
works.)

## Diagnostics (`scripts/yolobox-doctor.sh`)

A single **OS-independent, read-only** diagnostic anyone can run to produce a
categorized `PASS`/`WARN`/`FAIL` report — instead of live-debugging the setup by
hand on each machine.

**Run it from the host.** There is one mode: the host. That's where the launch
toolchain (`yolobox` binary, container runtime, `config.toml`) lives — and the
host is the only place that can see *all* of it. To check the things that exist
only *inside* the image, the doctor **reaches in itself** rather than asking you
to run it in a box: `docker image inspect` for image identity, and a throwaway
`docker run --rm` **probe container** for the in-image contract. (If it detects it
was started inside a box it says so and continues best-effort, but the meaningful
report is host-side.)

What it checks:

- **Host launch toolchain** — the `yolobox` binary (+ its own version via the
  `version` subcommand; note `yolobox --version` with dashes forwards to the
  harness and prints e.g. `2.1.170 (Claude Code)`, *not* yolobox's version),
  **Claude Code on the host** (`claude --version`, informational), and a reachable
  container runtime (off Linux, a reminder it must be in Linux-container/WSL2 mode).
- **Host config + state** — `config.toml` (image ref + mounts parsed, dumped
  verbatim), that each **mount source exists on the host** (a missing one mounts
  empty in-box), and **CRLF line endings** in the shell scripts (the classic
  Windows breakage — a `\r` in a script's shebang yields `bad interpreter`).
- **Docker image identity** — read straight from the host via `docker image
  inspect`: local digest, created time, OCI labels, and the baked `SLDS_*`
  provenance (the SLDS build revision/date + the upstream `finbarr/yolobox` base
  digest it was layered on; see *Image provenance* below).
- **In-image contract** (probe container) — the default user is `yolo`, `claude`
  resolves on `PATH`, the core tool stack is present, and `LC_NUMERIC=C`.

It then prints an inventory (informational, never affects the exit code) read from
the host `~/.claude`: the **Claude Code plugins** installed (name@marketplace +
scope) and their marketplaces, and the **skills** available to Claude Code —
standalone (`~/.claude/skills`) plus those bundled in the *currently-installed*
plugin versions. The plugin-skill scan reads only the installed `installPath`s
from the registry, **not** a blanket `plugins/cache` scan (which also holds every
stale cached version), and names each skill by its `SKILL.md` frontmatter `name:`.

```sh
sh scripts/yolobox-doctor.sh               # full host-side report
```

It is POSIX `sh` (runs under dash on WSL2-Ubuntu, bash on macOS, …) and exits
non-zero if any check fails — so it doubles as a CI smoke test. It does not mutate
host state: the image check runs in a throwaway `docker run --rm` probe container
(ephemeral, auto-removed). Run it from the repo root so the host-side line-ending
check can find the scripts.

## What's installed

The Dockerfile is organized into commented `RUN` blocks. In order:

1. **CLI / shell tooling** — locales, procps, aggregate, tmux, parallel, bc,
   bats + shellcheck, xz-utils, dtrx, sqlite3, graphviz, git-lfs, git-delta,
   zoxide, tealdeer, hyperfine, plus a C/C++ dev kit (clang/clangd/clang-tidy,
   gdb, valgrind, cppcheck, ccache).
2. **Native dev libraries** — the `-dev` headers needed to compile R/Python
   packages with native code (libcurl, libxml2, fontconfig, freetype, GDAL, GLPK,
   Eigen, …), plus `libmagick++-dev` for the R `magick` package (a `vistool` dep).
3. **Headless Chromium** — `chromium` from the xtradeb PPA (multi-arch amd64+arm64),
   for the R `webshot2`/`chromote` stack used by `vistool`; `CHROMOTE_CHROME` points
   at it. See *R packages* for why this PPA (and not apt/Google Chrome).
4. **LaTeX / document toolchain** — pandoc, tidy, qpdf, poppler-utils, lmodern,
   `texlive-full`.
5. **R** — current R from the CRAN apt repo, then packages via `install_packages.R`
   (see *R packages* below).
6. **Python** — no global library stack; only `copier` as an isolated `uv` tool
   (see *Python packages* below).
7. **Tooling binaries** — `air` (R formatter), `starship` prompt, `yq`, `glow`.
8. **Claude Code** — *not* installed or customized here; inherited from the base
   image as-is. No launch shim, no host↔box bridge, no version check, and the
   self-updater is left enabled (version drift allowed); see *Claude Code* below.
9. **Shell environment** — zsh + autosuggestions + syntax-highlighting, fzf
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
> `glow` — all pull `@latest` / `releases/latest`, so their versions float with
> each (no-cache) rebuild. Claude Code is not fetched here at all (inherited from
> the base image, self-updater left enabled), so the *image's* version moves only
> when the base image does — but a running box may self-update past it. The daily
> no-cache cron re-resolves the floating tools above.

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

We ship a curated stack of R packages (the mlr3 ecosystem, the tidyverse, and the
plotting / EDA / learner / dataset packages the SLDS lectures use), installed by
**`install_packages.R`** using `pak` and PPM, as pre-compiled noble binaries from a
**date-pinned snapshot**. The pinned date is the `noble/<DATE>` line in
`install_packages.R`.

**One documented exception to PPM-only.** Two packages the lectures use are not on
CRAN/PPM, so they can't come from the date-pinned snapshot. They install in a
**separate, clearly-marked step at the end of `install_packages.R`**, from different
non-PPM sources:

- **`mlr3extralearners`** — from the **mlr-org r-universe** (precompiled binary).
- **`vistool`** — **not on any r-universe**; only the GitHub repo exists, so it is
  built from **GitHub source** (`slds-lmu/vistool`). Its two system deps are both
  installed in the Dockerfile: **`libmagick++-dev`** (for `magick`, linked at load
  time) and **`chromium`** from the **xtradeb PPA** (for `webshot2`/`chromote`, which
  rasterize htmlwidgets/plotly via a headless browser), with `CHROMOTE_CHROME`
  pointing at `/usr/bin/chromium`. xtradeb is used because it's the only real
  chromium `.deb` that is multi-arch (amd64 + arm64) on noble — Ubuntu's apt
  chromium is a snap stub and Google Chrome has no arm64 build. Like vistool, this
  PPA floats outside the PPM date pin.

Trade-off: these sources have no date pin, so unlike everything else these two
**float** with each rebuild. Everything in the main `pkgs` list stays strictly
PPM-only and date-pinned.

### Bumping the R snapshot date

The daily cron bumps this pin automatically: it rewrites the `noble/<DATE>`
line in `install_packages.R` to T-7 days, rebuilds no-cache, and commits the
change back to `main` (see the workflow section above). To bump out of cycle,
edit that line yourself and rebuild.

### Per-project R packages

The baked package set above is a *shared* system library for ad-hoc use. A project
that needs its **own** extra R packages bakes them into a **derived image** via a
`.yolobox.Dockerfile` fragment — the R analogue of the `uv pip install` fragment
under *Per-project customization*. yolobox builds and caches the derived image on
top of this base, so the packages are preinstalled at container start.

Install with `pak` (already on the image) and pin `repos` to a **date-stamped PPM
snapshot**, exactly as the image's own `install_packages.R` does — that gives
reproducible, pre-compiled noble binaries instead of source compiles:

```dockerfile
# .yolobox.Dockerfile
RUN Rscript -e 'options(repos = c(PPM = "https://packagemanager.posit.co/cran/__linux__/noble/<DATE>")); pak::pak(c("pkgA", "pkgB"))'
```

Notes:

- **Pin the date** (`noble/<DATE>`, e.g. `noble/2026-06-21`) for reproducibility;
  using `noble/latest` would let versions float with every rebuild. See *R packages
  — repository policy and date pin* above for the rationale.
- **Native builds already work** if a package has no PPM binary: the image ships the
  `-dev` headers (see *What's installed*), so a source compile succeeds — staying on
  PPM binaries just avoids it.

## Python and Python packages

**Python version.** We don't install Python ourselves: the system interpreter is
whatever Ubuntu noble ships (currently **3.12**), inherited from the base image.
Projects that need a specific (or newer) version pick
it per-project with `uv` (`uv venv --python <X>`, `.python-version`).

The image **does not ship a global scientific Python stack.**
Instead, projects create their own pinned environments — a per-project `uv` venv, or a `.yolobox`
Dockerfile fragment (see *Per-project customization* below).

## Claude Code

This image **inherits Claude Code from the base `finbarr/yolobox` image as-is and
adds nothing on top of it.** There is no reinstall, no launch shim, no host↔box
session/memory/history bridge, and no host/image version check. (Earlier versions
of this image shipped all of that via a `claude-launch-shim.sh`; it was removed in
favor of full isolation.)

This image makes **no** Claude-level customization at all — not even pinning the
version. The in-box self-updater is **left enabled**, so a running box keeps Claude
Code current on its own. Note the consequence: `/home/yolo` is a persistent volume
(see below), so a self-update drops a versioned binary there and repoints
`~/.local/bin/claude` at it — from then on the in-box `claude` floats with that
volume and may differ from the version the image baked in. **Version drift between
image and box is explicitly allowed.** If you ever want to pin Claude Code to the
image's version instead, add `ENV DISABLE_AUTOUPDATER=1` to the Dockerfile.

**Isolation is configured host-side, not in this image.** Whether the box receives
any host Claude state at all is governed by the yolobox `config.toml` (managed in
the sysadmin repo):

- **`claude_config = false`** — the box starts with a clean Claude install: no host
  `~/.claude` is copied in, so you log in once per session and have no host config
  or plugins in-box. This is the intended fully-isolated mode.
- **`claude_config = true`** (the base default) — yolobox's entrypoint copies the
  host `~/.claude` into the box **one-way** at boot (a dead snapshot: box-side
  changes do **not** flow back and are lost on teardown). This image no longer adds
  any two-way bridge on top of that snapshot.

**Login.** Because nothing bridges credentials, the box logs in per session. For
unattended/`-p` use, forward a long-lived `CLAUDE_CODE_OAUTH_TOKEN`
(`claude setup-token`) — note it satisfies headless runs but interactive launches
may still show the login picker until onboarding is completed once. (A fresh
interactive `/login` rotates your subscription's OAuth grant, so logging into a
second box can log the first out; the token avoids that.)

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

> **Note — Claude Code state is the exception.** Claude's `~/.claude` is **not**
> governed by this volume: under `claude_config=true` the entrypoint re-snapshots
> it from the host on every boot (a one-way copy), and under `claude_config=false`
> the box starts with a clean install. Either way, box-side Claude state is *not*
> persisted by `/home/yolo` and does not flow back to the host — this image adds no
> bridge (see *Claude Code* above). The Claude *binary*, however, **is** subject to
> the volume: the self-updater is left enabled, so a self-updated
> `~/.local/bin/claude` persists on `/home/yolo` and can run a different version
> than the image baked in (version drift is allowed; see *Claude Code* above).

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

## Running multiple boxes at once (concurrency)

Nothing stops you from opening **several boxes at the same time** — different
terminals, different projects, or even two boxes pointed at the *same* directory.
With this image's isolated Claude model (no host↔box bridge; see *Claude Code*
above), the picture is much simpler than it used to be: **boxes no longer share
live Claude sessions, per-project memory, or prompt history** with each other or
with the host. Each box's `~/.claude` is container/volume state only — a one-way
boot snapshot under `claude_config=true`, or a clean install under
`claude_config=false` — and box-side changes are never mirrored out.

What concurrent boxes *can* still share is **not** Claude-specific:

- **The working tree.** If yolobox mounts the same host project directory into two
  boxes (the default, non-fork mount), two autonomous agents edit the same files
  concurrently — the ordinary lost-update / half-written-file / git-index race,
  amplified by both sides acting on their own. This is not Claude-specific (two
  humans hacking the same checkout hit it too), but two agents make it more likely.
  Isolate with **fork mode** or a **git worktree** if both will edit heavily.
- **The persistent `/home/yolo` volume.** yolobox uses one global `yolobox-home`
  named volume for every box, so if it attaches that volume to more than one running
  container at once, container-local state there — shell history, the zoxide db, and
  `~/.claude` itself (which lives on this volume) — is shared live and unlocked
  between the simultaneous boxes. This is a property of the yolobox volume, not of
  this image. If you want two boxes fully isolated from each other, run one in
  **`--scratch`** (ephemeral home) or use **fork mode**.

**Rule of thumb:** concurrent boxes on *different* projects — go ahead. Two boxes
on the *same* project — fine too, but the shared working tree (and, if attached to
both, the shared home volume) are the things to watch; isolate the tree with fork
mode or a git worktree if both agents will edit heavily. The old bridge-era hazards
(shared session transcripts, a shared `MEMORY.md` index, resuming one session from
two boxes) no longer apply here, because nothing bridges that state anymore.

