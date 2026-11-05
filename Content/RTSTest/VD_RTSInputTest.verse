# RTS input test device.
# Answers three questions in a playtest, all results go to the log as [RTSTest] lines:
#   1. Does /Verse.org/Input/UI PointerSelect fire on a mouse click while a UI is shown, and in which units?
#   2. Do Input Trigger devices (WASD pan) still work while a UI with InputMode All is shown?
#   3. Does a FindSweepHits ray (collision_point) hit normal placed props?
# The first player that joins gets the Fixed Point camera, the mouse UI and the WASD camera pan.

using { /Fortnite.com/Devices }
using { /Fortnite.com/UI }
using { /Verse.org/Simulation }
using { /Verse.org/SpatialMath }
using { /Verse.org/SceneGraph }
using { /UnrealEngine.com/Temporary/UI }
using { /Verse.org/Input }
using { /Verse.org/Input/UI }
using { /Verse.org/Colors }
using { /Fortnite.com/Characters }
using { /Fortnite.com/Input/Character }

rts_input_test_ui_mode := enum:
    Overlay
    BigButton
    NoInput
    NoTouch
    NoInputTouch

# Logs Input Trigger device events and Verse input actions under a fixed name.
rts_input_logger := class:
    Name:string

    OnPressed(Agent:agent):void =
        Print("[RTSTest] trigger {Name} PressedEvent", ?Duration := 6.0)

    OnReleased(Payload:tuple(agent, float)):void =
        Print("[RTSTest] trigger {Name} ReleasedEvent after {Payload(1)} s", ?Duration := 6.0)

    OnAction(Payload:tuple(player, logic)):void =
        Print("[RTSTest] Verse input action {Name} fired", ?Duration := 6.0)

RTSTestText<localizes>(S:string):message = "{S}"

VD_RTSInputTest := class(creative_device):

    # Off = the device does nothing (replaced by RTSCore/VD_RTSCamera, kept for further input tests).
    @editable
    Enabled:logic = true

    @editable
    Camera:gameplay_camera_fixed_point_device = gameplay_camera_fixed_point_device{}

    @editable
    PanForward:input_trigger_device = input_trigger_device{}

    @editable
    PanBack:input_trigger_device = input_trigger_device{}

    @editable
    PanLeft:input_trigger_device = input_trigger_device{}

    @editable
    PanRight:input_trigger_device = input_trigger_device{}

    @editable
    PropA:creative_prop = creative_prop{}

    @editable
    PropB:creative_prop = creative_prop{}

    @editable
    PropC:creative_prop = creative_prop{}

    @editable
    PropD:creative_prop = creative_prop{}

    # Camera pan speed with WASD, cm per second.
    @editable
    PanSpeed:float = 2500.0

    # Length of the click ray, cm.
    @editable
    RayLength:float = 100000.0

    # Drag with the held mouse button moves the camera (grab the world).
    @editable
    DragPan:logic = true

    # 1.0 = the ground point under the cursor stays under the cursor while dragging.
    @editable
    DragPanFactor:float = 1.0

    # Swipe: after a fast drag release the camera keeps gliding. Speed kept per 0.05 s step (0..1).
    @editable
    SwipeDecay:float = 0.9

    # Swipe release speeds below this (cm/s) do not glide.
    @editable
    SwipeMinSpeed:float = 300.0

    var Operator:?player = false
    var Mode:rts_input_test_ui_mode = rts_input_test_ui_mode.Overlay
    var CurrentUI:?canvas = false
    var CamPos:vector3 = vector3{Forward := 0.0, Left := 0.0, Up := 0.0}
    var CamRot:rotation = IdentityRotation()
    var DragHeld:logic = false
    var DragStart:vector3 = vector3{Forward := 0.0, Left := 0.0, Up := 0.0}
    var DragLast:vector3 = vector3{Forward := 0.0, Left := 0.0, Up := 0.0}
    var DragCamStart:vector3 = vector3{Forward := 0.0, Left := 0.0, Up := 0.0}
    var DragEvents:int = 0
    var PressHandled:logic = false
    var ClickCount:int = 0
    var LastKeys:string = ""
    var ModeGen:int = 0
    var DragStartDir:vector3 = vector3{Forward := 0.0, Left := 0.0, Up := -1.0}
    var DragNowDir:vector3 = vector3{Forward := 0.0, Left := 0.0, Up := -1.0}

    OnBegin<override>()<suspends>:void =
        if (not Enabled?):
            return
        CamT := Camera.GetGlobalTransform()
        set CamPos = CamT.Translation
        set CamRot = CamT.Rotation
        Log("Start. Camera at {V3(CamPos)}")
        LogProp("A", PropA)
        LogProp("B", PropB)
        LogProp("C", PropC)
        LogProp("D", PropD)
        Players := GetPlayspace().GetPlayers()
        if (First := Players[0], P := player[First]):
            StartFor(P)
        else:
            Joined := GetPlayspace().PlayerAddedEvent().Await()
            StartFor(Joined)
        PanLoop()

    Log(S:string):void =
        Print("[RTSTest] {S}", ?Duration := 6.0)

    V3(V:vector3):string =
        "(F {V.Forward}, L {V.Left}, U {V.Up})"

    LogProp(Name:string, Prop:creative_prop):void =
        if (Prop.IsValid[]):
            Log("Prop {Name} at {V3(Prop.GetGlobalTransform().Translation)}")
        else:
            Log("Prop {Name} not set")

    StartFor(P:player):void =
        set Operator = option{P}
        Camera.AddTo(P)
        Log("Camera added to player")
        if (PI := GetPlayerInput[P]):
            PI.AddInputMapping(TouchMapping)
            Events := PI.GetInputEvents(PointerSelect)
            Events.TriggerActivationEvent.Subscribe(OnSelectTrigger)
            Events.BeginDetectEvent.Subscribe(OnSelectBegin)
            Events.DetectionOngoingEvent.Subscribe(OnSelectOngoing)
            Events.EndDetectEvent.Subscribe(OnSelectEnd)
            Events.CancelActivationEvent.Subscribe(OnSelectCancel)
            Log("PointerSelect subscribed, TouchMapping added")
            # Do keyboard keys reach Verse at all while the mouse UI is shown?
            PI.AddInputMapping(TraversalMapping)
            PI.GetInputEvents(Jump).TriggerActivationEvent.Subscribe(rts_input_logger{Name := "Jump (Space)"}.OnAction)
            PI.GetInputEvents(Crouch).TriggerActivationEvent.Subscribe(rts_input_logger{Name := "Crouch (Ctrl)"}.OnAction)
            PI.GetInputEvents(Sprint).TriggerActivationEvent.Subscribe(rts_input_logger{Name := "Sprint (Shift)"}.OnAction)
            # UI-mode menu keys: may still work while the mouse UI blocks gameplay keys.
            PI.AddInputMapping(MenuNavigationMapping)
            PI.GetInputEvents(NextTab).TriggerActivationEvent.Subscribe(rts_input_logger{Name := "NextTab (E)"}.OnAction)
            PI.GetInputEvents(PreviousTab).TriggerActivationEvent.Subscribe(rts_input_logger{Name := "PreviousTab (Q)"}.OnAction)
            PI.GetInputEvents(NextPage).TriggerActivationEvent.Subscribe(rts_input_logger{Name := "NextPage (C)"}.OnAction)
            PI.GetInputEvents(PreviousPage).TriggerActivationEvent.Subscribe(rts_input_logger{Name := "PreviousPage (Z)"}.OnAction)
            PI.GetInputEvents(Back).TriggerActivationEvent.Subscribe(rts_input_logger{Name := "Back (Esc)"}.OnAction)
        else:
            Log("GetPlayerInput FAILED")
        Triggers := array{PanForward, PanBack, PanLeft, PanRight}
        TriggerNames := array{"W Forward", "S Back", "A Left", "D Right"}
        for (Index -> T : Triggers, TName := TriggerNames[Index]):
            T.Register(P)
            T.Enable()
            Logger := rts_input_logger{Name := TName}
            T.PressedEvent.Subscribe(Logger.OnPressed)
            T.ReleasedEvent.Subscribe(Logger.OnReleased)
        Log("Input triggers registered + enabled for the player")
        ShowUI(P)

    ModeName():string =
        case (Mode):
            rts_input_test_ui_mode.Overlay => "Overlay (InputMode All, invisible color block)"
            rts_input_test_ui_mode.BigButton => "BigButton (InputMode All, full screen button)"
            rts_input_test_ui_mode.NoInput => "NoInput (InputMode None, NO TouchMapping, back to Overlay in 10 s)"
            rts_input_test_ui_mode.NoTouch => "NoTouch (InputMode All, NO TouchMapping)"
            rts_input_test_ui_mode.NoInputTouch => "NoInputTouch (InputMode None, WITH TouchMapping, back to Overlay in 10 s)"

    ShowUI(P:player):void =
        if (PlayerUI := GetPlayerUI[P]):
            if (Old := CurrentUI?):
                PlayerUI.RemoveWidget(Old)
            BtnOverlay := button_regular{DefaultText := RTSTestText("Mode: Overlay")}
            BtnOverlay.OnClick().Subscribe(OnModeOverlay)
            BtnBig := button_regular{DefaultText := RTSTestText("Mode: Big button")}
            BtnBig.OnClick().Subscribe(OnModeBig)
            BtnNone := button_regular{DefaultText := RTSTestText("Mode: No input, no touch (10 s)")}
            BtnNone.OnClick().Subscribe(OnModeNone)
            BtnNoTouch := button_regular{DefaultText := RTSTestText("Mode: UI, no touch mapping")}
            BtnNoTouch.OnClick().Subscribe(OnModeNoTouch)
            BtnNoInputTouch := button_regular{DefaultText := RTSTestText("Mode: No input, WITH touch (10 s)")}
            BtnNoInputTouch.OnClick().Subscribe(OnModeNoInputTouch)
            Status := text_block{DefaultText := RTSTestText("RTS INPUT TEST - {ModeName()}"), DefaultTextColor := NamedColors.Yellow}
            Panel := stack_box:
                Orientation := orientation.Vertical
                Slots := array:
                    stack_box_slot{Widget := Status, HorizontalAlignment := horizontal_alignment.Left}
                    stack_box_slot{Widget := BtnOverlay, HorizontalAlignment := horizontal_alignment.Left}
                    stack_box_slot{Widget := BtnBig, HorizontalAlignment := horizontal_alignment.Left}
                    stack_box_slot{Widget := BtnNoTouch, HorizontalAlignment := horizontal_alignment.Left}
                    stack_box_slot{Widget := BtnNone, HorizontalAlignment := horizontal_alignment.Left}
                    stack_box_slot{Widget := BtnNoInputTouch, HorizontalAlignment := horizontal_alignment.Left}
            Background:widget = if (Mode = rts_input_test_ui_mode.BigButton):
                Big := button_quiet{DefaultText := RTSTestText(" ")}
                Big.OnClick().Subscribe(OnBigClick)
                Big
            else:
                color_block{DefaultColor := NamedColors.Black, DefaultOpacity := 0.0}
            NewUI := canvas:
                Slots := array:
                    canvas_slot:
                        Anchors := RTSAnchors(0.0, 0.0, 1.0, 1.0)
                        Offsets := margin{Left := 0.0, Top := 0.0, Right := 0.0, Bottom := 0.0}
                        Widget := Background
                    canvas_slot:
                        Anchors := RTSAnchors(0.0, 0.0, 0.0, 0.0)
                        Offsets := margin{Left := 40.0, Top := 220.0, Right := 0.0, Bottom := 0.0}
                        SizeToContent := true
                        Widget := Panel
            InputMode := if (Mode = rts_input_test_ui_mode.NoInput or Mode = rts_input_test_ui_mode.NoInputTouch) then ui_input_mode.None else ui_input_mode.All
            PlayerUI.AddWidget(NewUI, player_ui_slot{InputMode := InputMode})
            set CurrentUI = option{NewUI}
            Log("UI shown, mode {ModeName()}")
        else:
            Log("GetPlayerUI FAILED")

    SetMode(P:player, NewMode:rts_input_test_ui_mode):void =
        set Mode = NewMode
        set ModeGen += 1
        WantTouch := if (NewMode = rts_input_test_ui_mode.NoInput or NewMode = rts_input_test_ui_mode.NoTouch) then false else true
        SetTouchMapping(P, WantTouch)
        ShowUI(P)
        if (NewMode = rts_input_test_ui_mode.NoInput or NewMode = rts_input_test_ui_mode.NoInputTouch):
            spawn{ BackToOverlay(P, ModeGen) }

    BackToOverlay(P:player, Gen:int)<suspends>:void =
        Sleep(10.0)
        if (Gen = ModeGen):
            SetMode(P, rts_input_test_ui_mode.Overlay)

    OnModeOverlay(Msg:widget_message):void =
        Log("Button Overlay OnClick")
        SetMode(Msg.Player, rts_input_test_ui_mode.Overlay)

    OnModeBig(Msg:widget_message):void =
        Log("Button BigButton OnClick")
        SetMode(Msg.Player, rts_input_test_ui_mode.BigButton)

    OnModeNone(Msg:widget_message):void =
        Log("Button NoInput OnClick")
        SetMode(Msg.Player, rts_input_test_ui_mode.NoInput)

    OnModeNoInputTouch(Msg:widget_message):void =
        Log("Button NoInputTouch OnClick")
        SetMode(Msg.Player, rts_input_test_ui_mode.NoInputTouch)

    OnModeNoTouch(Msg:widget_message):void =
        Log("Button NoTouch OnClick")
        SetMode(Msg.Player, rts_input_test_ui_mode.NoTouch)

    SetTouchMapping(P:player, On:logic):void =
        if (PI := GetPlayerInput[P]):
            if (On?):
                PI.AddInputMapping(TouchMapping)
                Log("TouchMapping ADDED")
            else:
                PI.RemoveInputMapping(TouchMapping)
                Log("TouchMapping REMOVED")

    OnBigClick(Msg:widget_message):void =
        Log("Full screen button OnClick fired")

    # ---------- PointerSelect ----------

    # Test 1 showed: TriggerActivationEvent repeats every frame while the button is held, with the
    # current cursor position, and DetectionOngoingEvent never fires. So the first trigger of a press
    # is the click, the following ones are the drag.
    OnSelectTrigger(Payload:tuple(player, vector3)):void =
        set DragEvents += 1
        set DragLast = Payload(1)
        set DragNowDir = Payload(0).DeprojectViewportToWorld(Payload(1)).Direction
        if (PressHandled?):
            return
        set PressHandled = true
        set ClickCount += 1
        P := Payload(0)
        Pos := Payload(1)
        Log("CLICK #{ClickCount} viewport={V3(Pos)} mode={ModeName()}")
        if (PropA.IsValid[], SP := P.ProjectWorldToViewport[PropA.GetGlobalTransform().Translation]):
            Log("  (Prop A is at viewport {V3(SP)})")
        Ray := P.DeprojectViewportToWorld(Pos)
        Log("  ray origin={V3(Ray.Origin)} dir={V3(Ray.Direction)}")
        CastRay(Ray.Origin, Ray.Direction)

    OnSelectBegin(Payload:tuple(player, vector3)):void =
        set DragHeld = true
        set DragStart = Payload(1)
        set DragLast = Payload(1)
        set DragCamStart = CamPos
        set DragEvents = 0
        set PressHandled = false
        set DragStartDir = Payload(0).DeprojectViewportToWorld(Payload(1)).Direction
        set DragNowDir = DragStartDir
        Log("press begin viewport={V3(Payload(1))}")

    OnSelectOngoing(Payload:tuple(player, vector3, float)):void =
        set DragEvents += 1
        set DragLast = Payload(1)

    OnSelectEnd(Payload:tuple(player, float)):void =
        set DragHeld = false
        Log("press end after {Payload(1)} s, trigger events={DragEvents}, last={V3(DragLast)}, moved={V3(DragLast - DragStart)}")

    OnSelectCancel(Payload:tuple(player, vector3, float)):void =
        Log("press canceled viewport={V3(Payload(1))} after {Payload(2)} s")

    # ---------- Ray cast ----------

    CastRay(Origin:vector3, Dir:vector3):void =
        if (Sim := Self.GetSimulationEntity[]):
            Start := transform{Translation := Origin, Rotation := IdentityRotation(), Scale := vector3{Forward := 1.0, Left := 1.0, Up := 1.0}}
            var N:int = 0
            # Hits at distance ~0 are the camera device itself (it has collision at the ray origin).
            for (Hit : Sim.FindSweepHits(Dir * RayLength, Start, collision_point{}), Hit.SourceHitDistance > 1.0):
                set N += 1
                E := Hit.TargetComponent.Entity
                EPos := E.GetGlobalTransform().Translation
                Log("  hit {N}: dist={Hit.SourceHitDistance} contact={V3(Hit.ContactPosition)} entity at={V3(EPos)} comp={CompKind(Hit.TargetComponent)} nearest prop={NearestProp(Hit.ContactPosition)}")
            if (N = 0):
                Log("  NO HITS (the grid floor has no query collision)")
            # Ground point by ray / plane Z = 0 intersection, works without floor collision.
            if (Dir.Up < 0.0):
                T := -Origin.Up / Dir.Up
                Log("  ground point (Z=0)={V3(Origin + Dir * T)}")
        else:
            Log("  no simulation entity")

    CompKind(C:component):string =
        if (mesh_component[C]):
            "mesh_component"
        else:
            "other component"

    NearestProp(At:vector3):string =
        var Best:string = "none"
        var BestDist:float = 1000000000.0
        Names := array{"A", "B", "C", "D"}
        Props := array{PropA, PropB, PropC, PropD}
        for (Index -> Prop : Props, Prop.IsValid[], Name := Names[Index]):
            D := Distance(At, Prop.GetGlobalTransform().Translation)
            if (D < BestDist):
                set BestDist = D
                set Best = Name
        "{Best} ({BestDist} cm from its pivot)"

    # ---------- Camera pan ----------

    GroundOffset(Dir:vector3, Height:float):vector3 =
        if (Dir.Up < -0.01):
            Dir * (Height / -Dir.Up)
        else:
            vector3{Forward := 0.0, Left := 0.0, Up := 0.0}

    PanLoop()<suspends>:void =
        var PrintTimer:float = 0.0
        var CharTimer:float = 0.0
        var LastCharPos:vector3 = vector3{Forward := 0.0, Left := 0.0, Up := 0.0}
        Zero := vector3{Forward := 0.0, Left := 0.0, Up := 0.0}
        var WasDragging:logic = false
        var DragVel:vector3 = Zero
        var Coast:vector3 = Zero
        var LastPrintedDrag:vector3 = vector3{Forward := 0.0, Left := 0.0, Up := 0.0}
        loop:
            Sleep(0.05)
            if (P := Operator?):
                var Fwd:float = 0.0
                var Side:float = 0.0
                var Keys:string = ""
                if (PanForward.IsHeld[P]):
                    set Fwd += 1.0
                    set Keys += "W"
                if (PanBack.IsHeld[P]):
                    set Fwd -= 1.0
                    set Keys += "S"
                if (PanLeft.IsHeld[P]):
                    set Side += 1.0
                    set Keys += "A"
                if (PanRight.IsHeld[P]):
                    set Side -= 1.0
                    set Keys += "D"
                if (Keys <> LastKeys):
                    set LastKeys = Keys
                    Log("keys held: [{Keys}] mode={ModeName()}")
                var Moved:logic = false
                if (Fwd <> 0.0 or Side <> 0.0):
                    set CamPos = CamPos + vector3{Forward := Fwd * PanSpeed * 0.05, Left := Side * PanSpeed * 0.05, Up := 0.0}
                    set Moved = true
                if (DragPan? and DragHeld?):
                    if (not WasDragging?):
                        set DragVel = Zero
                        set Coast = Zero
                    PrevPos := CamPos
                    # Grab the ground: the camera only translates, so the ground offset of a ray depends on
                    # its direction and the camera height only. Keep the grabbed ground point under the cursor.
                    H := DragCamStart.Up
                    Delta := GroundOffset(DragStartDir, H) - GroundOffset(DragNowDir, H)
                    set CamPos = vector3:
                        Forward := DragCamStart.Forward + Delta.Forward * DragPanFactor
                        Left := DragCamStart.Left + Delta.Left * DragPanFactor
                        Up := DragCamStart.Up
                    set Moved = true
                    # Smoothed drag speed, used for the swipe on release.
                    set DragVel = DragVel * 0.5 + (CamPos - PrevPos) * (0.5 / 0.05)
                    set WasDragging = true
                else if (WasDragging?):
                    set WasDragging = false
                    Speed := Distance(DragVel, Zero)
                    if (Speed >= SwipeMinSpeed):
                        set Coast = DragVel
                        Log("swipe released at {Speed} cm/s")
                else if (Distance(Coast, Zero) > 20.0):
                    set CamPos = CamPos + Coast * 0.05
                    set Coast = Coast * SwipeDecay
                    set Moved = true
                if (Moved?):
                    spawn{ MoveCamera() }
                # Does WASD walk the (unseen) character instead?
                set CharTimer += 0.05
                if (CharTimer >= 1.0):
                    set CharTimer = 0.0
                    if (Char := P.GetFortCharacter[]):
                        CharPos := Char.GetGlobalTransform().Translation
                        if (Distance(CharPos, LastCharPos) > 20.0):
                            set LastCharPos = CharPos
                            Log("character moved to {V3(CharPos)} mode={ModeName()}")
                set PrintTimer += 0.05
                if (DragHeld? and PrintTimer >= 0.25):
                    set PrintTimer = 0.0
                    if (DragLast <> LastPrintedDrag):
                        set LastPrintedDrag = DragLast
                        Log("  drag viewport={V3(DragLast)} ongoing events={DragEvents}")

    MoveCamera()<suspends>:void =
        Camera.MoveTo(transform{Translation := CamPos, Rotation := CamRot, Scale := vector3{Forward := 1.0, Left := 1.0, Up := 1.0}}, 0.1)
