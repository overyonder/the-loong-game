#pragma once

#include <stdint.h>

namespace loong
{

// Device staging for the canonical tools/gamedata/replay.capnp events. Variable
// bodies and text are owned by the sink; offsets are relative to its payload.
enum ReplayEventKind : uint32_t
{
    ROUND_EVENT,
    TURN_EVENT,
    COUNTDOWN_EVENT,
    TILE_EVENT,
    ACTION_EVENT,
    ENGINE_LOG_EVENT,
    LOG_EVENT,
    INDICATOR_EVENT,
    DRAW_EVENT,
    UPDATE_EVENT,
    SPLIT_EVENT,
    DEATH_EVENT,
    SONAR_EVENT,
    ACTION_ERROR_EVENT,
};

struct ReplayEvent
{
    ReplayEventKind kind;
    int32_t fields[8] = {};
    uint64_t value = 0;
    uint32_t payloadStart = 0;
    uint32_t payloadCount = 0;
};

// Training instantiates the same simulation with no event storage or work.
struct NoReplayEvents
{
    LE void emit(ReplayEvent const &) const {}
    template <typename GameType> LE void split(GameType const &, int, int) const {}
};

} // namespace loong
