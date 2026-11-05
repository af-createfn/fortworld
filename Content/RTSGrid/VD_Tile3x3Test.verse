# 3x3 material test.
# One cube prop shows 3 x 3 map cells: M_Tile3x3 has scalar parameters C00..C22 (owner index per cell, row = local X,
# column = local Y), looked up in T_TilePalette (0 = sea, 1 = neutral land, 2..17 = nations 1..16).
# Question: does a parameter change reach the client without a new SetMaterial? The test alternates every PhaseTime:
#   phase A = only `set Mat.Cxy = ...` on the material already on the prop,
#   phase B = the same, then Prop.SetMaterial(Mat) again.
# Watch the test blocks north of the map: if they only change in phase B, every change needs a SetMaterial.

using { /Fortnite.com/Devices }
using { /Verse.org/Simulation }
using { /Verse.org/Simulation/Tags }
using { /Verse.org/Random }

# Verse tag on the 3x3 test props.
rts_tile3x3_test := class(tag){}

rts_tile3x3 := class:
    Prop:creative_prop
    Mat:Materials.M_Tile3x3

VD_Tile3x3Test := class(creative_device):

    @editable
    Active:logic = true

    # Seconds per phase (A, then B, then A ...).
    @editable
    PhaseTime:float = 10.0

    # Seconds between changes; each change gives one random cell of every block a new owner.
    @editable
    StepTime:float = 0.5

    Log(Text:string):void =
        Print("[Tile3x3] {Text}")

    OnBegin<override>()<suspends>:void =
        if (not Active?):
            return
        Blocks := for (Obj : Self.FindCreativeObjectsWithTag(rts_tile3x3_test), Prop := creative_prop[Obj]):
            Mat := Materials.M_Tile3x3{}
            Prop.SetMaterial(Mat)
            rts_tile3x3{Prop := Prop, Mat := Mat}
        Log("{Blocks.Length} test blocks")
        # Start pattern: each block shows owners 1..9 (neutral + nations 1..8) so the cell order is visible.
        for (B : Blocks, K := 0..8):
            SetCell(B.Mat, K, (K + 1) * 1.0)
        for (B : Blocks):
            B.Prop.SetMaterial(B.Mat)
        Sleep(3.0)
        var Phase:int = 0
        loop:
            Resend := if (Phase = 1) then true else false
            Log(if (Resend?) then "Phase B: parameter change + SetMaterial" else "Phase A: parameter change only")
            Start := GetSimulationElapsedTime()
            loop:
                if (GetSimulationElapsedTime() - Start >= PhaseTime):
                    break
                for (B : Blocks):
                    SetCell(B.Mat, GetRandomInt(0, 8), GetRandomInt(0, 17) * 1.0)
                    if (Resend?):
                        B.Prop.SetMaterial(B.Mat)
                Sleep(StepTime)
            set Phase = 1 - Phase

    # Cell K = row * 3 + column.
    SetCell(M:Materials.M_Tile3x3, K:int, V:float):void =
        case (K):
            0 => set M.C00 = V
            1 => set M.C01 = V
            2 => set M.C02 = V
            3 => set M.C10 = V
            4 => set M.C11 = V
            5 => set M.C12 = V
            6 => set M.C20 = V
            7 => set M.C21 = V
            _ => set M.C22 = V
