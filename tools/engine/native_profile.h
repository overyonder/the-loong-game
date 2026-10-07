#pragma once

#include <array>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <stdexcept>

// Aggregate diagnostics for the separately selected complete-match library.
// Inclusive host intervals overlap. Worker callback time is a sum across
// threads, not elapsed batch time. Device timings use the real CUDA stream.
enum class NativeHostStage : size_t
{
    SETUP,
    RUN,
    NEXT,
    DRAIN,
    OBSERVATIONS,
    BOT_WAVE,
    CALLBACK_SUM,
    APPLY,
    PARSE_REPLIES,
    COPY_ENQUEUE,
    STREAM_WAIT,
    CONSUME_EVENTS,
    SERIALIZE,
    CLEANUP,
    COUNT
};

enum class NativeDeviceStageTiming : size_t
{
    BEGIN,
    ADVANCE,
    APPLY,
    ACTIONS_HTOD,
    ACTING_DTOH,
    STATE_EVENTS_DTOH,
    COUNT
};

struct NativeStageTiming
{
    uint64_t nanoseconds = 0;
    uint64_t calls = 0;
};

struct NativeMatchProfile
{
    using Clock = std::chrono::steady_clock;
    bool enabled = false;
    std::array<NativeStageTiming, static_cast<size_t>(NativeHostStage::COUNT)> host{};
    std::array<NativeStageTiming, static_cast<size_t>(NativeDeviceStageTiming::COUNT)> device{};
    uint64_t waves = 0;
    uint64_t decisions = 0;
    uint64_t copiesHtoD = 0;
    uint64_t bytesHtoD = 0;
    uint64_t copiesDtoH = 0;
    uint64_t bytesDtoH = 0;

    NativeMatchProfile()
    {
        char const *value = std::getenv("LOONG_NATIVE_PROFILE");
        if (value)
        {
            if (std::strcmp(value, "1") != 0)
                throw std::runtime_error("LOONG_NATIVE_PROFILE must be unset or 1");
            enabled = true;
        }
    }

    Clock::time_point begin() const
    {
        return enabled ? Clock::now() : Clock::time_point{};
    }

    uint64_t elapsed(Clock::time_point start) const
    {
        return enabled ? static_cast<uint64_t>(
                             std::chrono::duration_cast<std::chrono::nanoseconds>(Clock::now() - start).count())
                       : 0;
    }

    void add(NativeHostStage stage, NativeStageTiming timing)
    {
        if (!enabled)
            return;
        auto &total = host[static_cast<size_t>(stage)];
        total.nanoseconds += timing.nanoseconds;
        total.calls += timing.calls;
    }

    void finish(NativeHostStage stage, Clock::time_point start)
    {
        add(stage, {elapsed(start), 1});
    }

    void print(size_t games, bool completed, bool failed) const
    {
        if (!enabled)
            return;
        constexpr char const *hostNames[] = {
            "setup", "run",           "next",         "drain",       "observations",   "bot_wave",  "callback_sum",
            "apply", "parse_replies", "copy_enqueue", "stream_wait", "consume_events", "serialize", "cleanup"};
        constexpr char const *deviceNames[] = {"begin",        "advance",     "apply",
                                               "actions_htod", "acting_dtoh", "state_events_dtoh"};
        static_assert(std::size(hostNames) == static_cast<size_t>(NativeHostStage::COUNT));
        static_assert(std::size(deviceNames) == static_cast<size_t>(NativeDeviceStageTiming::COUNT));
        std::fprintf(stderr, "native-profile\t1\tbatch\t%zu\tcompleted\t%d\tfailed\t%d\n", games, completed, failed);
        for (size_t stage = 0; stage < host.size(); stage++)
            std::fprintf(stderr, "native-profile\t1\thost\t%s\t%llu\t%llu\n", hostNames[stage],
                         static_cast<unsigned long long>(host[stage].calls),
                         static_cast<unsigned long long>(host[stage].nanoseconds));
        for (size_t stage = 0; stage < device.size(); stage++)
            std::fprintf(stderr, "native-profile\t1\tdevice\t%s\t%llu\t%llu\n", deviceNames[stage],
                         static_cast<unsigned long long>(device[stage].calls),
                         static_cast<unsigned long long>(device[stage].nanoseconds));
        std::fprintf(stderr, "native-profile\t1\twaves\t%llu\tdecisions\t%llu\n",
                     static_cast<unsigned long long>(waves), static_cast<unsigned long long>(decisions));
        std::fprintf(stderr, "native-profile\t1\tcopy\thtod\t%llu\t%llu\n", static_cast<unsigned long long>(copiesHtoD),
                     static_cast<unsigned long long>(bytesHtoD));
        std::fprintf(stderr, "native-profile\t1\tcopy\tdtoh\t%llu\t%llu\n", static_cast<unsigned long long>(copiesDtoH),
                     static_cast<unsigned long long>(bytesDtoH));
    }
};

struct NativeHostTimer
{
    NativeMatchProfile &profile;
    NativeHostStage stage;
    NativeMatchProfile::Clock::time_point start;

    NativeHostTimer(NativeMatchProfile &owner, NativeHostStage section)
        : profile(owner), stage(section), start(owner.begin())
    {
    }
    NativeHostTimer(NativeHostTimer const &) = delete;
    NativeHostTimer &operator=(NativeHostTimer const &) = delete;
    ~NativeHostTimer()
    {
        profile.finish(stage, start);
    }
};
