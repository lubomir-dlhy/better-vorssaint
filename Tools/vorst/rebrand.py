#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Rename user-visible "Vorssaint" text to "Vorst".

Idempotent: run it after every upstream merge. Only string literals in Swift
sources and values in plist/.strings resources change; identifiers, comments,
bundle IDs, URLs and the credit kept in VorstBrand.swift are left alone.
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
WORD = re.compile(r"(?<![A-Za-z0-9_.])Vorssaint(?![A-Z0-9_/]|\.[A-Za-z]|:\S|-[a-z0-9])")
# Literals other code matches by value: internal audio devices, the legacy
# bundle name and upstream's release-note footer.
KEEP_LITERAL = re.compile(r"^Vorssaint (Mixer|AirPlay|Island Levels|Recorder)$|^Vorssaint Utils\.app$|drag Vorssaint to Applications\.$")
EXCLUDE = {"Sources/Vorssaint/Core/VorstBrand.swift", "Sources/Vorssaint/Core/AppInfo.swift"}


def rebrand(text):
    return WORD.sub("Vorst", text)


def swift_literals(source):
    """Yield (start, end) spans of string literal contents, outside comments."""
    i, n = 0, len(source)
    while i < n:
        if source.startswith("//", i):
            i = source.find("\n", i)
            i = n if i < 0 else i
        elif source.startswith("/*", i):
            depth, i = 1, i + 2
            while i < n and depth:
                if source.startswith("/*", i):
                    depth, i = depth + 1, i + 2
                elif source.startswith("*/", i):
                    depth, i = depth - 1, i + 2
                else:
                    i += 1
        elif source[i] == '"' or source.startswith('#"', i):
            hashes = 0
            while source[i] == "#":
                hashes, i = hashes + 1, i + 1
            multiline = source.startswith('"""', i)
            quote = '"""' if multiline else '"'
            i += len(quote)
            start, depth = i, 0
            closer = quote + "#" * hashes
            while i < n:
                if source[i] == "\\" and hashes == 0:
                    if source.startswith("\\(", i):
                        depth, i = depth + 1, i + 2
                        continue
                    i += 2
                    continue
                if depth:
                    if source[i] == "(":
                        depth += 1
                    elif source[i] == ")":
                        depth -= 1
                    i += 1
                    continue
                if source.startswith(closer, i):
                    yield start, i
                    i += len(closer)
                    break
                i += 1
        else:
            i += 1


def rebrand_swift(source):
    out, last = [], 0
    for start, end in swift_literals(source):
        out.append(source[last:start])
        literal = source[start:end]
        out.append(literal if KEEP_LITERAL.search(literal) else rebrand(literal))
        last = end
    out.append(source[last:])
    return "".join(out)


def rebrand_strings_file(text):
    return re.sub(r'(=\s*")((?:[^"\\]|\\.)*)(")', lambda m: m[1] + rebrand(m[2]) + m[3], text)


def rebrand_plist(text):
    return re.sub(r"(<string>)([^<]*)(</string>)", lambda m: m[1] + rebrand(m[2]) + m[3], text)


def main():
    changed = []
    targets = [(p, rebrand_swift) for p in sorted((ROOT / "Sources/Vorssaint").rglob("*.swift"))]
    targets += [(p, rebrand_strings_file) for p in sorted((ROOT / "Resources").glob("*.lproj/*.strings"))]
    targets += [(ROOT / "Resources/Info.plist", rebrand_plist)]
    for path, transform in targets:
        rel = path.relative_to(ROOT).as_posix()
        if rel in EXCLUDE:
            continue
        original = path.read_text()
        updated = transform(original)
        if updated != original:
            path.write_text(updated)
            changed.append(rel)
    print(f"rebranded {len(changed)} files")
    return 0


if __name__ == "__main__":
    sys.exit(main())
