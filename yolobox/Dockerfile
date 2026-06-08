FROM ghcr.io/finbarr/yolobox:latest

# Upstream image runs as the unprivileged `yolo` user; switch to root for the
# apt / pip / R installs below. Restore the default user at the end.
USER root

# Install system packages.
#
# NOTE on what NOT to (re-)install here: the upstream ghcr.io/finbarr/yolobox
# already ships a baseline of dev tooling, including:
#   bat, build-essential, cmake, eza, fd-find, fzf, gh, git, gnupg, htop, jq,
#   less, nano, nodejs (+ npm), openssh-client, ripgrep, rsync, sudo, tree,
#   unzip, vim, zip.
# We intentionally do NOT re-list those — apt would no-op, but listing them
# would falsely imply ownership and bloat the diff against upstream. Anything
# below is either missing from upstream or something we want to pin/own here.
RUN apt-get update && apt-get install -y --no-install-recommends \
    # Locale data (en_US.UTF-8 generated below; LANG/LC_ALL stay C.UTF-8)
    locales \
    # Extra shell utilities
    procps \
    aggregate \
    tmux \
    parallel \
    bc \
    # ---- shell dev / testing ----
    # bats: Bash Automated Testing System — TAP-style test runner. /usr/bin/bats.
    bats \
    # shellcheck: static analysis for shell scripts (pairs with bats).
    shellcheck \
    # ---- archive / transfer / extraction ----
    # xz-utils: .xz / .lzma support (tar -J).
    xz-utils \
    # dtrx: "do the right extraction" — one command for any archive format.
    dtrx \
    # ---- inspection / DB / diagrams ----
    # sqlite3: lightweight DB CLI for inspection.
    sqlite3 \
    # graphviz: dot/neato — used by R/Python doc pipelines (DiagrammeR, etc.).
    graphviz \
    # ---- git ergonomics ----
    # git-lfs: large-file storage support for git (needed by some repos).
    git-lfs \
    # git-delta: side-by-side syntax-highlighted pager for git diff / log / show.
    # Wired in /etc/gitconfig below so all users get it without per-user setup.
    git-delta \
    # ---- modern CLI ergonomics ----
    # zoxide: smart `cd` replacement. Shell integration added in zshrc.
    zoxide \
    # tealdeer: fast Rust client for tldr-pages (three-line CLI summaries).
    # First run: `tldr -u` to fetch the page cache.
    tealdeer \
    # hyperfine: command-line benchmarking with warmups and statistics.
    hyperfine \
    # NOTE: glow is NOT in Ubuntu 24.04 noble's repos (added in 25.04). It is
    # installed from Charm's official apt repo in a later RUN block.
    # ---- C/C++ scientific dev kit ----
    # build-essential + cmake come from upstream. We add the analysis / debug
    # tooling that's typically needed for native R/Python extension work.
    clang \
    clangd \
    clang-tidy \
    ccache \
    gdb \
    valgrind \
    cppcheck \
    && locale-gen en_US.UTF-8 \
    # Symlinks for Ubuntu's renamed binaries so the canonical names work:
    #   /usr/bin/fdfind  (fd-find package) -> fd
    #   /usr/bin/batcat  (bat package)     -> bat
    # `ln -sf` is idempotent in case upstream ever adds these symlinks.
    && ln -sf /usr/bin/fdfind /usr/local/bin/fd \
    && ln -sf /usr/bin/batcat /usr/local/bin/bat \
    && rm -rf /var/lib/apt/lists/*

RUN apt-get update && apt-get install -y --no-install-recommends \
    libcurl4-openssl-dev \
    libxml2-dev \
    libfontconfig1-dev \
    libharfbuzz-dev \
    libfribidi-dev \
    libfreetype6-dev \
    libpng-dev \
    libtiff5-dev \
    libjpeg-dev \
    libgit2-dev \
    zlib1g-dev \
    libeigen3-dev \
    libx11-dev \
    libglpk-dev \
    libudunits2-dev \
    libhiredis-dev \
    libproj-dev \
    libprotobuf-dev \
    libgdal-dev \
    && rm -rf /var/lib/apt/lists/*

# LaTeX / document toolchain. texlive-full pulls ~3000 .deb
# files, so add apt retry/timeout config first to survive flaky mirrors.
RUN echo 'Acquire::Retries "5";' > /etc/apt/apt.conf.d/80-retries \
    && echo 'Acquire::http::Timeout "120";' >> /etc/apt/apt.conf.d/80-retries \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        pandoc \
        tidy \
        qpdf \
        poppler-utils \
        lmodern \
        texlive-full \
    && rm -rf /var/lib/apt/lists/*

# CRAN apt repo + R. Provides current R instead of Ubuntu's stock r-base.
RUN wget -qO- https://cloud.r-project.org/bin/linux/ubuntu/marutter_pubkey.asc \
        | tee /etc/apt/trusted.gpg.d/cran_ubuntu_key.asc > /dev/null \
    && echo "deb https://cloud.r-project.org/bin/linux/ubuntu noble-cran40/" \
        > /etc/apt/sources.list.d/cran.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        r-base \
        r-base-dev \
    && rm -rf /var/lib/apt/lists/*

# R packages via pak (tidyverse + mlr3 ecosystem). See install_packages.R for
# the package list, PPM date pin, and repository policy.
COPY install_packages.R /tmp/install_packages.R
RUN Rscript /tmp/install_packages.R && rm /tmp/install_packages.R

# Python tooling. We deliberately do NOT install a global stack,
# projects are supposed to handle this locally. Because nothing
# here writes to the system interpreter, Ubuntu's PEP 668 EXTERNALLY-MANAGED
# marker is left in place.
#
# copier (project/template scaffolding CLI) is a *tool*, not a library, so it
# goes in as an isolated `uv` tool: its own venv under /opt/uv/tools with the
# launcher symlinked into /usr/local/bin, so the runtime `yolo` user finds
# `copier` on PATH (the build runs as root). The env vars are scoped to this RUN
# so a `yolo`-user `uv tool install` at runtime still uses its own ~/.local dirs.
RUN UV_TOOL_DIR=/opt/uv/tools UV_TOOL_BIN_DIR=/usr/local/bin \
        uv tool install --no-cache copier \
    && copier --version

# air: Posit's R formatter (Rust binary). The cargo-dist installer drops the
# binary at /root/.local/bin/air; move it to /usr/local/bin so every user
# finds it on PATH, then strip the rc-file edits the installer leaves behind.
RUN curl -LsSf https://github.com/posit-dev/air/releases/latest/download/air-installer.sh | sh \
    && mv /root/.local/bin/air /usr/local/bin/air \
    && rm -rf /root/.local /root/.config/air \
    && sed -i '/\.local\/bin\/env/d' /root/.zshrc /root/.bashrc /root/.profile 2>/dev/null || true

# Claude Code (Anthropic's CLI, `claude`). Re-install `@latest` so every rebuild
# of this image picks up the current release rather than whatever upstream
# bundled.
#
# Upstream layout we must work around:
#   /usr/local/bin/claude          — a ~245 MB self-contained native binary
#   /opt/yolobox/bin/claude        — wrapper that strips itself from PATH then
#                                    re-runs `which claude` (i.e. resolves
#                                    against the rest of PATH) and execs with
#                                    --dangerously-skip-permissions.
#   /home/yolo/.local/bin/claude   — symlink -> /usr/local/bin/claude
#
# The wrapper's `which claude` hits /home/yolo/.local/bin/claude first, which
# points at /usr/local/bin/claude — so to override claude we MUST replace that
# specific file. A plain `npm install -g` as root goes to root's npm prefix
# (`/usr`, giving /usr/bin/claude) and is shadowed by the symlink; hence the
# explicit `--prefix=/usr/local`. We remove the upstream native binary first
# so npm's small JS shim can take its place at /usr/local/bin/claude.
#
# CLAUDE_CACHE_BUST: Docker caches RUN lines by literal text, so without a
# cache-busting arg the `@latest` resolves once and then sticks forever. Bump
# this (or pass `--build-arg CLAUDE_CACHE_BUST=$(date +%s)`) to force re-pull.
#
# The `gccm-gen` alias in zsh_aliases depends on `claude -p` being on PATH.
ARG CLAUDE_CACHE_BUST=1
RUN rm -f /usr/local/bin/claude \
    && npm install -g --prefix=/usr/local @anthropic-ai/claude-code@latest \
    && npm cache clean --force \
    && /usr/local/bin/claude --version

# Claude launch shim. We replace the npm `claude` launcher at
# /usr/local/bin/claude with a wrapper that runs once before the real binary,
# after the yolobox entrypoint snapshot but before Claude reads anything.
# Under claude_config=true the entrypoint snapshots host ~/.claude in one-way
# (dead copy). The shim does two fixups on top:
#   1. Rewrites the plugin registry's absolute host paths to the container home
#      (cp copies them verbatim, so plugins would otherwise fail to load).
#   2. Bridges the dirs we want LIVE by symlinking them to rw host mounts staged
#      at /host-claude-* (outside ~/.claude, so the entrypoint's `rm -rf` can't
#      clobber the host data): ~/.claude/projects (sessions + per-project
#      memory) and ~/.claude/history.jsonl (prompt history).
# Credentials are NOT bridged — the snapshot copy is enough.
# The shim execs the real binary by absolute path (resolved from the npm package
# dir — see the shim's candidate probe), so the upstream /opt/yolobox/bin/claude
# wrapper still resolves `which claude` here without recursion. The rw mounts themselves come from the sysadmin config.toml
# `mounts` list; see claude-launch-shim.sh for the expected mount paths.
# CRITICAL: `/usr/local/bin/claude` is the npm-created SYMLINK pointing at the
# package's real entry point (.../claude-code/bin/claude.exe). `COPY`-ing onto
# that path FOLLOWS the symlink and overwrites its target — i.e. it would clobber
# the real ~245 MB Claude binary with this small shim. The shim then probes for
# the real binary, finds only itself at bin/claude.exe, and exec-loops forever
# (a silent CPU-pegging hang at launch). So we must NOT write through the symlink.
# Instead: stage the shim at a neutral path, delete the symlink, then move the
# shim into its place as a regular file. bin/claude.exe stays the real binary,
# which the shim resolves and execs.
COPY claude-launch-shim.sh /usr/local/bin/claude.shim
RUN rm -f /usr/local/bin/claude \
    && mv /usr/local/bin/claude.shim /usr/local/bin/claude \
    && chmod 0755 /usr/local/bin/claude

# Interactive shell setup: zsh + plugins + starship prompt.
# The upstream yolobox base ships fzf but its
# shell-integration scripts under /usr/share/doc/fzf/examples/ are stripped by
# Ubuntu's dpkg.cfg.d/excludes (path-exclude=/usr/share/doc/*). We add a
# path-include for that directory BEFORE reinstalling fzf so the key-bindings
# and completion files get unpacked. Then install zsh and the two plugins.
RUN echo 'path-include=/usr/share/doc/fzf/examples/*' \
        > /etc/dpkg/dpkg.cfg.d/zz-keep-fzf-shell-integration \
    && apt-get update \
    && apt-get install -y --no-install-recommends --reinstall fzf \
    && apt-get install -y --no-install-recommends \
        zsh \
        zsh-autosuggestions \
        zsh-syntax-highlighting \
    && rm -rf /var/lib/apt/lists/*

# starship: cross-shell prompt (Rust binary). The plain-text-symbols preset
# avoids requiring a Nerd Font in the host terminal.
RUN curl -fsSL https://starship.rs/install.sh \
        | sh -s -- --yes --bin-dir /usr/local/bin

# yq: YAML/JSON/XML processor (mikefarah/yq, Go binary). Not in Ubuntu apt,
# so we fetch the latest release directly into /usr/local/bin. The arch is
# derived so the image builds correctly on both linux/amd64 and linux/arm64:
# `dpkg --print-architecture` returns amd64 / arm64, which match yq's release
# asset suffixes verbatim (yq_linux_amd64 / yq_linux_arm64).
RUN arch="$(dpkg --print-architecture)" \
    && curl -fsSL -o /usr/local/bin/yq \
        "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${arch}" \
    && chmod +x /usr/local/bin/yq

# glow: Charm.sh terminal Markdown renderer. Not in Ubuntu 24.04 noble repos
# (lands in 25.04+), so we use Charm's official apt repo. The key is scoped
# via [signed-by=...] so it only authenticates packages from repo.charm.sh
# (modern apt practice; doesn't globally trust the Charm key for other repos).
RUN install -d -m 0755 /etc/apt/keyrings \
    && curl -fsSL https://repo.charm.sh/apt/gpg.key \
        | gpg --dearmor -o /etc/apt/keyrings/charm.gpg \
    && echo "deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *" \
        > /etc/apt/sources.list.d/charm.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends glow \
    && rm -rf /var/lib/apt/lists/*

# System-wide git config for every user (root + yolo): delta pager wiring, the
# short git aliases, and a couple of behavior tweaks. Shipped as a standalone
# file (like the zsh dotfiles) instead of a stack of `git config --system`
# commands. See yolobox/gitconfig for the documented contents. Users can still
# override anything in their own ~/.gitconfig.
COPY gitconfig /etc/gitconfig

# Ship the interactive shell + prompt config SYSTEM-WIDE (under /etc), NOT into
# /home/yolo. At runtime yolobox bind-mounts a persistent home volume over
# /home/yolo, which shadows any dotfile baked into the image's home — so a baked
# ~/.zshrc / ~/.zsh_aliases / ~/.config/starship.toml would silently never load.
# Installing under /etc keeps them effective regardless of the volume:
#   /etc/zsh/zshrc.d/10-slds.zsh — interactive behavior, plugin wiring, prompt
#   /etc/zsh/zsh_aliases         — ls/grep colors, R alias, git/gccm helpers
#   /etc/starship.toml           — composed prompt config (see STARSHIP_CONFIG)
# These are root-owned system files; a user wanting to customize drops their own
# ~/.zsh_aliases in the home volume (still sourced by our zshrc as an override).
COPY zshrc        /etc/zsh/zshrc.d/10-slds.zsh
COPY zsh_aliases  /etc/zsh/zsh_aliases
COPY starship-extra.toml /tmp/starship-extra.toml
# The stock /etc/zsh/zshrc does not read any drop-in dir, so append a tiny
# loader that sources /etc/zsh/zshrc.d/*.zsh for every interactive shell. We
# append (not overwrite) to preserve the distro keybindings/compinit; (N) is the
# null-glob qualifier so an empty dir is not an error.
RUN printf '\n# ---- slds drop-ins (added by the slds-yolobox image) ----\nfor _f in /etc/zsh/zshrc.d/*.zsh(N); do source "$_f"; done\nunset _f\n' >> /etc/zsh/zshrc \
    # Compose the starship prompt config: the plain-text-symbols preset (no Nerd
    # Font required) concatenated with starship-extra.toml (our format /
    # directory / cmd_duration overrides). Written to /etc so the home-volume
    # mount can't shadow it; surfaced to starship via ENV STARSHIP_CONFIG below.
    && starship preset plain-text-symbols -o /tmp/starship-base.toml \
    && cat /tmp/starship-base.toml /tmp/starship-extra.toml > /etc/starship.toml \
    && rm /tmp/starship-base.toml /tmp/starship-extra.toml \
    # Make zsh the login shell for `yolo` (edits /etc/passwd, outside the home
    # volume, so it survives). Note: GNU parallel's first-run citation nag is
    # per-user state under $HOME/.parallel (no system-wide path), so it cannot be
    # silenced image-wide here — it is left to first-run / the user.
    && chsh -s /bin/zsh yolo \
    # Hand interactive bash off to zsh. `yolobox shell` launches bash directly,
    # bypassing the zsh login shell set above (yolobox has no shell-selection
    # flag), so without this an interactive bash gets none of our aliases /
    # functions / prompt / plugins (all zsh-only under /etc/zsh). Appended to
    # /etc/bash.bashrc, which BOTH interactive login bash (via /etc/profile) and
    # interactive non-login bash source. The `case $- in *i*)` guard fires ONLY
    # for interactive shells — non-interactive `bash -c` (the agent's tool calls,
    # the claude shim, scripts) does not read this file at all and is untouched.
    # `exec` replaces the process so there's no lingering bash. Escape hatch:
    # `NO_ZSH=1 bash` (or any non-interactive bash) stays in bash.
    && printf '%s\n' \
        '' \
        '# Hand interactive bash off to zsh (the configured shell); see Dockerfile.' \
        'case $- in' \
        '  *i*)' \
        '    if [ -z "$ZSH_VERSION" ] && [ -z "$NO_ZSH" ] && [ -x /usr/bin/zsh ]; then' \
        '      export SHELL=/usr/bin/zsh' \
        '      exec /usr/bin/zsh -l' \
        '    fi' \
        '    ;;' \
        'esac' \
        >> /etc/bash.bashrc

# SHELL=/bin/zsh exposes the chosen interactive shell to subprocesses (tmux,
# git, sub-shells) so they pick zsh as well.
# LC_NUMERIC=C keeps R / packaging / scripts using `.` as decimal separator
# regardless of LANG. Set at the Docker layer so even non-interactive shells
# (Rscript invoked from cron, scripts launched via `zsh -c`) inherit it; the
# .zshrc also exports it as a belt-and-braces for shells that bypass ENV.
# STARSHIP_CONFIG points starship at the system-wide /etc/starship.toml composed
# above, so the prompt config survives the home-volume mount over /home/yolo.
ENV SHELL=/bin/zsh \
    LC_NUMERIC=C \
    STARSHIP_CONFIG=/etc/starship.toml

# Restore the unprivileged default user from the upstream image so containers
# launched from this image keep dropping privileges by default.
USER yolo
WORKDIR /home/yolo