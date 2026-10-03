#pragma once

#include "native.h"
#include "reply_replay.h"
#include <array>

namespace loong
{

// One replay owner for CPU capture and drained CUDA events. These are staging
// bytes, not another replay schema; serialization uses generated replay.capnp.
struct NativeReplay
{
    std::vector<ReplayEvent> events;
    std::vector<uint8_t> payload;
    std::vector<uint8_t> teams;
    std::array<uint64_t, 2> notes{};
    std::array<uint64_t, 2> textBytes{};
    std::array<bool, 2> full{};
    std::string mapText;
    uint64_t seed = 0;
    int debug = 0;
    LoongNativeCallbacks callbacks{};

    void spawn(Game const &, int slot);
    void append(ReplayEvent, void const *data = nullptr, size_t size = 0);
    void consume(Game const &, ReplayEvent const &, void const *data = nullptr, size_t size = 0);
    Action readReply(int id, std::string const &, std::vector<uint8_t> &moveSteps);
    std::vector<uint8_t> serialize(Game const &, std::string const &a, std::string const &b) const;
};

struct NativeReplaySink
{
    NativeReplay *replay;
    Game const *game;
    void emit(ReplayEvent const &event) const { replay->consume(*game, event); }
    void split(Game const &state, int parent, int child) const;
};

void NativeResult(Game const &, size_t events, int32_t result[12]);

} // namespace loong
