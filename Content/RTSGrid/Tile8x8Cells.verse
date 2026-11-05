# Generated (8 x 8 cells per tile): cell K = row * 8 + column of a tile -> material parameter C<row><column>
# of M_Tile8x8 (row = editor X / cell I, column = editor Y / cell J). Value = owner + 1 (T_NationPalette index).

# Binary search over K.
SetTile8Cell(M:Materials.M_Tile8x8, K:int, V:float):void =
    if (K < 32):
        if (K < 16):
            if (K < 8):
                if (K < 4):
                    if (K < 2):
                        if (K < 1):
                            set M.C00 = V
                        else:
                            set M.C01 = V
                    else:
                        if (K < 3):
                            set M.C02 = V
                        else:
                            set M.C03 = V
                else:
                    if (K < 6):
                        if (K < 5):
                            set M.C04 = V
                        else:
                            set M.C05 = V
                    else:
                        if (K < 7):
                            set M.C06 = V
                        else:
                            set M.C07 = V
            else:
                if (K < 12):
                    if (K < 10):
                        if (K < 9):
                            set M.C10 = V
                        else:
                            set M.C11 = V
                    else:
                        if (K < 11):
                            set M.C12 = V
                        else:
                            set M.C13 = V
                else:
                    if (K < 14):
                        if (K < 13):
                            set M.C14 = V
                        else:
                            set M.C15 = V
                    else:
                        if (K < 15):
                            set M.C16 = V
                        else:
                            set M.C17 = V
        else:
            if (K < 24):
                if (K < 20):
                    if (K < 18):
                        if (K < 17):
                            set M.C20 = V
                        else:
                            set M.C21 = V
                    else:
                        if (K < 19):
                            set M.C22 = V
                        else:
                            set M.C23 = V
                else:
                    if (K < 22):
                        if (K < 21):
                            set M.C24 = V
                        else:
                            set M.C25 = V
                    else:
                        if (K < 23):
                            set M.C26 = V
                        else:
                            set M.C27 = V
            else:
                if (K < 28):
                    if (K < 26):
                        if (K < 25):
                            set M.C30 = V
                        else:
                            set M.C31 = V
                    else:
                        if (K < 27):
                            set M.C32 = V
                        else:
                            set M.C33 = V
                else:
                    if (K < 30):
                        if (K < 29):
                            set M.C34 = V
                        else:
                            set M.C35 = V
                    else:
                        if (K < 31):
                            set M.C36 = V
                        else:
                            set M.C37 = V
    else:
        if (K < 48):
            if (K < 40):
                if (K < 36):
                    if (K < 34):
                        if (K < 33):
                            set M.C40 = V
                        else:
                            set M.C41 = V
                    else:
                        if (K < 35):
                            set M.C42 = V
                        else:
                            set M.C43 = V
                else:
                    if (K < 38):
                        if (K < 37):
                            set M.C44 = V
                        else:
                            set M.C45 = V
                    else:
                        if (K < 39):
                            set M.C46 = V
                        else:
                            set M.C47 = V
            else:
                if (K < 44):
                    if (K < 42):
                        if (K < 41):
                            set M.C50 = V
                        else:
                            set M.C51 = V
                    else:
                        if (K < 43):
                            set M.C52 = V
                        else:
                            set M.C53 = V
                else:
                    if (K < 46):
                        if (K < 45):
                            set M.C54 = V
                        else:
                            set M.C55 = V
                    else:
                        if (K < 47):
                            set M.C56 = V
                        else:
                            set M.C57 = V
        else:
            if (K < 56):
                if (K < 52):
                    if (K < 50):
                        if (K < 49):
                            set M.C60 = V
                        else:
                            set M.C61 = V
                    else:
                        if (K < 51):
                            set M.C62 = V
                        else:
                            set M.C63 = V
                else:
                    if (K < 54):
                        if (K < 53):
                            set M.C64 = V
                        else:
                            set M.C65 = V
                    else:
                        if (K < 55):
                            set M.C66 = V
                        else:
                            set M.C67 = V
            else:
                if (K < 60):
                    if (K < 58):
                        if (K < 57):
                            set M.C70 = V
                        else:
                            set M.C71 = V
                    else:
                        if (K < 59):
                            set M.C72 = V
                        else:
                            set M.C73 = V
                else:
                    if (K < 62):
                        if (K < 61):
                            set M.C74 = V
                        else:
                            set M.C75 = V
                    else:
                        if (K < 63):
                            set M.C76 = V
                        else:
                            set M.C77 = V
