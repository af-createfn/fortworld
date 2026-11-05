# Generated data - do not edit by hand.
# M_Tile8x8P: 22 parameters P00..P21, each packs 3 cells of a tile (cells 3P, 3P+1, 3P+2, K = row * 8 + column):
# value = index(3P) + 256 * index(3P+1) + 65536 * index(3P+2), index = T_TilePalette256 index.

# Multipliers of the 3 cells in a pack.
Tile8PackMul:[]int = array{1, 256, 65536}

# Value of a pack whose 3 cells are neutral (index 1): the material default.
Tile8PackNeutral:int = 65793

# Binary search over P (5 tests).
SetTile8Pack(M:Materials.M_Tile8x8P, P:int, V:float):void =
    if (P < 11):
        if (P < 5):
            if (P < 2):
                if (P < 1):
                    set M.P00 = V
                else:
                    set M.P01 = V
            else:
                if (P < 3):
                    set M.P02 = V
                else:
                    if (P < 4):
                        set M.P03 = V
                    else:
                        set M.P04 = V
        else:
            if (P < 8):
                if (P < 6):
                    set M.P05 = V
                else:
                    if (P < 7):
                        set M.P06 = V
                    else:
                        set M.P07 = V
            else:
                if (P < 9):
                    set M.P08 = V
                else:
                    if (P < 10):
                        set M.P09 = V
                    else:
                        set M.P10 = V
    else:
        if (P < 16):
            if (P < 13):
                if (P < 12):
                    set M.P11 = V
                else:
                    set M.P12 = V
            else:
                if (P < 14):
                    set M.P13 = V
                else:
                    if (P < 15):
                        set M.P14 = V
                    else:
                        set M.P15 = V
        else:
            if (P < 19):
                if (P < 17):
                    set M.P16 = V
                else:
                    if (P < 18):
                        set M.P17 = V
                    else:
                        set M.P18 = V
            else:
                if (P < 20):
                    set M.P19 = V
                else:
                    if (P < 21):
                        set M.P20 = V
                    else:
                        set M.P21 = V
