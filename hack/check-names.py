#!/usr/bin/env python3
"""Render the chart across the full range of release-name lengths and assert
that every object name is unique within its kind and fits Kubernetes' limits.

Helm caps release names at 53 characters, and both truncation bugs this guards
against only appear at the long end of that range -- where CI's usual short
release names never reach.
"""
import subprocess
import sys
from collections import Counter

# DNS-1035 label: Services and most other names. Pods allow more, but staying
# inside the strictest limit keeps every object valid.
MAX_NAME = 63

EXTRA_VALUES = [
    ["--set", "networkPolicy.enabled=true"],
    ["--set", "web.autoscaling.enabled=true", "--set", "web.podDisruptionBudget.enabled=true"],
    ["--set", "nameOverride=a-considerably-longer-name-override"],
    ["--set", "fullnameOverride=a-considerably-longer-fullname-override-value"],
]


def render(chart, release, extra):
    proc = subprocess.run(
        ["helm", "template", release, chart, *extra],
        capture_output=True, text=True,
    )
    if proc.returncode != 0:
        raise RuntimeError(f"render failed for release {release!r} {extra}: {proc.stderr.strip()[:400]}")
    return proc.stdout


def names(manifest):
    """Pull kind/name pairs without needing PyYAML."""
    kind = None
    out = []
    for line in manifest.splitlines():
        if line.startswith("kind: "):
            kind = line[6:].strip()
        elif line.startswith("  name: ") and kind:
            out.append((kind, line[8:].strip().strip('"')))
            kind = None
    return out


def main():
    chart = sys.argv[1] if len(sys.argv) > 1 else "charts/mirofish-offline"
    failures = []

    for n in range(1, 54):                      # helm's own release-name limit
        release = "r" * n if n < 6 else "rel-" + "x" * (n - 5) + "z"
        for extra in EXTRA_VALUES:
            manifest = render(chart, release, extra)
            found = names(manifest)

            for kind, name in found:
                if len(name) > MAX_NAME:
                    failures.append(f"len={len(name)} {kind}/{name} (release {len(release)} chars, {extra})")

            counts = Counter(found)
            for (kind, name), count in counts.items():
                if count > 1:
                    failures.append(f"duplicate {kind}/{name} x{count} (release {len(release)} chars, {extra})")

    if failures:
        print("Object name check FAILED:")
        for f in sorted(set(failures))[:40]:
            print("  " + f)
        sys.exit(1)

    print(f"OK: names unique and <= {MAX_NAME} chars across release lengths 1-53 "
          f"and {len(EXTRA_VALUES)} value sets")


if __name__ == "__main__":
    main()
