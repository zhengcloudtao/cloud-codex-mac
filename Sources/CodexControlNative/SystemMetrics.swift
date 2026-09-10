import Darwin
import Foundation
import IOKit

enum SystemMetricsRefreshInterval: Int, CaseIterable, Identifiable {
    static let storageKey = "cloudcodex.systemMetricsRefreshInterval"

    case oneSecond = 1
    case twoSeconds = 2
    case fiveSeconds = 5
    case tenSeconds = 10
    case thirtySeconds = 30
    case sixtySeconds = 60

    var id: Int { rawValue }
    var title: String { "\(rawValue) 秒" }

    static func resolved(_ rawValue: Int) -> Self {
        Self(rawValue: rawValue) ?? .fiveSeconds
    }
}

struct SystemMetricsSnapshot: Codable, Equatable {
    var cpuUsagePercent: Double?
    var storageUsedBytes: Int64?
    var storageTotalBytes: Int64?
    var temperatureCelsius: Double?
    var temperatureSource: String?
    var capturedAt: Double

    static var unavailable: Self {
        .init(cpuUsagePercent: nil, storageUsedBytes: nil, storageTotalBytes: nil,
              temperatureCelsius: nil, temperatureSource: nil,
              capturedAt: Date().timeIntervalSince1970)
    }

    var storageUsedPercent: Double? {
        guard let used = storageUsedBytes, let total = storageTotalBytes, total > 0 else { return nil }
        return min(100, max(0, Double(used) / Double(total) * 100))
    }

    var hasValues: Bool {
        cpuUsagePercent != nil || storageUsedPercent != nil || temperatureCelsius != nil
    }
}

@MainActor
final class SystemMetricsMonitor: ObservableObject {
    @Published private(set) var snapshot = SystemMetricsSnapshot.unavailable
    @Published private(set) var refreshIntervalSeconds: Int = SystemMetricsRefreshInterval.fiveSeconds.rawValue

    private var previousCPUTicks: CPUTicks?
    private var loop: Task<Void, Never>?
    private var hasStarted = false

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        sample()
        startLoop()
    }

    func setRefreshInterval(_ interval: SystemMetricsRefreshInterval) {
        guard refreshIntervalSeconds != interval.rawValue else { return }
        refreshIntervalSeconds = interval.rawValue
        guard hasStarted else { return }
        sample()
        startLoop()
    }

    private func startLoop() {
        loop?.cancel()
        let nanoseconds = UInt64(refreshIntervalSeconds) * 1_000_000_000
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: nanoseconds)
                guard !Task.isCancelled, let self else { return }
                self.sample()
            }
        }
    }

    func sample() {
        let ticks = Self.readCPUTicks()
        let cpu = previousCPUTicks.flatMap { ticks?.usage(since: $0) }
        if let ticks { previousCPUTicks = ticks }
        let storage = Self.readStorage()
        let smcTemperature = AppleSMCTemperatureReader.readCPUAverage()
        let hidTemperature = smcTemperature == nil ? AppleSiliconTemperatureReader.readChipTemperature() : nil
        snapshot = .init(
            cpuUsagePercent: cpu,
            storageUsedBytes: storage?.used,
            storageTotalBytes: storage?.total,
            temperatureCelsius: smcTemperature?.value ?? hidTemperature?.value,
            temperatureSource: smcTemperature == nil ? hidTemperature?.source : "cpu_smc",
            capturedAt: Date().timeIntervalSince1970
        )
    }

    deinit { loop?.cancel() }

    private struct CPUTicks {
        let user: UInt64
        let system: UInt64
        let idle: UInt64
        let nice: UInt64

        func usage(since old: Self) -> Double? {
            let userDelta = user &- old.user
            let systemDelta = system &- old.system
            let niceDelta = nice &- old.nice
            let busy = userDelta + systemDelta + niceDelta
            let idleDelta = idle &- old.idle
            let total = busy + idleDelta
            guard total > 0 else { return nil }
            return min(100, max(0, Double(busy) / Double(total) * 100))
        }
    }

    private static func readCPUTicks() -> CPUTicks? {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return CPUTicks(
            user: UInt64(info.cpu_ticks.0),
            system: UInt64(info.cpu_ticks.1),
            idle: UInt64(info.cpu_ticks.2),
            nice: UInt64(info.cpu_ticks.3)
        )
    }

    private static func readStorage() -> (used: Int64, total: Int64)? {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        guard let values = try? home.resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey
        ]),
        let totalValue = values.volumeTotalCapacity,
        totalValue > 0 else { return nil }

        let total = Int64(totalValue)
        // APFS can reclaim purgeable space. Monitoring apps use the capacity
        // available for important usage so their "used" percentage matches
        // what a user can actually allocate, rather than treating all
        // reclaimable cache as permanently occupied.
        let available = values.volumeAvailableCapacityForImportantUsage
            ?? values.volumeAvailableCapacity.map(Int64.init)
        guard let available else { return nil }
        return (max(0, total - min(total, available)), total)
    }

}

/// Apple does not publish a CPU-die temperature API. Apple Silicon monitoring
/// apps such as Stats and SwiftTempBar enumerate the read-only HID temperature
/// services instead. Symbols are loaded dynamically so a future macOS change
/// degrades to an unavailable value without preventing CloudCodex from opening.
enum AppleSiliconTemperatureReader {
    struct Reading: Equatable {
        let value: Double
        let source: String
    }

    private struct Sensor {
        let name: String
        let value: Double
    }

    static func readChipTemperature() -> Reading? {
        selectChipTemperature(readSensors().map { (name: $0.name, value: $0.value) })
    }

    static func selectChipTemperature(_ values: [(name: String, value: Double)]) -> Reading? {
        values
            .filter { (0..<110).contains($0.value) }
            .compactMap { sensor -> Reading? in
                if isCPUSensor(sensor.name) {
                    return Reading(value: sensor.value, source: "cpu_hid")
                }
                if isSoCSensor(sensor.name) {
                    return Reading(value: sensor.value, source: "soc_hid")
                }
                return nil
            }
            .max(by: { $0.value < $1.value })
    }

    static func isCPUSensor(_ name: String) -> Bool {
        name.hasPrefix("PMU tdie")
            || name.hasPrefix("PMU tdev")
            || name.hasPrefix("pACC MTR Temp")
            || name.hasPrefix("eACC MTR Temp")
            || name.localizedCaseInsensitiveContains("CPU")
    }

    static func isSoCSensor(_ name: String) -> Bool {
        name.hasPrefix("PMGR SOC Die Temp")
            || name.hasPrefix("SOC MTR Temp")
            || name.localizedCaseInsensitiveContains("SoC")
    }

    private static func readSensors() -> [Sensor] {
        guard let context,
              let copyProperty = HIDAPI.copyProperty,
              let copyEvent = HIDAPI.copyEvent,
              let getFloatValue = HIDAPI.getFloatValue else { return [] }

        let eventType: Int64 = 15
        let valueField = Int32(eventType << 16)
        var result: [Sensor] = []
        for index in 0..<CFArrayGetCount(context.services) {
            guard let service = CFArrayGetValueAtIndex(context.services, index) else { continue }
            let pointer = UnsafeMutableRawPointer(mutating: service)
            guard let property = copyProperty(pointer, "Product" as CFString),
                  let name = property.takeRetainedValue() as? String,
                  let event = copyEvent(pointer, eventType, 0, 0) else { continue }
            let value = getFloatValue(event, valueField)
            release(event)
            result.append(.init(name: name, value: value))
        }
        return result
    }

    /// Keep the HID client and matched service list for the monitor lifetime.
    /// Recreating both on every one-second poll is needlessly expensive.
    private static let context: HIDContext? = {
        guard let create = HIDAPI.create,
              let setMatching = HIDAPI.setMatching,
              let copyServices = HIDAPI.copyServices,
              let client = create(kCFAllocatorDefault) else { return nil }

        var usagePage: Int32 = 0xff00
        var usage: Int32 = 5
        guard let usagePageNumber = CFNumberCreate(kCFAllocatorDefault, .sInt32Type, &usagePage),
              let usageNumber = CFNumberCreate(kCFAllocatorDefault, .sInt32Type, &usage) else {
            release(client)
            return nil
        }
        let matching = [
            "PrimaryUsagePage" as CFString: usagePageNumber,
            "PrimaryUsage" as CFString: usageNumber
        ] as CFDictionary
        _ = setMatching(client, matching)
        guard let services = copyServices(client)?.takeRetainedValue() else {
            release(client)
            return nil
        }
        return HIDContext(client: client, services: services)
    }()

    private final class HIDContext {
        let client: UnsafeMutableRawPointer
        let services: CFArray

        init(client: UnsafeMutableRawPointer, services: CFArray) {
            self.client = client
            self.services = services
        }

        deinit { AppleSiliconTemperatureReader.release(client) }
    }

    private static func release(_ pointer: UnsafeMutableRawPointer) {
        Unmanaged<CFTypeRef>.fromOpaque(pointer).release()
    }

    private enum HIDAPI {
        typealias Create = @convention(c) (CFAllocator?) -> UnsafeMutableRawPointer?
        typealias SetMatching = @convention(c) (UnsafeMutableRawPointer, CFDictionary) -> Int32
        typealias CopyServices = @convention(c) (UnsafeMutableRawPointer) -> Unmanaged<CFArray>?
        typealias CopyProperty = @convention(c) (UnsafeMutableRawPointer, CFString) -> Unmanaged<AnyObject>?
        typealias CopyEvent = @convention(c) (UnsafeMutableRawPointer, Int64, Int32, Int64) -> UnsafeMutableRawPointer?
        typealias GetFloatValue = @convention(c) (UnsafeMutableRawPointer, Int32) -> Double

        private static let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)
        static let create: Create? = load("IOHIDEventSystemClientCreate")
        static let setMatching: SetMatching? = load("IOHIDEventSystemClientSetMatching")
        static let copyServices: CopyServices? = load("IOHIDEventSystemClientCopyServices")
        static let copyProperty: CopyProperty? = load("IOHIDServiceClientCopyProperty")
        static let copyEvent: CopyEvent? = load("IOHIDServiceClientCopyEvent")
        static let getFloatValue: GetFloatValue? = load("IOHIDEventGetFloatValue")

        private static func load<T>(_ name: String) -> T? {
            guard let handle, let symbol = dlsym(handle, name) else { return nil }
            return unsafeBitCast(symbol, to: T.self)
        }
    }
}
