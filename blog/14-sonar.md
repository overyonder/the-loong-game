# Sonar

<!-- draft: 5e1a7c20b3, stage: Tactical ideas and espionage -->

Battlecode seasons usually hinge on one unusual mechanic, something the designers built that year's game around and that the strongest teams learn to exploit better than anyone else. In unswbc 2026, it's sonar. It's the only way dragons can talk to each other, it's the only way they can learn anything beyond their 7×7 window, and every message is just as audible to the enemy as to a teammate.

The strategy posts used sonar for plain jobs: announcing a dragon's length in [Roles](12-roles.md), and its position in [Tactics](13-tactics.md). This post steps back and looks at what else it could do. It's closer to a notebook than a tutorial. Like the questions at the start of the tactics post, most of what follows is open, and I'd rather hand out good questions than my own answers.

## How it works

Each turn, after it acts, a dragon may send up to four 64-bit values, one in each direction. Each becomes a ray that travels in a straight line, wraps round the edges of the board, passes through portals, and stops at the first kelp wall or living dragon segment it meets, including the sender's own body. A ray that finds nothing within the width plus the height of the board is lost. The ray pointing opposite the dragon's facing is the odd one out: it starts from the tail and points away from the body.

Whoever a ray hits receives its value on their next turn, with no sender and no team attached. And on its own next turn, the sender learns how many of its rays hit each of five things: kelp, an allied body, an allied head, an enemy body or an enemy head. Those counts are totals over all its rays, and they only arrive once a bot switches on the newer protocol with `PROTOCOL 3`.

![A small board with our dragon facing east and its four rays. The north ray stops at a kelp wall. The east ray hits an enemy's head. The south ray runs off the bottom edge, comes back in at the top and stops at the same kelp wall from above. The west ray, opposite the facing, starts from the tail and hits a teammate's body. The echoes the dragon reads next turn are kelp 2, allied body 1, allied head 0, enemy body 0 and enemy head 1.](images/sonar-rays.svg)

Every one of those details turned out to matter somewhere. The wrap-around is what made our roles bot hear its own messages. The missing sender is why we needed a team tag. The rest are waiting for someone to use them.

## Encoding

Sixty-four bits is both a lot and very little. It's enough for a team tag, an ID, a role, a length and a position, which is what the tactics bot sends, but every bit spent on one thing is a bit not spent on another. The roles bot spent 32 bits on its tag and the tactics bot only 16, to make room for a position. How short can a tag be before random enemy traffic starts to pass for ours? Is it better to spend bits on a checksum than on a longer tag? And a message doesn't have to fit in one ray: a dragon can send four values a turn, over as many turns as it likes, so larger things, like a map of what it has seen, can be split and reassembled, at the cost of every piece having to reach the same listener.

## Decoding

Nothing stops an enemy reading our messages, and nothing stops us reading theirs. A dragon in the path of an enemy ray receives the value like any other. And the [public replays](08-reading-a-replay.md) record every sonar message ever sent on the ladder, with its value, where it came from and what it hit. So a team's message format isn't a secret for long if anyone cares to look. What would you learn from another team's traffic, if you could read it? And what could you deliberately leave in yours for them to find?

## Fingerprinting

Even without decoding a message, its shape says something. A team that always sends four rays, or always puts the same 16 bits at the top, is recognisable from a single message. That raises two questions. Can a bot tell which opponent it's facing, part way through a game, from the messages that hit it, and switch strategies to suit? And how much of your own identity leaks from the way you talk, before anyone decodes a word of it?

## Echolocation

The echo counts are the only information a dragon gets from beyond its window that no teammate has to send. A ray fired down a long corridor that comes back with "enemy head: 1" says something is coming from that direction, well before it's visible. But the counts are totals over all the rays a dragon sent that turn, so four rays and one enemy head don't say which way it is. Firing fewer rays tells you more about each. How much can a dragon learn by aiming its rays deliberately, or by comparing its echoes with a teammate's? And since the rays pass through portals, what can a dragon learn about where a portal leads without ever using it?

## Misinformation

If our team tag can be copied, so can the enemy's. A dragon that learns another team's message format can speak it: announce a champion that doesn't exist, report a longer length than it has, or send the enemy's feeders somewhere empty. The roles post noted that our own tag stops random traffic but not a deliberate forgery. The open question is whether any of this is worth the effort. A lie only pays off if the enemy's bot acts on what it hears, and measuring that takes the same careful testing as any other change.

## Poker

Someone on the competition Discord proposed my favourite sonar idea so far: a jester bot. It drops down to a single dragon, lines up with an enemy, starts spinning in a circle, and plays a game of poker over the line between them.

It's a joke, but it's a good one, because it's about what sonar really is: a channel between two programs that don't trust each other and can't see each other's cards. Poker over sonar needs exactly the things a serious protocol needs, like a way to commit to a card without revealing it, a way to catch the other side cheating, and a way to tell whether the message you just received came from the dragon you're playing or from someone else listening in. Whether any bot on the ladder would fold is another question.

## Next up

That's the end of the ideas stages. The last stage of the series is performance: making the thinking a bot does cheaper, so it can afford more of it, starting with [counting room faster](15-counting-room-faster.md).
