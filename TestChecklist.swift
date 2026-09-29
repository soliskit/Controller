import SwiftUI

/// One check in the on screen test, in the order the user is asked to do them.
enum TestStep: Int, CaseIterable, Identifiable {
    case connect, anyInput, dpadUp, dpadDown, stickUp, stickDown, cross, leftTrigger, turnOff, turnOn

    var id: Int { rawValue }

    /// Short name for the checklist row and the log.
    var title: String {
        switch self {
        case .connect: "Controller connected"
        case .anyInput: "Input reaches the app"
        case .dpadUp: "D pad UP"
        case .dpadDown: "D pad DOWN"
        case .stickUp: "Left stick UP"
        case .stickDown: "Left stick DOWN"
        case .cross: "Cross button"
        case .leftTrigger: "L2 trigger"
        case .turnOff: "Disconnect detected"
        case .turnOn: "Reconnect detected"
        }
    }

    /// What the user should do.
    var command: String {
        switch self {
        case .connect: "Turn on your DualSense by pressing the PS button."
        case .anyInput: "Press any button on the controller."
        case .dpadUp: "Press UP on the D pad."
        case .dpadDown: "Press DOWN on the D pad."
        case .stickUp: "Push the left stick all the way UP."
        case .stickDown: "Pull the left stick all the way DOWN."
        case .cross: "Press the Cross (X) button."
        case .leftTrigger: "Squeeze the L2 trigger."
        case .turnOff: "Turn the controller off by holding PS for about 10 seconds."
        case .turnOn: "Turn it back on by pressing PS."
        }
    }

    /// What should change on screen when it works.
    var expectation: String {
        switch self {
        case .connect: "The dot turns green and the log says Controller connected."
        case .anyInput: "Input changes on the connection card goes above 0."
        case .dpadUp: "The UP / DOWN card shows UP and the up arrow lights."
        case .dpadDown: "The UP / DOWN card shows DOWN and the down arrow lights."
        case .stickUp: "The left stick dot moves up and the UP / DOWN card shows UP."
        case .stickDown: "The left stick dot moves down and the UP / DOWN card shows DOWN."
        case .cross: "Cross lights up in the Buttons card while you hold it."
        case .leftTrigger: "The L2 bar fills as you squeeze."
        case .turnOff: "The dot turns red and the log says Controller disconnected."
        case .turnOn: "The dot turns green again and the log says Controller connected."
        }
    }

    var hint: String? {
        switch self {
        case .connect: "Never paired? Hold PS and Create until the light bar flashes, then pick it in Settings, Bluetooth."
        case .turnOff: "The light bar goes dark once it is off."
        default: nil
        }
    }
}

enum TestResult {
    case passed, skipped
}

extension TestStep {
    /// The step a button press completes, if any.
    init?(pressing button: PadButton) {
        switch button {
        case .cross: self = .cross
        case .l2: self = .leftTrigger
        default: return nil
        }
    }
}

/// Walks the user through each check. Steps tick off by themselves as the
/// controller reports the matching input.
struct TestChecklist: View {
    @Environment(ControllerMonitor.self) private var monitor

    var body: some View {
        Card(title: "Test Checklist") {
            if let step = monitor.currentTestStep {
                CurrentStep(step: step)
            } else {
                Summary()
            }

            Divider()

            // Two columns on a wide screen keep the checklist short enough to
            // leave room for the event log below it.
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), alignment: .leading)], alignment: .leading, spacing: 6) {
                ForEach(TestStep.allCases) { step in
                    StepRow(step: step, result: monitor.result(for: step), isCurrent: step == monitor.currentTestStep)
                }
            }

            HStack {
                Button("Skip Step", systemImage: "forward") {
                    monitor.skipCurrentTest()
                }
                .disabled(monitor.currentTestStep == nil)
                Spacer()
                Button("Restart Test", systemImage: "arrow.counterclockwise") {
                    monitor.restartTest()
                }
            }
            .buttonStyle(.bordered)
        }
    }
}

private struct CurrentStep: View {
    @Environment(ControllerMonitor.self) private var monitor
    let step: TestStep

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Step \(step.rawValue + 1) of \(TestStep.allCases.count)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.accentColor)
            Text(step.command)
                .font(.title2.weight(.bold))
                .fixedSize(horizontal: false, vertical: true)
            Label("Check: \(step.expectation)", systemImage: "eye")
                .font(.callout)
                .foregroundStyle(.secondary)
            if let hint = step.hint {
                Label(hint, systemImage: "lightbulb")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if step == .anyInput, let since = monitor.connection?.connectedAt {
                // If input never arrives, suggest the known Swift Playgrounds workaround.
                TimelineView(.periodic(from: since, by: 1)) { context in
                    if context.date.timeIntervalSince(since) > Tuning.noInputHintDelay {
                        Label("Nothing yet? Close Swift Playgrounds completely, turn the controller off, run the app again, then turn the controller on.", systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(Color.orange)
                    }
                }
            }
        }
    }
}

private struct Summary: View {
    @Environment(ControllerMonitor.self) private var monitor

    var body: some View {
        let skipped = monitor.skippedCount
        let clean = skipped == 0 && monitor.faultCount == 0
        VStack(alignment: .leading, spacing: 6) {
            Label(clean ? "All checks passed" : "Test finished", systemImage: "checkmark.seal.fill")
                .font(.title2.weight(.bold))
                .foregroundStyle(clean ? Color.green : Color.orange)
            Text("\(TestStep.allCases.count - skipped) passed, \(skipped) skipped.")
            Text("Faults: \(monitor.faultCount)")
                .foregroundStyle(monitor.faultCount == 0 ? Color.secondary : Color.red)
        }
        .font(.callout)
    }
}

private struct StepRow: View {
    let step: TestStep
    let result: TestResult?
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .frame(width: 20)
            Text("\(step.rawValue + 1). \(step.title)")
                .fontWeight(isCurrent ? Font.Weight.semibold : Font.Weight.regular)
                .foregroundStyle(isCurrent || result != nil ? Color.primary : Color.secondary)
            Spacer()
            if result == .skipped {
                Text("skipped")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
    }

    private var symbol: String {
        switch result {
        case .passed?: "checkmark.circle.fill"
        case .skipped?: "forward.circle"
        case nil: isCurrent ? "arrow.right.circle.fill" : "circle"
        }
    }

    private var color: Color {
        switch result {
        case .passed?: .green
        case .skipped?: .orange
        case nil: isCurrent ? .accentColor : .secondary
        }
    }
}
