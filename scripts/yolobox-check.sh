#!/bin/sh
# trust-check.sh — live, in-box verification of the yolobox sandbox boundary.
#
# Purpose
#   Answer one question empirically: "can I let an agent run with
#   --dangerously-skip-permissions in this box?" It runs the checks from
#   TRUST-TESTS.md (this file's prose companion) and prints a categorized
#   PASS/WARN/FAIL report with a bottom-line verdict.
#
#   PASS  = a containment boundary HOLDS (host fs / secrets / privilege).
#   FAIL  = a boundary is BROKEN — do not trust skip-permissions until fixed.
#   WARN  = a capability is OPEN BY DESIGN (GitHub push, network egress).
#           Not a breach — a decision: accept it, or disable it in config.toml.
#   INFO  = neutral context.
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
#   sh trust-check.sh           # run every check (incl. the heavy R/LaTeX stack)
#   sh trust-check.sh -h        # help
#
# Exit status: 0 = no FAIL (WARN allowed), 1 = at least one containment FAIL,
#              2 = wrong context (run on host) / bad usage.
set -u

# ── Options ───────────────────────────────────────────────────────────────────
for arg in "$@"; do
  case "$arg" in
    -h|--help) printf 'Usage: sh trust-check.sh\n'; exit 0 ;;
    *) printf 'trust-check: unknown argument: %s\n' "$arg" >&2; exit 2 ;;
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
jqv() { [ "$HAVE_CTX" -eq 1 ] && jq -r "$1 // empty" "$CTX" 2>/dev/null; }
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
canary="$PROJECT_DIR/.trustcheck_$$"
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
    c="$m/.trustcheck_should_fail_$$"
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
    c="$parent/.trustcheck_should_fail_$$"
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
section "4. GitHub capability  (gh_token — a DECISION, not a breach)"
if have gh && gh auth status >/dev/null 2>&1; then
  who=$(gh api user --jq .login 2>/dev/null)
  warn "box is logged into GitHub as '${who:-you}' — it CAN push/PR as you over HTTPS"
  info "  accept this (treat 'agent commits as me' as in-scope) OR set gh_token=false in config.toml"
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

# ── 7. Tools work (so the agent can finish without manual installs) ───────────
section "7. Tool stack"
have claude && pass "claude resolves: $(claude --version 2>/dev/null | head -1)" \
            || warn "claude not on PATH (harness not installed in this image?)"
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

# ── 8. Persistence semantics ──────────────────────────────────────────────────
section "8. Persistence (home volume vs ephemeral root)"
if [ "$S_SCRATCH" = true ]; then
  info "scratch mode (config.scratch=true): \$HOME is EPHEMERAL this run, nothing persists"
else
  marker="$BOX_HOME/.trustcheck_persist"
  if [ -f "$marker" ]; then
    info "previous marker survived: $(cat "$marker" 2>/dev/null) — \$HOME persists across launches"
  else
    info "no prior marker — writing one; relaunch a box and re-run to see it survive"
  fi
  printf 'written-by-trust-check pid=%s\n' "$$" > "$marker" 2>/dev/null
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
printf '  %sVerdict:%s host filesystem, local secrets & privilege are contained.\n' "$C_BOLD" "$C_OFF"
if [ "$WARN_N" -gt 0 ]; then
  printf '  The WARNs above are capabilities OPEN BY DESIGN (GitHub / network):\n'
  printf '  the boundary is your host & secrets, NOT your GitHub account or the net.\n'
  printf '  Accept them, or tighten gh_token / network mode in config.toml.\n'
fi
printf '  Full rationale: yolobox/TRUST-TESTS.md\n'
exit 0
