import Foundation

/// Retries only failures that mean the selected model is temporarily unable
/// to accept work. Permission, validation, usage-limit, and task errors must
/// remain terminal instead of entering an accidental infinite loop.
enum CapacityRetryPolicy {
    static func isRetryable(error: [String: Any]?) -> Bool {
        guard let error else { return false }
        if let info = error["codexErrorInfo"] as? String,
           normalized(info) == "serveroverloaded" {
            return true
        }
        let message = error["message"] as? String ?? ""
        return message.localizedCaseInsensitiveContains("selected model is at capacity")
            || message.localizedCaseInsensitiveContains("server overloaded; retry later")
    }

    /// Exponential backoff with bounded jitter. The retry count is one-based.
    /// Retries never stop, but the delay is capped so recovery is eventually
    /// noticed without aggressively polling a busy service.
    static func delay(attempt: Int, jitter: Double = Double.random(in: 0...1)) -> TimeInterval {
        let exponent = min(max(attempt - 1, 0), 5)
        let base = min(300.0, 10.0 * pow(2.0, Double(exponent)))
        let boundedJitter = min(max(jitter, 0), 1)
        return min(300.0, base * (0.85 + boundedJitter * 0.30))
    }

    private static func normalized(_ value: String) -> String {
        value.lowercased().filter(\.isLetter)
    }
}
