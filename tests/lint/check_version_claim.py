#!/usr/bin/env python3
"""Reject a README version claim that has drifted from the roadmap.

README.md carries one sentence naming the newest shipped release. It is
the first claim a reader meets, and nothing checked it: at v0.18 it still
said v0.14, four releases stale, and had been wrong through four PRs that
each updated the roadmap table beside it.

This is the failure docs/README.md is generated to avoid -- a
hand-maintained claim that stops being true silently, invisible to
everyone except the reader who relied on it. One sentence is not worth
generating, so it is asserted instead.

TWO CHECKS, AND WHY THE SOURCE OF TRUTH IS NOT THE TAGS

  1. The README claim must name the newest row of the roadmap's Shipped
     table.
  2. That row must be at least as new as the newest git tag.

The roadmap table is the authority rather than `git tag` because of the
order releases are cut in: the roadmap row lands in a PR, and the tag is
pushed after it merges. Gating the README on tags would fail that PR for
being correct. Gating the roadmap on tags in one direction only -- table
ahead of tags is fine, table behind them is not -- permits that ordering
and still catches a release that was tagged and never written down.

Check 2 needs the tags to be present. CI's lint job fetches them
deliberately; see .github/workflows/ci.yml. A checkout with no tags is
reported as a failure rather than skipped, because a skip here is
indistinguishable from a pass and this file exists because something
unchecked went stale.

Exits non-zero and says which claim disagrees with which.
"""

import re
import subprocess
import sys

# "Everything through v0.14 has shipped" -- anchored on the load-bearing
# words rather than the whole sentence, so rewording the prose around it
# is fine and removing the claim is not.
CLAIM = re.compile(r'through (v\d+\.\d+) has shipped')

# A row of the Shipped table: | v0.18 | Rate limit quotas, ... |
ROW = re.compile(r'^\|\s*(v\d+\.\d+)\s*\|')

TAG = re.compile(r'^v\d+\.\d+$')


def key(version):
    """Sort v0.9 below v0.10, which a string compare does not."""
    return tuple(int(part) for part in version.lstrip('v').split('.'))


def read(path):
    with open(path, encoding='utf-8') as handle:
        return handle.read()


def shipped_versions(text):
    """Every version in the roadmap's `## Shipped` table, that table only."""
    lines = text.split('\n')
    try:
        start = lines.index('## Shipped')
    except ValueError:
        return []

    found = []
    for line in lines[start + 1:]:
        if line.startswith('## '):
            break
        match = ROW.match(line)
        if match:
            found.append(match.group(1))
    return found


def newest_tag():
    """The newest vN.N tag, or None when this is not a git checkout.

    Returns [] rather than None for a checkout that is a repository but
    carries no tags -- the caller treats those differently.
    """
    try:
        out = subprocess.run(
            ['git', 'tag', '--list'],
            capture_output=True, text=True, check=True,
        ).stdout
    except (subprocess.CalledProcessError, FileNotFoundError):
        return None

    tags = [t for t in out.split('\n') if TAG.match(t.strip())]
    return max(tags, key=key) if tags else []


def main():
    failures = []

    shipped = shipped_versions(read('docs/roadmap.md'))
    if not shipped:
        print('No `## Shipped` table found in docs/roadmap.md, or no version')
        print('rows in it. This check reads that table as the source of truth,')
        print('so it cannot run -- fix the table or update this checker.')
        return 1

    newest = max(shipped, key=key)

    claims = CLAIM.findall(read('README.md'))
    if not claims:
        failures.append(
            'README.md names no shipped version.\n'
            '  Expected a sentence matching "through vN.N has shipped".\n'
            '  If the wording changed deliberately, update CLAIM in this file\n'
            '  -- do not delete the claim, it is what a reader trusts first.'
        )
    else:
        stale = sorted({c for c in claims if c != newest}, key=key)
        if stale:
            failures.append(
                'README.md claims %s; docs/roadmap.md ships %s.\n'
                '  The roadmap table is the source of truth. Update the README.'
                % (', '.join(stale), newest)
            )

    tag = newest_tag()
    if tag is None:
        print('Not a git checkout; skipping the roadmap-versus-tag check.')
    elif tag == []:
        failures.append(
            'No vN.N git tags found.\n'
            '  This check compares the roadmap table against the newest tag,\n'
            '  and a checkout with no tags cannot answer that. Run\n'
            '  `git fetch --tags`; CI fetches them with fetch-depth: 0.'
        )
    elif key(newest) < key(tag):
        failures.append(
            '%s is tagged but docs/roadmap.md stops at %s.\n'
            '  A release was cut without a Shipped row. Add it.'
            % (tag, newest)
        )

    if failures:
        print('Version claims disagree:')
        for item in failures:
            print('  %s' % item)
        return 1

    print('README names %s; roadmap ships %s; newest tag %s.'
          % (newest, newest, tag if tag else 'n/a'))
    return 0


if __name__ == '__main__':
    sys.exit(main())
