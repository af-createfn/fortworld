# Character helpers that need UE SpatialMath (fort_character.TeleportTo takes the UE vector3), kept out of files using
# Verse.org SpatialMath (same reason as rts_ui_helpers.verse).

using { /Fortnite.com/Characters }
using { /UnrealEngine.com/Temporary/SpatialMath }

# Teleports Char to a world point given in Verse.org axes (Forward = X, Left = -Y, Up = Z), facing +X.
RTSTeleportCharacter<public>(Char:fort_character, Forward:float, Left:float, Up:float)<transacts><decides>:void =
    Char.TeleportTo[vector3{X := Forward, Y := -Left, Z := Up}, IdentityRotation()]

# Horizontal distance (cm) from Char to a world point in Verse.org axes.
RTSCharacterDistance2D<public>(Char:fort_character, Forward:float, Left:float)<transacts>:float =
    P := Char.GetTransform().Translation
    DX := P.X - Forward
    DY := P.Y + Left
    Sqrt(DX * DX + DY * DY)
