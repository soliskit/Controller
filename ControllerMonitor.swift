import GameController
import Observation

// Coding standard
//
// This app follows NASA JPL's "Power of Ten" rules for safety critical code,
// adapted to Swift:
//
//  1. Simple control flow. No recursion.
//  2. One cyclic frame loop is the only loop without a fixed bound. Every
//     other loop walks a fixed size table.
//  3. Bounded memory. Fixed size tables and a capped log; nothing grows
//     without limit after launch.
//  4. Short functions that fit on one screen.
//  5. Runtime checks with an explicit recovery action. A failed check is
//     counted and logged as a fault, shown on screen, and never crashes.
//  6. Data at the smallest scope. Private by default, `let` where possible.
//  7. Every input from the controller is validated before use, and every
//     return value is used or explicitly discarded.
//  8. No force unwraps, force casts, or `try!`.
//  9. Named constants in `Tuning` instead of magic numbers.
// 10. Builds with zero warnings.

/// Every tuning constant in one place.
enum Tuning {
    /// Input is sampled on a fixed frame, like an avionics control loop.
    static let frameRate = 60
    static let framePeriod = Duration.seconds(1) / frameRate
    /// Slower jobs run every this many frames: connection at 4 Hz, battery every 5 s.
    static let connectionCheckFrames: UInt64 = 15
    static let batteryCheckFrames: UInt64 = 300
    /// Stick readings inside this band are sensor noise and read as zero.
    static let stickDeadZone: Float = 0.05
    /// A stick counts as pushed past the first value and released below the second.
    static let stickPressThreshold: Float = 0.5
    static let stickReleaseThreshold: Float = 0.3
    /// Readings this far past their valid range count as invalid.
    static let rangeTolerance: Float = 0.001
    /// Oldest log lines are dropped past this count.
    static let logCapacity = 500
    /// Only this many faults are logged; later ones are still counted.
    static let maxLoggedFaults = 20
    /// Seconds without input before the checklist suggests a restart.
    static let noInputHintDelay: TimeInterval = 10
}

/// Every button the app shows, in on screen order, with DualSense names.
enum PadButton: Int, CaseIterable, Identifiable {
    case cross, circle, square, triangle, l1, r1, l2, r2, l3, r3, create, options, ps, touchpad

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .cross: "Cross"
        case .circle: "Circle"
        case .square: "Square"
        case .triangle: "Triangle"
        case .l1: "L1"
        case .r1: "R1"
        case .l2: "L2"
        case .r2: "R2"
        case .l3: "L3"
        case .r3: "R3"
        case .create: "Create"
        case .options: "Options"
        case .ps: "PS"
        case .touchpad: "Touchpad"
        }
    }

    /// The matching physical input, or nil when the controller lacks it.
    func input(on pad: GCExtendedGamepad) -> GCControllerButtonInput? {
        switch self {
        case .cross: return pad.buttonA
        case .circle: return pad.buttonB
        case .square: return pad.buttonX
        case .triangle: return pad.buttonY
        case .l1: return pad.leftShoulder
        case .r1: return pad.rightShoulder
        case .l2: return pad.leftTrigger
        case .r2: return pad.rightTrigger
        case .l3: return pad.leftThumbstickButton
        case .r3: return pad.rightThumbstickButton
        case .create: return pad.buttonOptions
        case .options: return pad.buttonMenu
        case .ps: return pad.buttonHome
        case .touchpad: return (pad as? GCDualSenseGamepad)?.touchpadButton
        }
    }
}

/// Pressed buttons as a fixed size bit set, one bit per `PadButton`.
struct ButtonSet: Equatable {
    static let capacity = UInt16.bitWidth

    private var bits: UInt16 = 0

    func contains(_ button: PadButton) -> Bool {
        bits & (UInt16(1) << button.rawValue) != 0
    }

    mutating func insert(_ button: PadButton) {
        bits |= UInt16(1) << button.rawValue
    }
}

enum VerticalDirection {
    case up, center, down

    var title: String {
        switch self {
        case .up: "UP"
        case .center: "CENTER"
        case .down: "DOWN"
        }
    }
}

/// One frame's reading of the controller, validated and clamped.
struct ControllerSample: Equatable {
    /// Each component is -1...1. Positive y is up.
    var dpad = SIMD2<Float>.zero
    var leftStick = SIMD2<Float>.zero
    var rightStick = SIMD2<Float>.zero
    /// 0...1
    var leftTrigger: Float = 0
    var rightTrigger: Float = 0
    var pressed = ButtonSet()
    /// Raw readings that were not a number or out of range, and were corrected.
    var invalidReadings = 0

    static let neutral = ControllerSample()

    init() {}

    init(reading pad: GCExtendedGamepad) {
        var validator = ReadingValidator()
        dpad = validator.axes(pad.dpad, deadZone: 0)
        leftStick = validator.axes(pad.leftThumbstick, deadZone: Tuning.stickDeadZone)
        rightStick = validator.axes(pad.rightThumbstick, deadZone: Tuning.stickDeadZone)
        leftTrigger = validator.unit(pad.leftTrigger.value)
        rightTrigger = validator.unit(pad.rightTrigger.value)
        for button in PadButton.allCases where button.input(on: pad)?.isPressed == true {
            pressed.insert(button)
        }
        invalidReadings = validator.invalidCount
    }
}

/// Validates raw readings: not a number becomes 0, out of range is clamped,
/// and each correction is counted.
private struct ReadingValidator {
    private(set) var invalidCount = 0

    mutating func axes(_ pad: GCControllerDirectionPad, deadZone: Float) -> SIMD2<Float> {
        let x = axis(pad.xAxis.value, deadZone: deadZone)
        let y = axis(pad.yAxis.value, deadZone: deadZone)
        return SIMD2(x, y)
    }

    mutating func axis(_ raw: Float, deadZone: Float) -> Float {
        let value = clamp(raw, to: -1...1)
        return abs(value) < deadZone ? 0 : value
    }

    mutating func unit(_ raw: Float) -> Float {
        clamp(raw, to: 0...1)
    }

    private mutating func clamp(_ raw: Float, to range: ClosedRange<Float>) -> Float {
        guard raw.isFinite else {
            invalidCount += 1
            return 0
        }
        if raw < range.lowerBound - Tuning.rangeTolerance || raw > range.upperBound + Tuning.rangeTolerance {
            invalidCount += 1
        }
        return min(max(raw, range.lowerBound), range.upperBound)
    }
}

/// Tracks which side of the dead zone an analog axis is on, with hysteresis so
/// a stick resting near the threshold does not flood the log.
private struct AxisZone {
    private(set) var value = 0

    /// Returns the new zone (-1, 0 or 1) when it changes, otherwise nil.
    mutating func update(_ axis: Float) -> Int? {
        let next: Int
        if axis > Tuning.stickPressThreshold {
            next = 1
        } else if axis < -Tuning.stickPressThreshold {
            next = -1
        } else if abs(axis) < Tuning.stickReleaseThreshold {
            next = 0
        } else {
            return nil
        }
        guard next != value else { return nil }
        value = next
        return next
    }
}

/// What the app knows about the connected controller.
struct ConnectionInfo {
    let name: String
    let category: String
    let connectedAt: Date
    var batteryLevel: Float?
    var batteryState: GCDeviceBattery.State?
}

/// One line in the on screen event log.
struct LogEntry: Identifiable {
    let id: Int
    let date: Date
    let message: String
    let isFault: Bool
}

/// Samples the game controller on a fixed frame and publishes its state for SwiftUI.
@MainActor
@Observable
final class ControllerMonitor {
    private(set) var connection: ConnectionInfo?
    private(set) var sample = ControllerSample.neutral
    private(set) var verticalDirection = VerticalDirection.center
    /// Frames where the reading changed, as proof that input reaches the app.
    private(set) var inputChangeCount = 0
    private(set) var faultCount = 0
    private(set) var log: [LogEntry] = []
    /// One slot per `TestStep`, indexed by its raw value.
    private(set) var testResults = [TestResult?](repeating: nil, count: TestStep.allCases.count)

    @ObservationIgnored private var controller: GCController?
    @ObservationIgnored private var frame: UInt64 = 0
    @ObservationIgnored private var nextLogID = 0
    @ObservationIgnored private var sawDisconnect = false
    @ObservationIgnored private var leftStickVertical = AxisZone()
    @ObservationIgnored private var leftStickHorizontal = AxisZone()

    var isConnected: Bool { connection != nil }

    init() {
        addLog("App started. Waiting for a controller.")
        _ = check(PadButton.allCases.count <= ButtonSet.capacity, "Button table is larger than the button bit set")
        _ = check(TestStep.allCases.map(\.rawValue) == Array(testResults.indices), "Test steps are not numbered in order")

        // Swift Playgrounds runs the app in a hosted process that the system
        // does not treat as the frontmost app. Without this, GameController
        // withholds input from it.
        GCController.shouldMonitorBackgroundEvents = true
        addLog("Background event monitoring on.")

        checkConnection()
        startFrameLoop()
    }

    func clearLog() {
        log.removeAll()
    }

    // MARK: Frame loop

    /// The cyclic executive. It runs for the life of the app and is the only
    /// loop without a fixed bound. Each frame samples the controller; slower
    /// jobs run every Nth frame.
    private func startFrameLoop() {
        Task { [weak self] in
            let clock = ContinuousClock()
            var deadline = clock.now
            while !Task.isCancelled {
                deadline += Tuning.framePeriod
                // After a stall, such as the app being suspended, restart the
                // schedule instead of running a burst of late frames.
                if deadline < clock.now {
                    deadline = clock.now + Tuning.framePeriod
                }
                do {
                    try await Task.sleep(until: deadline, clock: clock)
                } catch {
                    return
                }
                guard let self else { return }
                self.runFrame()
            }
        }
    }

    private func runFrame() {
        frame &+= 1
        if frame % Tuning.connectionCheckFrames == 0 {
            checkConnection()
        }
        if frame % Tuning.batteryCheckFrames == 0 {
            refreshBattery(logIt: false)
        }
        guard let pad = controller?.extendedGamepad else { return }
        process(ControllerSample(reading: pad))
    }

    // MARK: Connection

    /// Compares the connected controllers with the one being shown.
    private func checkConnection() {
        let connected = GCController.controllers()
        if let current = controller, !connected.contains(where: { $0 === current }) {
            didDisconnect()
        }
        if controller == nil, let next = connected.first {
            didConnect(next)
        }
    }

    private func didConnect(_ newController: GCController) {
        let name = newController.vendorName ?? newController.productCategory
        controller = newController
        connection = ConnectionInfo(name: name, category: newController.productCategory, connectedAt: .now)
        addLog("Controller connected: \(name)")
        pass(.connect)
        if sawDisconnect {
            pass(.turnOn)
        }
        if let pad = newController.extendedGamepad {
            if pad is GCDualSenseGamepad {
                addLog("DualSense profile detected.")
            }
        } else {
            addLog("This controller has no extended gamepad profile, so input cannot be read.")
        }
        refreshBattery(logIt: true)
    }

    private func didDisconnect() {
        addLog("Controller disconnected: \(connection?.name ?? "unknown")")
        controller = nil
        connection = nil
        sample = .neutral
        verticalDirection = .center
        inputChangeCount = 0
        leftStickVertical = AxisZone()
        leftStickHorizontal = AxisZone()
        sawDisconnect = true
        pass(.turnOff)
    }

    private func refreshBattery(logIt: Bool) {
        guard var info = connection, let battery = controller?.battery else { return }
        let level = battery.batteryLevel
        let state = battery.batteryState
        guard check(level.isFinite && (0...1).contains(level), "Battery level \(level) is out of range") else { return }
        let stateChanged = info.batteryState != state
        guard logIt || stateChanged || info.batteryLevel != level else { return }
        info.batteryLevel = level
        info.batteryState = state
        connection = info
        if logIt || stateChanged {
            addLog("Battery \(Int(level * 100))%, \(state.title)")
        }
    }

    // MARK: Input

    private func process(_ next: ControllerSample) {
        guard next != sample else { return }
        if next.invalidReadings > 0 {
            recordFault("Invalid controller readings corrected: \(next.invalidReadings)")
        }
        let previous = sample
        sample = next
        inputChangeCount += 1
        pass(.anyInput)
        reportDpad(from: previous.dpad, to: next.dpad)
        reportLeftStick(next.leftStick)
        reportButtons(from: previous.pressed, to: next.pressed)
        updateVerticalDirection()
    }

    private func reportDpad(from old: SIMD2<Float>, to new: SIMD2<Float>) {
        if new.y > 0, old.y <= 0 {
            addLog("D pad UP")
            pass(.dpadUp)
        }
        if new.y < 0, old.y >= 0 {
            addLog("D pad DOWN")
            pass(.dpadDown)
        }
        if new.x < 0, old.x >= 0 {
            addLog("D pad LEFT")
        }
        if new.x > 0, old.x <= 0 {
            addLog("D pad RIGHT")
        }
    }

    private func reportLeftStick(_ stick: SIMD2<Float>) {
        switch leftStickVertical.update(stick.y) {
        case 1:
            addLog("Left stick UP")
            pass(.stickUp)
        case -1:
            addLog("Left stick DOWN")
            pass(.stickDown)
        default:
            break
        }
        switch leftStickHorizontal.update(stick.x) {
        case 1: addLog("Left stick RIGHT")
        case -1: addLog("Left stick LEFT")
        default: break
        }
    }

    private func reportButtons(from old: ButtonSet, to new: ButtonSet) {
        guard old != new else { return }
        for button in PadButton.allCases {
            let wasPressed = old.contains(button)
            let isPressed = new.contains(button)
            if isPressed, !wasPressed {
                addLog("\(button.title) pressed")
                if let step = TestStep(pressing: button) {
                    pass(step)
                }
            } else if wasPressed, !isPressed {
                addLog("\(button.title) released")
            }
        }
    }

    private func updateVerticalDirection() {
        let dpad = sample.dpad.y
        let stick = leftStickVertical.value
        let next: VerticalDirection
        if dpad > 0 || stick > 0 {
            next = .up
        } else if dpad < 0 || stick < 0 {
            next = .down
        } else {
            next = .center
        }
        if next != verticalDirection {
            verticalDirection = next
        }
    }

    // MARK: Test checklist

    /// The first step that has not passed or been skipped yet.
    var currentTestStep: TestStep? {
        TestStep.allCases.first { result(for: $0) == nil }
    }

    var skippedCount: Int {
        testResults.filter { $0 == .skipped }.count
    }

    func result(for step: TestStep) -> TestResult? {
        guard let slot = slot(for: step) else { return nil }
        return testResults[slot]
    }

    func skipCurrentTest() {
        guard let step = currentTestStep, let slot = slot(for: step) else { return }
        testResults[slot] = .skipped
        addLog("Check skipped: \(step.title)")
    }

    func restartTest() {
        testResults = [TestResult?](repeating: nil, count: TestStep.allCases.count)
        sawDisconnect = false
        addLog("Test restarted.")
        if isConnected {
            pass(.connect)
        }
    }

    /// Marks a step passed. A skipped step still upgrades to passed if the
    /// input turns up later.
    private func pass(_ step: TestStep) {
        guard let slot = slot(for: step), testResults[slot] != .passed else { return }
        testResults[slot] = .passed
        addLog("Check passed: \(step.title)")
    }

    /// The table index for a step, or nil (and a fault) if it is out of range.
    private func slot(for step: TestStep) -> Int? {
        guard check(testResults.indices.contains(step.rawValue), "Test step \(step.rawValue) has no result slot") else { return nil }
        return step.rawValue
    }

    // MARK: Faults and log

    /// A runtime check with a recovery path. When `condition` is false the
    /// failure is recorded as a fault and false is returned, so the caller can
    /// take its recovery action. It never stops the app.
    private func check(_ condition: Bool, _ fault: @autoclosure () -> String) -> Bool {
        if !condition {
            recordFault(fault())
        }
        return condition
    }

    private func recordFault(_ message: String) {
        faultCount += 1
        if faultCount <= Tuning.maxLoggedFaults {
            addLog("FAULT: \(message)", isFault: true)
        } else if faultCount == Tuning.maxLoggedFaults + 1 {
            addLog("FAULT: further faults are counted but not logged.", isFault: true)
        }
    }

    private func addLog(_ message: String, isFault: Bool = false) {
        log.append(LogEntry(id: nextLogID, date: .now, message: message, isFault: isFault))
        nextLogID &+= 1
        if log.count > Tuning.logCapacity {
            log.removeFirst(log.count - Tuning.logCapacity)
        }
    }
}

extension GCDeviceBattery.State {
    var title: String {
        switch self {
        case .charging: "charging"
        case .discharging: "on battery"
        case .full: "full"
        default: "unknown"
        }
    }
}
