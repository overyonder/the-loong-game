#include "native_replay.h"
#include <exception>
#include <limits>
#include <memory>
#include <stdexcept>

struct LoongNativeMatch
{
    loong::Game game{};
    loong::NativeReplay replay;
    std::vector<uint8_t> bytes;
    std::string error;
    bool completed = false;
};

extern "C" uint32_t loong_native_abi() { return 1; }

extern "C" LoongNativeMatch *loong_native_create(LoongNativeCallbacks callbacks)
{
    if (!callbacks.reply)
        return nullptr;
    try
    {
        auto match = std::make_unique<LoongNativeMatch>();
        match->replay.callbacks = callbacks;
        return match.release();
    }
    catch (...)
    {
        return nullptr;
    }
}

extern "C" void loong_native_destroy(LoongNativeMatch *match) { delete match; }
extern "C" char const *loong_native_error(LoongNativeMatch const *match) { return match->error.c_str(); }

extern "C" int32_t loong_native_run(LoongNativeMatch *match, char const *map, size_t length, int32_t debug,
                                    uint64_t seed, int32_t result[12])
{
    try
    {
        match->completed = false;
        match->game = {};
        LoongNativeCallbacks const callbacks = match->replay.callbacks;
        match->replay = {};
        match->replay.callbacks = callbacks;
        match->replay.debug = debug;
        match->replay.seed = seed;
        match->replay.mapText.assign(map, length);
        match->error = loong::LoadMap(match->game, match->replay.mapText);
        if (!match->error.empty())
            return -1;
        for (int id = 0; id < match->game.nextId; id++)
            for (int slot = 0; slot < loong::MAX_SLOTS; slot++)
                if (match->game.dragon[slot].alive && match->game.dragon[slot].id == id)
                    match->replay.spawn(match->game, slot);
        loong::NativeReplaySink const sink{&match->replay, &match->game};
        loong::Begin(match->game, seed, sink);
        int slot;
        while ((slot = loong::Advance(match->game, sink)) >= 0)
        {
            int const id = match->game.dragon[slot].id;
            sink.emit({loong::TURN_EVENT, {id}});
            std::string const block = loong::RoundBlock(match->game, slot);
            size_t replyLength = 0;
            char const *reply =
                callbacks.reply(callbacks.context, static_cast<uint32_t>(id), block.data(), block.size(), &replyLength);
            if (!reply && replyLength)
                throw std::runtime_error("null reply buffer");
            if (replyLength > 10240)
                throw std::runtime_error("native reply exceeds SDK framing limit");
            std::vector<uint8_t> moveSteps;
            loong::Action const action =
                match->replay.readReply(id, std::string(reply ? reply : "", replyLength), moveSteps);
            loong::Act(match->game, action, sink);
            if (match->game.overflow)
                throw std::runtime_error("native engine capacity exceeded");
        }
        loong::NativeResult(match->game, match->replay.events.size(), result);
        match->completed = true;
        return 0;
    }
    catch (std::exception const &error)
    {
        match->error = error.what();
    }
    catch (...)
    {
        match->error = "native match failed";
    }
    return -1;
}

extern "C" int32_t loong_native_replay(LoongNativeMatch *match, char const *a, size_t aLength, char const *b,
                                       size_t bLength, uint8_t const **bytes, size_t *length)
{
    *bytes = nullptr;
    *length = 0;
    if (!match->completed)
    {
        match->error = "match has not completed";
        return -1;
    }
    try
    {
        match->bytes = match->replay.serialize(match->game, std::string(a, aLength), std::string(b, bLength));
        *bytes = match->bytes.data();
        *length = match->bytes.size();
        return 0;
    }
    catch (std::exception const &error)
    {
        match->error = error.what();
    }
    catch (...)
    {
        match->error = "native replay serialization failed";
    }
    return -1;
}
