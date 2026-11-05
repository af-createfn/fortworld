# Action menu of a human player.
# A click on the map opens it for the clicked cell (VD_GameSim.OpenMenu): the cell's owner and terrain on top, then
# Attack (OpenFront's center button: the clicked owner along the whole border, with the attack share of the troops),
# Boat (a transport ship to the clicked land) and Close. A button press signals ActionEvent; VD_GameSim acts on it.
# The menu sits at the right edge of the screen: the click's viewport position is in centimeters, not in canvas units,
# so it cannot follow the cursor yet. Kept apart from VD_GameSim.verse (UI types next to /Verse.org/SpatialMath clash).

using { /Fortnite.com/UI }
using { /UnrealEngine.com/Temporary/UI }
using { /UnrealEngine.com/Temporary/SpatialMath }
using { /Verse.org/Colors }
using { /Verse.org/Simulation }

ActionMenuText<localizes>(S:string):message = "{S}"

rts_menu_action := enum:
    Attack
    Boat
    Close

rts_action_menu := class:
    Root:canvas
    Title:text_block
    Info:text_block
    AttackButton:button_loud
    BoatButton:button_regular
    CloseButton:button_quiet
    ActionEvent:event(rts_menu_action) = event(rts_menu_action){}
    var Open:logic = false

    # Fills the menu and shows it on P's screen (input mode All, so the buttons take clicks).
    Show(P:player, TitleText:string, InfoText:string, AttackText:string, CanAttack:logic, BoatText:string, CanBoat:logic):void =
        Title.SetText(ActionMenuText(TitleText))
        Info.SetText(ActionMenuText(InfoText))
        AttackButton.SetText(ActionMenuText(AttackText))
        AttackButton.SetEnabled(CanAttack)
        BoatButton.SetText(ActionMenuText(BoatText))
        BoatButton.SetEnabled(CanBoat)
        if (not Open?, PlayerUI := GetPlayerUI[P]):
            PlayerUI.AddWidget(Root, player_ui_slot{InputMode := ui_input_mode.All})
            set Open = true

    Hide(P:player):void =
        if (Open?, PlayerUI := GetPlayerUI[P]):
            PlayerUI.RemoveWidget(Root)
        set Open = false

    OnAttack(Msg:widget_message):void =
        ActionEvent.Signal(rts_menu_action.Attack)

    OnBoat(Msg:widget_message):void =
        ActionEvent.Signal(rts_menu_action.Boat)

    OnClose(Msg:widget_message):void =
        ActionEvent.Signal(rts_menu_action.Close)

MenuMargin(L:float, T:float, R:float, B:float):margin =
    margin{Left := L, Top := T, Right := R, Bottom := B}

# A hidden menu with its buttons wired to ActionEvent.
MakeActionMenu():rts_action_menu =
    TitleBlock := text_block:
        DefaultText := ActionMenuText("")
        DefaultTextColor := NamedColors.White
        DefaultJustification := text_justification.Center
    InfoBlock := text_block:
        DefaultText := ActionMenuText("")
        DefaultTextColor := NamedColors.LightGray
        DefaultJustification := text_justification.Center
    Attack := button_loud{DefaultText := ActionMenuText("Attack")}
    Boat := button_regular{DefaultText := ActionMenuText("Boat")}
    Close := button_quiet{DefaultText := ActionMenuText("Close")}
    Column := stack_box:
        Orientation := orientation.Vertical
        Slots := array:
            stack_box_slot{Widget := TitleBlock, HorizontalAlignment := horizontal_alignment.Center, Padding := MenuMargin(0.0, 0.0, 0.0, 4.0)}
            stack_box_slot{Widget := InfoBlock, HorizontalAlignment := horizontal_alignment.Center, Padding := MenuMargin(0.0, 0.0, 0.0, 12.0)}
            stack_box_slot{Widget := Attack, HorizontalAlignment := horizontal_alignment.Fill, Padding := MenuMargin(0.0, 0.0, 0.0, 6.0)}
            stack_box_slot{Widget := Boat, HorizontalAlignment := horizontal_alignment.Fill, Padding := MenuMargin(0.0, 0.0, 0.0, 6.0)}
            stack_box_slot{Widget := Close, HorizontalAlignment := horizontal_alignment.Fill}
    Panel := overlay:
        Slots := array:
            overlay_slot:
                Widget := color_block{DefaultColor := NamedColors.Black, DefaultOpacity := 0.6}
                HorizontalAlignment := horizontal_alignment.Fill
                VerticalAlignment := vertical_alignment.Fill
            overlay_slot:
                Widget := Column
                Padding := MenuMargin(24.0, 16.0, 24.0, 16.0)
    Layer := canvas:
        Slots := array:
            canvas_slot:
                Anchors := anchors{Minimum := vector2{X := 1.0, Y := 0.5}, Maximum := vector2{X := 1.0, Y := 0.5}}
                Alignment := vector2{X := 1.0, Y := 0.5}
                Offsets := MenuMargin(-60.0, 0.0, 0.0, 0.0)
                SizeToContent := true
                Widget := Panel
    Menu := rts_action_menu:
        Root := Layer
        Title := TitleBlock
        Info := InfoBlock
        AttackButton := Attack
        BoatButton := Boat
        CloseButton := Close
    Attack.OnClick().Subscribe(Menu.OnAttack)
    Boat.OnClick().Subscribe(Menu.OnBoat)
    Close.OnClick().Subscribe(Menu.OnClose)
    Menu
