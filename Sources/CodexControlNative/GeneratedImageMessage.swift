import Foundation

enum GeneratedImageMessage {
    static func fromItem(_ item: [String: Any]) -> ChatMessage? {
        guard item["type"] as? String == "imageGeneration",
              item["status"] as? String == "completed",
              let id = item["id"] as? String,
              let path = item["savedPath"] as? String, path.hasPrefix("/"),
              !path.contains("\n"), !path.contains(">") else { return nil }
        return ChatMessage(id: id + "-generated-image", role: .assistant,
                           text: "![生成的图片](<\(path)>)")
    }
}
