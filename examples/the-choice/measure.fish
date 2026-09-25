# Median and 99th-percentile CPU points per turn for each bot playing itself on every map.
for bot in c nim python c-idle python-idle
    for map in maps/*.map
        unswbc run -v --sandbox --no-replay --seed 0x5eed5eed $map $bot $bot | string match -rg 'points (\d+)'
    end | sort -n | awk -v bot=$bot '{ v[NR] = $1 } END { printf "%-12s median %11d  p99 %11d  (%d turns)\n", bot, v[int(NR / 2) + 1], v[int(NR * 0.99)], NR }'
end
