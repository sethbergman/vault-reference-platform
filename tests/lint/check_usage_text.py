#!/usr/bin/env python3
"""--help prints the header, and nothing below it.

Every script here documents itself by printing its own header back, so the
header is the help text and cannot drift from it. That only holds while the
printing stops at the first line of code, and for a long time it did not:
`grep '^#' "$0"` matches the body's section dividers and standalone comments
too, which sit at column 0 as well. Across 34 scripts that was 1284 lines of
internal commentary in --help -- `bootstrap-dev-cluster.sh --help` printed
185 lines of which 124 were its own body comments, and nobody noticed because
nobody reads 185 lines of help. That is the failure, not a side effect of it.

So this runs each script's --help and compares the output to the header,
rather than checking which sed they use. A script that grows a comment block
below the code and starts leaking it fails here even with the idiom right.

Running them is the point and also the hazard: asking for help must not do
anything, and the first run of this check found that `dr-drill.sh --help`
tore the local cluster down -- the EXIT trap was armed above the argument
loop, and usage() ends in `exit 1`. So every tool that can change something
outside this process is replaced on PATH with one that refuses. A script
whose help text needs any of them fails here, which is the right answer.
"""
import os
import pathlib
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[2]

# Anything that can reach a cluster, a cloud account, a host or the disk.
# Not an exhaustive list of dangerous programs -- an exhaustive list of what
# these scripts use, which is the set that could be reached by accident.
REFUSED = [
    "docker", "docker-compose", "kubectl", "systemctl", "service",
    "aws", "az", "gcloud", "terraform", "vault", "consul",
    "ssh", "scp", "sftp", "rsync", "curl", "wget",
    "rm", "rmdir", "shred", "dd", "mv", "truncate",
]


def header_of(lines):
    """The contiguous comment block after the shebang, with the # stripped."""
    out = []
    for line in lines[1:]:
        if not line.startswith("#"):
            break
        out.append(line[2:] if line.startswith("# ") else line[1:])
    return out


def refusing_path(d):
    """A PATH whose first entry answers for everything in REFUSED."""
    for name in REFUSED:
        p = pathlib.Path(d) / name
        p.write_text(
            "#!/bin/sh\n"
            f'echo "refused: --help must not run {name}" >&2\n'
            "exit 127\n", encoding="utf-8")
        p.chmod(0o755)
    return f"{d}{os.pathsep}{os.environ.get('PATH', '')}"


problems = []
checked = 0

with tempfile.TemporaryDirectory() as shims:
    env = dict(os.environ, PATH=refusing_path(shims))

    for path in sorted((ROOT / "scripts").glob("*.sh")):
        lines = path.read_text(encoding="utf-8").splitlines()
        src = "\n".join(lines)
        if "usage()" not in src or "--help" not in src:
            continue
        checked += 1

        try:
            r = subprocess.run(["/bin/bash", str(path), "--help"], cwd=ROOT,
                               capture_output=True, text=True, timeout=30,
                               env=env)
        except subprocess.TimeoutExpired:
            problems.append(f"{path.name}: --help did not return within 30s")
            continue

        got = (r.stdout + r.stderr).splitlines()
        want = header_of(lines)

        if not got:
            problems.append(f"{path.name}: --help printed nothing")
        elif got != want:
            detail = f"printed {len(got)} lines, the header is {len(want)}"
            strays = [line for line in got if line not in want]
            if strays:
                detail += f"; not from the header: {strays[0]!r}"
            problems.append(f"{path.name}: {detail}")

if not checked:
    print("no script with a usage() and a --help was found, which is itself "
          "the finding", file=sys.stderr)
    sys.exit(1)

if problems:
    print(f"--help must print the header and nothing below it "
          f"({len(problems)} of {checked} scripts):", file=sys.stderr)
    for p in problems:
        print(f"  {p}", file=sys.stderr)
    print("\n  usage() should be:", file=sys.stderr)
    print("""    sed -n '2,${ /^#/!q; s/^# \\{0,1\\}//p; }' "$0\"""", file=sys.stderr)
    print("\n  and --help must be answered before anything with an effect: "
          "an EXIT trap armed above the argument loop runs on usage()'s own "
          "exit.", file=sys.stderr)
    sys.exit(1)

print(f"{checked} scripts print their header and nothing below it")
