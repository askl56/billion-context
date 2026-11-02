#!/usr/bin/env bash
# fork-update.sh — bring this fork up to upstream billion-context safely.
#
# Why this exists: upstream moves ~50 commits/day and the fork carries a
# handful of local commits on top of it. A raw `git pull --rebase` is a
# coin flip: upstream rewrites the same areas the fork touches (the
# prompt_cache_key policy has been rewritten three times), so most updates
# need a human decision about which local commits upstream already
# absorbed. This script does the mechanical parts and prints exactly the
# decisions that remain.
#
#   ./fork-tools/fork-update.sh status    # what upstream did, what we carry
#   ./fork-tools/fork-update.sh update    # fetch + rebase + build + test + report
#   ./fork-tools/fork-update.sh baseline  # refresh the known-failing test list
#
# Exit codes: 0 ok · 1 usage/env error · 2 rebase conflict (needs a human)
#             3 build/typecheck failed · 4 tests failed beyond the baseline
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

UPSTREAM_REMOTE="${FORK_UPDATE_UPSTREAM:-origin}"
FORK_REMOTE="${FORK_UPDATE_FORK:-fork}"
BRANCH="${FORK_UPDATE_BRANCH:-fork/stable-node-command}"
BASELINE="$REPO/fork-tools/baseline-failures.txt"
RUN_TESTS="${FORK_UPDATE_RUN_TESTS:-1}"

say()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
info() { printf '  %s\n' "$*"; }
warn() { printf '\033[33m  ! %s\033[0m\n' "$*"; }
die()  { printf '\033[31m  x %s\033[0m\n' "$*" >&2; exit "${2:-1}"; }

# Version of the package.json at a given git ref (or the worktree).
pkg_version() {
  local ref="${1:-HEAD}"
  git show "$ref:package.json" 2>/dev/null | node -p "JSON.parse(require('fs').readFileSync(0,'utf8')).version" 2>/dev/null || echo "?"
}

# Failing test names from a `npm test` log, normalized (durations stripped)
# so the set can be compared across runs.
failing_tests() {
  # '✖ failing tests:' is node's summary HEADER, not a test name — it must
  # never enter the set (it would read as a new failure on every run).
  grep -E '^✖' "$1" 2>/dev/null \
    | grep -vE '^✖ (failing tests:|passing tests:|tests? )' \
    | sed -E 's/ \([0-9.]+ms\)$//' \
    | sort -u
}

cmd_status() {
  say "Fetch"
  git fetch --quiet "$UPSTREAM_REMOTE" master 2>/dev/null || warn "fetch failed (offline?) — using local refs"
  git fetch --quiet "$FORK_REMOTE" "$BRANCH" 2>/dev/null || true

  local up="$UPSTREAM_REMOTE/master" cur="$BRANCH"
  say "Versions"
  info "worktree           $(pkg_version HEAD)   ($(git rev-parse --short HEAD))"
  info "upstream master    $(pkg_version "$up")   ($(git rev-parse --short "$up"))"
  info "behind / ahead     $(git rev-list --count "$cur..$up") behind · $(git rev-list --count "$up..$cur") ahead"

  say "Upstream since our base"
  git log --oneline --no-merges "$cur..$up" | head -30 | sed 's/^/  /'
  local n; n="$(git rev-list --count "$cur..$up")"
  [ "$n" -gt 30 ] && info "... and $((n - 30)) more"

  say "Local commits we carry"
  git log --oneline --no-merges "$up..$cur" | sed 's/^/  /'
  if ! git rev-list --count "$up..$cur" | grep -qv '^0$'; then :; fi

  say "Supersession hints"
  # Upstream rarely cherry-picks a fork commit verbatim, so patch-equality
  # (git cherry) misses most cases. Instead, look for upstream commits that
  # mention the same issue numbers: that is how an absorbed change usually
  # announces itself.
  local issues
  issues="$(git log --format='%s' "$up..$cur" | grep -oE '#[0-9]+' | sort -u | tr '\n' ' ')"
  if [ -z "$issues" ]; then
    info "our commits carry no issue references"
  else
    info "issues our commits touch: $issues"
    for i in $issues; do
      local hits; hits="$(git log --oneline "$up" --grep="$i" | head -2)"
      [ -n "$hits" ] && info "$i upstream:" && echo "$hits" | sed 's/^/      /'
    done
    info "read each: if upstream reimplemented the same behaviour, drop our commit"
    info "(git rebase --skip <sha>) — the upstream version wins by design, not by accident."
  fi
}

cmd_update() {
  cmd_status

  local up="$UPSTREAM_REMOTE/master" cur="$BRANCH"
  local behind; behind="$(git rev-list --count "$up..$cur")"
  if [ "$behind" = "0" ]; then
    say "Already up to date"
    return 0
  fi

  say "Backup"
  local tag="backup/pre-$(pkg_version "$up")-$(date +%Y-%m-%d)"
  git branch -f "$tag" "$cur"
  info "created $tag at $(git rev-parse --short "$cur")"

  say "Rebase onto upstream"
  git rebase "$up" "$cur" 2>&1 | tail -20
  local rc=${PIPESTATUS[0]}
  if [ "$rc" != "0" ]; then
    warn "rebase stopped on a conflict — this is the part that needs a human."
    git status --short | grep -E '^(UU|AA|DD)' | sed 's/^/      /'
    info "decide per file: keep upstream's version (upstream rewrote this area) or ours."
    info "  git checkout --theirs <file>   # take upstream's side (usual case)"
    info "  git rebase --continue           # or resolve by hand, then:"
    info "  git rebase --skip <sha>        # drop a local commit upstream absorbed"
    info "  git rebase --abort             # back out entirely"
    return 2
  fi
  info "rebase clean"

  say "Dependencies"
  npm install --no-audit --no-fund 2>&1 | tail -3

  say "Typecheck"
  if ! npm run typecheck 2>&1 | tail -5; then
    die "typecheck failed" 3
  fi
  info "typecheck clean"

  say "Build"
  if ! npm run build 2>&1 | tail -5; then
    die "build failed" 3
  fi
  info "built $(cat dist/build-info.json | tr -d '\n ')"

  if [ "$RUN_TESTS" = "0" ]; then
    say "Tests skipped (FORK_UPDATE_RUN_TESTS=0)"
    return 0
  fi

  say "Tests (this takes a few minutes)"
  local log; log="$(mktemp -t fork-update-test.XXXXXX)"
  npm test > "$log" 2>&1
  local now; now="$(failing_tests "$log")"
  local base=""
  [ -f "$BASELINE" ] && base="$(sort -u "$BASELINE")"

  if [ -z "$base" ]; then
    warn "no baseline yet — recording the current failures as the baseline"
    printf '%s\n' "$now" > "$BASELINE"
    info "wrote $BASELINE"
    echo "$log" > /dev/null
    return 0
  fi

  local regress added fixed
  # `now` already excludes node's summary header, so the comm output needs
  # no further filtering — filtering here instead would leave `added` (the
  # set the verdict is based on) unfiltered.
  regress="$(comm -23 <(echo "$now") <(echo "$base"))"
  added="$regress"
  fixed="$(comm -13 <(echo "$now") <(echo "$base"))"

  say "Test result"
  grep -E '^ℹ (tests|pass|fail)' "$log" | tail -3 | sed 's/^/  /'
  if [ -n "$added" ]; then
    warn "NEW failures vs baseline (these are ours):"
    echo "$added" | sed 's/^/      /'
    info "full log: $log"
    return 4
  fi
  info "no new failures vs baseline"
  if [ -n "$fixed" ]; then
    info "fixed since the baseline:"
    echo "$fixed" | sed 's/^/      /'
  fi
  info "full log: $log"
  return 0
}

cmd_baseline() {
  say "Recording the current failures as the baseline"
  local log; log="$(mktemp -t fork-baseline.XXXXXX)"
  npm test > "$log" 2>&1
  failing_tests "$log" > "$BASELINE"
  info "wrote $BASELINE ($(wc -l < "$BASELINE") entries)"
  info "full log: $log"
}

case "${1:-status}" in
  status)   cmd_status ;;
  update)   cmd_update ;;
  baseline) cmd_baseline ;;
  *) die "usage: $0 {status|update|baseline}" ;;
esac
