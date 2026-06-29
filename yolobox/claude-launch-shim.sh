#!/bin/bash
# claude-launch-shim.sh — wrapper installed at /usr/local/bin/claude.
#
# Purpose
#   Fix up the snapshotted Claude Code state, then exec the real `claude`
#   binary. Two small jobs, both after the yolobox entrypoint copy but before
#   Claude reads anything:
#     1. Rewrite the plugin registry's absolute host paths to the container
#        home so the snapshot's plugins (and their skills) actually load.
#     2. Bridge LIVE session state (sessions, memory, history) back to the host.
#
#   The container runs with claude_config=true, so the yolobox entrypoint
#   snapshots the whole host ~/.claude into the container at boot
#   (`rm -rf ~/.claude && cp -a`). That snapshot is a dead, one-way copy:
#   anything Claude writes inside the box — new sessions, per-project memory,
#   prompt history — would be lost when the container is torn down.
#
#   (1) Plugin path fixup. The snapshot copies the plugin content in, but the
#   registry (installed_plugins.json / known_marketplaces.json) locates each
#   plugin by an ABSOLUTE host path (e.g. /home/<host-user>/.claude/plugins/…),
#   which `cp` preserves verbatim and which does not exist in this container.
#   Unlike standalone skills under ~/.claude/skills (dir-scanned, so they just
#   work after the copy), plugins are looked up by that path — so without the
#   rewrite below they silently fail to load. We rewrite the leading dir to
#   $HOME; the prefix is taken from the file, so any host user / OS layout works.
#
#   (2) For the dirs we want LIVE (two-way), the host bind-mounts them READ-WRITE
#   at /host-claude-* paths OUTSIDE ~/.claude (so the entrypoint's `rm -rf`
#   cannot reach them). Here we discard the dead snapshot copy and symlink the
#   live mount in its place, so reads and writes hit the host both ways:
#     ~/.claude/projects      -> /host-claude-sessions        (sessions + memory)
#     ~/.claude/history.jsonl -> /host-claude-history.jsonl   (prompt history)
#   Claude stores per-project memory under projects/<proj>/memory/, so the
#   single `projects` symlink covers sessions and memory together.
#
#   This lives in the launch shim, not a Claude Code SessionStart hook, because
#   `claude --resume` lists sessions BEFORE any hook fires.
#
# Required host config
#   The rw staging mounts come from the yolobox config.toml `mounts` list
#   (managed in the sysadmin repo), e.g.:
#     "/home/<user>/.claude/projects:/host-claude-sessions"
#     "/home/<user>/.claude/history.jsonl:/host-claude-history.jsonl"
#   Without those mounts this shim is a transparent no-op and the dead snapshot
#   copies are used as-is.
#
# Bridged too: credentials
#   Claude refreshes (and may rotate) its OAuth token mid-session; a read-only
#   snapshot would lose that write on teardown, so the next boot re-snapshots an
#   aging host token and drops you to /login. So .credentials.json is bridged rw
#   like the dirs above — see the credentials block below.
#
# Not bridged
#   Plugins are not live: the snapshot copy is used as-is, only path-fixed.
#
# Launch chain
#   `claude` -> /opt/yolobox/bin/claude (upstream wrapper, adds
#   --dangerously-skip-permissions) -> /usr/local/bin/claude (this shim) ->
#   $REAL. No recursion: $REAL is addressed by absolute path and is not named
#   `claude` on PATH.
set -u

# Resolve the real Claude Code entry point that npm installed into the package
# dir. Don't hardcode a single filename: the package has shipped its launcher
# under different names across releases (cli.js for the JS build, bin/claude.exe
# or bin/claude for native builds), and a wrong guess makes `claude` silently
# dead. Probe the known candidates and fail loudly if none match, so a future
# upstream rename surfaces as a clear error at launch instead of a broken exec.
PKG=/usr/local/lib/node_modules/@anthropic-ai/claude-code
REAL=
for cand in "$PKG/cli.js" "$PKG/bin/claude.exe" "$PKG/bin/claude" "$PKG/claude"; do
  [ -f "$cand" ] && { REAL=$cand; break; }
done
[ -n "$REAL" ] || {
  echo "claude shim: cannot locate Claude Code entry point under $PKG" >&2
  exit 127
}

# ── Plugin path fixup ───────────────────────────────────────────────────────
# The snapshot copies plugin content in, but the registry locates each plugin by
# an ABSOLUTE host path (/home/<host-user>/.claude/plugins/…) that does not exist
# in this container. Standalone skills under ~/.claude/skills are dir-scanned and
# unaffected; plugins are path-addressed. We apply TWO layers, because the first
# alone does not hold:
#
#   (a) Best-effort rewrite of the host prefix to $HOME in the registry files.
#       This does NOT reliably stick: Claude's plugin subsystem regenerates the
#       registry on startup — AFTER this shim has exec'd into claude — and
#       re-introduces the host paths. The regeneration source is not the catalog
#       cache or ~/.claude.json (both checked); it was observed flipping an
#       already-fixed registry back to /home/<host-user> mid-session. Kept
#       anyway: it's free, it fixes the paths for anything that reads them before
#       the regeneration, and it is the only layer available when sudo is absent.
#
#   (b) Regeneration-proof compat symlink: make the host path itself RESOLVE in
#       the container, so it no longer matters what the registry says or how many
#       times Claude rewrites it. We point
#         <host-prefix>/.claude/plugins -> $HOME/.claude/plugins
#       The host prefix is detected from the registry (any /home/<user>,
#       /Users/<user>, … layout), BEFORE (a) rewrites it away. /home is
#       root-owned, so creating the path needs sudo (passwordless in yolobox); if
#       sudo is unavailable we silently fall back to (a) alone. /home/<host-user>
#       lives in the ephemeral container fs, so the link is recreated each boot.
#
# Why bother when plugins currently load fine? Current Claude Code resolves
# plugin content RELATIVE to ~/.claude/plugins, so today the stale absolute path
# is tolerated and skills load (verified). (b) is hardening: if a future release
# honors absolute registry paths strictly, (a) alone would break in-box plugins
# on every regeneration — (b) keeps them working regardless.
plugdir="$HOME/.claude/plugins"
if [ -d "$plugdir" ]; then
  reg_installed="$plugdir/installed_plugins.json"
  reg_markets="$plugdir/known_marketplaces.json"

  # Detect the embedded host prefix BEFORE rewriting (the rewrite would erase it).
  host_prefix=$(grep -hoE '"/[^"]*/\.claude/plugins' "$reg_installed" "$reg_markets" 2>/dev/null \
                | sed -E 's#^"##; s#/\.claude/plugins$##' | grep -vx "$HOME" | head -1)

  # (a) best-effort rewrite of the registry files to the container home.
  for f in "$reg_installed" "$reg_markets"; do
    [ -f "$f" ] && sed -E -i "s#\"[^\"]*/\.claude/plugins#\"$HOME/.claude/plugins#g" "$f"
  done

  # (b) regeneration-proof compat symlink, via sudo (best-effort, never fatal).
  # The case-glob guards against an empty / single-component / $HOME prefix.
  case "$host_prefix" in
    /?*/?*)
      if [ "$host_prefix" != "$HOME" ] && [ ! -e "$host_prefix/.claude/plugins" ] \
         && sudo -n true 2>/dev/null; then
        sudo mkdir -p "$host_prefix/.claude" 2>/dev/null \
          && sudo ln -sfn "$plugdir" "$host_prefix/.claude/plugins" 2>/dev/null
      fi
      ;;
  esac
fi

# ── Live session / memory / history bridge ──────────────────────────────────
# Swap each dead snapshot copy for a symlink to its rw host mount. The `! -L`
# guard makes each idempotent across the many `claude` invocations in one boot
# (e.g. repeated non-interactive `claude -p` calls): once swapped to a symlink, later
# launches skip it. Each `rm` only ever removes the container-local snapshot
# copy — never the host data, which lives at the /host-claude-* mount the
# symlink points to.
if [ -d /host-claude-sessions ] && [ ! -L "$HOME/.claude/projects" ]; then
  rm -rf "$HOME/.claude/projects"
  ln -s /host-claude-sessions "$HOME/.claude/projects"
fi
if [ -e /host-claude-history.jsonl ] && [ ! -L "$HOME/.claude/history.jsonl" ]; then
  rm -f "$HOME/.claude/history.jsonl"
  ln -s /host-claude-history.jsonl "$HOME/.claude/history.jsonl"
fi

# ── Live credentials bridge ─────────────────────────────────────────────────
# Same swap, but the point is write-back: Claude refreshes its OAuth access
# token (and may rotate the refresh token) and writes the new value to
# ~/.claude/.credentials.json. Pointing that at the rw host mount makes the
# write land on the host, so the next boot starts from a current token instead
# of the aging snapshot — without this you get dropped to /login. Same `! -L`
# idempotency, and the `rm` only removes the container-local snapshot copy.
if [ -e /host-claude-credentials.json ] && [ ! -L "$HOME/.claude/.credentials.json" ]; then
  rm -f "$HOME/.claude/.credentials.json"
  ln -s /host-claude-credentials.json "$HOME/.claude/.credentials.json"
fi

# ── Host vs image Claude Code version check ──────────────────────────────────
# The box shares LIVE state with the host — sessions, history, credentials (the
# bridges above) plus the snapshotted ~/.claude config. When the host and the
# image run different Claude Code versions, that shared state can drift in format
# (session schema, config migrations, credential layout), so we surface a
# mismatch once per boot and — on an interactive launch — make the user
# acknowledge it with Enter before continuing.
#
# Version sources, chosen for robustness (we must NEVER block or break a launch
# on missing/ambiguous data — a false alarm is worse than no alarm):
#   image : the npm package's package.json "version" — authoritative and instant
#           (no need to spawn the ~245 MB binary just to read --version).
#   host  : ~/.claude/.last-update-result.json "version_to", and only when the
#           recorded update "status"/"outcome" is success. The in-box updater is
#           disabled (DISABLE_AUTOUPDATER=1 in the Dockerfile), so this file is
#           NEVER written inside the box — it reflects the HOST's native Claude
#           exclusively, and the entrypoint re-snapshots it from the host on
#           every boot. If the file is absent or the last update failed, the host
#           version is unknown and we stay silent rather than guess.
#
# Gated to run at most once per boot via an ephemeral /tmp sentinel (the
# container fs resets each launch; /home is the persistent volume and must NOT
# hold this, or the check would fire only once ever). The blocking read fires
# only on a real TTY, so headless `claude -p` invocations print the warning (if
# any) but never hang waiting for input.
version_sentinel="${TMPDIR:-/tmp}/.claude-version-checked"
if [ ! -e "$version_sentinel" ]; then
  : > "$version_sentinel" 2>/dev/null || true

  img_ver=$(grep -m1 '"version"' "$PKG/package.json" 2>/dev/null \
            | sed -E 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')

  host_ver=
  upd="$HOME/.claude/.last-update-result.json"
  if [ -f "$upd" ] && grep -qE '"(status|outcome)":"success"' "$upd" 2>/dev/null; then
    host_ver=$(grep -oE '"version_to":"[^"]+"' "$upd" 2>/dev/null \
               | sed -E 's/.*"([^"]+)"$/\1/')
  fi

  # Only warn when BOTH versions are known and they actually differ.
  if [ -n "$img_ver" ] && [ -n "$host_ver" ] && [ "$img_ver" != "$host_ver" ]; then
    # Colorize only on a TTY so headless logs stay free of escape codes.
    if [ -t 2 ]; then y=$'\033[33m'; b=$'\033[1m'; n=$'\033[0m'; else y=''; b=''; n=''; fi
    printf '\n%s%s⚠  Claude Code version mismatch%s\n' "$b" "$y" "$n" >&2
    printf '   host : %s\n' "$host_ver" >&2
    printf '   image: %s\n' "$img_ver" >&2
    printf '   The box shares sessions, history, credentials and config with the\n' >&2
    printf '   host; differing versions can skew that shared state. Rebuild the\n' >&2
    printf '   image (or align the host) if you hit trouble.\n' >&2
    # Interactive launch only: require an explicit Enter to proceed.
    if [ -t 0 ] && [ -t 2 ]; then
      printf '\n   Press Enter to continue (Ctrl-C to abort)... ' >&2
      read -r _ || true
      printf '\n' >&2
    fi
  fi
fi

exec "$REAL" "$@"
