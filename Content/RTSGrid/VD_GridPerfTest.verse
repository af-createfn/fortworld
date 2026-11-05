# World-map grid test.
# A world-map grid of placed cube props tagged rts_grid_tile, recolored with creative_prop.SetMaterial.
# Land is painted neutral at start. Each click on land (VD_RTSCamera.ClickEvent) spreads the next owner color
# over the connected land, one ring of cells per StepTime.
#
# Performance rules learned here:
#   * Never `set A[I] = X` on big arrays in hot code: with the 50,400-cell grid this made every claimed cell cost
#     ~50k steps and 20 parallel spreads fell 5 s behind. Each cell is now an object (rts_cell) with var fields,
#     so a change is O(1); the cell lookup is built once at start.
#   * Ownership changes at once; tiles are repainted from a queue, at most MaxPaintsPerTick per server tick.

using { /Fortnite.com/Devices }
using { /Verse.org/Simulation }
using { /Verse.org/Simulation/Tags }
using { /Verse.org/SpatialMath }
using { /Verse.org/Assets }
using { RTSCore }

# Verse tag on every map tile prop.
rts_grid_tile := class(tag){}

# One land cell of the map.
rts_cell := class:
    I:int
    J:int
    Tile:creative_prop
    var Owner:int = 0
    # Per owner (index Owner - 1): spread id of that owner that last reached this cell (replaces a per-spread
    # visited array). One shared mark made parallel spreads clear each other's marks and re-take cells endlessly.
    var Marks:[]int = array{0, 0, 0, 0}
    # VD_GameSim: id of the last front rebuild that kept this cell (drops duplicate entries).
    var Rekey:int = 0
    # Waiting in the paint queue: a cell is queued at most once, painted with its owner at paint time.
    var Queued:logic = false
    var Neighbors:[]rts_cell = array{}

# Paint queue node: a linked list, so adding and taking batches costs the same at any queue length
# (an array of batches is copied on every append and made the server fall to 2.5 ticks/s).
rts_paint_batch := class:
    Cells:[]rts_cell
    var Next:?rts_paint_batch = false

# One column (fixed J) of the cell lookup.
rts_column := class:
    var Cells:[]?rts_cell = array{}

VD_GridPerfTest := class(creative_device):

    # The camera whose clicks start the spread.
    @editable
    RTSCamera:VD_RTSCamera = VD_RTSCamera{}

    # Cells along editor X (north) and editor Y (east). World map: 140 x 360 cells of 1 degree, 80 N .. 60 S.
    @editable
    GridWidth:int = 140

    @editable
    GridHeight:int = 360

    # Cell size in cm (tile = PG cube 128 x 128, scaled 15/128). Kept small so the camera stays well within the
    # props' 150 m network relevancy distance (netCullDistanceSquared is fixed on Fortnite props), else far tiles
    # do not show their color changes.
    @editable
    CellSize:float = 15.0

    # World X / Y (editor axes) of the grid's minimum corner.
    @editable
    OriginX:float = -1050.0

    @editable
    OriginY:float = -2700.0

    # The border moves out one ring of cells per step (s).
    @editable
    StepTime:float = 0.1

    # A spread stops after this many rings at the latest.
    @editable
    MaxRings:int = 400

    # Print [GridPerf] lines (click start, spread done).
    @editable
    DebugLog:logic = true

    # Visual recolors per server tick (30 ticks/s).
    @editable
    MaxPaintsPerTick:int = 150

    # Tiles processed per server tick while building the map at start.
    @editable
    BuildChunk:int = 400

    # Seconds to wait before the green start paint (diagnostics: measure the server with untouched tiles first).
    @editable
    PaintDelay:float = 3.0

    # Log the server tick rate every 2 s with the number of tiles painted so far.
    @editable
    TickDiagnostics:logic = true

    # Off: the device does nothing (VD_GameSim paints the same tiles).
    @editable
    Active:logic = true

    var PaintedTotal:int = 0

    # Cell lookup: Columns[J].Cells[I], false on sea.
    var Columns:[]rts_column = array{}
    var Mats:[]material = array{}
    var NextOwner:int = 1
    var WaveCount:int = 0

    # Paint queue: linked batches from PaintFirst to PaintLast, PaintPos = next cell in PaintFirst.
    var PaintFirst:?rts_paint_batch = false
    var PaintLast:?rts_paint_batch = false
    var PaintPos:int = 0
    var QueuedCount:int = 0

    OnBegin<override>()<suspends>:void =
        if (not Active?):
            return
        set Mats = array:
            Materials.MI_Tile_Neutral{}
            Materials.MI_Tile_P1{}
            Materials.MI_Tile_P2{}
            Materials.MI_Tile_P3{}
            Materials.MI_Tile_P4{}
        T0 := GetSimulationElapsedTime()
        AllCells := BuildCells()
        Log("Land cells {AllCells.Length}, built in {GetSimulationElapsedTime() - T0} s")
        spawn{ PainterLoop() }
        if (TickDiagnostics?):
            spawn{ TickMonitor() }
        spawn{ ClickLoop() }
        # Placed tiles are white: paint all land neutral (green), through the queue. The delay lets the tick monitor
        # measure the server with all tiles still untouched (network dormant) first.
        Sleep(PaintDelay)
        Log("Start paint of {AllCells.Length} cells")
        QueuePaint(AllCells)

    Log(S:string):void =
        if (DebugLog?):
            Print("[GridPerf] {S}", ?Duration := 2.0)

    # Cell coordinates for editor-axis X / Y, fails outside the grid.
    CellCoords(X:float, Y:float)<transacts><decides>:tuple(int, int) =
        I := Floor[(X - OriginX) / CellSize]
        J := Floor[(Y - OriginY) / CellSize]
        I >= 0
        I < GridWidth
        J >= 0
        J < GridHeight
        (I, J)

    CellAt(I:int, J:int)<transacts><decides>:rts_cell =
        Columns[J].Cells[I]?

    # Builds every land cell and the lookup, BuildChunk tiles per server tick: doing all 16k in one tick hit
    # ErrRuntime_ComputationLimitExceeded. Each column is a small object, so inserting a cell copies only
    # that column's 140 entries, never the whole map.
    BuildCells()<suspends>:[]rts_cell =
        Objects := for (Object : Self.FindCreativeObjectsWithTag(rts_grid_tile)):
            Object
        NoCell:?rts_cell = false
        EmptyColumn := for (I := 0..GridWidth - 1):
            NoCell
        set Columns = for (J := 0..GridHeight - 1):
            rts_column{Cells := EmptyColumn}
        var Chunks:[][]rts_cell = array{}
        var Start:int = 0
        loop:
            if (Start >= Objects.Length):
                break
            Stop := Min(Start + BuildChunk, Objects.Length) - 1
            # Tile pivot is its maximum X / Y corner: center = pivot - half a cell. Editor Y = -Left.
            Chunk := for (K := Start..Stop, Prop := creative_prop[Objects[K]], P := Prop.GetGlobalTransform().Translation, IJ := CellCoords[P.Forward - CellSize * 0.5, -P.Left - CellSize * 0.5], Column := Columns[IJ(1)]):
                Cell := rts_cell{I := IJ(0), J := IJ(1), Tile := Prop}
                if (set Column.Cells[IJ(0)] = option{Cell}) {}
                Cell
            set Chunks += array{Chunk}
            set Start = Stop + 1
            Sleep(0.0)
        for (Chunk : Chunks):
            for (C : Chunk):
                set C.Neighbors = for (D := 0..3, N := NeighborOf[C, D]):
                    N
            Sleep(0.0)
        for (Chunk : Chunks, C : Chunk):
            C

    NeighborOf(C:rts_cell, D:int)<transacts><decides>:rts_cell =
        if (D = 0) then CellAt[C.I - 1, C.J]
        else if (D = 1) then CellAt[C.I + 1, C.J]
        else if (D = 2) then CellAt[C.I, C.J - 1]
        else CellAt[C.I, C.J + 1]

    # Queues cells that are not waiting yet. Returns how many were added.
    QueuePaint(Cells:[]rts_cell):int =
        Fresh := for (C : Cells, not C.Queued?):
            set C.Queued = true
            C
        if (Fresh.Length > 0):
            Batch := rts_paint_batch{Cells := Fresh}
            if (Last := PaintLast?):
                set Last.Next = option{Batch}
            else:
                set PaintFirst = option{Batch}
                set PaintPos = 0
            set PaintLast = option{Batch}
            set QueuedCount += Fresh.Length
        Fresh.Length

    # Repaints at most MaxPaintsPerTick queued cells per tick, each with its owner at paint time.
    PainterLoop()<suspends>:void =
        loop:
            Sleep(0.0)
            var Budget:int = MaxPaintsPerTick
            loop:
                if (Budget <= 0):
                    break
                if (Batch := PaintFirst?):
                    if (Cell := Batch.Cells[PaintPos]):
                        set Cell.Queued = false
                        if (Mat := Mats[Cell.Owner]):
                            Cell.Tile.SetMaterial(Mat)
                            set PaintedTotal += 1
                        set PaintPos += 1
                        set QueuedCount -= 1
                        set Budget -= 1
                    else:
                        # Batch done: move to the next one.
                        set PaintFirst = Batch.Next
                        set PaintPos = 0
                        if (not PaintFirst?):
                            set PaintLast = false
                else:
                    break

    # Server tick rate over 2 s windows (Sleep(0.0) = one tick).
    TickMonitor()<suspends>:void =
        loop:
            T0 := GetSimulationElapsedTime()
            var Ticks:int = 0
            var Worst:float = 0.0
            var Last:float = T0
            loop:
                Sleep(0.0)
                Now := GetSimulationElapsedTime()
                set Ticks += 1
                if (Now - Last > Worst):
                    set Worst = Now - Last
                set Last = Now
                if (Now - T0 >= 2.0):
                    break
            Log("Server: {Ticks * 1.0 / (Last - T0)} ticks/s, worst tick {Worst * 1000.0} ms, tiles painted so far {PaintedTotal}, cells waiting {QueuedCount}")

    ClickLoop()<suspends>:void =
        loop:
            Click := RTSCamera.ClickEvent.Await()
            G := Click.GroundPoint
            if (IJ := CellCoords[G.Forward, -G.Left], Cell := CellAt[IJ(0), IJ(1)]):
                Owner := NextOwner
                set NextOwner = if (NextOwner >= 4) then 1 else NextOwner + 1
                spawn{ Spread(Cell, Owner) }

    # Ring-by-ring spread from Start over connected land not owned by Owner yet.
    Spread(Start:rts_cell, Owner:int)<suspends>:void =
        set WaveCount += 1
        Wave := WaveCount
        Slot := Owner - 1
        if (set Start.Marks[Slot] = Wave) {}
        var Frontier:[]rts_cell = array{Start}
        var Colored:int = 0
        var Rings:int = 0
        T0 := GetSimulationElapsedTime()
        Log("Spread {Wave}: owner {Owner}")
        loop:
            if (Frontier.Length = 0 or Rings >= MaxRings):
                break
            Changed := for (C : Frontier, C.Owner <> Owner):
                set C.Owner = Owner
                C
            QueuePaint(Changed)
            set Colored += Changed.Length
            # Each neighbor joins the next ring once (Marks), only cells this owner does not hold yet.
            set Frontier = for (C : Frontier, N : C.Neighbors, N.Marks[Slot] <> Wave, N.Owner <> Owner):
                if (set N.Marks[Slot] = Wave) {}
                N
            set Rings += 1
            Sleep(StepTime)
        Log("Spread {Wave} done: {Colored} cells, {Rings} rings, {GetSimulationElapsedTime() - T0} s")
