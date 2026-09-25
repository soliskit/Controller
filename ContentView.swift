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
                        EventLog()
                    }
                } else {
                    VStack(spacing: 16) {
                        StatePanel()
                        EventLog()
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
        VStack(spacing: 12) {
            ConnectionCard()

            Card(title: "Up / Down") {
                Text(monitor.verticalDirection)
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .foregroundStyle(monitor.verticalDirection == "CENTER" ? Color.secondary : Color.accentColor)
                    .frame(maxWidth: .infinity)
                    .contentTransition(.numericText())
                    .animation(.snappy, value: monitor.verticalDirection)
            }

            HStack(spacing: 12) {
                Card(title: "D Pad") { DirectionPad(value: monitor.dpad) }
                Card(title: "Left Stick") { StickView(value: monitor.leftStick) }
                Card(title: "Right Stick") { StickView(value: monitor.rightStick) }
            }
            .fixedSize(horizontal: false, vertical: true)

            Card(title: "Triggers") {
                VStack(spacing: 8) {
                    TriggerBar(label: "L2", value: monitor.leftTrigger)
                    TriggerBar(label: "R2", value: monitor.rightTrigger)
                }
            }

            Card(title: "Buttons") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 80))], spacing: 8) {
                    ForEach(ControllerMonitor.buttonNames, id: \.self) { name in
                        let pressed = monitor.pressedButtons.contains(name)
                        Text(name)
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
                if let name = monitor.controllerName {
                    Text("Connected").font(.headline)
                    Text(name).foregroundStyle(.secondary)
                    if let category = monitor.productCategory, category != name {
                        Text(category).font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Input events received: \(monitor.inputEventCount)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(monitor.inputEventCount > 0 ? Color.green : Color.orange)
                    Text("Polled changes: \(monitor.polledChangeCount)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(monitor.polledChangeCount > 0 ? Color.green : Color.orange)
                } else {
                    Text("No controller").font(.headline)
                    Text("Pair your DualSense in Settings, Bluetooth. Hold PS and Create until the light bar flashes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let level = monitor.batteryLevel, let state = monitor.batteryState {
                VStack(alignment: .trailing) {
                    Label("\(Int(level * 100))%", systemImage: state == .charging ? "battery.100percent.bolt" : "battery.75percent")
                        .monospacedDigit()
                    Text(ControllerMonitor.describe(state)).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: .rect(cornerRadius: 12))
    }
}

private struct Card<Content: View>: View {
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
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.background.secondary, in: .rect(cornerRadius: 12))
    }
}

private struct DirectionPad: View {
    let value: SIMD2<Float>

    var body: some View {
        Grid(horizontalSpacing: 2, verticalSpacing: 2) {
            GridRow {
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                arrow("arrowtriangle.up.fill", on: value.y > 0)
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
            }
            GridRow {
                arrow("arrowtriangle.left.fill", on: value.x < 0)
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                arrow("arrowtriangle.right.fill", on: value.x > 0)
            }
            GridRow {
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                arrow("arrowtriangle.down.fill", on: value.y < 0)
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
            }
        }
        .frame(maxWidth: .infinity)
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
        VStack(alignment: .leading, spacing: 8) {
            Text("Event Log")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            ScrollViewReader { proxy in
                List(monitor.log) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(entry.date, format: .dateTime.hour().minute().second().secondFraction(.fractional(3)))
                            .foregroundStyle(.secondary)
                        Text(entry.message)
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
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.background.secondary, in: .rect(cornerRadius: 12))
    }
}
