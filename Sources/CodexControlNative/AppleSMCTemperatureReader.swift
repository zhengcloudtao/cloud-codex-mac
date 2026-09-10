import Darwin
import Foundation
import IOKit

/// Read-only AppleSMC access for Apple Silicon CPU temperature sensors.
/// CloudCodex never writes SMC keys or changes thermal/fan policy.
enum AppleSMCTemperatureReader {
    struct Reading: Equatable {
        let value: Double
        let sensorCount: Int
    }

    static func readCPUAverage() -> Reading? {
        guard let reader = SMCReader.shared else { return nil }
        let values = cpuSensorKeys
            .compactMap(reader.temperature)
            .filter { (20..<110).contains($0) }
        guard !values.isEmpty else { return nil }
        return Reading(value: values.reduce(0, +) / Double(values.count), sensorCount: values.count)
    }

    static func isAppleSiliconCPUKey(_ key: String) -> Bool {
        // Apple Silicon core keys use a lowercase domain letter. Uppercase
        // Intel-era keys and GPU (Tg), storage (Ts), battery (TB) or board
        // sensors are intentionally excluded.
        key.hasPrefix("Tc") || key.hasPrefix("Te") || key.hasPrefix("Tf") || key.hasPrefix("Tp")
    }

    private static let cpuSensorKeys: [String] = {
        let brand = cpuBrand
        if brand.contains("M1") {
            return ["Tc0a", "Tc0b", "Tc0x", "Tc0z", "Tc7a", "Tc7b", "Tc7x", "Tc7z",
                    "Tc8a", "Tc8b", "Tc9a", "Tc9b", "Tc9x", "Tc9z",
                    "Tp09", "Tp0T", "Tp01", "Tp05", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0X", "Tp0b"]
        }
        if brand.contains("M2") {
            return ["Tp1h", "Tp1t", "Tp1p", "Tp1l", "Tp01", "Tp05", "Tp09", "Tp0D",
                    "Tp0X", "Tp0b", "Tp0f", "Tp0j"]
        }
        if brand.contains("M3") {
            return ["Te05", "Te0L", "Te0P", "Te0S", "Tf04", "Tf09", "Tf0A", "Tf0B",
                    "Tf0D", "Tf0E", "Tf44", "Tf49", "Tf4A", "Tf4B", "Tf4D", "Tf4E"]
        }
        if brand.contains("M4") {
            return ["Te05", "Te09", "Te0H", "Te0S", "Tp01", "Tp05", "Tp09", "Tp0D",
                    "Tp0V", "Tp0Y", "Tp0b", "Tp0e"]
        }
        if brand.contains("M5") {
            return ["Te04", "Te08", "Te0C", "Te0R", "Tp00", "Tp04", "Tp0C", "Tp0G",
                    "Tp0O", "Tp0R", "Tp0X", "Tp0a", "Tp0p", "Tp0u", "Tp0y"]
        }
        return []
    }()

    private static let cpuBrand: String = {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 1 else { return "" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0) == 0 else { return "" }
        return String(cString: buffer)
    }()

    private final class SMCReader {
        static let shared = SMCReader()

        private typealias Bytes32 = (
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
        )

        private struct Version {
            var major: UInt8 = 0
            var minor: UInt8 = 0
            var build: UInt8 = 0
            var reserved: UInt8 = 0
            var release: UInt16 = 0
        }

        private struct PowerLimit {
            var version: UInt16 = 0
            var length: UInt16 = 0
            var cpu: UInt32 = 0
            var gpu: UInt32 = 0
            var memory: UInt32 = 0
        }

        private struct KeyInfo {
            var dataSize: UInt32 = 0
            var dataType: UInt32 = 0
            var attributes: UInt8 = 0
        }

        private struct Parameters {
            var key: UInt32 = 0
            var version = Version()
            var powerLimit = PowerLimit()
            var keyInfo = KeyInfo()
            // Match the three bytes of C-ABI tail padding in SMCKeyInfoData.
            var keyInfoPadding: (UInt8, UInt8, UInt8) = (0, 0, 0)
            var result: UInt8 = 0
            var status: UInt8 = 0
            var command: UInt8 = 0
            var data32: UInt32 = 0
            var bytes: Bytes32 = (
                0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 0
            )
        }

        private struct CachedInfo {
            let size: UInt32
            let type: UInt32
        }

        private let connection: io_connect_t
        private var keyInfoCache: [String: CachedInfo] = [:]
        private var missingKeys: Set<String> = []

        private init?() {
            guard MemoryLayout<Parameters>.stride == 80 else {
                Self.debug("unexpected parameter size \(MemoryLayout<Parameters>.stride)")
                return nil
            }
            let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
            guard service != 0 else {
                Self.debug("AppleSMC service unavailable")
                return nil
            }
            defer { IOObjectRelease(service) }
            var connection: io_connect_t = 0
            let status = IOServiceOpen(service, mach_task_self_, 0, &connection)
            guard status == KERN_SUCCESS else {
                Self.debug("AppleSMC open failed: \(status)")
                return nil
            }
            self.connection = connection
            Self.debug("AppleSMC connection opened")
        }

        deinit { IOServiceClose(connection) }

        func temperature(_ key: String) -> Double? {
            guard let info = keyInfo(for: key), info.size >= 2, info.size <= 32 else { return nil }
            var input = Parameters()
            input.key = Self.fourCharacterCode(key)
            input.keyInfo.dataSize = info.size
            input.command = 5 // read key
            guard let output = call(input), output.result == 0 else { return nil }
            let bytes = Self.bytes(output.bytes, count: Int(info.size))
            switch Self.string(info.type) {
            case "flt ":
                guard bytes.count >= 4 else { return nil }
                let bits = UInt32(bytes[0])
                    | UInt32(bytes[1]) << 8
                    | UInt32(bytes[2]) << 16
                    | UInt32(bytes[3]) << 24
                return Double(Float(bitPattern: bits))
            case "sp78":
                let bits = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
                return Double(Int16(bitPattern: bits)) / 256
            default:
                return nil
            }
        }

        private func keyInfo(for key: String) -> CachedInfo? {
            if let cached = keyInfoCache[key] { return cached }
            guard !missingKeys.contains(key) else { return nil }
            var input = Parameters()
            input.key = Self.fourCharacterCode(key)
            input.command = 9 // key information
            guard let output = call(input), output.result == 0, output.keyInfo.dataSize > 0 else {
                Self.debug("key info unavailable: \(key)")
                missingKeys.insert(key)
                return nil
            }
            let info = CachedInfo(size: output.keyInfo.dataSize, type: output.keyInfo.dataType)
            keyInfoCache[key] = info
            return info
        }

        private func call(_ input: Parameters) -> Parameters? {
            var input = input
            var output = Parameters()
            var outputSize = MemoryLayout<Parameters>.stride
            let result = IOConnectCallStructMethod(
                connection,
                2,
                &input,
                MemoryLayout<Parameters>.stride,
                &output,
                &outputSize
            )
            if result != KERN_SUCCESS {
                Self.debug("AppleSMC call failed: \(result)")
            }
            return result == KERN_SUCCESS ? output : nil
        }

        private static func debug(_ message: String) {
            guard ProcessInfo.processInfo.environment["CLOUDCODEX_VERIFY_LIVE_TEMPERATURE"] == "1" else { return }
            print("CloudCodex AppleSMC: \(message)")
        }

        private static func bytes(_ value: Bytes32, count: Int) -> [UInt8] {
            withUnsafeBytes(of: value) { Array($0.prefix(min(32, max(0, count)))) }
        }

        private static func fourCharacterCode(_ value: String) -> UInt32 {
            value.utf8.prefix(4).reduce(0) { ($0 << 8) | UInt32($1) }
        }

        private static func string(_ value: UInt32) -> String {
            String(bytes: [
                UInt8((value >> 24) & 0xff),
                UInt8((value >> 16) & 0xff),
                UInt8((value >> 8) & 0xff),
                UInt8(value & 0xff)
            ], encoding: .ascii) ?? ""
        }
    }
}
