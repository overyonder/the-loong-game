#pragma once
#include "engine.h"
#include <cstring>
namespace loong {
inline char const DIRS[] = "NESW";

inline int DirOf(char c)
{
    char const* at = strchr(DIRS, c);
    return c != '\0' && at ? static_cast<int>(at - DIRS) : -1;
}

// The visible turn fields used to serialize a dragon's protocol block.
constexpr int VIEW_TILES = VISION * VISION;
constexpr int TURN_MESSAGES = 512;      // messages a round block may carry, kept

struct TurnView
{
    int round, facing, length, units;
    int messageCount;                     // the messages the block carries, as sent
    uint64_t messages[TURN_MESSAGES];
    int echoes[5];                        // zeros on a legacy-protocol block, which has no ECHOES line
    // The view's tiles, row by row in world orientation, the head at the middle.
    int x[VIEW_TILES], y[VIEW_TILES], countdown[VIEW_TILES];
    uint8_t pearl[VIEW_TILES];
    // The segment on each tile: its dragon's ID (-1 for none), its team, whether
    // it is the head, and its facing (a body segment faces toward its head).
    int segmentId[VIEW_TILES], segmentFacing[VIEW_TILES];
    uint8_t segmentTeam[VIEW_TILES];
    bool segmentHead[VIEW_TILES];
    // horizontal[r][c] is the north edge of tile row r, row VISION the south
    // edge of the last row; vertical[r][c] the west edge of tile column c,
    // column VISION the east edge of the last column. Each is an edge kind
    // with its portal ID, or -1.
    uint8_t horizontal[VISION + 1][VISION], vertical[VISION][VISION + 1];
    int horizontalId[VISION + 1][VISION], verticalId[VISION][VISION + 1];
};
LE int TurnCell(int x, int y, int width, int height)
{
    return Wrap(y, height) * width + Wrap(x, width);
}

LE int PortalIdOn(Game const& g, int o, int c)
{
    return g.edgeKind[o][c] == PORTAL ? g.portalId[o][c] : -1;
}

LE void BuildTurn(Game const& g, int slot, TurnView& t)
{
    Dragon const& d = g.dragon[slot];
    int const hx = X(g, d.head), hy = Y(g, d.head);
    bool const echoes = d.protocol >= ECHO_PROTOCOL;
    t.round = g.round;
    t.facing = d.facing;
    t.length = d.length;
    t.units = g.alive[d.team];
    // A legacy-protocol block leaves out messages wider than 32 bits.
    t.messageCount = 0;
    for (int k = 0; k < d.inboxCount && k < INBOX; k++)
        if (echoes || d.inbox[k] <= 0xFFFFFFFFull) t.messages[t.messageCount++] = d.inbox[k];
    for (int k = 0; k < 5; k++) t.echoes[k] = echoes ? d.echoes[k] : 0;
    int columns[VISION + 1], rows[VISION + 1];
    columns[0] = Wrap(hx - VISION_RADIUS, g.width);
    rows[0] = Wrap(hy - VISION_RADIUS, g.height);
    for (int k = 1; k <= VISION; k++)
    {
        columns[k] = columns[k - 1] + 1 == g.width ? 0 : columns[k - 1] + 1;
        rows[k] = rows[k - 1] + 1 == g.height ? 0 : rows[k - 1] + 1;
    }
    for (int i = 0; i < VIEW_TILES; i++)
    {
        int const x = columns[i % VISION], y = rows[i / VISION];
        int const c = Cell(g, x, y);
        t.x[i] = x;
        t.y[i] = y;
        t.pearl[i] = g.pearl[c] ? 1 : 0;
        t.countdown[i] = g.spawns[c] ? g.countdown[c] : -1;
        int const who = g.occupant[c];
        t.segmentId[i] = who >= 0 ? g.dragon[who].id : -1;
        t.segmentTeam[i] = who >= 0 ? g.dragon[who].team : 0;
        t.segmentHead[i] = who >= 0 && g.dragon[who].head == c;
        t.segmentFacing[i] = who < 0 ? 0 : t.segmentHead[i] ? g.dragon[who].facing : DirectionOfStepBetween(g, c, g.towardHead[c]);
    }
    for (int r = 0; r <= VISION; r++)
        for (int c = 0; c < VISION; c++)
        {
            int const tile = Cell(g, columns[c], rows[r]);
            t.horizontal[r][c] = g.edgeKind[0][tile];
            t.horizontalId[r][c] = PortalIdOn(g, 0, tile);
        }
    for (int r = 0; r < VISION; r++)
        for (int c = 0; c <= VISION; c++)
        {
            int const tile = Cell(g, columns[c], rows[r]);
            t.vertical[r][c] = g.edgeKind[1][tile];
            t.verticalId[r][c] = PortalIdOn(g, 1, tile);
        }
}
}
