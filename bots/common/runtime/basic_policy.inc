#include "helper.h"

#include <limits.h>
#include <stdlib.h>

/* Four deliberately small baselines share collision/visibility handling. */
static UnswbcTile const *clear_destination(UnswbcController const *controller,
                                           UnswbcTile const *tile,
                                           UnswbcDirection direction) {
  UnswbcEdge const *edge = unswbc_edge(tile, direction);
  if (!unswbc_passable(edge) || unswbc_is_portal(edge))
    return NULL;
  UnswbcTile const *destination =
      unswbc_tile(controller, unswbc_add(tile->position, direction));
  if (!destination || destination->entity.type == UNSWBC_ENTITY_DRAGON)
    return NULL;
  return destination;
}

static int visible_space(UnswbcController const *controller,
                         UnswbcTile const *start) {
  UnswbcTile const *queue[UNSWBC_VISION_TILES];
  bool visited[UNSWBC_VISION_TILES] = {false};
  int count = 1;
  queue[0] = start;
  visited[start - controller->tiles] = true;
  for (int cursor = 0; cursor < count; ++cursor) {
    for (int direction = 0; direction < 4; ++direction) {
      UnswbcTile const *destination = clear_destination(
          controller, queue[cursor], UNSWBC_DIRECTIONS[direction]);
      if (destination && !visited[destination - controller->tiles]) {
        visited[destination - controller->tiles] = true;
        queue[count++] = destination;
      }
    }
  }
  return count;
}

static int food_distance(UnswbcController const *controller,
                         UnswbcGame const *game, UnswbcPosition position) {
  int nearest = game->width + game->height;
  for (int index = 0; index < controller->tile_count; ++index) {
    UnswbcTile const *tile = &controller->tiles[index];
    if (!tile->has_pearl)
      continue;
    int dx = abs(position.x - tile->position.x);
    int dy = abs(position.y - tile->position.y);
    dx = dx < game->width - dx ? dx : game->width - dx;
    dy = dy < game->height - dy ? dy : game->height - dy;
    if (dx + dy < nearest)
      nearest = dx + dy;
  }
  return nearest;
}

static UnswbcDirection choose_move(UnswbcController const *controller,
                                   UnswbcGame const *game) {
  if (BASIC_POLICY == 0)
    return UNSWBC_NORTH;
  UnswbcTile const *head = unswbc_tile(controller, unswbc_position(controller));
  UnswbcDirection choices[4];
  int count = 0;
  int best = INT_MIN;
  for (int index = 0; index < 4; ++index) {
    UnswbcDirection direction = UNSWBC_DIRECTIONS[index];
    UnswbcTile const *destination =
        clear_destination(controller, head, direction);
    if (!destination)
      continue;
    int score = 0;
    if (BASIC_POLICY == 2)
      score = 100 * (int)destination->has_pearl -
              food_distance(controller, game, destination->position);
    if (BASIC_POLICY == 3)
      score = 10 * visible_space(controller, destination) +
              4 * (int)destination->has_pearl;
    if (score > best) {
      best = score;
      count = 0;
    }
    if (score == best)
      choices[count++] = direction;
  }
  if (count)
    return choices[rand() % count];
  for (int index = 0; index < 4; ++index)
    if (unswbc_is_portal(unswbc_edge(head, UNSWBC_DIRECTIONS[index])))
      return UNSWBC_DIRECTIONS[index];
  return unswbc_facing(controller);
}

int main(void) {
  UnswbcController *controller = NULL;
  UnswbcGame *game = NULL;
  unswbc_init(&controller, &game);
  srand((unsigned int)unswbc_id(controller));
  while (unswbc_update(controller, game)) {
    unswbc_move(choose_move(controller, game));
    unswbc_end_turn();
  }
  return 0;
}
