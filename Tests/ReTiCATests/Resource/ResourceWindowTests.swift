import Testing
@testable import ReTiCA

@Test func windowDefaultsMatchRNSSlowStart() {
    let w = ResourceWindow()
    #expect(w.window == 4)
    #expect(w.windowMin == 2)
    #expect(w.windowMax == 10)
    #expect(w.flexibility == 4)
}

@Test func grownIncrementsWindowUpToMax() {
    var w = ResourceWindow()
    let sizes = (0..<10).map { _ -> Int in w = w.grown(); return w.window }
    // 4 -> 5,6,7,8,9,10 then capped at 10
    #expect(sizes == [5, 6, 7, 8, 9, 10, 10, 10, 10, 10])
    #expect(w.windowMax == 10)
}

@Test func grownRaisesWindowMinOnceSpreadExceedsFlexibility() {
    // spread = window - windowMin; windowMin rises when spread > flexibility-1 (== 3).
    var w = ResourceWindow()          // window 4, windowMin 2  (spread 2)
    w = w.grown()                     // window 5, spread 3 -> no bump
    #expect(w.window == 5); #expect(w.windowMin == 2)
    w = w.grown()                     // window 6, spread 4 > 3 -> windowMin 3
    #expect(w.window == 6); #expect(w.windowMin == 3)
    w = w.grown()                     // window 7, spread 4 > 3 -> windowMin 4
    #expect(w.window == 7); #expect(w.windowMin == 4)
}

@Test func shrunkDecrementsWindowAndCeiling() {
    // Start wide so shrink has room: window 8, min 2, max 10 (spread window-min = 6).
    var w = ResourceWindow(window: 8, windowMin: 2, windowMax: 10, flexibility: 4)
    w = w.shrunk()
    // window 7; windowMax 10>2 -> 9; (windowMax-window)=9-7=2, not > 3, so no second drop.
    #expect(w.window == 7); #expect(w.windowMax == 9)
}

@Test func shrunkAppliesSecondCeilingDropOnWideSpread() {
    // window 4, min 2, max 10: shrink -> window 3; max 10->9; (9-3)=6 > 3 -> max 8.
    var w = ResourceWindow(window: 4, windowMin: 2, windowMax: 10, flexibility: 4)
    w = w.shrunk()
    #expect(w.window == 3); #expect(w.windowMax == 8)
}

@Test func shrunkStopsAtWindowMin() {
    var w = ResourceWindow(window: 2, windowMin: 2, windowMax: 10, flexibility: 4)
    w = w.shrunk()   // window == windowMin -> no change to window
    #expect(w.window == 2); #expect(w.windowMax == 10)
}
