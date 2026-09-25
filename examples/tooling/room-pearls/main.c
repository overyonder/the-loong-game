#include "helper.h"

#include <stdbool.h>

/* The 7x7 window as a small grid: which tiles hold a dragon, and which
   sides of each tile a dragon can cross. Index 24 is our head. */
typedef struct
{
    bool tile_is_occupied[UNSWBC_VISION_TILES];
    bool side_is_open[UNSWBC_VISION_TILES][4];
    bool tile_has_pearl[UNSWBC_VISION_TILES];
} LocalWindow;

enum { HEAD_INDEX = UNSWBC_VISION_TILES / 2 };

static int const STEP_COLUMN[4] = { 0, 1, 0, -1 };
static int const STEP_ROW[4]    = { -1, 0, 1, 0 };

static void ReadLocalWindowFromController(UnswbcController const* ct, UnswbcGame const* game, LocalWindow* window)
{
    UnswbcPosition const head = unswbc_position(ct);
    for (int index = 0; index < UNSWBC_VISION_TILES; index++)
    {
        UnswbcTile const*    tile     = unswbc_tile_at(ct, index);
        UnswbcPosition const position = { head.x + index % UNSWBC_VISION_SIZE - UNSWBC_VISION_RADIUS,
                                          head.y + index / UNSWBC_VISION_SIZE - UNSWBC_VISION_RADIUS };
        bool const           off_map  = position.x < 0 || position.x >= game->width || position.y < 0 || position.y >= game->height;
        window->tile_is_occupied[index] = off_map || (unswbc_entity(tile) != NULL && unswbc_entity(tile)->type == UNSWBC_ENTITY_DRAGON);
        window->tile_has_pearl[index] = unswbc_has_pearl(tile);
        for (int side = 0; side < 4; side++)
        {
            window->side_is_open[index][side] = unswbc_passable(unswbc_edge(tile, UNSWBC_DIRECTIONS[side]));
        }
    }
}

/* The neighbouring window index across one side, or -1 off the window. */
static int StepWithinWindow(LocalWindow const* window, int index, int side)
{
    int const column = index % UNSWBC_VISION_SIZE + STEP_COLUMN[side];
    int const row    = index / UNSWBC_VISION_SIZE + STEP_ROW[side];
    if (column < 0 || column >= UNSWBC_VISION_SIZE || row < 0 || row >= UNSWBC_VISION_SIZE)
    {
        return -1;
    }
    int const next = row * UNSWBC_VISION_SIZE + column;
    return window->side_is_open[index][side] && !window->tile_is_occupied[next] ? next : -1;
}

/* Tiles reachable from start without crossing the two cells of our path. */
static int CountReachableTiles(LocalWindow const* window, int start, int first_step)
{
    bool visited[UNSWBC_VISION_TILES] = { false };
    int  queue[UNSWBC_VISION_TILES];
    int  queue_length = 0;
    visited[HEAD_INDEX] = visited[first_step] = visited[start] = true;
    queue[queue_length++] = start;
    for (int cursor = 0; cursor < queue_length; cursor++)
    {
        for (int side = 0; side < 4; side++)
        {
            int const next = StepWithinWindow(window, queue[cursor], side);
            if (next >= 0 && !visited[next])
            {
                visited[next]         = true;
                queue[queue_length++] = next;
            }
        }
    }
    return queue_length;
}

/* Steps from start to the nearest visible pearl, or the window size if none is reachable. */
static int StepsToNearestPearl(LocalWindow const* window, int start)
{
    bool visited[UNSWBC_VISION_TILES] = { false };
    int  queue[UNSWBC_VISION_TILES];
    int  distance[UNSWBC_VISION_TILES];
    int  queue_length = 0;
    visited[HEAD_INDEX] = visited[start] = true;
    queue[queue_length]      = start;
    distance[queue_length++] = 0;
    for (int cursor = 0; cursor < queue_length; cursor++)
    {
        if (window->tile_has_pearl[queue[cursor]])
        {
            return distance[cursor];
        }
        for (int side = 0; side < 4; side++)
        {
            int const next = StepWithinWindow(window, queue[cursor], side);
            if (next >= 0 && !visited[next])
            {
                visited[next]            = true;
                queue[queue_length]      = next;
                distance[queue_length++] = distance[cursor] + 1;
            }
        }
    }
    return UNSWBC_VISION_TILES;
}

/* Score each first move by the most room any second move leaves us. */
static UnswbcDirection ChooseMoveWithMostRoomTwoStepsAhead(LocalWindow const* window, UnswbcDirection fallback)
{
    UnswbcDirection best_direction = fallback;
    int             best_score      = -1;
    for (int first_side = 0; first_side < 4; first_side++)
    {
        int const first_step = StepWithinWindow(window, HEAD_INDEX, first_side);
        if (first_step < 0)
        {
            continue;
        }
        int room = 0;
        for (int second_side = 0; second_side < 4; second_side++)
        {
            int const second_step = StepWithinWindow(window, first_step, second_side);
            if (second_step >= 0 && second_step != HEAD_INDEX)
            {
                int const reachable = CountReachableTiles(window, second_step, first_step);
                room                = reachable > room ? reachable : room;
            }
        }
        /* Room matters most. Among moves with room to spare, head for the nearest pearl. */
        int const score = (room < 8 ? room * 100 : 800) - StepsToNearestPearl(window, first_step);
        if (score > best_score)
        {
            best_score      = score;
            best_direction = UNSWBC_DIRECTIONS[first_side];
        }
    }
    return best_direction;
}

int main(void)
{
    UnswbcController* ct   = NULL;
    UnswbcGame*       game = NULL;
    unswbc_init(&ct, &game);
    while (unswbc_update(ct, game))
    {
        LocalWindow window;
        ReadLocalWindowFromController(ct, game, &window);
        unswbc_move(ChooseMoveWithMostRoomTwoStepsAhead(&window, unswbc_facing(ct)));
        unswbc_end_turn();
    }
    return 0;
}
