// Included only by the separately built LOONG_NATIVE_REPLAY CUDA candidate.
// The learning batch keeps its existing ABI, allocations and empty event sink.
#include "native_profile.h"
#include "native_replay.h"
#include <atomic>
#include <barrier>
#include <exception>
#include <limits>
#include <memory>
#include <stdexcept>
#include <thread>

namespace
{

// One 10 KiB framed move plus all corpse pearls / a full round's pearl tick.
// Capacity failure is fatal; no truncation, replay retry or CPU simulation.
constexpr uint32_t NATIVE_EVENT_CAPACITY = 2 * MAX_CELLS + 10240;
constexpr uint32_t NATIVE_COORDINATE_CAPACITY = 2 * MAX_CELLS;

struct NativeDeviceStage
{
    uint32_t events = 0;
    uint32_t coordinates = 0;
    uint32_t failed = 0;
};

struct NativeDeviceEvents
{
    NativeDeviceStage *stage;
    ReplayEvent *events;
    int32_t *coordinates;

    LE void emit(ReplayEvent const &event) const
    {
        if (stage->events >= NATIVE_EVENT_CAPACITY)
        {
            stage->failed = 1;
            return;
        }
        events[stage->events++] = event;
    }

    LE void split(Game const &game, int parent, int child) const
    {
        Dragon const &a = game.dragon[parent];
        Dragon const &b = game.dragon[child];
        uint32_t const count = static_cast<uint32_t>(a.length + b.length) * 2;
        if (stage->coordinates + count > NATIVE_COORDINATE_CAPACITY)
        {
            stage->failed = 1;
            return;
        }
        ReplayEvent event{SPLIT_EVENT, {a.id, b.id, b.team, b.facing, a.length, b.length}};
        event.payloadStart = stage->coordinates * sizeof(int32_t);
        event.payloadCount = count * sizeof(int32_t);
        for (int body = 0; body < 2; body++)
            for (int cell = game.dragon[body == 0 ? parent : child].head; cell >= 0; cell = game.towardTail[cell])
            {
                coordinates[stage->coordinates++] = X(game, cell);
                coordinates[stage->coordinates++] = Y(game, cell);
            }
        emit(event);
    }
};

__device__ NativeDeviceEvents NativeSink(int game, NativeDeviceStage *stages, ReplayEvent *events, int32_t *coordinates)
{
    return {stages + game, events + static_cast<size_t>(game) * NATIVE_EVENT_CAPACITY,
            coordinates + static_cast<size_t>(game) * NATIVE_COORDINATE_CAPACITY};
}

__global__ void NativeBegin(Game *games, int count, uint64_t const *seeds, NativeDeviceStage *stages,
                            ReplayEvent *events, int32_t *coordinates)
{
    int const index = static_cast<int>(blockIdx.x * blockDim.x + threadIdx.x);
    if (index < count)
        Begin(games[index], seeds[index], NativeSink(index, stages, events, coordinates));
}

__global__ void NativeAdvance(Game *games, int count, int32_t *acting, NativeDeviceStage *stages, ReplayEvent *events,
                              int32_t *coordinates)
{
    int const index = static_cast<int>(blockIdx.x * blockDim.x + threadIdx.x);
    if (index >= count)
        return;
    auto const sink = NativeSink(index, stages, events, coordinates);
    acting[index] = Advance(games[index], sink);
    if (acting[index] >= 0)
        sink.emit({TURN_EVENT, {games[index].dragon[acting[index]].id}});
}

__global__ void NativeApply(Game *games, int count, int32_t const *acting, Action const *actions,
                            NativeDeviceStage *stages, ReplayEvent *events, int32_t *coordinates)
{
    int const index = static_cast<int>(blockIdx.x * blockDim.x + threadIdx.x);
    if (index < count && acting[index] >= 0)
        Act(games[index], actions[index], NativeSink(index, stages, events, coordinates));
}

void NativeCudaCheck(cudaError_t status)
{
    if (status != cudaSuccess)
        throw std::runtime_error(std::string("CUDA: ") + cudaGetErrorString(status));
}

struct NativeCudaProfile
{
    std::array<std::array<cudaEvent_t, 2>, static_cast<size_t>(NativeDeviceStageTiming::COUNT)> events{};

    void create(NativeMatchProfile const &profile)
    {
        if (profile.enabled)
            for (auto &pair : events)
                for (auto &event : pair)
                    NativeCudaCheck(cudaEventCreate(&event));
    }

    ~NativeCudaProfile()
    {
        destroy();
    }

    void destroy()
    {
        for (auto &pair : events)
            for (auto &event : pair)
                if (event)
                {
                    cudaEventDestroy(event);
                    event = nullptr;
                }
    }

    void record(NativeMatchProfile const &profile, NativeDeviceStageTiming stage, size_t edge, cudaStream_t stream)
    {
        if (profile.enabled)
            NativeCudaCheck(cudaEventRecord(events[static_cast<size_t>(stage)][edge], stream));
    }

    // Called only after the existing stream synchronization. No new wait is
    // introduced to collect timing. A pair is reused only after collection.
    void collect(NativeMatchProfile &profile, NativeDeviceStageTiming stage)
    {
        if (!profile.enabled)
            return;
        auto const &pair = events[static_cast<size_t>(stage)];
        float milliseconds = 0;
        NativeCudaCheck(cudaEventElapsedTime(&milliseconds, pair[0], pair[1]));
        auto &timing = profile.device[static_cast<size_t>(stage)];
        timing.nanoseconds += static_cast<uint64_t>(static_cast<double>(milliseconds) * 1000000);
        timing.calls++;
    }
};

} // namespace

struct LoongNativeCudaBatch
{
    size_t count;
    Game *games = nullptr;
    int32_t *acting = nullptr;
    uint64_t *seeds = nullptr;
    Action *actions = nullptr;
    uint8_t *steps = nullptr;
    size_t stepCapacity = 0;
    NativeDeviceStage *stages = nullptr;
    ReplayEvent *events = nullptr;
    int32_t *coordinates = nullptr;
    cudaStream_t stream = nullptr;
    std::vector<Game> snapshots;
    std::vector<int32_t> hostActing;
    std::vector<NativeDeviceStage> hostStages;
    std::vector<NativeReplay> replays;
    std::vector<std::string> blocks;
    std::vector<std::vector<uint8_t>> packed;
    std::vector<LoongNativeDecision> decisions;
    std::string error;
    bool waiting = false;
    bool completed = false;
    NativeMatchProfile profile;
    NativeCudaProfile deviceProfile;

    explicit LoongNativeCudaBatch(size_t gamesCount)
        : count(gamesCount), snapshots(gamesCount), hostActing(gamesCount), hostStages(gamesCount), replays(gamesCount),
          blocks(gamesCount), packed(gamesCount)
    {
    }

    ~LoongNativeCudaBatch()
    {
        auto const cleanupStart = profile.begin();
        if (stream)
            cudaStreamSynchronize(stream);
        cudaFree(games);
        cudaFree(acting);
        cudaFree(seeds);
        cudaFree(actions);
        cudaFree(steps);
        cudaFree(stages);
        cudaFree(events);
        cudaFree(coordinates);
        if (stream)
            cudaStreamDestroy(stream);
        deviceProfile.destroy();
        profile.finish(NativeHostStage::CLEANUP, cleanupStart);
        profile.print(count, completed, !completed || !error.empty());
    }

    void copy(void *destination, void const *source, size_t bytes, cudaMemcpyKind direction)
    {
        NativeHostTimer timer(profile, NativeHostStage::COPY_ENQUEUE);
        NativeCudaCheck(cudaMemcpyAsync(destination, source, bytes, direction, stream));
        if (profile.enabled)
        {
            if (direction == cudaMemcpyHostToDevice)
            {
                profile.copiesHtoD++;
                profile.bytesHtoD += bytes;
            }
            else
            {
                profile.copiesDtoH++;
                profile.bytesDtoH += bytes;
            }
        }
    }

    void synchronize()
    {
        NativeHostTimer timer(profile, NativeHostStage::STREAM_WAIT);
        NativeCudaCheck(cudaStreamSynchronize(stream));
    }

    void drain()
    {
        NativeHostTimer timer(profile, NativeHostStage::DRAIN);
        deviceProfile.record(profile, NativeDeviceStageTiming::STATE_EVENTS_DTOH, 0, stream);
        copy(snapshots.data(), games, count * sizeof(Game), cudaMemcpyDeviceToHost);
        copy(hostStages.data(), stages, count * sizeof(NativeDeviceStage), cudaMemcpyDeviceToHost);
        deviceProfile.record(profile, NativeDeviceStageTiming::STATE_EVENTS_DTOH, 1, stream);
        synchronize();
        deviceProfile.collect(profile, NativeDeviceStageTiming::STATE_EVENTS_DTOH);
        std::vector<ReplayEvent> copiedEvents;
        std::vector<int32_t> copiedCoordinates;
        for (size_t i = 0; i < count; i++)
        {
            auto const stage = hostStages[i];
            if (stage.failed || snapshots[i].overflow)
                throw std::runtime_error("CUDA native game/event capacity exceeded");
            copiedEvents.resize(stage.events);
            copiedCoordinates.resize(stage.coordinates);
            bool const hasCopy = stage.events || stage.coordinates;
            if (hasCopy)
                deviceProfile.record(profile, NativeDeviceStageTiming::STATE_EVENTS_DTOH, 0, stream);
            if (stage.events)
                copy(copiedEvents.data(), events + i * NATIVE_EVENT_CAPACITY, stage.events * sizeof(ReplayEvent),
                     cudaMemcpyDeviceToHost);
            if (stage.coordinates)
                copy(copiedCoordinates.data(), coordinates + i * NATIVE_COORDINATE_CAPACITY,
                     stage.coordinates * sizeof(int32_t), cudaMemcpyDeviceToHost);
            if (hasCopy)
                deviceProfile.record(profile, NativeDeviceStageTiming::STATE_EVENTS_DTOH, 1, stream);
            synchronize();
            if (hasCopy)
                deviceProfile.collect(profile, NativeDeviceStageTiming::STATE_EVENTS_DTOH);
            NativeHostTimer consumeTimer(profile, NativeHostStage::CONSUME_EVENTS);
            for (auto const &event : copiedEvents)
            {
                if (event.payloadCount &&
                    (event.payloadStart + event.payloadCount > stage.coordinates * sizeof(int32_t)))
                    throw std::runtime_error("invalid CUDA event payload");
                auto const *data = event.payloadCount ? reinterpret_cast<uint8_t const *>(copiedCoordinates.data()) +
                                                            event.payloadStart
                                                      : nullptr;
                replays[i].consume(snapshots[i], event, data, event.payloadCount);
            }
        }
        NativeCudaCheck(cudaMemsetAsync(stages, 0, count * sizeof(NativeDeviceStage), stream));
        synchronize();
    }

    void next()
    {
        if (!error.empty())
            throw std::runtime_error(error);
        if (waiting || completed)
            return;
        NativeHostTimer timer(profile, NativeHostStage::NEXT);
        deviceProfile.record(profile, NativeDeviceStageTiming::ADVANCE, 0, stream);
        NativeAdvance<<<static_cast<unsigned int>((count + 127) / 128), 128, 0, stream>>>(
            games, static_cast<int>(count), acting, stages, events, coordinates);
        NativeCudaCheck(cudaGetLastError());
        deviceProfile.record(profile, NativeDeviceStageTiming::ADVANCE, 1, stream);
        deviceProfile.record(profile, NativeDeviceStageTiming::ACTING_DTOH, 0, stream);
        copy(hostActing.data(), acting, count * sizeof(int32_t), cudaMemcpyDeviceToHost);
        deviceProfile.record(profile, NativeDeviceStageTiming::ACTING_DTOH, 1, stream);
        drain();
        deviceProfile.collect(profile, NativeDeviceStageTiming::ADVANCE);
        deviceProfile.collect(profile, NativeDeviceStageTiming::ACTING_DTOH);
        NativeHostTimer formatTimer(profile, NativeHostStage::OBSERVATIONS);
        decisions.clear();
        for (size_t i = 0; i < count; i++)
        {
            int const slot = hostActing[i];
            if (slot < 0)
                continue;
            auto const &game = snapshots[i];
            blocks[i] = RoundBlock(game, slot); // read-only; no host Advance/Act
            auto const &dragon = game.dragon[slot];
            decisions.push_back({static_cast<uint32_t>(i), game.round, static_cast<uint32_t>(dragon.id), dragon.team,
                                 blocks[i].data(), blocks[i].size()});
        }
        waiting = !decisions.empty();
        completed = !waiting;
        if (profile.enabled && waiting)
        {
            profile.waves++;
            profile.decisions += decisions.size();
        }
    }

    void apply(char const *const *replies, size_t const *lengths, size_t supplied)
    {
        if (!error.empty())
            throw std::runtime_error(error);
        if (!waiting || supplied != decisions.size())
            throw std::runtime_error("CUDA replies do not match pending decisions");
        NativeHostTimer timer(profile, NativeHostStage::APPLY);
        std::vector<Action> hostActions(count);
        std::vector<uint8_t> extendedSteps;
        std::vector<size_t> offsets(count);
        {
            NativeHostTimer parseTimer(profile, NativeHostStage::PARSE_REPLIES);
            for (size_t i = 0; i < decisions.size(); i++)
            {
                auto const &decision = decisions[i];
                if (!replies[i] && lengths[i])
                    throw std::runtime_error("null CUDA reply buffer");
                if (lengths[i] > 10240)
                    throw std::runtime_error("CUDA reply exceeds SDK framing limit");
                std::vector<uint8_t> parsed;
                Action action = replays[decision.game].readReply(
                    static_cast<int>(decision.dragonId), std::string(replies[i] ? replies[i] : "", lengths[i]), parsed);
                if (action.extendedSteps)
                {
                    offsets[decision.game] = extendedSteps.size();
                    extendedSteps.insert(extendedSteps.end(), parsed.begin(), parsed.end());
                }
                hostActions[decision.game] = action;
            }
        }
        if (extendedSteps.size() > stepCapacity)
        {
            synchronize();
            NativeCudaCheck(cudaFree(steps));
            steps = nullptr;
            stepCapacity = 0;
            NativeCudaCheck(cudaMalloc(&steps, extendedSteps.size()));
            stepCapacity = extendedSteps.size();
        }
        deviceProfile.record(profile, NativeDeviceStageTiming::ACTIONS_HTOD, 0, stream);
        if (!extendedSteps.empty())
            copy(steps, extendedSteps.data(), extendedSteps.size(), cudaMemcpyHostToDevice);
        for (size_t i = 0; i < count; i++)
            if (hostActions[i].extendedSteps)
                hostActions[i].extendedSteps = steps + offsets[i];
        copy(actions, hostActions.data(), count * sizeof(Action), cudaMemcpyHostToDevice);
        deviceProfile.record(profile, NativeDeviceStageTiming::ACTIONS_HTOD, 1, stream);
        deviceProfile.record(profile, NativeDeviceStageTiming::APPLY, 0, stream);
        NativeApply<<<static_cast<unsigned int>((count + 127) / 128), 128, 0, stream>>>(
            games, static_cast<int>(count), acting, actions, stages, events, coordinates);
        NativeCudaCheck(cudaGetLastError());
        deviceProfile.record(profile, NativeDeviceStageTiming::APPLY, 1, stream);
        drain(); // also waits before host long-move storage goes out of scope
        deviceProfile.collect(profile, NativeDeviceStageTiming::ACTIONS_HTOD);
        deviceProfile.collect(profile, NativeDeviceStageTiming::APPLY);
        waiting = false;
    }
};

namespace
{

template <typename Function> int32_t NativeCudaOperation(LoongNativeCudaBatch *batch, Function operation)
{
    if (!batch->error.empty())
        return -1;
    try
    {
        operation();
        return 0;
    }
    catch (std::exception const &error)
    {
        batch->error = error.what();
    }
    catch (...)
    {
        batch->error = "CUDA native operation failed";
    }
    return -1;
}

// Persistent workers execute only canonical host callbacks. Each game has one
// pending turn, and every wave joins before any device mutation or next turn.
class NativeReplyWorkers
{
    LoongNativeCudaBatch &batch;
    std::atomic<size_t> next{0};
    std::atomic<bool> stopping{false};
    std::barrier<> start;
    std::barrier<> done;
    std::vector<std::thread> workers;
    std::vector<std::string> replies;
    std::vector<std::exception_ptr> failures;
    // A worker owns its entry until the done barrier. The controller merges
    // only after that barrier, while workers wait for the next wave.
    std::vector<NativeStageTiming> callbackTimings;

  public:
    NativeReplyWorkers(LoongNativeCudaBatch &owner, size_t count)
        : batch(owner), start(static_cast<ptrdiff_t>(count + 1)), done(static_cast<ptrdiff_t>(count + 1)),
          replies(owner.count), failures(count), callbackTimings(count)
    {
        // Reserve before creating any joinable threads. A thread-creation failure
        // explicitly drops unstarted barrier participants and joins the rest.
        workers.reserve(count);
        try
        {
            for (size_t worker = 0; worker < count; worker++)
                workers.emplace_back([this, worker] {
                    while (true)
                    {
                        start.arrive_and_wait();
                        if (stopping.load())
                            return;
                        try
                        {
                            while (true)
                            {
                                size_t const index = next.fetch_add(1);
                                if (index >= batch.decisions.size())
                                    break;
                                auto const &decision = batch.decisions[index];
                                auto const &callback = batch.replays[decision.game].callbacks;
                                size_t length = 0;
                                auto const callbackStart = batch.profile.begin();
                                char const *reply = callback.reply(callback.context, decision.dragonId, decision.block,
                                                                   decision.blockLength, &length);
                                if (batch.profile.enabled)
                                {
                                    callbackTimings[worker].nanoseconds += batch.profile.elapsed(callbackStart);
                                    callbackTimings[worker].calls++;
                                }
                                if (length > 10240)
                                    throw std::runtime_error("live bot reply exceeds SDK framing limit");
                                if (!reply && length)
                                    throw std::runtime_error("null live bot reply");
                                replies[index].assign(reply ? reply : "", length);
                            }
                        }
                        catch (...)
                        {
                            failures[worker] = std::current_exception();
                        }
                        done.arrive_and_wait();
                    }
                });
        }
        catch (...)
        {
            for (size_t missing = workers.size(); missing < count; missing++)
                start.arrive_and_drop();
            stopping.store(true);
            start.arrive_and_wait();
            for (auto &worker : workers)
                worker.join();
            throw;
        }
    }

    ~NativeReplyWorkers()
    {
        stopping.store(true);
        start.arrive_and_wait();
        for (auto &worker : workers)
            worker.join();
    }

    void answer()
    {
        next.store(0);
        auto const waveStart = batch.profile.begin();
        start.arrive_and_wait();
        done.arrive_and_wait();
        batch.profile.finish(NativeHostStage::BOT_WAVE, waveStart);
        for (auto &timing : callbackTimings)
        {
            batch.profile.add(NativeHostStage::CALLBACK_SUM, timing);
            timing = {};
        }
        for (auto const &failure : failures)
            if (failure)
                std::rethrow_exception(failure);
        std::vector<char const *> pointers(batch.decisions.size());
        std::vector<size_t> lengths(batch.decisions.size());
        for (size_t i = 0; i < pointers.size(); i++)
        {
            pointers[i] = replies[i].data();
            lengths[i] = replies[i].size();
        }
        batch.apply(pointers.data(), lengths.data(), pointers.size());
    }
};

} // namespace

extern "C" LoongNativeCudaBatch *loong_native_cuda_create(LoongNativeSetup const *setups, size_t count, char *error,
                                                          size_t capacity)
{
    try
    {
        if (!count || count > static_cast<size_t>(std::numeric_limits<int>::max()))
            throw std::runtime_error("invalid CUDA game count");
        auto batch = std::make_unique<LoongNativeCudaBatch>(count);
        // Keep the owner alive until setup timing is closed, even if setup
        // fails. The unique_ptr is released only after this scope.
        {
            NativeHostTimer setupTimer(batch->profile, NativeHostStage::SETUP);
            NativeCudaCheck(cudaStreamCreateWithFlags(&batch->stream, cudaStreamNonBlocking));
            batch->deviceProfile.create(batch->profile);
            NativeCudaCheck(cudaMalloc(&batch->games, count * sizeof(Game)));
            NativeCudaCheck(cudaMalloc(&batch->acting, count * sizeof(int32_t)));
            NativeCudaCheck(cudaMalloc(&batch->seeds, count * sizeof(uint64_t)));
            NativeCudaCheck(cudaMalloc(&batch->actions, count * sizeof(Action)));
            NativeCudaCheck(cudaMalloc(&batch->stages, count * sizeof(NativeDeviceStage)));
            NativeCudaCheck(cudaMalloc(&batch->events, count * NATIVE_EVENT_CAPACITY * sizeof(ReplayEvent)));
            NativeCudaCheck(cudaMalloc(&batch->coordinates, count * NATIVE_COORDINATE_CAPACITY * sizeof(int32_t)));
            std::vector<uint64_t> seeds(count);
            for (size_t i = 0; i < count; i++)
            {
                if (!setups[i].callbacks.reply)
                    throw std::runtime_error("missing CUDA bot callback");
                auto &replay = batch->replays[i];
                replay.callbacks = setups[i].callbacks;
                replay.debug = setups[i].debug;
                replay.seed = seeds[i] = setups[i].seed;
                replay.mapText.assign(setups[i].map, setups[i].mapLength);
                std::string const why = LoadMap(batch->snapshots[i], replay.mapText);
                if (!why.empty())
                    throw std::runtime_error(why);
                for (int id = 0; id < batch->snapshots[i].nextId; id++)
                    for (int slot = 0; slot < MAX_SLOTS; slot++)
                        if (batch->snapshots[i].dragon[slot].alive && batch->snapshots[i].dragon[slot].id == id)
                            replay.spawn(batch->snapshots[i], slot);
            }
            batch->copy(batch->games, batch->snapshots.data(), count * sizeof(Game), cudaMemcpyHostToDevice);
            batch->copy(batch->seeds, seeds.data(), count * sizeof(uint64_t), cudaMemcpyHostToDevice);
            NativeCudaCheck(cudaMemsetAsync(batch->stages, 0, count * sizeof(NativeDeviceStage), batch->stream));
            batch->deviceProfile.record(batch->profile, NativeDeviceStageTiming::BEGIN, 0, batch->stream);
            NativeBegin<<<static_cast<unsigned int>((count + 127) / 128), 128, 0, batch->stream>>>(
                batch->games, static_cast<int>(count), batch->seeds, batch->stages, batch->events, batch->coordinates);
            NativeCudaCheck(cudaGetLastError());
            batch->deviceProfile.record(batch->profile, NativeDeviceStageTiming::BEGIN, 1, batch->stream);
            batch->drain();
            batch->deviceProfile.collect(batch->profile, NativeDeviceStageTiming::BEGIN);
        }
        return batch.release();
    }
    catch (std::exception const &failure)
    {
        snprintf(error, capacity, "%s", failure.what());
    }
    catch (...)
    {
        snprintf(error, capacity, "CUDA native creation failed");
    }
    return nullptr;
}

extern "C" int32_t loong_native_cuda_next(LoongNativeCudaBatch *batch, LoongNativeDecision const **decisions,
                                          size_t *count)
{
    *decisions = nullptr;
    *count = 0;
    return NativeCudaOperation(batch, [&] {
        batch->next();
        *decisions = batch->decisions.data();
        *count = batch->decisions.size();
    });
}

extern "C" int32_t loong_native_cuda_apply(LoongNativeCudaBatch *batch, char const *const *replies,
                                           size_t const *lengths, size_t count)
{
    return NativeCudaOperation(batch, [&] { batch->apply(replies, lengths, count); });
}

extern "C" int32_t loong_native_cuda_run(LoongNativeCudaBatch *batch, uint32_t hostThreads)
{
    return NativeCudaOperation(batch, [&] {
        NativeHostTimer timer(batch->profile, NativeHostStage::RUN);
        size_t const threads = std::max<size_t>(1, std::min<size_t>(hostThreads, batch->count));
        NativeReplyWorkers workers(*batch, threads);
        while (true)
        {
            batch->next();
            if (batch->completed)
                break;
            workers.answer();
        }
    });
}

extern "C" int32_t loong_native_cuda_result(LoongNativeCudaBatch *batch, uint32_t game, int32_t result[12])
{
    return NativeCudaOperation(batch, [&] {
        if (!batch->completed || game >= batch->count)
            throw std::runtime_error("CUDA native result unavailable");
        NativeResult(batch->snapshots[game], batch->replays[game].events.size(), result);
    });
}

extern "C" int32_t loong_native_cuda_replay(LoongNativeCudaBatch *batch, uint32_t game, char const *a, size_t aLength,
                                            char const *b, size_t bLength, uint8_t const **bytes, size_t *length)
{
    *bytes = nullptr;
    *length = 0;
    return NativeCudaOperation(batch, [&] {
        if (!batch->completed || game >= batch->count)
            throw std::runtime_error("CUDA native replay unavailable");
        NativeHostTimer timer(batch->profile, NativeHostStage::SERIALIZE);
        batch->packed[game] =
            batch->replays[game].serialize(batch->snapshots[game], std::string(a, aLength), std::string(b, bLength));
        *bytes = batch->packed[game].data();
        *length = batch->packed[game].size();
    });
}

extern "C" char const *loong_native_cuda_error(LoongNativeCudaBatch const *batch)
{
    return batch->error.c_str();
}
extern "C" void loong_native_cuda_destroy(LoongNativeCudaBatch *batch)
{
    delete batch;
}
