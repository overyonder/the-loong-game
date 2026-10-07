#include "helper.h"

#include <stdlib.h>

static void take_random_action(UnswbcController const *controller) {
  UnswbcPosition const head_position = unswbc_position(controller);
  UnswbcTile const *head_tile = unswbc_tile(controller, head_position);
  UnswbcDirection safe_moves[4];
  UnswbcDirection portal_moves[4];
  int safe_move_count = 0;
  int portal_move_count = 0;

  for (int direction_index = 0; direction_index < 4; ++direction_index) {
    UnswbcDirection const direction = UNSWBC_DIRECTIONS[direction_index];
    UnswbcEdge const *edge = unswbc_edge(head_tile, direction);
    if (!unswbc_passable(edge)) {
      continue;
    }
    /* The adjacent tile is not a portal's destination. Risk portals only
       when no known-safe action is available. */
    if (unswbc_is_portal(edge)) {
      portal_moves[portal_move_count++] = direction;
      continue;
    }
    UnswbcTile const *destination =
        unswbc_tile(controller, unswbc_add(head_position, direction));
    UnswbcEntity const *occupant = unswbc_entity(destination);
    if (destination && (!occupant || occupant->type != UNSWBC_ENTITY_DRAGON)) {
      safe_moves[safe_move_count++] = direction;
    }
  }

  int const can_split = unswbc_can_split(controller, UNSWBC_MIN_SIZE);
  int const action_count = safe_move_count + can_split;
  if (action_count > 0) {
    int const action_index = rand() % action_count;
    if (action_index < safe_move_count) {
      unswbc_move(safe_moves[action_index]);
    } else {
      unswbc_split(controller, UNSWBC_MIN_SIZE);
    }
  } else if (portal_move_count > 0) {
    unswbc_move(portal_moves[rand() % portal_move_count]);
  } else {
    /* A trapped dragon must still submit an action; there is no wait. */
    unswbc_move(UNSWBC_DIRECTIONS[rand() % 4]);
  }
}

int main(void) {
  UnswbcController *controller = NULL;
  UnswbcGame *game = NULL;
  unswbc_init(&controller, &game);
  /* Reproducible, with a different random sequence for each dragon. */
  srand((unsigned int)unswbc_id(controller));

  while (unswbc_update(controller, game)) {
    take_random_action(controller);
    unswbc_end_turn();
  }
  return 0;
}
