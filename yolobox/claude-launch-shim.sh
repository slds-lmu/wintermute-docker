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
# Not bridged
#   Credentials come straight from the claude_config snapshot (read-only is
#   fine — the token works until expiry), so they need no live mount. Plugins
#   are not live either: the snapshot copy is used as-is, only path-fixed.
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

# ── Plugin registry path fixup ──────────────────────────────────────────────
# Repoint the snapshotted registry from the embedded host paths to the
# container home, so the plugin content the snapshot already copied in actually
# loads. Anchoring the match on the opening quote rewrites only the leading dir
# of each JSON string value, and the prefix is read from the file itself, so any
# host user / OS layout (/home/<user>, /Users/<user>, …) is handled. Idempotent:
# after a rewrite the value already starts at $HOME, so re-runs replace it with
# itself — safe to run on every `claude` invocation in a boot.
for f in "$HOME/.claude/plugins/installed_plugins.json" \
         "$HOME/.claude/plugins/known_marketplaces.json"; do
  [ -f "$f" ] && sed -E -i "s#\"[^\"]*/\.claude/plugins#\"$HOME/.claude/plugins#g" "$f"
done

# ── Live session / memory / history bridge ──────────────────────────────────
# Swap each dead snapshot copy for a symlink to its rw host mount. The `! -L`
# guard makes each idempotent across the many `claude` invocations in one boot
# (e.g. `claude -p` from the gccm alias): once swapped to a symlink, later
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

exec "$REAL" "$@"
