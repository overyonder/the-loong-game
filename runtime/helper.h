#ifndef UNSWBC_HELPER_H
#define UNSWBC_HELPER_H

/* Controller protocol for a C bot. init() reads the spawn block, update()
   reads one turn into the controller, and the move helpers print a reply.
   end_turn() flushes it. Pointers into the controller are valid until the
   next update(). */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/* Limits the engine holds every game to. */
enum
{
    UNSWBC_MAX_ROUNDS = 500,
    UNSWBC_VISION_RADIUS = 3,
    UNSWBC_VISION_SIZE = 2 * UNSWBC_VISION_RADIUS + 1,
    UNSWBC_VISION_TILES = UNSWBC_VISION_SIZE * UNSWBC_VISION_SIZE,
    UNSWBC_INITIAL_LENGTH = 3,
    UNSWBC_MIN_SIZE = 2,
    UNSWBC_PROTOCOL_MAJOR = 3
};

/* The protocol's direction letters. */
typedef enum
{
    UNSWBC_NORTH = 'N',
    UNSWBC_EAST = 'E',
    UNSWBC_SOUTH = 'S',
    UNSWBC_WEST = 'W'
} UnswbcDirection;

/* The protocol's team letters. */
typedef enum
{
    UNSWBC_TEAM_A = 'A',
    UNSWBC_TEAM_B = 'B'
} UnswbcTeam;

/* What is standing on a tile. */
typedef enum
{
    UNSWBC_ENTITY_NONE = 0,
    UNSWBC_ENTITY_DRAGON,
    UNSWBC_ENTITY_PEARL
} UnswbcEntityType;

/* What lies on the edge between two tiles. */
typedef enum
{
    UNSWBC_EDGE_EMPTY = 0,
    UNSWBC_EDGE_KELP,
    UNSWBC_EDGE_PORTAL
} UnswbcEdgeType;

/* Board coordinates, with y growing south from 0 at the top. */
typedef struct
{
    int x;
    int y;
} UnswbcPosition;

/* A pearl, or one segment of a dragon, standing on a tile. */
typedef struct
{
    UnswbcPosition position;
    UnswbcEntityType type;
    int dragon_id; /* which dragon this segment belongs to */
    UnswbcTeam team;
    /* A head's facing is its heading. A body segment's points towards the
       head. */
    UnswbcDirection dir;
    bool is_head;
} UnswbcEntity;

/* One side of a tile, which a dragon crosses to leave it. */
typedef struct
{
    bool is_horizontal; /* the north and south sides */
    bool present;       /* false if this turn's window did not carry it */
    UnswbcEdgeType type;
    int portal_id; /* -1 unless this is a portal */
} UnswbcEdge;

/* One of the 49 tiles the dragon can see this turn. */
typedef struct
{
    UnswbcPosition position; /* already wrapped */
    int pearl_time;          /* rounds until a pearl tries to spawn; -1 if it never does */
    bool has_pearl;
    UnswbcEntity entity; /* UNSWBC_ENTITY_NONE when the tile is empty */
    UnswbcEdge edges[4]; /* north, east, south, west */
} UnswbcTile;

typedef struct
{
    int kelp;
    int ally;
    int ally_head;
    int enemy;
    int enemy_head;
} UnswbcSonarEchoes;

/* What the dragon knows about itself and what it can see this turn. */
typedef struct
{
    int length;     /* segments, head included */
    int unit_count; /* living dragons on this dragon's team */
    int unit_limit; /* per team */
    UnswbcEntity head;
    UnswbcTile tiles[UNSWBC_VISION_TILES]; /* the 7x7 window, row by row */
    int tile_count;
    uint64_t *sonar; /* owned by the controller; replaced each update */
    int sonar_count;
    int sonar_cap; /* room in the array, not a message count */
    UnswbcSonarEchoes sonar_echoes;
} UnswbcController;

/* The board, and the round being played. */
typedef struct
{
    int round_num;
    int width;
    int height;
    int unit_limit;
} UnswbcGame;

/* The four directions, in the order north, east, south, west. */
extern UnswbcDirection const UNSWBC_DIRECTIONS[4];

/* Reads the spawn block, and sets stdout to a full buffer so that a turn's
   output costs one write. */
void unswbc_init(UnswbcController **ct, UnswbcGame **game);
/* Reads the next turn into the controller. False once the game is over or the
   dragon has died. */
int unswbc_update(UnswbcController *ct, UnswbcGame *game);
/* Ends the turn and flushes, which is the one write a turn costs. */
void unswbc_end_turn(void);

/* The step a direction makes, as dx east and dy south. */
void unswbc_offset(UnswbcDirection direction, int *dx, int *dy);
UnswbcDirection unswbc_opposite(UnswbcDirection direction);
UnswbcDirection unswbc_left(UnswbcDirection direction);
UnswbcDirection unswbc_right(UnswbcDirection direction);
UnswbcTeam unswbc_enemy(UnswbcTeam team);
/* The tile one step away, wrapped around the map. */
UnswbcPosition unswbc_add(UnswbcPosition position, UnswbcDirection direction);
int unswbc_in_map(UnswbcGame const *game, UnswbcPosition position);
/* True if the position is inside the dragon's window this turn. */
int unswbc_in_vision(UnswbcController const *ct, UnswbcPosition position);

int unswbc_round(UnswbcGame const *game);
int unswbc_unit_limit(UnswbcGame const *game);
/* Where the dragon's head is. */
UnswbcPosition unswbc_position(UnswbcController const *ct);
/* Segments, head included. */
int unswbc_length(UnswbcController const *ct);
/* Living dragons on this dragon's team. */
int unswbc_unit_count(UnswbcController const *ct);
/* Unique within the game, and a split child gets the next one. */
int unswbc_id(UnswbcController const *ct);
UnswbcTeam unswbc_team(UnswbcController const *ct);
UnswbcDirection unswbc_facing(UnswbcController const *ct);

int unswbc_tile_count(UnswbcController const *ct);
/* Null if the index is outside the window. */
UnswbcTile const *unswbc_tile_at(UnswbcController const *ct, int index);
/* Null outside the 7x7 window. */
UnswbcTile const *unswbc_tile(UnswbcController const *ct, UnswbcPosition position);
/* Null if the tile is null, or if that side was not seen. */
UnswbcEdge const *unswbc_edge(UnswbcTile const *tile, UnswbcDirection direction);
/* False for kelp, and for a null edge. */
int unswbc_passable(UnswbcEdge const *edge);
/* True if crossing the edge teleports the dragon to the partner edge. */
int unswbc_is_portal(UnswbcEdge const *edge);
/* The id the partner edge shares, -1 when the edge is not a portal. */
int unswbc_portal_id(UnswbcEdge const *edge);
/* Null on an empty tile. */
UnswbcEntity const *unswbc_entity(UnswbcTile const *tile);
int unswbc_has_pearl(UnswbcTile const *tile);
/* This turn's sonar messages, in the order they were sent. */
uint64_t const *unswbc_sonar(UnswbcController const *ct, int *count);
UnswbcSonarEchoes unswbc_sonar_echoes(UnswbcController const *ct);

/* The last action printed in a turn is the one the engine applies. */
int unswbc_move(UnswbcDirection direction);
/* One tile per direction, all in this turn.
   The helper sends whatever you pass, and a sprint of n steps costs n-1
   segments, so the dragon must be longer than n. */
int unswbc_moves(UnswbcController const *ct, UnswbcDirection const *directions, int count);
/* True if child_size segments can be split off this turn. */
int unswbc_can_split(UnswbcController const *ct, int child_size);
/* Splits child_size segments off the tail as a new dragon.
   The child is those segments reversed, and takes its own turn later in the
   same round. */
int unswbc_split(UnswbcController const *ct, int child_size);
/* Attaches a message to this turn, which the replay shows.
   Each line costs points, see the Timeouts page. */
void unswbc_log(char const *message);
/* Draws a dot on the board in the replay. */
void unswbc_dot(UnswbcPosition position, int r, int g, int b);
/* Draws a line on the board in the replay. */
void unswbc_line(UnswbcPosition from, UnswbcPosition to, int r, int g, int b);
/* Labels the dragon for this turn in the replay. */
void unswbc_indicator(char const *message);
int unswbc_send_sonar_to(UnswbcDirection direction, uint64_t message);
int unswbc_send_sonar(uint64_t message);

#endif
