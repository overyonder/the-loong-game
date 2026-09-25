# Maps nobody has seen

<!-- draft: a51bc86640, stage: Building our tooling -->

The organisers have said that every Sprint, Qualifier and Grand Final map will be brand new. That's a problem for anyone who only tests on the 13 maps bundled with the toolkit. A bot can quietly come to depend on something those maps happen to have in common, and look strong right up until the tournament puts it on a map without it. We can't test on the tournament maps, because nobody has seen them. What we can do is make lots of new maps that look like the real thing and test on those.

That's the third tool on the wishlist, a map generator. This post builds it, and then uses it straight away to find a blind spot in the flood-fill bot that the bundled maps had been hiding.

## What a plausible map needs

The generator, [harness/mapgen.py](../harness/mapgen.py), writes maps in the official format. The hard part is making them plausible, which means varied enough to find surprises but still recognisably the same game. So it's modelled on the maps the ladder has actually used, and each choice it makes is one that can trip up a bot.

Size and shape come first. Ladder maps range from small, cramped boards where dragons are always bumping into each other, to 64 by 64, where they may barely meet. Some are square and some are long and narrow. A bot that only ever plays on medium-sized square maps can pick up habits that fall apart at either extreme, so the generator covers the whole range.

Every map is also symmetric, mirrored or rotated so that both teams start in equivalent positions. That's how the real maps are built, and it keeps the games fair, so a win means something.

The generator never places anything on its own. Every tile it uses has a mirror image, found by flipping one axis or rotating the board half a turn, and every piece of kelp goes in together with its mirror:

```python
def mirror_tile(layout: GeneratedMap, tile: Tile) -> Tile:
    x, y = tile
    w, h = layout.width, layout.height
    if layout.symmetry == "y":
        return (w - 1 - x, y)
    if layout.symmetry == "x":
        return (x, h - 1 - y)
    return (w - 1 - x, h - 1 - y)


def add_kelp_symmetrically(layout: GeneratedMap, edge: Edge) -> None:
    layout.kelp.add(edge)
    layout.kelp.add(mirror_edge(layout, edge))
```

The kelp is where the variety really comes in. Kelp walls change how a dragon has to move, and different layouts demand different skills: open ground, scattered short walls, closed rooms, a maze, or a single wall dividing the board. The generator mixes these, and adds portals in pairs, because portals are the part of the game that most often breaks a bot's assumptions about where a move leads.

Pearls matter too. On some maps food is spread everywhere, on others it's scarce, and on others it's concentrated in a contested middle or in a private field on each side. A bot's sense of when to go looking for food is tested very differently by each.

Random choices like these can easily produce a map that's useless for testing, like a board mostly walled off, or teams starting right on top of each other. So before a map is kept, the generator checks that most of the board is reachable, that the two teams start at least four tiles apart, and that no dragon starts boxed in. The whole recipe is one retry loop. It picks a size, a symmetry and one to three kelp styles, adds portals, and throws the map away and starts again whenever a check fails:

```python
def generate_map(generator: random.Random, name: str) -> GeneratedMap:
    while True:
        # ... pick the size, symmetry and kelp styles, and draw the kelp
        if len(layout.kelp) > (0.6 if dense else 0.35) * 2 * width * height:
            continue
        add_portals(layout, generator, min(generator.choice([0, 0, 1, 2, 3, 4, 6]), width * height // 80))
        playable = largest_component(layout)
        if len(playable) < (0.35 if dense else 0.6) * width * height:
            continue
        # ... choose how many dragons each team starts with, and how long
        if not place_dragons(layout, generator, playable, len(lengths), lengths):
            continue
        assign_spawn_ranges(layout, generator, playable, generator.choice(FOOD_LAYOUTS))
        return layout
```

It's also seeded, so `--seed 2026` gives the same 20 maps every time, and anyone can reproduce these results:

![Twenty generated maps, drawn as boards with their kelp, portals and starting dragons. They range from a narrow 10×8 map to 64×64, with open maps, mazes and walled rooms.](images/generated-maps.svg)

## The flood-fill bot on new maps

To see whether the new maps tell us anything, we'll play the same matchup twice: the flood-fill bot against the C starter, first on the bundled maps and then on the 20 generated ones. If the generated maps were just more of the same, both runs should look alike.

![A terminal running just unseen-maps. The generator lists 20 maps with their size, symmetry, kelp and portals. On the bundled maps, room-c wins 50 games and loses 2. On the generated maps it wins 72 and loses 8.](images/unseen-maps.png)

They don't. The flood-fill bot lost only 2 of its 52 games on the bundled maps, but 8 of its 80 on the generated ones, about two and a half times as often. That's already worth knowing, since it means the bundled maps flatter this bot. But the more useful part is what the losses looked like.

In the games it lost on generated maps, its dragons mostly died by running into their own bodies. That's strange, because the flood fill is supposed to make that impossible. It marks every tile with a dragon on it as blocked, including our own dragon's tiles, and never moves into one.

The replays showed what was going on. In every one of those deaths I traced, the fatal move went through a portal. The flood fill treats a portal like any other open edge, as if the dragon would simply step onto the tile next door. But a portal actually carries the dragon to its partner edge, which can be anywhere on the map. Sometimes that's right where the dragon's own body is.

Nine of the 13 bundled maps have portals too, and the bot rarely lost on them, so we'd never have spotted this without the new maps. Fixing it properly means teaching the flood fill how portals work, and it's the first job for the strategy posts.

## Where the tools fit

That's three of the eight tools on the wishlist. The harness plays the games, the statistics tell us what the results mean, and the generator makes sure those results hold on maps nobody has seen. Here's how they fit around the bot, next to the official toolkit and the rest of the wishlist:

![Our tools around the bot. The current bot sits in the middle, written in Nim with hot paths in C and compiled to WebAssembly, with numbered snapshots of earlier versions saved below it. The official toolkit is on the right: unswbc init, unswbc run --sandbox, --seed, unswbc maps, the visualiser and unswbc submit. Our wishlist tools are on the left with their languages: the evaluation harness, statistics and map generator in Python are built, and the offline Elo ladder, replay sampler, replay decoder, the Odin debug viewer and profiling are still to come. Ideas from the grand strategy, tactical ideas and espionage stages flow into the bot from the top.](images/pipeline.svg)

The point of all this is to take the drudgery out of improving a bot. Without these tools, every idea means hours of running games by hand and squinting at results that might just be luck. With them, trying an idea is one command, and the answer comes back as better, worse or undecided, tested on maps the bot has never seen. When a version passes, we save a numbered snapshot of it, and it becomes the version to beat.

Those three are enough to tell whether an idea worked, and every later post leans on them. The other five on the wishlist answer different questions. The offline Elo ladder shows whether the bot is getting better overall, and not just beating its last version. The replay sampler and decoder open up the other teams' games for study. The debug viewer shows why one of our dragons did what it did, and profiling shows where its CPU budget went. The rest of this stage builds those, and then the series turns to the part that actually decides games: the strategy and tactics of the dragons themselves.

## Next up

[A ladder of our own](06-a-ladder-of-our-own.md): rating every saved version against every other, so we can see whether the bot is improving overall.
