# Game loop simulation: nations expand over the world map the way the real game will.
# Each nation starts with a small area on a random land cell; every StepTime its troops grow (faster with more land).
# Human nations are played through the action menu: a click on the map opens it for the
# clicked cell; Attack sends AttackShare of the troops against the cell's owner along the whole border (OpenFront),
# Boat sends a transport ship there. The other nations are bots with OpenFront's nation decisions (BotAttack).
# Attacks (troop costs and the conquer order come from OpenFront's AttackExecution / EngineConfig.attackLogic):
#   * one attack per nation at a time against one target owner (neutral land or a neighbor);
#   * the target's border cells are taken lowest key first, key = (distance to the contact point + AimPull * distance
#     to the aim point) * DirectionWeight + a random 10..16 scaled by (1.5 - 0.5 * attacker neighbors): the attack
#     bulges out of the border where it is nearest the aim, stretched toward it, with a ragged edge, and fills dents
#     first, so no enemy specks stay behind;
#   * troops, costs and speed follow OpenFront; the old linear speed was
#     cells per second = AttackCellsPerSecond + troops * CellsPerTroop, slower
#     the more the attack is outnumbered (troop ratio clamped to 0.82..7.5), so an attack slows as it is spent.
# Only border cells change, so the paint load is close to a real match.
# Replaces the click spreads of VD_GridPerfTest as the perf test; switch that device's Active off when this runs.
#
# Map: each placed 1-degree tile (tag rts_grid_tile, 15 cm) shows 3 x 3 cells of 1/3 degree
# through M_Tile3x3: one scalar parameter per cell (C00..C22 = owner + 1, colors from T_TilePalette, 16 nations) and
# sea cells cut out by T_LandMask. The tiles carry the shared M_Tile3x3 from the editor (all cells neutral), so nothing
# is painted at start; a tile gets its own material instance when one of its cells first changes owner, after that a
# change is one parameter write. Land cells come from LandMask3x3.verse (9-bit mask per tile).
#
# Boats: a click on land the nation does not border sends a boat with AttackShare of the troops (at most
# MaxBoatsPerNation at sea). The route runs over 1-degree sea cells (gs_sea: tiles with at most 4 land cells of 9, plus
# sea without tiles) from the nation's coast to the landing shore;
# the boat (a rowboat prop from the pool tagged rts_boat, in the nation's color) sails it back and lands: the landing
# cell becomes the nation's and an attack with the boat's troops starts there toward the click. Bots without a land
# target send boats to random land now and then (BotBoatChance).
#

using { /Fortnite.com/Devices }
using { /Fortnite.com/Characters }
using { /Verse.org/Simulation }
using { /Verse.org/Simulation/Tags }
using { /Verse.org/SpatialMath }
using { /Verse.org/Assets }
using { /Verse.org/Random }
using { /UnrealEngine.com/Assets }
using { RTSCore }
using { RTSLobby }

# A lobby nation's seat in the pick phase: its nation id (humans 1..H in the order they came, bots from Nations
# down), the player (false = bot), the start cell chosen (anywhere on free land) and, for bots, when it chooses.
rts_seat := class:
    Id:int
    Player:?player
    var Cell:?gs_cell = false
    var PlaceAt:float = 0.0
    # palette color of a bot seat above LobbyColors (shared with the tribes, SeatColor); 0 = not chosen yet.
    var Color:int = 0

# One placed tile: 8 x 8 cells. Mat is its own material instance, made when one of its cells first changes.
# M_Tile8x8P, 22 parameters of 3 packed cells each (Tile8x8Packs.verse); Packs = the values the tile shows now,
# PackStamp = the paint round that last queued a write of that parameter.
gs_tile := class:
    Prop:creative_prop
    # Tile column / row and its 64 cell slots by K (false = sea).
    TI:int = 0
    TJ:int = 0
    var Slots:[]?gs_cell = array{}
    var Mat:?Materials.M_Tile8x8P = false
    var Cells:[]gs_cell = array{}
    var Packs:[]int = array{}
    var PackStamp:[]int = array{}

# One land cell (1/3 degree). K = its slot in the tile (row * 3 + column = material parameter Cxy).
gs_cell := class:
    I:int
    J:int
    Tile:gs_tile
    K:int
    var Owner:int = 0
    # Id of the last front rebuild that kept this cell (drops duplicate entries).
    var Rekey:int = 0
    # Waiting in the paint queue: a cell is queued at most once, painted with its owner at paint time.
    var Queued:logic = false
    # its parameter (K / 3) and place in it (K mod 3), and the palette index its tile shows now.
    var Pack:int = 0
    var Slot:int = 0
    var Painted:int = 1
    # Palette index shown instead of the owner's (pick phase spots), -1 = the owner.
    var Shown:int = -1
    var Neighbors:[]gs_cell = array{}
    var Far:[]gs_cell = array{}
    # Boats: id of the last landing search that looked at this cell.
    var Mark:int = 0
    # The connected land this cell belongs to (continent or island).
    var Mass:?gs_landmass = false
    # Id of the last cluster sweep that reached this cell (nation labels).
    var ClusterMark:int = 0
    # Terrain (Terrain.verse): 0 plains, 1 highland, 2 mountain.
    var Terrain:int = 0
    # The attack front this cell waits in (Push skips it there again; counted in that front's Live).
    var InFront:?rts_front = false
    # In its owner's border list; cleared when the cell changes owner.
    var InBorder:logic = false

# One connected piece of land. Counts = cells per owner at the start.
gs_landmass := class:
    var Counts:[]int = array{}

# One 1-degree sea cell of the boat routes (tile coordinates TI, TJ), loaded from SeaGrid.verse. Its coast = the
# coastal land cells (fewer than 4 land neighbors) of its tile and the 8 tiles around it. Owners[O] = coast cells owned
# by O (0 = neutral), kept by Take; empty for sea cells without a coast. Neighbors are looked up in the grid.
# Stamp / Parent belong to the route search running at the time (one at a time). Node = its route graph node.
gs_sea := class:
    TI:int
    TJ:int
    var Owners:[]int = array{}
    var Stamp:int = 0
    var Parent:?gs_sea = false
    var Node:int = -1

gs_sea_column := class:
    var Cells:[]?gs_sea = array{}

# Boat route graph node: one connected group of sea cells inside an 8 x 8 tile cluster, with
# its point (the group's sea cell closest to the group's center). Owners[O] = the sum of its sea cells' Owners[O]
# (kept by CoastMove). Stamp, Dist, Done, Parent and Via belong to the route search running at the time.
gs_route_node := class:
    Point:gs_sea
    var Edges:[]gs_route_edge = array{}
    var Owners:[]int = array{}
    var Stamp:int = 0
    var Dist:int = 0
    var Done:logic = false
    var Parent:?gs_route_node = false
    var Via:?gs_route_edge = false

# Edge to node To: cost (straight cell 10, diagonal 14) and the sea cells where the course turns between the two node
# points, in order from the node that owns the edge.
gs_route_edge := class:
    To:gs_route_node
    Cost:int
    Turns:[]gs_sea

# Bucket queue of the route search (Dial's algorithm): bucket = distance modulo the bucket count (> largest edge cost).
gs_route_item := class:
    Node:gs_route_node
    Dist:int
    var Next:?gs_route_item = false

gs_route_bucket := class:
    var Head:?gs_route_item = false

# One boat prop of the pool and the nation it currently sails for (false = free, hidden).
gs_boat := class:
    Prop:creative_prop
    var Busy:logic = false

# Verse tag on the boat props (rowboats scaled to the map, parked hidden).
rts_boat := class(tag){}

# Cell queue node: a linked list, so adding and taking batches costs the same at any length. Used = the filled slots;
# PushOne fills a block of QueueBlock slots instead of making an object per cell (an object costs ~12 us, an array
# slot write ~2 us, benchmark).
gs_batch := class:
    var Cells:[]gs_cell
    var Used:int = 0
    var Next:?gs_batch = false

# One column (fixed J) of the cell lookup.
gs_column := class:
    var Cells:[]?gs_cell = array{}

# Verse tag on the Billboard devices used as nation labels (one per nation, in tag order).
rts_nation_label := class(tag){}

# Verse tag on the Billboard devices of the attack label pool.
rts_attack_label := class(tag){}

# Tribe names: one of the first words + one of the second.
TribeFirst:[]string = array{"Ash", "Iron", "Red", "Stone", "Raven", "Wolf", "Oak", "Salt", "Storm", "Frost", "Sun", "Moon", "Bear", "Elk", "Thorn", "Amber", "Cedar", "Flint", "Hawk", "River", "Dune", "Reed", "Copper", "Grey", "Ember", "Willow", "Boar", "Fox", "Pine", "Cliff"}
TribeSecond:[]string = array{"folk", "clan", "kin", "riders", "tribe", "band", "hold", "watch", "born", "walkers"}

LabelMessage<localizes>(S:string):message = "{S}"

# a human nation's label. An agent in a localized message shows as the player's Fortnite display name (Verse
# has no string for it), so the name is never a string on the server.
PlayerLabelMessage<localizes>(Agent:agent, Power:string):message = "{Agent}\n{Power}"

# FIFO of cells: linked batches (same node as the paint queue), so a push costs the same at any length.
rts_cell_queue := class:
    var First:?gs_batch = false
    var Last:?gs_batch = false
    var Pos:int = 0
    var Count:int = 0

    Push(Cells:[]gs_cell):void =
        if (Cells.Length > 0):
            Link(gs_batch{Cells := Cells, Used := Cells.Length})
            set Count += Cells.Length

    # One cell: into the free slot of the last block, or a new block of QueueBlock slots.
    PushOne(C:gs_cell):void =
        if (L := Last?, L.Used < L.Cells.Length, set L.Cells[L.Used] = C):
            set L.Used += 1
        else:
            Link(gs_batch{Cells := array{C, C, C, C, C, C, C, C, C, C, C, C, C, C, C, C, C, C, C, C, C, C, C, C, C, C, C, C, C, C, C, C}, Used := 1})
        set Count += 1

    Link(Batch:gs_batch):void =
        if (L := Last?):
            set L.Next = option{Batch}
        else:
            set First = option{Batch}
            set Pos = 0
        set Last = option{Batch}

    # The next cell, false when the queue is empty. The last block stays (PushOne may still fill it).
    Pop()<transacts>:?gs_cell =
        var Result:?gs_cell = false
        loop:
            if (Batch := First?):
                if (Pos < Batch.Used, Cell := Batch.Cells[Pos]):
                    set Pos += 1
                    set Count -= 1
                    set Result = option{Cell}
                    break
                if (Next := Batch.Next?):
                    set First = option{Next}
                    set Pos = 0
                else:
                    break
            else:
                break
        Result

# Buckets in a front's key ring.
FrontRing:int = 256

# Random part of the attack key (OpenFront random 10..16), drawn once into a table and read in turn.
RollCount:int = 64

# The cells one attack may take, lowest key first (OpenFront's toConquer heap), in a ring of FrontRing buckets (bucket
# = key mod FrontRing) for the keys Cursor .. Cursor + FrontRing - 1: a push is one step, a pop only steps over empty
# buckets. Keys under Cursor go into Cursor's bucket, keys above the ring into its last bucket. Entries go stale when
# cells change owner and are checked when taken. the border list of the nation fills a new attack's front
# (rts_scan_job).
rts_front := class<unique>:
    var Ring:[]rts_cell_queue = array{}
    var Cursor:int = 0
    var RingCount:int = 0
    # Entries including stale ones.
    var Count:int = 0
    # The attack waits for a border scan (rts_scan_job) to fill this front; WaitJob = the scan id that fills it.
    var Pending:logic = false
    var WaitJob:int = 0
    # Distinct cells waiting in the ring: the attack's border size.
    var Live:int = 0
    # Sums of the coordinates of the Live cells.
    var SumI:int = 0
    var SumJ:int = 0
    # Buckets Pop stepped over, all time.
    var Steps:int = 0

    Push(C:gs_cell, Key:int):void =
        # Waiting here already: it keeps its key.
        if (M := C.InFront?, M = Self):
            return
        set C.InFront = option{Self}
        set Live += 1
        set SumI += C.I
        set SumJ += C.J
        if (Ring.Length = 0):
            set Ring = for (X := 1..FrontRing) { rts_cell_queue{} }
        if (RingCount = 0):
            # Room below the first key: keys of one batch spread about 160 around it.
            set Cursor = Key - 160
        K := Clamp(Key, Cursor, Cursor + FrontRing - 1)
        if (B := Ring[RingIndex(K)]):
            B.PushOne(C)
            set RingCount += 1
            set Count += 1

    # Push for a cell the caller checked with Has (no InFront test), the bucket index without a RingIndex call.
    PushNew(C:gs_cell, Key:int):void =
        set C.InFront = option{Self}
        set Live += 1
        set SumI += C.I
        set SumJ += C.J
        if (Ring.Length = 0):
            set Ring = for (X := 1..FrontRing) { rts_cell_queue{} }
        if (RingCount = 0):
            set Cursor = Key - 160
        K := Clamp(Key, Cursor, Cursor + FrontRing - 1)
        M := Mod[K, FrontRing] or 0
        if (B := Ring[if (M < 0) then M + FrontRing else M]):
            B.PushOne(C)
            set RingCount += 1
            set Count += 1

    # C waits in this front already.
    Has(C:gs_cell)<transacts><decides>:void =
        M := C.InFront?
        M = Self

    RingIndex(K:int)<transacts>:int =
        M := Mod[K, FrontRing] or 0
        if (M < 0) then M + FrontRing else M

    # The entry with the lowest key, false when the front is empty.
    # an empty bucket is passed by its Count (no queue Pop call) and the bucket index steps along with Cursor
    # (one Mod per Pop, not per step).
    Pop():?gs_cell =
        var Result:?gs_cell = false
        var Step:int = 0
        var Idx:int = RingIndex(Cursor)
        loop:
            if (RingCount <= 0 or Step > FrontRing):
                break
            if (B := Ring[Idx], B.Count > 0, C := B.Pop()?):
                set RingCount -= 1
                set Count -= 1
                if (M := C.InFront?, M = Self):
                    set C.InFront = false
                    set Live -= 1
                    set SumI -= C.I
                    set SumJ -= C.J
                set Result = option{C}
                break
            set Cursor += 1
            set Idx += 1
            if (Idx >= FrontRing) { set Idx = 0 }
            set Step += 1
        set Steps += Step
        if (not Result?):
            # A full lap without a cell: the ring is empty.
            set Count -= RingCount
            set RingCount = 0
            set Live = 0
            set SumI = 0
            set SumJ = 0
        Result

    # Drops every entry (a kept front reused by a new attack).
    Clear():void =
        loop:
            MaybeC := Pop()
            if (not MaybeC?):
                break

# A border scan of one nation spread over several ticks: walks the nation's border list, drops
# stale and duplicate entries (compaction) and puts the target cells next to each border cell into the fronts of the
# nation's attacks waiting for this scan (OpenFront refreshToConquer over owner.borderTiles()).
rts_scan_job := class:
    N:rts_nation
    Id:int
    Valid:rts_cell_queue = rts_cell_queue{}
    var Phase:int = 0
    var Kept:int = 0

# A border repaint after the war state of two nations changed: walks N's border list block by
# block from Batch / Pos (nothing is taken out, stale entries are skipped) and queues a repaint of each cell of N that
# touches Other, so their shared border turns red or back.
rts_border_job := class:
    N:rts_nation
    Other:int
    var Batch:?gs_batch = false
    var Pos:int = 0
    # next job in line; N.RepaintJob[Other] points here while it waits.
    var Next:?rts_border_job = false

# Lookups Take needs for cells of one old owner taken by one nation: the old owner (false = neutral land), the
# front of the taker's land attack on it, the front of its land attack on the taker, and (Batched, during an attack
# run) the net change of their shared sides not yet written (EdgeD, see EndTakes).
gs_take := class:
    var NId:int = -1
    var OldId:int = -1
    var Old:?rts_nation = false
    var Front:?rts_front = false
    var Counter:?rts_front = false
    var Batched:logic = false
    var EdgeD:int = 0

# One running attack of a nation on Target (owner id, 0 = neutral land), OpenFront AttackExecution. A land attack
# takes the cells of its Front (filled by a border scan, then by every cell N takes next to Target); a boat attack
# (Beach set) only grows from its landing cell, like OpenFront's sourceTile. Credit = the fraction of a cell carried
# over to the next tick.
rts_attack := class<unique>:
    Target:int
    Front:rts_front
    Beach:?rts_front = false
    var Troops:float = 0.0
    var Credit:float = 0.0
    var Done:logic = false
    # Simulation time it last ran.
    var Clock:float = -1.0
    # -1 = not run yet) and the cells of the human budget it may still take.
    var Rate:float = -1.0
    var Share:float = 0.0
    # when its values were computed (-1 = never), plains cells per OpenFront tick (0.1 s) and the
    # attacker's loss per terrain mag point (loss of a cell = mag 80 / 100 / 120 * PerMag).
    var SetupAt:float = -1.0
    var PerTick:float = 0.0
    var PerMag:float = 0.0
    # Attack label: the pool billboard it shows on (-1 = none). Cand = of the cells taken since the last label update,
    # the one closest to the front's center (CandD = squared distance), see TrackLabel / PlaceAttackLabel.
    Labeled:logic = false
    var Label:int = -1
    var HasPos:logic = false
    var PosI:float = 0.0
    var PosJ:float = 0.0
    var HasCand:logic = false
    var CandI:float = 0.0
    var CandJ:float = 0.0
    var CandD:float = 0.0

# One nation. Id = gs_cell.Owner value (0 = neutral).
rts_nation := class:
    Id:int
    # The player commanding this nation (false = bot) and its start slot.
    Human:?player
    Slot:int
    var Color:int = 1
    # Tribe: a weak AI nation that only fills the map (TribeAttack), not from the lobby; Slot is -1. Its own
    # random decision ratios as in OpenFront TribeExecution: attacks start at TriggerRatio of the maximum troops and
    # keep ReserveRatio (attacks on nations / humans) or ExpandRatio (free land, other tribes) of the maximum at home.
    # bots get their own ratios too (OpenFront NationExecution: 0.5..0.6, 0.3..0.4, 0.1..0.2).
    Tribe:logic = false
    Name:string = ""
    TriggerRatio:float = 0.55
    ReserveRatio:float = 0.35
    ExpandRatio:float = 0.15
    # Tribes: free land next to it was seen at the last decision (off for good once there is none).
    var NeutralNear:logic = true
    var Troops:float = 0.0
    var Cells:int = 0
    var Eliminated:logic = false
    # The player left the game: the nation no longer grows or attacks and decays (DecayLoop).
    var Left:logic = false
    # Sums of the cell coordinates (center = sum / Cells).
    var SumI:int = 0
    var SumJ:int = 0
    # Edge[Owner] = cell sides this nation shares with that owner (0 = neutral land;
    # > 0 = they border), Border = its cells with a foreign neighbor (unordered, stale entries dropped by scans),
    # AttackOn[Owner] = its running land attack on that owner, Fronts[Owner] = the front kept for attacks on that owner.
    var Edge:[]int = array{}
    Border:rts_cell_queue = rts_cell_queue{}
    var AttackOn:[]?rts_attack = array{}
    var Fronts:[]?rts_front = array{}
    # Border scans: id of the next scan, a scan is queued or running.
    var NextScan:int = 1
    var Scanning:logic = false
    # OpenFront large-territory sigmoid of Cells (BigNation), kept by Grow every game step.
    var BigS:float = 0.0
    # Cells at the last name box placement.
    var PlacedCells:int = 0
    # Running attacks.
    var Attacks:[]rts_attack = array{}
    # Simulation time its attacks last ran.
    var AttackClock:float = 0.0
    # Its waiting border repaint toward each owner.
    var RepaintJob:[]?rts_border_job = array{}
    # Bots: simulation time of the next attack decision (OpenFront nation attackRate).
    var NextThink:float = 0.0
    # Boats at sea and the troops on them; coastal cells a boat can leave from (cells with a sea cell).
    var Boats:int = 0
    var BoatTroops:float = 0.0
    # gold (OpenFront goldAdditionRate, conquerGoldAmount), the player's attack ratio from the panel slider (< 0 =
    # AttackShare) and the troop growth per second at the last panel update (green / orange).
    var Gold:float = 0.0
    var AttackRatio:float = -1.0
    var LastGrowth:float = 0.0
    var CoastCells:int = 0
    # Nation label (OpenFront NameBoxCalculator): bounding box of the largest connected territory (cell coordinates)
    # found by the last cluster sweep, the name box target (center, font size in cells) and what is shown now
    # (eased toward the target).
    var BoxSize:int = 0
    var BoxMinI:int = 0
    var BoxMaxI:int = 0
    var BoxMinJ:int = 0
    var BoxMaxJ:int = 0
    var CandSize:int = 0
    var CandMinI:int = 0
    var CandMaxI:int = 0
    var CandMinJ:int = 0
    var CandMaxJ:int = 0
    var NameI:float = 0.0
    var NameJ:float = 0.0
    var NameSize:float = 0.0
    var ShownI:float = 0.0
    var ShownJ:float = 0.0
    var ShownSize:float = 0.0

VD_GameSim := class(creative_device):

    # Cameras of the human players; a click commands the clicking player's nation.
    @editable
    RTSCamera:VD_RTSCamera = VD_RTSCamera{}

    # Pick phase: nations of the
    # lobby kind (humans + bots; tribes come on top and spawn first, spread evenly), seconds to pick (then
    # unseated players get a random spot), seconds after the last seat change once every player has a seat, the seat
    # mark size (cells around the seat cell painted) and the least distance (cells) between two seats.
    # 64 = up to 32 humans (ids 1..32) + bots; a seat without a human is a bot, so there are always 64.
    @editable
    Nations:int = 64

    @editable
    PickTime:float = 30.0

    @editable
    PickReadyDelay:float = 3.0

    @editable
    SpotRadius:int = 2

    @editable
    MinSeatGap:int = 12

    # Bots choose their seat at a random time BotPickMin..BotPickMax s into the pick phase (all at once, one per
    # quarter second, when every player has a seat): with BotNearPlayerChance BotNearMin..BotNearMax cells from a
    # random seated player, else spread out (the candidate farthest from every seat and tribe).
    @editable
    BotPickMin:float = 2.0

    @editable
    BotPickMax:float = 20.0

    @editable
    BotNearPlayerChance:float = 0.5

    # at most this many bots per game seat near players (a random 0..MaxBotsNearPlayers each game).
    @editable
    MaxBotsNearPlayers:int = 2

    @editable
    BotNearMin:int = 15

    @editable
    BotNearMax:int = 40

    # Random free cells looked at for a spread-out start (bots, players without a seat), and for a tribe start .
    @editable
    SpreadCandidates:int = 40

    @editable
    TribeCandidates:int = 40

    @editable
    TribesPerTick:int = 4

    # Ends the game with a human winner (Winning Team = Activating Team): WinShare of the land, or the last two nations
    # are both human and one player leaves.
    @editable
    EndGame:end_game_device = end_game_device{}

    # Ends the game when a bot wins (Winning Team = None: every player loses); activated by any player still here.
    @editable
    EndGameNoWinner:end_game_device = end_game_device{}

    # Nation of a player who left (OpenFront Doomsday Clock decay): it stops growing and attacking (a running attack is
    # called off), its troops drain to AbandonTroopFloor of what it had over AbandonDrainTime seconds, and from
    # AbandonRotStart seconds on its land turns neutral in random cells (speckles that grow together) until it is gone
    # AbandonRotTime seconds after the player left (OpenFront: troops to 5 % over ~90 s, rot finished at 150 s).
    @editable
    AbandonDrainTime:float = 90.0

    @editable
    AbandonTroopFloor:float = 0.05

    @editable
    AbandonRotStart:float = 30.0

    @editable
    AbandonRotTime:float = 150.0

    # Cell grid: 3 x 3 cells per placed tile (tiles 15 cm, 140 x 360, min corner OriginX / OriginY).
    @editable
    GridWidth:int = 420

    @editable
    GridHeight:int = 1080

    @editable
    CellSize:float = 5.0

    @editable
    OriginX:float = -1050.0

    @editable
    OriginY:float = -2700.0

    # Rings of land around the start slot's cell a nation starts with.
    @editable
    SpawnRadius:int = 6

    # Seconds per game step.
    @editable
    StepTime:float = 0.5

    # Server profiling: each server part writes "VerseProfile: rts_<part> X ms" to the log every time it runs
    # (attacks, paint, labels, name boxes, bot decisions, front rebuilds, route search, landing search). Off for
    # release: it writes ~100 log lines per second.
    @editable
    ProfileServer:logic = true

    # ---------- Troops and attacks ----------
    # One cell = one OpenFront tile, one OpenFront tick = 0.1 s (engine-lib/configuration/Config.ts, engine
    # configuration/EngineConfig.ts attackLogic, execution/AttackExecution.ts). The 80 / 16.5 below are the plains values; highland and
    # mountain cells use theirs (TerrainOf).
    #   max troops = 2 * (cells^0.6 * 1000 + 50000)                        (AI: times BotMaxTroopsFactor)
    #   growth per tick = (10 + troops^0.73 / 4) * (1 - troops / max)      (AI: times BotGrowthFactor)
    #   attack troops = AttackShare of the troops at home (OpenFront attack slider 20 %), boats BoatShare (1/5)
    #   neutral cell: attacker loses 80 / 5 = 16 troops; per tick budget 1, a cell costs
    #     clamp(2000 * 16.5 / attack troops, 5, 100) / (2 * border)
    #   enemy cell (r = defender troops / attack troops): attacker loses
    #     80 * clamp(r, 0.6, 2) * (0.463 * big attacker * big defender + 0.0039 * defender troops / defender cells),
    #     defender loses defender troops / defender cells; a cell costs
    #     clamp(r, 0.82, 7.5) * max(1, min(r / 20, 50)) / 8.55 * 16.5 * big attacker speed * big defender / border
    #   big-nation factors from S(n) = 1 / (1 + (300000 / n)^2.5): attacker loss max(0.3, 1 - 0.7 S), attacker
    #   speed max(0.27, 1 - 0.73 S), defender max(0.7, 1 - 0.3 S); border = cells on the attack's front + 0..5.
    #   An attack whose troops drop below 1 is lost (no refund); one that runs out of cells returns its troops.
    # The AI nations are OpenFront "Nations" at Medium difficulty by default (start 18,750, max x0.75, growth x0.95,
    # attack 1/5); OpenFront's weak "Bot" tribes would be 10,000, x1/3, x0.5, 1/20.
    @editable
    StartTroopsPlayer:float = 25000.0

    @editable
    BotStartTroops:float = 18750.0

    @editable
    BotMaxTroopsFactor:float = 0.75

    @editable
    BotGrowthFactor:float = 0.95

    # Tribes: how many join the lobby's nations (OpenFront Bot players: start 10,000 troops, max troops x 1/3,
    # growth x 0.5), the land rings they start with, and how often they decide (OpenFront attackRate 40..80 ticks).
    @editable
    TribeCount:int = 140

    @editable
    TribeStartTroops:float = 10000.0

    @editable
    TribeMaxTroopsFactor:float = 0.333

    @editable
    TribeGrowthFactor:float = 0.5

    @editable
    TribeSpawnRadius:int = 3

    @editable
    TribeThinkMin:float = 4.0

    @editable
    TribeThinkMax:float = 8.0

    @editable
    AttackShare:float = 0.2

    @editable
    BoatShare:float = 0.2

    # gold per OpenFront tick (0.1 s): humans and nations (OpenFront 100), tribes (OpenFront Bot 50).
    @editable
    GoldPerTick:float = 100.0

    @editable
    TribeGoldPerTick:float = 50.0

    # seconds between control panel updates (texts are sent only when they changed).
    @editable
    PanelInterval:float = 0.5

    # A bot starts an attack only with at least this many troops.
    @editable
    MinAttackTroops:float = 1000.0

    # A bot attacks a neighbor with at least this many times the neighbor's troops, or any neighbor once its own
    # troops reach FullArmyShare of its maximum (else a map of full armies never fights). BotTriggerChance = the
    # chance to attack below the trigger ratio (OpenFront 1 in 10).
    @editable
    AttackRatio:float = 1.5

    @editable
    FullArmyShare:float = 0.9

    @editable
    BotTriggerChance:float = 0.1

    # Bots decide on attacks every BotThinkMin..BotThinkMax seconds (OpenFront nation attackRate, Medium: 55..70
    # ticks of 0.1 s), each bot at its own random offset.
    @editable
    BotThinkMin:float = 5.5

    @editable
    BotThinkMax:float = 7.0

    # Stress test: the lobby bots (not tribes) play like active humans: player start troops, maximum and growth,
    # attacks every tick before everyone else and outside the shared caps, attack labels, and a decision every
    # PlayerBotThinkMin..PlayerBotThinkMax s that sends AttackShare of the troops (the player's slider) into free land
    # and AttackShare into a neighbor nation (PlayerBotAttack).
    @editable
    BotsAsPlayers:logic = false

    @editable
    PlayerBotThinkMin:float = 1.0

    @editable
    PlayerBotThinkMax:float = 2.5

    # a bot playing as a human attacks only with at least this share of its maximum troops.
    @editable
    PlayerBotMinArmy:float = 0.4

    # Cells all attacks together may take in one server tick (30 ticks/s); attacks over the cap wait for the next
    # tick. The cap adapts: it drops by one per tick slower than SlowTickMs and rises by one per faster tick,
    # between MinConquestsPerTick and MaxConquestsPerTick.
    @editable
    MaxConquestsPerTick:int = 24

    @editable
    MinConquestsPerTick:int = 6

    @editable
    SlowTickMs:float = 40.0

    # Cells one attack may take in one server tick: a fast attack becomes a steady stream of a few cells every tick
    # instead of chunks (credit above that is kept, up to one second of cells).
    @editable
    MaxCellsPerNationPerTick:int = 2

    # cells per second all human nations together may take (BotsAsPlayers bots count as humans); the per-attack caps
    # above still apply. A server tick longer than 0.1 s counts as 0.1 s, so a slow server slows the humans down too.
    @editable
    HumanCellsPerSecond:float = 500.0

    # share of HumanCellsPerSecond split equally among the attacking human nations before the rest is split by
    # speed (a nation wanting less than its equal part gives the unused part to the speed split).
    @editable
    HumanFloorShare:float = 0.2

    # OpenFront tiles one cell stands for (OpenFront World 651,569 land tiles / 136,216 land cells). Attack speed /
    # sqrt(TilesPerCell), attacker loss per cell * TilesPerCell, max troops from cells * TilesPerCell.
    @editable
    TilesPerCell:float = 4.78

    # seconds an attack keeps its speed and loss values (AttackSetup) before computing them again (OpenFront:
    # every tick; troop ratios change slowly, the full formula on every run cost ~0.1-0.2 ms).
    @editable
    AttackSetupTime:float = 0.25

    # Tribes' attacks run every TribeAttackPeriod server ticks.
    @editable
    TribeAttackPeriod:int = 4

    # Attacks on neutral land have their own budget: MaxNeutralConquestsPerTick for all of them together, scaled down
    # with the adaptive cap (cap / MaxConquestsPerTick), and MaxNeutralCellsPerAttackPerTick per attack.
    @editable
    MaxNeutralConquestsPerTick:int = 48

    @editable
    MaxNeutralCellsPerAttackPerTick:int = 3

    # Front entries a rebuild handles per server tick; a longer front is rebuilt over several ticks (~50 us per entry).
    @editable
    RebuildWorkPerTick:int = 200

    # Material parameter writes per paint round, and seconds between paint rounds.
    @editable
    MaxPaintsPerTick:int = 300

    @editable
    PaintInterval:float = 0.1

    # below this LoadShare (adaptive conquest cap / its maximum) the server counts as slow: paint rounds every
    # SlowPaintInterval s (writes per round scaled up to match) and human attacks every second tick.
    @editable
    SlowLoadShare:float = 0.5

    @editable
    SlowPaintInterval:float = 0.2

    # Tiles processed per server tick while building the map at start (9 cells each).
    @editable
    BuildChunk:int = 40

    # Tiles and boat icons switch from the editor cube to the 2-triangle plane SM_GridTilePlane at start (the PG cube
    # props cannot keep another mesh in the editor).
    @editable
    UsePlanes:logic = true

    # Seconds between building the map and spawning the nations (lets the tick monitor measure the idle map first;
    # 3 -> 0.5, the start was too long).
    @editable
    StartDelay:float = 0.5

    # Runs the Verse cost benchmark at start.
    @editable
    RunBenchmark:logic = false

    # A nation holding more than this share of the land wins and the game ends (OpenFront percentageTilesOwnedToWin 80).
    @editable
    WinShare:float = 0.8

    # Boats: at most MaxBoatsPerNation at sea per nation, BoatSpeed in cm per second (one 1-degree sea cell = 15 cm).
    # A boat is a flat boat icon (PG cube with M_BoatIcon in the nation color, BoatIconSize cm, pivot at its max
    # corner) BoatHeight cm above the map. It stays a cube: as the plane the icons did not show while sailing.
    # Free boats are never hidden: they wait BoatParkDepth cm under the map center (a Show right before a short trip
    # reached the client too late, so 1-8 sea cell boats never showed).
    # Bots send random boats like OpenFront nations (attackWithRandomBoat): at a decision without neutral land next to
    # them, with BotBoatChanceAlone when they border no nation, else BotBoatChanceAtWar (that decision then makes no
    # land attack); the goal is a random land cell within BotBoatRange cells of the bot's center, free land first,
    # else a nation it does not border and is not weaker than; at least BotBoatTroops troops.
    @editable
    MaxBoatsPerNation:int = 3

    @editable
    BoatSpeed:float = 28.0

    @editable
    BoatIconSize:float = 20.0

    @editable
    BoatHeight:float = 1.6

    @editable
    BoatParkDepth:float = 200.0

    @editable
    BotBoatChanceAlone:float = 0.2

    @editable
    BotBoatChanceAtWar:float = 0.1

    @editable
    BotBoatRange:int = 200

    @editable
    BotBoatTroops:float = 5000.0

    # Sea cells the route search looks at per server tick.
    @editable
    RouteNodesPerTick:int = 400

    # Spawn NS_ClickRing where the map is clicked.
    @editable
    ShowClickRing:logic = true

    # Nation labels (Billboard devices tagged rts_nation_label): name and military power (troops at home + in the
    # running attack) on the nation's center, LabelHeight cm above the map. Each billboard keeps the rotation it has in
    # the editor (set there so the text lies flat on the map, readable from the default camera) plus the camera's
    # Q/E turn, so the text stays upright on screen.
    @editable
    LabelHeight:float = 3.0

    @editable
    LabelUpdateTime:float = 0.1

    # A label is moved only when its eased position changed by more than this (cm) or its size by more than 2 %.
    @editable
    LabelMoveStep:float = 0.5

    # Label placement and size as in OpenFront (NameBoxCalculator): the name sits in the largest rectangle inside the
    # nation's largest connected territory (own land, any shore, shallow sea next to a coast) with font size min(rect
    # width / name length * 2, rect height / 3) cells, in map space (big nation = big name). The billboard scale is
    # font size * LabelScalePerCell (its text line is ~24 cm at scale 1, a cell is 5 cm), clamped to
    # LabelMinScale..LabelMaxScale. Clusters are recomputed every LabelRecalcTime s; the shown label eases toward the
    # new box with LabelEase per second.
    @editable
    LabelScalePerCell:float = 0.21

    @editable
    LabelMinScale:float = 0.15

    @editable
    LabelMaxScale:float = 1.5

    @editable
    LabelRecalcTime:float = 2.0

    @editable
    LabelEase:float = 4.0

    # Work of the cluster sweep per server tick: a cell it only looks at costs 1, a cell it walks over costs 4 (it
    # runs all game long; a full late-game sweep ~270 ticks at 2000).
    @editable
    ClusterWorkPerTick:int = 2000

    @editable
    LabelTextSize:int = 24

    # The billboard draws its text this far above its pivot (along its own up axis): the pivot is moved down by it so
    # the text, not the pivot, sits on the nation's center.
    @editable
    LabelWidgetHeight:float = 81.0

    # Attack labels: troops of a running attack on another nation, AttackLabelHeight cm above the map, billboard scale
    # AttackLabelScale, updated every AttackLabelTime s. an attack keeps its billboard until it ends (no swapping by
    # troops). it moves to a closer one only when that is AttackLabelHold cells closer to the center (no flicker
    # between front parts at about the same distance). The shown label eases toward the point with AttackLabelEase per
    # second (OpenFront: 250 ms ease).
    @editable
    AttackLabelTime:float = 0.3

    @editable
    AttackLabelHeight:float = 3.5

    @editable
    AttackLabelScale:float = 0.5

    @editable
    AttackLabelEase:float = 6.0

    @editable
    AttackLabelHold:float = 4.0

    # Border list entries the border repaint after a war starts or ends walks per server tick.
    @editable
    BorderRefreshPerTick:int = 400

    # Print [GameSim] lines (stats every 2 s, eliminations, win, player attacks).
    @editable
    DebugLog:logic = true

    # Front entries one attack may look at per wanted cell (stale entries are skipped).
    PopsPerCell:int = 8

    # One call in ProfileSample gets the sampled profile tags.
    ProfileSample:int = 64

    # Most nations in a game. humans only get these ids), the rest shared by the tribes and the lobby bots above 32
    # (TribeColor, SeatColor). 8-bit packs allow no more than 64 colors.
    MaxNations:int = 204

    LobbyColors:int = 32

    PaletteColors:int = 63

    Pow2:[]int = array{1, 2, 4, 8, 16, 32, 64, 128, 256}

    # Cells per tile side (M_Tile8x8: 8 x 8 parameters C00..C77).
    TileCells:int = 8

    # Character -> value of the rts_tile_masks alphabet.
    var MaskDigit:[char]int = map{}

    var Columns:[]gs_column = array{}
    var SeaColumns:[]gs_sea_column = array{}
    var ClusterStamp:int = 0
    var AllCells:[]gs_cell = array{}
    var BoatPool:[]gs_boat = array{}
    var RouteStamp:int = 0
    var RouteBusy:logic = false
    var RouteNodes:[]gs_route_node = array{}
    var RouteBuckets:[]gs_route_bucket = array{}
    var LandingStamp:int = 0
    var NationList:[]rts_nation = array{}
    # The nation each human player commands.
    var HumanNations:[player]rts_nation = map{}
    # Players who left before the nations spawned (their nations decay from the start).
    var GonePlayers:[player]logic = map{}
    # Pick phase: players in the order they came (nation id = index + 1), the seats, the time of the last seat
    # change, the tribes' start cells, running flag.
    var Pickers:[]player = array{}
    var Seats:[]rts_seat = array{}
    var SeatChange:float = 0.0
    # Bots that may still seat near a player in this pick phase.
    var BotsNearLeft:int = 0
    var TribeStarts:[]gs_cell = array{}
    var TribeStartColors:[]int = array{}
    # Color of each owner id.
    var OwnerColor:[]int = array{}
    # War state cache of the paint round: owners A, B, the result and the round.
    var WarA:int = -1
    var WarB:int = -1
    var WarV:logic = false
    var WarRound:int = -1
    var Picking:logic = false
    # Border repaints waiting after war states changed, and the cells they queued (stats).
    # a linked list (head, tail, length), one job per nation pair.
    var BorderHead:?rts_border_job = false
    var BorderTail:?rts_border_job = false
    var BorderJobCount:int = 0
    var BorderRestarts:int = 0
    var BorderRefreshes:int = 0
    # Repaints QueueIfChanged left out, the shown index being the same.
    var PaintSkips:int = 0
    # Neighbor repaints TakePaint left out, the old owner's cell showing the war border already.
    var TakeSkips:int = 0
    # Material parameter writes of the paint rounds.
    var ParamWrites:int = 0
    var WinnerDeclared:logic = false
    var LandCells:int = 0
    var WinLogged:logic = false
    var RekeyCount:int = 0

    # Cells waiting for a repaint (each at most once, see gs_cell.Queued).
    PaintQueue:rts_cell_queue = rts_cell_queue{}

    # Take's lookups, reused.
    TakeCtx:gs_take = gs_take{}
    var QueuedCount:int = 0

    # Counters for the 2 s stats.
    var PaintedTotal:int = 0
    var ChangedTotal:int = 0
    # Times an attack wanted more cells in a tick than the server caps allowed (since the last stats line).
    var CapHits:int = 0
    # sampled profile calls (SampleNow) and the cells of the sampled attack runs.
    var AttackRuns:int = 0
    var AttackPops:int = 0
    var StalePops:int = 0
    # Empty front buckets the attack pops stepped over.
    var PopSteps:int = 0
    # Attack runs that took no cell and the sampled-run flag (RunAttack).
    var ZeroRuns:int = 0
    var RunSampled:logic = false
    var CellsTaken:int = 0
    var HumanTaken:int = 0
    var KeyPushes:int = 0
    var HumanGiven:float = 0.0
    var SampleCount:int = 0
    var SampleRuns:int = 0
    var SampleRunCells:int = 0
    # Work counters for the stats line (since the last line): front rebuilds and the entries they walked, front
    # pushes, bot decisions, route search and landing search steps, name box steps.
    var RebuildsDone:int = 0
    var RebuildEntries:int = 0
    var FrontPushes:int = 0
    var BotDecisions:int = 0
    var RouteSteps:int = 0
    var LandingSteps:int = 0
    var ClusterSteps:int = 0
    var TribeDecisions:int = 0
    var TribeAttacks:int = 0
    var AttackLabelCalls:int = 0
    var AttackLabelsWanted:int = 0
    var AttackLabelsShown:int = 0
    # Attack label pool state (AttackLabelLoop / UpdateAttackLabels).
    var AttackLabels:[]billboard_device = array{}
    var AttackLabelRots:[]rotation = array{}
    var AttackLabelOwners:[]?rts_attack = array{}
    var AttackLabelTexts:[]string = array{}
    var AttackLabelPositions:[]vector3 = array{}
    # The eased point each billboard shows.
    var AttackLabelEased:[]vector3 = array{}
    # What each nation label shows now: a device call only when the text changed or the label moved / resized
    # visibly.
    var LabelShown:[]logic = array{}
    var LabelText:[]string = array{}
    var LabelPos:[]vector3 = array{}
    var LabelSize:[]float = array{}
    var LabelRound:int = 0
    # Current adaptive cap of conquests per tick (MinConquestsPerTick..MaxConquestsPerTick).
    var ConquestCap:int = 12

    # Action menu per human player (ActionMenu.verse), the cell it was opened on, and the time before which map clicks
    # are ignored (a menu button press can also arrive as a map click).
    var Menus:[player]rts_action_menu = map{}
    var MenuCells:[player]gs_cell = map{}
    var MenuStamp:[player]int = map{}
    var IgnoreClicksUntil:[player]float = map{}
    var Panels:[player]rts_control_panel = map{}
    # Short notes at the top of a player's screen: the newest note's stamp (an older note's timer does not clear it).
    var NoteStamp:[player]int = map{}

    OnBegin<override>()<suspends>:void =
        # Every player sees the map at once; the pick phase starts when the map is built.
        for (P : GetPlayspace().GetPlayers()):
            StartCamera(P)
        GetPlayspace().PlayerAddedEvent().Subscribe(OnPlayerJoined)
        GetPlayspace().PlayerRemovedEvent().Subscribe(OnPlayerLeft)
        T0 := GetSimulationElapsedTime()
        set AllCells = BuildCells()
        set LandCells = AllCells.Length
        Log("Land cells {LandCells}, built in {GetSimulationElapsedTime() - T0} s")
        T2 := GetSimulationElapsedTime()
        Masses := LoadLandmasses()
        Log("{Masses} landmasses, loaded in {GetSimulationElapsedTime() - T2} s")
        T3 := GetSimulationElapsedTime()
        Rough := LoadTerrain()
        Log("{Rough} highland / mountain cells, loaded in {GetSimulationElapsedTime() - T3} s")
        T1 := GetSimulationElapsedTime()
        Seas := LoadSea()
        Log("Sea cells {Seas}, built in {GetSimulationElapsedTime() - T1} s")
        T4 := GetSimulationElapsedTime()
        Edges := LoadRoutes()
        Log("Route graph: {RouteNodes.Length} nodes, {Edges} edges, {RouteBuckets.Length} buckets, loaded in {GetSimulationElapsedTime() - T4} s")
        set BoatPool = for (Obj : Self.FindCreativeObjectsWithTag(rts_boat), Prop := creative_prop[Obj]):
            ParkBoat(Prop)
            gs_boat{Prop := Prop}
        Log("{BoatPool.Length} boats")
        set RollTable = for (K := 1..RollCount) { GetRandomInt(10, 16) }
        if (RunBenchmark?):
            Bench()
        spawn{ PainterLoop() }
        spawn{ StatsLoop() }
        # The tiles already show neutral land (shared M_Tile8x8 from the editor): nothing to paint at start.
        Sleep(StartDelay)
        SpawnTribes()
        PickPhase()
        SpawnLobby()
        spawn{ AttackLoop() }
        spawn{ RebuildLoop() }
        spawn{ BorderLoop() }
        spawn{ LabelLoop() }
        spawn{ AttackLabelLoop() }
        spawn{ NameBoxLoop() }
        for (N : NationList, P := N.Human?):
            Log("{NationName(N)} plays nation {N.Id} ({N.Cells} cells): click the map for the action menu")
            MakeMenu(P)
            MakePanel(P, N)
        spawn{ ClickLoop() }
        spawn{ PanelLoop() }
        GameLoop()

    # P's RTS camera over the middle of the map; the character cannot take damage (a death would respawn it without
    # the camera).
    StartCamera(P:player):void =
        if (Char := P.GetFortCharacter[]):
            Char.SetVulnerability(false)
        Focus := vector3:
            Forward := OriginX + GridWidth * CellSize * 0.6
            Left := -(OriginY + GridHeight * CellSize * 0.5)
            Up := 0.0
        Started := RTSCamera.StartFor(P, Focus)
        if (not Started?):
            Log("No camera for a player")

    # A player joining during the pick phase plays; later ones only watch (Island Settings keep joins closed anyway).
    OnPlayerJoined(P:player):void =
        StartCamera(P)

    # ---------- Pick phase ----------

    # The tribes are already on the map
    # (SpawnTribes). Each player clicks free land for a seat (PickClickLoop, another click moves it); each bot seat
    # chooses at its PlaceAt time (BotSeat). Once every player has a seat and every bot has chosen, the game starts
    # PickReadyDelay s after the last seat change; after PickTime it starts anyway and seatless players get a spread-out
    # spot (SpreadCell). The lobby nations spawn on their seats afterwards (SpawnLobby).
    PickPhase()<suspends>:void =
        set Picking = true
        set BotsNearLeft = GetRandomInt(0, Max(0, MaxBotsNearPlayers))
        spawn{ PickClickLoop() }
        T0 := GetSimulationElapsedTime()
        set SeatChange = T0
        loop:
            Now := GetSimulationElapsedTime()
            for (P : GetPlayspace().GetPlayers(), PickerIndex(P) < 0, Pickers.Length < Min(Nations, LobbyColors)):
                set Pickers += array{P}
                set Seats += array{rts_seat{Id := Pickers.Length, Player := option{P}}}
            UpdateBotSeats(Now)
            Active := for (S : Seats, P := S.Player?, PlayerHere(P)?) { S }
            Seated := for (S : Active, S.Cell?) { S }
            AllSeated:logic = if (Active.Length > 0, Seated.Length = Active.Length) then true else false
            # Bots choose at their time, or once every player has a seat. with 64 seats several due in one round made
            # 300-400 ms ticks (BotSeat ~50-100 ms each).
            var Placed:logic = false
            for (S : Seats, not S.Player?, not S.Cell?, not Placed?, AllSeated? or Now >= S.PlaceAt):
                BotSeat(S)
                set Placed = true
            BotsDone:logic = if (for (S : Seats, not S.Player?, not S.Cell?) { S }.Length = 0) then true else false
            Left := Max(0.0, PickTime - (Now - T0))
            Ready:logic = if (AllSeated?, BotsDone?) then true else false
            StartIn := if (Ready?) then Min(Left, Max(0.0, PickReadyDelay - (Now - SeatChange))) else Left
            if (StartIn <= 0.0):
                break
            Seconds := Ceil[StartIn] or 0
            for (S : Active, P := S.Player?):
                Mine := if (S.Cell?) then "Your start is set (click elsewhere to move it)" else "Click free land on the map to choose your start"
                Header := if (Ready?) then "Everyone chose - the game starts in {Seconds} s" else "Choose your start - {Seconds} s"
                RTSCamera.SetStatus(P, "{Header}\n{Mine}\n{Seated.Length} / {Active.Length} players chose")
            Sleep(0.25)
        set Picking = false
        for (S : Seats, P := S.Player?):
            RTSCamera.SetStatus(P, "")
        # Players who left lose their seat; seatless players and bots get a spread-out spot.
        set Seats = for (S : Seats, SeatStays(S)?) { S }
        Picked := for (S : Seats, S.Player?, S.Cell?) { S }.Length
        Humans := for (S : Seats, S.Player?) { S }.Length
        for (S : Seats, not S.Cell?):
            if (C := SpreadCell(S)?):
                set S.Cell = option{C}
            Sleep(0.0)
        # The seat marks go; the nations' land paints over the seats.
        for (S : Seats, C := S.Cell?):
            MarkSeat(C, -1)
        Log("Pick phase over in {GetSimulationElapsedTime() - T0} s: {Picked} of {Humans} players chose, {Seats.Length - Humans} bots, {TribeStarts.Length} tribes")

    # Bot seats fill the lobby: ids Pickers.Length + 1 .. Nations (from Nations down). A player who comes takes the next
    # id, so the bot seat with that id goes (its mark too). New bot seats choose BotPickMin..BotPickMax s from now.
    UpdateBotSeats(Now:float):void =
        Humans := Pickers.Length
        for (S : Seats, not S.Player?, S.Id <= Humans, C := S.Cell?):
            MarkSeat(C, -1)
        set Seats = for (S : Seats, S.Player? or S.Id > Humans) { S }
        for (Id := Humans + 1..Nations, not SeatOf[Id]):
            set Seats += array{rts_seat{Id := Id, Player := false, PlaceAt := Now + GetRandomFloat(BotPickMin, BotPickMax)}}

    SeatOf(Id:int)<transacts><decides>:rts_seat =
        var Found:?rts_seat = false
        for (S : Seats, S.Id = Id):
            set Found = option{S}
        Found?

    # Index of P in Pickers, -1 when P has not been in the pick phase.
    PickerIndex(P:player)<transacts>:int =
        var Found:int = -1
        for (Index -> X : Pickers, Found < 0, X = P):
            set Found = Index
        Found

    PlayerHere(P:player)<transacts>:logic =
        if (GetPlayspace().GetPlayers().Find[P]) then true else false

    # Clicks of the pick phase: free land (no owner, MinSeatGap cells from every other seat) becomes the player's seat;
    # its old seat is free again. Every change restarts the start countdown.
    PickClickLoop()<suspends>:void =
        loop:
            Click := RTSCamera.ClickEvent.Await()
            if (not Picking?):
                break
            P := Click.Player
            Id := PickerIndex(P) + 1
            G := Click.GroundPoint
            if (Id > 0, S := SeatOf[Id]):
                if (IJ := CellCoords[G.Forward, -G.Left], C := CellAt[IJ(0), IJ(1)]):
                    if (SeatFree[C, S]):
                        PlaceSeat(S, C)
                        Log("Pick: player {Id} sits at cell {C.I}, {C.J}")
                    else:
                        RTSCamera.SetStatus(P, "Too close to a tribe or another start: click free land farther away")
                else:
                    RTSCamera.SetStatus(P, "Click on land to choose your start")

    # S sits at C now: marks moved, countdown restarted.
    PlaceSeat(S:rts_seat, C:gs_cell):void =
        if (Old := S.Cell?):
            MarkSeat(Old, -1)
        set S.Cell = option{C}
        # Nations 1..32 have their own color; the seat shows it (border state: opaque).
        MarkSeat(C, SeatColor(S, C) * 4 + 1)
        set SeatChange = GetSimulationElapsedTime()

    # seat S's palette color. Ids 1..LobbyColors (every human, humans are capped to LobbyColors) have their own;
    # bot ids above it share the tribe colors (TribeColor at its first cell C, kept for the game).
    SeatColor(S:rts_seat, C:gs_cell):int =
        if (S.Id <= LobbyColors):
            S.Id
        else:
            if (S.Color = 0):
                set S.Color = TribeColor(C)
            S.Color

    # C is free land at least MinSeatGap cells from every other seat.
    # stops at the first close seat (was a new array of the close seats per call).
    SeatFree(C:gs_cell, S:rts_seat)<transacts><decides>:void =
        C.Owner = 0
        Gap2 := MinSeatGap * MinSeatGap
        var Close:logic = false
        var K:int = 0
        loop:
            if (Close?):
                break
            if (X := Seats[K]):
                set K += 1
                if (X.Id <> S.Id, XC := X.Cell?, Distance2(XC, C) < Gap2):
                    set Close = true
            else:
                break
        not Close?

    # Squared cell distance of A and B.
    Distance2(A:gs_cell, B:gs_cell)<transacts>:int =
        DI := A.I - B.I
        DJ := A.J - B.J
        DI * DI + DJ * DJ

    # A seat stays after the pick phase: a bot's, or a player's who is still here.
    SeatStays(S:rts_seat)<transacts>:logic =
        if (P := S.Player?) then PlayerHere(P) else true

    # A bot's seat: with BotNearPlayerChance near a random seated player (BotNearMin..BotNearMax cells) while the game
    # still allows one, else spread out.
    BotSeat(S:rts_seat):void =
        var Cell:?gs_cell = false
        Players := for (X : Seats, X.Player?, XC := X.Cell?) { XC }
        if (BotsNearLeft > 0, Players.Length > 0, GetRandomFloat(0.0, 1.0) < BotNearPlayerChance, Near := Players[GetRandomInt(0, Players.Length - 1)]):
            for (Try := 1..60, not Cell?):
                D := GetRandomInt(BotNearMin, BotNearMax) * 1.0
                Angle := GetRandomFloat(0.0, 6.2832)
                I := Near.I + (Round[D * Cos(Angle)] or 0)
                J := Near.J + (Round[D * Sin(Angle)] or 0)
                if (C := CellAt[I, J], SeatFree[C, S]):
                    set Cell = option{C}
            if (Cell?):
                set BotsNearLeft -= 1
        if (not Cell?):
            set Cell = SpreadCell(S)
        if (C := Cell?):
            PlaceSeat(S, C)

    # A spread-out free cell for seat S: of SpreadCandidates random free cells (free land two steps around, MinSeatGap
    # from the seats) the one farthest from every seat and tribe start.
    SpreadCell(S:rts_seat)<transacts>:?gs_cell =
        Others := TribeStarts + (for (X : Seats, X.Id <> S.Id, XC := X.Cell?) { XC })
        var Best:?gs_cell = false
        var BestD:int = -1
        Cells := AllCells
        Last := Cells.Length - 1
        for (Try := 1..SpreadCandidates, C := Cells[GetRandomInt(0, Last)], FreeAround[C], SeatFree[C, S]):
            D := NearestAbove(C, Others, BestD)
            if (D > BestD):
                set Best = option{C}
                set BestD = D
        Best

    # Squared cell distance from C to the nearest of Cells (a large number when there are none).
    NearestDistance(C:gs_cell, Cells:[]gs_cell)<transacts>:int =
        var Nearest:int = 2000000000
        for (X : Cells):
            set Nearest = Min(Nearest, Distance2(X, C))
        Nearest

    # NearestDistance, but it stops once the distance is Bound or less; the result is then some distance <= Bound.
    NearestAbove(C:gs_cell, Cells:[]gs_cell, Bound:int)<transacts>:int =
        var Nearest:int = 2000000000
        var K:int = 0
        loop:
            if (Nearest <= Bound):
                break
            if (X := Cells[K]):
                set K += 1
                set Nearest = Min(Nearest, Distance2(X, C))
            else:
                break
        Nearest

    # Paints the land cells within SpotRadius of C with palette index Mark (-1 = their owner again).
    MarkSeat(C:gs_cell, Mark:int):void =
        for (DI := -SpotRadius..SpotRadius, DJ := -SpotRadius..SpotRadius, DI * DI + DJ * DJ <= SpotRadius * SpotRadius, X := CellAt[C.I + DI, C.J + DJ]):
            set X.Shown = Mark
            # (A cell waiting already is painted with the new mark.)
            QueuePaint(X)

    IsHuman(N:rts_nation)<transacts>:logic =
        if (N.Human?) then true else false

    # A human, or with BotsAsPlayers a lobby bot: player troops, growth, attack priority and labels.
    # only the bots on player seats (ids 1..LobbyColors, BotOnPlayerSeat); bots above them play as bots.
    PlaysAsHuman(N:rts_nation)<transacts><decides>:void =
        Plays:logic = if (N.Human?) then true else if (not N.Tribe?, BotOnPlayerSeat[N.Id]) then true else false
        Plays?

    # With BotsAsPlayers, lobby id Id is a player seat (1..LobbyColors, the ids humans can have) and plays as a human
    # when a bot holds it.
    BotOnPlayerSeat(Id:int)<transacts><decides>:void =
        BotsAsPlayers?
        Id <= LobbyColors

    # ---------- Players leaving ----------

    # The last two nations are both human and one player leaves: the other one wins (no ragequit, no bot to beat
    # afterwards). Any other case: the leaver's nation decays and the game goes on.
    OnPlayerLeft(P:player):void =
        if (N := HumanNations[P]):
            if (N.Left? or N.Eliminated?):
                return
            Alive := for (X : NationList, not X.Eliminated?, X.Cells > 0) { X }
            Others := for (X : Alive, X.Id <> N.Id) { X }
            if (Alive.Length = 2, Other := Others[0], Winner := Other.Human?, not Other.Left?, not WinnerDeclared?):
                set N.Left = true
                EndAllAttacks(N)
                Log("{NationName(N)} left with only two nations on the map: {NationName(Other)} wins")
                DeclareWinner(Other, "the last opponent left the game")
            else:
                Abandon(N)
        else:
            # Left after the lobby but before the nations spawned.
            if (set GonePlayers[P] = true) {}

    Abandon(N:rts_nation):void =
        set N.Left = true
        EndAllAttacks(N)
        Log("{NationName(N)} left the game: the nation decays")
        spawn{ DecayLoop(N) }

    # N wins (Why = the reason shown to the players): a message on every player's screen, then the game ends.
    DeclareWinner(N:rts_nation, Why:string):void =
        if (WinnerDeclared?):
            return
        set WinnerDeclared = true
        Log("{NationName(N)} wins: {Why}")
        for (X : NationList, P := X.Human?, not X.Left?):
            Text := if (X.Id = N.Id) then "Victory! You win: {Why}." else "{NationName(N)} wins: {Why}."
            RTSCamera.SetStatus(P, Text)
        spawn{ EndGameLater(N) }

    # Leaves the message on screen for a moment, then ends the game: a human winner's team wins; a bot winner ends it
    # with no winner.
    EndGameLater(N:rts_nation)<suspends>:void =
        Sleep(3.0)
        if (Winner := N.Human?, not N.Left?):
            EndGame.Activate(Winner)
        else if (Anyone := GetPlayspace().GetPlayers()[0]):
            EndGameNoWinner.Activate(Anyone)

    # OpenFront-style decay of a left player's nation: troops drain, then the land rots away cell by cell in random
    # order (the order is fixed once from the cells it holds when the rot starts; it gains nothing anymore).
    DecayLoop(N:rts_nation)<suspends>:void =
        T0 := GetSimulationElapsedTime()
        Troops0 := N.Troops
        var Order:[]gs_cell = array{}
        var Next:int = 0
        var Built:logic = false
        loop:
            if (N.Eliminated? or N.Cells <= 0):
                break
            T := GetSimulationElapsedTime() - T0
            Target := Troops0 * (1.0 - (1.0 - AbandonTroopFloor) * Min(1.0, T / Max(0.1, AbandonDrainTime)))
            set N.Troops = Min(N.Troops, Target)
            if (T >= AbandonRotStart):
                if (not Built?):
                    set Built = true
                    # One map chunk per tick (appending cell by cell would copy the list every time).
                    var Parts:[][]gs_cell = array{}
                    var Start:int = 0
                    loop:
                        if (Start >= AllCells.Length):
                            break
                        Stop := Min(Start + 5000, AllCells.Length) - 1
                        Part := for (Index := Start..Stop, C := AllCells[Index], C.Owner = N.Id) { C }
                        set Parts += array{Part}
                        set Start = Stop + 1
                        Sleep(0.0)
                    set Order = Shuffle(for (Part : Parts, C : Part) { C })
                    Log("{NationName(N)}: {Order.Length} cells start to decay")
                Share := Clamp((T - AbandonRotStart) / Max(0.1, AbandonRotTime - AbandonRotStart), 0.0, 1.0)
                Goal := if (Share >= 1.0) then Order.Length else (Floor[Share * Order.Length] or 0)
                loop:
                    if (Next >= Goal):
                        break
                    if (C := Order[Next], C.Owner = N.Id):
                        Release(C)
                    set Next += 1
                if (Next >= Order.Length):
                    break
            Sleep(StepTime)

    Log(S:string):void =
        if (DebugLog?):
            Print("[GameSim] {S}", ?Duration := 2.0)

    # Cell coordinates for editor-axis X / Y, fails outside the grid.
    CellCoords(X:float, Y:float)<transacts><decides>:tuple(int, int) =
        I := Floor[(X - OriginX) / CellSize]
        J := Floor[(Y - OriginY) / CellSize]
        I >= 0
        I < GridWidth
        J >= 0
        J < GridHeight
        (I, J)

    CellAt(I:int, J:int)<transacts><decides>:gs_cell =
        Columns[J].Cells[I]?

    FindCell(I:int, J:int)<transacts>:?gs_cell =
        if (C := CellAt[I, J]) then option{C} else false

    NeighborOf(C:gs_cell, D:int)<transacts><decides>:gs_cell =
        if (D = 0) then CellAt[C.I - 1, C.J]
        else if (D = 1) then CellAt[C.I + 1, C.J]
        else if (D = 2) then CellAt[C.I, C.J - 1]
        else CellAt[C.I, C.J + 1]

    # Builds every land cell and the lookup from the placed tiles, BuildChunk tiles per server tick. A tile gets the
    # 2-triangle plane mesh and the shared neutral material; its land cells come from the 1/3-degree land mask
    # (rts_tile_masks, LandMask3x3.verse: 9 bits per 1-degree square).
    BuildCells()<suspends>:[]gs_cell =
        Objects := for (Object : Self.FindCreativeObjectsWithTag(rts_grid_tile)):
            Object
        for (Index -> Ch : rts_mask_alphabet):
            if (set MaskDigit[Ch] = Index) {}
        NoCell:?gs_cell = false
        TileSize := CellSize * TileCells * 1.0
        Shared := Materials.M_Tile8x8P{}
        var Chunks:[][]gs_cell = array{}
        var TileChunks:[][]gs_tile = array{}
        var Start:int = 0
        # time of each build step in the log (startup analysis).
        var Mark:float = GetSimulationElapsedTime()
        var Ticks:int = 0
        loop:
            if (Start >= Objects.Length):
                break
            Stop := Min(Start + BuildChunk, Objects.Length) - 1
            # Tile pivot is its maximum X / Y corner: tile index = pivot / tile size - 1. Editor Y = -Left.
            Tiles := for (Index := Start..Stop, Prop := creative_prop[Objects[Index]], P := Prop.GetGlobalTransform().Translation, TI := Floor[(P.Forward - OriginX) / TileSize - 0.5], TJ := Floor[(-P.Left - OriginY) / TileSize - 0.5]):
                if (UsePlanes?):
                    Prop.SetMesh(Meshes.SM_GridTilePlane_asset)
                Prop.SetMaterial(Shared)
                MakeTile(Prop, TI, TJ)
            Chunk := for (T : Tiles, C : T.Cells):
                C
            set Chunks += array{Chunk}
            set TileChunks += array{Tiles}
            set Start = Stop + 1
            set Ticks += 1
            Sleep(0.0)
        Log("Build: {Objects.Length} tiles in {Ticks} ticks, {GetSimulationElapsedTime() - Mark} s")
        set Mark = GetSimulationElapsedTime()
        # the cell lookup is built column by column from the tiles at the end. Tiles by tile row, then each column J
        # reads its cells from the tiles of row J / 8.
        AllTiles := for (Part : TileChunks, T : Part) { T }
        TileRows := Quotient[GridHeight + TileCells - 1, TileCells] or 0
        TileCols := Quotient[GridWidth + TileCells - 1, TileCells] or 0
        NoTile:?gs_tile = false
        var RowTiles:[][]?gs_tile = array{}
        for (TJ := 0..TileRows - 1):
            InRow := for (T : AllTiles, T.TJ = TJ) { T }
            RowSlots := for (TI := 0..TileCols - 1):
                var Found:?gs_tile = NoTile
                for (T : InRow, T.TI = TI):
                    set Found = option{T}
                Found
            set RowTiles += array{RowSlots}
            if (Mod[TJ, 8] = 7):
                Sleep(0.0)
        Log("Build: tile rows in {GetSimulationElapsedTime() - Mark} s")
        set Mark = GetSimulationElapsedTime()
        var Built:[]gs_column = array{}
        for (J := 0..GridHeight - 1):
            DJ := Mod[J, TileCells] or 0
            Row := RowTiles[Quotient[J, TileCells] or 0] or array{}
            ColumnCells := for (I := 0..GridWidth - 1):
                if (TO := Row[Quotient[I, TileCells] or 0], T := TO?, Slot := T.Slots[(Mod[I, TileCells] or 0) * TileCells + DJ]) then Slot else NoCell
            set Built += array{gs_column{Cells := ColumnCells}}
            if (Mod[J, 40] = 39):
                Sleep(0.0)
        set Columns = Built
        Log("Build: columns in {GetSimulationElapsedTime() - Mark} s")
        set Mark = GetSimulationElapsedTime()
        for (Chunk : Chunks):
            for (C : Chunk):
                set C.Neighbors = for (D := 0..3, N := NeighborOf[C, D]):
                    N
            Sleep(0.0)
        Log("Build: neighbors in {GetSimulationElapsedTime() - Mark} s")
        set Mark = GetSimulationElapsedTime()
        # The sampled grid of the name box sweep.
        var Sampled:[][]gs_cell = array{}
        for (Chunk : Chunks):
            Part := for (C : Chunk, Mod[C.I, 2] = 0, Mod[C.J, 2] = 0):
                set C.Far = for (X : array{FindCell(C.I - 2, C.J), FindCell(C.I + 2, C.J), FindCell(C.I, C.J - 2), FindCell(C.I, C.J + 2)}, F := X?):
                    F
                C
            set Sampled += array{Part}
            Sleep(0.0)
        set SweepCells = for (Part : Sampled, C : Part) { C }
        Log("Build: sweep grid in {GetSimulationElapsedTime() - Mark} s")
        for (Chunk : Chunks, C : Chunk):
            C

    # The land cells of tile (TI, TJ) (cell K = row * 8 + column = material parameter C<row><column>), entered in the
    # lookup.
    MakeTile(Prop:creative_prop, TI:int, TJ:int):gs_tile =
        Tile := gs_tile{Prop := Prop, TI := TI, TJ := TJ}
        NoCell:?gs_cell = false
        Slots := for (K := 0..TileCells * TileCells - 1, DI := Quotient[K, TileCells], DJ := Mod[K, TileCells], I := TI * TileCells + DI, J := TJ * TileCells + DJ):
            if (IsLand[I, J]) then option{gs_cell{I := I, J := J, Tile := Tile, K := K, Pack := Quotient[K, 3] or 0, Slot := Mod[K, 3] or 0}} else NoCell
        set Tile.Slots = Slots
        set Tile.Cells = for (S : Slots, C := S?) { C }
        Tile

    # Succeeds when cell (I, J) is land: bit (I mod 3) * 3 + (J mod 3) of the 1-degree square's mask in rts_tile_masks.
    IsLand(I:int, J:int)<transacts><decides>:void =
        I >= 0
        I < GridWidth
        J >= 0
        J < GridHeight
        Row := rts_tile_masks[Quotient[I, 3]]
        TJ := Quotient[J, 3]
        Hi := MaskDigit[Row[TJ * 2]]
        Lo := MaskDigit[Row[TJ * 2 + 1]]
        Bit := Pow2[Mod[I, 3] * 3 + Mod[J, 3]]
        Mod[Quotient[Hi * 32 + Lo, Bit], 2] = 1

    # Queues cells that are not waiting yet.
    QueuePaint(C:gs_cell):void =
        if (not C.Queued?):
            set C.Queued = true
            PaintQueue.PushOne(C)
            set QueuedCount += 1

    # queues C only when it would show another palette index than it shows now. Safe because every later change of C's
    # index queues C again: its owner (TakeCounts), a neighbor's owner (TakePaint), a war state (WarChanged, border
    # jobs), a mark (MarkSeat). The war cache is valid outside paint rounds too (WarChanged clears it).
    QueueIfChanged(C:gs_cell):void =
        if (not C.Queued?):
            if (ShownIndex(C) <> C.Painted):
                QueuePaint(C)
            else:
                set PaintSkips += 1

    # Repaints at most MaxPaintsPerTick queued cells per tick, each with its owner at paint time.
    PainterLoop()<suspends>:void =
        if (First := AllCells[0]):
            set WriteTiles = for (K := 1..MaxRoundWrites()) { First.Tile }
            set WritePacks = for (K := 1..MaxRoundWrites()) { 0 }
        loop:
            # longer rounds while the server is slow (RoundWrites scales the budget with the interval).
            set RoundWrites = if (LoadShare() < SlowLoadShare) then MaxRoundWrites() else MaxPaintsPerTick
            Sleep(if (LoadShare() < SlowLoadShare) then Max(PaintInterval, SlowPaintInterval) else PaintInterval)
            if (QueuedCount > 0):
                if (ProfileServer?):
                    profile("rts_paint"):
                        PaintSome()
                else:
                    PaintSome()

    # One paint round: queued cells update their tile's packed values; each changed parameter is written once at
    # the end of the round, at most MaxPaintsPerTick writes (cells: at most 4 x that many per round).
    PaintSome():void =
        set PaintRound += 1
        PaintNow := PaintRound
        # Writes = all parameter writes of the round (budget), Listed = the ones collected for the end of the round.
        var Writes:int = 0
        var Listed:int = 0
        var Popped:int = 0
        loop:
            if (Writes >= RoundWrites or Popped >= RoundWrites * 4):
                break
            MaybeC := PaintQueue.Pop()
            if (C := MaybeC?):
                set C.Queued = false
                set Popped += 1
                New := ShownIndex(C)
                if (New <> C.Painted):
                    T := C.Tile
                    if (T.Mat?):
                        if (Old := T.Packs[C.Pack], Mul := Tile8PackMul[C.Slot], set T.Packs[C.Pack] = Old + (New - C.Painted) * Mul):
                            set C.Painted = New
                            if (Stamp := T.PackStamp[C.Pack], Stamp <> PaintNow, set T.PackStamp[C.Pack] = PaintNow, set WriteTiles[Listed] = T, set WritePacks[Listed] = C.Pack):
                                set Listed += 1
                                set Writes += 1
                    else:
                        set Writes += FirstPaint(T)
            else:
                break
        set QueuedCount -= Popped
        set PaintedTotal += Popped
        if (ProfileServer?):
            profile("rts_paint_writes"):
                WriteParams(Listed)
        else:
            WriteParams(Listed)
        set ParamWrites += Writes

    # Writes a slow paint round may do: MaxPaintsPerTick per PaintInterval of SlowPaintInterval.
    MaxRoundWrites()<transacts>:int =
        Max(MaxPaintsPerTick, Ceil[MaxPaintsPerTick * Max(PaintInterval, SlowPaintInterval) / Max(0.01, PaintInterval)] or MaxPaintsPerTick)

    # The parameter writes collected by a paint round.
    WriteParams(Listed:int):void =
        for (W := 0..Listed - 1, T := WriteTiles[W], P := WritePacks[W], M := T.Mat?, V := T.Packs[P]):
            SetTile8Pack(M, P, V * 1.0)

    # The first change on a tile: its own material instance with every cell as it is now (a fresh instance shows all
    # cells neutral, so only other packs are written). Returns the parameters written.
    FirstPaint(T:gs_tile):int =
        set T.Packs = for (P := 1..22) { Tile8PackNeutral }
        set T.PackStamp = for (P := 1..22) { 0 }
        for (X : T.Cells):
            Index := ShownIndex(X)
            if (Index <> 1, Old := T.Packs[X.Pack], Mul := Tile8PackMul[X.Slot], set T.Packs[X.Pack] = Old + (Index - 1) * Mul) {}
            set X.Painted = Index
        M := Materials.M_Tile8x8P{}
        var Count:int = 0
        for (P -> V : T.Packs, V <> Tile8PackNeutral):
            SetTile8Pack(M, P, V * 1.0)
            set Count += 1
        T.Prop.SetMaterial(M)
        set T.Mat = option{M}
        Count

    # Palette index C shows: its mark (pick phase), 1 for neutral land, else its owner's color * 4 + its border state
    # as in OpenFront's border-compute.frag.glsl: 0 territory, 1 border (a neighbor of another owner, neutral land or
    # the sea), 2 border toward a nation at war with the owner (AtWar). State 3 (toward an ally) waits for alliances.
    # neighbors unrolled, the color from OwnerColor and the war state cached per owner pair within a paint round
    # (WarCached;
    ShownIndex(C:gs_cell)<transacts>:int =
        if (C.Shown >= 0):
            return C.Shown
        Owner := C.Owner
        if (Owner = 0):
            return 1
        var State:int = if (C.Neighbors.Length < 4) then 1 else 0
        if (X := C.Neighbors[0], Q := X.Owner, Q <> Owner):
            set State = if (Q > 0, WarCached(Owner, Q)?) then 2 else Max(State, 1)
        if (State < 2, X := C.Neighbors[1], Q := X.Owner, Q <> Owner):
            set State = if (Q > 0, WarCached(Owner, Q)?) then 2 else Max(State, 1)
        if (State < 2, X := C.Neighbors[2], Q := X.Owner, Q <> Owner):
            set State = if (Q > 0, WarCached(Owner, Q)?) then 2 else Max(State, 1)
        if (State < 2, X := C.Neighbors[3], Q := X.Owner, Q <> Owner):
            set State = if (Q > 0, WarCached(Owner, Q)?) then 2 else Max(State, 1)
        (OwnerColor[Owner] or 1) * 4 + State

    # AtWar for owners A, B (both > 0), the last answer kept for the rest of the paint round.
    WarCached(A:int, B:int)<transacts>:logic =
        if (A = WarA, B = WarB, WarRound = PaintRound):
            return WarV
        V:logic = if (AtWar[A, B]) then true else false
        set WarA = A
        set WarB = B
        set WarV = V
        set WarRound = PaintRound
        V

    # AtWar as a logic (false for neutral land).
    WarNow(A:int, B:int)<transacts>:logic =
        if (A > 0, B > 0, AtWar[A, B]) then true else false

    # Owners A and B are at war: a running land attack of one on the other.
    AtWar(A:int, B:int)<transacts><decides>:void =
        NA := NationOf[A]
        NB := NationOf[B]
        Found:logic = if (LandAttackOn(NA, B)? or LandAttackOn(NB, A)?) then true else false
        Found?

    # The war state of A and B changed: their shared border is repainted over the next ticks (BorderLoop). one job per
    # pair; a pair still waiting starts its walk over (the repaint reads the war state when it gets to a cell, so one
    # walk covers every change before it).
    WarChanged(A:int, B:int):void =
        # the cached war answer may be this pair's old state (QueueIfChanged reads it between paint rounds).
        set WarRound = -1
        if (NA := NationOf[A], NB := NationOf[B]):
            QueueBorderJob(NA, B)
            QueueBorderJob(NB, A)

    QueueBorderJob(N:rts_nation, Other:int):void =
        if (JO := N.RepaintJob[Other], Job := JO?):
            set Job.Batch = N.Border.First
            set Job.Pos = N.Border.Pos
            set BorderRestarts += 1
        else:
            Job := rts_border_job{N := N, Other := Other, Batch := N.Border.First, Pos := N.Border.Pos}
            if (set N.RepaintJob[Other] = option{Job}) {}
            if (T := BorderTail?):
                set T.Next = option{Job}
            else:
                set BorderHead = option{Job}
            set BorderTail = option{Job}
            set BorderJobCount += 1

    # Works off the border repaints, BorderRefreshPerTick border list entries per server tick.
    BorderLoop()<suspends>:void =
        loop:
            Sleep(0.0)
            var Work:int = 0
            loop:
                if (Work >= BorderRefreshPerTick):
                    break
                if (Job := BorderHead?):
                    # An eliminated nation has nothing left to repaint.
                    if (Job.N.Eliminated?):
                        set Job.Batch = false
                    else:
                        set Work += BorderStep(Job, BorderRefreshPerTick - Work)
                    if (not Job.Batch?):
                        set BorderHead = Job.Next
                        if (not BorderHead?):
                            set BorderTail = false
                        set BorderJobCount -= 1
                        NoJob:?rts_border_job = false
                        if (set Job.N.RepaintJob[Job.Other] = NoJob) {}
                else:
                    break

    # Up to MaxWork entries of Job: cells of Job.N touching Job.Other are queued for a repaint. Returns the work done.
    BorderStep(Job:rts_border_job, MaxWork:int):int =
        var Work:int = 0
        loop:
            if (Work >= MaxWork):
                break
            if (B := Job.Batch?):
                set Work += 1
                if (Job.Pos < B.Used, C := B.Cells[Job.Pos]):
                    set Job.Pos += 1
                    if (C.Owner = Job.N.Id, TouchesOwner[C, Job.Other]):
                        QueueIfChanged(C)
                        set BorderRefreshes += 1
                else:
                    set Job.Batch = B.Next
                    set Job.Pos = 0
            else:
                break
        Work

    # Share of the optional per-tick work (name box sweep, boat route search) the server does now: the adaptive
    # conquest cap's share of its maximum, at least a quarter (a slow server does less of it).
    LoadShare()<transacts>:float =
        Clamp(ConquestCap * 1.0 / (Max(1, MaxConquestsPerTick) * 1.0), 0.25, 1.0)

    # Sea cells the route search looks at in this tick (RouteNodesPerTick scaled by LoadShare).
    RouteBudget()<transacts>:int =
        Max(50, Floor[RouteNodesPerTick * 1.0 * LoadShare()] or RouteNodesPerTick)

    # A shared color for a tribe starting at Start: of the colors after the lobby's (LobbyColors + 1 .. PaletteColors)
    # the one whose nearest tribe already using it is farthest away (unused colors first), so tribes with the same
    # color are far apart.
    TribeColor(Start:gs_cell):int =
        var Nearest:[]int = for (Color := 0..PaletteColors) { 2000000000 }
        for (Index -> X : TribeStarts, Color := TribeStartColors[Index]):
            D := Distance2(X, Start)
            if (D < (Nearest[Color] or 0), set Nearest[Color] = D) {}
        for (S : Seats, S.Color > 0, X := S.Cell?):
            D := Distance2(X, Start)
            if (D < (Nearest[S.Color] or 0), set Nearest[S.Color] = D) {}
        var Best:int = LobbyColors + 1
        var BestD:int = -1
        for (Color := LobbyColors + 1..PaletteColors, D := Nearest[Color], D > BestD):
            set Best = Color
            set BestD = D
        Best

    # all nations are made before the pick phase: ids 1..Nations for the lobby (placeholders until SpawnLobby
    # puts the real nations in their place) and TribeCount tribes after them, which spawn at once, spread evenly over
    # the land (each start = the SpreadCandidates candidate farthest from the tribes before it), so players and bots
    # see them while they choose. Nations are made 10 per tick (each has a front per owner: 100 nations = 10k fronts).
    SpawnTribes()<suspends>:void =
        Count := Min(MaxNations, Nations + TribeCount)
        var Made:[]rts_nation = array{}
        for (K := 1..Count):
            Now := GetSimulationElapsedTime()
            if (K <= Nations):
                set Made += array{rts_nation{Id := K, Human := false, Slot := -1, Color := Min(K, LobbyColors)}}
            else:
                First := TribeFirst[GetRandomInt(0, TribeFirst.Length - 1)] or "Stone"
                Second := TribeSecond[GetRandomInt(0, TribeSecond.Length - 1)] or "folk"
                Tribe := rts_nation:
                    Id := K
                    Human := false
                    Slot := -1
                    Tribe := true
                    Name := First + Second
                    TriggerRatio := GetRandomFloat(0.5, 0.6)
                    ReserveRatio := GetRandomFloat(0.3, 0.4)
                    ExpandRatio := GetRandomFloat(0.1, 0.2)
                    Troops := TribeStartTroops
                    NextThink := Now + GetRandomFloat(0.0, TribeThinkMax)
                set Made += array{Tribe}
            if (Mod[K, 10] = 0):
                Sleep(0.0)
        # 204 nations x 4 tables of 205 entries; 20 nations per tick keeps the tick short.
        for (Index -> N : Made):
            InitNation(N)
            if (Mod[Index + 1, 20] = 0):
                Sleep(0.0)
        set NationList = Made
        set OwnerColor = for (Owner := 0..Count) { if (Owner = 0) then 1 else Min(Owner, LobbyColors) }
        T0 := GetSimulationElapsedTime()
        var Done:int = 0
        for (N : NationList, N.Tribe?):
            if (ProfileServer?):
                profile("rts_spawn_tribe"):
                    SpawnTribe(N)
            else:
                SpawnTribe(N)
            set Done += 1
            # TribesPerTick tribes per server tick.
            if (Mod[Done, TribesPerTick] = 0):
                Sleep(0.0)
        Log("{TribeStarts.Length} tribes spawned in {GetSimulationElapsedTime() - T0} s")

    # The best of TribeCandidates random free cells for a tribe start: the one farthest from the tribes before it.
    # FreeAround first (cheap), and the distance check stops once the candidate cannot beat the best one. the cells
    # are read from a local copy of AllCells.
    TribeStart():?gs_cell =
        Cells := AllCells
        Last := Cells.Length - 1
        var Start:?gs_cell = false
        var StartD:int = -1
        for (Try := 1..TribeCandidates, C := Cells[GetRandomInt(0, Last)], C.Owner = 0, FreeAround[C]):
            D := NearestAbove(C, TribeStarts, StartD)
            if (D > StartD):
                set Start = option{C}
                set StartD = D
        Start

    # Tribe N spawns at the best of TribeCandidates random free cells: the one farthest from the tribes before it
    # (an even spread over the land), with the tribe color its nearest same-color tribe is farthest from.
    SpawnTribe(N:rts_nation):void =
        var Start:?gs_cell = false
        if (ProfileServer?):
            profile("rts_spawn_search"):
                set Start = TribeStart()
        else:
            set Start = TribeStart()
        if (C := Start?):
            # (Before any of its cells is painted: the painter runs only between ticks.)
            Color := TribeColor(C)
            set N.Color = Color
            if (set OwnerColor[N.Id] = Color) {}
            set TribeStarts += array{C}
            set TribeStartColors += array{Color}
            # the land part profiled apart.
            if (ProfileServer?):
                profile("rts_spawn_land"):
                    SpawnAt(N, C, TribeSpawnRadius)
            else:
                SpawnAt(N, C, TribeSpawnRadius)

    # The per-owner tables of N (shared sides, land attacks, kept fronts) for every owner id 0..NationList size.
    InitNation(N:rts_nation):void =
        Count := Min(MaxNations, Nations + TribeCount)
        NoAttack:?rts_attack = false
        NoFront:?rts_front = false
        set N.Edge = for (Owner := 0..Count) { 0 }
        set N.AttackOn = for (Owner := 0..Count) { NoAttack }
        set N.Fronts = for (Owner := 0..Count) { NoFront }
        NoJob:?rts_border_job = false
        set N.RepaintJob = for (Owner := 0..Count) { NoJob }

    # N starts with Start and the free land within Radius rings around it.
    SpawnAt(N:rts_nation, Start:gs_cell, Radius:int):void =
        if (Start.Owner <> 0):
            return
        Take(N, Start)
        var Ring:[]gs_cell = array{Start}
        for (R := 1..Radius):
            set Ring = for (C : Ring, X : C.Neighbors, X.Owner = 0):
                Take(N, X)
                X

    # After the pick phase: each seat's nation (human or bot) replaces its placeholder and starts with the land within
    # SpawnRadius rings of its seat (one nation per tick: all at once made one 260-280 ms tick); lobby ids without a
    # seat stay empty (eliminated). Attacks and bots start after the last one.
    SpawnLobby()<suspends>:void =
        for (S : Seats, Start := S.Cell?):
            Now := GetSimulationElapsedTime()
            Color := SeatColor(S, Start)
            if (set OwnerColor[S.Id] = Color) {}
            N := rts_nation:
                Id := S.Id
                Human := S.Player
                Slot := -1
                Color := Color
                TriggerRatio := GetRandomFloat(0.5, 0.6)
                ReserveRatio := GetRandomFloat(0.3, 0.4)
                ExpandRatio := GetRandomFloat(0.1, 0.2)
                Troops := if (S.Player? or BotOnPlayerSeat[S.Id]) then StartTroopsPlayer else BotStartTroops
                NextThink := Now + GetRandomFloat(0.0, BotThinkMax)
            InitNation(N)
            if (set NationList[S.Id - 1] = N) {}
            if (P := S.Player?, set HumanNations[P] = N) {}
            SpawnAt(N, Start, SpawnRadius)
            Sleep(0.0)
        for (N : NationList, not N.Tribe?, N.Cells <= 0):
            set N.Eliminated = true
        # Players who left between their seat and now: their nations decay right away.
        for (N : NationList, P := N.Human?, GonePlayers[P]):
            Abandon(N)
        Spawned := for (N : NationList, not N.Eliminated?) { N }.Length
        Log("{Spawned} nations on the map ({TribeStarts.Length} tribes)")

    # Succeeds when the cells within 2 steps of C are all free land (and C has 4 land neighbors).
    FreeAround(C:gs_cell)<transacts><decides>:void =
        C.Neighbors.Length = 4
        for (X : C.Neighbors):
            X.Owner = 0
            for (Y : X.Neighbors):
                Y.Owner = 0

    NationOf(Owner:int)<transacts><decides>:rts_nation =
        NationList[Owner - 1]

    # OpenFront troopCap: 2 * (tiles^0.6 * 1000 + 50000), AI nations times BotMaxTroopsFactor.
    MaxTroops(N:rts_nation)<transacts>:float =
        Cap := 2.0 * (PowF(N.Cells * TilesPerCell, 0.6) * 1000.0 + 50000.0)
        if (PlaysAsHuman[N]) then Cap else if (N.Tribe?) then Cap * TribeMaxTroopsFactor else Cap * BotMaxTroopsFactor

    # X^E for X >= 0 (0 for X <= 0).
    PowF(X:float, E:float)<transacts>:float =
        if (X <= 0.0) then 0.0 else Exp(E * Ln(X))

    # OpenFront sigmoid(ln n, 2.5, ln 300000) = 1 / (1 + (300000 / n)^2.5): ~0 for small nations, 0.5 at 300k tiles
    BigNation(Cells:int)<transacts>:float =
        1.0 / (1.0 + PowF(300000.0 / Max(1.0, Cells * TilesPerCell), 2.5))

    # C has a neighbor owned by Id (stops at the first).
    TouchesOwner(C:gs_cell, Id:int)<transacts><decides>:void =
        if (X := C.Neighbors[0], X.Owner = Id) {}
        else if (X := C.Neighbors[1], X.Owner = Id) {}
        else if (X := C.Neighbors[2], X.Owner = Id) {}
        else:
            X := C.Neighbors[3]
            X.Owner = Id

    # OwnNeighbors without a for (benchmark candidate).
    OwnNeighborsFast(C:gs_cell, Id:int)<transacts>:int =
        var K:int = 0
        if (X := C.Neighbors[0], X.Owner = Id) { set K += 1 }
        if (X := C.Neighbors[1], X.Owner = Id) { set K += 1 }
        if (X := C.Neighbors[2], X.Owner = Id) { set K += 1 }
        if (X := C.Neighbors[3], X.Owner = Id) { set K += 1 }
        K

    # unrolled like OwnNeighborsFast (a cell has at most 4 neighbors); the for loop cost more per key push.
    OwnNeighbors(C:gs_cell, Id:int)<transacts>:int =
        var K:int = 0
        if (X := C.Neighbors[0], X.Owner = Id) { set K += 1 }
        if (X := C.Neighbors[1], X.Owner = Id) { set K += 1 }
        if (X := C.Neighbors[2], X.Owner = Id) { set K += 1 }
        if (X := C.Neighbors[3], X.Owner = Id) { set K += 1 }
        K

    # OpenFront attack order (AttackExecution.addNeighbors): key = random 10..16 * (1 - 0.5 * own neighbors + terrain
    # / 2) + the OpenFront tick (0.1 s) the cell was found at (terrain: plains 1, highland 1.5, mountain 2), lowest
    # first. Cells found earlier go first, so an attack rolls along the whole border as a wave; dents fill first,
    # rough terrain later.
    AttackKey(C:gs_cell, Own:int):int =
        M4 := if (C.Terrain = 2) then 4 else if (C.Terrain = 1) then 3 else 2
        set RollAt += 1
        if (RollAt >= RollCount):
            set RollAt = 0
        Roll := RollTable[RollAt] or 13
        KeyTick + Roll * (4 - 2 * Own + M4)

    # AttackKey(C, OwnNeighbors(C, Id)) in one call (the key pushes of TakeSides, one call less per push).
    KeyFor(C:gs_cell, Id:int):int =
        var Own:int = 0
        if (X := C.Neighbors[0], X.Owner = Id) { set Own += 1 }
        if (X := C.Neighbors[1], X.Owner = Id) { set Own += 1 }
        if (X := C.Neighbors[2], X.Owner = Id) { set Own += 1 }
        if (X := C.Neighbors[3], X.Owner = Id) { set Own += 1 }
        M4 := if (C.Terrain = 2) then 4 else if (C.Terrain = 1) then 3 else 2
        set RollAt += 1
        if (RollAt >= RollCount):
            set RollAt = 0
        Roll := RollTable[RollAt] or 13
        KeyTick + Roll * (4 - 2 * Own + M4)

    # N's running land attack on Target, if any.
    LandAttackOn(N:rts_nation, Target:int)<transacts>:?rts_attack =
        if (AO := N.AttackOn[Target]) then AO else false

    # Succeeds when N borders owner Id (0 = neutral land).
    Borders(N:rts_nation, Id:int)<transacts><decides>:void =
        E := N.Edge[Id]
        E > 0

    # Shared cell sides of owners A and B (B <> A) change by D (both nations' counts; neutral keeps none).
    AddEdge(A:int, B:int, D:int):void =
        if (NA := NationOf[A], V := NA.Edge[B], set NA.Edge[B] = V + D) {}
        if (NB := NationOf[B], V := NB.Edge[A], set NB.Edge[A] = V + D) {}

    # C (owned by N) goes into N's border list unless it is there already. A list much longer than the nation (stale
    # entries) gets a compaction scan.
    AddBorder(N:rts_nation, C:gs_cell):void =
        if (not C.InBorder?):
            set C.InBorder = true
            N.Border.PushOne(C)
            set FrontPushes += 1
            if (N.Border.Count > N.Cells * 2 + 256, not N.Scanning?):
                StartScan(N)

    # Gives C to N: cell counts and centers, coast, repaint, shared sides, border lists and the attack fronts that
    # change. in three parts, profiled apart on a sampled call (rts_s_take_counts / _paint / _sides).
    Take(N:rts_nation, C:gs_cell):void =
        OldId := C.Owner
        set CellsTaken += 1
        if (not TakeCtx.Batched? or TakeCtx.NId <> N.Id or TakeCtx.OldId <> OldId):
            PrepareTake(N, OldId)
        Sampled := SampleNow()
        if (Sampled?):
            profile("rts_s_take_counts"):
                TakeCounts(N, C, OldId)
            profile("rts_s_take_paint"):
                TakePaint(N, C, OldId)
            profile("rts_s_take_sides"):
                TakeSides(N, C, OldId)
        else:
            TakeCounts(N, C, OldId)
            TakePaint(N, C, OldId)
            TakeSides(N, C, OldId)

    # Take: coast, cell counts and centers, the cell's own repaint.
    TakeCounts(N:rts_nation, C:gs_cell, OldId:int):void =
        if (C.Neighbors.Length < 4):
            CoastMove(C, N.Id)
        if (Old := TakeCtx.Old?):
            set Old.Cells -= 1
            set Old.SumI -= C.I
            set Old.SumJ -= C.J
            # the last cell brings the old owner's gold, half of a human's.
            if (Old.Cells <= 0, Old.Gold > 0.0):
                Loot := if (Old.Human?) then Old.Gold * 0.5 else Old.Gold
                set N.Gold += Loot
                set Old.Gold -= Loot
        set C.Owner = N.Id
        set C.InBorder = false
        set N.Cells += 1
        set N.SumI += C.I
        set N.SumJ += C.J
        set ChangedTotal += 1
        QueuePaint(C)

    # Take: the neighbors' repaints.
    TakePaint(N:rts_nation, C:gs_cell, OldId:int):void =
        # the owned neighbors may gain or lose their border. a third owner's neighbor was a border cell already and
        # changes only when its war state toward N differs from the one toward the old owner. an old owner's cell that
        # already shows the war border (palette state 2, its last paint) keeps it: C was its own owner's cell, so the
        # war state comes from another neighbor. One Mod on a stored int, no ShownIndex. Safe only when not queued
        # (else Painted may be old) and without a pick mark (Shown).
        for (X : C.Neighbors, Q := X.Owner, Q > 0):
            if (Q = OldId, not X.Queued?, X.Shown < 0, Mod[X.Painted, 4] = 2):
                set TakeSkips += 1
            else if (Q = N.Id or Q = OldId):
                QueuePaint(X)
            else if (WarNow(Q, N.Id) <> WarNow(Q, OldId)):
                QueuePaint(X)

    # Fills TakeCtx for cells of OldId that N takes.
    PrepareTake(N:rts_nation, OldId:int):void =
        set TakeCtx.NId = N.Id
        set TakeCtx.OldId = OldId
        set TakeCtx.Batched = false
        set TakeCtx.EdgeD = 0
        set TakeCtx.Old = if (OldId > 0, O := NationOf[OldId]) then option{O} else false
        set TakeCtx.Front = if (AO := N.AttackOn[OldId], A := AO?) then option{A.Front} else false
        set TakeCtx.Counter = if (O := TakeCtx.Old?, BO := O.AttackOn[N.Id], B := BO?) then option{B.Front} else false

    # An attack run of N on OldId starts taking cells: the lookups once, the shared sides batched.
    BeginTakes(N:rts_nation, OldId:int):void =
        PrepareTake(N, OldId)
        set TakeCtx.Batched = true

    # The run is over: the batched shared sides are written, the lookups are dropped (fronts may change after it).
    EndTakes():void =
        if (TakeCtx.Batched?, TakeCtx.EdgeD <> 0):
            AddEdge(TakeCtx.NId, TakeCtx.OldId, TakeCtx.EdgeD)
        set TakeCtx.Batched = false
        set TakeCtx.EdgeD = 0
        set TakeCtx.NId = -1

    # Take: shared sides, border lists and the attack fronts. it may be attacked next and gets a border) or a third
    # owner's (ThirdSide). The sides of N and the old owner change by one net amount (OldSides - OwnSides).
    TakeSides(N:rts_nation, C:gs_cell, OldId:int):void =
        var OwnSides:int = 0
        var OldSides:int = 0
        var Others:int = 0
        if (X := C.Neighbors[0]):
            Q0 := X.Owner
            if (Q0 = N.Id) then set OwnSides += 1
            else if (Q0 = OldId) then { set OldSides += 1; OldSide(N, X) }
            else { set Others += 1; ThirdSide(N, C, OldId, X) }
        if (X := C.Neighbors[1]):
            Q1 := X.Owner
            if (Q1 = N.Id) then set OwnSides += 1
            else if (Q1 = OldId) then { set OldSides += 1; OldSide(N, X) }
            else { set Others += 1; ThirdSide(N, C, OldId, X) }
        if (X := C.Neighbors[2]):
            Q2 := X.Owner
            if (Q2 = N.Id) then set OwnSides += 1
            else if (Q2 = OldId) then { set OldSides += 1; OldSide(N, X) }
            else { set Others += 1; ThirdSide(N, C, OldId, X) }
        if (X := C.Neighbors[3]):
            Q3 := X.Owner
            if (Q3 = N.Id) then set OwnSides += 1
            else if (Q3 = OldId) then { set OldSides += 1; OldSide(N, X) }
            else { set Others += 1; ThirdSide(N, C, OldId, X) }
        D := OldSides - OwnSides
        if (D <> 0):
            if (TakeCtx.Batched?) then set TakeCtx.EdgeD += D else AddEdge(N.Id, OldId, D)
        if (OldSides > 0):
            # The old owner's land attack on N gets C (C touches OldSides of its cells).
            if (B := TakeCtx.Counter?, not B.Has[C]):
                B.PushNew(C, AttackKey(C, OldSides))
                set KeyPushes += 1
        if (OldSides + Others > 0):
            AddBorder(N, C)

    # Neighbor X of the old owner: N's land attack on it may take X next; X is now a border cell of its owner.
    OldSide(N:rts_nation, X:gs_cell):void =
        if (F := TakeCtx.Front?, not F.Has[X]):
            F.PushNew(X, KeyFor(X, N.Id))
            set KeyPushes += 1
        if (Old := TakeCtx.Old?):
            AddBorder(Old, X)

    # Neighbor X of a third owner Q: the sides
    # old owner - Q go, N - Q come; N's land attack on Q and Q's on N may get X / C.
    ThirdSide(N:rts_nation, C:gs_cell, OldId:int, X:gs_cell):void =
        Q := X.Owner
        AddEdge(OldId, Q, -1)
        AddEdge(N.Id, Q, 1)
        if (AO := N.AttackOn[Q], A := AO?, not A.Front.Has[X]):
            A.Front.PushNew(X, KeyFor(X, N.Id))
            set KeyPushes += 1
        if (Y := NationOf[Q]):
            AddBorder(Y, X)
            if (BO := Y.AttackOn[N.Id], B := BO?, not B.Front.Has[C]):
                B.Front.PushNew(C, KeyFor(C, Q))
                set KeyPushes += 1

    # ProfileServer: true for one call in ProfileSample. Call it outside a failure context (an `if` that fails rolls
    # the count back).
    SampleNow()<transacts>:logic =
        if (not ProfileServer?):
            return false
        set SampleCount += 1
        if (Mod[SampleCount, ProfileSample] = 0) then true else false

    # Coastal cell C goes to owner NewId (0 = neutral): the owner counts of the sea cells around it and the nations'
    # coastal cell counts.
    CoastMove(C:gs_cell, NewId:int):void =
        TI := Quotient[C.I, 3] or 0
        TJ := Quotient[C.J, 3] or 0
        var HasSea:logic = false
        for (DI := -1..1, DJ := -1..1, S := SeaAt[TI + DI, TJ + DJ]):
            set HasSea = true
            if (V := S.Owners[C.Owner], set S.Owners[C.Owner] = V - 1) {}
            if (V := S.Owners[NewId], set S.Owners[NewId] = V + 1) {}
            if (S.Owners.Length > 0, Node := RouteNodes[S.Node]):
                if (V := Node.Owners[C.Owner], set Node.Owners[C.Owner] = V - 1) {}
                if (V := Node.Owners[NewId], set Node.Owners[NewId] = V + 1) {}
        if (HasSea?):
            if (Old := NationOf[C.Owner]):
                set Old.CoastCells -= 1
            if (New := NationOf[NewId]):
                set New.CoastCells += 1

    # C becomes neutral land again (territory decay of a nation whose player left): counts, coast, repaint, shared
    # sides, the neighbors' border lists and their attacks on neutral land.
    Release(C:gs_cell):void =
        OldId := C.Owner
        if (OldId = 0):
            return
        if (C.Neighbors.Length < 4):
            CoastMove(C, 0)
        if (Old := NationOf[OldId]):
            set Old.Cells -= 1
            set Old.SumI -= C.I
            set Old.SumJ -= C.J
        set C.Owner = 0
        set C.InBorder = false
        set ChangedTotal += 1
        QueuePaint(C)
        for (X : C.Neighbors):
            Q := X.Owner
            if (Q <> OldId):
                AddEdge(OldId, Q, -1)
            if (Q <> 0):
                if (Q = OldId or WarNow(Q, OldId)?):
                    QueuePaint(X)
                AddEdge(0, Q, 1)
                if (Y := NationOf[Q]):
                    AddBorder(Y, X)
                    if (AO := Y.AttackOn[0], A := AO?):
                        A.Front.Push(C, AttackKey(C, OwnNeighbors(C, Q)))

    # Starts a border scan of N for its waiting attacks (or a compaction): at once when the border list is short,
    # else queued for RebuildLoop (RebuildWorkPerTick entries per tick; the attacks wait).
    StartScan(N:rts_nation):void =
        if (N.Scanning?):
            return
        set N.Scanning = true
        set RebuildsDone += 1
        Job := rts_scan_job{N := N, Id := N.NextScan}
        set N.NextScan += 1
        if (N.Border.Count > RebuildWorkPerTick):
            set RebuildJobs += array{Job}
        else:
            if (ProfileServer?):
                profile("rts_rebuild"):
                    RunScanNow(Job)
            else:
                RunScanNow(Job)

    RunScanNow(Job:rts_scan_job):void =
        loop:
            Done := ScanStep(Job, 1000000)
            if (Done <= 0):
                break
        FinishScan(Job)

    # Up to MaxWork entries of a scan. Phase 0: the border list empties itself; a valid border cell (still N's, still
    # with a foreign neighbor, first time in this scan) puts its neighbors that a waiting attack targets into that
    # attack's front and goes to Valid; phase 1: Valid back into the list; phase 2: done. Returns the entries handled
    # (0 = done).
    ScanStep(Job:rts_scan_job, MaxWork:int):int =
        N := Job.N
        var Work:int = 0
        loop:
            if (Work >= MaxWork or Job.Phase >= 2):
                break
            set Work += 1
            if (Job.Phase = 0):
                MaybeC := N.Border.Pop()
                if (C := MaybeC?):
                    set RebuildEntries += 1
                    if (C.Owner = N.Id, C.InBorder?, C.Rekey <> Job.Id):
                        set C.Rekey = Job.Id
                        var Foreign:logic = false
                        for (X : C.Neighbors, X.Owner <> N.Id):
                            set Foreign = true
                            if (AO := N.AttackOn[X.Owner], A := AO?, A.Front.Pending?, A.Front.WaitJob <= Job.Id):
                                A.Front.Push(X, AttackKey(X, OwnNeighbors(X, N.Id)))
                        if (Foreign?):
                            Job.Valid.PushOne(C)
                            set Job.Kept += 1
                        else:
                            set C.InBorder = false
                else:
                    set Job.Phase = 1
            else:
                MaybeC := Job.Valid.Pop()
                if (C := MaybeC?):
                    N.Border.PushOne(C)
                else:
                    set Job.Phase = 2
        if (Job.Phase >= 2) then 0 else Work

    # The attacks this scan filled may run; attacks launched during the scan need another one.
    FinishScan(Job:rts_scan_job):void =
        N := Job.N
        set N.Scanning = false
        var Again:logic = false
        for (A : N.Attacks, A.Front.Pending?):
            if (A.Front.WaitJob <= Job.Id):
                set A.Front.Pending = false
            else:
                set Again = true
        if (Again?):
            StartScan(N)

    # Runs the queued long scans, RebuildWorkPerTick entries per tick, oldest first.
    RebuildLoop()<suspends>:void =
        loop:
            Sleep(0.0)
            if (RebuildJobs.Length > 0):
                if (ProfileServer?):
                    profile("rts_rebuild_queued"):
                        RunRebuildJobs()
                else:
                    RunRebuildJobs()

    RunRebuildJobs():void =
        var Left:int = RebuildWorkPerTick
        loop:
            if (Left <= 0):
                break
            if (Job := RebuildJobs[0]):
                Used := ScanStep(Job, Left)
                set Left -= Used
                if (Used <= 0):
                    set RebuildJobs = RebuildJobs.Slice[1] or array{}
                    FinishScan(Job)
            else:
                break

    # Troops in N's running attacks.
    AttackTroopsOf(N:rts_nation)<transacts>:float =
        var Sum:float = 0.0
        for (A : N.Attacks, not A.Done?):
            set Sum += A.Troops
        Sum

    # OpenFront AttackExecution.init: N attacks Target with Troops already taken from the nation. Attacks of Target on
    # N cancel out first (the larger side keeps the difference). A land attack (Landing false) joins N's running land
    # attack on Target if there is one (troops added, front reordered); a boat attack starts from Landing (taken by
    # N already) and grows only from there. When nothing of Target borders the attack the troops come back. True
    # when the troops went into an attack (or were spent cancelling one out).
    LaunchAttack(N:rts_nation, Target:int, Troops:float, Landing:?gs_cell):logic =
        var Rest:float = Troops
        if (Def := NationOf[Target]):
            for (X : Def.Attacks, not X.Done?, X.Target = N.Id):
                if (Rest <= 0.0):
                    # Nothing left to cancel with.
                else if (X.Troops > Rest):
                    set X.Troops -= Rest
                    set Rest = 0.0
                else:
                    set Rest -= X.Troops
                    set X.Troops = 0.0
                    set X.Done = true
        if (Rest <= 0.0):
            true
        else if (Shore := Landing?):
            Front := rts_front{}
            for (X : Shore.Neighbors, X.Owner = Target):
                Front.Push(X, AttackKey(X, OwnNeighbors(X, N.Id)))
            if (Front.Count > 0):
                set N.Attacks += array{rts_attack{Target := Target, Front := Front, Beach := option{Front}, Troops := Rest, Labeled := WantsLabel(N, Target)}}
                true
            else:
                set N.Troops += Rest
                false
        else if (Old := LandAttackOn(N, Target)?, not Old.Done?):
            set Old.Troops += Rest
            true
        else if (Borders[N, Target]):
            # The front kept for this target (made the first time), filled by a border scan; the attack waits for it.
            Front := if (FO := N.Fronts[Target], F := FO?) then F else rts_front{}
            Front.Clear()
            if (set N.Fronts[Target] = option{Front}) {}
            set Front.Pending = true
            set Front.WaitJob = N.NextScan
            WasWar:logic = if (AtWar[N.Id, Target]) then true else false
            A := rts_attack{Target := Target, Front := Front, Troops := Rest, Labeled := WantsLabel(N, Target)}
            set N.Attacks += array{A}
            if (set N.AttackOn[Target] = option{A}) {}
            if (Target > 0, not WasWar?):
                WarChanged(N.Id, Target)
            StartScan(N)
            true
        else:
            set N.Troops += Rest
            false

    # N attacks Target over land with Share of its troops (menu Attack button, bots). True when an attack runs.
    AttackWithShare(N:rts_nation, Target:int, Share:float):logic =
        Troops := N.Troops * Share
        if (Troops < 1.0 or Target = N.Id):
            return false
        set N.Troops -= Troops
        LaunchAttack(N, Target, Troops, false)

    # The attack ends and its troops come back to the nation.
    EndAttack(N:rts_nation, A:rts_attack)<transacts>:void =
        set N.Troops += A.Troops
        set A.Troops = 0.0
        set A.Done = true

    EndAllAttacks(N:rts_nation):void =
        Targets := for (A : N.Attacks, not A.Done?, A.Target > 0, not A.Beach?) { A.Target }
        for (A : N.Attacks):
            EndAttack(N, A)
        NoAttack:?rts_attack = false
        set N.AttackOn = for (X : N.AttackOn) { NoAttack }
        set N.Attacks = array{}
        for (T : Targets, not AtWar[N.Id, T]):
            WarChanged(N.Id, T)

    # attacks a human makes, or receives from a nation (not a tribe; OpenFront skips incoming bot attacks), on another
    # nation get an attack label.
    WantsLabel(N:rts_nation, Target:int)<transacts>:logic =
        if (Target <= 0) then false
        else if (PlaysAsHuman[N]) then true
        else if (not N.Tribe?, Def := NationOf[Target], PlaysAsHuman[Def]) then true
        else false

    GameLoop()<suspends>:void =
        loop:
            T0 := GetSimulationElapsedTime()
            # Nations are spread over a few ticks to keep each tick short.
            var Index:int = 0
            loop:
                if (N := NationList[Index]):
                    if (not N.Eliminated?, not N.Left?):
                        Grow(N)
                        Now := GetSimulationElapsedTime()
                        if (not N.Human?, Now >= N.NextThink):
                            set N.NextThink = Now + (if (N.Tribe?) then GetRandomFloat(TribeThinkMin, TribeThinkMax) else if (BotOnPlayerSeat[N.Id]) then GetRandomFloat(PlayerBotThinkMin, PlayerBotThinkMax) else GetRandomFloat(BotThinkMin, BotThinkMax))
                            set BotDecisions += 1
                            if (not ProfileServer?):
                                Think(N)
                            else if (N.Tribe?):
                                profile("rts_tribe"):
                                    Think(N)
                            else:
                                profile("rts_bot"):
                                    Think(N)
                    set Index += 1
                    if (Mod[Index, 12] = 0):
                        Sleep(0.0)
                else:
                    break
            for (N : NationList, not N.Eliminated?, N.Cells <= 0):
                set N.Eliminated = true
                # The attacks of an eliminated nation are gone (nothing comes back; Done frees their labels).
                for (A : N.Attacks):
                    set A.Done = true
                set N.Attacks = array{}
                NoAttack:?rts_attack = false
                set N.AttackOn = for (X : N.AttackOn) { NoAttack }
                Log("Nation {N.Id} eliminated")
                # The player keeps the camera and watches the rest of the game.
                if (P := N.Human?, not N.Left?):
                    if (Menu := Menus[P]):
                        Menu.Hide(P)
                    if (Panel := Panels[P]):
                        Panel.Hide(P)
                    RTSCamera.SetStatus(P, "Your nation was eliminated. You can keep watching the map.")
            if (not WinLogged?, Best := Largest[], Best.Cells * 1.0 > WinShare * LandCells):
                set WinLogged = true
                Log("Nation {Best.Id} holds {Best.Cells} of {LandCells} cells")
                DeclareWinner(Best, "{Floor[WinShare * 100.0 + 0.5] or 80} % of the land conquered")
            Elapsed := GetSimulationElapsedTime() - T0
            Sleep(Max(0.0, StepTime - Elapsed))

    Grow(N:rts_nation):void =
        # OpenFront troopIncreaseRate, once per OpenFront tick (0.1 s) of this game step.
        Cap := MaxTroops(N)
        Factor := if (PlaysAsHuman[N]) then 1.0 else if (N.Tribe?) then TribeGrowthFactor else BotGrowthFactor
        Ticks := StepTime / 0.1
        # the OpenFront ticks of this step in one go (troops change little within 0.5 s; was one PowF each).
        ToAdd := (10.0 + PowF(N.Troops, 0.73) / 4.0) * (1.0 - N.Troops / Cap) * Factor * Ticks
        set N.Troops = Max(0.0, Min(N.Troops + ToAdd, Cap))
        set N.BigS = BigNation(N.Cells)
        set N.Gold += (if (N.Tribe?) then TribeGoldPerTick else GoldPerTick) * Ticks

    # Troops N gains per second now (OpenFront troopIncreaseRate * 10, the panel's +x/s).
    GrowthPerSecond(N:rts_nation)<transacts>:float =
        Cap := MaxTroops(N)
        Factor := if (PlaysAsHuman[N]) then 1.0 else if (N.Tribe?) then TribeGrowthFactor else BotGrowthFactor
        (10.0 + PowF(N.Troops, 0.73) / 4.0) * (1.0 - N.Troops / Cap) * Factor * 10.0

    # The share of the troops an Attack or Boat press of N sends.
    RatioOf(N:rts_nation)<transacts>:float =
        if (N.AttackRatio > 0.0) then N.AttackRatio else AttackShare

    Think(N:rts_nation):void =
        if (N.Tribe?):
            set TribeDecisions += 1
            TribeAttack(N)
        else if (BotOnPlayerSeat[N.Id]):
            PlayerBotAttack(N)
        else:
            BotAttack(N)

    # Tribe decision every TribeThinkMin..TribeThinkMax s: free land next to it, keeping ExpandRatio of its maximum
    # troops at home (OpenFront TribeExecution's expansion). once no free land touches it, it only grows troops and
    # defends.
    TribeAttack(N:rts_nation):void =
        if (not N.NeutralNear?):
            return
        if (Borders[N, 0]):
            SendTroops(N, 0, N.Troops - MaxTroops(N) * N.ExpandRatio)
        else:
            set N.NeutralNear = false

    # A tribe's or bot's land attack with Troops (nothing below 1). True when it runs.
    SendTroops(N:rts_nation, Target:int, Troops:float):logic =
        if (Troops < 1.0 or Troops > N.Troops):
            return false
        set N.Troops -= Troops
        if (N.Tribe?):
            set TribeAttacks += 1
        LaunchAttack(N, Target, Troops, false)

    # Bot decision every BotThinkMin..BotThinkMax s (OpenFront NationAttackBehavior.chooseAttack / attackBestTarget,
    # Medium): free land next to it first; else, with no nation next to it, now and then a random boat
    # (BotBoatChanceAlone); at war a random boat instead of a land attack with BotBoatChanceAtWar. Land attacks on
    # nations wait for ReserveRatio of the maximum troops at home; then the nation attacking it with the most troops
    # first (Medium retaliate), else, with TriggerRatio troops (or BotTriggerChance), the weakest neighbor it has
    # AttackRatio times the troops of, or the weakest at all once its army is full. A new attack on a target already
    # attacked adds to that attack.
    BotAttack(N:rts_nation):void =
        if (N.Troops < MinAttackTroops):
            return
        Cap := MaxTroops(N)
        if (Borders[N, 0]):
            Started := SendTroops(N, 0, N.Troops - Cap * N.ExpandRatio)
            if (Started?):
                return
        Enemies := for (Y : NationList, Y.Id <> N.Id, not Y.Eliminated?, Borders[N, Y.Id]) { Y }
        if (Enemies.Length = 0):
            if (GetRandomFloat(0.0, 1.0) < BotBoatChanceAlone):
                RandomBoat(N)
            return
        if (GetRandomFloat(0.0, 1.0) < BotBoatChanceAtWar):
            RandomBoat(N)
            return
        if (N.Troops < Cap * N.ReserveRatio):
            return
        var Hit:int = 0
        var HitTroops:float = 0.0
        for (Y : Enemies, A : Y.Attacks, not A.Done?, A.Target = N.Id, A.Troops > HitTroops):
            set Hit = Y.Id
            set HitTroops = A.Troops
        if (Hit > 0, Y := NationOf[Hit]):
            SendTroops(N, Hit, N.Troops - Cap * (if (Y.Tribe?) then N.ExpandRatio else N.ReserveRatio))
            return
        if (N.Troops < Cap * N.TriggerRatio and GetRandomFloat(0.0, 1.0) >= BotTriggerChance):
            return
        Full:logic = if (N.Troops >= FullArmyShare * Cap) then true else false
        var Target:?rts_nation = false
        for (Y : Enemies, Full? or N.Troops >= Y.Troops * AttackRatio):
            if (T := Target?):
                if (Y.Troops < T.Troops):
                    set Target = option{Y}
            else:
                set Target = option{Y}
        if (T := Target?):
            SendTroops(N, T.Id, N.Troops - Cap * (if (T.Tribe?) then N.ExpandRatio else N.ReserveRatio))

    # A bot playing as an active human: every decision sends AttackShare of its troops (the player's slider) into free
    # land next to it, and AttackShare into a neighbor nation or tribe (the weakest or a random one, half and half),
    # like a player clicking the menu's Attack button; without a neighbor, now and then a random boat as the bots do.
    # OpenFront growth is fastest near 40 %, where a player waits).
    PlayerBotAttack(N:rts_nation):void =
        if (N.Troops < MinAttackTroops or N.Troops < PlayerBotMinArmy * MaxTroops(N)):
            return
        if (Borders[N, 0]):
            SendTroops(N, 0, N.Troops * AttackShare)
        Enemies := for (Y : NationList, Y.Id <> N.Id, not Y.Eliminated?, Borders[N, Y.Id]) { Y }
        if (Enemies.Length = 0):
            if (GetRandomFloat(0.0, 1.0) < BotBoatChanceAlone):
                RandomBoat(N)
            return
        if (GetRandomFloat(0.0, 1.0) < BotBoatChanceAtWar):
            RandomBoat(N)
        var Target:?rts_nation = false
        if (GetRandomFloat(0.0, 1.0) < 0.5):
            for (Y : Enemies):
                if (T := Target?):
                    if (Y.Troops < T.Troops):
                        set Target = option{Y}
                else:
                    set Target = option{Y}
        else if (Y := Enemies[GetRandomInt(0, Enemies.Length - 1)]):
            set Target = option{Y}
        if (T := Target?):
            SendTroops(N, T.Id, N.Troops * AttackShare)

    # OpenFront attackWithRandomBoat / findRandomBoatTarget: a boat to a random land cell within BotBoatRange cells
    # of N's center, free land first (500 tries), else also nations N does not border and that have no more troops
    # than N (500 tries). A busy route search skips the boat (the next decision may send one).
    RandomBoat(N:rts_nation):void =
        if (N.Boats >= MaxBoatsPerNation or N.CoastCells <= 0 or N.Troops < BotBoatTroops or RouteBusy?):
            return
        Cells := Max(1, N.Cells) * 1.0
        CI := Floor[N.SumI * 1.0 / Cells] or 0
        CJ := Floor[N.SumJ * 1.0 / Cells] or 0
        var Goal:?gs_cell = false
        for (Pass := 0..1, not Goal?):
            for (Try := 1..500, not Goal?):
                I := CI + GetRandomInt(-BotBoatRange, BotBoatRange)
                J := CJ + GetRandomInt(-BotBoatRange, BotBoatRange)
                if (C := CellAt[I, J], C.Owner <> N.Id, BoatGoalOk(N, C, Pass)?):
                    set Goal = option{C}
        if (C := Goal?):
            spawn{ SendBoat(N, C) }

    # Pass 0: free land only; pass 1: also a nation N does not border and that has no more troops than N.
    BoatGoalOk(N:rts_nation, C:gs_cell, Pass:int)<transacts>:logic =
        if (C.Owner = 0) then true
        else if (Pass = 1, Y := NationOf[C.Owner], not Y.Eliminated?, not Borders[N, C.Owner], Y.Troops <= N.Troops) then true
        else false

    # Every server tick: each running attack advances by its speed * tick time, all together at most ConquestCap
    # cells. The cap adapts to the server: a tick slower than SlowTickMs lowers it by 2, a faster one raises it by 1.
    # The first nation served rotates, so no nation always waits.
    AttackLoop()<suspends>:void =
        var Last:float = GetSimulationElapsedTime()
        var First:int = 0
        set ConquestCap = Clamp(12, MinConquestsPerTick, MaxConquestsPerTick)
        loop:
            Sleep(0.0)
            Now := GetSimulationElapsedTime()
            Tick := Now - Last
            set Last = Now
            if (Tick * 1000.0 > SlowTickMs):
                set ConquestCap = Max(MinConquestsPerTick, ConquestCap - 2)
            else:
                set ConquestCap = Min(MaxConquestsPerTick, ConquestCap + 1)
            set KeyTick = (Floor[Now * 10.0] or 0) * 4
            # One table entry rerolled per tick (~2 us): the table never repeats as a fixed 64-key cycle.
            if (set RollTable[Mod[First, RollCount] or 0] = GetRandomInt(10, 16)) {}
            if (ProfileServer?):
                profile("rts_attacks"):
                    RunAllAttacks(Now, First, Tick)
            else:
                RunAllAttacks(Now, First, Tick)
            set First += 1

    # One server tick of the attacks, starting with nation First (rotating). bots every second tick, tribes every
    # TribeAttackPeriod ticks, each over the time since its last run and with the per-attack caps times its period, at
    # most ConquestCap cells (neutral: TickNeutral) for all of them together. the humans' attacks share
    # HumanCellsPerSecond * the tick time (at most 0.1 s) in proportion to what each wants this tick (AttackWant);
    # while they want less than that, each gets all it wants.
    RunAllAttacks(Now:float, First:int, Tick:float):void =
        set TickBudget = ConquestCap
        set TickNeutral = Max(1, Floor[MaxNeutralConquestsPerTick * ConquestCap * 1.0 / (Max(1, MaxConquestsPerTick) * 1.0)] or 1)
        Humans := for (N : NationList, PlaysAsHuman[N], not N.Eliminated?) { N }
        TickTime := Clamp(Tick, 0.0, 0.1)
        Budget := HumanCellsPerSecond * TickTime
        # while the server is slow each human attack runs every second tick with twice the cells.
        HumanPeriod := if (LoadShare() < SlowLoadShare) then 2 else 1
        set HumanRunCap = Max(2, (Floor[Budget] or 0) + 1) * HumanPeriod
        NationWants := for (N : Humans) { NationWant(N, TickTime) }
        var Want:float = 0.0
        var Attacking:int = 0
        for (W : NationWants, W > 0.0):
            set Want += W
            set Attacking += 1
        # The equal part of each attacking nation, at most what it wants; the rest of the budget goes by speed.
        FloorEach := if (Attacking > 0) then Clamp(HumanFloorShare, 0.0, 1.0) * Budget / (Attacking * 1.0) else 0.0
        var FloorUsed:float = 0.0
        for (W : NationWants):
            set FloorUsed += Min(W, FloorEach)
        RestWant := Want - FloorUsed
        Rest := Budget - FloorUsed
        Scale := if (RestWant > Rest) then Max(0.0, Rest) / RestWant else 1.0
        for (Index -> N : Humans, W := NationWants[Index], W > 0.0):
            Part := Min(W, FloorEach) / W
            for (A : N.Attacks, not A.Done?):
                AW := AttackWant(A, TickTime)
                set A.Share = Min(A.Share + AW * (Part + (1.0 - Part) * Scale), Max(AttackCap(A) * 2.0 * HumanPeriod, AW / Max(0.001, TickTime)))
        set HumanGiven += Min(Want, Budget)
        # the two run loops under their own tags (rts_attacks minus both = the budget split above).
        if (ProfileServer?):
            profile("rts_attacks_humans"):
                RunHumanTurns(Humans, Now, First, HumanPeriod)
            profile("rts_attacks_others"):
                RunOtherTurns(Now, First)
        else:
            RunHumanTurns(Humans, Now, First, HumanPeriod)
            RunOtherTurns(Now, First)

    # The human nations' attacks of a tick.
    RunHumanTurns(Humans:[]rts_nation, Now:float, First:int, HumanPeriod:int):void =
        for (Index -> N : Humans, Mod[First + Index, HumanPeriod] = 0):
            RunNationAttacks(N, Now, HumanPeriod, true)

    # The bots' and tribes' attacks of a tick, starting with nation First.
    RunOtherTurns(Now:float, First:int):void =
        Count := NationList.Length
        for (Offset := 0..Count - 1, Index := Mod[First + Offset, Count] or 0, N := NationList[Index], not PlaysAsHuman[N], not N.Eliminated?):
            Period := if (N.Tribe?) then Max(1, TribeAttackPeriod) else 2
            if (Mod[First + Index, Period] = 0):
                RunNationAttacks(N, Now, Period, false)

    # Cells one attack may take per tick (the per-attack caps).
    AttackCap(A:rts_attack)<transacts>:float =
        if (A.Target = 0) then MaxNeutralCellsPerAttackPerTick * 1.0 else MaxCellsPerNationPerTick * 1.0

    # Cells a human attack wants in a tick of TickTime s: its OpenFront speed from its last run.
    AttackWant(A:rts_attack, TickTime:float)<transacts>:float =
        if (A.Rate < 0.0) then AttackCap(A) else A.Rate * TickTime

    # Cells all of N's running attacks want in a tick of TickTime s.
    NationWant(N:rts_nation, TickTime:float)<transacts>:float =
        var W:float = 0.0
        for (A : N.Attacks, not A.Done?):
            set W += AttackWant(A, TickTime)
        W

    # N's attacks over the time since they last ran (at most a quarter second per tick of Period). attacks with no
    # cells allowed are skipped (no setup cost; their clock keeps the time for later).
    RunNationAttacks(N:rts_nation, Now:float, Period:int, Human:logic):void =
        set N.AttackClock = Now
        if (N.Attacks.Length > 0):
            var Ended:int = 0
            # an attack whose troops no longer pay for one plains cell (80 * PerMag, from its last setup) is lost
            # now (its label went on showing the last few troops while it waited seconds for that cell).
            for (A : N.Attacks, not A.Done?, A.PerMag > 0.0, A.Troops < 80.0 * A.PerMag):
                LoseAttack(A)
            if (Human?):
                for (A : N.Attacks, not A.Done?):
                    Allowed := Min(Floor[A.Share] or 0, HumanRunCap)
                    if (Allowed > 0):
                        Got := RunAttack(N, A, AttackDt(A, Now), Allowed)
                        set A.Share -= Got * 1.0
                        set HumanTaken += Got
            else:
                for (A : N.Attacks, not A.Done?):
                    if (A.Target = 0):
                        Allowed := Max(0, Min(TickNeutral, MaxNeutralCellsPerAttackPerTick * Period))
                        if (Allowed > 0):
                            set TickNeutral -= RunAttack(N, A, AttackDt(A, Now), Allowed)
                    else:
                        Allowed := Max(0, Min(TickBudget, MaxCellsPerNationPerTick * Period))
                        if (Allowed > 0):
                            set TickBudget -= RunAttack(N, A, AttackDt(A, Now), Allowed)
            for (A : N.Attacks):
                if (A.Done?):
                    set Ended += 1
                    if (not A.Beach?, AO := N.AttackOn[A.Target], Cur := AO?, Cur = A):
                        NoAttack:?rts_attack = false
                        if (set N.AttackOn[A.Target] = NoAttack) {}
                        if (A.Target > 0, not AtWar[N.Id, A.Target]):
                            WarChanged(N.Id, A.Target)
            if (Ended > 0):
                set N.Attacks = for (A : N.Attacks, not A.Done?) { A }

    # Seconds since A last ran, at most 5 s.
    AttackDt(A:rts_attack, Now:float):float =
        if (A.Clock < 0.0):
            set A.Clock = Now - 0.1
        Dt := Clamp(Now - A.Clock, 0.0, 5.0)
        set A.Clock = Now
        Dt

    # OpenFront AttackExecution: per OpenFront tick (0.1 s) the attack has a budget of 1, each cell costs TickCost
    # (cheaper on a long front, see attackLogic above); here the budget over Dt is turned into cells, at most MaxCells
    # (the server caps), lowest key first. Each cell: attacker and defender losses; an attack whose troops drop below 1
    # is lost, one that runs out of cells returns its troops. A boat attack adds the target's cells around each cell
    # it takes to its own front. Returns the number of cells taken.
    # a sampled run also profiles its parts (RunSampled: rts_s_run_setup / _begin / _end / _endattack; the rest
    # of rts_s_run_attack is the pop / take loop), and runs that take no cell are counted (ZeroRuns).
    RunAttack(N:rts_nation, A:rts_attack, Dt:float, MaxCells:int):int =
        set AttackRuns += 1
        Sampled := SampleNow()
        var Got:int = 0
        if (Sampled?):
            set RunSampled = true
            profile("rts_s_run_attack"):
                set Got = RunAttackBody(N, A, Dt, MaxCells)
            set RunSampled = false
            set SampleRuns += 1
            set SampleRunCells += Got
        else:
            set Got = RunAttackBody(N, A, Dt, MaxCells)
        if (Got = 0):
            set ZeroRuns += 1
        Got

    RunAttackBody(N:rts_nation, A:rts_attack, Dt:float, MaxCells:int):int =
        Target := A.Target
        if (A.Troops < 1.0):
            LoseAttack(A)
            return 0
        Front:rts_front = if (B := A.Beach?) then B else A.Front
        if (Front.Pending?):
            return 0
        MaybeDef:?rts_nation = if (D := NationOf[Target]) then option{D} else false
        # speed and losses from AttackSetup, at most AttackSetupTime s old (A.Clock = now, set by AttackDt).
        if (A.SetupAt < 0.0 or A.Clock - A.SetupAt >= AttackSetupTime):
            if (RunSampled?):
                profile("rts_s_run_setup"):
                    AttackSetup(N, A, Front, MaybeDef)
            else:
                AttackSetup(N, A, Front, MaybeDef)
        PerTick := A.PerTick
        Loss0 := 80.0 * A.PerMag
        Loss1 := 100.0 * A.PerMag
        Loss2 := 120.0 * A.PerMag
        # The credit counts plains cells; a highland or mountain cell uses up its cost relative to plains (OpenFront
        # tile cost 20 and 25 vs 16.5).
        Ratio1 := 20.0 / 16.5
        Ratio2 := 25.0 / 16.5
        # Credit over the cap is kept for later ticks, but never more than a second (10 OpenFront ticks) of cells.
        set A.Credit = Min(A.Credit + PerTick * Dt / 0.1, Max(1.0, PerTick * 10.0))
        var StepCells:int = 0
        if (K := Floor[A.Credit]):
            set StepCells = Max(0, Min(K, MaxCells))
            if (K > MaxCells):
                set CapHits += 1
        if (StepCells <= 0):
            return 0
        var Budget:int = StepCells * PopsPerCell
        StepsBefore := Front.Steps
        if (RunSampled?):
            profile("rts_s_run_begin"):
                BeginTakes(N, Target)
        else:
            BeginTakes(N, Target)
        var Taken:int = 0
        var Running:logic = true
        loop:
            if (Taken >= StepCells or A.Credit < 1.0 or not Running? or Budget <= 0 or A.Troops < 1.0):
                break
            set Budget -= 1
            set AttackPops += 1
            Sampled := SampleNow()
            MaybeNext := if (Sampled?) then PopSampled(Front) else Front.Pop()
            if (C := MaybeNext?):
                # Stale entry: the cell changed owner or no longer touches N.
                if (C.Owner = Target, TouchesOwner[C, N.Id]):
                    if (C.Terrain = 0):
                        set A.Credit -= 1.0
                        set A.Troops = Max(0.0, A.Troops - Loss0)
                    else if (C.Terrain = 1):
                        set A.Credit -= Ratio1
                        set A.Troops = Max(0.0, A.Troops - Loss1)
                    else:
                        set A.Credit -= Ratio2
                        set A.Troops = Max(0.0, A.Troops - Loss2)
                    if (Def := MaybeDef?, Def.Cells > 0):
                        set Def.Troops = Max(0.0, Def.Troops - Def.Troops / (Def.Cells * 1.0))
                    Take(N, C)
                    if (A.Labeled?):
                        TrackLabel(A, Front, C)
                    if (A.Beach?):
                        if (X := C.Neighbors[0], X.Owner = Target) { Front.Push(X, AttackKey(X, OwnNeighbors(X, N.Id))) }
                        if (X := C.Neighbors[1], X.Owner = Target) { Front.Push(X, AttackKey(X, OwnNeighbors(X, N.Id))) }
                        if (X := C.Neighbors[2], X.Owner = Target) { Front.Push(X, AttackKey(X, OwnNeighbors(X, N.Id))) }
                        if (X := C.Neighbors[3], X.Owner = Target) { Front.Push(X, AttackKey(X, OwnNeighbors(X, N.Id))) }
                    set Taken += 1
                else:
                    set StalePops += 1
            else:
                set Running = false
        if (RunSampled?):
            profile("rts_s_run_end"):
                EndTakes()
        else:
            EndTakes()
        set PopSteps += Front.Steps - StepsBefore
        if (not Running?):
            if (RunSampled?):
                profile("rts_s_run_endattack"):
                    EndAttack(N, A)
            else:
                EndAttack(N, A)
        Taken

    # OpenFront attackLogic for A: plains cells per OpenFront tick
    # (PerTick, from the cost of a plains cell, OpenFront tickFraction) and the attacker's loss per terrain mag point
    # (PerMag); troop ratio, border size (live front cells + 0..5) and defender density as they are now.
    AttackSetup(N:rts_nation, A:rts_attack, Front:rts_front, MaybeDef:?rts_nation):void =
        set A.SetupAt = A.Clock
        BorderSize := Max(1, Front.Live) + GetRandomInt(0, 5)
        var Cost0:float = 0.0
        if (Def := MaybeDef?):
            R := Def.Troops / Max(1.0, A.Troops)
            Speed := Clamp(R, 0.82, 7.5) * Max(1.0, Min(R / 20.0, 50.0)) / 8.55 * Max(0.27, 1.0 - 0.73 * N.BigS) * Max(0.7, 1.0 - 0.3 * Def.BigS) / (BorderSize * 1.0)
            set Cost0 = Speed * 16.5
            Bot := if (Def.Tribe?, not N.Tribe?) then 0.7 else 1.0
            set A.PerMag = Bot * Clamp(R, 0.6, 2.0) * (0.463 * Max(0.3, 1.0 - 0.7 * N.BigS) * Max(0.7, 1.0 - 0.3 * Def.BigS) + 0.0039 * Def.Troops / Max(1.0, Def.Cells * Max(1.0, TilesPerCell)))
        else:
            Troops := Max(1.0, A.Troops)
            set Cost0 = Clamp(2000.0 * 16.5 / Troops, 5.0, 100.0) / (2.0 * BorderSize)
            set A.PerMag = if (N.Tribe?) then 0.1 else 0.2
        # a cell stands for TilesPerCell tiles: the front of BorderSize cells is sqrt(TilesPerCell) times longer in
        # tiles (cells per tick = tiles per tick / TilesPerCell), and taking a cell costs the attacker TilesPerCell
        # tiles.
        K := Max(1.0, TilesPerCell)
        set A.PerMag = A.PerMag * K
        set A.PerTick = 1.0 / (Max(0.0001, Cost0) * Sqrt(K))
        set A.Rate = A.PerTick * 10.0

    # Front.Pop under the sampled tag rts_s_pop.
    PopSampled(Front:rts_front):?gs_cell =
        var Result:?gs_cell = false
        profile("rts_s_pop"):
            set Result = Front.Pop()
        Result

    # OpenFront terrainEffect (mag, tile cost) of C's terrain: plains 80 / 16.5, highland 100 / 20, mountain 120 / 25.
    TerrainOf(C:gs_cell)<transacts>:tuple(float, float) =
        if (C.Terrain = 2) then (120.0, 25.0)
        else if (C.Terrain = 1) then (100.0, 20.0)
        else (80.0, 16.5)

    # A took C, a cell of its Front: C becomes the label candidate when it is closer to the center than the candidate
    # so far. The cells taken between two label updates lie all along the front, so the best of them is near the
    # center; reading the whole front (OpenFront's BFS over the border) would cost far more on the server.
    TrackLabel(A:rts_attack, Front:rts_front, C:gs_cell):void =
        I := C.I * 1.0
        J := C.J * 1.0
        Live := Front.Live * 1.0
        D := if (Live > 0.0) then Square(I - Front.SumI * 1.0 / Live) + Square(J - Front.SumJ * 1.0 / Live) else 0.0
        if (not A.HasCand? or D < A.CandD):
            set A.HasCand = true
            set A.CandI = I
            set A.CandJ = J
            set A.CandD = D

    Square(X:float)<transacts>:float = X * X

    # The label point of A at a label update: the first candidate; later the candidate only when it is
    # AttackLabelHold cells closer to the front's center than the point (the point stays on its part of a bent or
    # split front while the center hardly moves, and follows the front once it has moved on).
    PlaceAttackLabel(A:rts_attack):void =
        if (not A.HasCand?):
            return
        set A.HasCand = false
        if (not A.HasPos?):
            set A.PosI = A.CandI
            set A.PosJ = A.CandJ
            set A.HasPos = true
            return
        Front:rts_front = if (B := A.Beach?) then B else A.Front
        Live := Front.Live * 1.0
        if (Live <= 0.0):
            return
        CI := Front.SumI * 1.0 / Live
        CJ := Front.SumJ * 1.0 / Live
        PosD := Sqrt(Square(A.PosI - CI) + Square(A.PosJ - CJ))
        CandD := Sqrt(Square(A.CandI - CI) + Square(A.CandJ - CJ))
        if (CandD + AttackLabelHold < PosD):
            set A.PosI = A.CandI
            set A.PosJ = A.CandJ

    # The attack's troops ran out (OpenFront: troops < 1 = the attack is gone, nothing returns).
    LoseAttack(A:rts_attack)<transacts>:void =
        set A.Troops = 0.0
        set A.Done = true

    # ---------- Player clicks and the action menu ----------

    # A click on the map opens the clicking player's action menu (ActionMenu.verse) for the clicked cell, like
    # OpenFront's radial menu; a click while the menu is open closes it. Eliminated players and players who left get
    # no menu.
    ClickLoop()<suspends>:void =
        loop:
            Click := RTSCamera.ClickEvent.Await()
            P := Click.Player
            G := Click.GroundPoint
            Now := GetSimulationElapsedTime()
            Ignore:logic = if (Until := IgnoreClicksUntil[P], Now < Until) then true else false
            if (not Ignore?):
                if (Menu := Menus[P], Menu.Open?):
                    spawn{ CloseMenuLater(P) }
                else if (N := HumanNations[P], not N.Eliminated?, not N.Left?, IJ := CellCoords[G.Forward, -G.Left], Cell := CellAt[IJ(0), IJ(1)]):
                    if (ShowClickRing?):
                        # Expanding red ring at the clicked point (NS_ClickRing: one sprite, the material grows and fades it).
                        SpawnParticleSystem(VFX.NS_ClickRing_asset, vector3{Forward := G.Forward, Left := G.Left, Up := G.Up + 3.0})
                    S := Click.ScreenPosition
                    Log("{NationName(N)}: menu for cell {Cell.I}, {Cell.J} (screen {S.Left}, {S.Up})")
                    OpenMenu(P, N, Cell)

    # The player's menu and the loop that acts on its buttons.
    MakeMenu(P:player):void =
        Menu := MakeActionMenu()
        if (set Menus[P] = Menu) {}
        spawn{ MenuLoop(P, Menu) }

    # P's control panel, shown at once, and the loop that takes its attack ratio.
    MakePanel(P:player, N:rts_nation):void =
        Panel := MakeControlPanel(RatioOf(N))
        if (set Panels[P] = Panel) {}
        UpdatePanel(N, Panel)
        Panel.Show(P)
        spawn{ RatioLoop(P, N, Panel) }

    RatioLoop(P:player, N:rts_nation, Panel:rts_control_panel)<suspends>:void =
        loop:
            Ratio := Panel.RatioEvent.Await()
            set N.AttackRatio = Clamp(Ratio, 0.01, 1.0)
            # Dragging the slider can reach the map as a click.
            if (set IgnoreClicksUntil[P] = GetSimulationElapsedTime() + 0.4) {}
            UpdatePanel(N, Panel)

    # Every PanelInterval s: the panels of the players still in the game.
    PanelLoop()<suspends>:void =
        loop:
            Sleep(Max(0.1, PanelInterval))
            for (N : NationList, P := N.Human?, not N.Eliminated?, not N.Left?, Panel := Panels[P]):
                UpdatePanel(N, Panel)

    UpdatePanel(N:rts_nation, Panel:rts_control_panel):void =
        Cap := Max(1.0, MaxTroops(N))
        Away := AttackTroopsOf(N) + N.BoatTroops
        Growth := GrowthPerSecond(N)
        Rising:logic = if (Growth >= N.LastGrowth) then true else false
        set N.LastGrowth = Growth
        Ratio := RatioOf(N)
        Percent := Floor[Ratio * 100.0 + 0.5] or 20
        Panel.Update(
            "Troops {PowerText(N.Troops)} / {PowerText(Cap)}",
            "+{PowerText(Growth)}/s",
            Rising,
            "In attacks {PowerText(Away)}",
            "Gold {PowerText(N.Gold)}  +{PowerText(GoldPerTick * 10.0)}/s",
            "Attack ratio {Percent} % ({PowerText(N.Troops * Ratio)} troops)",
            N.Troops / Cap,
            Away / Cap)

    MenuLoop(P:player, Menu:rts_action_menu)<suspends>:void =
        loop:
            Action := Menu.ActionEvent.Await()
            # A button press can also reach the map as a click: ignore map clicks for a moment.
            if (set IgnoreClicksUntil[P] = GetSimulationElapsedTime() + 0.4) {}
            BumpMenu(P)
            Menu.Hide(P)
            if (N := HumanNations[P], not N.Eliminated?, not N.Left?, Cell := MenuCells[P]):
                case (Action):
                    rts_menu_action.Attack => MenuAttack(P, N, Cell)
                    rts_menu_action.Boat => MenuBoat(P, N, Cell)
                    rts_menu_action.Close => {}

    # A click on the map while the menu is open closes it, unless a menu button was pressed meanwhile (its press may
    # reach the map first).
    CloseMenuLater(P:player)<suspends>:void =
        Stamp := MenuStamp[P] or 0
        Sleep(0.2)
        if ((MenuStamp[P] or 0) = Stamp, Menu := Menus[P]):
            BumpMenu(P)
            Menu.Hide(P)

    BumpMenu(P:player):void =
        Next := (MenuStamp[P] or 0) + 1
        if (set MenuStamp[P] = Next) {}

    # Shows P's menu for Cell: owner, troops and terrain; Attack when N borders the owner, Boat when N has a coast and
    # a free boat.
    OpenMenu(P:player, N:rts_nation, Cell:gs_cell):void =
        if (Menu := Menus[P]):
            if (set MenuCells[P] = Cell) {}
            BumpMenu(P)
            Owner := Cell.Owner
            Ground := if (Cell.Terrain = 2) then "Mountains" else if (Cell.Terrain = 1) then "Highland" else "Plains"
            Title := if (Owner = N.Id) then "Your land" else if (Y := NationOf[Owner]) then NationName(Y) else "Neutral land"
            Info := if (Y := NationOf[Owner]) then "{PowerText(Y.Troops)} troops, {Y.Cells} cells - {Ground}" else Ground
            Mine:logic = if (Owner = N.Id) then true else false
            Bordering:logic = if (not Mine?, Borders[N, Owner]) then true else false
            CanBoat:logic = if (not Mine?, N.CoastCells > 0, N.Boats < MaxBoatsPerNation) then true else false
            AttackText := if (Mine?) then "Attack" else if (Bordering?) then "Attack ({PowerText(N.Troops * RatioOf(N))} troops)" else "Attack (no border)"
            BoatText := if (Mine?) then "Boat" else if (N.CoastCells <= 0) then "Boat (no coast)" else if (N.Boats >= MaxBoatsPerNation) then "Boat (all at sea)" else "Boat ({PowerText(N.Troops * RatioOf(N))} troops)"
            Menu.Show(P, Title, Info, AttackText, Bordering, BoatText, CanBoat)

    # Attack button (OpenFront center button): an attack on the cell's owner along the whole border with AttackShare
    # of the troops; another press on the same owner adds troops to the running attack.
    MenuAttack(P:player, N:rts_nation, Cell:gs_cell):void =
        Target := Cell.Owner
        What := if (Target = 0) then "neutral land" else if (Y := NationOf[Target]) then NationName(Y) else "that land"
        if (Target = N.Id):
            Note(P, "That is your land")
        else:
            Started := AttackWithShare(N, Target, RatioOf(N))
            if (Started?):
                Log("{NationName(N)}: attack on {What}, {Floor[AttackTroopsOf(N)] or 0} troops in {N.Attacks.Length} attacks")
            else:
                Note(P, "No border with {What}: send a boat")

    # Boat button: a transport ship with BoatShare of the troops to the clicked land.
    MenuBoat(P:player, N:rts_nation, Cell:gs_cell):void =
        if (Cell.Owner = N.Id):
            Note(P, "That is your land")
        else if (N.Boats >= MaxBoatsPerNation):
            Note(P, "All {MaxBoatsPerNation} boats are at sea")
        else:
            spawn{ SendBoat(N, Cell) }

    # A short message at the top of P's screen for 3 s.
    Note(P:player, S:string):void =
        Next := (NoteStamp[P] or 0) + 1
        if (set NoteStamp[P] = Next) {}
        RTSCamera.SetStatus(P, S)
        spawn{ ClearNote(P, Next) }

    ClearNote(P:player, Stamp:int)<suspends>:void =
        Sleep(3.0)
        if ((NoteStamp[P] or 0) = Stamp, not WinnerDeclared?, N := HumanNations[P], not N.Eliminated?):
            RTSCamera.SetStatus(P, "")

    # Note for a human nation's player (nothing for bots).
    NationNote(N:rts_nation, S:string):void =
        if (P := N.Human?, not N.Left?):
            Note(P, S)

    # Moves one billboard per nation to the nation's center every LabelUpdateTime, facing the camera, with its name
    # and military power. Billboards of eliminated nations are hidden.
    LabelLoop()<suspends>:void =
        Labels := for (Obj : Self.FindCreativeObjectsWithTag(rts_nation_label), B := billboard_device[Obj]):
            B
        Log("{Labels.Length} nation labels")
        for (B : Labels):
            B.SetShowBorder(false)
            B.SetTextSize(LabelTextSize)
        set LabelShown = for (B : Labels) { false }
        set LabelText = for (B : Labels) { "" }
        set LabelPos = for (B : Labels) { vector3{Forward := 0.0, Left := 0.0, Up := -1000.0} }
        set LabelSize = for (B : Labels) { 0.0 }
        BaseRots := for (B : Labels):
            DeviceRotation(B)
        # Spawn phase: OpenFront sizes the name against an 8-tile region around the spawn.
        for (N : NationList):
            SpawnSize := SpawnFontSize(N)
            set N.NameI = N.SumI * 1.0 / (Max(1, N.Cells) * 1.0)
            set N.NameJ = N.SumJ * 1.0 / (Max(1, N.Cells) * 1.0)
            set N.NameSize = SpawnSize
            set N.ShownI = N.NameI
            set N.ShownJ = N.NameJ
            set N.ShownSize = SpawnSize
        Humans := for (N : NationList, P := N.Human?) { P }
        loop:
            # Labels are shared by all players: they follow the camera turn (Q/E) only when one human plays.
            Yaw := if (Humans.Length = 1, P := Humans[0]) then RTSCamera.GetViewYaw(P) else 0.0
            Turn := MakeRotationDegrees(vector3{Forward := 0.0, Left := 0.0, Up := 1.0}, Yaw)
            Ease := 1.0 - Exp(-LabelEase * LabelUpdateTime)
            # The troop text changes every update; rewriting it every 5th one (0.5 s) keeps the label cost down.
            set LabelRound += 1
            DoText:logic = if (Mod[LabelRound, 5] = 0) then true else false
            if (ProfileServer?):
                profile("rts_labels"):
                    UpdateLabels(Labels, BaseRots, Turn, Ease, DoText)
            else:
                UpdateLabels(Labels, BaseRots, Turn, Ease, DoText)
            Sleep(LabelUpdateTime)

    # One label update: moves, resizes and rewrites only the billboards that changed visibly.
    UpdateLabels(Labels:[]billboard_device, BaseRots:[]rotation, Turn:rotation, Ease:float, DoText:logic):void =
        for (Index -> B : Labels, BaseRot := BaseRots[Index]):
            Rot := BaseRot * Turn
            # Tribe labels change only every third update.
            if (N := NationList[Index], N.Tribe?, LabelShown[Index] = true, not N.Eliminated?, N.Cells > 0, Mod[LabelRound, 3] <> 0) {}
            else if (N := NationList[Index], not N.Eliminated?, N.Cells > 0):
                set N.ShownI = Lerp(N.ShownI, N.NameI, Ease)
                set N.ShownJ = Lerp(N.ShownJ, N.NameJ, Ease)
                set N.ShownSize = Lerp(N.ShownSize, N.NameSize, Ease)
                Size := Clamp(N.ShownSize * LabelScalePerCell, LabelMinScale, LabelMaxScale)
                Center := vector3:
                    Forward := OriginX + (N.ShownI + 0.5) * CellSize
                    Left := -(OriginY + (N.ShownJ + 0.5) * CellSize)
                    Up := LabelHeight
                # Text widget offset inside the billboard: 81 up, 8 to the side (editor Y -8 = Left +8).
                Pos := Center - (Rot.GetLeftAxis() * 8.0 + Rot.GetUpAxis() * LabelWidgetHeight) * Size
                OldPos := LabelPos[Index] or Pos
                OldSize := LabelSize[Index] or Size
                if (LabelShown[Index] = false or Distance(Pos, OldPos) > LabelMoveStep or Abs(Size - OldSize) > OldSize * 0.02):
                    if (set LabelPos[Index] = Pos, set LabelSize[Index] = Size) {}
                    if (B.TeleportTo[transform{Translation := Pos, Rotation := Rot, Scale := vector3{Forward := Size, Left := Size, Up := Size}}]) {}
                    else if (LabelShown[Index] = false):
                        Log("Label {Index} ({NationName(N)}) TeleportTo failed")
                if (DoText? or LabelShown[Index] = false):
                    Power := PowerText(N.Troops + AttackTroopsOf(N) + N.BoatTroops)
                    # humans still playing show their Fortnite name (PlayerLabelMessage); LabelText keeps the
                    # string key only to skip unchanged rewrites.
                    Text := "{NationName(N)}\n{Power}"
                    if (Old := LabelText[Index], Old <> Text):
                        if (set LabelText[Index] = Text) {}
                        if (P := N.Human?, not N.Left?):
                            B.SetText(PlayerLabelMessage(P, Power))
                        else:
                            B.SetText(LabelMessage(Text))
                        B.UpdateDisplay()
                if (LabelShown[Index] = false):
                    B.ShowText()
                    if (set LabelShown[Index] = true) {}
            else if (LabelShown[Index] = true):
                B.HideText()
                if (set LabelShown[Index] = false) {}

    # ---------- Attack labels ----------

    # Every AttackLabelTime: each labeled attack (WantsLabel: a human makes or receives it) shows its troops at its
    # label point (TrackLabel), on a billboard of the pool (tag rts_attack_label). OpenFront shows these only to the
    # local player; Fortnite billboards are the same for every player, so every human's attacks show. An attack keeps
    # its billboard until it ends; with all billboards busy, later attacks wait for a free one.
    AttackLabelLoop()<suspends>:void =
        set AttackLabels = for (Obj : Self.FindCreativeObjectsWithTag(rts_attack_label), B := billboard_device[Obj]):
            B
        Log("{AttackLabels.Length} attack labels")
        if (AttackLabels.Length = 0):
            return
        for (B : AttackLabels):
            B.SetShowBorder(false)
            B.SetTextSize(LabelTextSize)
            B.HideText()
        set AttackLabelRots = for (B : AttackLabels):
            DeviceRotation(B)
        NoAttack:?rts_attack = false
        set AttackLabelOwners = for (B : AttackLabels) { NoAttack }
        set AttackLabelTexts = for (B : AttackLabels) { "" }
        set AttackLabelPositions = for (B : AttackLabels) { vector3{Forward := 0.0, Left := 0.0, Up := -1000.0} }
        set AttackLabelEased = AttackLabelPositions
        loop:
            Sleep(AttackLabelTime)
            if (ProfileServer?):
                profile("rts_attack_labels"):
                    UpdateAttackLabels()
            else:
                UpdateAttackLabels()

    # One attack label update (see AttackLabelLoop).
    UpdateAttackLabels():void =
        Labels := AttackLabels
        Ease := 1.0 - Exp(-AttackLabelEase * AttackLabelTime)
        Scale := AttackLabelScale
        NoAttack:?rts_attack = false
        # Free the billboards of attacks that ended.
        for (Index -> Owner : AttackLabelOwners, A := Owner?, A.Done?, B := Labels[Index]):
            set A.Label = -1
            if (set AttackLabelOwners[Index] = NoAttack) {}
            B.HideText()
            set AttackLabelCalls += 1
        # Labeled attacks with a label point get a free billboard, first come first served, and keep it.
        var Wanted:int = 0
        for (N : NationList, not N.Eliminated?, A : N.Attacks, A.Labeled?, not A.Done?):
            PlaceAttackLabel(A)
        for (N : NationList, not N.Eliminated?, A : N.Attacks, A.Labeled?, not A.Done?, A.HasPos?):
            set Wanted += 1
            if (A.Label < 0):
                var Free:int = -1
                for (Index -> Owner : AttackLabelOwners, Free < 0, not Owner?):
                    set Free = Index
                if (set AttackLabelOwners[Free] = option{A}, set AttackLabelTexts[Free] = ""):
                    set A.Label = Free
        set AttackLabelsWanted = Max(AttackLabelsWanted, Wanted)
        var Shown:int = 0
        for (Index -> Owner : AttackLabelOwners, A := Owner?, B := Labels[Index], Rot := AttackLabelRots[Index]):
            set Shown += 1
            Point := vector3:
                Forward := OriginX + (A.PosI + 0.5) * CellSize
                Left := -(OriginY + (A.PosJ + 0.5) * CellSize)
                Up := AttackLabelHeight
            New:logic = if (Old := AttackLabelTexts[Index], Old = "") then true else false
            # The shown point eases toward the label point (a new label starts on it).
            Center := if (not New?, Eased := AttackLabelEased[Index]) then Eased + (Point - Eased) * Ease else Point
            if (set AttackLabelEased[Index] = Center) {}
            Pos := Center - (Rot.GetLeftAxis() * 8.0 + Rot.GetUpAxis() * LabelWidgetHeight) * Scale
            if (New? or Distance(Pos, AttackLabelPositions[Index] or Pos) > LabelMoveStep):
                if (set AttackLabelPositions[Index] = Pos) {}
                if (B.TeleportTo[transform{Translation := Pos, Rotation := Rot, Scale := vector3{Forward := Scale, Left := Scale, Up := Scale}}]) {}
                set AttackLabelCalls += 1
            Text := PowerText(A.Troops)
            if (Old := AttackLabelTexts[Index], Old <> Text, set AttackLabelTexts[Index] = Text):
                B.SetText(LabelMessage(Text))
                B.UpdateDisplay()
                set AttackLabelCalls += 2
            if (New?):
                B.ShowText()
                set AttackLabelCalls += 1
        set AttackLabelsShown = Max(AttackLabelsShown, Shown)

    # ---------- Name boxes (OpenFront NameBoxCalculator) ----------

    # Font size of a name in an 8 x 8 cell box (OpenFront's spawn-phase size).
    SpawnFontSize(N:rts_nation):float =
        FontSize(8.0, 8.0, NationName(N).Length)

    # OpenFront calculateFontSize: min(width / name length * 2, height / 3), in cells.
    FontSize(Width:float, Height:float, NameLength:int)<transacts>:float =
        Min(Width / (Max(1, NameLength) * 1.0) * 2.0, Height / 3.0)

    # Every LabelRecalcTime: one sweep over the map finds each nation's largest connected territory (bounding box),
    # ClusterWorkPerTick work per tick; then each nation's name box is computed (one nation per tick).
    NameBoxLoop()<suspends>:void =
        # Stack of the depth-first walk: every cell is pushed at most once per sweep, so the land cells fit.
        set ClusterStack = AllCells
        loop:
            set ClusterStamp += 1
            Id := ClusterStamp
            for (N : NationList):
                set N.CandSize = 0
            var Steps:int = 0
            var Work:int = 0
            SweepStart := GetSimulationElapsedTime()
            # every second cell in both directions (SweepCells, Far neighbors): 4 x fewer steps; boxes +-1 cell.
            for (Seed : SweepCells):
                set Work += 1
                if (Seed.Owner > 0, Seed.ClusterMark <> Id, N := NationOf[Seed.Owner]):
                    # Depth-first over the connected cells of this owner (size and bounding box) on ClusterStack, a
                    # reused array.
                    Owner := Seed.Owner
                    set Seed.ClusterMark = Id
                    if (set ClusterStack[0] = Seed) {}
                    var Top:int = 1
                    var Size:int = 0
                    var MinI:int = Seed.I
                    var MaxI:int = Seed.I
                    var MinJ:int = Seed.J
                    var MaxJ:int = Seed.J
                    loop:
                        if (Top <= 0):
                            break
                        set Top -= 1
                        if (C := ClusterStack[Top]):
                            set Size += 1
                            if (C.I < MinI) { set MinI = C.I } else if (C.I > MaxI) { set MaxI = C.I }
                            if (C.J < MinJ) { set MinJ = C.J } else if (C.J > MaxJ) { set MaxJ = C.J }
                            if (X := C.Far[0], X.Owner = Owner, X.ClusterMark <> Id, set ClusterStack[Top] = X):
                                set X.ClusterMark = Id
                                set Top += 1
                            if (X := C.Far[1], X.Owner = Owner, X.ClusterMark <> Id, set ClusterStack[Top] = X):
                                set X.ClusterMark = Id
                                set Top += 1
                            if (X := C.Far[2], X.Owner = Owner, X.ClusterMark <> Id, set ClusterStack[Top] = X):
                                set X.ClusterMark = Id
                                set Top += 1
                            if (X := C.Far[3], X.Owner = Owner, X.ClusterMark <> Id, set ClusterStack[Top] = X):
                                set X.ClusterMark = Id
                                set Top += 1
                            set Work += 4
                            if (Work * 1.0 >= ClusterWorkPerTick * 1.0 * LoadShare()):
                                set Steps += Work
                                set ClusterSteps += Work
                                set Work = 0
                                Sleep(0.0)
                    if (Size > N.CandSize):
                        set N.CandSize = Size
                        set N.CandMinI = MinI
                        set N.CandMaxI = MaxI + 1
                        set N.CandMinJ = MinJ
                        set N.CandMaxJ = MaxJ + 1
                if (Work * 1.0 >= ClusterWorkPerTick * 1.0 * LoadShare()):
                    set Steps += Work
                    set ClusterSteps += Work
                    set Work = 0
                    Sleep(0.0)
            # a nation whose land changed by less than 5 % since its last placement keeps its name box.
            for (N : NationList, not N.Eliminated?, N.CandSize > 0, N.PlacedCells = 0 or Abs(N.Cells - N.PlacedCells) * 20 > N.PlacedCells):
                set N.PlacedCells = Max(1, N.Cells)
                set N.BoxSize = N.CandSize
                set N.BoxMinI = N.CandMinI
                set N.BoxMaxI = N.CandMaxI
                set N.BoxMinJ = N.CandMinJ
                set N.BoxMaxJ = N.CandMaxJ
                if (ProfileServer?):
                    profile("rts_namebox"):
                        PlaceName(N)
                else:
                    PlaceName(N)
                Sleep(0.0)
            if (ProfileServer?):
                Log("Name boxes: sweep of {Steps} steps from {SweepStart} s to {GetSimulationElapsedTime()} s")
            Sleep(LabelRecalcTime)

    # OpenFront placeName: coarse grid over the largest cluster's bounding box (1..32 cells per grid cell by the box's
    # smaller side), largest inscribed rectangle of filled grid cells, name centered in it (shifted up by a third of
    # the font size), font size from the rectangle.
    PlaceName(N:rts_nation):void =
        W := N.BoxMaxJ - N.BoxMinJ + 1
        H := N.BoxMaxI - N.BoxMinI + 1
        Small := Min(W, H)
        S0 := if (Small < 25) then 1 else if (Small < 50) then 2 else if (Small < 100) then 4 else if (Small < 250) then 8 else if (Small < 500) then 16 else 32
        # The grid is kept at most 40 x 40 (long thin territories would make the rectangle search too slow for a tick).
        S := Max(S0, Quotient[Max(W, H) + 39, 40] or 1)
        GW := Quotient[W + S - 1, S] or 1
        GH := Quotient[H + S - 1, S] or 1
        # Largest rectangle row by row: Heights[x] = filled grid cells above and including this row in column x.
        var Heights:[]int = for (X := 0..GW - 1) { 0 }
        var Stack:[]int = for (X := 0..GW) { 0 }
        var BestArea:int = 0
        var BestX:int = 0
        var BestY:int = 0
        var BestW:int = 1
        var BestH:int = 1
        for (Y := 0..GH - 1):
            set Heights = for (X := 0..GW - 1, Old := Heights[X]):
                if (Filled[N, N.BoxMinI + Y * S, N.BoxMinJ + X * S]) then Old + 1 else 0
            # Largest rectangle under this row's histogram with a stack of rising columns. X = GW is a zero column
            # that empties it.
            var Top:int = 0
            for (X := 0..GW):
                HX := if (HV := Heights[X]) then HV else 0
                loop:
                    if (Top > 0, SI := Stack[Top - 1], SH := Heights[SI], SH >= HX):
                        set Top -= 1
                        Left := if (Top > 0, P := Stack[Top - 1]) then P + 1 else 0
                        Area := SH * (X - Left)
                        if (Area > BestArea):
                            set BestArea = Area
                            set BestX = Left
                            set BestY = Y - SH + 1
                            set BestW = X - Left
                            set BestH = SH
                    else:
                        break
                if (set Stack[Top] = X):
                    set Top += 1
        if (BestArea > 0):
            RectW := BestW * S * 1.0
            RectH := BestH * S * 1.0
            Font := FontSize(RectW, RectH, NationName(N).Length)
            set N.NameSize = Font
            # Grid Y grows with I (north); OpenFront's "up by a third of the font size" is toward north here.
            set N.NameI = N.BoxMinI * 1.0 + BestY * S * 1.0 + RectH / 2.0 + Font / 3.0
            set N.NameJ = N.BoxMinJ * 1.0 + BestX * S * 1.0 + RectW / 2.0

    # OpenFront createGrid condition: the nation's own land, any shore cell, or shallow sea (a 1-degree sea cell next
    # to a coast). Cells outside the map count as empty.
    Filled(N:rts_nation, I:int, J:int)<transacts><decides>:void =
        if (C := CellAt[I, J]):
            C.Owner = N.Id or C.Neighbors.Length < 4
        else:
            I >= 0
            I < GridWidth
            J >= 0
            J < GridHeight
            TI := Quotient[I, 3]
            TJ := Quotient[J, 3]
            Sea := SeaAt[TI, TJ]
            Sea.Owners.Length > 0

    # ---------- Benchmark (ProfileServer) ----------

    # Times single operations once in the lobby, 2000 of each, as "VerseProfile: rts_bench_<op>" lines (cost of one =
    # the time / 2000, minus the empty loop). Touches no game state except the Rekey stamps of the test cells.
    Bench()<suspends>:void =
        Cells := for (Index := 0..1999, C := AllCells[Index * 50]) { C }
        if (Cells.Length = 0):
            return
        Sleep(0.0)
        profile("rts_bench_empty_loop"):
            var X:int = 0
            for (C : Cells):
                set X += 1
        Sleep(0.0)
        profile("rts_bench_field_set"):
            for (Index -> C : Cells):
                set C.Rekey = -1 - Index
        Sleep(0.0)
        profile("rts_bench_var_add"):
            var Y:int = 0
            for (C : Cells):
                set Y += C.I
        Sleep(0.0)
        profile("rts_bench_random_int"):
            var Z:int = 0
            for (C : Cells):
                set Z += GetRandomInt(10, 16)
        Sleep(0.0)
        profile("rts_bench_sim_time"):
            var T:float = 0.0
            for (C : Cells):
                set T += GetSimulationElapsedTime()
        Sleep(0.0)
        profile("rts_bench_own_neighbors"):
            var K:int = 0
            for (C : Cells):
                set K += OwnNeighbors(C, 0)
        Sleep(0.0)
        profile("rts_bench_attack_key"):
            var K2:int = 0
            for (C : Cells):
                set K2 += AttackKey(C, 1)
        Sleep(0.0)
        profile("rts_bench_array_one"):
            var L:int = 0
            for (C : Cells):
                A := array{C}
                set L += A.Length
        Sleep(0.0)
        profile("rts_bench_queue_push"):
            Q := rts_cell_queue{}
            for (C : Cells):
                Q.Push(array{C})
        Sleep(0.0)
        Q2 := rts_cell_queue{}
        for (C : Cells):
            Q2.Push(array{C})
        # (A call inside "not" is rolled back: the result must be taken outside the condition.)
        profile("rts_bench_queue_pop"):
            loop:
                MaybeC := Q2.Pop()
                if (not MaybeC?):
                    break
        Sleep(0.0)
        profile("rts_bench_front_push_ring"):
            F := rts_front{}
            for (Index -> C : Cells):
                F.Push(C, 1000 + Mod[Index, 40] or 0)
        Sleep(0.0)
        Sleep(0.0)
        profile("rts_bench_nation_lookup"):
            var M:int = 0
            for (C : Cells):
                if (NationOf[C.Owner]):
                    set M += 1
        Sleep(0.0)
        profile("rts_bench_cell_at"):
            var M2:int = 0
            for (C : Cells, X2 := CellAt[C.I, C.J]):
                set M2 += 1
        Sleep(0.0)
        profile("rts_bench_object_new"):
            for (C : Cells):
                B := gs_batch{Cells := array{}}
        Sleep(0.0)
        profile("rts_bench_material_param"):
            Mat := Materials.M_Tile8x8{}
            for (Index -> C : Cells):
                SetTile8Cell(Mat, Mod[Index, 64] or 0, 2.0)
        Sleep(0.0)
        profile("rts_bench_own_neighbors_unrolled"):
            var K3:int = 0
            for (C : Cells):
                set K3 += OwnNeighborsFast(C, 0)
        Sleep(0.0)
        profile("rts_bench_for_filter_4"):
            var K4:int = 0
            for (C : Cells):
                for (X3 : C.Neighbors, X3.Owner = 0):
                    set K4 += 1
        Sleep(0.0)
        profile("rts_bench_index_4"):
            var K5:int = 0
            for (C : Cells):
                if (X4 := C.Neighbors[0]) { set K5 += X4.Owner }
                if (X4 := C.Neighbors[1]) { set K5 += X4.Owner }
                if (X4 := C.Neighbors[2]) { set K5 += X4.Owner }
                if (X4 := C.Neighbors[3]) { set K5 += X4.Owner }
        Sleep(0.0)
        profile("rts_bench_float_math"):
            var F3:float = 0.0
            for (Index -> C : Cells):
                set F3 += (Index * 1.0) * (1.0 - 0.5 * 2.0 + 1.5 / 2.0)
        Sleep(0.0)
        profile("rts_bench_floor"):
            var K6:int = 0
            for (Index -> C : Cells):
                if (V := Floor[Index * 1.5]) { set K6 += V }
        Sleep(0.0)
        profile("rts_bench_option_wrap"):
            var O:?gs_cell = false
            for (C : Cells):
                set O = option{C}
        Sleep(0.0)
        profile("rts_bench_local_array_set"):
            var Arr:[]gs_cell = Cells
            for (Index -> C : Cells):
                if (set Arr[Index] = C) {}
        Sleep(0.0)
        set BenchArr = Cells
        profile("rts_bench_field_array_set"):
            for (Index -> C : Cells):
                if (set BenchArr[Index] = C) {}
        Sleep(0.0)
        profile("rts_bench_queue_push_batched"):
            Q3 := rts_cell_queue{}
            Q3.Push(Cells)
        Sleep(0.0)
        profile("rts_bench_method_call"):
            var K7:int = 0
            for (C : Cells):
                set K7 += BenchNoop(C)
        Sleep(0.0)
        profile("rts_bench_land_attack_on"):
            if (N := NationList[0]):
                for (C : Cells):
                    LandAttackOn(N, 0)
        Sleep(0.0)
        profile("rts_bench_queue_push_one"):
            Q4 := rts_cell_queue{}
            for (C : Cells):
                Q4.PushOne(C)
        Sleep(0.0)
        profile("rts_bench_borders"):
            var K8:int = 0
            for (C : Cells, TouchesOwner[C, 0]):
                set K8 += 1
        Sleep(0.0)
        Log("Benchmark done (2000 of each, VerseProfile rts_bench_*)")

    var BenchArr:[]gs_cell = array{}
    # round number and the parameter writes collected in the current round.
    var PaintRound:int = 0
    var WriteTiles:[]gs_tile = array{}
    var WritePacks:[]int = array{}
    var ClusterStack:[]gs_cell = array{}
    # Cells with even I and J.
    var SweepCells:[]gs_cell = array{}
    var RebuildJobs:[]rts_scan_job = array{}
    # OpenFront tick x 4 of the current server tick, the roll table and its read position.
    var KeyTick:int = 0
    var RollTable:[]int = array{}
    var RollAt:int = 0
    # Cells the bots' and tribes' attacks may still take in this server tick.
    var TickBudget:int = 0
    # Writes the current paint round may do.
    var RoundWrites:int = 300
    # Cells one human attack run may take in this tick.
    var HumanRunCap:int = 2
    var TickNeutral:int = 0

    BenchNoop(C:gs_cell)<transacts>:int = 1

    # ---------- Boats ----------

    # Static map: the landmasses come precomputed from Landmasses.verse, one fine row of runs (start column, length,
    # id) per step, 20 rows per tick. Returns the count.
    LoadLandmasses()<suspends>:int =
        Masses := for (Size : rts_landmass_sizes):
            gs_landmass{Counts := for (Owner := 0..MaxNations) { if (Owner = 0) then Size else 0 }}
        for (I -> Runs : rts_landmass_runs):
            RunCount := Quotient[Runs.Length, 3] or 0
            for (R := 0..RunCount - 1, J0 := Runs[R * 3], Len := Runs[R * 3 + 1], M := Masses[Runs[R * 3 + 2]], J := J0..J0 + Len - 1, C := CellAt[I, J]):
                set C.Mass = option{M}
            if (Mod[I, 20] = 19):
                Sleep(0.0)
        Masses.Length

    # Static map: highland and mountain cells come from Terrain.verse, runs (start column, length, type) per cell row,
    # 20 rows per tick; all other land is plains. Returns the count.
    LoadTerrain()<suspends>:int =
        var Count:int = 0
        for (I -> Runs : rts_terrain_runs):
            RunCount := Quotient[Runs.Length, 3] or 0
            for (R := 0..RunCount - 1, J0 := Runs[R * 3], Len := Runs[R * 3 + 1], Kind := Runs[R * 3 + 2], J := J0..J0 + Len - 1, C := CellAt[I, J]):
                set C.Terrain = Kind
                set Count += 1
            if (Mod[I, 20] = 19):
                Sleep(0.0)
        Count

    # Labels every land cell with its connected landmass by searching (breadth-first, ~3000 cells per tick). Not used
    # on the static map (see LoadLandmasses); kept for generated maps. Returns the count.
    BuildLandmasses()<suspends>:int =
        var Count:int = 0
        var Steps:int = 0
        for (Seed : AllCells):
            set Steps += 1
            if (Mod[Steps, 3000] = 0):
                Sleep(0.0)
            if (not Seed.Mass?):
                M := gs_landmass{Counts := for (Owner := 0..MaxNations) { 0 }}
                set Count += 1
                set Seed.Mass = option{M}
                Queue := rts_cell_queue{}
                Queue.Push(array{Seed})
                var Size:int = 0
                loop:
                    MaybeC := Queue.Pop()
                    if (C := MaybeC?):
                        set Size += 1
                        Next := for (X : C.Neighbors, not X.Mass?):
                            set X.Mass = option{M}
                            X
                        Queue.Push(Next)
                        set Steps += 1
                        if (Mod[Steps, 3000] = 0):
                            Sleep(0.0)
                    else:
                        break
                if (set M.Counts[0] = Size) {}
        Count

    SeaAt(TI:int, TJ:int)<transacts><decides>:gs_sea =
        SeaColumns[TJ].Cells[TI]?

    # Static map: the sea cells come precomputed from SeaGrid.verse: runs of sea cells per tile row and the coastal
    # cell count of each sea cell next to a coast. Returns the number of sea cells.
    LoadSea()<suspends>:int =
        TilesI := Quotient[GridWidth, 3] or 0
        TilesJ := Quotient[GridHeight, 3] or 0
        NoSea:?gs_sea = false
        set SeaColumns = for (TJ := 0..TilesJ - 1):
            gs_sea_column{Cells := for (TI := 0..TilesI - 1) { NoSea }}
        var Count:int = 0
        for (TI -> Runs : rts_sea_runs):
            RunCount := Quotient[Runs.Length, 2] or 0
            for (R := 0..RunCount - 1, TJ0 := Runs[R * 2], Len := Runs[R * 2 + 1], TJ := TJ0..TJ0 + Len - 1, Column := SeaColumns[TJ]):
                if (set Column.Cells[TI] = option{gs_sea{TI := TI, TJ := TJ}}):
                    set Count += 1
            if (Coast := rts_sea_coast[TI]):
                CoastCount := Quotient[Coast.Length, 2] or 0
                for (K := 0..CoastCount - 1, TJ := Coast[K * 2], Cells := Coast[K * 2 + 1], S := SeaAt[TI, TJ]):
                    set S.Owners = for (Owner := 0..MaxNations) { if (Owner = 0) then Cells else 0 }
            if (Mod[TI, 10] = 9):
                Sleep(0.0)
        Count

    # Route graph from SeaRoutes.verse: each sea cell's node (runs of equal ids in rts_sea_runs order), the nodes with
    # their points, the edges with their turn cells, the nodes' coast owner counts from their sea cells and the search
    # buckets. Call after LoadSea. Returns the number of edges (both directions).
    LoadRoutes()<suspends>:int =
        set RouteNodes = for (Data : rts_route_nodes, Point := SeaAt[Data[0], Data[1]]):
            gs_route_node{Point := Point, Owners := for (Owner := 0..MaxNations) { 0 }}
        if (RouteNodes.Length <> rts_route_nodes.Length):
            Log("Route graph: {rts_route_nodes.Length - RouteNodes.Length} node points are not sea cells, regenerate SeaRoutes.verse")
        for (TI -> Runs : rts_sea_runs, Ids := rts_route_node_of[TI]):
            RunCount := Quotient[Runs.Length, 2] or 0
            Cells := for (R := 0..RunCount - 1, TJ0 := Runs[R * 2], Len := Runs[R * 2 + 1], TJ := TJ0..TJ0 + Len - 1, S := SeaAt[TI, TJ]) { S }
            var At:int = 0
            IdCount := Quotient[Ids.Length, 2] or 0
            for (K := 0..IdCount - 1, Id := Ids[K * 2], Len := Ids[K * 2 + 1]):
                for (X := At..At + Len - 1, S := Cells[X]):
                    set S.Node = Id
                    if (Coast := S.Owners[0], Coast > 0, Node := RouteNodes[Id], V := Node.Owners[0], set Node.Owners[0] = V + Coast) {}
                set At += Len
            if (Mod[TI, 10] = 9):
                Sleep(0.0)
        var EdgeCount:int = 0
        var MaxCost:int = 1
        for (Id -> Data : rts_route_nodes, Node := RouteNodes[Id]):
            var Edges:[]gs_route_edge = array{}
            var At:int = 2
            loop:
                if (To := Data[At], Cost := Data[At + 1], TurnCount := Data[At + 2], ToNode := RouteNodes[To]):
                    Turns := for (K := 0..TurnCount - 1, S := SeaAt[Data[At + 3 + K * 2], Data[At + 4 + K * 2]]) { S }
                    set Edges += array{gs_route_edge{To := ToNode, Cost := Cost, Turns := Turns}}
                    set MaxCost = Max(MaxCost, Cost)
                    set At += 3 + TurnCount * 2
                else:
                    break
            set Node.Edges = Edges
            set EdgeCount += Edges.Length
            if (Mod[Id, 100] = 99):
                Sleep(0.0)
        set RouteBuckets = for (K := 0..MaxCost) { gs_route_bucket{} }
        EdgeCount

    # A sea cell next to coastal cell C (its tile or the 8 around it), fails when C is inland or has no usable sea.
    CoastSea(C:gs_cell)<transacts><decides>:gs_sea =
        C.Neighbors.Length < 4
        TI := Quotient[C.I, 3]
        TJ := Quotient[C.J, 3]
        var Found:?gs_sea = false
        for (DI := -1..1, DJ := -1..1, S := SeaAt[TI + DI, TJ + DJ], not Found?):
            set Found = option{S}
        Found?

    # A coastal cell of N next to sea cell S (in S's tile or the 8 around it), or false.
    OwnCoastNear(N:rts_nation, S:gs_sea)<transacts>:?gs_cell =
        var Found:?gs_cell = false
        for (DI := -3..5, DJ := -3..5, not Found?, C := CellAt[S.TI * 3 + DI, S.TJ * 3 + DJ], C.Owner = N.Id, C.Neighbors.Length < 4):
            set Found = option{C}
        Found

    # World position of a sea cell's center (Up = BoatHeight).
    SeaPos(S:gs_sea)<transacts>:vector3 =
        vector3:
            Forward := OriginX + (S.TI * 3.0 + 1.5) * CellSize
            Left := -(OriginY + (S.TJ * 3.0 + 1.5) * CellSize)
            Up := BoatHeight

    CellPos(C:gs_cell)<transacts>:vector3 =
        vector3:
            Forward := OriginX + (C.I * 1.0 + 0.5) * CellSize
            Left := -(OriginY + (C.J * 1.0 + 0.5) * CellSize)
            Up := BoatHeight

    # The coastal cell nearest Goal on Goal's land that is not N's and touches usable sea (breadth-first over land,
    # at most 3000 cells), or false.
    LandingCell(N:rts_nation, Goal:gs_cell)<suspends>:?gs_cell =
        set LandingStamp += 1
        Id := LandingStamp
        set Goal.Mark = Id
        Queue := rts_cell_queue{}
        Queue.Push(array{Goal})
        var Seen:int = 0
        var Result:?gs_cell = false
        loop:
            MaybeC := Queue.Pop()
            if (C := MaybeC?):
                if (C.Owner <> N.Id, CoastSea[C]):
                    set Result = option{C}
                    break
                set Seen += 1
                set LandingSteps += 1
                if (Seen > 3000):
                    break
                Next := for (X : C.Neighbors, X.Mark <> Id):
                    set X.Mark = Id
                    X
                Queue.Push(Next)
                if (Mod[Seen, 300] = 0):
                    Sleep(0.0)
            else:
                break
        Result

    # Route from N's coast to Landing: nearest-first search over the route nodes from the landing's node (Dial's
    # buckets) until a node next to N's coast (Owners); inside that node a breadth-first search from its point to a
    # sea cell next to N's coast, inside the landing's node one from its point to the landing's sea cell. Returns the
    # sea cells in sailing order (first = at N's coast; between two node points only the turn cells) and the cell the
    # boat leaves from.
    FindRoute(N:rts_nation, Landing:gs_cell)<suspends>:?tuple([]gs_sea, gs_cell) =
        loop:
            if (not RouteBusy?):
                break
            Sleep(0.0)
        set RouteBusy = true
        set RouteStamp += 1
        Id := RouteStamp
        var Result:?tuple([]gs_sea, gs_cell) = false
        var Searched:int = 0
        T0 := GetSimulationElapsedTime()
        if (Start := CoastSea[Landing], StartNode := RouteNodes[Start.Node]):
            if (Own := Start.Owners[N.Id], Own > 0, From := OwnCoastNear(N, Start)?):
                # N's coast is right at the landing.
                set Result = option{(array{Start}, From)}
            else:
                BucketCount := RouteBuckets.Length
                for (B : RouteBuckets):
                    set B.Head = false
                set StartNode.Stamp = Id
                set StartNode.Dist = 0
                set StartNode.Done = false
                set StartNode.Parent = false
                set StartNode.Via = false
                if (B := RouteBuckets[0]):
                    set B.Head = option{gs_route_item{Node := StartNode, Dist := 0}}
                var Pending:int = 1
                var D:int = 0
                var Budget:int = RouteBudget()
                loop:
                    if (Pending <= 0 or Result?):
                        break
                    if (Bucket := RouteBuckets[Mod[D, BucketCount]], Item := Bucket.Head?):
                        set Bucket.Head = Item.Next
                        set Pending -= 1
                        Node := Item.Node
                        # Skip entries left behind by a shorter way to the same node.
                        if (Item.Dist = Node.Dist, not Node.Done?):
                            set Node.Done = true
                            set Searched += 1
                            set RouteSteps += 1
                            if (NodeOwn := Node.Owners[N.Id], NodeOwn > 0, Coast := LocalPath(Node.Point, option{N}, false)?, From := Coast(1)?):
                                set Result = option{(RoutePath(Coast(0), Node, StartNode, Start), From)}
                            else:
                                for (E : Node.Edges):
                                    X := E.To
                                    ND := Node.Dist + E.Cost
                                    if (X.Stamp <> Id or (not X.Done? and ND < X.Dist)):
                                        set X.Stamp = Id
                                        set X.Dist = ND
                                        set X.Done = false
                                        set X.Parent = option{Node}
                                        set X.Via = option{E}
                                        if (B := RouteBuckets[Mod[ND, BucketCount]]):
                                            set B.Head = option{gs_route_item{Node := X, Dist := ND, Next := B.Head}}
                                            set Pending += 1
                            set Budget -= 1
                            if (Budget <= 0):
                                set Budget = RouteBudget()
                                Sleep(0.0)
                    else:
                        set D += 1
        set RouteBusy = false
        if (N.Human?):
            Points := if (R := Result?) then R(0).Length else 0
            Log("{NationName(N)}: route search {Searched} graph nodes, {Points} route points in {GetSimulationElapsedTime() - T0} s")
        if (not Result?, N.Human?):
            Log("{NationName(N)}: no route, searched {Searched} graph nodes from landing cell {Landing.I}, {Landing.J}, none next to your {N.CoastCells} coastal cells")
        Result

    # Sailing order of a found route (FindRoute): Coast (the sea cell next to N's coast .. Goal node's point), then from
    # node to node back to the start node (each edge's turn cells reversed, then the parent's point), then the start
    # node's point .. the landing's sea cell Start.
    RoutePath(Coast:[]gs_sea, Goal:gs_route_node, StartNode:gs_route_node, Start:gs_sea)<transacts>:[]gs_sea =
        var Path:[]gs_sea = Coast
        var At:gs_route_node = Goal
        loop:
            if (P := At.Parent?, E := At.Via?):
                set Path += for (K := 0..E.Turns.Length - 1, T := E.Turns[E.Turns.Length - 1 - K]) { T }
                set Path += array{P.Point}
                set At = P
            else:
                break
        if (Landing := LocalPath(StartNode.Point, false, option{Start})?):
            # Landing(0) runs from Start back to the point (the point is in Path already).
            Back := Landing(0)
            set Path += for (K := 1..Back.Length - 1, T := Back[Back.Length - 1 - K]) { T }
        else:
            set Path += array{Start}
        Path

    # Breadth-first search over the sea cells of From's route node (at most 64), from From to Goal, or with N to the
    # first sea cell next to a coastal cell of N. Returns the cells from the found cell back to From and, with N, the
    # coastal cell of N there.
    LocalPath(From:gs_sea, N:?rts_nation, Goal:?gs_sea)<transacts>:?tuple([]gs_sea, ?gs_cell) =
        set RouteStamp += 1
        Id := RouteStamp
        set From.Stamp = Id
        set From.Parent = false
        var Queue:[]gs_sea = array{From}
        var Head:int = 0
        var Result:?tuple([]gs_sea, ?gs_cell) = false
        loop:
            if (S := Queue[Head]):
                set Head += 1
                set RouteSteps += 1
                var Coast:?gs_cell = false
                var Hit:logic = false
                if (G := Goal?, G.TI = S.TI, G.TJ = S.TJ):
                    set Hit = true
                else if (Nation := N?, Own := S.Owners[Nation.Id], Own > 0, C := OwnCoastNear(Nation, S)?):
                    set Coast = option{C}
                    set Hit = true
                if (Hit?):
                    var Chain:[]gs_sea = array{}
                    var At:?gs_sea = option{S}
                    loop:
                        if (A := At?):
                            set Chain += array{A}
                            set At = A.Parent
                        else:
                            break
                    set Result = option{(Chain, Coast)}
                    break
                for (DI := -1..1, DJ := -1..1, DI <> 0 or DJ <> 0, X := SeaAt[S.TI + DI, S.TJ + DJ], X.Node = From.Node, X.Stamp <> Id):
                    set X.Stamp = Id
                    set X.Parent = option{S}
                    set Queue += array{X}
            else:
                break
        Result

    # Sends a boat of N toward Goal: finds the landing shore and the route, takes AttackShare of N's troops, sails,
    # lands and attacks from the landing cell toward Goal.
    SendBoat(N:rts_nation, Goal:gs_cell)<suspends>:void =
        IsPlayer := IsHuman(N)
        if (N.Boats >= MaxBoatsPerNation):
            return
        if (N.CoastCells <= 0):
            if (IsPlayer?):
                Log("{NationName(N)}: your nation has no coast yet, conquer a coastal cell first")
                NationNote(N, "Your nation has no coast yet")
            return
        set N.Boats += 1
        MaybeLanding := LandingCell(N, Goal)
        MaybeRoute:?tuple([]gs_sea, gs_cell) = if (Landing := MaybeLanding?) then FindRoute(N, Landing) else false
        MaybeBoat := FreeBoat()
        if (Landing := MaybeLanding?, Route := MaybeRoute?, Boat := MaybeBoat?, N.Troops >= 1.0):
            Path := Route(0)
            From := Route(1)
            Troops := N.Troops * (if (N.Human?) then RatioOf(N) else BoatShare)
            set N.Troops -= Troops
            set N.BoatTroops += Troops
            if (IsPlayer?):
                Log("{NationName(N)}: boat with {Floor[Troops] or 0} troops from cell {From.I}, {From.J} to {Landing.I}, {Landing.J} ({Path.Length} sea cells)")
            Sail(N, Boat, From, Path, Landing)
            set N.BoatTroops -= Troops
            Land(N, Landing, Goal, Troops)
            set Boat.Busy = false
            ParkBoat(Boat.Prop)
        else:
            if (Boat := MaybeBoat?):
                set Boat.Busy = false
            if (IsPlayer?):
                if (not MaybeLanding?):
                    Log("{NationName(N)}: no coast to land on near cell {Goal.I}, {Goal.J}")
                    NationNote(N, "No coast to land on there")
                else if (not MaybeRoute?):
                    Log("{NationName(N)}: no sea route from your coast to there")
                    NationNote(N, "No sea route from your coast to there")
                else if (not MaybeBoat?):
                    Log("{NationName(N)}: no free boat prop (tag rts_boat)")
                    NationNote(N, "No free boat")
        set N.Boats -= 1

    FreeBoat()<transacts>:?gs_boat =
        var Result:?gs_boat = false
        for (B : BoatPool, not B.Busy?, not Result?):
            set B.Busy = true
            set Result = option{B}
        Result

    # Moves the boat icon from From's coast to Landing at BoatSpeed in N's color, over the sea cells of the route
    # cut into straight runs over open sea (few long MoveTo calls: many short ones stuttered). The cutting runs one
    # step per tick before the boat appears.
    Sail(N:rts_nation, Boat:gs_boat, From:gs_cell, Path:[]gs_sea, Landing:gs_cell)<suspends>:void =
        # Same palette texture as the tiles (index = owner + 1), so the boat matches its nation's land exactly.
        Mat := VFX.M_BoatIcon{}
        set Mat.Index = (N.Id + 1) * 1.0
        Boat.Prop.SetMaterial(Mat)
        Points := StraightRuns(array{CellPos(From)} + (for (S : Path) { SeaPos(S) }) + array{CellPos(Landing)})
        Scale := Boat.Prop.GetGlobalTransform().Scale
        var Last:vector3 = CellPos(From)
        if (Boat.Prop.TeleportTo[IconTransform(Last, Scale)]) {}
        for (Index -> P : Points, Index > 0):
            Dist := Distance(Last, P)
            if (Dist > 0.1):
                Boat.Prop.MoveTo(IconTransform(P, Scale), Dist / Max(1.0, BoatSpeed))
            set Last = P

    # Puts a free boat under the map center, shown (see BoatParkDepth).
    ParkBoat(Prop:creative_prop):void =
        Scale := Prop.GetGlobalTransform().Scale
        if (Prop.TeleportTo[transform{Translation := vector3{Forward := 0.0, Left := 0.0, Up := -BoatParkDepth}, Rotation := IdentityRotation(), Scale := Scale}]) {}
        Prop.Show()

    # Transform that puts the icon's center on P (the cube pivot is its max X / Y corner; Left = -Y).
    IconTransform(P:vector3, Scale:vector3)<transacts>:transform =
        Half := BoatIconSize * 0.5
        transform{Translation := vector3{Forward := P.Forward + Half, Left := P.Left - Half, Up := P.Up}, Rotation := IdentityRotation(), Scale := Scale}

    # Keeps only the points where the course has to turn: from each kept point, the farthest later point that is
    # reached in a straight line over sea cells (at most 20 points ahead). The first and last points (coast cells) are
    # always kept.
    StraightRuns(Points:[]vector3)<suspends>:[]vector3 =
        var Result:[]vector3 = array{}
        var At:int = 0
        if (First := Points[0]):
            set Result += array{First}
        loop:
            if (At >= Points.Length - 1):
                break
            var Next:int = At + 1
            # Look at most 20 points ahead (keeps one step cheap); one step per server tick.
            for (J := At + 2..Min(At + 20, Points.Length - 1), A := Points[At], B := Points[J], OpenSea[A, B]):
                set Next = J
            if (P := Points[Next]):
                set Result += array{P}
            set At = Next
            Sleep(0.0)
        Result

    # Succeeds when the straight line from A to B crosses only sea cells (checked every 15 cm = one sea cell, ends
    # excluded).
    OpenSea(A:vector3, B:vector3)<transacts><decides>:void =
        Dist := Distance(A, B)
        Steps := Max(1, Floor[Dist / 15.0] or 1)
        for (K := 1..Steps - 1):
            T := K * 1.0 / (Steps * 1.0)
            P := A + (B - A) * T
            TI := Floor[((P.Forward - OriginX) / CellSize) / 3.0]
            TJ := Floor[((-P.Left - OriginY) / CellSize) / 3.0]
            SeaAt[TI, TJ]

    # The boat arrives (OpenFront TransportShipExecution): the landing cell becomes N's and a boat attack with the
    # boat's troops starts there on the shore's owner (the goal's owner when the shore is N's already); it grows only
    # from the landing cell. With nothing to attack the troops go home.
    Land(N:rts_nation, Landing:gs_cell, Goal:gs_cell, Troops:float):void =
        # A nation whose player left takes no land: the boat's troops are lost.
        if (N.Eliminated? or N.Left?):
            return
        Target := if (Landing.Owner <> N.Id) then Landing.Owner else Goal.Owner
        if (Landing.Owner <> N.Id):
            Take(N, Landing)
        Started:logic = if (Target <> N.Id) then LaunchAttack(N, Target, Troops, option{Landing}) else false
        if (not Started?, Target = N.Id):
            set N.Troops += Troops
        if (N.Human?):
            Log("{NationName(N)}: boat landed at cell {Landing.I}, {Landing.J}" + (if (Started?) then ", attacking owner {Target}" else ""))

    NationName(N:rts_nation):string =
        if (N.Tribe?) then N.Name
        else if (N.Left?) then "Player {N.Id} (left)"
        else if (N.Human?) then "Player {N.Id}"
        else "Bot_{N.Id}"

    # Troops as a short number: 950, 12.3k, 1.2M.
    PowerText(Troops:float):string =
        T := Floor[Troops] or 0
        if (T >= 1000000, M := Quotient[T, 1000000], D := Mod[Quotient[T, 100000] or 0, 10]):
            "{M}.{D}M"
        else if (T >= 1000, K := Quotient[T, 1000], D := Mod[Quotient[T, 100] or 0, 10]):
            "{K}.{D}k"
        else:
            "{T}"

    Largest()<transacts><decides>:rts_nation =
        var Best:?rts_nation = false
        for (N : NationList):
            if (B := Best?):
                if (N.Cells > B.Cells):
                    set Best = option{N}
            else:
                set Best = option{N}
        Best?

    # Every 2 s: server tick rate, cell changes and paints per second, paint backlog, nations and attacks.
    StatsLoop()<suspends>:void =
        loop:
            T0 := GetSimulationElapsedTime()
            Changed0 := ChangedTotal
            Painted0 := PaintedTotal
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
            Span := Last - T0
            var AliveCount:int = 0
            var OnNeutral:int = 0
            var OnEnemy:int = 0
            var Boats:int = 0
            var Owned:int = 0
            var TribesAlive:int = 0
            var TribeCells:int = 0
            for (N : NationList):
                set Owned += N.Cells
                if (not N.Eliminated?):
                    set AliveCount += 1
                    if (N.Tribe?):
                        set TribesAlive += 1
                        set TribeCells += N.Cells
                    for (A : N.Attacks, not A.Done?):
                        if (A.Target = 0) then set OnNeutral += 1 else set OnEnemy += 1
                        if (A.Beach?) then set Boats += 1
            var Top:string = "-"
            if (Best := Largest[], Troops := Floor[Best.Troops]):
                set Top = "nation {Best.Id} {Best.Cells} cells, {Troops} troops"
            var You:string = ""
            for (Player : NationList, Player.Human?, Troops := Floor[Player.Troops]):
                set You += " | P{Player.Id} {Player.Cells} cells, {Troops} troops, {Player.Attacks.Length} attacks"
            Log("Work: rebuilds {RebuildsDone} ({RebuildEntries} entries, {RebuildJobs.Length} queued), border pushes {FrontPushes}, bot decisions {BotDecisions}, route steps {RouteSteps}, landing steps {LandingSteps}, name box steps {ClusterSteps} | tribe decisions {TribeDecisions}, tribe attacks {TribeAttacks}, attack label calls {AttackLabelCalls}, attack labels shown {AttackLabelsShown} of {AttackLabelsWanted} wanted, border repaints {BorderRefreshes} ({BorderJobCount} jobs waiting, {BorderRestarts} restarted), material writes {ParamWrites}, paint skips {PaintSkips}, take skips {TakeSkips} (last 2 s)")
            Log("Attacks: runs {AttackRuns} ({ZeroRuns} took no cell), pops {AttackPops} (stale {StalePops}, {PopSteps} empty bucket steps), cells taken {CellsTaken} (humans {HumanTaken} of {Floor[HumanGiven] or 0} shared out), key pushes {KeyPushes}, sampled runs {SampleRuns} with {SampleRunCells} cells (last 2 s)")
            set AttackRuns = 0
            set AttackPops = 0
            set StalePops = 0
            set PopSteps = 0
            set ZeroRuns = 0
            set CellsTaken = 0
            set HumanTaken = 0
            set KeyPushes = 0
            set HumanGiven = 0.0
            set SampleRuns = 0
            set SampleRunCells = 0
            set BorderRestarts = 0
            set BorderRefreshes = 0
            set PaintSkips = 0
            set TakeSkips = 0
            set ParamWrites = 0
            set RebuildsDone = 0
            set RebuildEntries = 0
            set FrontPushes = 0
            set BotDecisions = 0
            set RouteSteps = 0
            set LandingSteps = 0
            set ClusterSteps = 0
            set TribeDecisions = 0
            set TribeAttacks = 0
            set AttackLabelCalls = 0
            set AttackLabelsWanted = 0
            set AttackLabelsShown = 0
            Log("Server: {Ticks * 1.0 / Span} ticks/s, worst tick {Worst * 1000.0} ms | changes {(ChangedTotal - Changed0) * 1.0 / Span}/s, paints {(PaintedTotal - Painted0) * 1.0 / Span}/s, waiting {QueuedCount}, capped {CapHits}, cap {ConquestCap} | nations {AliveCount} (tribes {TribesAlive}, cells {TribeCells}), attacks neutral {OnNeutral} enemy {OnEnemy} (boat {Boats}), neutral {LandCells - Owned}, largest {Top}{You}")
            set CapHits = 0
