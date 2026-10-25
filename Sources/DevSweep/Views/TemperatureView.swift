import Charts
import DevSweepCore
import SwiftUI

/// How hot the Mac is right now, and which apps are heating it.
struct TemperatureView: View {
    @Environment(AppModel.self) private var model
    @State private var metric = UsageMetric.power
    let theme = ModuleTheme.heat

    var body: some View {
        let thermal = model.monitor.thermal
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ModuleHeader(theme: theme, title: "Temperature",
                             subtitle: "How hot your Mac is, and which apps are heating it. Apps don't have a temperature of their own, so they're ranked by the power they draw — that's what warms the chip.")
                    .appearIn()

                HStack(alignment: .top, spacing: 16) {
                    ThermometerCard(thermal: thermal)
                        .frame(width: 280)
                    VStack(spacing: 16) {
                        TemperatureChartCard()
                        SensorGroupsCard(groups: thermal.groups)
                    }
                }
                .appearIn(delay: 0.06)

                if thermal.state != .nominal {
                    HStack(spacing: 12) {
                        Image(systemName: "lightbulb.fill").foregroundStyle(thermal.state.color)
                        Text("Quitting the apps at the top of the list cools things down fastest. Keep the vents clear, and on a laptop, a hard surface helps.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glass(cornerRadius: 14)
                }

                // Where macOS doesn't account energy per process (older Intel Macs), rank by CPU instead.
                let reportsPower = model.processes.apps.contains { $0.watts > 0 }
                TopAppsCard(metric: $metric, choices: reportsPower ? [.power, .cpu] : [.cpu],
                            title: "Apps heating your Mac", tint: theme)
                    .onAppear { if !reportsPower { metric = .cpu } }
                    .appearIn(delay: 0.12)
            }
            .padding(28)
            .frame(maxWidth: 1060)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Temperature")
        .whileVisible(start: {
            model.monitor.start()
            model.processes.start()
        }, stop: {
            model.monitor.stop()
            model.processes.stop()
        })
    }
}

extension ThermalSnapshot.State {
    var color: Color {
        switch self {
        case .nominal: ModuleTheme.hex(0x2DD4BF)
        case .fair: ModuleTheme.hex(0xFACC15)
        case .serious: ModuleTheme.hex(0xFB923C)
        case .critical: ModuleTheme.hex(0xEF4444)
        }
    }
}

/// A colour for a temperature: teal when cool, through yellow and orange, to red when very hot.
func temperatureColor(_ celsius: Double) -> Color {
    switch celsius {
    case ..<55: ModuleTheme.hex(0x2DD4BF)
    case ..<72: ModuleTheme.hex(0xFACC15)
    case ..<88: ModuleTheme.hex(0xFB923C)
    default: ModuleTheme.hex(0xEF4444)
    }
}

func formatTemperature(_ celsius: Double?) -> String {
    celsius.map { "\(Int($0.rounded()))°" } ?? "—"
}

private struct ThermometerCard: View {
    let thermal: ThermalSnapshot

    var body: some View {
        let celsius = thermal.cpu
        // The arc spans 20–110 °C. It's drawn from 45° to 315° and turned a quarter, so it opens at
        // the bottom; the gradient uses the unturned angles.
        let fraction = celsius.map { min(1, max(0, ($0 - 20) / 90)) } ?? 0
        let color = celsius.map(temperatureColor) ?? .secondary
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .trim(from: 0.125, to: 0.875)
                    .stroke(.white.opacity(0.08), style: StrokeStyle(lineWidth: 14, lineCap: .round))
                    .rotationEffect(.degrees(90))
                Circle()
                    .trim(from: 0.125, to: 0.125 + 0.75 * fraction)
                    .stroke(AngularGradient(colors: [ModuleTheme.hex(0x2DD4BF), ModuleTheme.hex(0xFACC15), ModuleTheme.hex(0xFB923C), ModuleTheme.hex(0xEF4444)],
                                            center: .center, startAngle: .degrees(45), endAngle: .degrees(315)),
                            style: StrokeStyle(lineWidth: 14, lineCap: .round))
                    .rotationEffect(.degrees(90))
                    .animation(.easeOut(duration: 0.6), value: fraction)
                VStack(spacing: 2) {
                    Text(celsius.map { "\(Int($0.rounded()))°C" } ?? "—")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(color)
                    Text("CPU").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 170, height: 170)
            HStack(spacing: 6) {
                Circle().fill(thermal.state.color).frame(width: 8, height: 8)
                Text(thermal.state.title).font(.callout.weight(.semibold))
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Capsule().fill(thermal.state.color.opacity(0.14)))
            Text(thermal.sensors.isEmpty ? "This Mac doesn't share its temperature sensors with apps." : thermal.state.detail)
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            HStack(spacing: 18) {
                stat("Hottest", formatTemperature(thermal.hottest))
                stat("Battery", formatTemperature(thermal.battery))
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .glass(cornerRadius: 20)
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.callout.weight(.semibold)).monospacedDigit()
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

private struct TemperatureChartCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let history = model.monitor.temperatureHistory
        let points = Array(history.enumerated())
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    CardTitle(title: "CPU temperature", subtitle: "Last few minutes")
                    Spacer()
                    if let low = history.min(), let high = history.max() {
                        Text("\(Int(low.rounded()))–\(Int(high.rounded()))°C").font(.callout.weight(.semibold)).monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                if points.count < 2 {
                    Text("Measuring…").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 90)
                } else {
                    let low = (history.min() ?? 30) - 6
                    let high = (history.max() ?? 80) + 6
                    Chart(points, id: \.offset) { point in
                        AreaMark(x: .value("Sample", point.offset), yStart: .value("Base", low), yEnd: .value("°C", point.element))
                            .foregroundStyle(LinearGradient(colors: [ModuleTheme.heat.primary.opacity(0.28), ModuleTheme.heat.primary.opacity(0.02)],
                                                            startPoint: .top, endPoint: .bottom))
                            .interpolationMethod(.monotone)
                        LineMark(x: .value("Sample", point.offset), y: .value("°C", point.element))
                            .foregroundStyle(ModuleTheme.heat.gradient)
                            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                            .interpolationMethod(.monotone)
                    }
                    .chartXAxis(.hidden)
                    .chartYScale(domain: low...high)
                    .chartYAxis {
                        AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                            AxisGridLine().foregroundStyle(.white.opacity(0.07))
                            AxisValueLabel { Text("\(Int(value.as(Double.self) ?? 0))°") }
                        }
                    }
                    .frame(height: 96)
                }
            }
        }
    }
}

private struct SensorGroupsCard: View {
    let groups: [ThermalSnapshot.Group]

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                CardTitle(title: "Inside your Mac", subtitle: "Hottest sensor in each part")
                if groups.isEmpty {
                    Text("No sensors to show.").foregroundStyle(.secondary)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                    ForEach(groups) { group in
                        HStack(spacing: 10) {
                            Image(systemName: group.symbol)
                                .font(.callout)
                                .foregroundStyle(temperatureColor(group.celsius))
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(group.title).font(.caption).foregroundStyle(.secondary)
                                Text("\(Int(group.celsius.rounded()))°C").font(.callout.weight(.semibold)).monospacedDigit()
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.04)))
                    }
                }
            }
        }
    }
}
