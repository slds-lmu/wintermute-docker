#!/bin/sh
# yolobox-check.sh — live, in-box check of the yolobox sandbox: is it SAFE and is
# it FUNCTIONAL as a Claude Code (CC) workspace?
#
# Purpose
#   Two questions, one report:
#     (1) SAFETY  — "can I let an agent run with --dangerously-skip-permissions
#                    in this box?" (containment of host fs / secrets / privilege)
#     (2) FUNCTION — "can the agent actually get work done?" (git+commit, CC
#                    config, an edit→build→run loop, tools, disk)
#
#   PASS  = a check holds.
#   FAIL  = a CONTAINMENT boundary is BROKEN — do not trust skip-permissions.
#           (Reserved for safety only, so a non-zero exit always means "unsafe".)
#   WARN  = either a capability OPEN BY DESIGN (GitHub push, network egress) or a
#           FUNCTIONALITY problem (e.g. commits would fail). Review, don't ignore.
#   INFO  = neutral context / inventory.
#
# HOST-AGNOSTIC
#   Nothing about a particular user or machine is hardcoded. Everything
#   host-specific — the project path, the box home, the read-only mounts, the
#   host home whose dotfiles must stay invisible, and the sandbox settings — is
#   read from the in-box yolobox manifest (/run/yolobox/context.json, override
#   with $YOLOBOX_CONTEXT_FILE) and falls back to live probing of $PWD/$HOME when
#   the manifest or `jq` is absent. So any yolobox user can run it unchanged.
#
# WHERE TO RUN
#   INSIDE a box only. It refuses to run on the host, because the filesystem
#   tests deliberately attempt writes into the read-only mounts — harmless
#   against a read-only mount in-box, but real writes on the host. For the
#   host-side setup report run scripts/yolobox-doctor.sh instead.
#
# Portability: POSIX sh (dash/ash/bash). Colour only on a TTY.
#
# Usage
#   sh yolobox-check.sh         # run every check (incl. the heavy R/LaTeX stack)
#   sh yolobox-check.sh -h      # help
#
# Exit status: 0 = no FAIL (WARN allowed), 1 = at least one containment FAIL,
#              2 = wrong context (run on host) / bad usage.
set -u

# ── Options ───────────────────────────────────────────────────────────────────
for arg in "$@"; do
  case "$arg" in
    -h|--help) printf 'Usage: sh yolobox-check.sh\n'; exit 0 ;;
    *) printf 'yolobox-check: unknown argument: %s\n' "$arg" >&2; exit 2 ;;
  esac
done

# ── Reporting helpers (mirrors yolobox-doctor.sh) ─────────────────────────────
if [ -t 1 ]; then
  C_GREEN=$(printf '\033[32m'); C_YELLOW=$(printf '\033[33m')
  C_RED=$(printf '\033[31m');   C_BLUE=$(printf '\033[36m')
  C_BOLD=$(printf '\033[1m');   C_OFF=$(printf '\033[0m')
else
  C_GREEN=; C_YELLOW=; C_RED=; C_BLUE=; C_BOLD=; C_OFF=
fi

PASS_N=0; WARN_N=0; FAIL_N=0; FIRST_FAIL=""
section() { printf '\n%s== %s ==%s\n' "$C_BOLD" "$1" "$C_OFF"; }
pass()    { PASS_N=$((PASS_N+1)); printf '  %s[PASS]%s %s\n' "$C_GREEN"  "$C_OFF" "$1"; }
info()    {                       printf '  %s[INFO]%s %s\n' "$C_BLUE"   "$C_OFF" "$1"; }
warn()    { WARN_N=$((WARN_N+1)); printf '  %s[WARN]%s %s\n' "$C_YELLOW" "$C_OFF" "$1"; }
fail()    { FAIL_N=$((FAIL_N+1)); [ -z "$FIRST_FAIL" ] && FIRST_FAIL="$1"
            printf '  %s[FAIL]%s %s\n' "$C_RED" "$C_OFF" "$1"; }
have()    { command -v "$1" >/dev/null 2>&1; }

# ── Context guard — refuse to run on the host ─────────────────────────────────
# Done BEFORE any filesystem write test, because those tests target the host
# mount paths: a no-op against a read-only mount in-box, but a real write if this
# were (mistakenly) run on the host.
section "Context"
if [ -z "${YOLOBOX:-}" ]; then
  printf '  %s[ABORT]%s $YOLOBOX is empty — you are on the HOST, not in a box.\n' "$C_RED" "$C_OFF"
  printf '          The filesystem tests below try to WRITE into the read-only mounts;\n'
  printf '          in-box that hits a read-only filesystem, but on the host it would\n'
  printf '          touch your real files. Launch a box and run this there.\n'
  printf '          For the host-side setup report run: sh scripts/yolobox-doctor.sh\n'
  exit 2
fi
pass "in a yolobox container (\$YOLOBOX=$YOLOBOX)"

# ── Read the manifest (authoritative, host-agnostic source of truth) ──────────
# Everything host-specific is derived here, never hardcoded. jqv pulls a single
# scalar; jql pulls a newline list. Both degrade to empty when jq / the manifest
# is missing, and each consumer has a live-probe fallback.
CTX="${YOLOBOX_CONTEXT_FILE:-/run/yolobox/context.json}"
HAVE_CTX=0; { [ -r "$CTX" ] && have jq; } && HAVE_CTX=1
# jqv: one scalar; null/absent -> empty. NOTE we must NOT use `expr // empty`
# here: in jq, `false // empty` yields empty, so a boolean FALSE would vanish.
# The explicit null test preserves a literal `false` while still blanking absent.
jqv() { [ "$HAVE_CTX" -eq 1 ] && jq -r "($1) as \$v | if \$v==null then empty else \$v end" "$CTX" 2>/dev/null; }
jql() { [ "$HAVE_CTX" -eq 1 ] && jq -r "$1" "$CTX" 2>/dev/null; }

if [ "$HAVE_CTX" -eq 1 ]; then
  info "manifest: $CTX (authoritative for paths / mounts / network / docker)"
else
  info "manifest $CTX unreadable (or no jq) — falling back to live probes of \$PWD/\$HOME"
fi

# Project dir (the writable mount), box home, and the read-only mount targets.
PROJECT_DIR=$(jqv '.paths.project'); [ -n "$PROJECT_DIR" ] || PROJECT_DIR="$PWD"
BOX_HOME=$(jqv '.paths.home');       [ -n "$BOX_HOME" ]    || BOX_HOME="$HOME"
# Read-only mount targets = the container-side path of every mount ending in :ro.
RO_TARGETS=$(jql '.config.mounts[]? | select(test(":ro$")) | split(":")[1]')
# Host home = the /home/<user> | /Users/<user> | /root ancestor of the project
# path (host paths are mounted at the same path in-box). Empty if the project is
# not under a recognizable home — then the host-dotfile check is skipped.
HOST_HOME=$(printf '%s\n' "$PROJECT_DIR" \
  | sed -nE 's#^(/home/[^/]+|/Users/[^/]+|/root)(/.*)?$#\1#p')

# Sandbox settings (used to set the RIGHT expectation per machine's config).
S_SSH=$(jqv '.config.ssh_agent')
S_GH=$(jqv '.config.gh_token')
S_NONET=$(jqv '.config.no_network')
S_NET=$(jqv '.config.network')
S_DOCKER=$(jqv '.config.docker')
S_SCRATCH=$(jqv '.config.scratch')
S_ROPROJ=$(jqv '.config.readonly_project')
S_CCFG=$(jqv '.config.claude_config')

# ── 1. Identity & privilege ───────────────────────────────────────────────────
section "1. Identity & privilege"
u=$(id -un 2>/dev/null)
case "$u" in root|"") warn "running as '${u:-?}' in-box (most images drop to an unprivileged user)" ;;
                    *) pass "running as unprivileged user '$u'" ;; esac
[ "$(id -u 2>/dev/null)" != 0 ] && pass "uid is non-zero ($(id -u))" \
                                || warn "uid 0 in-box (container-root; still cannot touch the host — see §6)"

# ── 2. Filesystem confinement ─────────────────────────────────────────────────
section "2. Filesystem confinement"

# 2a. The project mount: writable (the agent needs it) unless launched read-only.
canary="$PROJECT_DIR/.yoloboxcheck_$$"
if (touch "$canary") 2>/dev/null; then
  rm -f "$canary"
  if [ "$S_ROPROJ" = true ]; then warn "project is writable but readonly_project=true (config mismatch?)"
  else pass "current project is writable ($PROJECT_DIR)"; fi
else
  if [ "$S_ROPROJ" = true ]; then pass "project is read-only, as configured (readonly_project=true)"
  else warn "project NOT writable ($PROJECT_DIR) — launched outside a writable mount?"; fi
fi

# 2b. Read-only mounts must reject writes. Iterate via here-doc (not a pipe) so
# the pass/fail counters survive. Skip the project itself (it is the nested rw
# mount that legitimately wins over any read-only parent).
if [ -n "$RO_TARGETS" ]; then
  while IFS= read -r m; do
    [ -n "$m" ] || continue
    [ "$m" = "$PROJECT_DIR" ] && continue
    [ -e "$m" ] || continue
    c="$m/.yoloboxcheck_should_fail_$$"
    if (touch "$c") 2>/dev/null; then
      fail "wrote into read-only mount $m — it is NOT actually read-only!"; rm -f "$c" 2>/dev/null
    else
      pass "read-only mount is unwritable: $m"
    fi
  done <<EOF
$RO_TARGETS
EOF
else
  # Fallback when the manifest has no ro mounts (or is unreadable): probe the
  # project's parent, which in the common nested-mount layout is the ro parent.
  parent=$(dirname "$PROJECT_DIR")
  if [ "$parent" != "/" ] && [ "$parent" != "$PROJECT_DIR" ] && [ -e "$parent" ]; then
    c="$parent/.yoloboxcheck_should_fail_$$"
    if (touch "$c") 2>/dev/null; then
      rm -f "$c" 2>/dev/null
      info "project parent ($parent) is writable — no read-only parent mount here (config-dependent)"
    else
      pass "project parent is read-only: $parent"
    fi
  else
    info "no read-only mounts to test in this config — sibling-confinement N/A"
  fi
fi

# 2c. Host home dotfiles (secrets) must not be reachable in-box. Derived from the
# project path, not hardcoded; skipped when no host home can be inferred.
if [ -n "$HOST_HOME" ] && [ "$HOST_HOME" != "$BOX_HOME" ]; then
  for s in .ssh .gnupg .password-store .aws .netrc .bash_history .docker/config.json; do
    p="$HOST_HOME/$s"
    if [ -e "$p" ]; then fail "host secret path reachable in-box: $p (should be invisible)"
    else pass "absent in-box: $p"; fi
  done
else
  info "no distinct host home inferable from project path — skipping host-dotfile absence check"
fi

# ── 3. Credential isolation (box-local; host-agnostic) ────────────────────────
section "3. Credential isolation"
if [ -n "${SSH_AUTH_SOCK:-}" ]; then
  fail "SSH agent forwarded (\$SSH_AUTH_SOCK set) — box could sign/auth as you"
else
  pass "no SSH agent forwarded (\$SSH_AUTH_SOCK empty)"
fi
[ "$S_SSH" = false ] && info "manifest confirms ssh_agent=false"
if have ssh-add && ssh-add -l >/dev/null 2>&1; then
  fail "ssh-add lists keys — an agent with your keys is reachable"
else
  pass "ssh-add reaches no agent/keys"
fi
if have gpg && [ -n "$(gpg --list-secret-keys 2>/dev/null)" ]; then
  fail "GPG secret keys present in-box"
else
  pass "no GPG secret keys in-box"
fi

# ── 4. GitHub capability (open by design) ─────────────────────────────────────
# We MEASURE the forwarded token's write capability rather than assuming it. A
# read-only fine-grained PAT can read your repos but not push/PR — a very
# different blast radius. The API's repo `.permissions.push` reflects your ROLE,
# not the token, so it lies for fine-grained PATs; instead we negotiate a
# receive-pack push with `--dry-run` (never mutates) and read the verdict. Echoes
# "<verdict>\t<repo>" where verdict is writable|readonly|unknown. Run in a command
# substitution, so it can't set globals — it returns everything on stdout.
gh_write_probe() {
  have gh && have git || { printf 'unknown\t'; return; }
  # A repo the token can READ — the question is whether it can also WRITE it.
  repo=$(gh api 'user/repos?affiliation=owner&sort=updated&per_page=1' \
         --jq '.[0].full_name' 2>/dev/null)
  [ -n "$repo" ] || { printf 'unknown\t'; return; }
  t=$(mktemp -d 2>/dev/null) || { printf 'unknown\t%s' "$repo"; return; }
  git -C "$t" init -q >/dev/null 2>&1
  git -C "$t" config user.email probe@example.com
  git -C "$t" config user.name  yolobox-check-probe
  echo probe > "$t/p"; git -C "$t" add p >/dev/null 2>&1
  git -C "$t" commit -qm probe >/dev/null 2>&1
  # --dry-run does the full auth + permission negotiation but never updates the
  # remote. A read-only token is rejected at the receive-pack advertisement (403).
  tmo=""; have timeout && tmo="timeout 20"
  out=$(cd "$t" && GIT_TERMINAL_PROMPT=0 $tmo git push --dry-run \
        "https://github.com/$repo.git" HEAD:refs/heads/__yolobox_write_probe__ 2>&1)
  rm -rf "$t" 2>/dev/null
  case "$out" in
    *denied*|*403*|*"not granted"*|*"Permission to"*) printf 'readonly\t%s' "$repo" ;;
    *fatal*|*"could not"*|*"Could not"*|*"unable to"*) printf 'unknown\t%s'  "$repo" ;;
    *) printf 'writable\t%s' "$repo" ;;
  esac
}

section "4. GitHub capability  (gh_token — measured, not assumed)"
if have gh && gh auth status >/dev/null 2>&1; then
  who=$(gh api user --jq .login 2>/dev/null)
  probe=$(gh_write_probe)
  verdict=$(printf '%s' "$probe" | cut -f1)
  prepo=$(printf '%s' "$probe" | cut -f2)
  case "$verdict" in
    writable)
      warn "GitHub token for '${who:-you}' CAN PUSH (verified write to $prepo) — box can push/PR as you"
      info "  to limit this, use a READ-ONLY fine-grained PAT, or set gh_token=false in config.toml" ;;
    readonly)
      pass "GitHub token for '${who:-you}' is READ-ONLY (push to $prepo denied 403) — box cannot push/PR as you"
      info "  it can clone/read your repos over HTTPS, but cannot modify them or your account" ;;
    *)
      warn "GitHub token for '${who:-you}' present, but write-capability is UNDETERMINED (offline / no readable repo)"
      info "  re-run with network to measure; until then assume it MIGHT be writable" ;;
  esac
else
  pass "no usable GitHub credentials in-box (cannot act as you on GitHub)"
  [ "$S_GH" = true ] && info "  (manifest says gh_token=true, but no live gh session resolved)"
fi

# ── 5. Network reach (open by design) ─────────────────────────────────────────
section "5. Network reach  (egress is expected for a dev box)"
[ -n "$S_NET" ]    && info "manifest network mode: $S_NET"
[ "$S_NONET" = true ] && info "manifest no_network=true — egress is expected to be BLOCKED"
if have curl; then
  code=$(curl -sS -m 8 -o /dev/null -w '%{http_code}' https://example.com 2>/dev/null)
  if [ "$code" = 200 ]; then
    if [ "$S_NONET" = true ]; then
      fail "internet reachable (HTTP $code) despite no_network=true — egress is NOT blocked"
    else
      warn "internet egress works (HTTP $code to example.com) — expected; the box CAN reach the net"
      info "  boundary is filesystem+host, NOT network. Lock down via yolobox network mode if needed."
    fi
  else
    info "no internet egress (curl got '${code:-none}') — network appears restricted"
  fi
else
  info "curl absent — skipping egress probe"
fi
info "reminder: 127.0.0.1 in-box = this container, NOT your host's localhost"

# ── 6. Privilege & host isolation ─────────────────────────────────────────────
section "6. Host isolation"
if [ -S /var/run/docker.sock ] || [ -S /run/docker.sock ]; then
  if [ "$S_DOCKER" = true ]; then
    warn "host Docker socket mounted (docker=true) — by design, but it IS a host-reach vector"
  else
    fail "host Docker socket mounted — container-root + host socket = HOST ESCAPE"
  fi
else
  pass "no host Docker socket mounted (cannot drive the host daemon)"
  [ "$S_DOCKER" = true ] && info "  (manifest says docker=true but no socket found)"
fi

# ══════════════════════════════════════════════════════════════════════════════
# FUNCTIONALITY — from here down, can the agent actually get work done? Problems
# below are WARN (not FAIL): they degrade usefulness but are not safety breaches.
# ══════════════════════════════════════════════════════════════════════════════

# ── 7. Tool stack (build & language) ──────────────────────────────────────────
section "7. Tool stack (build & language)"
missing=""
for t in git rg jq; do have "$t" || missing="$missing $t"; done
[ -z "$missing" ] && pass "essential CLI present (git, rg, jq)" \
                  || warn "missing essentials:$missing"
# R / LaTeX are image-specific extras; probe only when present, so this stays
# meaningful on a vanilla yolobox base too.
if have Rscript; then
  nd=$(Rscript -e 'cat(1/3)' 2>/dev/null)
  case "$nd" in 0.333*) pass "Rscript numeric OK ($nd, dot decimal / LC_NUMERIC=C)" ;;
                *) warn "Rscript numeric unexpected ('$nd') — check LC_NUMERIC" ;; esac
  info "exercising the R / LaTeX chain where present (slow)…"
  if R -q -e 'library(mlr3); library(tidyverse)' >/dev/null 2>&1; then
    pass "R: mlr3 + tidyverse load"
  else info "R: mlr3/tidyverse not installed/loadable (not an SLDS image?)"; fi
  if R -q -e 'library(vistool)' >/dev/null 2>&1; then
    pass "R: vistool loads (magick + chromium dep chain intact)"
  else info "R: vistool not installed/loadable (not an SLDS image?)"; fi
else
  info "no R in this image — skipping the R/LaTeX stack checks"
fi
if have pdflatex; then
  tdir=$(mktemp -d 2>/dev/null || echo /tmp)
  printf '\\documentclass{article}\\begin{document}hi\\end{document}\n' > "$tdir/t.tex"
  if pdflatex -interaction=nonstopmode -output-directory="$tdir" "$tdir/t.tex" >/dev/null 2>&1; then
    pass "LaTeX: pdflatex builds a document"
  else warn "LaTeX: pdflatex present but the build failed"; fi
  rm -rf "$tdir" 2>/dev/null
fi

# ── 8. Git & commit workflow (the core CC loop) ───────────────────────────────
section "8. Git & commit workflow"
# Identity — CC's commits need an author. git_config=true copies the host's in.
gname=$(git config --get user.name 2>/dev/null)
gemail=$(git config --get user.email 2>/dev/null)
if [ -n "$gname" ] && [ -n "$gemail" ]; then
  pass "git identity set ($gname <$gemail>)"
else
  warn "git user.name/user.email not set — CC commits fail or misattribute (git_config=true?)"
fi
# Project is a git work tree where you launched it.
if git -C "$PROJECT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  pass "project is a git work tree ($PROJECT_DIR)"
else
  info "project is not a git repo — git workflow checks limited"
fi
# delta pager wired (image ergonomics for diffs/log/show).
case "$(git config --get core.pager 2>/dev/null)" in
  *delta*) pass "git pager is delta (syntax-highlighted diffs)" ;;
  *)       info "git core.pager is not delta" ;;
esac
# A real commit must work — in a THROWAWAY repo, never your project. This also
# catches the classic trap: a copied-in host gitconfig with commit.gpgsign=true
# but no GPG key in-box makes EVERY CC commit fail silently.
gtmp=$(mktemp -d 2>/dev/null)
if [ -n "$gtmp" ] && git -C "$gtmp" init -q >/dev/null 2>&1; then
  git -C "$gtmp" config user.email check@example.com
  git -C "$gtmp" config user.name  yolobox-check
  echo probe > "$gtmp/f"
  if git -C "$gtmp" add f >/dev/null 2>&1 && git -C "$gtmp" commit -qm probe >/dev/null 2>&1; then
    pass "git can stage & commit (throwaway repo; uses your real git config)"
  else
    if [ "$(git config --get commit.gpgsign 2>/dev/null)" = true ]; then
      warn "commit FAILED: commit.gpgsign=true but no GPG key in-box — CC commits will fail. Disable signing or don't copy it in."
    else
      warn "git commit failed in a clean throwaway repo — the core git workflow is broken"
    fi
  fi
  rm -rf "$gtmp" 2>/dev/null
fi

# ── 9. Claude Code readiness ──────────────────────────────────────────────────
section "9. Claude Code readiness"
if have claude; then
  pass "claude resolves: $(claude --version 2>/dev/null | head -1)"
else
  warn "claude not on PATH — the harness is missing from this image"
fi
# settings.json (often mounted in): present AND valid JSON — CC refuses bad JSON.
cset="$BOX_HOME/.claude/settings.json"
if [ -f "$cset" ]; then
  if have jq && jq -e . "$cset" >/dev/null 2>&1; then
    pass "CC settings.json present and valid JSON"
  else
    warn "CC settings.json present but NOT valid JSON — CC may ignore or refuse it"
  fi
else
  info "no ~/.claude/settings.json in-box (CC uses defaults)"
fi
# statusline helper (mounted in this setup): present + executable.
csl="$BOX_HOME/.claude/statusline-command.sh"
if [ -f "$csl" ]; then
  [ -x "$csl" ] && pass "CC statusline script present & executable" \
                || warn "CC statusline present but not executable (chmod +x)"
fi
# Global agent instructions / skills copied in (copy_agent_instructions=true).
[ -f "$BOX_HOME/.claude/CLAUDE.md" ] && info "global CLAUDE.md present in-box"
if [ -d "$BOX_HOME/.claude/skills" ]; then
  ns=$(find "$BOX_HOME/.claude/skills" -maxdepth 2 -name SKILL.md 2>/dev/null | wc -l | tr -d ' ')
  info "standalone skills available in-box: ${ns:-0}"
fi
# Auth posture (never prints the token value — only its presence).
if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
  info "CLAUDE_CODE_OAUTH_TOKEN present — headless/-p runs can authenticate"
else
  info "no OAuth token forwarded — interactive /login needed once per session (claude_config=${S_CCFG:-?})"
fi

# ── 10. Edit → build → run loop (can the agent run code it writes?) ───────────
section "10. Edit-build-run loop"
rtmp=$(mktemp -d 2>/dev/null || echo "/tmp/yoloboxcheck.$$")
mkdir -p "$rtmp" 2>/dev/null
ran=0
if have node; then
  printf 'console.log("ok")\n' > "$rtmp/t.js"
  [ "$(node "$rtmp/t.js" 2>/dev/null)" = ok ] \
    && { pass "node runs a written script"; ran=1; } || warn "node failed to run a script"
fi
if have python3; then
  [ "$(python3 -c 'print("ok")' 2>/dev/null)" = ok ] \
    && { pass "python3 runs"; ran=1; } || warn "python3 present but failed to run"
fi
ccbin=$(command -v cc 2>/dev/null || command -v gcc 2>/dev/null || command -v clang 2>/dev/null)
if [ -n "$ccbin" ]; then
  printf '#include <stdio.h>\nint main(void){puts("ok");return 0;}\n' > "$rtmp/t.c"
  if "$ccbin" "$rtmp/t.c" -o "$rtmp/t.out" 2>/dev/null && [ "$("$rtmp/t.out" 2>/dev/null)" = ok ]; then
    pass "C toolchain compiles & runs ($(basename "$ccbin"))"; ran=1
  else
    warn "C compile/run failed via $(basename "$ccbin")"
  fi
fi
[ "$ran" -eq 0 ] && info "no node/python3/C compiler found to exercise an edit-run loop"
rm -rf "$rtmp" 2>/dev/null

# ── 11. Environment & resources ───────────────────────────────────────────────
section "11. Environment & resources"
# Editor — git commit-message editing, sudoedit, etc. honor this. The *vi*
# pattern already covers vim/nvim/vi, so list only non-overlapping alternatives.
case "${EDITOR:-}${VISUAL:-}" in
  *nano*|*emacs*|*vi*) pass "EDITOR/VISUAL set (EDITOR='${EDITOR:-}', VISUAL='${VISUAL:-}')" ;;
  *) info "EDITOR/VISUAL not set to a known editor (EDITOR='${EDITOR:-unset}')" ;;
esac
# $HOME/.local/bin on PATH so user-scope installs win over system ones.
case ":$PATH:" in
  *":$BOX_HOME/.local/bin:"*) pass "$BOX_HOME/.local/bin is on PATH" ;;
  *) info "$BOX_HOME/.local/bin not on PATH (user-scope installs may be shadowed)" ;;
esac
# Passwordless sudo lets CC apt-install a tool a task needs.
if have sudo && sudo -n true 2>/dev/null; then
  info "passwordless sudo available — CC can install packages in-box (ephemeral)"
else
  info "no passwordless sudo — extra packages need a .yolobox.Dockerfile fragment"
fi
# Login shell.
case "${SHELL:-}" in *zsh*) info "login shell: zsh" ;; *) info "login shell: ${SHELL:-unset}" ;; esac
# Ergonomic CLI inventory — informational, never fails the run.
nh=""; for t in fd bat fzf zoxide delta starship glow yq tmux; do have "$t" || nh="$nh $t"; done
[ -z "$nh" ] && info "ergonomic CLI all present (fd bat fzf zoxide delta starship glow yq tmux)" \
             || info "ergonomic CLI missing:$nh"
# Disk headroom — low space silently breaks builds, installs, and git ops.
for d in "$PROJECT_DIR" /tmp "$BOX_HOME"; do
  [ -d "$d" ] || continue
  avail_kb=$(df -Pk "$d" 2>/dev/null | awk 'NR==2{print $4}')
  [ -n "$avail_kb" ] || continue
  mb=$((avail_kb/1024))
  if [ "$mb" -lt 512 ]; then warn "low disk on $d: ${mb} MB free (<512 MB)"
  else info "disk free on $d: ${mb} MB"; fi
done

# ── 12. Persistence semantics ─────────────────────────────────────────────────
section "12. Persistence (home volume vs ephemeral root)"
if [ "$S_SCRATCH" = true ]; then
  info "scratch mode (config.scratch=true): \$HOME is EPHEMERAL this run, nothing persists"
else
  marker="$BOX_HOME/.yolobox-check.persist"
  if [ -f "$marker" ]; then
    info "previous marker survived: $(cat "$marker" 2>/dev/null) — \$HOME persists across launches"
  else
    info "no prior marker — writing one; relaunch a box and re-run to see it survive"
  fi
  printf 'written-by-yolobox-check pid=%s\n' "$$" > "$marker" 2>/dev/null
  info "note: \$HOME ($BOX_HOME) PERSISTS between sessions; /tmp & root fs reset each launch"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
section "Summary"
printf '  %s%d pass%s, %s%d warn%s, %s%d fail%s\n' \
  "$C_GREEN" "$PASS_N" "$C_OFF" "$C_YELLOW" "$WARN_N" "$C_OFF" "$C_RED" "$FAIL_N" "$C_OFF"
if [ "$FAIL_N" -gt 0 ]; then
  printf '  %sCONTAINMENT BROKEN:%s %s\n' "$C_BOLD" "$C_OFF" "$FIRST_FAIL"
  printf '  Do NOT run --dangerously-skip-permissions until this is fixed.\n'
  exit 1
fi
printf '  %sSafety:%s host filesystem, local secrets & privilege are contained.\n' "$C_BOLD" "$C_OFF"
if [ "$WARN_N" -gt 0 ]; then
  printf '  Review the WARNs above — each is one of:\n'
  printf '    • a capability OPEN BY DESIGN (GitHub push / network egress), or\n'
  printf '    • a FUNCTIONALITY gap (e.g. commits would fail, a tool is missing).\n'
  printf '  Safety warns: accept or tighten gh_token / network in config.toml.\n'
fi
exit 0
