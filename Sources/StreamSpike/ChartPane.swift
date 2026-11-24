import Charts
import SwiftUI
import StreamSpikeKit

/// Chat velocity over time, with a marker on every spike. Click a marker, or the bucket it sits in, to select it.
struct ChartPane: View {
    @Environment(AppModel.self) private var model
    let runtime: SessionRuntime
    @State private var hoverTime: Double?

    private var bucketSize: Double {
        let buckets = runtime.buckets
        return buckets.count >= 2 ? buckets[1].start - buckets[0].start : Double(model.settings.detection.bucketSeconds)
    }

    private var domainEnd: Double { max(runtime.duration, bucketSize * 6) }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            header
            chart
        }
        .padding(Space.lg)
        .overlay {
            if runtime.buckets.isEmpty {
                ContentUnavailableView(runtime.isRunning ? "Waiting for chat" : "No chat",
                                       systemImage: "bubble.left.and.bubble.right")
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
            Text("Chat velocity").font(.headline)
            Text("messages per \(Int(bucketSize)) s").font(.callout).foregroundStyle(.secondary)
            Spacer()
            Text(readout)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var readout: String {
        if let hoverTime, let bucket = bucket(at: hoverTime) {
            let z = bucket.z == 0 ? "" : String(format: " · z %.1f", bucket.z)
            return "\(Timecode.string(bucket.start)) · \(bucket.count) messages\(z)"
        }
        if let spike = runtime.selectedSpike {
            return "Spike at \(Timecode.string(spike.time)) · z \(String(format: "%.1f", spike.zScore))"
        }
        let n = runtime.spikes.count
        return n == 0 ? "" : (n == 1 ? "1 spike" : "\(n) spikes")
    }

    private func bucket(at time: Double) -> ChatBucket? {
        let index = Int(time / bucketSize)
        return runtime.buckets.indices.contains(index) && time >= 0 ? runtime.buckets[index] : nil
    }

    private var chart: some View {
        let size = bucketSize
        let preRoll = model.settings.detection.preRoll
        let postRoll = model.settings.detection.postRoll
        return Chart {
            if let spike = runtime.selectedSpike {
                RectangleMark(xStart: .value("Window start", max(0, spike.runStart - preRoll)),
                              xEnd: .value("Window end", spike.time + postRoll))
                    .foregroundStyle(Palette.accent.opacity(0.10))
            }
            ForEach(runtime.buckets) { bucket in
                AreaMark(x: .value("Time", bucket.start + size / 2), y: .value("Messages", bucket.count))
                    .foregroundStyle(LinearGradient(colors: [Palette.accent.opacity(0.35), Palette.accent.opacity(0.04)],
                                                    startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Time", bucket.start + size / 2), y: .value("Messages", bucket.count))
                    .foregroundStyle(Palette.accent)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    .interpolationMethod(.monotone)
            }
            ForEach(runtime.spikes) { spike in
                let selected = spike.id == runtime.selectedSpikeID
                PointMark(x: .value("Spike", spike.time + size / 2), y: .value("Messages", spike.messageCount))
                    .symbol(selected ? .diamond : .circle)
                    .symbolSize(selected ? 220 : 90)
                    .foregroundStyle(selected ? Palette.accent : Color.orange)
            }
            if let spike = runtime.selectedSpike {
                RuleMark(x: .value("Selected", spike.time + size / 2))
                    .foregroundStyle(Palette.accent.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
            if let hoverTime {
                RuleMark(x: .value("Hover", hoverTime))
                    .foregroundStyle(.secondary.opacity(0.4))
            }
        }
        .chartXScale(domain: 0...domainEnd)
        .chartXAxis {
            AxisMarks(values: .stride(by: Self.axisStep(for: domainEnd))) { value in
                AxisGridLine()
                AxisTick()
                AxisValueLabel {
                    if let seconds = value.as(Double.self) { Text(Timecode.string(seconds)) }
                }
            }
        }
        .chartYAxis { AxisMarks(position: .leading) }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let point): hoverTime = time(at: point, proxy: proxy, geometry: geometry)
                        case .ended: hoverTime = nil
                        }
                    }
                    .onTapGesture { point in select(at: point, proxy: proxy, geometry: geometry) }
            }
        }
        .accessibilityLabel("Chat velocity chart")
        .accessibilityValue(readout)
    }

    private func time(at point: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) -> Double? {
        guard let frame = proxy.plotFrame else { return nil }
        return proxy.value(atX: point.x - geometry[frame].origin.x, as: Double.self)
    }

    private func select(at point: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) {
        guard let frame = proxy.plotFrame, let tapped = time(at: point, proxy: proxy, geometry: geometry) else { return }
        let width = geometry[frame].width
        // A click within 14 points of a marker, or anywhere inside a spike's run of buckets, selects it.
        let slack = domainEnd / max(width, 1) * 14
        let hit = runtime.spikes.first { tapped >= $0.runStart && tapped <= $0.runEnd }
            ?? runtime.spikes.min { abs($0.time + bucketSize / 2 - tapped) < abs($1.time + bucketSize / 2 - tapped) }
                .flatMap { abs($0.time + bucketSize / 2 - tapped) <= slack ? $0 : nil }
        runtime.selectedSpikeID = hit?.id
    }

    /// A round step so the axis shows about eight labels: 1, 5, 10, 15, 30 minutes, 1 hour.
    static func axisStep(for end: Double) -> Double {
        let steps: [Double] = [30, 60, 120, 300, 600, 900, 1800, 3600, 7200]
        return steps.first { end / $0 <= 9 } ?? 7200
    }
}
