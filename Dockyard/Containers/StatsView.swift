import Charts
import DockyardCore
import SwiftUI

struct StatsView: View {
    let container: ContainerItem
    @Environment(AppModel.self) private var model

    private var store: StatsStore { model.stats }

    var body: some View {
        Group {
            if container.status != .running {
                EmptyListView(
                    symbol: "chart.line.uptrend.xyaxis",
                    title: "Container isn’t running",
                    message: "Resource usage is only reported while a container is running."
                )
            } else if store.isWarmingUp {
                VStack(spacing: 10) {
                    ProgressView()
                    // Rates need two readings; saying so beats drawing a flat
                    // line at zero and letting the user think it is idle.
                    Text("Measuring…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                charts
            }
        }
        .task(id: container.id) {
            store.start(containerID: container.id)
        }
        .onDisappear {
            // 1 Hz polling behind a hidden tab is exactly the kind of cost
            // T07 went to some trouble to remove.
            store.stop()
        }
    }

    private var charts: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                cpuCard
                memoryCard
                throughputCard(
                    title: "Network",
                    symbol: "network",
                    inLabel: "Received",
                    outLabel: "Sent",
                    inValue: \.networkReceivedPerSecond,
                    outValue: \.networkSentPerSecond
                )
                throughputCard(
                    title: "Disk",
                    symbol: "internaldrive",
                    inLabel: "Read",
                    outLabel: "Written",
                    inValue: \.blockReadPerSecond,
                    outValue: \.blockWrittenPerSecond
                )
            }
            .padding(16)
        }
    }

    // MARK: - Cards

    private var cpuCard: some View {
        card(
            title: "CPU",
            symbol: "cpu",
            value: (store.latest?.cpuPercent).map { String(format: "%.1f%%", $0) } ?? "—",
            detail: "100% is one core · peak \(String(format: "%.0f%%", store.peakCPUPercent))"
        ) {
            Chart(store.samples) { sample in
                AreaMark(
                    x: .value("Time", sample.timestamp),
                    y: .value("CPU", sample.cpuPercent)
                )
                .foregroundStyle(.blue.opacity(0.18))
                LineMark(
                    x: .value("Time", sample.timestamp),
                    y: .value("CPU", sample.cpuPercent)
                )
                .foregroundStyle(.blue)
                .interpolationMethod(.monotone)
            }
            // Scaled to at least one core so a near-idle container does not
            // look busy through an auto-scaled axis.
            .chartYScale(domain: 0...max(100, store.peakCPUPercent * 1.15))
            .chartYAxis { AxisMarks(format: Decimal.FormatStyle.Percent.percent.scale(1)) }
        }
    }

    private var memoryCard: some View {
        let latest = store.latest
        return card(
            title: "Memory",
            symbol: "memorychip",
            value: latest.map { $0.memoryUsedBytes.formatted(.byteCount(style: .memory)) } ?? "—",
            detail: memoryDetail(latest)
        ) {
            Chart(store.samples) { sample in
                AreaMark(
                    x: .value("Time", sample.timestamp),
                    y: .value("Memory", sample.memoryUsedBytes)
                )
                .foregroundStyle(.purple.opacity(0.18))
                LineMark(
                    x: .value("Time", sample.timestamp),
                    y: .value("Memory", sample.memoryUsedBytes)
                )
                .foregroundStyle(.purple)
                .interpolationMethod(.monotone)
            }
            .chartYScale(domain: 0...Double(max(store.peakMemoryBytes, 1)) * 1.15)
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let bytes = value.as(Double.self) {
                            Text(UInt64(bytes).formatted(.byteCount(style: .memory)))
                        }
                    }
                }
            }
        }
    }

    private func memoryDetail(_ sample: ContainerStatsSample?) -> String {
        guard let sample, let limit = sample.memoryLimitBytes else {
            return "no limit reported"
        }
        let percent = (sample.memoryFraction ?? 0) * 100
        // A container using 2 MB of a 1 GB limit is at 0.2%, and rounding that
        // to "0%" reads as though nothing were measured.
        let formatted = percent < 10 ? String(format: "%.1f%%", percent) : String(format: "%.0f%%", percent)
        return "\(formatted) of \(limit.formatted(.byteCount(style: .memory)))"
    }

    private func throughputCard(
        title: String,
        symbol: String,
        inLabel: String,
        outLabel: String,
        inValue: KeyPath<ContainerStatsSample, Double>,
        outValue: KeyPath<ContainerStatsSample, Double>
    ) -> some View {
        let latest = store.latest
        let inRate: Double = latest?[keyPath: inValue] ?? 0
        let outRate: Double = latest?[keyPath: outValue] ?? 0

        return card(
            title: title,
            symbol: symbol,
            value: "\(rate(inRate)) ↓  \(rate(outRate)) ↑",
            detail: "\(inLabel) and \(outLabel) per second"
        ) {
            Chart(store.samples) { sample in
                LineMark(
                    x: .value("Time", sample.timestamp),
                    y: .value("Rate", sample[keyPath: inValue]),
                    series: .value("Direction", inLabel)
                )
                .foregroundStyle(.green)
                .interpolationMethod(.monotone)

                LineMark(
                    x: .value("Time", sample.timestamp),
                    y: .value("Rate", sample[keyPath: outValue]),
                    series: .value("Direction", outLabel)
                )
                .foregroundStyle(.orange)
                .interpolationMethod(.monotone)
            }
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let bytes = value.as(Double.self) {
                            Text(UInt64(max(0, bytes)).formatted(.byteCount(style: .memory)))
                        }
                    }
                }
            }
        }
    }

    private func rate(_ bytesPerSecond: Double) -> String {
        // `spellsOutZero` is on by default and renders an idle container as
        // "Zero kB/s", which reads like a bug rather than a measurement.
        let bytes = UInt64(max(0, bytesPerSecond))
        return "\(bytes.formatted(.byteCount(style: .memory, spellsOutZero: false)))/s"
    }

    private func card(
        title: String,
        symbol: String,
        value: String,
        detail: String,
        @ViewBuilder chart: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label(title, systemImage: symbol)
                    .font(.headline)
                Spacer()
                Text(value)
                    .font(.title3.monospacedDigit())
                    .contentTransition(.numericText())
            }
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
            chart()
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.minute().second())
                    }
                }
                .frame(height: 120)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }
}
