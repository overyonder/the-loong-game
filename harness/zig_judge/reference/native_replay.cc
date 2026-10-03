#include "native_replay.h"
#include "replays/viewer/replay.capnp.h"
#include <algorithm>
#include <capnp/message.h>
#include <capnp/serialize-packed.h>
#include <cstring>
#include <kj/io.h>
#include <limits>
#include <stdexcept>

namespace loong
{

void NativeReplay::spawn(Game const &game, int slot)
{
    Dragon const &dragon = game.dragon[slot];
    teams.resize(static_cast<size_t>(dragon.id) + 1);
    teams[dragon.id] = dragon.team;
    std::string const init = InitBlock(game, slot);
    if (callbacks.spawn)
        callbacks.spawn(callbacks.context, static_cast<uint32_t>(dragon.id), init.data(), init.size());
}

void NativeReplay::append(ReplayEvent event, void const *data, size_t size)
{
    if (event.kind >= ENGINE_LOG_EVENT && event.kind <= DRAW_EVENT && (debug & 16))
    {
        int const team = teams.at(event.fields[0]);
        if (full[team])
            return;
        textBytes[team] += size;
        if (++notes[team] > 500000 || textBytes[team] > (16u << 20))
        {
            full[team] = true;
            static constexpr char message[] =
                "debug output limit reached (500000 lines or 16 MB per team), the rest of this team's is dropped";
            event = {ENGINE_LOG_EVENT, {event.fields[0]}};
            data = message;
            size = sizeof(message) - 1;
        }
    }
    if (payload.size() + size > std::numeric_limits<uint32_t>::max())
        throw std::runtime_error("replay payload exceeds offset capacity");
    event.payloadStart = static_cast<uint32_t>(payload.size());
    event.payloadCount = static_cast<uint32_t>(size);
    if (size)
    {
        auto const *start = static_cast<uint8_t const *>(data);
        payload.insert(payload.end(), start, start + size);
    }
    events.push_back(event);
}

void NativeReplay::consume(Game const &game, ReplayEvent const &event, void const *data, size_t size)
{
    if (event.kind == ACTION_ERROR_EVENT)
    {
        auto const *f = event.fields;
        std::string const text =
            f[1] == 0   ? "can't pay for step " + std::to_string(f[2])
            : f[1] == 1 ? "can't split " + std::to_string(f[2]) + " segments off a length of " + std::to_string(f[3])
                        : "can't split: unit limit of " + std::to_string(f[5]) + " reached";
        append({ENGINE_LOG_EVENT, {f[0]}}, text.data(), text.size());
        return;
    }
    append(event, data, size);
    if (event.kind == DEATH_EVENT && callbacks.death)
        callbacks.death(callbacks.context, static_cast<uint32_t>(event.fields[0]), event.fields[2],
                        static_cast<uint8_t>("WSOHA"[event.fields[1]]));
    if (event.kind == SPLIT_EVENT)
    {
        for (int slot = 0; slot < MAX_SLOTS; slot++)
            if (game.dragon[slot].alive && game.dragon[slot].id == event.fields[1])
            {
                spawn(game, slot);
                return;
            }
        throw std::runtime_error("split child missing from snapshot");
    }
}

void NativeReplaySink::split(Game const &state, int parent, int child) const
{
    Dragon const &a = state.dragon[parent];
    Dragon const &b = state.dragon[child];
    std::vector<int32_t> coordinates;
    coordinates.reserve(static_cast<size_t>(a.length + b.length) * 2);
    for (int slot : {parent, child})
        for (int cell = state.dragon[slot].head; cell >= 0; cell = state.towardTail[cell])
        {
            coordinates.push_back(X(state, cell));
            coordinates.push_back(Y(state, cell));
        }
    replay->consume(state, {SPLIT_EVENT, {a.id, b.id, b.team, b.facing, a.length, b.length}}, coordinates.data(),
                    coordinates.size() * sizeof(int32_t));
}

Action NativeReplay::readReply(int id, std::string const &reply, std::vector<uint8_t> &moveSteps)
{
    ReplyReplay const output{this, debug, id, [](void *context, ReplayEvent const &event, char const *text, size_t size)
                             { static_cast<NativeReplay *>(context)->append(event, text, size); }};
    Action const action = ReadReply(reply, moveSteps, &output);
    // The SDK engine callback does not attach SandboxBot.live to the replay.
    // Preserve its absent instruction pointer and false TLE; points stay in the
    // judge's separate turn columns rather than becoming invented metadata.
    ReplayEvent const event{ACTION_EVENT, {id, action.kind, action.split, action.steps}};
    if (action.kind == MOVE)
        append(event, action.extendedSteps ? action.extendedSteps : action.step, static_cast<size_t>(action.steps));
    else
        append(event);
    return action;
}

void NativeResult(Game const &game, size_t events, int32_t result[12])
{
    if (!game.over || game.overflow)
        throw std::runtime_error("native match incomplete");
    if (events > static_cast<size_t>(std::numeric_limits<int32_t>::max()))
        throw std::runtime_error("replay event count exceeds result capacity");
    Standing standings[2];
    Standings(game, standings);
    int32_t const values[12] = {game.round,           game.winner == 2 ? 0 : game.winner + 1,
                                game.endReason,       standings[0].dragons,
                                standings[1].dragons, standings[0].total,
                                standings[1].total,   static_cast<int32_t>(events),
                                standings[0].queen,   standings[1].queen,
                                standings[0].longest, standings[1].longest};
    std::copy(values, values + 12, result);
}

std::vector<uint8_t> NativeReplay::serialize(Game const &game, std::string const &a, std::string const &b) const
{
    capnp::MallocMessageBuilder message;
    auto replay = message.initRoot<::Replay>();
    replay.setFormatVersion(2);
    replay.initSeed().setValue(seed);
    replay.setMap(mapText.c_str());
    replay.setBotA(a.c_str());
    replay.setBotB(b.c_str());
    auto out = replay.initEvents(static_cast<unsigned int>(events.size()));
    auto const point = [](Point::Builder target, int x, int y)
    {
        target.setX(x);
        target.setY(y);
    };
    for (size_t i = 0; i < events.size(); i++)
    {
        ReplayEvent const &event = events[i];
        auto const *f = event.fields;
        auto target = out[static_cast<unsigned int>(i)];
        auto const *bytes = event.payloadCount ? payload.data() + event.payloadStart : nullptr;
        switch (event.kind)
        {
        case ROUND_EVENT:
            target.initRoundStart().setRound(f[0]);
            break;
        case TURN_EVENT:
            target.initTurnStart().setId(f[0]);
            break;
        case COUNTDOWN_EVENT:
        {
            auto value = target.initPearlCountdown();
            point(value.initTile(), f[0], f[1]);
            value.setCountdown(f[2]);
            break;
        }
        case TILE_EVENT:
        {
            auto value = target.initTileChange();
            point(value.initTile(), f[0], f[1]);
            value.setHasPearl(f[2] != 0);
            break;
        }
        case ACTION_EVENT:
        {
            auto value = target.initDragonAction();
            value.setId(f[0]);
            auto action = value.initAction();
            if (f[1] == MOVE)
            {
                auto steps = action.initMove(static_cast<unsigned int>(f[3]));
                for (int k = 0; k < f[3]; k++)
                    steps.set(static_cast<unsigned int>(k), static_cast<Direction>(bytes[k]));
            }
            else if (f[1] == SPLIT)
                action.setSplit(f[2]);
            else
                action.setSuicide();
            value.setTle(false);
            break;
        }
        case ENGINE_LOG_EVENT:
        case LOG_EVENT:
        case INDICATOR_EVENT:
        {
            auto value = event.kind == ENGINE_LOG_EVENT ? target.initEngineLog()
                         : event.kind == LOG_EVENT      ? target.initDragonLog()
                                                        : target.initDragonIndicator();
            std::string const text(bytes ? reinterpret_cast<char const *>(bytes) : "", event.payloadCount);
            value.setId(f[0]);
            value.setText(text.c_str());
            break;
        }
        case DRAW_EVENT:
        {
            auto value = target.initDebugDraw();
            value.setId(f[0]);
            auto draw = value.initDraw();
            draw.setShape(static_cast<uint16_t>(f[1]));
            point(draw.initFrom(), f[2], f[3]);
            point(draw.initTo(), f[4], f[5]);
            draw.setRed(static_cast<uint8_t>(f[6]));
            draw.setGreen(static_cast<uint8_t>(f[7]));
            draw.setBlue(static_cast<uint8_t>(event.value));
            break;
        }
        case UPDATE_EVENT:
        {
            auto value = target.initDragonUpdate();
            value.setId(f[0]);
            value.setFacing(static_cast<Direction>(f[1]));
            point(value.initHead(), f[2], f[3]);
            point(value.initTail(), f[4], f[5]);
            break;
        }
        case SPLIT_EVENT:
        {
            auto value = target.initDragonSplit();
            value.setParentId(f[0]);
            value.setChildId(f[1]);
            value.setTeam(static_cast<::Team>(f[2]));
            value.setChildFacing(static_cast<Direction>(f[3]));
            size_t position = 0;
            for (int body = 0; body < 2; body++)
            {
                auto points = body == 0 ? value.initParentBody(static_cast<unsigned int>(f[4]))
                                        : value.initChildBody(static_cast<unsigned int>(f[5]));
                for (auto targetPoint : points)
                {
                    int32_t coordinates[2];
                    std::memcpy(coordinates, bytes + position, sizeof(coordinates));
                    point(targetPoint, coordinates[0], coordinates[1]);
                    position += sizeof(coordinates);
                }
            }
            break;
        }
        case DEATH_EVENT:
        {
            auto value = target.initDragonDeath();
            value.setId(f[0]);
            value.setReason(static_cast<uint16_t>(f[1]));
            break;
        }
        case SONAR_EVENT:
        {
            auto value = target.initSonarPing();
            value.setSenderId(f[0]);
            value.setDirection(static_cast<Direction>(f[1]));
            value.setValue64(event.value);
            value.setHitKind(static_cast<uint16_t>(f[7]));
            point(value.initOrigin(), f[2], f[3]);
            point(value.initEnd(), f[4], f[5]);
            if (f[6] >= 0)
                value.setHitId(f[6]);
            else
                value.setNoHit();
            break;
        }
        default:
            throw std::runtime_error("unknown native replay event");
        }
    }
    auto result = replay.initResult();
    result.setTerminated(game.over != 0);
    result.setEndReason(game.endReason);
    if (game.winner == 2)
        result.setNoWinner();
    else
        result.setWinner(static_cast<::Team>(game.winner));
    Standing standings[2];
    Standings(game, standings);
    for (int team = 0; team < 2; team++)
    {
        auto standing = team == 0 ? result.initTeamA() : result.initTeamB();
        standing.setDragonCount(standings[team].dragons);
        standing.setLongestDragon(standings[team].longest);
        standing.setTotalLength(standings[team].total);
        standing.setQueenLength(standings[team].queen);
    }
    kj::VectorOutputStream stream;
    capnp::writePackedMessage(stream, message);
    auto const bytes = stream.getArray();
    return {bytes.begin(), bytes.end()};
}

} // namespace loong
