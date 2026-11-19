@testable import SimHostKit
import Testing

/// Lines as SpringBoard logged them on an iPhone Duo simulator with iOS 27.2.
struct SpringBoardTests {
    @Test func switchNamesThePanelBeforeTheArrow() {
        let line = "2026-11-19 20:53:03.060 Df SpringBoard[96741:4dc2e60] [com.apple.SpringBoard:DisplayContentMode] STARTING:      .inner:off→pri .cover:pri→aux | style .continuousSnapshot | 6.0° (0.03 fold:0.01): closed+toOpen"
        #expect(SpringBoard.litPanel(in: line[...]) == .duoCover)
    }

    @Test func appliedModeNamesTheNewPanel() {
        let line = "2026-11-19 20:53:03.096 Df SpringBoard[96741:4dc2e60] [com.apple.SpringBoard:DisplayContentMode] pre-client modeChanged transitioning  .inner:pri .cover:aux (interactive) ← mode applied"
        #expect(SpringBoard.litPanel(in: line[...]) == .duoInner)
    }

    @Test func completedSwitch() {
        let line = "2026-11-19 20:53:00.903 Df SpringBoard[96741:4dc2e60] [com.apple.SpringBoard:DisplayContentMode] COMPLETED:     .inner:off .cover:pri | 0.0° (0.00 fold:0.00): fullyClosed [device:Pu]"
        #expect(SpringBoard.litPanel(in: line[...]) == .duoCover)
    }

    @Test func otherLinesTellNothing() {
        let line = "2026-11-19 20:54:03.485 Db SpringBoard[96741:4dc2e60] [com.apple.SpringBoard:InteractionSuppression] SBHingeMotionUnintendedInteractionMonitor: Handling angle update <SBFCMAngle: 123.8° vel=0.0°/s>"
        #expect(SpringBoard.litPanel(in: line[...]) == nil)
    }

    @Test func streamHeaderTellsNothing() {
        let line = #"Filtering the log data using "process == "SpringBoard" AND category == "DisplayContentMode" AND (composedMessage CONTAINS ".cover:pri" OR composedMessage CONTAINS ".inner:pri")""#
        #expect(SpringBoard.litPanel(in: line[...]) == nil)
    }
}
