import SwiftUI

struct SystemMetricsView: View {
    @ObservedObject private var monitor: SystemMetricsMonitor

    init(monitor: SystemMetricsMonitor) {
        _monitor = ObservedObject(wrappedValue: monitor)
    }

    var body: some View {
        HStack(spacing: 14) {
            if monitor.snapshot.temperatureCelsius != nil {
                metric("温度", value: temperatureLabel)
            }
            metric("CPU", value: percentLabel(monitor.snapshot.cpuUsagePercent))
            metric("存储", value: percentLabel(monitor.snapshot.storageUsedPercent))
        }
        .lineLimit(1)
        .padding(.horizontal, 2)
        .help(detailLabel)
    }

    private var temperatureLabel: String {
        guard let value = monitor.snapshot.temperatureCelsius else { return "—" }
        return "\(Int(value.rounded()))°C"
    }

    private func percentLabel(_ value: Double?) -> String {
        value.map { "\(Int($0.rounded()))%" } ?? "—"
    }

    private var detailLabel: String {
        let storage: String
        if let used = monitor.snapshot.storageUsedBytes, let total = monitor.snapshot.storageTotalBytes {
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            storage = "存储 \(formatter.string(fromByteCount: used)) / \(formatter.string(fromByteCount: total))"
        } else {
            storage = "存储暂不可用"
        }
        let temperature: String
        switch monitor.snapshot.temperatureSource {
        case "cpu_smc": temperature = "温度为 AppleSMC CPU 核心传感器的当前平均值"
        case "cpu_hid": temperature = "温度为 CPU 与 SoC 传感器中的当前最高值，来源为 CPU"
        case "soc_hid": temperature = "温度为 CPU 与 SoC 传感器中的当前最高值，来源为 SoC"
        default: temperature = "芯片温度传感器不可用"
        }
        return "\(temperature) · CPU 为整机占用 · \(storage) · 每 \(monitor.refreshIntervalSeconds) 秒刷新"
    }

    private func metric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 9)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit()
        }
        .frame(minWidth: 44, alignment: .leading)
    }
}
