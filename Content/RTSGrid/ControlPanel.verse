# Control panel of a human player. OpenFront's ControlPanel (src/client/hud/layers/ControlPanel.ts) at the bottom
# left: troops at home / maximum troops over a bar (blue = at home, light blue = in attacks and boats), the troop
# growth per second (green while it rises, orange while it falls), gold with its income per second, and the attack
# ratio slider (1..100 %, OpenFront default 20 %) that sets the troops an Attack or Boat press sends. A row of
# building slots sits at the bottom center (placeholders, disabled until buildings exist). VD_GameSim fills it every
# PanelInterval s (SetText only when a text changed). Kept apart from VD_GameSim.verse (UI types next to
# /Verse.org/SpatialMath clash).

using { /Fortnite.com/UI }
using { /UnrealEngine.com/Temporary/UI }
using { /UnrealEngine.com/Temporary/SpatialMath }
using { /Verse.org/Colors }
using { /Verse.org/Simulation }

PanelText<localizes>(S:string):message = "{S}"

# Width and height of the troop bar (canvas units).
PanelBarWidth:float = 300.0
PanelBarHeight:float = 14.0

# OpenFront build menu order; slots only (no buildings yet).
PanelBuildings:[]string = array{"City", "Port", "Defense Post", "Factory", "SAM Launcher", "Missile Silo", "Warship"}

rts_control_panel := class:
    Root:canvas
    TroopsText:text_block
    RateText:text_block
    AttackingText:text_block
    GoldText:text_block
    RatioText:text_block
    RatioSlider:slider_regular
    HomeBar:color_block
    AttackBar:color_block
    # Attack ratio from the slider (0.01..1), and when it last moved (VD_GameSim ignores map clicks right after).
    RatioEvent:event(float) = event(float){}
    var Shown:logic = false
    var LastTroops:string = ""
    var LastRate:string = ""
    var LastRising:logic = true
    var LastAttacking:string = ""
    var LastGold:string = ""
    var LastRatio:string = ""
    var LastHome:float = -1.0
    var LastAway:float = -1.0

    Show(P:player):void =
        if (not Shown?, PlayerUI := GetPlayerUI[P]):
            PlayerUI.AddWidget(Root, player_ui_slot{InputMode := ui_input_mode.All})
            set Shown = true

    Hide(P:player):void =
        if (Shown?, PlayerUI := GetPlayerUI[P]):
            PlayerUI.RemoveWidget(Root)
        set Shown = false

    # New values: texts are written only when they changed; Home and Away are the bar's shares (0..1) of the maximum.
    Update(Troops:string, Rate:string, Rising:logic, Attacking:string, Gold:string, Ratio:string, Home:float, Away:float):void =
        if (Troops <> LastTroops):
            set LastTroops = Troops
            TroopsText.SetText(PanelText(Troops))
        if (Rate <> LastRate):
            set LastRate = Rate
            RateText.SetText(PanelText(Rate))
        if (Rising <> LastRising):
            set LastRising = Rising
            RateText.SetTextColor(if (Rising?) then NamedColors.LightGreen else NamedColors.Orange)
        if (Attacking <> LastAttacking):
            set LastAttacking = Attacking
            AttackingText.SetText(PanelText(Attacking))
        if (Gold <> LastGold):
            set LastGold = Gold
            GoldText.SetText(PanelText(Gold))
        if (Ratio <> LastRatio):
            set LastRatio = Ratio
            RatioText.SetText(PanelText(Ratio))
        H := Clamp(Home, 0.0, 1.0)
        A := Clamp(Away, 0.0, 1.0 - H)
        # Bar sizes change in whole pixels only.
        if (Abs(H - LastHome) * PanelBarWidth >= 1.0 or Abs(A - LastAway) * PanelBarWidth >= 1.0):
            set LastHome = H
            set LastAway = A
            HomeBar.SetDesiredSize(vector2{X := H * PanelBarWidth, Y := PanelBarHeight})
            AttackBar.SetDesiredSize(vector2{X := A * PanelBarWidth, Y := PanelBarHeight})

    OnRatio(Msg:widget_message):void =
        RatioEvent.Signal(RatioSlider.GetValue() / 100.0)

PanelMargin(L:float, T:float, R:float, B:float):margin =
    margin{Left := L, Top := T, Right := R, Bottom := B}

PanelLabel(Color:color):text_block =
    text_block:
        DefaultText := PanelText("")
        DefaultTextColor := Color

# A dark box behind Content.
PanelBox(Content:widget):overlay =
    overlay:
        Slots := array:
            overlay_slot:
                Widget := color_block{DefaultColor := NamedColors.Black, DefaultOpacity := 0.6}
                HorizontalAlignment := horizontal_alignment.Fill
                VerticalAlignment := vertical_alignment.Fill
            overlay_slot:
                Widget := Content
                Padding := PanelMargin(16.0, 10.0, 16.0, 10.0)

# A hidden panel with the slider wired to RatioEvent; Ratio = the start ratio (0.01..1).
MakeControlPanel(Ratio:float):rts_control_panel =
    Troops := PanelLabel(NamedColors.White)
    Rate := PanelLabel(NamedColors.LightGreen)
    Attacking := PanelLabel(NamedColors.LightBlue)
    Gold := PanelLabel(NamedColors.Gold)
    RatioLabel := PanelLabel(NamedColors.White)
    Slider := slider_regular:
        DefaultValue := Clamp(Ratio * 100.0, 1.0, 100.0)
        DefaultMinValue := 1.0
        DefaultMaxValue := 100.0
        DefaultStepSize := 1.0
    Home := color_block:
        DefaultColor := NamedColors.DodgerBlue
        DefaultDesiredSize := vector2{X := 0.0, Y := PanelBarHeight}
    Away := color_block:
        DefaultColor := NamedColors.LightSkyBlue
        DefaultDesiredSize := vector2{X := 0.0, Y := PanelBarHeight}
    Bar := overlay:
        Slots := array:
            overlay_slot:
                Widget := color_block:
                    DefaultColor := NamedColors.DimGray
                    DefaultOpacity := 0.8
                    DefaultDesiredSize := vector2{X := PanelBarWidth, Y := PanelBarHeight}
                HorizontalAlignment := horizontal_alignment.Left
                VerticalAlignment := vertical_alignment.Center
            overlay_slot:
                Widget := stack_box:
                    Orientation := orientation.Horizontal
                    Slots := array:
                        stack_box_slot{Widget := Home, VerticalAlignment := vertical_alignment.Center}
                        stack_box_slot{Widget := Away, VerticalAlignment := vertical_alignment.Center}
                HorizontalAlignment := horizontal_alignment.Left
                VerticalAlignment := vertical_alignment.Center
    TroopRow := stack_box:
        Orientation := orientation.Horizontal
        Slots := array:
            stack_box_slot{Widget := Troops, Padding := PanelMargin(0.0, 0.0, 12.0, 0.0)}
            stack_box_slot{Widget := Rate}
    Column := stack_box:
        Orientation := orientation.Vertical
        Slots := array:
            stack_box_slot{Widget := TroopRow, HorizontalAlignment := horizontal_alignment.Left, Padding := PanelMargin(0.0, 0.0, 0.0, 4.0)}
            stack_box_slot{Widget := Bar, HorizontalAlignment := horizontal_alignment.Left, Padding := PanelMargin(0.0, 0.0, 0.0, 4.0)}
            stack_box_slot{Widget := Attacking, HorizontalAlignment := horizontal_alignment.Left, Padding := PanelMargin(0.0, 0.0, 0.0, 8.0)}
            stack_box_slot{Widget := Gold, HorizontalAlignment := horizontal_alignment.Left, Padding := PanelMargin(0.0, 0.0, 0.0, 8.0)}
            stack_box_slot{Widget := RatioLabel, HorizontalAlignment := horizontal_alignment.Left, Padding := PanelMargin(0.0, 0.0, 0.0, 2.0)}
            stack_box_slot{Widget := Slider, HorizontalAlignment := horizontal_alignment.Fill}
    BuildRow := stack_box:
        Orientation := orientation.Horizontal
        Slots := for (Name : PanelBuildings):
            Slot := button_quiet{DefaultText := PanelText(Name)}
            Slot.SetEnabled(false)
            stack_box_slot{Widget := Slot, Padding := PanelMargin(4.0, 0.0, 4.0, 0.0)}
    Layer := canvas:
        Slots := array:
            canvas_slot:
                Anchors := anchors{Minimum := vector2{X := 0.0, Y := 1.0}, Maximum := vector2{X := 0.0, Y := 1.0}}
                Alignment := vector2{X := 0.0, Y := 1.0}
                Offsets := PanelMargin(40.0, -40.0, 0.0, 0.0)
                SizeToContent := true
                Widget := PanelBox(Column)
            canvas_slot:
                Anchors := anchors{Minimum := vector2{X := 0.5, Y := 1.0}, Maximum := vector2{X := 0.5, Y := 1.0}}
                Alignment := vector2{X := 0.5, Y := 1.0}
                Offsets := PanelMargin(0.0, -40.0, 0.0, 0.0)
                SizeToContent := true
                Widget := PanelBox(BuildRow)
    Panel := rts_control_panel:
        Root := Layer
        TroopsText := Troops
        RateText := Rate
        AttackingText := Attacking
        GoldText := Gold
        RatioText := RatioLabel
        RatioSlider := Slider
        HomeBar := Home
        AttackBar := Away
    Slider.OnValueChanged().Subscribe(Panel.OnRatio)
    Panel
