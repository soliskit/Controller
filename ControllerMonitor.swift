import GameController
import Observation
import SwiftUI

/// One line in the on screen event log.
struct LogEntry: Identifiable {
    let id = UUID()
    let date: Date
    let message: String
}

/// Tracks which side of the dead zone an analog axis is on, with hysteresis so
/// a stick resting near the threshold does not flood the log.
private struct AxisZone {
    private(set) var value = 0

    /// Returns the new zone (-1, 0 or 1) when it changes, otherwise nil.
    mutating func update(_ axis: Float) -> Int? {
        let next: Int
        if axis > 0.5 {
            next = 1
        } else if axis < -0.5 {
            next = -1
        } else if abs(axis) < 0.3 {
            next = 0
        } else {
            return nil
        }
        guard next != value else { return nil }
        value = next
        return next
    }
}

/// GameController calls handlers on `handlerQueue`, which is set to the main
/// queue, so hop onto the main actor synchronously.
private func onMain(_ body: @MainActor () -> Void) {
    MainActor.assumeIsolated(body)
}

/// Watches for a game controller and publishes its live state for SwiftUI.
@MainActor
@Observable
final class ControllerMonitor {
    /// Buttons in the order the UI shows them, using DualSense names.
    static let buttonNames = [
        "Cross", "Circle", "Square", "Triangle",
        "L1", "R1", "L2", "R2", "L3", "R3",
        "Create", "Options", "PS", "Touchpad",
    ]

    private(set) var controllerName: String?
    private(set) var productCategory: String?
    private(set) var batteryLevel: Float?
    private(set) var batteryState: GCDeviceBattery.State?

    /// Each component is -1, 0 or 1. Positive y is up.
    private(set) var dpad = SIMD2<Float>.zero
    private(set) var leftStick = SIMD2<Float>.zero
    private(set) var rightStick = SIMD2<Float>.zero
    private(set) var leftTrigger: Float = 0
    private(set) var rightTrigger: Float = 0
    private(set) var pressedButtons: Set<String> = []

    /// Counts every input change the controller reports, as a quick check
    /// that input is reaching the app at all.
    private(set) var inputEventCount = 0

    private(set) var log: [LogEntry] = []

    var isConnected: Bool { controllerName != nil }

    /// Combined up/down reading from the directional pad and left stick.
    var verticalDirection: String {
        if dpad.y > 0 || leftStickVertical.value > 0 { return "UP" }
        if dpad.y < 0 || leftStickVertical.value < 0 { return "DOWN" }
        return "CENTER"
    }

    @ObservationIgnored private var controller: GCController?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var batteryTask: Task<Void, Never>?
    private var leftStickVertical = AxisZone()
    private var leftStickHorizontal = AxisZone()

    private let maxLogEntries = 500

    init() {
        addLog("App started. Waiting for a controller.")

        // Swift Playgrounds runs the app in a hosted process that the system
        // does not treat as the frontmost app. GameController only sends input
        // to the frontmost app unless background monitoring is on, so without
        // this the controller connects but no button or stick events arrive.
        GCController.shouldMonitorBackgroundEvents = true
        addLog("Background event monitoring on.")

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] note in
            guard let controller = note.object as? GCController else { return }
            onMain { self?.didConnect(controller) }
        })
        observers.append(center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] note in
            guard let controller = note.object as? GCController else { return }
            onMain { self?.didDisconnect(controller) }
        })

        // A controller that was already connected before launch does not post a
        // connect notification, so pick it up here.
        for controller in GCController.controllers() {
            didConnect(controller)
        }
    }

    func clearLog() {
        log.removeAll()
    }

    // MARK: Connection

    private func didConnect(_ controller: GCController) {
        guard self.controller !== controller else { return }
        addLog("Controller connected: \(displayName(of: controller))")

        guard self.controller == nil else {
            addLog("Already showing \(controllerName ?? "a controller"), ignoring the new one.")
            return
        }
        attach(controller)
    }

    private func didDisconnect(_ controller: GCController) {
        addLog("Controller disconnected: \(displayName(of: controller))")
        guard self.controller === controller else { return }

        detach()
        if let next = GCController.controllers().first(where: { $0 !== controller }) {
            attach(next)
        }
    }

    private func attach(_ controller: GCController) {
        self.controller = controller
        controllerName = displayName(of: controller)
        productCategory = controller.productCategory
        controller.handlerQueue = .main

        guard let pad = controller.extendedGamepad else {
            addLog("This controller has no extended gamepad profile, so input cannot be read.")
            return
        }
        if pad is GCDualSenseGamepad {
            addLog("DualSense profile detected.")
        }

        pad.valueChangedHandler = { [weak self] _, _ in
            onMain { self?.inputEventCount += 1 }
        }
        pad.dpad.valueChangedHandler = { [weak self] _, x, y in
            onMain { self?.dpadChanged(x: x, y: y) }
        }
        pad.leftThumbstick.valueChangedHandler = { [weak self] _, x, y in
            onMain { self?.leftStickChanged(x: x, y: y) }
        }
        pad.rightThumbstick.valueChangedHandler = { [weak self] _, x, y in
            onMain { self?.rightStick = SIMD2(x, y) }
        }
        pad.leftTrigger.valueChangedHandler = { [weak self] _, value, _ in
            onMain { self?.leftTrigger = value }
        }
        pad.rightTrigger.valueChangedHandler = { [weak self] _, value, _ in
            onMain { self?.rightTrigger = value }
        }

        var buttons: [(String, GCControllerButtonInput?)] = [
            ("Cross", pad.buttonA),
            ("Circle", pad.buttonB),
            ("Square", pad.buttonX),
            ("Triangle", pad.buttonY),
            ("L1", pad.leftShoulder),
            ("R1", pad.rightShoulder),
            ("L2", pad.leftTrigger),
            ("R2", pad.rightTrigger),
            ("L3", pad.leftThumbstickButton),
            ("R3", pad.rightThumbstickButton),
            ("Create", pad.buttonOptions),
            ("Options", pad.buttonMenu),
            ("PS", pad.buttonHome),
        ]
        if let dualSense = pad as? GCDualSenseGamepad {
            buttons.append(("Touchpad", dualSense.touchpadButton))
        }
        for (name, button) in buttons {
            button?.pressedChangedHandler = { [weak self] _, _, pressed in
                onMain { self?.buttonChanged(name, pressed: pressed) }
            }
        }

        refreshBattery(logIt: true)
        batteryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                self?.refreshBattery(logIt: false)
            }
        }
    }

    private func detach() {
        batteryTask?.cancel()
        batteryTask = nil
        controller = nil
        controllerName = nil
        productCategory = nil
        batteryLevel = nil
        batteryState = nil
        dpad = .zero
        leftStick = .zero
        rightStick = .zero
        leftTrigger = 0
        rightTrigger = 0
        pressedButtons = []
        inputEventCount = 0
        leftStickVertical = AxisZone()
        leftStickHorizontal = AxisZone()
    }

    private func refreshBattery(logIt: Bool) {
        guard let battery = controller?.battery else { return }
        let changed = batteryState != battery.batteryState
        batteryLevel = battery.batteryLevel
        batteryState = battery.batteryState
        if logIt || changed {
            addLog("Battery \(Int(battery.batteryLevel * 100))%, \(Self.describe(battery.batteryState))")
        }
    }

    // MARK: Input

    private func dpadChanged(x: Float, y: Float) {
        let old = dpad
        dpad = SIMD2(x, y)
        if y > 0, old.y <= 0 { addLog("D pad UP") }
        if y < 0, old.y >= 0 { addLog("D pad DOWN") }
        if x < 0, old.x >= 0 { addLog("D pad LEFT") }
        if x > 0, old.x <= 0 { addLog("D pad RIGHT") }
    }

    private func leftStickChanged(x: Float, y: Float) {
        leftStick = SIMD2(x, y)
        switch leftStickVertical.update(y) {
        case 1: addLog("Left stick UP")
        case -1: addLog("Left stick DOWN")
        default: break
        }
        switch leftStickHorizontal.update(x) {
        case 1: addLog("Left stick RIGHT")
        case -1: addLog("Left stick LEFT")
        default: break
        }
    }

    private func buttonChanged(_ name: String, pressed: Bool) {
        if pressed {
            pressedButtons.insert(name)
            addLog("\(name) pressed")
        } else {
            pressedButtons.remove(name)
            addLog("\(name) released")
        }
    }

    // MARK: Helpers

    private func addLog(_ message: String) {
        log.append(LogEntry(date: .now, message: message))
        if log.count > maxLogEntries {
            log.removeFirst(log.count - maxLogEntries)
        }
    }

    private func displayName(of controller: GCController) -> String {
        controller.vendorName ?? controller.productCategory
    }

    static func describe(_ state: GCDeviceBattery.State) -> String {
        switch state {
        case .charging: "charging"
        case .discharging: "on battery"
        case .full: "full"
        default: "unknown"
        }
    }
}
