#!/usr/bin/env python3

import argparse
import json
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parent.parent
CATALOG = ROOT / "Whisky" / "Localizable.xcstrings"
VALUE_LINE = re.compile(r'^(\s*"value"\s*:\s*)("(?:[^"\\]|\\.)*")(,?)$')

REQUIRED_TEXT = {
    "OpenBottle.xcodeproj/project.pbxproj": [
        "path = OpenBottle.app;",
        "name = OpenBottle;",
        "PRODUCT_BUNDLE_IDENTIFIER = io.github.ewoudvv.OpenBottle;",
        "PRODUCT_BUNDLE_IDENTIFIER = io.github.ewoudvv.OpenBottleCmd;",
        "PRODUCT_BUNDLE_IDENTIFIER = io.github.ewoudvv.OpenBottle.OpenBottleThumbnail;",
    ],
    "Whisky/Info.plist": [
        "<string>io.github.ewoudvv.OpenBottle</string>",
        "<string>openbottle</string>",
        "https://ewoudvv.github.io/OpenBottle/appcast.xml",
    ],
    ".github/workflows/CI.yml": [
        "OpenBottle.xcodeproj",
        "for scheme in OpenBottle OpenBottleCmd OpenBottleThumbnail",
        "-only-testing:OpenBottleUITests",
    ],
}

REQUIRED_PATHS = [
    "OpenBottle.xcodeproj/xcshareddata/xcschemes/OpenBottle.xcscheme",
    "OpenBottle.xcodeproj/xcshareddata/xcschemes/OpenBottleCmd.xcscheme",
    "OpenBottle.xcodeproj/xcshareddata/xcschemes/OpenBottleThumbnail.xcscheme",
    "OpenBottleCmd/Main.swift",
    "OpenBottleThumbnail/OpenBottleThumbnail.entitlements",
    "OpenBottleUITests/OpenBottleUITests.swift",
    "Whisky/Utils/OpenBottleCmd.swift",
    "Whisky/Views/OpenBottleApp.swift",
]

FORBIDDEN_ACTIVE_TEXT = {
    "Whisky/Info.plist": [
        "com.franke.Whisky",
        "com.isaacmarovitz.Whisky",
        "<string>whisky</string>",
        "PostHogProjectToken",
        "SUPublicEDKey",
    ],
    ".github/workflows/CI.yml": [
        "Whisky.xcodeproj",
        "-scheme Whisky ",
        "-only-testing:WhiskyUITests",
    ],
    "scripts/release.sh": [
        "Whisky.xcodeproj",
        "-scheme Whisky ",
        "Whisky.app",
        "Whisky-$VERSION.dmg",
    ],
}


def updated_value(value: str) -> str:
    value = re.sub(r"\s*\(frankea/Whisky#\d+\)", "", value)
    value = value.replace("WhiskyWine", "OpenBottle Runtime")
    value = value.replace("whisky://", "openbottle://")
    value = value.replace("Whisky", "OpenBottle")
    return value


def rewrite_catalog(raw: str) -> str:
    lines: list[str] = []
    for line in raw.splitlines(keepends=True):
        ending = "\n" if line.endswith("\n") else ""
        content = line.removesuffix("\n")
        match = VALUE_LINE.match(content)
        if match is None:
            lines.append(line)
            continue
        value = json.loads(match.group(2))
        replacement = json.dumps(updated_value(value), ensure_ascii=False)
        lines.append(f"{match.group(1)}{replacement}{match.group(3)}{ending}")
    return "".join(lines)


def stale_values(raw: str) -> list[str]:
    stale: list[str] = []
    for line in raw.splitlines():
        match = VALUE_LINE.match(line)
        if match is None:
            continue
        value = json.loads(match.group(2))
        if updated_value(value) != value:
            stale.append(value)
    return stale


def identity_problems() -> list[str]:
    problems: list[str] = []
    for relative_path in REQUIRED_PATHS:
        if not (ROOT / relative_path).exists():
            problems.append(f"missing {relative_path}")
    for relative_path, snippets in REQUIRED_TEXT.items():
        path = ROOT / relative_path
        if not path.exists():
            problems.append(f"missing {relative_path}")
            continue
        text = path.read_text(encoding="utf-8")
        for snippet in snippets:
            if snippet not in text:
                problems.append(f"{relative_path} is missing {snippet!r}")
    for relative_path, snippets in FORBIDDEN_ACTIVE_TEXT.items():
        path = ROOT / relative_path
        if not path.exists():
            continue
        text = path.read_text(encoding="utf-8")
        for snippet in snippets:
            if snippet in text:
                problems.append(f"{relative_path} still contains {snippet!r}")
    return problems


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    raw = CATALOG.read_text(encoding="utf-8")
    stale = stale_values(raw)
    if args.check:
        problems = identity_problems()
        if stale or problems:
            print(f"{len(stale)} user-facing Whisky value(s) remain")
            for value in stale[:10]:
                print(f"  {value}")
            for problem in problems:
                print(f"  {problem}")
            return 1
        print("OpenBottle identity and user-facing product values are consistent")
        return 0
    updated = rewrite_catalog(raw)
    CATALOG.write_text(updated, encoding="utf-8")
    print(f"updated {len(stale)} user-facing product value(s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
