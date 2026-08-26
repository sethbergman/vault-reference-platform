#!/usr/bin/env bash
#
# run-tests.sh — Behaviour of scripts/generate-docs-index.sh
#
# Usage:
#   ./tests/docs-index/run-tests.sh
#
# WHAT THIS IS FOR
#
# The generated index is only worth having if it is a faithful function
# of the documents: a heading the generator misreads becomes a wrong
# description that CI then defends, which is worse than no index.
#
# Most cases run the generator against a fixture tree rather than against
# docs/ — a copy of the script beside a docs/ of the suite's own making,
# which works because the script locates the doc set relative to itself
# and needs no test-only switch to be pointed elsewhere. The exception is
# the first check, which asserts against the real doc set.
#
# Requirements: bash, awk, diff

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
GENERATOR="${REPO_ROOT}/scripts/generate-docs-index.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0

green() { printf '\033[32m%s\033[0m\n' "$*"; }
red()   { printf '\033[31m%s\033[0m\n' "$*"; }

ok()  { PASS=$((PASS + 1)); green "  PASS  $1"; }
bad() { FAIL=$((FAIL + 1)); red   "  FAIL  $1"; [[ -n "${2:-}" ]] && printf '%s\n' "$2"; return 0; }

# Build a throwaway repo whose docs/ is whatever the caller writes into
# the directory this prints.
new_fixture() {
    local root
    root="$(mktemp -d "${WORK}/fixture.XXXXXX")"
    mkdir -p "${root}/scripts" "${root}/docs"
    cp "$GENERATOR" "${root}/scripts/"
    printf '%s' "$root"
}

# ---------------------------------------------------------------------------
printf '\n=== The committed index covers every document ===\n'
# ---------------------------------------------------------------------------
# Asserted positively and by name: "the index is not stale" is already
# CI's job, but a generator that silently skipped a file would satisfy
# that check forever, because the omission would be in both halves of the
# diff.
missing=""
for doc in "${REPO_ROOT}"/docs/*.md; do
    name="$(basename "$doc")"
    [[ "$name" == "README.md" ]] && continue
    grep -qF "($name)" "${REPO_ROOT}/docs/README.md" || missing+=" docs/$name"
done
if [[ -z "$missing" ]]; then
    ok "every file in docs/ is linked from docs/README.md"
else
    bad "every file in docs/ is linked from docs/README.md" \
        "Not linked:${missing} — run: make docs"
fi

# ---------------------------------------------------------------------------
printf '\n=== Headings inside fenced code blocks are not sections ===\n'
# ---------------------------------------------------------------------------
# Several documents open with a shell block, and a comment in one begins
# with `##`. Read as markdown that is a section heading; read as shell it
# is a comment. The fixture uses a comment the assertion does not name
# elsewhere, so a generator that grepped for `^## ` fails here.
root="$(new_fixture)"
cat > "${root}/docs/fenced.md" <<'DOC'
# Fenced

```bash
## vault operator init
```

## Real section
DOC
"${root}/scripts/generate-docs-index.sh" > /dev/null 2>&1
index="$(cat "${root}/docs/README.md")"
if grep -qF "Real section" <<<"$index" && ! grep -qF "vault operator init" <<<"$index"; then
    ok "a ## line inside a fence is not indexed as a section"
else
    bad "a ## line inside a fence is not indexed as a section" "$index"
fi

# ---------------------------------------------------------------------------
printf '\n=== A document with no title is an error, not a blank row ===\n'
# ---------------------------------------------------------------------------
# The failure mode this rejects is a row reading `| []( orphan.md ) |`,
# which renders as an empty link and points nowhere a reader can follow.
root="$(new_fixture)"
printf 'Body text with no heading at all.\n' > "${root}/docs/orphan.md"
if OUT="$("${root}/scripts/generate-docs-index.sh" 2>&1)"; then
    bad "a document without an H1 fails the generator" "Exited 0, said: $OUT"
elif grep -qF "orphan.md" <<<"$OUT"; then
    ok "a document without an H1 fails the generator, naming the file"
else
    bad "a document without an H1 fails the generator, naming the file" "$OUT"
fi

# ---------------------------------------------------------------------------
printf '\n=== A pipe in a heading does not break the table ===\n'
# ---------------------------------------------------------------------------
# An unescaped `|` ends the cell early, so the rest of the heading
# becomes a third column and the row stops rendering as a row.
root="$(new_fixture)"
cat > "${root}/docs/piped.md" <<'DOC'
# Piped

## Either a | or b
DOC
"${root}/scripts/generate-docs-index.sh" > /dev/null 2>&1
row="$(grep -F 'piped.md' "${root}/docs/README.md")"
# Count the pipes that still delimit cells, i.e. the unescaped ones: a
# correct row has exactly three, opening, separating and closing it.
delimiters="$(printf '%s' "${row//\\|/}" | grep -o '|' | wc -l)"
if [[ "$delimiters" -eq 3 ]] && grep -qF 'Either a \| or b' <<<"$row"; then
    ok "a pipe in a heading is escaped, leaving a two-column row"
else
    bad "a pipe in a heading is escaped, leaving a two-column row" "$row"
fi

# ---------------------------------------------------------------------------
printf '\n=== --check writes nothing and reports staleness ===\n'
# ---------------------------------------------------------------------------
# The point of --check is that CI can run it on a read-only expectation:
# it must report the drift rather than quietly fixing it, or the CI step
# would pass on every branch that had forgotten to run `make docs`.
root="$(new_fixture)"
printf '# Kept\n\n## One\n' > "${root}/docs/kept.md"
"${root}/scripts/generate-docs-index.sh" > /dev/null 2>&1

if "${root}/scripts/generate-docs-index.sh" --check > /dev/null 2>&1; then
    ok "--check passes on a freshly generated index"
else
    bad "--check passes on a freshly generated index"
fi

printf '# Added later\n\n## Two\n' > "${root}/docs/added.md"
before="$(cat "${root}/docs/README.md")"
if OUT="$("${root}/scripts/generate-docs-index.sh" --check 2>&1)"; then
    bad "--check fails once a new document is added" "Exited 0, said: $OUT"
elif [[ "$before" == "$(cat "${root}/docs/README.md")" ]]; then
    ok "--check fails on a stale index without rewriting it"
else
    bad "--check fails on a stale index without rewriting it" \
        "The index was modified by a check that promises not to write."
fi

# ---------------------------------------------------------------------------
printf '\n=== Regenerating is idempotent ===\n'
# ---------------------------------------------------------------------------
# The index lists docs/*.md and is itself docs/README.md, so a generator
# that did not exclude itself would grow an entry for itself on every
# run, and `make docs` would never reach a fixed point.
root="$(new_fixture)"
printf '# Solo\n\n## Only\n' > "${root}/docs/solo.md"
"${root}/scripts/generate-docs-index.sh" > /dev/null 2>&1
first="$(cat "${root}/docs/README.md")"
"${root}/scripts/generate-docs-index.sh" > /dev/null 2>&1
if [[ "$first" == "$(cat "${root}/docs/README.md")" ]] \
   && ! grep -qF '(README.md)' "${root}/docs/README.md"; then
    ok "a second run produces the same index and does not index itself"
else
    bad "a second run produces the same index and does not index itself" \
        "$(cat "${root}/docs/README.md")"
fi

printf '\n'
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
green "All docs index checks hold."
