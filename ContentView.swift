import SwiftUI

struct ContentView: View {
    @Environment(ControllerMonitor.self) private var monitor
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        NavigationStack {
            Group {
                if sizeClass == .regular {
                    HStack(alignment: .top, spacing: 16) {
                        ScrollView { StatePanel() }
                            .frame(maxWidth: 420)
                        // The checklist sits beside the live state so both stay
                        // visible while working through the steps.
                        VStack(spacing: 16) {
                            TestChecklist()
                                .fixedSize(horizontal: false, vertical: true)
                            EventLog()
                        }
                    }
                } else {
                    ScrollView {
                        VStack(spacing: 16) {
                            TestChecklist()
                            StatePanel()
                            EventLog()
                                .frame(height: 320)
                        }
                    }
                }
            }
            .padding()
            .navigationTitle("Controller Debug")
            .background(GameControllerEventCapture())
            .toolbar {
                Button("Clear Log", systemImage: "trash") {
                    monitor.clearLog()
                }
            }
        }
    }
}

// MARK: Live state

private struct StatePanel: View {
    @Environment(ControllerMonitor.self) private var monitor

    var body: some View {
        let sample = monitor.sample
        VStack(spacing: 12) {
            ConnectionCard()

            Card(title: "Up / Down") {
                Text(monitor.verticalDirection.title)
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .foregroundStyle(monitor.verticalDirection == .center ? Color.secondary : Color.accentColor)
                    .frame(maxWidth: .infinity)
                    .contentTransition(.numericText())
                    .animation(.snappy, value: monitor.verticalDirection)
            }

            HStack(spacing: 12) {
                Card(title: "D Pad") { DirectionPad(value: sample.dpad) }
                Card(title: "Left Stick") { StickView(value: sample.leftStick) }
                Card(title: "Right Stick") { StickView(value: sample.rightStick) }
            }
            .fixedSize(horizontal: false, vertical: true)

            Card(title: "Triggers") {
                VStack(spacing: 8) {
                    TriggerBar(label: PadButton.l2.title, value: sample.leftTrigger)
                    TriggerBar(label: PadButton.r2.title, value: sample.rightTrigger)
                }
            }

            Card(title: "Buttons") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 80))], spacing: 8) {
                    ForEach(PadButton.allCases) { button in
                        let pressed = sample.pressed.contains(button)
                        Text(button.title)
                            .font(.callout.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 32)
                            .background(pressed ? Color.accentColor : Color.secondary.opacity(0.15), in: .capsule)
                            .foregroundStyle(pressed ? Color.white : Color.primary)
                    }
                }
            }
        }
        .opacity(monitor.isConnected ? 1 : 0.5)
    }
}

private struct ConnectionCard: View {
    @Environment(ControllerMonitor.self) private var monitor

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(monitor.isConnected ? Color.green : Color.red)
                .frame(width: 14, height: 14)
            VStack(alignment: .leading, spacing: 2) {
                if let info = monitor.connection {
                    Text("Connected").font(.headline)
                    Text(info.name).foregroundStyle(.secondary)
                    if info.category != info.name {
                        Text(info.category).font(.caption).foregroundStyle(.secondary)
                    }
                    StatusLine(label: "Input changes", value: monitor.inputChangeCount,
                               color: monitor.inputChangeCount > 0 ? .green : .orange)
                } else {
                    Text("No controller").font(.headline)
                    Text("Pair your DualSense in Settings, Bluetooth. Hold PS and Create until the light bar flashes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                StatusLine(label: "Faults", value: monitor.faultCount,
                           color: monitor.faultCount == 0 ? .green : .red)
            }
            Spacer()
            if let level = monitor.connection?.batteryLevel, let state = monitor.connection?.batteryState {
                VStack(alignment: .trailing) {
                    Label("\(Int(level * 100))%", systemImage: state == .charging ? "battery.100percent.bolt" : "battery.75percent")
                        .monospacedDigit()
                    Text(state.title).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .cardStyle()
    }
}

/// A labeled counter, colored by whether its value is healthy.
private struct StatusLine: View {
    let label: String
    let value: Int
    let color: Color

    var body: some View {
        Text("\(label): \(value)")
            .font(.caption.monospacedDigit())
            .foregroundStyle(color)
    }
}

struct Card<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            content
        }
        .cardStyle()
    }
}

private extension View {
    /// The rounded panel shared by every card.
    func cardStyle() -> some View {
        padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(.background.secondary, in: .rect(cornerRadius: 12))
    }
}

private struct DirectionPad: View {
    let value: SIMD2<Float>

    var body: some View {
        Grid(horizontalSpacing: 2, verticalSpacing: 2) {
            GridRow {
                blank
                arrow("arrowtriangle.up.fill", on: value.y > 0)
                blank
            }
            GridRow {
                arrow("arrowtriangle.left.fill", on: value.x < 0)
                blank
                arrow("arrowtriangle.right.fill", on: value.x > 0)
            }
            GridRow {
                blank
                arrow("arrowtriangle.down.fill", on: value.y < 0)
                blank
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var blank: some View {
        Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
    }

    private func arrow(_ symbol: String, on: Bool) -> some View {
        Image(systemName: symbol)
            .font(.title3)
            .frame(width: 28, height: 28)
            .foregroundStyle(on ? Color.accentColor : Color.secondary.opacity(0.4))
    }
}

private struct StickView: View {
    let value: SIMD2<Float>
    private let size: CGFloat = 84

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().stroke(Color.secondary.opacity(0.4), lineWidth: 2)
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 16, height: 16)
                    // Screen y grows downward, controller y grows upward.
                    .offset(x: CGFloat(value.x) * size / 2, y: CGFloat(-value.y) * size / 2)
            }
            .frame(width: size, height: size)

            Text(String(format: "x %+.2f\ny %+.2f", value.x, value.y))
                .font(.caption.monospacedDigit())
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct TriggerBar: View {
    let label: String
    let value: Float

    var body: some View {
        HStack {
            Text(label).font(.callout.weight(.semibold)).frame(width: 28, alignment: .leading)
            ProgressView(value: Double(value))
            Text(String(format: "%.2f", value))
                .font(.caption.monospacedDigit())
                .frame(width: 40, alignment: .trailing)
        }
    }
}

// MARK: Event log

private struct EventLog: View {
    @Environment(ControllerMonitor.self) private var monitor

    var body: some View {
        Card(title: "Event Log") {
            ScrollViewReader { proxy in
                List(monitor.log) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(entry.date, format: .dateTime.hour().minute().second().secondFraction(.fractional(3)))
                            .foregroundStyle(.secondary)
                        Text(entry.message)
                            .foregroundStyle(entry.isFault ? Color.red : Color.primary)
                    }
                    .font(.system(.callout, design: .monospaced))
                    .id(entry.id)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .onChange(of: monitor.log.last?.id) { _, id in
                    if let id {
                        proxy.scrollTo(id, anchor: .bottom)
                    }
                }
            }
        }
    }
}
