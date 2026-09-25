"""Summarise the LOG lines the profiled and benchmark bots write, from `unswbc run -v` output.

    unswbc run --sandbox -v maps/arena.map bench-bot starter-c | python3 summarise.py

Prints the median of every name=value field, over all turns, in the order they appear.
"""

import re
import statistics
import sys

values = {}
turns = 0
for line in sys.stdin:
    if "LOG profile" not in line and "LOG bench" not in line:
        continue
    turns += 1
    for name, value in re.findall(r"(\w[\w-]*)=(\d+)", line):
        values.setdefault(name, []).append(int(value))
width = max(map(len, values), default=0)
for name, numbers in values.items():
    print(f"{name:<{width}}  {statistics.median(numbers):>12,.0f}")
print(f"{turns} turns")
