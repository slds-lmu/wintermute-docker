#!/bin/sh
# yolobox-doctor.sh — OS-independent diagnostic for the SLDS yolobox setup.
#
# Purpose
#   A read-only "where am I stuck?" report that ANY user, on ANY OS, can run
#   and paste back for debugging. It does NOT fix anything and NEVER mutates
#   state (no installs, no writes) unless --write-probe is passed explicitly.
#   It replaces ad-hoc live-debugging on N machines with one reproducible
#   report whose checks are identical everywhere.
#
# Two contexts, auto-detected
#   HOST  (yolobox binary lives here): checks prerequisites that decide whether
#         a box will even launch and bridge correctly — runtime, config.toml,
#         the host-side mount sources, and shell-script line endings (the
#         classic Windows/CRLF trap).
#   IN-BOX ($YOLOBOX set): verifies the launch shim actually ran and the live
#         host bridge resolved — the symlinks, the plugin compat link, the real
#         claude entry point, and the core tool stack.
#
# Checks performed (this is the integration-test surface)
#   HOST mode:
#     - yolobox binary present on PATH (+ version)
#     - a container runtime reachable (docker/podman/apple 'container'; daemon up;
#       off Linux, a reminder it must run Linux containers / WSL2 backend)
#     - config.toml present; key settings echoed (claude_config, image, harness)
#     - every mount SOURCE in config.toml exists on the host (missing source =
#       silent dead bridge — the #1 failure we keep hitting)
#     - host ~/.claude bridge state present (projects / history.jsonl / creds)
#     - shell scripts are LF, not CRLF (the Windows 'bad interpreter' trap)
#   IN-BOX mode:
#     - running as the unprivileged 'yolo' user
#     - claude launch chain resolves on PATH; /usr/local/bin/claude IS the shim;
#       the real Claude Code entry point exists (mirrors the shim's own probe)
#     - LIVE host bridge: projects / history.jsonl / .credentials.json are
#       symlinks to their /host-claude-* mounts (else writes are lost on teardown)
#     - session resume readiness: transcripts are reachable through the bridge,
#       the current project has resumable *.jsonl, and the newest one is valid
#       JSONL (preconditions for `claude --resume`; we don't invoke it)
#     - --write-probe (opt-in): a sentinel written in-box actually appears on the
#       host through the sessions bridge
#     - plugin path fixup: the host-prefix compat symlink resolves; sudo available
#     - core tool stack on PATH (R, node, git, rg, jq, …), ~/.local/bin first,
#       LC_NUMERIC=C
#   BOTH modes (inventory, never affects exit code):
#     - Docker image identity: the SLDS image's build revision/date and the
#       upstream finbarr/yolobox base digest it was layered on (in-box from the
#       baked SLDS_* env; on the host via `docker image inspect`)
#     - print the global yolobox config.toml verbatim
#     - list installed Claude Code plugins (+ scope) and their marketplaces
#     - list skills available to Claude Code (standalone + currently-installed
#       plugin versions)
#
# NOT covered here (would need a real container runtime / a harness):
#   actually launching a box, building the image, or exercising Claude end-to-end.
#   This script tests the SETUP/CONTRACT around the box, not a running agent.
#
# Portability
#   POSIX sh only (runs under dash on WSL2-Ubuntu, bash 3.2 on macOS, busybox
#   ash, …). No bashisms, no `local`, no `echo -e`, no `readlink -f` (macOS
#   lacks it). Colour is used only on a TTY.
#
# Exit status
#   0 = no FAIL (WARN is allowed),  1 = at least one FAIL.
#
# Usage
#   sh scripts/yolobox-doctor.sh            # auto-detect host vs in-box
#   sh scripts/yolobox-doctor.sh --write-probe   # in-box: also test write-through
#                                                 # to the host (writes+removes a
#                                                 # sentinel under the bridge)
set -u

# ── Options ──────────────────────────────────────────────────────────────────
WRITE_PROBE=0
for arg in "$@"; do
  case "$arg" in
    --write-probe) WRITE_PROBE=1 ;;
    -h|--help)
      printf 'Usage: sh yolobox-doctor.sh [--write-probe]\n'
      printf '  --write-probe  in-box only: verify host write-through (writes a sentinel)\n'
      exit 0 ;;
    *) printf 'yolobox-doctor: unknown argument: %s\n' "$arg" >&2; exit 2 ;;
  esac
done

# ── Reporting helpers ─────────────────────────────────────────────────────────
# Colour only when stdout is a terminal, so pasted reports stay clean.
if [ -t 1 ]; then
  C_GREEN=$(printf '\033[32m'); C_YELLOW=$(printf '\033[33m')
  C_RED=$(printf '\033[31m');   C_BLUE=$(printf '\033[36m')
  C_BOLD=$(printf '\033[1m');   C_OFF=$(printf '\033[0m')
else
  C_GREEN=; C_YELLOW=; C_RED=; C_BLUE=; C_BOLD=; C_OFF=
fi

PASS_N=0; WARN_N=0; FAIL_N=0
FIRST_FAIL=""   # captured to build the "most likely stuck here" hint

section() { printf '\n%s== %s ==%s\n' "$C_BOLD" "$1" "$C_OFF"; }
pass()    { PASS_N=$((PASS_N+1)); printf '  %s[PASS]%s %s\n' "$C_GREEN" "$C_OFF" "$1"; }
info()    { printf '  %s[INFO]%s %s\n' "$C_BLUE" "$C_OFF" "$1"; }
warn()    { WARN_N=$((WARN_N+1)); printf '  %s[WARN]%s %s\n' "$C_YELLOW" "$C_OFF" "$1"; }
fail()    {
  FAIL_N=$((FAIL_N+1))
  [ -z "$FIRST_FAIL" ] && FIRST_FAIL="$1"
  printf '  %s[FAIL]%s %s\n' "$C_RED" "$C_OFF" "$1"
}

have() { command -v "$1" >/dev/null 2>&1; }

# Read a symlink's immediate target portably (macOS readlink has no -f).
linktarget() { readlink "$1" 2>/dev/null; }

# Strip ANSI colour escape sequences from stdin. Some tools (e.g. yolobox)
# emit colour codes unconditionally — even when their output is piped, not a
# TTY — which would otherwise litter a captured/pasted report.
strip_ansi() {
  _esc=$(printf '\033')
  sed "s/${_esc}\[[0-9;]*m//g"
}

# Claude Code version baked into THIS environment, read from the installed npm
# package's package.json (the reliable source — `claude --version` would need to
# launch the wrapped binary). Prints the bare version or nothing.
cc_pkg_version() {
  pj=/usr/local/lib/node_modules/@anthropic-ai/claude-code/package.json
  [ -f "$pj" ] || return 0
  if have jq; then jq -r '.version // empty' "$pj" 2>/dev/null
  else grep -m1 '"version"' "$pj" 2>/dev/null | sed -E 's/.*"version"[^"]*"([^"]+)".*/\1/'
  fi
}

# Friendly one-line OS identification, portable across the targets we support.
# `uname -s` gives the kernel family; we refine it per family into a name a human
# recognizes (distro + version on Linux, product version on macOS, WSL/Windows).
detect_os() {
  k=$(uname -s 2>/dev/null || echo unknown)
  case "$k" in
    Linux)
      if [ -r /etc/os-release ]; then
        # PRETTY_NAME, e.g. "Ubuntu 24.04.1 LTS"; strip the surrounding quotes.
        # shellcheck disable=SC1091  # runtime file, not present at lint time
        pretty=$(. /etc/os-release 2>/dev/null; printf '%s' "${PRETTY_NAME:-Linux}")
      else
        pretty="Linux"
      fi
      printf 'Linux (%s)' "$pretty"
      ;;
    Darwin)
      if have sw_vers; then
        printf 'macOS %s (build %s)' \
          "$(sw_vers -productVersion 2>/dev/null)" "$(sw_vers -buildVersion 2>/dev/null)"
      else
        printf 'macOS (Darwin %s)' "$(uname -r 2>/dev/null)"
      fi
      ;;
    CYGWIN*|MINGW*|MSYS*)
      printf 'Windows (%s — POSIX emulation layer)' "$k" ;;
    *)
      printf '%s' "$k" ;;
  esac
}

# ── Environment facts (always) ────────────────────────────────────────────────
section "Environment"
OS=$(uname -s 2>/dev/null || echo unknown)
info "OS: $(detect_os)"
info "uname: $(uname -a 2>/dev/null || echo unknown)"
info "shell: ${SHELL:-?}   (running under: $0)"
info "user:  $(id -un 2>/dev/null || echo ?)   home: ${HOME:-?}"

# WSL detection — the only place "Windows" really shows up for yolobox.
IS_WSL=0
if [ -n "${WSL_DISTRO_NAME:-}" ]; then
  IS_WSL=1; info "WSL: yes (distro: $WSL_DISTRO_NAME)"
elif [ -r /proc/version ] && grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null; then
  IS_WSL=1; info "WSL: yes (detected via /proc/version)"
else
  info "WSL: no"
fi

# Context: in-box if yolobox set the marker, else treat as host.
if [ -n "${YOLOBOX:-}" ]; then
  MODE=inbox; info "context: INSIDE a yolobox container (\$YOLOBOX=$YOLOBOX)"
else
  MODE=host;  info "context: HOST (no \$YOLOBOX) — checking launch prerequisites"
fi

# ── Versions ──────────────────────────────────────────────────────────────────
# Three numbers worth comparing when something misbehaves: the yolobox binary,
# the Claude Code on the host, and the Claude Code baked into the image. No single
# context can see all three (the host doesn't ship the image's binary; the box
# doesn't ship yolobox or the host's binary), so each side reports what it can and
# points at the other for the rest. The image's CC version floats with each
# (no-cache) rebuild, so a host/box mismatch is normal — only a surprise.
#
# HOST: the version numbers belong with "is the launch toolchain here at all?",
# so they're folded into the merged "yolobox & container runtime" section in
# host_checks() below (binary presence + version + Claude versions + runtime in
# one block). Here we only print the IN-BOX version view.
if [ "$MODE" = inbox ]; then
  section "Versions"
  # In-box: the image's Claude Code is the one we can read reliably.
  v=$(cc_pkg_version)
  if [ -n "$v" ]; then info "Claude Code (in box): $v"
  else warn "Claude Code (in box): could not read package.json version"; fi
  info "Claude Code (host): run this doctor on the HOST to read it (claude --version)"
  info "yolobox: binary not present in-box — run this doctor on the HOST for its version"
fi

# =============================================================================
# HOST MODE — will a box launch and bridge at all?
# =============================================================================
host_checks() {
  # ── yolobox & container runtime (the host launch toolchain, with versions) ──
  # One section answering "can this host launch a box, and with what versions?":
  #   (a) the yolobox binary — present on PATH + its own version,
  #   (b) the Claude Code versions worth comparing (host + image pointer),
  #   (c) a working container runtime (present + daemon reachable).
  section "yolobox & container runtime"

  # (a) yolobox binary: presence AND version together.
  # IMPORTANT: `yolobox --version` (with dashes) FORWARDS to the default harness
  # and prints e.g. "2.1.170 (Claude Code)" — that's Claude Code, not yolobox.
  # yolobox's *own* version comes from the `version` SUBCOMMAND (no dashes):
  # `yolobox version` -> "yolobox 0.18.4 (linux/amd64)". We strip its ANSI colour
  # codes (yolobox emits them even when piped) for a clean report.
  if have yolobox; then
    pass "yolobox on PATH: $(command -v yolobox)"
    yb_ver=$(yolobox version 2>/dev/null | head -1 | strip_ansi)
    case "$yb_ver" in
      "") warn "  'yolobox version' printed nothing — a build too old for the 'version' subcommand? check your installer (e.g. 'brew list --versions yolobox')" ;;
      *"Claude Code"*|*"claude"*)
        # A yolobox old enough to lack the 'version' subcommand can forward this too.
        info "  version: $yb_ver"
        warn "  that looks like the forwarded harness version, not yolobox's own — your yolobox likely predates the 'version' subcommand; check your installer (e.g. 'brew list --versions yolobox')" ;;
      *)  info "  version: $yb_ver" ;;
    esac
  else
    fail "yolobox not on PATH — install it, or you're on a machine that only runs the host side via WSL/SSH"
  fi

  # (b) Claude Code versions — host binary (read directly) + image pointer.
  if have claude; then
    info "Claude Code (host): $(claude --version 2>/dev/null | head -1)"
  else
    info "Claude Code (host): 'claude' not on PATH"
  fi
  info "Claude Code (in image): run this doctor IN-BOX to read the shipped version"

  # (c) Container runtime: yolobox needs one to start a box.
  RT=""
  for c in docker podman container; do
    have "$c" && { RT="$c"; break; }
  done
  if [ -z "$RT" ]; then
    fail "no container runtime found (docker / podman / apple 'container') — yolobox cannot start a box"
  else
    pass "runtime present: $RT ($(command -v "$RT"))"
    case "$RT" in
      docker|podman)
        if "$RT" info >/dev/null 2>&1; then
          pass "$RT daemon reachable"
        else
          fail "$RT found but daemon not reachable — start Docker Desktop / the $RT service"
        fi
        # The Windows-specific trap: Linux containers need the WSL2/Linux engine.
        if [ "$IS_WSL" -eq 0 ] && [ "$OS" != "Linux" ] && [ "$OS" != "Darwin" ]; then
          warn "non-Linux host: ensure $RT is in Linux-container mode (WSL2 backend), not Windows containers"
        fi
        ;;
    esac
  fi

  # NOTE: the yolobox config.toml + its bridge mount-source checks, and the
  # "Host Claude state" of those bridge sources, are handled by the unified
  # yolobox_config_section() / host_claude_state() in the COMMON INVENTORY block
  # below — printed right after the config so the mounts and their sources sit
  # together — so they aren't duplicated here.

  # ── Shell-script line endings (CRLF = the Windows killer) ──────────────────
  # If the shim or shell config got CRLF endings (e.g. edited/checked out on
  # Windows), the in-box '#!/bin/bash\r' breaks with 'bad interpreter'.
  section "Shell-script line endings"
  REPO=""
  for d in . .. "$(dirname "$0")/.." ; do
    [ -f "$d/yolobox/claude-launch-shim.sh" ] && { REPO=$d; break; }
  done
  if [ -n "$REPO" ]; then
    crlf=0
    for f in "$REPO"/yolobox/*.sh "$REPO"/yolobox/zshrc "$REPO"/yolobox/zsh_aliases; do
      [ -f "$f" ] || continue
      if LC_ALL=C grep -q "$(printf '\r')" "$f" 2>/dev/null; then
        fail "CRLF line endings in $f — will break in-box with 'bad interpreter'. Re-checkout as LF / add .gitattributes."
        crlf=1
      fi
    done
    [ "$crlf" -eq 0 ] && pass "shell scripts use LF endings"
  else
    info "repo not found from CWD — skipping line-ending check (run from the repo to enable)"
  fi
}

# =============================================================================
# IN-BOX MODE — did the shim run and the bridge resolve?
# =============================================================================
inbox_checks() {
  # ── Identity ──────────────────────────────────────────────────────────────
  section "Container identity"
  if [ "$(id -un 2>/dev/null)" = "yolo" ]; then pass "running as 'yolo'"
  else warn "not running as 'yolo' (user: $(id -un 2>/dev/null))"; fi

  # ── claude launch chain ─────────────────────────────────────────────────
  # Portable "all matches on PATH" scan (POSIX has no `command -v -a`).
  section "claude launch chain"
  n=0
  IFS_SAVE=$IFS; IFS=:
  for d in $PATH; do
    [ -n "$d" ] || d=.
    if [ -x "$d/claude" ]; then info "claude on PATH: $d/claude"; n=$((n+1)); fi
  done
  IFS=$IFS_SAVE
  if [ "$n" -ge 1 ]; then
    pass "claude resolves on PATH ($n match(es); the SLDS chain expects 3)"
  else
    fail "claude not on PATH"
  fi
  if [ -f /usr/local/bin/claude ] && grep -q 'claude-launch-shim' /usr/local/bin/claude 2>/dev/null; then
    pass "shim installed at /usr/local/bin/claude"
  else
    fail "/usr/local/bin/claude is not the launch shim — bridge will not be applied"
  fi
  # Replicate the shim's entry-point probe so a future upstream rename surfaces.
  PKG=/usr/local/lib/node_modules/@anthropic-ai/claude-code
  REAL=""
  for cand in "$PKG/cli.js" "$PKG/bin/claude.exe" "$PKG/bin/claude" "$PKG/claude"; do
    [ -f "$cand" ] && { REAL=$cand; break; }
  done
  if [ -n "$REAL" ]; then pass "real Claude Code entry point: $REAL"
  else fail "no Claude Code entry point under $PKG — 'claude' would exit 127"; fi

  # ── Live host bridge (the heart of the matter) ────────────────────────────
  section "Live host bridge"
  # Each pair: container path, its host mount. The shim swaps the snapshot copy
  # for a symlink to the mount IF the mount exists.
  check_bridge() {
    cpath=$1; mount=$2; label=$3
    if [ ! -e "$mount" ]; then
      warn "$label: host mount $mount ABSENT — bridge is a no-op. Did you enter via 'yolobox shell' instead of a 'claude' launch, or is the config.toml mount missing?"
      return
    fi
    tgt=$(linktarget "$cpath")
    if [ -L "$cpath" ] && [ "$tgt" = "$mount" ]; then
      pass "$label: $cpath -> $mount (live, two-way)"
    elif [ -L "$cpath" ]; then
      warn "$label: $cpath is a symlink but points to '$tgt' (expected $mount)"
    else
      # Mount exists but the path is a real file/dir: bridge is INACTIVE. State
      # the symptom, not a guessed cause (the shim may not have run for this
      # launch, or its boot-time symlink was later replaced by a snapshot copy).
      kind="file"; [ -d "$cpath" ] && kind="directory"
      fail "$label: $cpath is a real $kind, not a symlink to $mount — bridge INACTIVE (writes won't reach the host / lost on teardown)"
    fi
  }
  check_bridge "$HOME/.claude/projects"         /host-claude-sessions        "sessions+memory"
  check_bridge "$HOME/.claude/history.jsonl"    /host-claude-history.jsonl   "prompt history"
  check_bridge "$HOME/.claude/.credentials.json" /host-claude-credentials.json "credentials"

  # ── Session resume readiness ──────────────────────────────────────────────
  # `claude --resume` lists prior sessions from ~/.claude/projects/<mangled-cwd>/
  # *.jsonl. (This is exactly why the bridge lives in the shim, not a SessionStart
  # hook: --resume reads these files before any hook fires.) We can't safely run
  # --resume here — it needs credentials, makes an API call, and appends to a
  # transcript — so we verify its PRECONDITIONS read-only: the sessions store is
  # reachable, holds transcripts, and the current project has resumable ones.
  # Claude derives the project dir by replacing every non-alphanumeric character
  # of the absolute cwd with '-' (verified: '/home/bischl/cos/.x' -> '...cos--x').
  section "Session resume readiness"
  proj="$HOME/.claude/projects"
  if [ ! -e "$proj" ]; then
    fail "no $proj — 'claude --resume' has nothing to read"
  else
    # Total transcripts reachable through the store (follow the bridge symlink).
    total=$(find -L "$proj" -name '*.jsonl' 2>/dev/null | grep -c .)
    if [ "$total" -gt 0 ]; then
      pass "$total session transcript(s) reachable via $proj (resume can list sessions)"
    else
      warn "no *.jsonl transcripts under $proj — nothing to resume yet (expected on a fresh setup)"
    fi

    # Current-project resumability: does a dir match this cwd, with transcripts?
    mangled=$(printf '%s' "$PWD" | sed 's#[^A-Za-z0-9]#-#g')
    pdir="$proj/$mangled"
    if [ -d "$pdir" ]; then
      pc=$(find -L "$pdir" -maxdepth 1 -name '*.jsonl' 2>/dev/null | grep -c .)
      if [ "$pc" -gt 0 ]; then
        pass "current project ($PWD): $pc resumable session(s)"
        # Sanity-check the newest transcript: non-empty and valid JSONL (first
        # line parses as JSON), so a truncated/corrupt file is caught, not just
        # counted. Pick newest by mtime portably via ls -t.
        # ls -t is the portable "newest by mtime" (BSD find has no -printf);
        # transcript names are UUIDs, so no whitespace-globbing risk here.
        # shellcheck disable=SC2012
        newest=$(ls -t "$pdir"/*.jsonl 2>/dev/null | head -1)
        if [ -n "$newest" ] && [ -s "$newest" ]; then
          if head -1 "$newest" 2>/dev/null | { have jq && jq -e . >/dev/null 2>&1 \
               || grep -q '^[[:space:]]*{'; }; then
            pass "newest transcript parses as JSONL ($(basename "$newest"))"
          else
            fail "newest transcript is not valid JSONL ($(basename "$newest")) — resume may fail to load it"
          fi
        else
          warn "newest transcript for this project is empty"
        fi
      else
        warn "project dir exists but has no transcripts: $pdir"
      fi
    else
      info "no sessions recorded for this project ($PWD) yet — resume would show nothing here"
    fi
  fi

  # Optional: prove writes actually reach the host (opt-in; writes a sentinel).
  if [ "$WRITE_PROBE" -eq 1 ]; then
    section "Write-through probe"
    if [ -L "$HOME/.claude/projects" ] && [ -d "$HOME/.claude/projects" ]; then
      sentinel="$HOME/.claude/projects/.yolobox-doctor-probe.$$"
      if ( : > "$sentinel" ) 2>/dev/null && [ -e "/host-claude-sessions/.yolobox-doctor-probe.$$" ]; then
        pass "write reached host (/host-claude-sessions) — bridge is genuinely two-way"
        rm -f "$sentinel" 2>/dev/null
      else
        fail "wrote to ~/.claude/projects but it did not appear under /host-claude-sessions"
        rm -f "$sentinel" 2>/dev/null
      fi
    else
      warn "skipped: sessions bridge not active, nothing to probe"
    fi
  fi

  # ── Plugin compat ─────────────────────────────────────────────────────────
  section "Plugins"
  plugdir="$HOME/.claude/plugins"
  if [ -d "$plugdir" ]; then
    pass "plugin dir present: $plugdir"
    # The host prefix recorded in the registry; the shim makes it resolve via a
    # sudo-created compat symlink.
    hp=$(grep -hoE '"/[^"]*/\.claude/plugins' \
          "$plugdir/installed_plugins.json" "$plugdir/known_marketplaces.json" 2>/dev/null \
          | sed -E 's#^"##; s#/\.claude/plugins$##' | grep -vx "$HOME" | head -1)
    if [ -n "$hp" ]; then
      if [ -e "$hp/.claude/plugins" ]; then
        pass "host-path compat link resolves: $hp/.claude/plugins"
      else
        warn "registry references host prefix $hp but $hp/.claude/plugins does not resolve (sudo unavailable at launch? plugins may not load if a future Claude honors absolute paths)"
      fi
    else
      info "no foreign host prefix in registry (already \$HOME, or no plugins installed)"
    fi
    if sudo -n true 2>/dev/null; then info "passwordless sudo available (compat symlink can be created)"
    else warn "no passwordless sudo — plugin compat symlink falls back to registry-rewrite only"; fi
  else
    info "no plugins installed (nothing to fix up)"
  fi

  # ── Core tool stack ─────────────────────────────────────────────────────
  section "Tool stack"
  for t in R Rscript node npm git rg jq; do
    if have "$t"; then pass "$t: $(command -v "$t")"; else warn "$t not found on PATH"; fi
  done
  case ":${PATH}:" in
    *":$HOME/.local/bin:"*) pass "$HOME/.local/bin on PATH" ;;
    *) warn "$HOME/.local/bin not on PATH (user-scope installs won't win)" ;;
  esac
  if [ "${LC_NUMERIC:-}" = "C" ]; then pass "LC_NUMERIC=C (decimal '.' for R)"
  else warn "LC_NUMERIC is '${LC_NUMERIC:-unset}' (expected C)"; fi
}

# =============================================================================
# COMMON INVENTORY — runs in BOTH modes
#   These describe the Claude Code config the box runs with: the global yolobox
#   config.toml, plus the skills and plugins available to Claude Code in the box.
#   INFO/PASS/WARN only, no FAILs — so this block never affects the exit code.
# =============================================================================

# ── Docker image identity (the SLDS image + the upstream base it builds on) ───
# Reports the version numbers worth knowing for the image itself: which SLDS
# commit it was built from, when, and which finbarr/yolobox base digest it was
# layered on. These are baked by the Dockerfile's "Image build metadata" block.
# Two read paths, because no single context can do both:
#   IN-BOX: the SLDS_* values are baked as ENV, hence always in the container
#           environment — read straight from there (the box has no runtime to
#           inspect its own image's labels).
#   HOST:   the box isn't running here, so inspect the configured image ref with
#           docker/podman — the same values live as ENV + OCI labels — and also
#           show the local image's own digest and creation time.
# Informational only (never a FAIL). "unknown"/absent simply means the image
# predates this metadata or was built locally without the build-args.
docker_image_section() {
  section "Docker image"

  if [ "$MODE" = inbox ]; then
    rev=${SLDS_IMAGE_REVISION:-}; created=${SLDS_IMAGE_CREATED:-}
    base=${SLDS_BASE_IMAGE:-};    bdig=${SLDS_BASE_DIGEST:-}
    if [ -n "$rev$created$base$bdig" ]; then
      info "SLDS image revision: ${rev:-unknown}"
      info "SLDS image built:    ${created:-unknown}"
      info "built on base:       ${base:-unknown}${bdig:+ @ }${bdig}"
    else
      info "no build metadata baked (SLDS_* env unset) — image predates it or was built locally without build-args"
    fi
    return 0
  fi

  # HOST: resolve the configured image ref (from config.toml `image =`, else the
  # published default) and inspect it locally.
  img_ref=""
  for c in "${XDG_CONFIG_HOME:-$HOME/.config}/yolobox/config.toml" \
           "$HOME/.config/yolobox/config.toml"; do
    [ -f "$c" ] || continue
    img_ref=$(grep -E '^[[:space:]]*image[[:space:]]*=' "$c" 2>/dev/null | head -1 \
              | sed -E 's/.*=[[:space:]]*"?([^"#]+)"?.*/\1/; s/[[:space:]]*$//')
    break
  done
  [ -n "$img_ref" ] || img_ref="ghcr.io/slds-lmu/slds-yolobox:latest"
  info "configured image: $img_ref"

  rt=""
  for c in docker podman; do have "$c" && { rt=$c; break; }; done
  if [ -z "$rt" ]; then
    info "no docker/podman on host — cannot inspect the image; run this doctor IN-BOX to read the baked SLDS_* metadata"
    return 0
  fi
  if ! "$rt" image inspect "$img_ref" >/dev/null 2>&1; then
    info "image not present locally ($img_ref) — pull it (or launch a box) first; nothing to inspect"
    return 0
  fi

  # Local identity of the cached image (independent of our baked metadata).
  ldig=$("$rt" image inspect --format '{{if .RepoDigests}}{{index .RepoDigests 0}}{{end}}' "$img_ref" 2>/dev/null)
  lcreated=$("$rt" image inspect --format '{{.Created}}' "$img_ref" 2>/dev/null)
  if [ -n "$ldig" ]; then info "local image digest:  $ldig"; else info "local image digest:  <none recorded>"; fi
  [ -n "$lcreated" ] && info "local image created: $lcreated"

  # Baked SLDS_* provenance — read from ENV so it works regardless of label
  # support; one inspect, then pick the fields out.
  envdump=$("$rt" image inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$img_ref" 2>/dev/null)
  rev=$(printf '%s\n' "$envdump" | sed -n 's/^SLDS_IMAGE_REVISION=//p' | head -1)
  created=$(printf '%s\n' "$envdump" | sed -n 's/^SLDS_IMAGE_CREATED=//p' | head -1)
  base=$(printf '%s\n' "$envdump" | sed -n 's/^SLDS_BASE_IMAGE=//p' | head -1)
  bdig=$(printf '%s\n' "$envdump" | sed -n 's/^SLDS_BASE_DIGEST=//p' | head -1)
  if [ -n "$rev$created$base$bdig" ]; then
    info "SLDS image revision: ${rev:-unknown}"
    info "SLDS image built:    ${created:-unknown}"
    info "built on base:       ${base:-unknown}${bdig:+ @ }${bdig}"
  else
    info "no SLDS_* build metadata on this image — predates it or was built without the build-args"
  fi
}

# ── yolobox config.toml — locate, validate mounts (host), dump verbatim ───────
# ONE section for everything about the global yolobox config (we used to split
# "yolobox config" + "Mount sources" + a separate verbatim "Global config" dump).
# The config is a HOST-side file (~/.config/yolobox/config.toml), normally NOT
# mounted into the box — so in-box this usually reports it absent and points you
# at the host; that's expected, not a failure. On the HOST it additionally
# validates the bridge mount sources before printing the file as reference.
yolobox_config_section() {
  section "yolobox config (config.toml)"
  cfg=""
  for c in "${XDG_CONFIG_HOME:-$HOME/.config}/yolobox/config.toml" \
           "$HOME/.config/yolobox/config.toml"; do
    [ -f "$c" ] && { cfg=$c; break; }
  done

  if [ -z "$cfg" ]; then
    if [ "$MODE" = inbox ]; then
      info "not mounted in-box — it's a host-side file; run this on the host to print it"
    else
      warn "no config.toml at the standard path — yolobox is using upstream defaults (no SLDS bridge mounts)"
    fi
    return 0
  fi
  pass "config found: $cfg"

  # HOST only: verify each mount's HOST source exists. A missing source is the #1
  # silent cause of "the bridge does nothing" — docker creates the missing source
  # as an empty dir, so it mounts empty in-box and the shim silently no-ops.
  if [ "$MODE" = host ]; then
    info "Mount sources: each 'mounts' entry is host_path:container_path — we check the"
    info "HOST side (left of ':') exists, since a missing source mounts as empty in-box"
    info "and silently kills the bridge it feeds."
    # Keep the whole "host:container" mapping so we can show source AND target.
    mounts=$(awk '
      /mounts[[:space:]]*=/        { inm=1 }
      inm && /"[^"]+"/ {
        s=$0
        while (match(s, /"[^"]+"/)) {
          q=substr(s, RSTART+1, RLENGTH-2)
          if (q ~ /:/) { print q }
          s=substr(s, RSTART+RLENGTH)
        }
      }
      inm && /\]/                  { inm=0 }
    ' "$cfg" 2>/dev/null)
    if [ -z "$mounts" ]; then
      warn "no mounts parsed from config — bridge mounts may be absent (shim becomes a no-op in-box)"
    else
      echo "$mounts" | while IFS= read -r entry; do
        [ -z "$entry" ] && continue
        src=${entry%%:*}        # host path (what we test)
        tgt=${entry#*:}         # container path it's mounted at
        if [ -e "$src" ]; then
          pass "host source exists: $src  → in-box: $tgt"
        else
          warn "host source MISSING: $src  → in-box: $tgt  (mounts as empty in-box → bridge no-op)"
        fi
      done
    fi
  fi

  # Both modes: print the file verbatim as reference, indented so it stands out.
  info "full contents:"
  sed 's/^/    | /' "$cfg"
}

# ── Host Claude state the bridge SOURCES from (host only) ──────────────────────
# The bridge mounts above bind three HOST paths under ~/.claude into the box; the
# launch shim then symlinks the box's ~/.claude entries onto those mounts. This
# checks the HOST end of that chain: do those three source paths actually exist
# as real Claude state on this machine? (Distinct from the mount-source check
# above, which reads them out of config.toml — here we name each by its ROLE and
# say what breaks in-box if it's missing.) An absent source isn't a hard error —
# Claude creates it on first use — but until it exists its bridge carries nothing.
# Printed right after the config so each mount sits next to the state it feeds.
host_claude_state() {
  section "Host Claude state (bridge sources)"
  info "The three host-side ~/.claude paths the live bridge maps into the box."
  info "If a path is absent here, its bridge has nothing to surface in-box (and"
  info "nothing to persist back) until Claude first creates it on the host."
  _hcs() {  # path, role, what's lost if missing
    if [ -e "$1" ]; then pass "$2 present: $1"
    else warn "$2 ABSENT: $1  ($3 until it exists on the host)"; fi
  }
  _hcs "$HOME/.claude/projects"          "sessions+memory" "no past sessions or per-project memory in-box"
  _hcs "$HOME/.claude/history.jsonl"     "prompt history"  "no prompt history in-box"
  _hcs "$HOME/.claude/.credentials.json" "credentials"     "box starts logged out → /login"
}

# Emit the installPath of every CURRENTLY-installed plugin, normalized to this
# machine's $HOME (host paths use a different user prefix than the box). Scanning
# only these — not all of plugins/cache — avoids counting stale cached versions.
installed_plugin_paths() {
  reg="$HOME/.claude/plugins/installed_plugins.json"
  [ -f "$reg" ] || return 0
  if have jq; then
    jq -r '.plugins | to_entries[] | .value[] | .installPath' "$reg" 2>/dev/null
  else
    grep -oE '"installPath"[[:space:]]*:[[:space:]]*"[^"]*"' "$reg" 2>/dev/null \
      | sed -E 's/.*"([^"]*)"$/\1/'
  fi | while IFS= read -r ip; do
    [ -n "$ip" ] || continue
    case "$ip" in
      */cache/*) printf '%s/.claude/plugins/cache/%s\n' "$HOME" "${ip#*/cache/}" ;;
      *)         printf '%s\n' "$ip" ;;
    esac
  done
}

# ── List installed plugins + marketplaces ─────────────────────────────────────
list_plugins() {
  section "Claude Code plugins"
  reg="$HOME/.claude/plugins/installed_plugins.json"
  if [ ! -f "$reg" ]; then
    info "no plugin registry ($reg) — no plugins installed"
    return 0
  fi
  n=0
  if have jq; then
    # name@marketplace + scope, one per install entry.
    jq -r '.plugins | to_entries[] | .key as $k | .value[]
           | "\($k)\t[\(.scope)]"' "$reg" 2>/dev/null \
      | while IFS="$(printf '\t')" read -r name scope; do
          info "plugin: $name $scope"
        done
    n=$(jq -r '[.plugins[] | .[]] | length' "$reg" 2>/dev/null)
  else
    grep -oE '"[A-Za-z0-9_.-]+@[A-Za-z0-9_.-]+"[[:space:]]*:' "$reg" 2>/dev/null \
      | sed -E 's/"[[:space:]]*:$//; s/^"//' \
      | while IFS= read -r name; do info "plugin: $name"; done
    n=$(grep -cE '"[A-Za-z0-9_.-]+@[A-Za-z0-9_.-]+"[[:space:]]*:' "$reg" 2>/dev/null)
  fi
  pass "${n:-0} plugin install entr$( [ "${n:-0}" = 1 ] && printf y || printf ies ) registered"

  # Marketplaces the plugins come from.
  mk="$HOME/.claude/plugins/known_marketplaces.json"
  if [ -f "$mk" ]; then
    if have jq; then
      jq -r 'to_entries[] | "\(.key)\t\(.value.source.repo // .value.source.url // "?")"' "$mk" 2>/dev/null \
        | while IFS="$(printf '\t')" read -r name src; do info "marketplace: $name  ($src)"; done
    else
      grep -oE '"[A-Za-z0-9_.-]+":[[:space:]]*\{' "$mk" 2>/dev/null \
        | sed -E 's/":.*//; s/^"//' | while IFS= read -r name; do info "marketplace: $name"; done
    fi
  fi
}

# Canonical skill name from a SKILL.md's YAML frontmatter `name:` field (this is
# the id Claude Code uses); fall back to the containing directory name. Avoids
# the misleading bare dir names of nested skills (e.g. ".../notation/check").
skill_name() {
  _n=$(grep -m1 -E '^name:[[:space:]]*' "$1" 2>/dev/null \
        | sed -E 's/^name:[[:space:]]*//; s/[[:space:]]*$//' | tr -d '"'\''')
  if [ -n "$_n" ]; then printf '%s\n' "$_n"; else basename "$(dirname "$1")"; fi
}

# ── List skills available to Claude Code ──────────────────────────────────────
# Two sources, mirroring how Claude Code discovers them:
#   (1) standalone skills under ~/.claude/skills (dir-scanned, always active)
#   (2) skills bundled in the CURRENTLY-installed plugin versions (installPaths
#       from the registry — NOT a blanket plugins/cache scan, which would also
#       count every stale cached version).
list_skills() {
  section "Claude Code skills"

  # (1) Standalone.
  sn=0
  if [ -d "$HOME/.claude/skills" ]; then
    for d in "$HOME"/.claude/skills/*/; do
      [ -f "${d}SKILL.md" ] || continue
      info "skill (standalone): $(skill_name "${d}SKILL.md")"
      sn=$((sn+1))
    done
  fi

  # (2) Plugin-provided, deduped by canonical name.
  installed_plugin_paths | while IFS= read -r ip; do
    [ -d "$ip" ] && find "$ip" -name SKILL.md 2>/dev/null
  done | while IFS= read -r f; do skill_name "$f"; done | sort -u \
    | while IFS= read -r name; do
        [ -n "$name" ] && info "skill (plugin):     $name"
      done

  # Recount plugin skills for the summary (the pipes above run in subshells, so
  # their counters don't survive — recompute in one shot here).
  pn=$(installed_plugin_paths | while IFS= read -r ip; do
         [ -d "$ip" ] && find "$ip" -name SKILL.md 2>/dev/null
       done | while IFS= read -r f; do skill_name "$f"; done | sort -u | grep -c .)
  pass "${sn} standalone + ${pn:-0} plugin skill(s) available to Claude Code"
}

# ── Dispatch ──────────────────────────────────────────────────────────────────
if [ "$MODE" = "host" ]; then host_checks; else inbox_checks; fi
docker_image_section
yolobox_config_section
[ "$MODE" = "host" ] && host_claude_state   # host-only; right after the config it sources from
list_plugins
list_skills

# ── Summary ───────────────────────────────────────────────────────────────────
section "Summary"
printf '  %s%d pass%s, %s%d warn%s, %s%d fail%s\n' \
  "$C_GREEN" "$PASS_N" "$C_OFF" "$C_YELLOW" "$WARN_N" "$C_OFF" "$C_RED" "$FAIL_N" "$C_OFF"
if [ "$FAIL_N" -gt 0 ]; then
  printf '  %sMost likely stuck here:%s %s\n' "$C_BOLD" "$C_OFF" "$FIRST_FAIL"
  exit 1
fi
[ "$WARN_N" -gt 0 ] && printf '  No hard failures; review the warnings above.\n'
exit 0
