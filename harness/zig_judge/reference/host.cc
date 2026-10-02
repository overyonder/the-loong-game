// The host side of the ported engine (engine.h): loading a map, the text turn
// block a dragon reads, and the reply it writes, each following its namesake in
// the organisers' engine/src (config.cc, protocol.cc). The Zig judge's lockstep
// mode drives the port through the C interface at the end, beside the
// organisers' own engine, and compares every block.
//
// Original work: Copyright (c) 2026 UNSW CPMSoc, MIT License. The full notice
// is in engine.h.

#include "engine.h"
#include "port.h"

#include <algorithm>
#include <cmath>
#include <charconv>
#include <cstdio>
#include <cstring>
#include <map>
#include <memory>
#include <sstream>
#include <string>
#include <vector>

namespace loong {

static char const DIRS[] = "NESW";

// EdgeIndexOf: a map file's edge index to orientation * MAX_CELLS + cell, or -1
// for the right and bottom padding the map editor writes.
static int EdgeIndexOf(Game const& g, int index)
{
    int const stride = g.width + 1;
    int const column = index % stride;
    int const row = index / stride;
    if (index < 0 || row > 2 * g.height)
    {
        return -1;
    }
    if (row % 2 == 0)
    {
        if (column == g.width || row == 2 * g.height)
        {
            return -1;
        }
        return Cell(g, column, row / 2);
    }
    if (column == g.width)
    {
        return -1;
    }
    return MAX_CELLS + Cell(g, column, (row - 1) / 2);
}

// LoadMap into a zeroed game. Returns an error, or an empty string.
std::string LoadMap(Game& g, std::string const& text)
{
    g.unitLimit = 64;
    for (int o = 0; o < 2; o++)
    {
        for (int c = 0; c < MAX_CELLS; c++)
        {
            g.edgeKind[o][c] = OPEN;
            g.portalId[o][c] = -1;
            g.partner[o][c] = -1;
        }
    }
    for (int c = 0; c < MAX_CELLS; c++)
    {
        g.occupant[c] = -1;
        g.towardHead[c] = -1;
        g.towardTail[c] = -1;
    }
    std::map<int, std::vector<int>> portalEnds;
    std::istringstream lines(text);
    std::string line;
    int slots = 0;
    while (std::getline(lines, line))
    {
        if (!line.empty() && line.back() == '\r')
        {
            line.pop_back();
        }
        if (line.empty())
        {
            continue;
        }
        if (line == "END")
        {
            break;
        }
        std::istringstream fields(line);
        std::string keyword;
        fields >> keyword;
        if (keyword == "MAP")
        {
            fields >> g.width >> g.height;
            if (g.width < VISION || g.height < VISION || g.width > MAX_SIDE || g.height > MAX_SIDE)
            {
                return "map size " + std::to_string(g.width) + "x" + std::to_string(g.height) + " is outside 7 to 64";
            }
        }
        else if (keyword == "UNIT_LIMIT")
        {
            fields >> g.unitLimit;
            if (g.unitLimit < 1 || 2 * g.unitLimit > MAX_SLOTS)
            {
                return "unit limit " + std::to_string(g.unitLimit) + " is beyond the port's arrays";
            }
        }
        else if (keyword == "SYMMETRY")
        {
            std::string value;
            fields >> value;
            g.symmetry = value == "x" ? SYM_X : value == "y" ? SYM_Y : value == "xy" ? SYM_XY : SYM_NONE;
        }
        else if (keyword == "TILE")
        {
            int x = 0, y = 0, lo = 0, hi = 0;
            fields >> x >> y >> lo >> hi;
            int const c = Cell(g, x, y);
            g.spawns[c] = hi > 0;
            g.minGap[c] = lo;
            g.maxGap[c] = hi;
        }
        else if (keyword == "EDGE")
        {
            int index = 0, kind = 0, id = -1;
            fields >> index >> kind >> id;
            int const edge = EdgeIndexOf(g, index);
            if (edge < 0)
            {
                continue;
            }
            int const o = edge / MAX_CELLS, c = edge % MAX_CELLS;
            if (kind == 0)
            {
                g.edgeKind[o][c] = OPEN;
            }
            else if (kind == 1)
            {
                g.edgeKind[o][c] = KELP;
            }
            else
            {
                g.portalId[o][c] = static_cast<int16_t>(g.edgeKind[o][c] == PORTAL ? std::min<int>(g.portalId[o][c], id) : id);
                g.edgeKind[o][c] = PORTAL;
                portalEnds[id].push_back(edge);
            }
        }
        else if (keyword == "DRAGON")
        {
            int team = 0, count = 0;
            fields >> team >> count;
            if (slots >= MAX_SLOTS)
            {
                return "too many dragons";
            }
            Dragon& d = g.dragon[slots];
            d.id = g.nextId++;
            d.team = static_cast<uint8_t>(team);
            d.alive = 1;
            d.protocol = LEGACY_PROTOCOL;
            d.length = count;
            int previous = -1;
            for (int i = 0; i < count; i++)
            {
                int x = 0, y = 0;
                fields >> x >> y;
                int const c = Cell(g, x, y);
                g.occupant[c] = static_cast<int16_t>(slots);
                g.towardHead[c] = static_cast<int16_t>(previous);
                if (previous >= 0)
                {
                    g.towardTail[previous] = static_cast<int16_t>(c);
                }
                if (i == 0)
                {
                    d.head = static_cast<int16_t>(c);
                }
                d.tail = static_cast<int16_t>(c);
                previous = c;
            }
            g.alive[d.team]++;
            slots++;
        }
        // TILE_COUNT, EDGE_COUNT, DRAGON_COUNT and MAP_NAME only check or label.
    }
    for (auto const& [id, ends] : portalEnds)
    {
        if (ends.size() != 2)
        {
            continue;
        }
        int const o0 = ends[0] / MAX_CELLS, c0 = ends[0] % MAX_CELLS;
        int const o1 = ends[1] / MAX_CELLS, c1 = ends[1] % MAX_CELLS;
        g.partner[o0][c0] = ends[1];
        g.partner[o1][c1] = ends[0];
        int16_t const shared = std::min(g.portalId[o0][c0], g.portalId[o1][c1]);
        g.portalId[o0][c0] = g.portalId[o1][c1] = shared;
    }
    for (int s = 0; s < slots; s++)
    {
        Dragon& d = g.dragon[s];
        d.facing = static_cast<uint8_t>(DirectionOfStepBetween(g, g.towardTail[d.head], d.head));
    }
    return "";
}

static void AppendEdge(std::string& out, Game const& g, int edge)
{
    int const o = edge / MAX_CELLS, c = edge % MAX_CELLS;
    switch (g.edgeKind[o][c])
    {
    case KELP: out += 'w'; return;
    case PORTAL: out += std::to_string(g.portalId[o][c]); return;
    default: out += '.';
    }
}

static bool Within(int from, int to, int size)
{
    int const offset = ((to - from) % size + size) % size;
    return offset <= VISION_RADIUS || offset >= size - VISION_RADIUS;
}

// BuildRoundBlock for the dragon in `slot`.
std::string RoundBlock(Game const& g, int slot)
{
    Dragon const& d = g.dragon[slot];
    int const hx = X(g, d.head), hy = Y(g, d.head);
    bool const echoes = d.protocol >= ECHO_PROTOCOL;
    std::vector<uint64_t> readable;
    for (int i = 0; i < std::min(d.inboxCount, INBOX); i++)
    {
        if (echoes || d.inbox[i] <= UINT32_MAX)
        {
            readable.push_back(d.inbox[i]);
        }
    }
    std::string out = "ROUND " + std::to_string(g.round) + "\nDIR " + DIRS[d.facing] + "\nLENGTH " +
                      std::to_string(d.length) + "\nUNIT_COUNT " + std::to_string(g.alive[d.team]) + "\nNUM_MSGS " +
                      std::to_string(readable.size()) + "\n";
    for (uint64_t const m : readable)
    {
        out += std::to_string(m) + "\n";
    }
    if (echoes)
    {
        out += "ECHOES";
        for (int k = 0; k < 5; k++)
        {
            out += " " + std::to_string(d.echoes[k]);
        }
        out += '\n';
    }
    auto const tileAt = [&](int column, int row) {
        return Cell(g, Wrap(hx + column - VISION_RADIUS, g.width), Wrap(hy + row - VISION_RADIUS, g.height));
    };
    for (int row = 0; row < VISION; row++)
    {
        for (int column = 0; column < VISION; column++)
        {
            int const c = tileAt(column, row);
            out += std::to_string(X(g, c)) + " " + std::to_string(Y(g, c)) + (g.pearl[c] ? " 1 " : " 0 ") +
                   std::to_string(g.spawns[c] ? g.countdown[c] : -1) + "\n";
        }
    }
    // Bodies in the engine's order: dragons by ID, each from its head.
    std::vector<int> byId;
    for (int s = 0; s < MAX_SLOTS; s++)
    {
        if (g.dragon[s].alive)
        {
            byId.push_back(s);
        }
    }
    std::sort(byId.begin(), byId.end(), [&](int a, int b) { return g.dragon[a].id < g.dragon[b].id; });
    std::string bodies;
    int count = 0;
    for (int s : byId)
    {
        Dragon const& other = g.dragon[s];
        int segment = 0;
        for (int c = other.head, previous = -1; c >= 0; previous = c, c = g.towardTail[c], segment++)
        {
            if (!Within(hx, X(g, c), g.width) || !Within(hy, Y(g, c), g.height))
            {
                continue;
            }
            int const facing = segment == 0 ? other.facing : DirectionOfStepBetween(g, c, previous);
            bodies += other.team == 0 ? 'A' : 'B';
            bodies += " " + std::to_string(other.id) + " " + std::to_string(X(g, c)) + " " + std::to_string(Y(g, c)) + " " +
                      DIRS[facing] + (segment == 0 ? " 1\n" : " 0\n");
            count++;
        }
    }
    out += "DRAGON_BODIES " + std::to_string(count) + "\n" + bodies;
    for (int row = 0; row <= VISION; row++)
    {
        for (int column = 0; column < VISION; column++)
        {
            int const edge = row < VISION ? EdgeOnTileSide(g, tileAt(column, row), N) : EdgeOnTileSide(g, tileAt(column, row - 1), S);
            if (column > 0)
            {
                out += ' ';
            }
            AppendEdge(out, g, edge);
        }
        out += "\n";
    }
    for (int row = 0; row < VISION; row++)
    {
        for (int column = 0; column <= VISION; column++)
        {
            int const edge = column < VISION ? EdgeOnTileSide(g, tileAt(column, row), W) : EdgeOnTileSide(g, tileAt(column - 1, row), E);
            if (column > 0)
            {
                out += ' ';
            }
            AppendEdge(out, g, edge);
        }
        out += "\n";
    }
    return out;
}

static char const* AfterSpaces(char const* text)
{
    while (isspace(static_cast<unsigned char>(*text)))
    {
        text++;
    }
    return text;
}

static int DirOf(char c)
{
    char const* at = strchr(DIRS, c);
    return c != '\0' && at ? static_cast<int>(at - DIRS) : -1;
}

// ReadReply, keeping only what changes the game: the action, sonar and protocol.
Action ReadReply(std::string const& text)
{
    Action a;
    std::istringstream lines(text.substr(0, text.rfind('\n') + 1));
    std::string line;
    while (std::getline(lines, line))
    {
        if (!line.empty() && line.back() == '\r')
        {
            line.pop_back();
        }
        char keyword[16] = "";
        int start = 0;
        sscanf(line.c_str(), "%15s%n", keyword, &start);
        std::string const command = keyword;
        char const* args = line.c_str() + start;
        int consumed = 0;
        if (command.empty())
        {
            continue;
        }
        if (command == "ENDTURN" && *AfterSpaces(args) == '\0')
        {
            break;
        }
        if (command == "MOVE")
        {
            Action move = a;
            move.steps = 0;
            char const* at = AfterSpaces(args);
            bool valid = true;
            int steps = 0;
            for (; *at != '\0' && !isspace(static_cast<unsigned char>(*at)); at++)
            {
                int const d = DirOf(*at);
                if (d < 0)
                {
                    valid = false;
                    break;
                }
                if (steps < MAX_STEPS)
                {
                    move.step[steps] = static_cast<uint8_t>(d);
                }
                steps++;
            }
            if (valid && steps > 0 && *AfterSpaces(at) == '\0' && steps <= MAX_STEPS)
            {
                move.kind = MOVE;
                move.steps = static_cast<uint8_t>(steps);
                a = move;
            }
        }
        else if (command == "SPLIT")
        {
            int count = 0;
            if (sscanf(args, "%d %n", &count, &consumed) == 1 && args[consumed] == '\0')
            {
                a.kind = SPLIT;
                a.split = count;
            }
        }
        else if (command == "SONAR")
        {
            uint32_t value = 0;
            char direction = 0;
            char digits[21] = "";
            if (sscanf(args, "%u %n", &value, &consumed) == 1 && args[consumed] == '\0')
            {
                a.legacySonar = 1;
                a.legacyValue = value;
            }
            else if (sscanf(args, " %c %20[0-9] %n", &direction, digits, &consumed) == 2 && args[consumed] == '\0' &&
                     DirOf(direction) >= 0)
            {
                uint64_t v = 0;
                char const* end = digits + strlen(digits);
                auto const [stop, error] = std::from_chars(digits, end, v);
                if (error == std::errc{} && stop == end)
                {
                    int const d = DirOf(direction);
                    a.sonarMask |= static_cast<uint8_t>(1 << d);
                    a.sonar[d] = v;
                }
            }
        }
        else if (command == "PROTOCOL")
        {
            int major = 0;
            if (sscanf(args, "%d %n", &major, &consumed) == 1 && args[consumed] == '\0')
            {
                a.protocol = major;
            }
        }
    }
    return a;
}


} // namespace loong

extern "C" {

struct LoongPort
{
    loong::Game game;
    int slot;
};

LoongPort* loong_port_create(char const* map, size_t length, uint64_t seed, char* error, size_t errorCapacity)
{
    auto* port = static_cast<LoongPort*>(calloc(1, sizeof(LoongPort)));
    std::string const why = loong::LoadMap(port->game, std::string(map, length));
    if (!why.empty())
    {
        snprintf(error, errorCapacity, "%s", why.c_str());
        free(port);
        return nullptr;
    }
    loong::Begin(port->game, seed);
    port->slot = -1;
    return port;
}

// The next turn's dragon ID and block, or -1 once the game is over. A block
// longer than `capacity` is cut short.
int32_t loong_port_next(LoongPort* port, char* block, size_t capacity, size_t* length)
{
    port->slot = loong::Advance(port->game);
    if (port->slot < 0)
    {
        *length = 0;
        return -1;
    }
    std::string const text = loong::RoundBlock(port->game, port->slot);
    *length = std::min(text.size(), capacity);
    memcpy(block, text.data(), *length);
    return port->game.dragon[port->slot].id;
}

void loong_port_apply(LoongPort* port, char const* reply, size_t length)
{
    loong::Act(port->game, loong::ReadReply(std::string(reply, length)));
}

// rounds, winner (1 A, 2 B, 0 none), end reason, then each team's dragons,
// longest and total length, then how often the port ran past its arrays.
void loong_port_result(LoongPort const* port, int32_t* out)
{
    loong::Standing s[2];
    loong::Standings(port->game, s);
    out[0] = port->game.round + 1;
    out[1] = port->game.winner == 2 ? 0 : port->game.winner + 1;
    out[2] = port->game.endReason;
    out[3] = s[0].dragons;
    out[4] = s[0].longest;
    out[5] = s[0].total;
    out[6] = s[1].dragons;
    out[7] = s[1].longest;
    out[8] = s[1].total;
    out[9] = port->game.overflow;
}

void loong_port_destroy(LoongPort* port)
{
    free(port);
}
}
