/* Public contract example: always move north. Its diagnostic path and target
 * describe that literal decision, including when it is a bad one. */
#include "gizmos.h"
#include "helper.h"
#include <stdio.h>

#define LOONG_BEHAVIOURS(X) X(NORTH)
#define TRACE(name) ((void)0)

int main(void) {
  UnswbcController *controller;
  UnswbcGame *game;
  unswbc_init(&controller, &game);
  while (unswbc_update(controller, game)) {
    TRACE(NORTH);
    unswbc_move(UNSWBC_NORTH);
    LOONG_DIAGNOSTIC_BLOCK(
        const int head = controller->head.position.y * game->width +
                         controller->head.position.x;
        const int target = (head + game->width * (game->height - 1)) %
                           (game->width * game->height);
        char record[1024];
        snprintf(record, sizeof record,
                 "{\"version\":1,\"kind\":\"line\",\"label\":\"Chosen step\","
                 "\"points\":[%d,%d]}",
                 head, target);
        LOONG_GIZMO_JSON(record);
        snprintf(record, sizeof record,
                 "{\"version\":1,\"kind\":\"target\",\"label\":\"North\","
                 "\"points\":[%d]}",
                 target);
        LOONG_GIZMO_JSON(record);
        snprintf(record, sizeof record,
                 "{\"version\":1,\"kind\":\"path\",\"label\":\"One-step plan\","
                 "\"points\":[%d,%d]}",
                 head, target);
        LOONG_GIZMO_JSON(record); snprintf(
            record, sizeof record,
            "{\"version\":1,\"kind\":\"search\",\"label\":\"Considered cell\","
            "\"objective\":\"Fixed north direction\","
            "\"cells\":[{\"cell\":%d,\"value\":1,\"label\":\"only option\"}]}",
            target);
        LOONG_GIZMO_JSON(record);
        snprintf(record, sizeof record,
                 "{\"version\":1,\"kind\":\"map\",\"label\":\"Stored head "
                 "position\","
                 "\"reason\":\"This example stores only its current head\","
                 "\"cells\":[{\"cell\":%d,\"label\":\"head\",\"value\":1}]}",
                 head);
        LOONG_GIZMO_JSON(record); LOONG_GIZMO_JSON(
            "{\"version\":1,\"kind\":\"candidate\",\"label\":\"N\","
            "\"objective\":\"Fixed direction preference\",\"score\":1,"
            "\"selected\":true,\"reason\":\"The only candidate\"}");
        LOONG_GIZMO_JSON(
            "{\"version\":1,\"kind\":\"state\",\"label\":\"Policy\","
            "\"nodes\":[{\"id\":\"north\",\"label\":\"North\",\"x\":0.2,\"y\":"
            "0.5,\"active\":true}],"
            "\"links\":[{\"from\":\"north\",\"to\":\"north\",\"label\":\"every "
            "turn\",\"active\":true}]}"););
    unswbc_end_turn();
  }
  return 0;
}
