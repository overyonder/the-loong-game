// The host side of the ported engine (engine.h): loading a map, the text turn
// block a dragon reads, and the reply it writes, each following its namesake in
// the organisers' engine/src (config.cc, protocol.cc). The Zig judge's lockstep
// mode drives the port through the C interface at the end, beside the
// organisers' own engine, and compares every block.
//
// Original work: Copyright (c) 2026 UNSW CPMSoc, MIT License. The full notice
// is in engine.h.

#include "turn.h"
#include "reply_replay.h"
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
    g.unseen[0] = g.unseen[1] = 0;
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
            if ((team != 0 && team != 1) || (slots > 0 && team == g.dragon[slots - 1].team))
            {
                return "initial dragon teams must alternate";
            }
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

// An edge's token in a round block: kelp, a portal's ID, or open.
static void AppendEdge(std::string& out, int kind, int portal)
{
    if (kind == KELP) out += 'w';
    else if (kind == PORTAL) out += std::to_string(portal);
    else out += '.';
}

// The round block the dragon in `slot` is sent: the turn BuildTurn builds
// (turn/0001.h), which the training engine encodes directly, as text.
std::string RoundBlock(Game const& g, int slot)
{
    TurnView t;
    BuildTurn(g, slot, t);
    std::string out = "ROUND " + std::to_string(t.round) + "\nDIR " + DIRS[t.facing] + "\nLENGTH " +
                      std::to_string(t.length) + "\nUNIT_COUNT " + std::to_string(t.units) + "\nNUM_MSGS " +
                      std::to_string(t.messageCount) + "\n";
    for (int k = 0; k < t.messageCount; k++) out += std::to_string(t.messages[k]) + "\n";
    if (g.dragon[slot].protocol >= ECHO_PROTOCOL)
    {
        out += "ECHOES";
        for (int k = 0; k < 5; k++) out += " " + std::to_string(t.echoes[k]);
        out += '\n';
    }
    for (int i = 0; i < VIEW_TILES; i++)
        out += std::to_string(t.x[i]) + " " + std::to_string(t.y[i]) + (t.pearl[i] ? " 1 " : " 0 ") +
               std::to_string(t.countdown[i]) + "\n";
    // Bodies in the engine's order: dragons by ID, each from its head.
    std::vector<std::pair<std::pair<int, int>, int>> listed;
    for (int i = 0; i < VIEW_TILES; i++)
    {
        if (t.segmentId[i] < 0) continue;
        int steps = 0;
        for (int c = Cell(g, t.x[i], t.y[i]); g.towardHead[c] >= 0; c = g.towardHead[c]) steps++;
        listed.push_back({{t.segmentId[i], steps}, i});
    }
    std::sort(listed.begin(), listed.end());
    out += "DRAGON_BODIES " + std::to_string(listed.size()) + "\n";
    for (auto const& [key, i] : listed)
    {
        out += t.segmentTeam[i] == 0 ? 'A' : 'B';
        out += " " + std::to_string(t.segmentId[i]) + " " + std::to_string(t.x[i]) + " " + std::to_string(t.y[i]) + " " +
               DIRS[t.segmentFacing[i]] + (t.segmentHead[i] ? " 1\n" : " 0\n");
    }
    for (int r = 0; r <= VISION; r++)
    {
        for (int c = 0; c < VISION; c++)
        {
            if (c > 0) out += ' ';
            AppendEdge(out, t.horizontal[r][c], t.horizontalId[r][c]);
        }
        out += "\n";
    }
    for (int r = 0; r < VISION; r++)
    {
        for (int c = 0; c <= VISION; c++)
        {
            if (c > 0) out += ' ';
            AppendEdge(out, t.vertical[r][c], t.verticalId[r][c]);
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

// ReadReply owns both simulation commands and optional replay annotations.
Action ReadReply(std::string const& text, std::vector<uint8_t>& moveSteps, ReplyReplay const* replay)
{
    Action a;
    std::string indicator;
    bool hasIndicator = false;
    auto const emitText = [&](ReplayEventKind kind, std::string const& value) {
        if (replay) replay->emit(replay->context, {kind, {replay->dragonId}}, value.data(), value.size());
    };
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
            std::vector<uint8_t> candidate;
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
                candidate.push_back(static_cast<uint8_t>(d));
                steps++;
            }
            if (valid && steps > 0 && *AfterSpaces(at) == '\0')
            {
                move.kind = MOVE;
                move.steps = steps;
                moveSteps = std::move(candidate);
                move.extendedSteps = steps > MAX_STEPS ? moveSteps.data() : nullptr;
                a = move;
                continue;
            }
        }
        else if (command == "SPLIT")
        {
            int count = 0;
            if (sscanf(args, "%d %n", &count, &consumed) == 1 && args[consumed] == '\0')
            {
                a.kind = SPLIT;
                a.split = count;
                continue;
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
                continue;
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
                    continue;
                }
            }
        }
        else if (command == "PROTOCOL")
        {
            int major = 0;
            if (sscanf(args, "%d %n", &major, &consumed) == 1 && args[consumed] == '\0')
            {
                a.protocol = major;
                continue;
            }
        }
        else if (command == "LOG")
        {
            if (replay && (replay->debug & 1)) emitText(LOG_EVENT, AfterSpaces(args));
            continue;
        }
        else if (command == "INDICATOR")
        {
            if (replay && (replay->debug & 2))
            {
                indicator = AfterSpaces(args);
                if ((replay->debug & 16) && indicator.size() > 512) indicator.resize(512);
                hasIndicator = true;
            }
            continue;
        }
        else if (command == "DOT" || command == "LINE")
        {
            int x = 0, y = 0, toX = 0, toY = 0;
            unsigned char red = 0, green = 0, blue = 0;
            bool const dot = command == "DOT";
            int const read = dot
                ? sscanf(args, "%d %d %hhu %hhu %hhu %n", &x, &y, &red, &green, &blue, &consumed)
                : sscanf(args, "%d %d %d %d %hhu %hhu %hhu %n", &x, &y, &toX, &toY, &red, &green, &blue, &consumed);
            if (read == (dot ? 5 : 7) && args[consumed] == '\0')
            {
                if (dot) { toX = x; toY = y; }
                if (replay && (replay->debug & 4))
                    replay->emit(replay->context, {DRAW_EVENT, {replay->dragonId, dot ? 1 : 0, x, y, toX, toY, red, green}, blue}, nullptr, 0);
                continue;
            }
        }
        if (replay && (replay->debug & 8)) emitText(ENGINE_LOG_EVENT, "can't read line: " + line);
    }
    if (hasIndicator) emitText(INDICATOR_EVENT, indicator);
    return a;
}

std::string InitBlock(Game const& g, int slot)
{
    std::ostringstream out;
    out << "ID " << g.dragon[slot].id << "\n";
    out << "TEAM " << (g.dragon[slot].team == 0 ? 'A' : 'B') << "\n";
    out << "MAP " << g.width << ' ' << g.height << "\n";
    out << "UNIT_LIMIT " << g.unitLimit << "\n";
    return out.str();
}

} // namespace loong

// The C interface the Zig judge's lockstep mode links.
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
    std::vector<uint8_t> moveSteps;
    loong::Act(port->game, loong::ReadReply(std::string(reply, length), moveSteps));
}

// rounds, winner (1 A, 2 B, 0 none), end reason, then each team's dragons,
// longest and total length, then overflow and the two queen lengths.
void loong_port_result(LoongPort const* port, int32_t* out)
{
    loong::Standing s[2];
    loong::Standings(port->game, s);
    out[0] = port->game.round;
    out[1] = port->game.winner == 2 ? 0 : port->game.winner + 1;
    out[2] = port->game.endReason;
    out[3] = s[0].dragons;
    out[4] = s[0].longest;
    out[5] = s[0].total;
    out[6] = s[1].dragons;
    out[7] = s[1].longest;
    out[8] = s[1].total;
    out[9] = port->game.overflow;
    out[10] = s[0].queen;
    out[11] = s[1].queen;
}

// The trainer's action `a` (engine.h's Decode) for the dragon `loong_port_next`
void loong_port_destroy(LoongPort* port) { free(port); }
}
