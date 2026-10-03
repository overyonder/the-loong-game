#pragma once

#include "engine.h"
#include <string>
#include <vector>

namespace loong
{

// Optional output of the one full protocol parser. The replay owner applies
// per-team retention limits; the parser only decides syntax and event order.
struct ReplyReplay
{
    void *context;
    int debug;
    int dragonId;
    void (*emit)(void *, ReplayEvent const &, char const *, size_t);
};

std::string LoadMap(Game &, std::string const &);
std::string RoundBlock(Game const &, int slot);
Action ReadReply(std::string const &, std::vector<uint8_t> &, ReplyReplay const * = nullptr);
std::string InitBlock(Game const &, int slot);

} // namespace loong
