#include "helper.h"
#include "gizmos.h"

#include <ctype.h>
#include <errno.h>
#include <limits.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Diagnostics run only for our inspection harness (gizmos.h, unswbc_init). */
int loong_diagnostics_enabled = 0;

enum
{
    kMaxTokens = 16,
    kLineCap = 8192
};

static UnswbcGame* gGame = NULL;
static char gLine[kLineCap];

_Noreturn static void Die(char const* message)
{
    fprintf(stderr, "unswbc: %s\n", message);
    abort();
}

_Noreturn static void DieFmt(char const* fmt, ...)
{
    va_list args;
    fprintf(stderr, "unswbc: ");
    va_start(args, fmt);
    vfprintf(stderr, fmt, args);
    va_end(args);
    fputc('\n', stderr);
    abort();
}

static void Require(void const* value, char const* message)
{
    if (!value)
    {
        Die(message);
    }
}

typedef struct
{
    char* tokens[kMaxTokens];
    int count;
} Tokens;

static Tokens ReadTokens(void)
{
    for (;;)
    {
        if (!fgets(gLine, (int)sizeof gLine, stdin))
        {
            Die("unexpected end of controller input");
        }
        if (!strchr(gLine, '\n') && !feof(stdin))
        {
            Die("controller input line is too long");
        }

        char* hash = strchr(gLine, '#');
        if (hash)
        {
            *hash = '\0';
        }

        Tokens out = {0};
        char* cursor = gLine;
        while (*cursor)
        {
            while (isspace((unsigned char)*cursor))
            {
                cursor++;
            }
            if (!*cursor)
            {
                break;
            }
            if (out.count == kMaxTokens)
            {
                Die("too many fields on one line");
            }
            out.tokens[out.count++] = cursor;
            while (*cursor && !isspace((unsigned char)*cursor))
            {
                cursor++;
            }
            if (*cursor)
            {
                *cursor++ = '\0';
            }
        }
        if (out.count)
        {
            return out;
        }
    }
}

static Tokens CheckLabelled(Tokens line, char const* label, int value_count)
{
    if (strcmp(line.tokens[0], label) != 0)
    {
        DieFmt("expected %s, got %s", label, line.tokens[0]);
    }
    if (line.count != value_count + 1)
    {
        DieFmt("%s requires %d value(s)", label, value_count);
    }
    return line;
}

static Tokens ReadLabelled(char const* label, int value_count)
{
    return CheckLabelled(ReadTokens(), label, value_count);
}

static int ParseInt(char const* text)
{
    char* end = NULL;
    errno = 0;
    long value = strtol(text, &end, 10);
    if (errno || !end || end == text || *end || value < INT_MIN || value > INT_MAX)
    {
        DieFmt("invalid integer: %s", text);
    }
    return (int)value;
}

static uint64_t ParseU64(char const* text)
{
    if (!text || text[0] == '-')
    {
        DieFmt("invalid integer: %s", text ? text : "");
    }
    char* end = NULL;
    errno = 0;
    unsigned long long value = strtoull(text, &end, 10);
    if (errno || !end || end == text || *end || value > UINT64_MAX)
    {
        DieFmt("invalid integer: %s", text);
    }
    return (uint64_t)value;
}

static UnswbcDirection ParseDir(char const* text)
{
    if (!text || text[1] != '\0')
    {
        Die("invalid direction");
    }
    switch (text[0])
    {
    case UNSWBC_NORTH:
    case UNSWBC_EAST:
    case UNSWBC_SOUTH:
    case UNSWBC_WEST:
        return (UnswbcDirection)text[0];
    default:
        Die("invalid direction");
    }
}

static UnswbcTeam ParseTeam(char const* text)
{
    if (!text || text[1] != '\0')
    {
        Die("invalid team");
    }
    switch (text[0])
    {
    case UNSWBC_TEAM_A:
    case UNSWBC_TEAM_B:
        return (UnswbcTeam)text[0];
    default:
        Die("invalid team");
    }
}

static int DirIndex(UnswbcDirection direction)
{
    switch (direction)
    {
    case UNSWBC_NORTH:
        return 0;
    case UNSWBC_EAST:
        return 1;
    case UNSWBC_SOUTH:
        return 2;
    case UNSWBC_WEST:
        return 3;
    }
    Die("invalid direction");
}

static int Wrap(int value, int size)
{
    return (value % size + size) % size;
}

static UnswbcTile* FindTile(UnswbcTile* tiles, int count, UnswbcPosition position)
{
    for (int i = 0; i < count; i++)
    {
        if (tiles[i].position.x == position.x && tiles[i].position.y == position.y)
        {
            return &tiles[i];
        }
    }
    return NULL;
}

static UnswbcEdge ParseEdge(char const* value, bool horizontal)
{
    UnswbcEdge edge = {0};
    edge.is_horizontal = horizontal;
    edge.present = true;
    edge.portal_id = -1;
    if (strcmp(value, ".") == 0)
    {
        edge.type = UNSWBC_EDGE_EMPTY;
        return edge;
    }
    if (strcmp(value, "w") == 0)
    {
        edge.type = UNSWBC_EDGE_KELP;
        return edge;
    }
    int portal_id = ParseInt(value);
    if (portal_id < 0)
    {
        Die("portal IDs cannot be negative");
    }
    edge.type = UNSWBC_EDGE_PORTAL;
    edge.portal_id = portal_id;
    return edge;
}

static UnswbcTile* TileAtLocal(UnswbcTile* tiles, int count, UnswbcPosition head, UnswbcGame const* game, int local_x,
                               int local_y)
{
    UnswbcPosition position = {
        Wrap(head.x + local_x - UNSWBC_VISION_RADIUS, game->width),
        Wrap(head.y + local_y - UNSWBC_VISION_RADIUS, game->height),
    };
    UnswbcTile* tile = FindTile(tiles, count, position);
    if (!tile)
    {
        Die("vision is missing expected tile");
    }
    return tile;
}

void unswbc_init(UnswbcController** ct_out, UnswbcGame** game_out)
{
    /* The judge's stdout looks like a terminal, so it is line buffered unless
       we ask otherwise, and every line costs a write. One buffer, one write a
       turn, flushed by unswbc_end_turn. */
    setvbuf(stdout, NULL, _IOFBF, 1 << 16);
    Require(ct_out, "init output is null");
    Require(game_out, "init output is null");
    if (gGame)
    {
        Die("init called twice");
    }

    /* Our inspection harness sends LOONG_INSPECT before the init block to turn
       diagnostics on (gizmos.h); the official engine never sends it. */
    Tokens first = ReadTokens();
    if (first.count == 1 && strcmp(first.tokens[0], "LOONG_INSPECT") == 0)
    {
        loong_diagnostics_enabled = 1;
        first = ReadTokens();
    }
    Tokens id_line = CheckLabelled(first, "ID", 1);
    int dragon_id = ParseInt(id_line.tokens[1]);
    Tokens team_line = ReadLabelled("TEAM", 1);
    UnswbcTeam team = ParseTeam(team_line.tokens[1]);
    Tokens map_line = ReadLabelled("MAP", 2);
    int width = ParseInt(map_line.tokens[1]);
    int height = ParseInt(map_line.tokens[2]);
    if (width <= 0 || height <= 0)
    {
        Die("map dimensions must be positive");
    }
    Tokens unit_limit_line = ReadLabelled("UNIT_LIMIT", 1);
    int unit_limit = ParseInt(unit_limit_line.tokens[1]);
    if (unit_limit <= 0)
    {
        Die("UNIT_LIMIT must be positive");
    }

    UnswbcController* ct = calloc(1, sizeof *ct);
    UnswbcGame* game = calloc(1, sizeof *game);
    if (!ct || !game)
    {
        Die("out of memory");
    }

    ct->length = UNSWBC_INITIAL_LENGTH;
    ct->unit_count = 1;
    ct->unit_limit = unit_limit;
    ct->head.type = UNSWBC_ENTITY_DRAGON;
    ct->head.dragon_id = dragon_id;
    ct->head.team = team;
    ct->head.dir = UNSWBC_NORTH;
    ct->head.is_head = true;
    game->round_num = 1;
    game->width = width;
    game->height = height;
    game->unit_limit = unit_limit;
    gGame = game;
    *ct_out = ct;
    *game_out = game;
}

int unswbc_update(UnswbcController* ct, UnswbcGame* game)
{
    Require(ct, "update controller is null");
    Require(game, "update game is null");

    /* Reading stdin does not flush stdout in C, so a bot that skipped
       unswbc_end_turn would otherwise block with its reply still buffered. */
    fflush(stdout);

    Tokens first = ReadTokens();
    if (strcmp(first.tokens[0], "ENDGAME") == 0)
    {
        return 0;
    }
    if (strcmp(first.tokens[0], "ROUND") != 0 || first.count != 2)
    {
        DieFmt("expected ROUND, got %s", first.tokens[0]);
    }
    game->round_num = ParseInt(first.tokens[1]);

    Tokens dir_line = ReadLabelled("DIR", 1);
    UnswbcDirection facing = ParseDir(dir_line.tokens[1]);
    ct->head.dir = facing;

    Tokens length_line = ReadLabelled("LENGTH", 1);
    ct->length = ParseInt(length_line.tokens[1]);

    Tokens unit_count_line = ReadLabelled("UNIT_COUNT", 1);
    ct->unit_count = ParseInt(unit_count_line.tokens[1]);
    if (ct->unit_count <= 0 || ct->unit_count > ct->unit_limit)
    {
        Die("UNIT_COUNT must be between 1 and UNIT_LIMIT");
    }

    Tokens msgs_line = ReadLabelled("NUM_MSGS", 1);
    int num_msgs = ParseInt(msgs_line.tokens[1]);
    if (num_msgs < 0)
    {
        Die("NUM_MSGS cannot be negative");
    }
    if (num_msgs > ct->sonar_cap)
    {
        uint64_t* grown = realloc(ct->sonar, (size_t)num_msgs * sizeof *grown);
        if (!grown)
        {
            Die("out of memory");
        }
        ct->sonar = grown;
        ct->sonar_cap = num_msgs;
    }
    ct->sonar_count = num_msgs;
    for (int i = 0; i < num_msgs; i++)
    {
        Tokens message = ReadTokens();
        if (message.count != 1)
        {
            Die("missing sonar message value");
        }
        ct->sonar[i] = ParseU64(message.tokens[0]);
    }

    Tokens first_tile_values = ReadTokens();
    ct->sonar_echoes = (UnswbcSonarEchoes){0};
    if (strcmp(first_tile_values.tokens[0], "ECHOES") == 0)
    {
        if (first_tile_values.count != 6)
        {
            Die("ECHOES requires 5 values");
        }
        ct->sonar_echoes = (UnswbcSonarEchoes){
            ParseInt(first_tile_values.tokens[1]), ParseInt(first_tile_values.tokens[2]),
            ParseInt(first_tile_values.tokens[3]), ParseInt(first_tile_values.tokens[4]),
            ParseInt(first_tile_values.tokens[5]),
        };
        first_tile_values = ReadTokens();
    }

    UnswbcTile tiles[UNSWBC_VISION_TILES] = {0};
    for (int i = 0; i < UNSWBC_VISION_TILES; i++)
    {
        Tokens values = i == 0 ? first_tile_values : ReadTokens();
        if (values.count != 4)
        {
            Die("each vision tile requires: x y hasPearl pearlIn");
        }
        int x = ParseInt(values.tokens[0]);
        int y = ParseInt(values.tokens[1]);
        int has_pearl = ParseInt(values.tokens[2]);
        int pearl_time = ParseInt(values.tokens[3]);
        if (has_pearl != 0 && has_pearl != 1)
        {
            Die("hasPearl must be 0 or 1");
        }
        UnswbcPosition position = {x, y};
        if (FindTile(tiles, i, position))
        {
            Die("duplicate vision tile");
        }
        tiles[i].position = position;
        tiles[i].pearl_time = pearl_time;
        tiles[i].has_pearl = has_pearl != 0;
        if (has_pearl)
        {
            tiles[i].entity.type = UNSWBC_ENTITY_PEARL;
            tiles[i].entity.position = position;
        }
    }

    Tokens bodies_line = ReadLabelled("DRAGON_BODIES", 1);
    int num_parts = ParseInt(bodies_line.tokens[1]);
    if (num_parts < 0)
    {
        Die("DRAGON_BODIES cannot be negative");
    }

    int found_head = 0;
    for (int i = 0; i < num_parts; i++)
    {
        Tokens values = ReadTokens();
        if (values.count != 6)
        {
            Die("each dragon part requires: team dragonId x y facing isHead");
        }
        UnswbcTeam team = ParseTeam(values.tokens[0]);
        int dragon_id = ParseInt(values.tokens[1]);
        UnswbcPosition position = {ParseInt(values.tokens[2]), ParseInt(values.tokens[3])};
        UnswbcDirection part_dir = ParseDir(values.tokens[4]);
        int head_flag = ParseInt(values.tokens[5]);
        if (head_flag != 0 && head_flag != 1)
        {
            Die("isHead must be 0 or 1");
        }

        UnswbcTile* tile = FindTile(tiles, UNSWBC_VISION_TILES, position);
        if (!tile)
        {
            Die("dragon part is outside the vision tiles");
        }

        UnswbcEntity* entity = &tile->entity;
        entity->type = UNSWBC_ENTITY_DRAGON;
        entity->position = position;
        entity->dragon_id = dragon_id;
        entity->team = team;
        entity->is_head = head_flag == 1;
        if (dragon_id == ct->head.dragon_id && head_flag == 1)
        {
            ct->head.position = position;
            ct->head.team = team;
            ct->head.dir = facing;
            ct->head.is_head = true;
            entity->dir = facing;
            found_head = 1;
        }
        else
        {
            entity->dir = part_dir;
        }
    }
    if (!found_head)
    {
        Die("controller head is missing from DRAGON_BODIES");
    }

    UnswbcPosition head = ct->head.position;
    for (int y = 0; y < UNSWBC_VISION_SIZE + 1; y++)
    {
        Tokens row = ReadTokens();
        if (row.count != UNSWBC_VISION_SIZE)
        {
            Die("horizontal edge row requires 7 values");
        }
        for (int x = 0; x < UNSWBC_VISION_SIZE; x++)
        {
            UnswbcEdge edge = ParseEdge(row.tokens[x], true);
            if (y > 0)
            {
                TileAtLocal(tiles, UNSWBC_VISION_TILES, head, game, x, y - 1)->edges[DirIndex(UNSWBC_SOUTH)] = edge;
            }
            if (y < UNSWBC_VISION_SIZE)
            {
                TileAtLocal(tiles, UNSWBC_VISION_TILES, head, game, x, y)->edges[DirIndex(UNSWBC_NORTH)] = edge;
            }
        }
    }

    for (int y = 0; y < UNSWBC_VISION_SIZE; y++)
    {
        Tokens row = ReadTokens();
        if (row.count != UNSWBC_VISION_SIZE + 1)
        {
            Die("vertical edge row requires 8 values");
        }
        for (int x = 0; x < UNSWBC_VISION_SIZE + 1; x++)
        {
            UnswbcEdge edge = ParseEdge(row.tokens[x], false);
            if (x > 0)
            {
                TileAtLocal(tiles, UNSWBC_VISION_TILES, head, game, x - 1, y)->edges[DirIndex(UNSWBC_EAST)] = edge;
            }
            if (x < UNSWBC_VISION_SIZE)
            {
                TileAtLocal(tiles, UNSWBC_VISION_TILES, head, game, x, y)->edges[DirIndex(UNSWBC_WEST)] = edge;
            }
        }
    }

    memcpy(ct->tiles, tiles, sizeof tiles);
    ct->tile_count = UNSWBC_VISION_TILES;
    return 1;
}

void unswbc_end_turn(void)
{
#ifdef LOONG_PROTOCOL_EVERY_TURN
    bool protocol_requested = false;
#else
    static bool protocol_requested = false;
#endif
    if (!protocol_requested)
    {
        printf("PROTOCOL %d\n", UNSWBC_PROTOCOL_MAJOR);
        protocol_requested = true;
    }
    fputs("ENDTURN\n", stdout);
    fflush(stdout);
}

UnswbcDirection const UNSWBC_DIRECTIONS[4] = {
    UNSWBC_NORTH,
    UNSWBC_EAST,
    UNSWBC_SOUTH,
    UNSWBC_WEST,
};

void unswbc_offset(UnswbcDirection direction, int* dx, int* dy)
{
    Require(dx, "offset output is null");
    Require(dy, "offset output is null");
    switch (direction)
    {
    case UNSWBC_NORTH:
        *dx = 0;
        *dy = -1;
        return;
    case UNSWBC_EAST:
        *dx = 1;
        *dy = 0;
        return;
    case UNSWBC_SOUTH:
        *dx = 0;
        *dy = 1;
        return;
    case UNSWBC_WEST:
        *dx = -1;
        *dy = 0;
        return;
    }
    Die("invalid direction");
}

UnswbcDirection unswbc_opposite(UnswbcDirection direction)
{
    switch (direction)
    {
    case UNSWBC_NORTH:
        return UNSWBC_SOUTH;
    case UNSWBC_EAST:
        return UNSWBC_WEST;
    case UNSWBC_SOUTH:
        return UNSWBC_NORTH;
    case UNSWBC_WEST:
        return UNSWBC_EAST;
    }
    Die("invalid direction");
}

UnswbcDirection unswbc_left(UnswbcDirection direction)
{
    switch (direction)
    {
    case UNSWBC_NORTH:
        return UNSWBC_WEST;
    case UNSWBC_EAST:
        return UNSWBC_NORTH;
    case UNSWBC_SOUTH:
        return UNSWBC_EAST;
    case UNSWBC_WEST:
        return UNSWBC_SOUTH;
    }
    Die("invalid direction");
}

UnswbcDirection unswbc_right(UnswbcDirection direction)
{
    switch (direction)
    {
    case UNSWBC_NORTH:
        return UNSWBC_EAST;
    case UNSWBC_EAST:
        return UNSWBC_SOUTH;
    case UNSWBC_SOUTH:
        return UNSWBC_WEST;
    case UNSWBC_WEST:
        return UNSWBC_NORTH;
    }
    Die("invalid direction");
}

UnswbcTeam unswbc_enemy(UnswbcTeam team)
{
    return team == UNSWBC_TEAM_B ? UNSWBC_TEAM_A : UNSWBC_TEAM_B;
}

UnswbcPosition unswbc_add(UnswbcPosition position, UnswbcDirection direction)
{
    if (!gGame)
    {
        Die("game is not initialised");
    }
    int dx = 0;
    int dy = 0;
    unswbc_offset(direction, &dx, &dy);
    UnswbcPosition next = {
        Wrap(position.x + dx, gGame->width),
        Wrap(position.y + dy, gGame->height),
    };
    return next;
}

int unswbc_in_map(UnswbcGame const* game, UnswbcPosition position)
{
    Require(game, "game is null");
    return position.x >= 0 && position.y >= 0 && position.x < game->width && position.y < game->height;
}

int unswbc_in_vision(UnswbcController const* ct, UnswbcPosition position)
{
    Require(ct, "controller is null");
    if (!gGame)
    {
        Die("game is not initialised");
    }
    if (!unswbc_in_map(gGame, position))
    {
        return 0;
    }
    int const column = Wrap(position.x - (ct->head.position.x - UNSWBC_VISION_RADIUS), gGame->width);
    int const row = Wrap(position.y - (ct->head.position.y - UNSWBC_VISION_RADIUS), gGame->height);
    return column < UNSWBC_VISION_SIZE && row < UNSWBC_VISION_SIZE;
}

int unswbc_round(UnswbcGame const* game)
{
    Require(game, "game is null");
    return game->round_num;
}

int unswbc_unit_limit(UnswbcGame const* game)
{
    Require(game, "game is null");
    return game->unit_limit;
}

UnswbcPosition unswbc_position(UnswbcController const* ct)
{
    Require(ct, "controller is null");
    return ct->head.position;
}

int unswbc_length(UnswbcController const* ct)
{
    Require(ct, "controller is null");
    return ct->length;
}

int unswbc_unit_count(UnswbcController const* ct)
{
    Require(ct, "controller is null");
    return ct->unit_count;
}

int unswbc_id(UnswbcController const* ct)
{
    Require(ct, "controller is null");
    return ct->head.dragon_id;
}

UnswbcTeam unswbc_team(UnswbcController const* ct)
{
    Require(ct, "controller is null");
    return ct->head.team;
}

UnswbcDirection unswbc_facing(UnswbcController const* ct)
{
    Require(ct, "controller is null");
    return ct->head.dir;
}

int unswbc_tile_count(UnswbcController const* ct)
{
    Require(ct, "controller is null");
    return ct->tile_count;
}

UnswbcTile const* unswbc_tile_at(UnswbcController const* ct, int index)
{
    Require(ct, "controller is null");
    if (index < 0 || index >= ct->tile_count)
    {
        return NULL;
    }
    return &ct->tiles[index];
}

UnswbcTile const* unswbc_tile(UnswbcController const* ct, UnswbcPosition position)
{
    Require(ct, "controller is null");
    return FindTile((UnswbcTile*)ct->tiles, ct->tile_count, position);
}

UnswbcEdge const* unswbc_edge(UnswbcTile const* tile, UnswbcDirection direction)
{
    if (!tile)
    {
        return NULL;
    }
    UnswbcEdge const* edge = &tile->edges[DirIndex(direction)];
    return edge->present ? edge : NULL;
}

int unswbc_passable(UnswbcEdge const* edge)
{
    return edge && edge->type != UNSWBC_EDGE_KELP;
}

int unswbc_is_portal(UnswbcEdge const* edge)
{
    return edge && edge->type == UNSWBC_EDGE_PORTAL;
}

int unswbc_portal_id(UnswbcEdge const* edge)
{
    return unswbc_is_portal(edge) ? edge->portal_id : -1;
}

UnswbcEntity const* unswbc_entity(UnswbcTile const* tile)
{
    if (!tile || tile->entity.type == UNSWBC_ENTITY_NONE)
    {
        return NULL;
    }
    return &tile->entity;
}

int unswbc_has_pearl(UnswbcTile const* tile)
{
    return tile && tile->has_pearl;
}

uint64_t const* unswbc_sonar(UnswbcController const* ct, int* count)
{
    Require(ct, "controller is null");
    if (count)
    {
        *count = ct->sonar_count;
    }
    return ct->sonar;
}

UnswbcSonarEchoes unswbc_sonar_echoes(UnswbcController const* ct)
{
    Require(ct, "controller is null");
    return ct->sonar_echoes;
}

int unswbc_move(UnswbcDirection direction)
{
    ParseDir((char[]){(char)direction, '\0'});
    printf("MOVE %c\n", (char)direction);
    return 1;
}

int unswbc_moves(UnswbcController const* ct, UnswbcDirection const* directions, int count)
{
    Require(ct, "controller is null");
    Require(directions, "directions are null");
    fputs("MOVE ", stdout);
    for (int i = 0; i < count; i++)
    {
        ParseDir((char[]){(char)directions[i], '\0'});
        putchar((char)directions[i]);
    }
    putchar('\n');
    return 1;
}

int unswbc_can_split(UnswbcController const* ct, int child_size)
{
    Require(ct, "controller is null");
    return UNSWBC_MIN_SIZE <= child_size && ct->length - child_size >= UNSWBC_MIN_SIZE && ct->unit_count < ct->unit_limit;
}

int unswbc_split(UnswbcController const* ct, int child_size)
{
    Require(ct, "controller is null");
    printf("SPLIT %d\n", child_size);
    return 1;
}

void unswbc_log(char const* message)
{
    Require(message, "log message is null");
    printf("LOG %s\n", message);
}

void unswbc_dot(UnswbcPosition position, int r, int g, int b)
{
    printf("DOT %d %d %d %d %d\n", position.x, position.y, r, g, b);
}

void unswbc_line(UnswbcPosition from, UnswbcPosition to, int r, int g, int b)
{
    printf("LINE %d %d %d %d %d %d %d\n", from.x, from.y, to.x, to.y, r, g, b);
}

void unswbc_indicator(char const* message)
{
    Require(message, "indicator message is null");
    printf("INDICATOR %s\n", message);
}

int unswbc_send_sonar_to(UnswbcDirection direction, uint64_t message)
{
    ParseDir((char[]){(char)direction, '\0'});
    printf("SONAR %c %llu\n", (char)direction, (unsigned long long)message);
    return 1;
}

int unswbc_send_sonar(uint64_t message)
{
    if (message > UINT32_MAX)
    {
        return 0;
    }
    printf("SONAR %llu\n", (unsigned long long)message);
    return 1;
}
