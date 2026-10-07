// loong-map-fit: the pearl gap tables of served map variants, from games'
// seeds and spawns (tools/ladder/map_variants.nim describes the method and
// drives it). The engine draws each countdown as `min + draw % (max - min + 1)`
// from its mt19937_64 (rules/0001.h's Seed and Draw): once per spawning tile
// at the start, in scan order over the tiles that own a shared countdown, then
// once at every spawn attempt, in the same order within a round.
//
//   loong-map-fit fit < INPUT       prints the fitted table, `x y low high` a line
//   loong-map-fit explain < INPUT   prints each table's explained and total spawns
//
// Input is little-endian binary on stdin (map_variants.nim writes it):
//   both:    u32 width, u32 height, u8 symmetry (0 xy, 1 x, 2 y)
//   fit:     u32 largest (0 for the default), u32 hidden_most,
//            i32 low[cells], i32 high[cells], u8 present[cells] (the published table),
//            u32 games, each: u64 seed, u32 rounds, rounds * ceil(cells / 8) bytes of
//            blocked tiles at each round's attempts, u32 spawns, spawns * (u32 round, u32 cell)
//   explain: u32 tables, each i32 low[cells], i32 high[cells]; then one game:
//            u64 seed, u32 spawns, spawns * (u32 round, u32 cell)

#include "../../engine/engine.h"

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <optional>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>

namespace {

constexpr int ROUNDS = loong::MAX_ROUNDS;

struct Reader
{
    std::vector<uint8_t> bytes;
    size_t at = 0;
    template <typename T> T Take()
    {
        T value{};
        if (at + sizeof(T) <= bytes.size()) std::memcpy(&value, bytes.data() + at, sizeof(T));
        at += sizeof(T);
        return value;
    }
    bool Ok() const { return at <= bytes.size(); }
};

std::vector<uint8_t> ReadAll(FILE* in)
{
    std::vector<uint8_t> data;
    uint8_t buffer[1 << 16];
    size_t n;
    while ((n = std::fread(buffer, 1, sizeof buffer, in)) > 0) data.insert(data.end(), buffer, buffer + n);
    return data;
}

struct Board
{
    int width = 0, height = 0, symmetry = 0;
    int Cells() const { return width * height; }
    int Mirror(int cell) const
    {
        int const x = cell % width, y = cell / width;
        if (symmetry == 1) return (height - 1 - y) * width + x;
        if (symmetry == 2) return y * width + (width - 1 - x);
        return (height - 1 - y) * width + (width - 1 - x);
    }
    int Owner(int cell) const
    {
        int const other = Mirror(cell);
        return other >= cell ? cell : other;
    }
};

// A gap table: each cell's (low, high), (0, 0) where it has none.
struct Gaps
{
    std::vector<int32_t> low, high;
    explicit Gaps(int cells = 0) : low(cells, 0), high(cells, 0) {}
};

// A game's generator outputs, made as they are first needed.
struct Draws
{
    loong::Rng rng;
    std::vector<uint64_t> made;
    explicit Draws(uint64_t seed) { loong::Seed(rng, seed); }
    uint64_t operator()(int k)
    {
        while (static_cast<int>(made.size()) <= k) made.push_back(loong::Draw(rng));
        return made[k];
    }
};

struct Attempt
{
    int round, tile;
};

// Every spawn attempt a table gives with a seed, in the engine's order. A
// countdown set to c before round 0 first reaches zero in round c - 1, and one
// reset to c in round r reaches it again in r + c.
std::vector<Attempt> AttemptList(Board const& board, Gaps const& gaps, Draws& draw)
{
    std::vector<std::vector<int>> due(ROUNDS);
    int k = 0;
    auto schedule = [&](int round, int tile) {
        if (round >= 0 && round < ROUNDS) due[round].push_back(tile);
    };
    for (int cell = 0; cell < board.Cells(); cell++)
    {
        if (board.Owner(cell) != cell || gaps.high[cell] <= 0) continue;
        int64_t const span = gaps.high[cell] - gaps.low[cell] + 1;
        schedule(gaps.low[cell] + static_cast<int>(draw(k) % static_cast<uint64_t>(span)) - 1, cell);
        k++;
    }
    std::vector<Attempt> found;
    for (int round = 0; round < ROUNDS; round++)
    {
        std::vector<int> tiles = std::move(due[round]);
        std::sort(tiles.begin(), tiles.end());
        for (int tile : tiles)
        {
            found.push_back({round, tile});
            int64_t const span = gaps.high[tile] - gaps.low[tile] + 1;
            schedule(round + gaps.low[tile] + static_cast<int>(draw(k) % static_cast<uint64_t>(span)), tile);
            k++;
        }
    }
    return found;
}

struct Game
{
    uint64_t seed;
    int rounds;                        // rounds with a board, 0 .. rounds - 1
    std::vector<uint8_t> blocked;      // rounds * cells: a pearl or a dragon at the round's attempts
    std::vector<uint8_t> spawned;      // rounds * cells: a spawn there that round
    std::vector<Attempt> spawns;       // sorted by round then cell
    Draws draw;
    explicit Game(uint64_t s) : seed(s), rounds(0), draw(s) {}
    bool Blocked(int round, int cell, int cells) const { return blocked[static_cast<size_t>(round) * cells + cell]; }
    bool Spawned(int round, int cell, int cells) const
    {
        return round >= 0 && round < rounds && spawned[static_cast<size_t>(round) * cells + cell];
    }
};

// The first round where a table disagrees with a game: an attempt on a free
// tile that shows no spawn, or a spawn on no attempt. ROUNDS if none.
int Contradiction(Board const& board, Gaps const& gaps, Game& game, std::vector<uint32_t>& tried, uint32_t& epoch)
{
    int const cells = board.Cells();
    epoch++;
    for (Attempt const& a : AttemptList(board, gaps, game.draw))
    {
        if (a.round >= game.rounds) break;  // the game ended before this round
        int const pair[2] = {a.tile, board.Mirror(a.tile)};
        for (int i = 0; i < (pair[1] == pair[0] ? 1 : 2); i++)
        {
            int const cell = pair[i];
            tried[static_cast<size_t>(a.round) * cells + cell] = epoch;
            if (!game.Blocked(a.round, cell, cells) != game.Spawned(a.round, cell, cells)) return a.round;
        }
    }
    for (Attempt const& s : game.spawns)
    {
        if (s.round < 0 || s.round >= ROUNDS || tried[static_cast<size_t>(s.round) * cells + s.tile] != epoch)
            return s.round;
    }
    return ROUNDS;
}

using Choice = std::pair<int, int>;  // (low, span)

struct Fit
{
    Board board;
    Gaps published;
    std::vector<uint8_t> present;
    std::vector<Game> games;
    int largest = 0, hiddenMost = 150;
    std::vector<uint32_t> tried;
    uint32_t epoch = 0;

    std::vector<int> seen;                                 // owner tiles any game shows spawn, scan order
    std::unordered_map<int, std::vector<int>> firstSpawn;  // tile -> each game's first spawn round there, or -1

    int First(int tile, int game) const
    {
        auto it = firstSpawn.find(tile);
        return it == firstSpawn.end() ? -1 : it->second[game];
    }

    bool StartsWell(int tile, int k, int low, int span, int g)
    {
        Game& game = games[g];
        int const attempt = low + static_cast<int>(game.draw(k) % static_cast<uint64_t>(span)) - 1;
        int const spawned = First(tile, g);
        if (spawned >= 0 && spawned < attempt) return false;
        if (attempt < 0 || attempt >= game.rounds) return true;  // after the game ended
        int const cells = board.Cells();
        int const pair[2] = {tile, board.Mirror(tile)};
        for (int i = 0; i < (pair[1] == pair[0] ? 1 : 2); i++)
        {
            if (!game.Blocked(attempt, pair[i], cells) && !game.Spawned(attempt, pair[i], cells)) return false;
        }
        return true;
    }

    bool StartsWellEverywhere(int tile, int k, int low, int span)
    {
        for (int g = 0; g < static_cast<int>(games.size()); g++)
            if (!StartsWell(tile, k, low, span, g)) return false;
        return true;
    }

    // The choices whose first attempts fit: for each span, the one or two
    // lows most of the games that show the tile spawn agree on (ties in game
    // order, as Counter.most_common gives them). With `any`, stops at the first.
    std::vector<Choice> Options(int tile, int k, bool any = false)
    {
        std::vector<int> data;
        for (int g = 0; g < static_cast<int>(games.size()); g++)
            if (First(tile, g) >= 0) data.push_back(g);
        std::vector<Choice> found;
        std::vector<std::pair<int, int>> lows;  // (value, count) in first-seen order
        for (int span = 1; span <= largest; span++)
        {
            lows.clear();
            for (int g : data)
            {
                int const low = First(tile, g) + 1 - static_cast<int>(games[g].draw(k) % static_cast<uint64_t>(span));
                auto it = std::find_if(lows.begin(), lows.end(), [&](auto const& p) { return p.first == low; });
                if (it == lows.end()) lows.push_back({low, 1});
                else it->second++;
            }
            // The two with the most games, earliest first among equals.
            int best[2] = {-1, -1};
            for (int i = 0; i < static_cast<int>(lows.size()); i++)
            {
                if (best[0] < 0 || lows[i].second > lows[best[0]].second) { best[1] = best[0]; best[0] = i; }
                else if (best[1] < 0 || lows[i].second > lows[best[1]].second) best[1] = i;
            }
            for (int b : best)
            {
                if (b < 0) continue;
                int const low = lows[b].first;
                if (low >= 1 && StartsWellEverywhere(tile, k, low, span))
                {
                    found.push_back({low, span});
                    if (any) return found;
                }
            }
        }
        return found;
    }

    // Every choice whose first attempts fit: in each game the first attempt is
    // the first spawn or a round before it when both cells were blocked, so one
    // game's possible first attempts give every low.
    std::vector<Choice> EveryOption(int tile, int k)
    {
        int const cells = board.Cells();
        int reference = -1;
        std::vector<int> referenceRounds;
        for (int g = 0; g < static_cast<int>(games.size()); g++)
        {
            int const spawned = First(tile, g);
            if (spawned < 0) continue;
            std::vector<int> rounds{spawned};
            for (int r = 0; r < spawned; r++)
            {
                if (r >= games[g].rounds) continue;
                bool all = true;
                int const pair[2] = {tile, board.Mirror(tile)};
                for (int i = 0; i < (pair[1] == pair[0] ? 1 : 2); i++)
                    all = all && games[g].Blocked(r, pair[i], cells);
                if (all) rounds.push_back(r);
            }
            if (reference < 0 || rounds.size() < referenceRounds.size())
            {
                reference = g;
                referenceRounds = rounds;
            }
        }
        std::vector<Choice> found;
        if (reference < 0) return found;
        for (int span = 1; span <= largest; span++)
        {
            int const u = static_cast<int>(games[reference].draw(k) % static_cast<uint64_t>(span));
            for (int a : referenceRounds)
            {
                int const low = a + 1 - u;
                if (low >= 1 && StartsWellEverywhere(tile, k, low, span)) found.push_back({low, span});
            }
        }
        return found;
    }

    std::vector<int> hidden;
    std::vector<int> choiceTiles;                          // seen, in order
    std::unordered_map<int, std::vector<Choice>> candidates;

    Gaps Table(std::unordered_map<int, Choice> const& choice) const
    {
        Gaps gaps(board.Cells());
        for (int tile : hidden)
        {
            for (int cell : {tile, board.Mirror(tile)})
            {
                gaps.low[cell] = ROUNDS + 1;
                gaps.high[cell] = ROUNDS + 1;
            }
        }
        for (int tile : choiceTiles)
        {
            Choice const c = choice.at(tile);
            for (int cell : {tile, board.Mirror(tile)})
            {
                gaps.low[cell] = c.first;
                gaps.high[cell] = c.first + c.second - 1;
            }
        }
        return gaps;
    }

    std::vector<int> AllRounds(Gaps const& gaps)
    {
        std::vector<int> rounds;
        for (Game& game : games) rounds.push_back(Contradiction(board, gaps, game, tried, epoch));
        return rounds;
    }

    // The fitted table, or none: as map_variants.nim's `fit` describes.
    std::optional<Gaps> Run()
    {
        int const cells = board.Cells();
        tried.assign(static_cast<size_t>(ROUNDS) * cells, 0);
        if (largest == 0)
        {
            int widest = 0;
            for (int c = 0; c < cells; c++)
                if (present[c]) widest = std::max(widest, published.high[c] - published.low[c] + 1);
            largest = std::max(2000, widest * 5 / 4);
        }
        std::vector<uint8_t> isSeen(cells, 0);
        for (int g = 0; g < static_cast<int>(games.size()); g++)
        {
            for (Attempt const& s : games[g].spawns)
            {
                int const owner = board.Owner(s.tile);
                auto& firsts = firstSpawn.try_emplace(owner, std::vector<int>(games.size(), -1)).first->second;
                if (firsts[g] < 0) firsts[g] = s.round;
                isSeen[owner] = 1;
            }
        }
        for (int c = 0; c < cells; c++)
            if (isSeen[c]) seen.push_back(c);

        // Walk the seen tiles in scan order, moving the draw index on past
        // hidden tiles whenever a well-observed tile fits only a later draw.
        int offset = 0;
        std::vector<int> offsets;
        for (int i = 0; i < static_cast<int>(seen.size()); i++)
        {
            int const tile = seen[i];
            int observed = 0;
            for (int g = 0; g < static_cast<int>(games.size()); g++) observed += First(tile, g) >= 0;
            if (observed >= 3 &&
                !(!Options(tile, i + offset, true).empty() && !Options(tile, i + offset + 1, true).empty()))
            {
                for (int jump = 0; jump < hiddenMost - offset; jump++)
                {
                    if (!Options(tile, i + offset + jump, true).empty())
                    {
                        offset += jump;
                        break;
                    }
                }
            }
            offsets.push_back(offset);
        }
        int previous = -1, before = 0;
        for (size_t i = 0; i < seen.size(); i++)
        {
            int const wanted = offsets[i] - before;
            if (wanted)
            {
                std::vector<int> spare, bare;
                for (int c = previous + 1; c < seen[i]; c++)
                {
                    if (board.Owner(c) != c || isSeen[c]) continue;
                    (published.high[c] == 0 ? bare : spare).push_back(c);
                }
                spare.insert(spare.end(), bare.begin(), bare.end());
                if (static_cast<int>(spare.size()) < wanted) return std::nullopt;
                hidden.insert(hidden.end(), spare.begin(), spare.begin() + wanted);
            }
            previous = seen[i];
            before = offsets[i];
        }
        std::vector<int> order = seen;
        order.insert(order.end(), hidden.begin(), hidden.end());
        std::sort(order.begin(), order.end());
        std::unordered_map<int, int> position;
        for (int k = 0; k < static_cast<int>(order.size()); k++) position[order[k]] = k;
        for (int tile : seen)
        {
            candidates[tile] = Options(tile, position[tile]);
            if (candidates[tile].empty()) return std::nullopt;
        }
        choiceTiles = seen;
        std::unordered_map<int, Choice> choice;
        for (int tile : seen)
        {
            Choice const published_choice{published.low[tile], published.high[tile] - published.low[tile] + 1};
            auto const& c = candidates[tile];
            choice[tile] = std::find(c.begin(), c.end(), published_choice) != c.end() ? published_choice : c[0];
        }
        std::vector<int> rounds = AllRounds(Table(choice));
        std::unordered_set<int> widened;
        auto sum = [](std::vector<int> const& v) { long s = 0; for (int x : v) s += x; return s; };
        auto least = [](std::vector<int> const& v) { return *std::min_element(v.begin(), v.end()); };
        while (least(rounds) < ROUNDS)
        {
            int const worst = static_cast<int>(std::min_element(rounds.begin(), rounds.end()) - rounds.begin());
            int const when = rounds[worst];
            // Suspects: the tiles that attempted before the disagreement, latest
            // first, then every seen tile.
            std::vector<int> suspects;
            std::unordered_set<int> listed;
            std::vector<int> recent;
            for (Attempt const& a : AttemptList(board, Table(choice), games[worst].draw))
                if (a.round <= when) recent.push_back(a.tile);
            auto add = [&](int t) {
                if (candidates.count(t) && listed.insert(t).second) suspects.push_back(t);
            };
            for (auto it = recent.rbegin(); it != recent.rend(); ++it) add(*it);
            for (int t : seen) add(t);

            using Best = std::optional<std::pair<std::unordered_map<int, Choice>, std::vector<int>>>;
            auto bestChange = [&](std::vector<int> const& tiles, bool whole) -> Best {
                Best best;
                for (int tile : tiles)
                {
                    for (Choice const& candidate : candidates[tile])
                    {
                        if (candidate == choice[tile]) continue;
                        auto trial = choice;
                        trial[tile] = candidate;
                        Gaps const gaps = Table(trial);
                        int const reached = Contradiction(board, gaps, games[worst], tried, epoch);
                        if (reached <= when || (whole && reached < ROUNDS)) continue;
                        std::vector<int> trialRounds = AllRounds(gaps);
                        if (sum(trialRounds) > sum(best ? best->second : rounds)) best = {{trial, trialRounds}};
                    }
                    if (best && least(best->second) == ROUNDS) break;
                }
                return best;
            };
            Best better = bestChange(suspects, true);
            for (int tile : suspects)
            {
                if (better) break;
                if (!widened.insert(tile).second) continue;
                std::vector<Choice> extra;
                for (Choice const& c : EveryOption(tile, position[tile]))
                    if (std::find(candidates[tile].begin(), candidates[tile].end(), c) == candidates[tile].end())
                        extra.push_back(c);
                if (!extra.empty())
                {
                    candidates[tile].insert(candidates[tile].end(), extra.begin(), extra.end());
                    better = bestChange({tile}, true);
                }
            }
            if (!better) better = bestChange(suspects, false);
            if (!better) break;
            choice = std::move(better->first);
            rounds = std::move(better->second);
        }
        if (least(rounds) < ROUNDS) return std::nullopt;
        return Table(choice);
    }
};

void ReadBoard(Reader& in, Board& board)
{
    board.width = static_cast<int>(in.Take<uint32_t>());
    board.height = static_cast<int>(in.Take<uint32_t>());
    board.symmetry = in.Take<uint8_t>();
}

Gaps ReadGaps(Reader& in, int cells)
{
    Gaps gaps(cells);
    for (int c = 0; c < cells; c++) gaps.low[c] = in.Take<int32_t>();
    for (int c = 0; c < cells; c++) gaps.high[c] = in.Take<int32_t>();
    return gaps;
}

std::vector<Attempt> ReadSpawns(Reader& in)
{
    uint32_t const count = in.Take<uint32_t>();
    std::vector<Attempt> spawns;
    for (uint32_t i = 0; i < count && in.Ok(); i++)
    {
        int const round = static_cast<int>(in.Take<uint32_t>());
        int const cell = static_cast<int>(in.Take<uint32_t>());
        spawns.push_back({round, cell});
    }
    std::sort(spawns.begin(), spawns.end(),
              [](Attempt const& a, Attempt const& b) { return a.round != b.round ? a.round < b.round : a.tile < b.tile; });
    return spawns;
}

int FitCommand(Reader& in)
{
    Fit fit;
    ReadBoard(in, fit.board);
    int const cells = fit.board.Cells();
    fit.largest = static_cast<int>(in.Take<uint32_t>());
    fit.hiddenMost = static_cast<int>(in.Take<uint32_t>());
    fit.published = ReadGaps(in, cells);
    fit.present.resize(cells);
    for (int c = 0; c < cells; c++) fit.present[c] = in.Take<uint8_t>();
    uint32_t const count = in.Take<uint32_t>();
    for (uint32_t g = 0; g < count && in.Ok(); g++)
    {
        Game game(in.Take<uint64_t>());
        game.rounds = std::min(static_cast<int>(in.Take<uint32_t>()), ROUNDS);
        size_t const row = (static_cast<size_t>(cells) + 7) / 8;
        game.blocked.assign(static_cast<size_t>(game.rounds) * cells, 0);
        for (int r = 0; r < game.rounds; r++)
            for (size_t b = 0; b < row; b++)
            {
                uint8_t const bits = in.Take<uint8_t>();
                for (int i = 0; i < 8; i++)
                {
                    size_t const cell = b * 8 + i;
                    if (cell < static_cast<size_t>(cells)) game.blocked[r * cells + cell] = (bits >> i) & 1;
                }
            }
        game.spawns = ReadSpawns(in);
        game.spawned.assign(static_cast<size_t>(game.rounds) * cells, 0);
        for (Attempt const& s : game.spawns)
            if (s.round >= 0 && s.round < game.rounds) game.spawned[static_cast<size_t>(s.round) * cells + s.tile] = 1;
        fit.games.push_back(std::move(game));
    }
    if (!in.Ok())
    {
        std::fprintf(stderr, "loong-map-fit: the input ended early\n");
        return 2;
    }
    std::optional<Gaps> const table = fit.Run();
    if (!table) return 0;
    for (int c = 0; c < cells; c++)
        if (table->high[c] != 0 || table->low[c] != 0)
            std::printf("%d %d %d %d\n", c % fit.board.width, c / fit.board.width, table->low[c], table->high[c]);
    return 0;
}

int ExplainCommand(Reader& in)
{
    Board board;
    ReadBoard(in, board);
    int const cells = board.Cells();
    uint32_t const tables = in.Take<uint32_t>();
    std::vector<Gaps> all;
    for (uint32_t t = 0; t < tables && in.Ok(); t++) all.push_back(ReadGaps(in, cells));
    uint64_t const seed = in.Take<uint64_t>();
    std::vector<Attempt> const spawns = ReadSpawns(in);
    if (!in.Ok())
    {
        std::fprintf(stderr, "loong-map-fit: the input ended early\n");
        return 2;
    }
    Draws draw(seed);
    for (Gaps const& gaps : all)
    {
        std::vector<uint8_t> tried(static_cast<size_t>(ROUNDS) * cells, 0);
        for (Attempt const& a : AttemptList(board, gaps, draw)) tried[static_cast<size_t>(a.round) * cells + a.tile] = 1;
        int explained = 0;
        for (Attempt const& s : spawns)
            explained += s.round >= 0 && s.round < ROUNDS && tried[static_cast<size_t>(s.round) * cells + board.Owner(s.tile)];
        std::printf("%d %zu\n", explained, spawns.size());
    }
    return 0;
}

}  // namespace

int main(int argc, char** argv)
{
    std::string const command = argc > 1 ? argv[1] : "";
    if (command != "fit" && command != "explain")
    {
        std::fprintf(stderr, "usage: loong-map-fit fit|explain < INPUT\n");
        return 2;
    }
    Reader in{ReadAll(stdin)};
    return command == "fit" ? FitCommand(in) : ExplainCommand(in);
}
