#!/usr/bin/env python3
"""Reject trap handlers whose last command is a bare conditional.

    cleanup() { [[ -n "$D" && -d "$D" ]] && rm -rf "$D"; }
    trap cleanup EXIT

When the test is false the function returns 1, and bash applies that to
the script's exit status from an EXIT trap -- so a run that succeeded
reports failure. An explicit `exit 0` does not save it.

Only functions actually registered with `trap` are checked. Elsewhere the
same shape is idiomatic and harmless: at the top level, and as the last
statement of an if/else branch, `set -e` does not act on it. It is
specifically the function-return path that bites.

Exits non-zero and names the offenders when any are found.
"""

import glob
import re
import sys

FUNC = re.compile(r'\s*([A-Za-z_][A-Za-z0-9_]*)\(\)\s*\{')
TRAP = re.compile(r'\s*trap\s+([A-Za-z_][A-Za-z0-9_]*)\s')


def offenders(path):
    with open(path, encoding='utf-8') as handle:
        lines = handle.read().split('\n')

    handlers = {m.group(1) for m in (TRAP.match(l) for l in lines) if m}
    if not handlers:
        return []

    found = []
    start = name = None
    for i, line in enumerate(lines):
        match = FUNC.match(line)
        if match:
            start, name = i, match.group(1)
        elif line.rstrip() == '}' and start is not None:
            if name in handlers:
                # The last statement that is neither blank nor a comment.
                for j in range(i - 1, start, -1):
                    text = lines[j].strip()
                    if not text or text.startswith('#'):
                        continue
                    # `||` means the author already handled the false
                    # branch, so the function cannot return the test.
                    if text.startswith('[[') and '&&' in text and '||' not in text:
                        found.append((path, j + 1, text))
                    break
            start = name = None
    return found


def main():
    paths = sorted(glob.glob('scripts/*.sh')) + sorted(glob.glob('docker/*/*.sh'))
    bad = [item for path in paths for item in offenders(path)]
    if not bad:
        print('Checked %d scripts; no trap handler returns a bare test.' % len(paths))
        return 0

    print('Trap handlers ending in a bare conditional:')
    for path, line, text in bad:
        print('  %s:%d' % (path, line))
        print('      %s' % text)
    print('')
    print('Each returns 1 when its test is false, and bash applies that to')
    print('the exit status from an EXIT trap. Use an if block instead:')
    print('')
    print('    if [[ ... ]]; then')
    print('        rm -rf "$D"')
    print('    fi')
    return 1


if __name__ == '__main__':
    sys.exit(main())
