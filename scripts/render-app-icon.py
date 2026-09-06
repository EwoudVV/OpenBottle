#!/usr/bin/env python3
"""Render the hand-drawn OpenBottle SVGs into every asset-catalog size."""

from __future__ import annotations

import argparse
import shutil
import struct
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
LARGE_SOURCE = ROOT / "images/openbottle-icon.svg"
SMALL_SOURCE = ROOT / "images/openbottle-icon-small.svg"

OUTPUTS = {
    ROOT / "images/openbottle-icon-master.png": (1024, LARGE_SOURCE),
    ROOT / "Whisky/Assets.xcassets/AppIcon.appiconset/16R64x1.png": (16, SMALL_SOURCE),
    ROOT / "Whisky/Assets.xcassets/AppIcon.appiconset/16@2x.png": (32, SMALL_SOURCE),
    ROOT / "Whisky/Assets.xcassets/AppIcon.appiconset/32R64x1.png": (32, SMALL_SOURCE),
    ROOT / "Whisky/Assets.xcassets/AppIcon.appiconset/32@2x.png": (64, LARGE_SOURCE),
    ROOT / "Whisky/Assets.xcassets/AppIcon.appiconset/128R128x1.png": (128, LARGE_SOURCE),
    ROOT / "Whisky/Assets.xcassets/AppIcon.appiconset/128@2x.png": (256, LARGE_SOURCE),
    ROOT / "Whisky/Assets.xcassets/AppIcon.appiconset/256R256x1.png": (256, LARGE_SOURCE),
    ROOT / "Whisky/Assets.xcassets/AppIcon.appiconset/256@2x.png": (512, LARGE_SOURCE),
    ROOT / "Whisky/Assets.xcassets/AppIcon.appiconset/512R512x1.png": (512, LARGE_SOURCE),
    ROOT / "Whisky/Assets.xcassets/AppIcon.appiconset/512@2x.png": (1024, LARGE_SOURCE),
    ROOT / "OpenBottleThumbnail/Icons.xcassets/Icon.imageset/512R512x1.png": (512, LARGE_SOURCE),
}


def sips(*arguments: str) -> None:
    subprocess.run(
        ["/usr/bin/sips", *arguments],
        check=True,
        stdout=subprocess.DEVNULL,
    )


def render_source(source: Path, output: Path) -> None:
    sips("-s", "format", "png", str(source), "--out", str(output))


def resize(source: Path, output: Path, size: int) -> None:
    if size == 1024:
        shutil.copyfile(source, output)
    else:
        sips("-z", str(size), str(size), str(source), "--out", str(output))


def png_size_and_colour_type(path: Path) -> tuple[int, int, int]:
    data = path.read_bytes()
    if data[:8] != b"\x89PNG\r\n\x1a\n" or data[12:16] != b"IHDR":
        raise ValueError(f"{path} is not a PNG")
    width, height = struct.unpack(">II", data[16:24])
    return width, height, data[25]


def validate(path: Path, expected_size: int) -> None:
    width, height, colour_type = png_size_and_colour_type(path)
    if (width, height) != (expected_size, expected_size):
        raise ValueError(f"{path} is {width}x{height}, expected {expected_size}x{expected_size}")
    if colour_type not in (4, 6):
        raise ValueError(f"{path} has no alpha channel")


def render(check: bool) -> None:
    with tempfile.TemporaryDirectory(prefix="openbottle-icon-") as directory:
        temporary = Path(directory)
        rendered_sources: dict[Path, Path] = {}
        for source in (LARGE_SOURCE, SMALL_SOURCE):
            rendered = temporary / f"{source.stem}.png"
            render_source(source, rendered)
            rendered_sources[source] = rendered

        for index, (target, (size, source)) in enumerate(OUTPUTS.items()):
            generated = temporary / f"{index}-{target.name}"
            resize(rendered_sources[source], generated, size)
            validate(generated, size)
            if check:
                if not target.exists() or target.read_bytes() != generated.read_bytes():
                    raise ValueError(f"{target.relative_to(ROOT)} is out of date")
            else:
                shutil.copyfile(generated, target)
                print(f"rendered {target.relative_to(ROOT)} ({size}x{size})")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--check",
        action="store_true",
        help="verify that every committed PNG matches the SVG sources",
    )
    arguments = parser.parse_args()
    render(arguments.check)
    if arguments.check:
        print("OpenBottle icon assets match their SVG sources")


if __name__ == "__main__":
    main()
