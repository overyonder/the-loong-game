#include "helper.h"

int main(void)
{
    UnswbcController* ct   = NULL;
    UnswbcGame*       game = NULL;
    unswbc_init(&ct, &game);
    while (unswbc_update(ct, game))
    {
        unswbc_move(unswbc_facing(ct));
        unswbc_end_turn();
    }
    return 0;
}
