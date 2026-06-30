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
    # Locale data. The system default stays C.UTF-8 (inherited LANG/LC_ALL); we
    # additionally GENERATE en_US.UTF-8 below so it is AVAILABLE for tools/users
    # that explicitly request it (e.g. `LANG=en_US.UTF-8 some-cmd`), without
    # making it the default. Generating an ungenerated locale would otherwise
    # fail at use time with "Cannot set LC_* to default locale".
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
    # libmagick++-dev: ImageMagick C++ headers + runtime libs for the R `magick`
    # package, a hard dependency of `vistool` (installed from GitHub in
    # install_packages.R). magick dynamically links libMagick++ at namespace-load
    # time, so without this `library(vistool)` fails with a shared-object error.
    libmagick++-dev \
    # gsfonts: Ghostscript/URW base fonts — magick's declared SystemRequirements.
    # A soft dep (magick loads without it), but it's what ImageMagick falls back to
    # for PostScript/PDF text rendering. pak used to auto-install it as part of the
    # vistool solve; since vistool now installs via `remotes` (which does NOT
    # resolve system requirements), we install it explicitly here to keep parity.
    gsfonts \
    && rm -rf /var/lib/apt/lists/*

# Headless Chromium for the R webshot2/chromote stack, which `vistool` uses to
# rasterize htmlwidgets/plotly to static images. This is a runtime-only dep: vistool
# loads without it, but the screenshot feature launches a browser on demand.
#
# Why this PPA and not apt/Chrome: Ubuntu noble ships no usable chromium .deb
# (`chromium`/`chromium-browser` are snap stubs that don't run in a container), and
# Google Chrome has no arm64 Linux build — either would break our multi-arch build.
# The xtradeb PPA publishes a real chromium .deb for BOTH amd64 and arm64 on noble,
# so it is the one apt-native multi-arch option. As a third-party source it floats
# outside the PPM date pin (same caveat as vistool itself). We do NOT install
# chromium-driver: chromote drives the browser over the DevTools protocol, not via
# chromedriver. CHROMOTE_CHROME pins the binary so chromote skips auto-discovery.
RUN apt-get update \
    && apt-get install -y --no-install-recommends software-properties-common \
    && add-apt-repository -y ppa:xtradeb/apps \
    && apt-get update \
    && apt-get install -y --no-install-recommends chromium \
    # software-properties-common was only needed to run add-apt-repository; purge
    # it and its now-orphaned python3-* deps so they don't bloat the final image.
    # The PPA list + key it wrote (under sources.list.d/ and trusted.gpg.d/)
    # persist, so chromium stays installable in derived images / at runtime; and
    # chromium itself is manually installed, so --auto-remove won't touch it.
    && apt-get purge -y --auto-remove software-properties-common \
    && rm -rf /var/lib/apt/lists/* \
    && chromium --version
ENV CHROMOTE_CHROME=/usr/bin/chromium

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
# The key is scoped via [signed-by=...] so it authenticates ONLY the CRAN repo
# (modern apt practice, matching the charm.sh block below), rather than dropping
# it into trusted.gpg.d where it would be trusted for every repo system-wide.
RUN install -d -m 0755 /etc/apt/keyrings \
    && curl -fsSL https://cloud.r-project.org/bin/linux/ubuntu/marutter_pubkey.asc \
        -o /etc/apt/keyrings/cran_ubuntu_key.asc \
    && echo "deb [signed-by=/etc/apt/keyrings/cran_ubuntu_key.asc] https://cloud.r-project.org/bin/linux/ubuntu noble-cran40/" \
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

# Claude Code is INHERITED from the base finbarr/yolobox image as-is — no
# reinstall, launch shim, host<->box bridge, version check, or updater pinning.
# The self-updater is left ENABLED, so the in-box `claude` floats on the
# persistent /home/yolo volume and may drift from the image's version (accepted;
# add `ENV DISABLE_AUTOUPDATER=1` to pin). Isolation is host-side via the yolobox
# config.toml `claude_config` flag, not here. See README "Claude Code".

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

# System-wide git config for every user (root + yolo): delta pager wiring plus a
# couple of behavior tweaks (init.defaultBranch, pull.rebase, merge.conflictStyle).
# Shipped as a standalone file (like the zsh dotfiles) instead of a stack of
# `git config --system` commands. See yolobox/gitconfig for the documented
# contents. Users can still override anything in their own ~/.gitconfig.
COPY gitconfig /etc/gitconfig

# Ship the interactive shell + prompt config SYSTEM-WIDE (under /etc), NOT into
# /home/yolo. At runtime yolobox bind-mounts a persistent home volume over
# /home/yolo, which shadows any dotfile baked into the image's home — so a baked
# ~/.zshrc / ~/.zsh_aliases / ~/.config/starship.toml would silently never load.
# Installing under /etc keeps them effective regardless of the volume:
#   /etc/zsh/zshrc.d/10-slds.zsh — interactive behavior, plugin wiring, prompt
#   /etc/zsh/zsh_aliases         — ls/grep colors, R alias
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
    # Suppress zsh's built-in new-user wizard (`zsh-newuser-install`). zsh fires
    # it for any interactive shell whose user has NONE of ~/.zshenv ~/.zprofile
    # ~/.zshrc ~/.zlogin. yolobox mounts an EMPTY persistent volume over
    # /home/yolo at runtime, shadowing any dotfile we bake into the image, so on
    # first launch zsh sees a "new user" and prompts the wizard. No config edit
    # disables it — zsh requires an actual startup file in $HOME — so seed an
    # empty ~/.zshrc live from /etc/zsh/zshenv (sourced FIRST, before the wizard
    # check). Guarded: only for interactive shells, and never clobbers a real
    # user ~/.zshrc. All real config stays system-wide in /etc/zsh; this stub is
    # just the user's personal override point (sourced after the system zshrc).
    && printf '\n# Seed an empty ~/.zshrc on first interactive start so zsh-newuser-install\n# does not prompt on the empty /home/yolo volume (see Dockerfile). Never\n# clobbers a real user file; all system config lives in /etc/zsh.\n[[ -o interactive && ! -e ${ZDOTDIR:-$HOME}/.zshrc ]] && : > ${ZDOTDIR:-$HOME}/.zshrc 2>/dev/null\n' >> /etc/zsh/zshenv \
    # Compose the starship prompt config: the plain-text-symbols preset (no Nerd
    # Font required) deep-merged with starship-extra.toml (our format /
    # directory / cmd_duration overrides). We must MERGE, not `cat`: both files
    # define a `[directory]` table (the preset sets `read_only`, our extra sets
    # truncation), and two `[directory]` headers in one file is a TOML
    # `duplicate key` error that makes starship reject the WHOLE config and fall
    # back to its default prompt. `yq` (installed above) deep-merges the tables
    # so colliding sections fold into one. Written to /etc so the home-volume
    # mount can't shadow it; surfaced to starship via ENV STARSHIP_CONFIG below.
    && starship preset plain-text-symbols -o /tmp/starship-base.toml \
    && yq eval-all -p toml -o toml 'select(fileIndex==0) * select(fileIndex==1)' \
        /tmp/starship-base.toml /tmp/starship-extra.toml > /etc/starship.toml \
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
    # scripts) does not read this file at all and is untouched.
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

# ── Image build metadata ─────────────────────────────────────────────────────
# Stamp build provenance into the image so the version numbers worth comparing
# are actually recoverable later: WHICH commit this SLDS image was built from,
# WHEN, and WHICH upstream finbarr/yolobox base it was layered on. Without this
# the base digest is unknowable after the fact (the `FROM` tag floats and the
# built image records nothing about what `:latest` resolved to). yolobox-doctor.sh
# surfaces these (in-box from the ENV below, on the host via `docker image
# inspect`). CI fills the args in (see .github/workflows/docker-yolobox.yml);
# all default to "unknown" so a plain `docker build yolobox` — no buildx, no CI —
# still succeeds.
#   SLDS_IMAGE_REVISION — git commit this image was built from (the SLDS version)
#   SLDS_IMAGE_CREATED  — RFC3339 build timestamp
#   SLDS_BASE_IMAGE     — upstream base ref (must match the FROM line at top)
#   SLDS_BASE_DIGEST    — that base's immutable digest, resolved at build time
# Declared LAST on purpose: these args change on every build, so keeping them
# below all the heavy RUN layers means a metadata-only change rebuilds just this
# tiny ENV/LABEL layer instead of busting the whole cache.
ARG SLDS_IMAGE_REVISION=unknown
ARG SLDS_IMAGE_CREATED=unknown
ARG SLDS_BASE_IMAGE=ghcr.io/finbarr/yolobox:latest
ARG SLDS_BASE_DIGEST=unknown
# ENV: the in-box read path. A running container cannot inspect its OWN image's
# labels without the container runtime (which the box does not get), but ENV
# baked here is always present in the container's environment, so the doctor can
# read it directly inside the box.
ENV SLDS_IMAGE_REVISION=${SLDS_IMAGE_REVISION} \
    SLDS_IMAGE_CREATED=${SLDS_IMAGE_CREATED} \
    SLDS_BASE_IMAGE=${SLDS_BASE_IMAGE} \
    SLDS_BASE_DIGEST=${SLDS_BASE_DIGEST}
# LABELs: the host read path — standard OCI keys surfaced by `docker image
# inspect`. org.opencontainers.image.base.{name,digest} are the OCI-blessed way
# to record the upstream base an image derives from.
LABEL org.opencontainers.image.title="slds-yolobox" \
      org.opencontainers.image.source="https://github.com/slds-lmu/wintermute-docker" \
      org.opencontainers.image.revision="${SLDS_IMAGE_REVISION}" \
      org.opencontainers.image.created="${SLDS_IMAGE_CREATED}" \
      org.opencontainers.image.base.name="${SLDS_BASE_IMAGE}" \
      org.opencontainers.image.base.digest="${SLDS_BASE_DIGEST}"

# Restore the unprivileged default user from the upstream image so containers
# launched from this image keep dropping privileges by default.
USER yolo
WORKDIR /home/yolo