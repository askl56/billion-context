# fork-tools — keeping this fork current

This fork tracks upstream [billion-context](https://github.com/ranxianglei/billion-context)
and carries a small set of local commits on top. Upstream moves fast (~50
commits/day), and the areas this fork touches are exactly the areas upstream
keeps rewriting — the `prompt_cache_key` policy alone was redesigned three
times in two weeks. So "update" is not `git pull`; it is a short decision
process, and these scripts do the mechanical part of it.

## The update cycle

```bash
cd /Users/ams/code/forks/billion-context
./fork-tools/fork-update.sh status    # what upstream did, what we carry
./fork-tools/fork-update.sh update    # fetch → backup → rebase → build → test → report
```

`update` exits **2** if the rebase stops on a conflict — that is the only
step that needs a human, and the script prints the exact commands for it.
Every other failure mode (typecheck, build, tests) is reported with the
command to reproduce.

### When the rebase conflicts

Upstream usually wins, because upstream's version of a rewritten area is
the one with design rationale behind it. Decide per commit:

```bash
git checkout --theirs <file>   # take upstream's side (the usual case)
git rebase --continue
git rebase --skip <sha>        # drop a local commit upstream absorbed
git rebase --abort             # back out entirely
```

`git rebase --skip` is right when upstream **reimplemented** the same
behaviour rather than cherry-picking our commit. Example from the 0.1.211
update: our `ddc4d0ab` added a static loopback-only gate for stamping
`prompt_cache_key`; upstream replaced it with a runtime A/B probe
(`7f15eacd`, `e26ac07b`) that learns which upstreams reject the field.
Upstream's design wins on purpose — the static gate cost the two largest
relay/account-pool populations their prefix-cache affinity.

To check whether a local commit was absorbed before you rebase, look for
upstream commits mentioning the same issue number:

```bash
git log --oneline origin/master --grep='#2645'
```

## The test baseline

Upstream's suite has pre-existing failures (13 on 0.1.211 — see
`baseline-failures.txt`). A raw `npm test` therefore never goes green, and
"did my change break something?" cannot be answered by exit code.

The script compares against `baseline-failures.txt` and reports only
**new** failures. After an upstream update that legitimately changes which
tests fail, refresh it:

```bash
./fork-tools/fork-update.sh baseline
```

Baseline should be captured from a **clean upstream** worktree, not the
fork, so it stays a statement about upstream rather than about us:

```bash
git worktree add /tmp/bc-base upstream/master
cd /tmp/bc-base && npm install && npm run build && npm test
```

## Layout

| file | what it is |
|---|---|
| `fork-update.sh` | the update driver (`status` / `update` / `baseline`) |
| `baseline-failures.txt` | upstream's known-failing tests on the current base |

`fork-tools/` deliberately sits outside `src/`, `tests/` and `scripts/` so
upstream's own gates (`check-unused-exports.mjs`, which scans `src/`,
`tests/`, `scripts/` and root `*.ts`/`*.mjs`/`*.cjs`) never see it — the
fork's diff stays confined to files upstream does not own.

## What this fork carries

Three local commits, all still live upstream-relative:

- `f1b0544b` — persist the **stable** node path in host configs. A Homebrew
  Cellar path (`/opt/homebrew/Cellar/node/26.12.0/bin/node`) dies on the
  next `brew upgrade`, which would break every command written into a
  codex/opencode/pi config.
- `e116295f` — pin probe-and-remember **shape-independence**: a strict
  *remote* upstream self-heals the same way a loopback one does. Upstream's
  own probe tests only bind their mock upstream to `127.0.0.1`.
- `01715ef6` — assert the stable node path in the tests that pinned the
  literal `process.execPath`.
