#!/bin/sh
# yolobox-doctor.sh — OS-independent diagnostic for the SLDS yolobox setup.
#
# Purpose
#   A read-only "where am I stuck?" report that ANY user, on ANY OS, can run on
#   the HOST and paste back for debugging. It replaces ad-hoc live-debugging on
#   N machines with one reproducible report whose checks are identical everywhere.
#
# ONE mode: run it from the HOST.
#   This script is always run on the host — that's where the launch toolchain
#   (yolobox binary, container runtime, config.toml) and the real ~/.claude state
#   live, and the host is the only place that can see ALL of it. To check the
#   things that only exist INSIDE the image/container, the host reaches in itself:
#     - `docker image inspect`             — image identity + baked metadata
#     - `docker run --rm --entrypoint sh`  — a throwaway probe container that
#                                            inspects image-intrinsic facts AND
#                                            integration-tests the live bridge
#                                            (mounts attached, symlink swap +
#                                            optional write-through), reproducing
#                                            exactly what the launch shim does.
#   So there is no separate "in-box mode" anymore: you never have to be inside a
#   box to run this. (If it detects it's been started INSIDE a box it says so and
#   continues best-effort, but most checks need the host.)
#
# Checks performed (this is the integration-test surface)
#   Host launch toolchain:
#     - yolobox binary present on PATH (+ its own version via the `version` subcmd)
#     - Claude Code on the host (claude --version)
#     - a container runtime reachable (docker/podman/apple 'container'; daemon up;
#       off Linux, a reminder it must run Linux containers / WSL2 backend)
#   Host config + state:
#     - config.toml present; image ref + mounts parsed; every mount SOURCE exists
#       on the host (a missing source mounts empty in-box = silent dead bridge,
#       the #1 failure we keep hitting); file dumped verbatim as reference
#     - host ~/.claude bridge state present (projects / history.jsonl / creds)
#     - shell scripts are LF, not CRLF (the Windows 'bad interpreter' trap)
#   Image (reached into from the host, runtime permitting):
#     - identity: local digest, created time, OCI labels, baked SLDS_* provenance
#       (the SLDS build revision/date + the finbarr/yolobox base digest)
#     - intrinsic contract via a probe container: default user is 'yolo', the
#       launch shim is installed, the launch-chain links exist, the real Claude
#       Code entry point resolves, the core tool stack is present, LC_NUMERIC=C,
#       and the Claude Code version shipped in the image
#   Live host bridge (integration-tested from the host via the probe container):
#     - each bridge mount attaches and is writable inside the container, the
#       shim's symlink swap resolves (~/.claude/<x> -> /host-claude-*), and with
#       --write-probe a sentinel written in the container actually appears back
#       on the host (genuine two-way proof)
#   Claude Code version: host (claude --version) vs image (probe) — WARN if they
#     differ, since the box shares live state with the host (non-fatal)
#   Inventory (informational, never affects exit code; read from host ~/.claude):
#     - installed Claude Code plugins (+ scope) and their marketplaces
#     - skills available to Claude Code (standalone + currently-installed plugins)
#
# NOT covered here: actually launching a real box end-to-end, or exercising
#   Claude against the API. This tests the SETUP/CONTRACT around the box.
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
#   sh scripts/yolobox-doctor.sh              # full host-side report
#   sh scripts/yolobox-doctor.sh --write-probe  # also prove bridge write-through
#                                               # (writes+removes a host sentinel
#                                               #  via the probe container)
set -u

# ── Options ──────────────────────────────────────────────────────────────────
WRITE_PROBE=0
for arg in "$@"; do
  case "$arg" in
    --write-probe) WRITE_PROBE=1 ;;
    -h|--help)
      printf 'Usage: sh yolobox-doctor.sh [--write-probe]\n'
      printf '  --write-probe  also prove bridge write-through (writes a host sentinel\n'
      printf '                 via the probe container, then removes it)\n'
      exit 0 ;;
    *) printf 'yolobox-doctor: unknown argument: %s\n' "$arg" >&2; exit 2 ;;
  esac
done

# A literal tab, used as the probe protocol's field separator (see run_probe()).
TAB=$(printf '\t')

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
CC_HOST=""      # bare semver of Claude Code on the host (captured below)
CC_IMAGE=""     # bare semver of Claude Code in the image (captured from the probe)

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

# Strip ANSI colour escape sequences from stdin. Some tools (e.g. yolobox) emit
# colour codes unconditionally — even when piped — which would litter a report.
strip_ansi() {
  _esc=$(printf '\033')
  sed "s/${_esc}\[[0-9;]*m//g"
}

# Friendly one-line OS identification, portable across the targets we support.
detect_os() {
  k=$(uname -s 2>/dev/null || echo unknown)
  case "$k" in
    Linux)
      if [ -r /etc/os-release ]; then
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

# ── Environment facts ─────────────────────────────────────────────────────────
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

# This script is host-only now. If we were launched INSIDE a box, say so loudly:
# the host toolchain (yolobox/docker/config.toml) won't be there, so the report
# below will be mostly blanks. We continue best-effort rather than hard-exit.
if [ -n "${YOLOBOX:-}" ]; then
  warn "started INSIDE a yolobox container (\$YOLOBOX=$YOLOBOX) — this doctor is host-only now; re-run it on the HOST for a meaningful report"
else
  info "context: HOST — this is where the doctor is meant to run"
fi

# =============================================================================
# Host launch toolchain — can this host launch a box, and with what versions?
# =============================================================================
section "yolobox & container runtime"

# yolobox binary: presence AND version together.
# IMPORTANT: `yolobox --version` (with dashes) FORWARDS to the default harness
# and prints e.g. "2.1.170 (Claude Code)" — that's Claude Code, not yolobox.
# yolobox's *own* version comes from the `version` SUBCOMMAND (no dashes):
# `yolobox version` -> "yolobox 0.18.4 (linux/amd64)". Strip its ANSI colour.
if have yolobox; then
  pass "yolobox on PATH: $(command -v yolobox)"
  yb_ver=$(yolobox version 2>/dev/null | head -1 | strip_ansi)
  case "$yb_ver" in
    "") warn "  'yolobox version' printed nothing — a build too old for the 'version' subcommand? check your installer (e.g. 'brew list --versions yolobox')" ;;
    *"Claude Code"*|*"claude"*)
      info "  version: $yb_ver"
      warn "  that looks like the forwarded harness version, not yolobox's own — your yolobox likely predates the 'version' subcommand; check your installer" ;;
    *)  info "  version: $yb_ver" ;;
  esac
else
  fail "yolobox not on PATH — install it, or you're on a machine that only runs the host side via WSL/SSH"
fi

# Claude Code on the host (the binary the host itself runs). Capture the bare
# semver too (the line reads e.g. "2.1.170 (Claude Code)") for the host-vs-image
# comparison after the probe runs.
if have claude; then
  cc_host_raw=$(claude --version 2>/dev/null | head -1)
  info "Claude Code (host): ${cc_host_raw:-?}"
  CC_HOST=$(printf '%s\n' "$cc_host_raw" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
else
  info "Claude Code (host): 'claude' not on PATH"
fi

# Container runtime: yolobox needs one, and so do our image/bridge probes below.
RT=""
for c in docker podman container; do
  have "$c" && { RT="$c"; break; }
done
if [ -z "$RT" ]; then
  fail "no container runtime found (docker / podman / apple 'container') — yolobox cannot start a box, and the image/bridge probes below will be skipped"
else
  pass "runtime present: $RT ($(command -v "$RT"))"
  case "$RT" in
    docker|podman)
      if "$RT" info >/dev/null 2>&1; then
        pass "$RT daemon reachable"
      else
        fail "$RT found but daemon not reachable — start Docker Desktop / the $RT service"
      fi
      if [ "$IS_WSL" -eq 0 ] && [ "$OS" != "Linux" ] && [ "$OS" != "Darwin" ]; then
        warn "non-Linux host: ensure $RT is in Linux-container mode (WSL2 backend), not Windows containers"
      fi
      ;;
  esac
fi
# Only docker/podman expose the `image inspect` / `run` we use below.
PROBE_RT=""
case "$RT" in docker|podman) PROBE_RT=$RT ;; esac

# =============================================================================
# yolobox config.toml — locate, parse image ref + mounts, validate, dump.
# Sets globals consumed later: CFG, IMG_REF, BRIDGE_PAIRS (src<TAB>dst per line,
# only for /host-claude-* mounts whose host source exists).
# =============================================================================
CFG=""
IMG_REF=""
BRIDGE_PAIRS=""

yolobox_config_section() {
  section "yolobox config (config.toml)"
  for c in "${XDG_CONFIG_HOME:-$HOME/.config}/yolobox/config.toml" \
           "$HOME/.config/yolobox/config.toml"; do
    [ -f "$c" ] && { CFG=$c; break; }
  done

  if [ -z "$CFG" ]; then
    warn "no config.toml at the standard path — yolobox is using upstream defaults (no SLDS bridge mounts)"
  else
    pass "config found: $CFG"
    # Image ref the box launches from (used by the image/bridge probes below).
    IMG_REF=$(grep -E '^[[:space:]]*image[[:space:]]*=' "$CFG" 2>/dev/null | head -1 \
              | sed -E 's/.*=[[:space:]]*"?([^"#]+)"?.*/\1/; s/[[:space:]]*$//')
    [ -n "$IMG_REF" ] && info "configured image: $IMG_REF"

    # Verify each mount's HOST source exists. A missing source is the #1 silent
    # cause of "the bridge does nothing": docker creates the missing source as an
    # empty dir, so it mounts empty in-box and the shim silently no-ops.
    info "Each 'mounts' entry is host_path:container_path[:opt]. We check that the host"
    info "side (left of the ':') exists. If it doesn't, Docker silently creates it as an"
    info "empty directory and mounts that — so the box sees nothing and the bridge it"
    info "feeds does nothing."
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
    ' "$CFG" 2>/dev/null)
    if [ -z "$mounts" ]; then
      warn "no mounts parsed from config — the bridge mounts may be missing, leaving the launch shim with nothing to bridge inside the box"
    else
      # Iterate via here-doc (not a pipe) so pass/warn counters survive, and so
      # we can accumulate BRIDGE_PAIRS in this shell.
      while IFS= read -r entry; do
        [ -z "$entry" ] && continue
        src=${entry%%:*}            # host path (what we test)
        rest=${entry#*:}            # container path [+ :opt]
        tgt=${rest%%:*}             # container path
        if [ -e "$src" ]; then
          pass "host source exists: $src  → in-box: $tgt"
        else
          warn "host source MISSING: $src  → in-box: $tgt  (Docker mounts an empty dir here, so the bridge carries nothing)"
        fi
        # Collect the live-bridge mounts (only those whose source exists, so we
        # never attach — and thus never auto-create — a missing host path).
        case "$tgt" in
          /host-claude-*)
            [ -e "$src" ] && BRIDGE_PAIRS="${BRIDGE_PAIRS}${src}${TAB}${tgt}
" ;;
        esac
      done <<EOF
$mounts
EOF
    fi

    info "full contents:"
    sed 's/^/    | /' "$CFG"
  fi
}

# ── Host Claude state the bridge SOURCES from ─────────────────────────────────
# The bridge mounts bind three HOST paths under ~/.claude into the box; the shim
# then symlinks the box's ~/.claude entries onto those mounts. This checks the
# HOST end: do those source paths exist as real Claude state? An absent source
# isn't fatal — Claude creates it on first use — but until then its bridge
# carries nothing. Printed right after the config so each mount sits next to the
# state it feeds.
host_claude_state() {
  section "Host Claude state (bridge sources)"
  info "These are the host ~/.claude paths the live bridge maps into the box."
  info "If one is missing here, the box has nothing to show for it — and nothing to"
  info "save back to the host — until Claude creates it on the host for the first time."
  _hcs() {  # path, role, what's lost if missing
    if [ -e "$1" ]; then pass "$2 present: $1"
    else warn "$2 ABSENT: $1  ($3 until it exists on the host)"; fi
  }
  _hcs "$HOME/.claude/projects"          "sessions+memory" "no past sessions or per-project memory in-box"
  _hcs "$HOME/.claude/history.jsonl"     "prompt history"  "no prompt history in-box"
}

# ── Shell-script line endings (CRLF = the Windows killer) ─────────────────────
# If the shim or shell config got CRLF endings (edited/checked out on Windows),
# the in-box '#!/bin/bash\r' breaks with 'bad interpreter'.
line_endings_section() {
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
# Docker image identity — read the image straight from the host.
# `docker image inspect` gives the local digest, creation time, OCI labels and
# the baked SLDS_* provenance (the SLDS build commit/date + finbarr/yolobox base
# digest). Informational; degrades gracefully when the runtime/image is absent.
# Sets IMAGE_PRESENT=1 when the configured image is available locally, so the
# probe section below knows whether it can run.
# =============================================================================
IMAGE_PRESENT=0
docker_image_section() {
  section "Docker image"
  [ -n "$IMG_REF" ] || IMG_REF="ghcr.io/slds-lmu/slds-yolobox:latest"
  info "image ref: $IMG_REF"

  if [ -z "$PROBE_RT" ]; then
    info "no docker/podman on host — cannot inspect the image"
    return 0
  fi
  if ! "$PROBE_RT" image inspect "$IMG_REF" >/dev/null 2>&1; then
    info "image not present locally — pull it (or launch a box) first; nothing to inspect"
    return 0
  fi
  IMAGE_PRESENT=1

  ldig=$("$PROBE_RT" image inspect --format '{{if .RepoDigests}}{{index .RepoDigests 0}}{{end}}' "$IMG_REF" 2>/dev/null)
  lcreated=$("$PROBE_RT" image inspect --format '{{.Created}}' "$IMG_REF" 2>/dev/null)
  if [ -n "$ldig" ]; then info "local image digest:  $ldig"; else info "local image digest:  <none recorded>"; fi
  [ -n "$lcreated" ] && info "local image created: $lcreated"

  # Default user is an image-config fact — read it authoritatively here rather
  # than from inside the probe (the probe runs as whatever uid, so it's the wrong
  # place to assert the configured USER).
  iuser=$("$PROBE_RT" image inspect --format '{{.Config.User}}' "$IMG_REF" 2>/dev/null)
  if [ "$iuser" = yolo ]; then pass "image default user is 'yolo'"
  else warn "image default user is '${iuser:-<unset>}' (expected yolo)"; fi

  # Baked SLDS_* provenance — read from the image's ENV (works regardless of
  # label support). One inspect, then pick the fields out.
  envdump=$("$PROBE_RT" image inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$IMG_REF" 2>/dev/null)
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

# =============================================================================
# Image contract + live-bridge integration test, via ONE probe container.
#
# We bypass the image's entrypoint (`--entrypoint sh`) so nothing tries to do a
# full yolobox boot; we just get a clean shell inside the image to (a) inspect
# image-intrinsic facts and (b) integration-test the bridge with the real host
# mounts attached. The probe reproduces the launch shim's symlink swap exactly
# (see yolobox/claude-launch-shim.sh) — that's why we attach the /host-claude-*
# mounts and then verify the symlinks resolve and (opt-in) writes reach the host.
#
# Protocol: the probe prints one line per finding, prefixed '@@' and with a TAB
# between KIND (PASS/WARN/FAIL/INFO) and message. The host reads them back via a
# here-doc loop (NOT a pipe) so the shared pass/warn/fail counters survive.
# =============================================================================
run_probe() {
  section "Image contract & live bridge (probe container)"
  if [ "$IMAGE_PRESENT" -ne 1 ]; then
    info "skipped — needs the configured image present locally (see Docker image above)"
    return 0
  fi

  # Build -v flags + a space-separated list of bridge container-paths from the
  # mounts whose host source exists. Word-splitting on VOL_ARGS is intentional.
  VOL_ARGS=""
  BRIDGE_TGTS=""
  while IFS="$TAB" read -r src tgt; do
    [ -n "${src:-}" ] || continue
    VOL_ARGS="$VOL_ARGS -v $src:$tgt"
    BRIDGE_TGTS="$BRIDGE_TGTS $tgt"
  done <<EOF
$BRIDGE_PAIRS
EOF
  if [ -n "$BRIDGE_TGTS" ]; then
    info "host bridge mounts attached to the probe:$BRIDGE_TGTS"
    info "The probe now repeats what the launch shim does at boot: for each mount it"
    info "deletes the snapshot copy and puts a symlink in its place (~/.claude/<x> ->"
    info "the mount), then checks that the symlink resolves and the mount is usable."
    info "One caveat: this is a plain 'docker run', not a real yolobox launch, so it"
    info "does NOT set up yolobox's user-ID mapping. Because of that, a mount can look"
    info "read-only, or a write can fail to reach the host, purely because the user IDs"
    info "don't match — not because the bridge is broken. So those two checks only ever"
    info "WARN, never FAIL. (A real box has the mapping; trust write-through only there.)"
  else
    warn "no bridge mounts to attach (none configured, or their host sources are missing) — the bridge can't be tested, so only the image's own contents are checked below"
  fi

  # The in-container probe. Intentionally single-quoted so $VARS expand inside the
  # CONTAINER at run time, not here on the host — hence SC2016 is disabled.
  # shellcheck disable=SC2016
  probe='
H=${HOME:-/home/yolo}
e() { printf "@@%s\t%s\n" "$1" "$2"; }

if [ -f /usr/local/bin/claude ] && grep -q claude-launch-shim /usr/local/bin/claude 2>/dev/null; then
  e PASS "launch shim installed at /usr/local/bin/claude"
else
  e FAIL "/usr/local/bin/claude is not the launch shim — bridge would not be applied"
fi

for cf in /opt/yolobox/bin/claude "$H/.local/bin/claude" /usr/local/bin/claude; do
  [ -e "$cf" ] && e PASS "launch-chain link present: $cf" || e WARN "launch-chain link missing: $cf"
done

PKG=/usr/local/lib/node_modules/@anthropic-ai/claude-code
REAL=
for c in "$PKG/cli.js" "$PKG/bin/claude.exe" "$PKG/bin/claude" "$PKG/claude"; do
  [ -f "$c" ] && { REAL=$c; break; }
done
[ -n "$REAL" ] && e PASS "real Claude Code entry point: $REAL" || e FAIL "no Claude Code entry point under $PKG — claude would exit 127"

if [ -f "$PKG/package.json" ]; then
  v=$(grep -m1 "\"version\"" "$PKG/package.json" | sed -E "s/.*\"version\"[^\"]*\"([^\"]+)\".*/\1/")
  e INFO "Claude Code (in image): ${v:-?}"
fi

for t in R Rscript node npm git rg jq; do
  command -v "$t" >/dev/null 2>&1 && e PASS "tool present: $t" || e WARN "tool missing in image: $t"
done

[ "${LC_NUMERIC:-}" = C ] && e PASS "LC_NUMERIC=C (decimal '"'"'.'"'"' for R)" || e WARN "LC_NUMERIC='"'"'${LC_NUMERIC:-unset}'"'"' (expected C)"

# Live-bridge reproduction: for each attached /host-claude-* mount, mirror the
# shim swap (rm snapshot copy; symlink ~/.claude/<x> -> mount) and verify it.
for dst in ${BRIDGE:-}; do
  case "$dst" in
    /host-claude-sessions)         name=projects ;;
    /host-claude-history.jsonl)    name=history.jsonl ;;
    *)                             name=$(basename "$dst") ;;
  esac
  if [ ! -e "$dst" ]; then e WARN "bridge mount not attached: $dst"; continue; fi
  if [ -w "$dst" ]; then e PASS "bridge mount writable: $dst"; else e WARN "bridge mount not writable by the probe: $dst (either a read-only mount, or — more likely — this probe lacks the yolobox user-ID mapping, so a usable mount can still look read-only here)"; fi
  mkdir -p "$H/.claude" 2>/dev/null
  rm -rf "$H/.claude/$name" 2>/dev/null
  if ln -s "$dst" "$H/.claude/$name" 2>/dev/null && [ "$(readlink "$H/.claude/$name" 2>/dev/null)" = "$dst" ]; then
    e PASS "bridge symlink resolves: ~/.claude/$name -> $dst"
  else
    e FAIL "could not establish bridge symlink for ~/.claude/$name"
  fi
  # Write-through: only meaningful for the sessions DIR; drop a sentinel that the
  # host verifies after the run (then removes).
  if [ "${WP:-0}" = 1 ] && [ -d "$dst" ]; then
    s="$dst/.yolobox-doctor-probe.$PID"
    if (: > "$s") 2>/dev/null; then e INFO "wrote sentinel into $name (host will verify)"; else e WARN "could not write sentinel into $name"; fi
  fi
done
'

  # Run the probe. --entrypoint sh bypasses the image entrypoint; -e passes the
  # bridge target list / write-probe flag / a host-unique id for the sentinel.
  # shellcheck disable=SC2086  # VOL_ARGS must word-split into separate -v flags
  out=$("$PROBE_RT" run --rm --entrypoint sh $VOL_ARGS \
          -e BRIDGE="$BRIDGE_TGTS" -e WP="$WRITE_PROBE" -e PID="$$" \
          "$IMG_REF" -c "$probe" 2>/dev/null)

  # Dispatch the probe's findings into our reporters. Here-doc (not a pipe) keeps
  # the counters in this shell. Non-protocol stray lines are ignored.
  while IFS="$TAB" read -r kind msg; do
    case "$kind" in
      @@PASS) pass "$msg" ;;
      @@WARN) warn "$msg" ;;
      @@FAIL) fail "$msg" ;;
      @@INFO)
        info "$msg"
        # Capture the image's Claude Code version for the host-vs-image check.
        case "$msg" in
          "Claude Code (in image): "*)
            CC_IMAGE=$(printf '%s\n' "$msg" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1) ;;
        esac
        ;;
    esac
  done <<EOF
$out
EOF

  # Host-side half of the write-through proof: confirm each sentinel reached the
  # host source, then remove it. Only sessions (a dir) gets one.
  if [ "$WRITE_PROBE" -eq 1 ]; then
    while IFS="$TAB" read -r src tgt; do
      [ -n "${src:-}" ] || continue
      [ -d "$src" ] || continue
      sent="$src/.yolobox-doctor-probe.$$"
      if [ -e "$sent" ]; then
        pass "write reached the host: $sent — bridge is genuinely two-way"
        rm -f "$sent" 2>/dev/null
      else
        warn "probe write into $tgt did not reach the host at $src — most likely because this probe lacks yolobox's user-ID mapping. Only a real yolobox box has that mapping, so this write-through test is conclusive only when run from inside one."
      fi
    done <<EOF
$BRIDGE_PAIRS
EOF
  fi
}

# ── Claude Code version: host vs image ────────────────────────────────────────
# The doctor is the one place that sees BOTH numbers (host via `claude --version`,
# image via the probe), so it's where the comparison belongs. The box shares live
# state with the host — sessions, history, snapshotted config — so a
# version skew can muddle that shared state. Non-fatal (WARN, never FAIL): a
# mismatch is expected right after the host updates but before the image is
# rebuilt/pulled. Skipped silently unless BOTH versions are known.
cc_version_check() {
  section "Claude Code version (host vs image)"
  if [ -z "$CC_HOST" ] || [ -z "$CC_IMAGE" ]; then
    info "skipped — need both versions (host: ${CC_HOST:-?}, image: ${CC_IMAGE:-?}); the image one needs the probe to have run"
    return 0
  fi
  if [ "$CC_HOST" = "$CC_IMAGE" ]; then
    pass "host and image run the same Claude Code ($CC_HOST)"
  else
    warn "Claude Code differs — host $CC_HOST vs image $CC_IMAGE; the box shares sessions/history/config with the host, so a skew can muddle that shared state (pull/rebuild the image, or align the host)"
  fi
}

# =============================================================================
# Inventory — installed plugins + skills, read from the HOST ~/.claude (the
# source of truth that gets snapshotted into the box). INFO/PASS/WARN only.
# =============================================================================

# Emit the installPath of every CURRENTLY-installed plugin, normalized to this
# machine's $HOME. Scanning only these — not all of plugins/cache — avoids
# counting stale cached versions.
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

list_plugins() {
  section "Claude Code plugins"
  reg="$HOME/.claude/plugins/installed_plugins.json"
  if [ ! -f "$reg" ]; then
    info "no plugin registry ($reg) — no plugins installed"
    return 0
  fi
  n=0
  if have jq; then
    jq -r '.plugins | to_entries[] | .key as $k | .value[]
           | "\($k)\t[\(.scope)]"' "$reg" 2>/dev/null \
      | while IFS="$TAB" read -r name scope; do
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

  mk="$HOME/.claude/plugins/known_marketplaces.json"
  if [ -f "$mk" ]; then
    if have jq; then
      jq -r 'to_entries[] | "\(.key)\t\(.value.source.repo // .value.source.url // "?")"' "$mk" 2>/dev/null \
        | while IFS="$TAB" read -r name src; do info "marketplace: $name  ($src)"; done
    else
      grep -oE '"[A-Za-z0-9_.-]+":[[:space:]]*\{' "$mk" 2>/dev/null \
        | sed -E 's/":.*//; s/^"//' | while IFS= read -r name; do info "marketplace: $name"; done
    fi
  fi
}

# Canonical skill name from a SKILL.md's YAML frontmatter `name:` field; fall
# back to the containing directory name.
skill_name() {
  _n=$(grep -m1 -E '^name:[[:space:]]*' "$1" 2>/dev/null \
        | sed -E 's/^name:[[:space:]]*//; s/[[:space:]]*$//' | tr -d '"'\''')
  if [ -n "$_n" ]; then printf '%s\n' "$_n"; else basename "$(dirname "$1")"; fi
}

list_skills() {
  section "Claude Code skills"
  sn=0
  if [ -d "$HOME/.claude/skills" ]; then
    for d in "$HOME"/.claude/skills/*/; do
      [ -f "${d}SKILL.md" ] || continue
      info "skill (standalone): $(skill_name "${d}SKILL.md")"
      sn=$((sn+1))
    done
  fi

  installed_plugin_paths | while IFS= read -r ip; do
    [ -d "$ip" ] && find "$ip" -name SKILL.md 2>/dev/null
  done | while IFS= read -r f; do skill_name "$f"; done | sort -u \
    | while IFS= read -r name; do
        [ -n "$name" ] && info "skill (plugin):     $name"
      done

  pn=$(installed_plugin_paths | while IFS= read -r ip; do
         [ -d "$ip" ] && find "$ip" -name SKILL.md 2>/dev/null
       done | while IFS= read -r f; do skill_name "$f"; done | sort -u | grep -c .)
  pass "${sn} standalone + ${pn:-0} plugin skill(s) available to Claude Code"
}

# ── Dispatch (single host-side flow) ──────────────────────────────────────────
yolobox_config_section     # locates config, sets IMG_REF + BRIDGE_PAIRS
host_claude_state          # the host state the bridge sources from
line_endings_section       # CRLF trap
docker_image_section       # image identity (sets IMAGE_PRESENT)
run_probe                  # image contract + live-bridge integration test
cc_version_check           # host vs image Claude Code (needs both versions known)
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
