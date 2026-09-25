# Sonar

<!-- draft: 5e1a7c20b3, stage: Tactical ideas and espionage -->

Battlecode seasons usually hinge on one unusual mechanic, something the designers built that year's game around and that the strongest teams learn to exploit better than anyone else. In unswbc 2026, it's sonar. It's the only way dragons can talk to each other, it's the only way they can learn anything beyond their 7×7 window, and every message is just as audible to the enemy as to a teammate.

The strategy posts used sonar for plain jobs: announcing a dragon's length in [Roles](12-roles.md), and its position in [Tactics](13-tactics.md). This post steps back and looks at what else it could do. It's closer to a notebook than a tutorial: a tour of what the rules allow, with the working out left to you.

## How it works

Each turn, after it acts, a dragon may send up to four 64-bit values, one in each direction. Each becomes a ray that travels in a straight line, wraps round the edges of the board, passes through portals, and stops at the first kelp wall or living dragon segment it meets, including the sender's own body. A ray that finds nothing within the width plus the height of the board is lost. The ray pointing opposite the dragon's facing is the odd one out: it starts from the tail and points away from the body.

Whoever a ray hits receives its value on their next turn, with no sender and no team attached. And on its own next turn, the sender learns how many of its rays hit each of five things: kelp, an allied body, an allied head, an enemy body or an enemy head. Those counts are totals over all its rays, and they only arrive once a bot switches on the newer protocol with `PROTOCOL 3`.

![A small board with our dragon facing east and its four rays. The north ray stops at a kelp wall. The east ray hits an enemy's head. The south ray runs off the bottom edge, comes back in at the top and stops at the same kelp wall from above. The west ray, opposite the facing, starts from the tail and hits a teammate's body. The echoes the dragon reads next turn are kelp 2, allied body 1, allied head 0, enemy body 0 and enemy head 1.](images/sonar-rays.svg)

Every one of those details turned out to matter somewhere. The wrap-around is what made our roles bot hear its own messages. The missing sender is why we needed a team tag. The rest are waiting for someone to use them.

## Encoding

Sixty-four bits is both a lot and very little. It's enough for a team tag, an ID, a role, a length and a position, which is what the tactics bot sends, but every bit spent on one thing is a bit not spent on another. The roles bot spent 32 bits on its tag and the tactics bot only 16, to make room for a position. And a message doesn't have to fit in one ray. A dragon can send four values a turn, over as many turns as it likes, so larger things can be split up and reassembled, as long as every piece reaches the same listener.

## Decoding

Every message reaches whoever the ray hits, so an enemy dragon in the way receives ours just as a teammate would, and our dragons receive theirs. A team tag keeps random traffic from being mistaken for a teammate's, but it doesn't hide what a message says. Anything a bot sends should be something it doesn't mind the other team reading.

## Fingerprinting

Even without decoding a message, its shape can say something about who sent it. A team whose messages always look the same is recognisable from them, and that works in both directions: whatever another team's messages give away about them, ours give away about us.

## Echolocation

The echo counts are the only information a dragon gets from beyond its window that no teammate has to send. They say what the dragon's rays hit, which means something out of sight is in that direction. Because the counts are totals over all of a dragon's rays, turning them into a direction takes some thought.

## Misinformation

Messages carry no sender, so nothing in the game stops a dragon from sending a message in another team's format, or stops another team from sending one in ours. A bot that believes everything it hears can be misled. Checking a message against what the dragon can see for itself is the simplest defence.

## Poker

Someone on the competition Discord proposed my favourite sonar idea so far: a jester bot. It drops down to a single dragon, lines up with an enemy, starts spinning in a circle, and plays a game of poker over the line between them.

It's a joke, but it's a good one, because it's about what sonar really is: a channel between two programs that don't trust each other and can't see each other's cards. Poker over sonar needs exactly the things a serious protocol needs, like a way to commit to a card without revealing it, a way to catch the other side cheating, and a way to tell whether the message you just received came from the dragon you're playing or from someone else listening in. Whether any bot on the ladder would fold is another question.

## Next up

That's the end of the ideas stages. The last stage of the series is performance: making the thinking a bot does cheaper, so it can afford more of it, starting with [counting room faster](15-counting-room-faster.md).
