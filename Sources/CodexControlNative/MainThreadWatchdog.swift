import Foundation
import OSLog

/// Accessed only on the watchdog queue. There is at most one queued heartbeat
/// and one diagnostic per stall, even if the UI never comes back.
struct MainThreadHeartbeat {
    private(set) var sentAt: TimeInterval?
    private var reported = false

    mutating func send(at time: TimeInterval) -> Bool {
        guard sentAt == nil else { return false }
        sentAt = time
        reported = false
        return true
    }

    mutating func shouldReport(at time: TimeInterval) -> Bool {
        guard let sentAt, time - sentAt >= 3, !reported else { return false }
        reported = true
        return true
    }

    mutating func acknowledge() { sentAt = nil }
}

/// Captures native stacks locally while a stall is still happening. No request
/// bodies, subprocess stderr, credentials or conversation text are logged.
final class MainThreadWatchdog: @unchecked Sendable {
    static let shared = MainThreadWatchdog()
    private let queue = DispatchQueue(label: "cloudcodex.ui-watchdog", qos: .utility)
    private let logger = Logger(subsystem: "com.zhengyuntao.cloudcodex", category: "responsiveness")
    private var timer: DispatchSourceTimer?
    private var heartbeat = MainThreadHeartbeat()
    private var captures = 0
    private var sampler: Process?

    func start() {
        queue.async { [self] in
            guard timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 1, repeating: 1)
            timer.setEventHandler { [weak self] in self?.tick() }
            self.timer = timer
            logger.notice("UI watchdog started; native stack capture after 3 seconds without a main-thread heartbeat")
            timer.resume()
        }
    }

    private func tick() {
        // System uptime avoids false reports when the wall clock changes.
        let now = ProcessInfo.processInfo.systemUptime
        if heartbeat.shouldReport(at: now) {
            logger.error("Main thread heartbeat delayed at least 3 seconds")
            captureStack()
        }
        if heartbeat.send(at: now) {
            DispatchQueue.main.async { [weak self] in
                self?.queue.async { [weak self] in self?.heartbeat.acknowledge() }
            }
        }
    }

    private func captureStack() {
        // Bound disk use and avoid an accumulating queue of sample processes.
        guard captures < 3, sampler?.isRunning != true else { return }
        do {
            let directory = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/CloudCodex", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            captures += 1
            let output = directory.appendingPathComponent("ui-hang-\(captures).sample.txt")
            try Data().write(to: output, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
            process.arguments = [String(ProcessInfo.processInfo.processIdentifier), "2", "10", "-file", output.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            sampler = process
        } catch {
            logger.error("Unable to start local native stack capture")
        }
    }
}
