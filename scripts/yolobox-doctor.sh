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

# =============================================================================
# HOST MODE — will a box launch and bridge at all?
# =============================================================================
host_checks() {
  # ── yolobox binary ──────────────────────────────────────────────────────
  section "yolobox CLI"
  if have yolobox; then
    pass "yolobox on PATH: $(command -v yolobox)"
    ver=$(yolobox --version 2>/dev/null | head -1)
    if [ -n "$ver" ]; then info "version: $ver"
    else warn "could not read 'yolobox --version' (old build?)"; fi
  else
    fail "yolobox not on PATH — install it, or you're on a machine that only runs the host side via WSL/SSH"
  fi

  # ── Container runtime ───────────────────────────────────────────────────
  section "Container runtime"
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

  # ── config.toml ─────────────────────────────────────────────────────────
  section "yolobox config"
  CFG="${XDG_CONFIG_HOME:-$HOME/.config}/yolobox/config.toml"
  if [ -f "$CFG" ]; then
    pass "config found: $CFG"
    for key in claude_config image default_harness; do
      line=$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "$CFG" 2>/dev/null | head -1)
      [ -n "$line" ] && info "$(printf '%s' "$line" | sed 's/^[[:space:]]*//')"
    done

    # Verify the HOST sources of each mount exist. A missing source is the #1
    # silent cause of "the bridge does nothing" — the shim then no-ops.
    section "Mount sources (host side)"
    # Extract the source (text before the first ':') from each quoted mount entry.
    srcs=$(awk '
      /mounts[[:space:]]*=/        { inm=1 }
      inm && /"[^"]+"/ {
        s=$0
        while (match(s, /"[^"]+"/)) {
          q=substr(s, RSTART+1, RLENGTH-2)
          if (q ~ /:/) { sub(/:.*/, "", q); print q }
          s=substr(s, RSTART+RLENGTH)
        }
      }
      inm && /\]/                  { inm=0 }
    ' "$CFG" 2>/dev/null)
    if [ -z "$srcs" ]; then
      warn "no mounts parsed from config — bridge mounts may be absent (shim becomes a no-op in-box)"
    else
      echo "$srcs" | while IFS= read -r s; do
        [ -z "$s" ] && continue
        if [ -e "$s" ]; then
          pass "mount source exists: $s"
        else
          warn "mount source MISSING on host: $s  (that mount will be empty/absent in-box)"
        fi
      done
    fi
  else
    warn "no config at $CFG — yolobox runs with upstream defaults (no SLDS bridge mounts)"
  fi

  # ── Host Claude state the bridge depends on ───────────────────────────────
  section "Host Claude state"
  for p in "$HOME/.claude/projects" "$HOME/.claude/history.jsonl" "$HOME/.claude/.credentials.json"; do
    if [ -e "$p" ]; then pass "present: $p"
    else warn "absent: $p  (its bridge will no-op until it exists)"
    fi
  done

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
#   Pure inventory (INFO/PASS), no FAILs — so it never affects the exit code.
# =============================================================================

# ── Print the global yolobox config.toml ──────────────────────────────────────
# The global config is a HOST-side file (~/.config/yolobox/config.toml). It is
# normally NOT mounted into the box, so in-box this section usually reports it
# absent and points you at the host — that's expected, not a failure.
dump_global_config() {
  section "Global yolobox config (config.toml)"
  cfg=""
  for c in "${XDG_CONFIG_HOME:-$HOME/.config}/yolobox/config.toml" \
           "$HOME/.config/yolobox/config.toml"; do
    [ -f "$c" ] && { cfg=$c; break; }
  done
  if [ -n "$cfg" ]; then
    info "source: $cfg"
    # Print the file verbatim, indented so it's visually distinct in a report.
    sed 's/^/    | /' "$cfg"
  elif [ "$MODE" = inbox ]; then
    info "not mounted in-box — it's a host-side file; run this on the host to print it"
  else
    warn "no config.toml at the standard path — yolobox is using upstream defaults"
  fi
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
dump_global_config
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
