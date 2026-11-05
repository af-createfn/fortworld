# RTS camera controller.
# Top-down camera per player that orbits a focus point on the ground:
#   * left mouse drag  : grab and move the map (a fast release keeps it gliding only with Swipe on)
#   * left mouse click : select, signals ClickEvent with the player, the hit entity and the ground point
#   * Q / E            : rotate the view by RotateStep, only with AllowRotation on
#   * Z / C            : zoom in / out by ZoomStep
# SetStatus shows a game message at the top of a player's screen. A player who leaves frees the camera.
# Built on the results of the RTS input tests (RTSTest/VD_RTSInputTest.verse):
#   * mouse clicks reach Verse only with Input/UI TouchMapping and a UI with InputMode All,
#   * that mode blocks all gameplay keys (WASD), but the MenuNavigationMapping keys Q/E/Z/C still arrive,
#   * PointerSelect TriggerActivationEvent repeats every frame while held (drag stream),
#   * FindSweepHits with collision_point works as a ray cast against props, the grid floor is not hit.
# Cameras: Fixed Point Camera devices tagged rts_player_camera (one per player, Add To Players On Start off); their
# placed rotation gives the view pitch and the start yaw. StartFor(Player, Focus) gives a player a free camera from
# that pool looking at Focus (called by VD_GameSim when the lobby ends).
# FollowCamera. Verse only runs on the server, so the
# smooth part is left to the camera devices, which run on each client: Fixed Angle cameras tagged rts_zoom_camera, one
# per zoom level, shared by all players (a camera device follows the player it is added to). Verse moves the player's
# hidden character to the focus point; the camera follows it with the device's own follow smoothing (Horizontal Speed),
# and a zoom step swaps to the next level's camera, which blends over on the client (Transition In Time). The fixed
# point pool camera then only gives the view rotation. The character at the focus also puts Fortnite's net relevancy
# where the player looks (zoom analysis: far tiles went stale with the character parked off the map).

using { /Fortnite.com/Devices }
using { /Fortnite.com/Characters }
using { /Fortnite.com/UI }
using { /Verse.org/Simulation }
using { /Verse.org/Simulation/Tags }
using { /Verse.org/SpatialMath }
using { /Verse.org/SceneGraph }
using { /Verse.org/Input }
using { /Verse.org/Input/UI }
using { /Fortnite.com/Input/Character }
using { /Verse.org/Colors }
using { /UnrealEngine.com/Temporary/UI }

# Verse tag on the Fixed Point cameras of the pool (one per player).
rts_player_camera<public> := class(tag){}

# Verse tag on the Fixed Angle cameras of the zoom levels (FollowCamera). Place each one at a height (Z) equal to its
# Distance setting: Verse cannot read device settings, so it sorts the levels by that height and uses it as the distance.
rts_zoom_camera<public> := class(tag){}

# One zoom level: its camera and distance (cm).
rts_zoom_level := class:
    Camera:gameplay_camera_fixed_angle_device
    Dist:float

# Result of a mouse click, signaled by VD_RTSCamera.ClickEvent.
rts_click<public> := struct:
    Player<public>:player
    # Viewport position of the click (Left = right from the top-left corner, Up = negative downwards).
    ScreenPosition<public>:vector3
    # Where the click ray meets the ground plane (GroundZ).
    GroundPoint<public>:vector3
    # The first object the ray hit, false when it only hit the ground.
    HitEntity<public>:?entity
    # Contact point on HitEntity, or GroundPoint when nothing was hit.
    HitPoint<public>:vector3

RTSCameraText<localizes>(S:string):message = "{S}"

# One player's camera and its state.
rts_camera_view := class:
    Player:player
    Camera:gameplay_camera_fixed_point_device
    # Index of Camera in the pool (devices cannot be compared).
    PoolIndex:int
    BaseRot:rotation
    var Focus:vector3 = vector3{Forward := 0.0, Left := 0.0, Up := 0.0}
    var TargetYaw:float = 0.0
    var CurYaw:float = 0.0
    var TargetDist:float = 3000.0
    var CurDist:float = 3000.0

    var Pressed:logic = false
    var Dragging:logic = false
    var PressStart:vector3 = vector3{Forward := 0.0, Left := 0.0, Up := 0.0}
    var PressLast:vector3 = vector3{Forward := 0.0, Left := 0.0, Up := 0.0}
    var PressRayOrigin:vector3 = vector3{Forward := 0.0, Left := 0.0, Up := 0.0}
    var PressRayDir:vector3 = vector3{Forward := 0.0, Left := 0.0, Up := -1.0}
    var DragNowDir:vector3 = vector3{Forward := 0.0, Left := 0.0, Up := -1.0}
    var DragFocusStart:vector3 = vector3{Forward := 0.0, Left := 0.0, Up := 0.0}
    var DragHeight:float = 3000.0
    var DragVel:vector3 = vector3{Forward := 0.0, Left := 0.0, Up := 0.0}
    var Coast:vector3 = vector3{Forward := 0.0, Left := 0.0, Up := 0.0}
    var LastKeyTime:[string]float = map{}
    # FollowCamera: current zoom level (index into ZoomLevels) and the level whose camera P has now (-1 = none).
    var Level:int = 0
    var ShownLevel:int = -1
    # Last camera position and yaw sent to the device (server-moved camera only).
    var LastPos:vector3 = vector3{Forward := 0.0, Left := 0.0, Up := 0.0}
    var LastYaw:float = 0.0

VD_RTSCamera<public> := class(creative_device):

    # Height of the ground plane used for dragging and click ground points (cm).
    @editable
    GroundZ:float = 0.0

    # Camera distance from the focus point when a player's camera starts (cm).
    @editable
    StartDistance:float = 3000.0

    # Closest and farthest camera distance from the focus point (cm).
    @editable
    MinDistance:float = 1200.0

    @editable
    MaxDistance:float = 9000.0

    # One Z / C press divides / multiplies the distance by this.
    @editable
    ZoomStep:float = 1.3

    # Q / E turn the view by RotateStep degrees. Off by default.
    @editable
    AllowRotation:logic = false

    @editable
    RotateStep:float = 45.0

    # How fast zoom and rotation reach their target (higher = snappier).
    @editable
    Smoothing:float = 8.0

    # A fast drag release keeps the map gliding (swipe). Off by default.
    @editable
    Swipe:logic = false

    # Swipe: share of the glide speed kept per 0.05 s step (0..1).
    @editable
    SwipeDecay:float = 0.9

    # Releases slower than this (cm/s) do not glide.
    @editable
    SwipeMinSpeed:float = 300.0

    # A press that moves less than this (viewport units) is a click, not a drag.
    @editable
    ClickMaxMove:float = 0.8

    # The focus point stays inside these world bounds (cm).
    @editable
    MinForward:float = -12000.0

    @editable
    MaxForward:float = 12000.0

    @editable
    MinLeft:float = -12000.0

    @editable
    MaxLeft:float = 12000.0

    # Length of the click ray (cm).
    @editable
    RayLength:float = 100000.0

    # Hide the player's character while it is the camera operator.
    @editable
    HidePlayerCharacter:logic = true

    # Show the control hint at the bottom of the screen.
    @editable
    ShowHelp:logic = true

    # Print [RTSCamera] lines (clicks, zoom, rotation).
    @editable
    DebugLog:logic = true

    # True: the click (ClickEvent) fires when the left button goes down. False: on release, and only if it was no drag.
    # Release is the default: with left drag panning, a press-click fired on every drag start.
    @editable
    ClickOnPress:logic = false

    # Left button drag moves the map. Verse only exposes the left button with a cursor position (PointerSelect);
    # tested: in mouse mode neither WeaponSecondary (right mouse) nor WeaponPrimary reach Verse.
    @editable
    LeftDragPans:logic = true

    # Log every left press and the Fortnite fire / aim actions (left / right mouse) with [RTSCamera] input lines.
    @editable
    InputDiagnostics:logic = false

    # Client-side camera: the player's hidden character stands on the focus point and the zoom level cameras
    # (tag rts_zoom_camera) follow it. Off, or with no zoom cameras placed: the old server-moved fixed point camera.
    @editable
    FollowCamera:logic = true

    # FollowCamera: height above GroundZ the character is teleported to (it drops onto the map).
    @editable
    CharacterHeight:float = 100.0

    # Signaled for every mouse click (not for drags).
    ClickEvent<public>:event(rts_click) = event(rts_click){}

    StepTime<private>:float = 0.05

    var Pool:[]gameplay_camera_fixed_point_device = array{}
    var Used:[]logic = array{}
    var Views:[player]rts_camera_view = map{}
    var Status:[player]text_block = map{}
    # FollowCamera zoom levels, nearest first (empty = FollowCamera off).
    var ZoomLevels:[]rts_zoom_level = array{}
    # Watch counters for the playtest: character moves (focus changed), drift fixes
    # (character away from the focus), failed teleports, zoom camera swaps.
    var CharacterMoves:int = 0
    var DriftFixes:int = 0
    var TeleportFails:int = 0
    var ZoomSwaps:int = 0

    OnBegin<override>()<suspends>:void =
        set Pool = for (Obj : Self.FindCreativeObjectsWithTag(rts_player_camera), Cam := gameplay_camera_fixed_point_device[Obj]):
            Cam
        set Used = for (Cam : Pool) { false }
        if (FollowCamera?):
            var Levels:[]rts_zoom_level = array{}
            for (Obj : Self.FindCreativeObjectsWithTag(rts_zoom_camera), Cam := gameplay_camera_fixed_angle_device[Obj]):
                New := rts_zoom_level{Camera := Cam, Dist := Cam.GetGlobalTransform().Translation.Up}
                # Insertion by distance (a handful of levels).
                Before := for (L : Levels, L.Dist <= New.Dist) { L }
                After := for (L : Levels, L.Dist > New.Dist) { L }
                set Levels = Before + array{New} + After
            set ZoomLevels = Levels
        GetPlayspace().PlayerRemovedEvent().Subscribe(OnPlayerRemoved)
        spawn{ CamerasLoop() }
        Log("Ready: {Pool.Length} cameras (tag rts_player_camera), {ZoomLevels.Length} zoom levels (tag rts_zoom_camera)")
        var Dists:string = ""
        for (L : ZoomLevels):
            set Dists += " {L.Dist}"
        if (ZoomLevels.Length > 0):
            Log("Zoom level distances (camera Z):{Dists}")
            spawn{ WatchLoop() }

    # Every 5 s while a camera runs: the FollowCamera counters (one [RTSCamera] Watch line, playtest check).
    WatchLoop()<suspends>:void =
        loop:
            Sleep(5.0)
            if (Views.Length > 0):
                Log("Watch: {Views.Length} cameras, character moves {CharacterMoves}, drift fixes {DriftFixes}, teleport fails {TeleportFails}, zoom swaps {ZoomSwaps} (last 5 s)")
            set CharacterMoves = 0
            set DriftFixes = 0
            set TeleportFails = 0
            set ZoomSwaps = 0

    # A player who leaves gives the camera back to the pool (CamerasLoop no longer sees the view).
    OnPlayerRemoved(P:player):void =
        if (View := Views[P]):
            if (set Used[View.PoolIndex] = false) {}
            var Kept:[player]rts_camera_view = map{}
            for (Key -> V : Views, Key <> P):
                if (set Kept[Key] = V) {}
            set Views = Kept
            Log("Player left, camera freed")

    # A line of text at the top of P's screen (game messages: eliminated, winner). Empty = hidden.
    SetStatus<public>(P:player, S:string):void =
        if (T := Status[P]):
            T.SetText(RTSCameraText(S))

    Log(S:string):void =
        if (DebugLog?):
            Print("[RTSCamera] {S}", ?Duration := 4.0)

    V3(V:vector3):string =
        "({V.Forward}, {V.Left}, {V.Up})"

    Zero()<computes>:vector3 =
        vector3{Forward := 0.0, Left := 0.0, Up := 0.0}

    # ---------- Setup ----------

    # Gives P a free camera of the pool looking at Focus (on the ground). False when P already has one or the pool is
    # empty.
    StartFor<public>(P:player, Focus:vector3):logic =
        if (Views[P]):
            return false
        var Found:int = -1
        for (Index -> U : Used, U = false, Found < 0):
            set Found = Index
        if (Cam := Pool[Found], set Used[Found] = true):
            View := rts_camera_view:
                Player := P
                Camera := Cam
                PoolIndex := Found
                BaseRot := Cam.GetGlobalTransform().Rotation
            set View.Focus = vector3{Forward := Focus.Forward, Left := Focus.Left, Up := GroundZ}
            set View.TargetDist = Clamp(StartDistance, MinDistance, MaxDistance)
            if (ZoomLevels.Length > 0):
                # The level nearest StartDistance.
                for (Index -> L : ZoomLevels, Near := ZoomLevels[View.Level], Abs(L.Dist - StartDistance) < Abs(Near.Dist - StartDistance)):
                    set View.Level = Index
                if (L := ZoomLevels[View.Level]):
                    set View.TargetDist = L.Dist
            set View.CurDist = View.TargetDist
            if (set Views[P] = View) {}
            StartView(View)
            set View.LastPos = CameraPosition(View)
            Log("Camera {Found} started at {V3(View.Focus)}")
            true
        else:
            Log("No free camera (tag rts_player_camera) for a player")
            false

    StartView(View:rts_camera_view):void =
        P := View.Player
        if (ZoomLevels.Length > 0):
            MoveCharacter(View)
            ShowLevel(View)
        else:
            MoveCameraNow(View)
            View.Camera.AddTo(P)
        if (HidePlayerCharacter?, Char := P.GetFortCharacter[]):
            Char.Hide()
        if (PI := GetPlayerInput[P]):
            PI.AddInputMapping(TouchMapping)
            PI.AddInputMapping(MenuNavigationMapping)
            Select := PI.GetInputEvents(PointerSelect)
            Select.BeginDetectEvent.Subscribe(OnPressBegin)
            Select.TriggerActivationEvent.Subscribe(OnPressMove)
            Select.EndDetectEvent.Subscribe(OnPressEnd)
            if (AllowRotation?):
                PI.GetInputEvents(PreviousTab).TriggerActivationEvent.Subscribe(OnRotateLeft)
                PI.GetInputEvents(NextTab).TriggerActivationEvent.Subscribe(OnRotateRight)
            PI.GetInputEvents(PreviousPage).TriggerActivationEvent.Subscribe(OnZoomIn)
            PI.GetInputEvents(NextPage).TriggerActivationEvent.Subscribe(OnZoomOut)
            if (InputDiagnostics?):
                # Does the right mouse button (Fortnite aim = WeaponSecondary) reach Verse in mouse mode?
                PI.AddInputMapping(RangedWeaponMapping)
                PI.GetInputEvents(WeaponSecondary).BeginDetectEvent.Subscribe(OnAimBegin)
                PI.GetInputEvents(WeaponSecondary).EndDetectEvent.Subscribe(OnAimEnd)
                PI.GetInputEvents(WeaponPrimary).BeginDetectEvent.Subscribe(OnFireBegin)
        else:
            Log("GetPlayerInput failed, no mouse or key input")
        ShowInputLayer(P)

    # Full screen invisible UI layer: shows the mouse cursor and lets PointerSelect clicks through.
    ShowInputLayer(P:player):void =
        if (PlayerUI := GetPlayerUI[P]):
            Layer := canvas:
                Slots := array:
                    canvas_slot:
                        Anchors := RTSAnchors(0.0, 0.0, 1.0, 1.0)
                        Offsets := margin{Left := 0.0, Top := 0.0, Right := 0.0, Bottom := 0.0}
                        Widget := color_block{DefaultColor := NamedColors.Black, DefaultOpacity := 0.0}
            StatusText := text_block:
                DefaultText := RTSCameraText("")
                DefaultTextColor := NamedColors.White
                DefaultJustification := text_justification.Center
            StatusSlot := canvas_slot:
                Anchors := RTSAnchors(0.5, 0.0, 0.5, 0.0)
                Alignment := RTSVector2(0.5, 0.0)
                Offsets := margin{Left := 0.0, Top := 120.0, Right := 0.0, Bottom := 0.0}
                SizeToContent := true
                Widget := StatusText
            Layer.AddWidget(StatusSlot)
            if (set Status[P] = StatusText) {}
            if (ShowHelp?):
                Keys := if (AllowRotation?) then "Drag: move map    Click: actions    Q / E: rotate    Z / C: zoom" else "Drag: move map    Click: actions    Z / C: zoom"
                Help := text_block{DefaultText := RTSCameraText(Keys), DefaultTextColor := NamedColors.White}
                HelpSlot := canvas_slot:
                    Anchors := RTSAnchors(0.0, 1.0, 0.0, 1.0)
                    Alignment := RTSVector2(0.0, 1.0)
                    Offsets := margin{Left := 40.0, Top := -40.0, Right := 0.0, Bottom := 0.0}
                    SizeToContent := true
                    Widget := Help
                Layer.AddWidget(HelpSlot)
            PlayerUI.AddWidget(Layer, player_ui_slot{InputMode := ui_input_mode.All})

    # ---------- Mouse ----------

    OnPressBegin(Payload:tuple(player, vector3)):void =
        if (View := Views[Payload(0)]):
            Ray := Payload(0).DeprojectViewportToWorld(Payload(1))
            set View.Pressed = true
            set View.Dragging = false
            set View.PressStart = Payload(1)
            set View.PressLast = Payload(1)
            set View.PressRayOrigin = Ray.Origin
            set View.PressRayDir = Ray.Direction
            set View.DragNowDir = Ray.Direction
            set View.DragFocusStart = View.Focus
            # The ray starts at the camera the client really shows (FollowCamera: the device's smoothed position).
            set View.DragHeight = Ray.Origin.Up - GroundZ
            set View.DragVel = Zero()
            set View.Coast = Zero()
            if (InputDiagnostics?):
                Log("input: PointerSelect press at {V3(Payload(1))}")
            if (ClickOnPress?):
                HandleClick(View)

    OnAimBegin(Payload:tuple(player, logic)):void =
        Log("input: WeaponSecondary (right mouse) pressed")

    OnAimEnd(Payload:tuple(player, float)):void =
        Log("input: WeaponSecondary (right mouse) released after {Payload(1)} s")

    OnFireBegin(Payload:tuple(player, logic)):void =
        Log("input: WeaponPrimary (left mouse) pressed")

    # Repeats every frame while the button is held, with the current cursor position.
    OnPressMove(Payload:tuple(player, vector3)):void =
        if (View := Views[Payload(0)], View.Pressed?):
            set View.PressLast = Payload(1)
            set View.DragNowDir = Payload(0).DeprojectViewportToWorld(Payload(1)).Direction
            if (LeftDragPans?, not View.Dragging?, Distance(View.PressLast, View.PressStart) > ClickMaxMove):
                set View.Dragging = true

    OnPressEnd(Payload:tuple(player, float)):void =
        if (View := Views[Payload(0)]):
            set View.Pressed = false
            if (View.Dragging?):
                set View.Dragging = false
                Speed := Distance(View.DragVel, Zero())
                if (Swipe?, Speed >= SwipeMinSpeed):
                    set View.Coast = View.DragVel
            else if (not ClickOnPress?):
                HandleClick(View)

    HandleClick(View:rts_camera_view):void =
        Origin := View.PressRayOrigin
        Dir := View.PressRayDir
        Ground := if (Dir.Up < -0.0001) then Origin + Dir * ((GroundZ - Origin.Up) / Dir.Up) else Origin
        var HitEntity:?entity = false
        var HitPoint:vector3 = Ground
        if (Sim := Self.GetSimulationEntity[]):
            Start := transform{Translation := Origin, Rotation := IdentityRotation(), Scale := vector3{Forward := 1.0, Left := 1.0, Up := 1.0}}
            # Hits are sorted by distance. Distance ~0 is the camera device's own collision.
            for (Hit : Sim.FindSweepHits(Dir * RayLength, Start, collision_point{}), Hit.SourceHitDistance > 1.0, not HitEntity?):
                set HitEntity = option{Hit.TargetComponent.Entity}
                set HitPoint = Hit.ContactPosition
        Click := rts_click:
            Player := View.Player
            ScreenPosition := View.PressStart
            GroundPoint := Ground
            HitEntity := HitEntity
            HitPoint := HitPoint
        if (E := HitEntity?):
            Log("Click on object at {V3(E.GetGlobalTransform().Translation)}, contact {V3(HitPoint)}")
        else:
            Log("Click on ground {V3(Ground)}")
        ClickEvent.Signal(Click)

    # ---------- Keys (each press arrives twice, ~0.1 s apart) ----------

    KeyReady(View:rts_camera_view, Name:string):logic =
        Now := GetSimulationElapsedTime()
        Last := View.LastKeyTime[Name] or -10.0
        if (Now - Last < 0.25):
            false
        else:
            if (set View.LastKeyTime[Name] = Now) {}
            true

    OnRotateLeft(Payload:tuple(player, logic)):void =
        if (View := Views[Payload(0)]):
            Ready := KeyReady(View, "Q")
            if (Ready?):
                set View.TargetYaw -= RotateStep
                Log("Rotate to {View.TargetYaw}")

    OnRotateRight(Payload:tuple(player, logic)):void =
        if (View := Views[Payload(0)]):
            Ready := KeyReady(View, "E")
            if (Ready?):
                set View.TargetYaw += RotateStep
                Log("Rotate to {View.TargetYaw}")

    OnZoomIn(Payload:tuple(player, logic)):void =
        if (View := Views[Payload(0)]):
            Ready := KeyReady(View, "Z")
            if (Ready?):
                if (ZoomLevels.Length > 0):
                    StepLevel(View, -1)
                else:
                    set View.TargetDist = Clamp(View.TargetDist / ZoomStep, MinDistance, MaxDistance)
                Log("Zoom to {View.TargetDist}")

    OnZoomOut(Payload:tuple(player, logic)):void =
        if (View := Views[Payload(0)]):
            Ready := KeyReady(View, "C")
            if (Ready?):
                if (ZoomLevels.Length > 0):
                    StepLevel(View, 1)
                else:
                    set View.TargetDist = Clamp(View.TargetDist * ZoomStep, MinDistance, MaxDistance)
                Log("Zoom to {View.TargetDist}")

    # ---------- FollowCamera ----------

    # Moves the zoom level by Delta steps (clamped) and gives the player that level's camera.
    StepLevel(View:rts_camera_view, Delta:int):void =
        set View.Level = Clamp(View.Level + Delta, 0, ZoomLevels.Length - 1)
        if (L := ZoomLevels[View.Level]):
            set View.TargetDist = L.Dist
        ShowLevel(View)

    # Gives the player the camera of its current level: the new camera goes on top of the camera stack first (the
    # client blends to it with the device's Transition In Time), then the old one is taken off underneath.
    ShowLevel(View:rts_camera_view):void =
        if (View.ShownLevel = View.Level):
            return
        if (New := ZoomLevels[View.Level]):
            New.Camera.AddTo(View.Player)
            set ZoomSwaps += 1
            Log("Zoom level {View.Level} ({New.Dist} cm)")
            if (Old := ZoomLevels[View.ShownLevel]):
                Old.Camera.RemoveFrom(View.Player)
            set View.ShownLevel = View.Level

    # Puts the player's hidden character on the focus point; the zoom cameras follow it.
    MoveCharacter(View:rts_camera_view):void =
        if (Char := View.Player.GetFortCharacter[]):
            set CharacterMoves += 1
            if (RTSTeleportCharacter[Char, View.Focus.Forward, View.Focus.Left, GroundZ + CharacterHeight]) {}
            else:
                set TeleportFails += 1
                Log("Character teleport failed at {V3(View.Focus)}")
        else:
            set TeleportFails += 1

    # ---------- Camera ----------

    # Placed camera rotation turned around the world up axis by the current yaw.
    CameraRotation(View:rts_camera_view)<transacts>:rotation =
        View.BaseRot * MakeRotationDegrees(vector3{Forward := 0.0, Left := 0.0, Up := 1.0}, View.CurYaw)

    # P's current camera rotation (identity when P has no camera), for world labels that face the camera.
    GetViewRotation<public>(P:player)<transacts>:rotation =
        if (View := Views[P]) then CameraRotation(View) else IdentityRotation()

    # P's current camera turn around the world up axis (Q/E), in degrees; 0 = the placed camera's direction.
    GetViewYaw<public>(P:player)<transacts>:float =
        if (View := Views[P]) then View.CurYaw else 0.0

    # P's current camera distance from its ground focus (zoom), in cm.
    GetViewDistance<public>(P:player)<transacts>:float =
        if (View := Views[P]) then View.CurDist else StartDistance

    CameraPosition(View:rts_camera_view)<transacts>:vector3 =
        View.Focus - CameraRotation(View).GetForwardAxis() * View.CurDist

    CameraTransform(View:rts_camera_view)<transacts>:transform =
        transform{Translation := CameraPosition(View), Rotation := CameraRotation(View), Scale := vector3{Forward := 1.0, Left := 1.0, Up := 1.0}}

    MoveCameraNow(View:rts_camera_view):void =
        if (View.Camera.TeleportTo[CameraTransform(View)]) {}

    # Ground offset of a ray from a camera Height above the ground. The camera only translates while
    # dragging, so keeping the grabbed ground point under the cursor is a difference of two offsets.
    GroundOffset(Dir:vector3, Height:float)<transacts>:vector3 =
        if (Dir.Up < -0.01):
            Dir * (Height / -Dir.Up)
        else:
            Zero()

    ClampFocus(V:vector3)<transacts>:vector3 =
        vector3:
            Forward := Clamp(V.Forward, MinForward, MaxForward)
            Left := Clamp(V.Left, MinLeft, MaxLeft)
            Up := GroundZ

    # One loop for every player's camera.
    CamerasLoop()<suspends>:void =
        var Steps:int = 0
        loop:
            Sleep(StepTime)
            set Steps += 1
            for (P -> View : Views):
                StepView(View, Steps)

    # One camera step: drag / glide, zoom and yaw easing, then the character (FollowCamera) or the camera moves.
    StepView(View:rts_camera_view, Steps:int):void =
        A := 1.0 - Exp(-Smoothing * StepTime)
        OldFocus := View.Focus
        if (View.Dragging?):
            Grab := View.DragFocusStart + GroundOffset(View.PressRayDir, View.DragHeight) - GroundOffset(View.DragNowDir, View.DragHeight)
            set View.Focus = ClampFocus(Grab)
            set View.DragVel = View.DragVel * 0.5 + (View.Focus - OldFocus) * (0.5 / StepTime)
        else if (Distance(View.Coast, Zero()) > 20.0):
            set View.Focus = ClampFocus(View.Focus + View.Coast * StepTime)
            set View.Coast = View.Coast * SwipeDecay
        set View.CurYaw = Lerp(View.CurYaw, View.TargetYaw, A)
        set View.CurDist = Lerp(View.CurDist, View.TargetDist, A)
        NewPos := CameraPosition(View)
        if (ZoomLevels.Length > 0):
            # The camera smoothing runs on the client: only the character moves, and only when the focus does.
            if (Distance(View.Focus, OldFocus) > 0.5):
                MoveCharacter(View)
            # Once a second per player (spread over the players): a character that was not there yet (spawned late)
            # or got pushed off is put back.
            else if (Mod[Steps + View.PoolIndex, 20] = 0, Char := View.Player.GetFortCharacter[], RTSCharacterDistance2D(Char, View.Focus.Forward, View.Focus.Left) > 30.0):
                set DriftFixes += 1
                Char.SetVulnerability(false)
                if (HidePlayerCharacter?):
                    Char.Hide()
                MoveCharacter(View)
        else if (Distance(NewPos, View.LastPos) > 0.5 or Abs(View.CurYaw - View.LastYaw) > 0.01):
            set View.LastPos = NewPos
            set View.LastYaw = View.CurYaw
            spawn{ MoveCamera(View, CameraTransform(View)) }

    # Each step starts a new 0.1 s move before the last one ends, so the camera never stops in between.
    MoveCamera(View:rts_camera_view, Target:transform)<suspends>:void =
        View.Camera.MoveTo(Target, 0.1)
