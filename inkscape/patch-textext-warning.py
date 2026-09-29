#!/usr/bin/python3
"""Filter TexText's known GLib warning without hiding other diagnostics."""

import argparse
from pathlib import Path
import re

MARKER = "# NewComputer: TexText GLib compatibility (upstream issue #496)."


def patch(path):
    source = path.read_text()
    if MARKER in source:
        return
    matches = list(re.finditer(r"^( +)import gi[ \t]*$", source, re.MULTILINE))
    if len(matches) != 1:
        raise RuntimeError(f"Unrecognized TexText GTK import in {path}; review compatibility patch")
    match = matches[0]
    indent = match.group(1)
    lines = [
        MARKER,
        "import warnings",
        "warnings.filterwarnings(",
        '    "ignore",',
        '    message=r"GLib\\.unix_signal_add_full is deprecated;.*",',
        "    category=gi.PyGIDeprecationWarning,",
        ")",
    ]
    insertion = "\n" + "\n".join(indent + line for line in lines)
    updated = source[:match.end()] + insertion + source[match.end():]
    compile(updated, str(path), "exec")
    path.write_text(updated)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("path", type=Path, help="TexText asktext.py to patch")
    patch(parser.parse_args().path)
