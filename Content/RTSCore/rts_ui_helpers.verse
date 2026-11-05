# UI helpers kept apart from files that use /Verse.org/SpatialMath (both modules define vector3).

using { /UnrealEngine.com/Temporary/UI }
using { /UnrealEngine.com/Temporary/SpatialMath }

RTSAnchors(MinX:float, MinY:float, MaxX:float, MaxY:float):anchors =
    anchors{Minimum := vector2{X := MinX, Y := MinY}, Maximum := vector2{X := MaxX, Y := MaxY}}

RTSVector2(X:float, Y:float):vector2 =
    vector2{X := X, Y := Y}
