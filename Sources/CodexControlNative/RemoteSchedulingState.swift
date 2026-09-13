import Foundation

/// Remote scheduling has its own global snapshot. Sidebar selection must never
/// change the set of conversations reported to the relay.
struct RemoteSchedulingState {
    private var threads: [CodexThread] = []
    private var updatedAt: Date?
    private var busyThreads: [String: (snapshot: RemoteThreadSnapshot, until: Date)] = [:]

    mutating func replace(with threads: [CodexThread], now: Date = Date()) {
        self.threads = threads
        updatedAt = now
        busyThreads = busyThreads.filter { $0.value.until > now }
    }

    mutating func deferBusyThread(_ task: RemoteTask, now: Date = Date()) {
        guard !task.threadId.isEmpty else { return }
        let known = threads.first { $0.id == task.threadId }
        busyThreads[task.threadId] = (
            RemoteThreadSnapshot(id: task.threadId, title: known?.displayName ?? "正在执行的会话",
                                 workspace: task.workspace, model: known?.model ?? task.model, status: "active",
                                 updatedAt: now.timeIntervalSince1970),
            now.addingTimeInterval(30)
        )
    }

    func snapshots(allowedPaths: Set<String>, locallyRunning: [CodexThread] = [], now: Date = Date()) -> [RemoteThreadSnapshot] {
        // A failed read is not proof of an active turn. Expire stale status,
        // keeping recent history available; the claim path rechecks the writer.
        let fresh = updatedAt.map { now.timeIntervalSince($0) < 30 } ?? false
        var result: [RemoteThreadSnapshot] = []
        var seen = Set<String>()
        func append(_ snapshot: RemoteThreadSnapshot) {
            guard allowedPaths.contains(snapshot.workspace), seen.insert(snapshot.id).inserted else { return }
            result.append(snapshot)
        }
        for thread in locallyRunning {
            append(RemoteThreadSnapshot(id: thread.id, title: thread.displayName,
                                       workspace: thread.cwd, model: thread.model ?? "", status: "active",
                                       updatedAt: thread.updatedAt.timeIntervalSince1970))
        }
        for id in busyThreads.keys.sorted() {
            if let busy = busyThreads[id], busy.until > now { append(busy.snapshot) }
        }
        for thread in threads {
            append(RemoteThreadSnapshot(id: thread.id, title: thread.displayName,
                                       workspace: thread.cwd, model: thread.model ?? "",
                                       status: fresh ? thread.status : "unknown",
                                       updatedAt: thread.updatedAt.timeIntervalSince1970))
        }
        return Array(result.prefix(300))
    }
}

struct RemoteQueueSummary: Codable, Equatable {
    let queuedCount: Int
    let blockedCount: Int

    var waitingDescription: String? {
        guard queuedCount > 0 else { return nil }
        let blocked = min(max(blockedCount, 0), queuedCount)
        if blocked == queuedCount { return "\(queuedCount) 条任务排队中，等待会话空闲或释放" }
        if blocked > 0 { return "\(queuedCount) 条任务排队中，\(blocked) 条等待会话空闲；其余继续领取" }
        return "\(queuedCount) 条任务等待领取，正在调度"
    }
}
