import Foundation

// swiftc -parse-as-library NotchBuddy/Sources/App/IslandStateMachine.swift tests/IslandHoverTests.swift -o /tmp/hover && /tmp/hover
@main
@MainActor
enum IslandHoverTests {
    static func wait(_ s: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

    static func main() {
        let fsm = IslandStateMachine()
        fsm.hoverOpenDelay = 0.05
        fsm.hoverLeaveCollapseDelay = 0.05

        // Hover on hidden notch → compact, then opens without a click.
        fsm.mouseEntered()
        precondition(fsm.state == .petit)
        wait(0.15)
        precondition(fsm.state == .home, "hover must open the island")

        // Leaving folds it back to compact quickly.
        fsm.mouseLeft(quick: true)
        wait(0.15)
        precondition(fsm.state == .petit, "leave must fold the island")

        // Passing over and out before the delay does not open it.
        fsm.mouseEntered()
        fsm.mouseLeft()
        wait(0.15)
        precondition(fsm.state == .petit, "a quick pass must not open")

        // Non-quick leave (pinned / chat) keeps the long delay.
        fsm.click()
        fsm.mouseLeft()
        wait(0.15)
        precondition(fsm.state == .home, "pinned/chat must stay open")

        // Held open (pending approval) never folds.
        fsm.isHeldOpen = { true }
        fsm.mouseLeft(quick: true)
        wait(0.15)
        precondition(fsm.state == .home, "held open must stay open")

        print("IslandHover: all cases passed")
    }
}
