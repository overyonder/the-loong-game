"""Chart the room-counting kernels' CPU points from the benchmark bot's logs.

    unswbc run --sandbox -v ... bench-bot ... > bench.log   # one or more games
    python3 tools/kernel_chart.py bench.log blog/images/room-kernels.svg

Bars use a log scale, since the kernels differ by nearly two orders of magnitude.
"""

import math
import re
import statistics
import sys

PAPER, INK, MUTED, RULE = "#ede5d5", "#20251f", "#66675e", "#b9ad99"
FOREST, SIGNAL = "#263d31", "#b53b13"

KERNELS = [  # log name, label, stage colour
    ("nim-seq", "Nim: a seq queue and a set", FOREST),
    ("nim-array", "Nim: fixed arrays", FOREST),
    ("c-queue", "C: fixed arrays", FOREST),
    ("bitboard", "C: bitboards", "#3f6e8c"),
    ("components", "C: one flood fill per region", "#3f6e8c"),
    ("simd", "SIMD: two flood fills at once", "#7a4f8a"),
    ("inline-asm", "Hand-written WebAssembly step", "#7a4f8a"),
    ("simd-masks", "SIMD: building the bitboards", SIGNAL),
]


def main() -> None:
    values = {}
    turns = 0
    for line in open(sys.argv[1]):
        if "LOG bench" in line:
            turns += 1
            for name, value in re.findall(r"([\w-]+)=(\d+)", line):
                values.setdefault(name, []).append(int(value))
    medians = {name: statistics.median(numbers) for name, numbers in values.items()}

    left, right, top, row = 250, 640, 64, 44
    width, height = 780, top + row * len(KERNELS) + 60
    low, high = math.log10(1000), math.log10(200_000)
    scale = lambda value: left + (math.log10(value) - low) / (high - low) * (right - left)
    parts = [
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {width} {height}" font-family="Helvetica, Arial, sans-serif"'
        ' role="img" aria-labelledby="t">',
        f'<title id="t">CPU points to count the room behind all four first moves, median of {turns:,} turns</title>',
        f'<rect width="{width}" height="{height}" fill="{PAPER}"/>',
        f'<text x="{left}" y="28" font-size="15" font-weight="bold" fill="{INK}">CPU points to count the room behind all four first moves</text>',
        f'<text x="{left}" y="47" font-size="12" fill="{MUTED}">median of {turns:,} turns on six maps, log scale</text>',
    ]
    for tick in (1000, 3000, 10_000, 30_000, 100_000):
        x = scale(tick)
        parts.append(f'<path d="M{x:.1f} {top - 6}V{top + row * len(KERNELS)}" stroke="{RULE}" stroke-width="1"/>')
        parts.append(f'<text x="{x:.1f}" y="{top + row * len(KERNELS) + 18}" font-size="11" fill="{MUTED}"'
                     f' text-anchor="middle">{tick:,}</text>')
    for index, (name, label, colour) in enumerate(KERNELS):
        y = top + index * row
        value = medians[name]
        parts.append(f'<text x="{left - 12}" y="{y + 24}" font-size="13" fill="{INK}" text-anchor="end">{label}</text>')
        parts.append(f'<rect x="{left}" y="{y + 8}" width="{scale(value) - left:.1f}" height="24" rx="3" fill="{colour}"/>')
        parts.append(f'<text x="{scale(value) + 8:.1f}" y="{y + 25}" font-size="13" font-weight="bold" fill="{INK}">{value:,.0f}</text>')
    parts.append("</svg>")
    with open(sys.argv[2], "w") as output:
        output.write("\n".join(parts) + "\n")


if __name__ == "__main__":
    main()
