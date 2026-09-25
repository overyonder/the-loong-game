import helper as unswbc

ct, game = unswbc.init()
while unswbc.update(ct, game):
    ct.make_move(ct.get_dir())
    unswbc.end_turn()
