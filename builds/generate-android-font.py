#!/usr/bin/env python3
"""Generate org-timegrid's Android SVG path-font tables from a font."""

import argparse
from pathlib import Path

from fontTools.pens.roundingPen import RoundingPen
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.ttLib import TTFont
from fontTools.varLib.instancer import instantiateVariableFont


CHARS = "".join(chr(code) for code in range(32, 127)) + "…–—‘’“”•"


def lisp_string(value):
    """Return VALUE quoted as an Emacs Lisp string."""
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def open_instance(source, weight):
    """Open SOURCE and select WEIGHT when it provides a weight axis."""
    font = TTFont(source)
    if "fvar" not in font:
        return font
    axes = {axis.axisTag: axis for axis in font["fvar"].axes}
    location = {tag: axis.defaultValue for tag, axis in axes.items()}
    if "wght" in axes:
        axis = axes["wght"]
        if not axis.minValue <= weight <= axis.maxValue:
            raise ValueError(
                f"weight {weight} is outside {axis.minValue:g}..{axis.maxValue:g}"
            )
        location["wght"] = weight
    return instantiateVariableFont(font, location)


def extract(source, weight, characters):
    """Extract advance widths and rounded SVG paths at WEIGHT from SOURCE."""
    font = open_instance(source, weight)
    glyphs = font.getGlyphSet()
    cmap = font.getBestCmap()
    metrics = font["hmtx"].metrics
    fallback = cmap.get(ord("?"), ".notdef")
    result = []
    for character in characters:
        name = cmap.get(ord(character), fallback)
        pen = SVGPathPen(glyphs)
        glyphs[name].draw(RoundingPen(pen))
        result.append((ord(character), round(metrics[name][0]), pen.getCommands()))
    return font["head"].unitsPerEm, result


def metadata(source):
    """Return concise family, version, and copyright metadata from SOURCE."""
    font = TTFont(source, lazy=True)
    names = font["name"]
    family = names.getDebugName(1) or source.stem
    version = names.getDebugName(5) or "unknown version"
    copyright_notice = names.getDebugName(0)
    font.close()
    return family, version, copyright_notice


def comment(value):
    """Format possibly multiline VALUE as Emacs Lisp comments."""
    if not value:
        return ""
    return "\n".join(f";; {line}" for line in value.splitlines()) + "\n"


def emit_table(name, glyphs):
    """Return an Emacs Lisp constant NAME containing GLYPHS."""
    lines = [f"(defconst {name}", "  '("]
    for codepoint, advance, path in glyphs:
        lines.append(f"    ({codepoint} {advance} {lisp_string(path)})")
    lines.append("    ))\n")
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(
        description="Convert a TTF or OTF into org-timegrid path-font Elisp."
    )
    parser.add_argument("font", type=Path, help="regular or variable TTF/OTF")
    parser.add_argument("output", type=Path, help="Elisp file to generate")
    parser.add_argument(
        "--bold-font", type=Path,
        help="separate bold TTF/OTF; useful when FONT is not variable",
    )
    parser.add_argument("--regular-weight", type=float, default=400)
    parser.add_argument("--bold-weight", type=float, default=500)
    parser.add_argument(
        "--characters", default=CHARS,
        help="literal characters to include (default: calendar subset)",
    )
    args = parser.parse_args()

    bold_source = args.bold_font or args.font
    units, regular = extract(args.font, args.regular_weight, args.characters)
    bold_units, bold = extract(bold_source, args.bold_weight, args.characters)
    if units != bold_units:
        raise ValueError("font instances have different units per em")

    family, version, copyright_notice = metadata(args.font)
    text = """;;; org-timegrid-android-font.el --- Generated Android path font -*- lexical-binding: t; -*-

"""
    text += (f";; Generated from {family}, {version}, at weights "
             f"{args.regular_weight:g} and {args.bold_weight:g}.\n")
    text += ";; Do not edit by hand.\n"
    text += comment(copyright_notice) + "\n"
    text += f"(defconst org-timegrid-android-font-units-per-em {units})\n\n"
    text += emit_table("org-timegrid-android-font-regular", regular)
    text += emit_table("org-timegrid-android-font-bold", bold)
    text += "(provide 'org-timegrid-android-font)\n"
    text += ";;; org-timegrid-android-font.el ends here\n"
    args.output.write_text(text, encoding="utf-8")


if __name__ == "__main__":
    main()
