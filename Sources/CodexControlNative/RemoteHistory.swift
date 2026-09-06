import Foundation

struct RemoteHistoryRead: Decodable {
    let id: String
    let threadId: String
    let workspace: String
    let cursor: String
}
struct RemoteHistoryPage: Codable {
    var messages: [RemoteHistoryMessage]
    var nextCursor: String?
}
struct RemoteHistoryMessage: Codable {
    var id: String
    var role: String
    var text: String
    var title: String
    var timestamp: Double?
    var model: String
    var effort: String
    var attachments: [String]
}
struct RemoteHistoryResponse: Encodable {
    var page: RemoteHistoryPage?
    var error: String
}
