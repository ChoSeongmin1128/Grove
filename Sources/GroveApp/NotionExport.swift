import AppKit
import CryptoKit
import Foundation
import Security

enum NotionPageLink {
    static func id(from input: String) throws -> String {
        let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let path: String
        if UUID(uuidString: input) != nil { return input.lowercased() }
        if input.count == 32 && input.allSatisfy(\.isHexDigit) { path = input }
        else {
            guard let url = URL(string: input), url.scheme == "https", let host = url.host?.lowercased(),
                  host == "notion.so" || host.hasSuffix(".notion.so") || host == "notion.site" || host.hasSuffix(".notion.site"),
                  url.user == nil, url.password == nil else { throw NotionExportError.invalidLink }
            path = url.lastPathComponent
        }
        guard let match = path.range(of: #"[0-9a-fA-F]{32}$|[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"#, options: .regularExpression) else {
            throw NotionExportError.invalidLink
        }
        let hex = String(path[match]).replacingOccurrences(of: "-", with: "").lowercased()
        let chars = Array(hex)
        return [String(chars[0..<8]), String(chars[8..<12]), String(chars[12..<16]), String(chars[16..<20]), String(chars[20..<32])].joined(separator: "-")
    }
    static func url(for id: String) -> URL { URL(string: "https://www.notion.so/" + id.replacingOccurrences(of: "-", with: ""))! }
}

enum MeetingExportContent {
    static func title(_ meeting: MeetingRecord) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return "\(formatter.string(from: meeting.startedAt)) \(meeting.title)"
    }
    static func markdown(meeting: MeetingRecord, document: TranscriptDocument, original: Bool) -> String {
        let options = TranscriptExportOptions(format: .markdown, usesOriginalText: original)
        return "# \(TranscriptRenderer.escapeMarkdown(title(meeting)))\n\n"
            + (original ? "최초 전사문" : "검토한 전사문") + "\n\n"
            + TranscriptRenderer.render(document, options: options)
    }
    static func html(meeting: MeetingRecord, document: TranscriptDocument, original: Bool) -> String {
        let document = TranscriptRenderer.exportDocument(document, original: original)
        let body = document.utterances.sorted { $0.startTime < $1.startTime }.map { utterance in
            let heading = "[\(TranscriptRenderer.timestamp(utterance.startTime))] \(document.speakerName(for: utterance))"
            return "<p><b>\(escapeHTML(heading))</b><br>\(escapeHTML(original ? utterance.rawText : utterance.displayedText))</p>"
        }.joined()
        return "<html><head><meta charset=\"utf-8\"></head><body><h1>\(escapeHTML(title(meeting)))</h1>\(body)</body></html>"
    }
    static func copy(meeting: MeetingRecord, document: TranscriptDocument, original: Bool) -> Bool {
        let item = NSPasteboardItem()
        item.setString(markdown(meeting: meeting, document: document, original: original), forType: .string)
        item.setString(html(meeting: meeting, document: document, original: original), forType: .html)
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.writeObjects([item])
    }
    private static func escapeHTML(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "\n", with: "<br>")
    }
}

struct NotionTokenStore {
    private let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "io.github.ChoSeongmin1128.Grove.Notion", kSecAttrAccount as String: "connection"]
    func read() throws -> String? {
        var values = query
        values[kSecReturnData as String] = true
        values[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(values as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let token = String(data: data, encoding: .utf8) else {
            throw NotionExportError.keychain
        }
        return token
    }
    func save(_ token: String) throws {
        let cleaned = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, !cleaned.contains(where: \.isWhitespace) else { throw NotionExportError.missingToken }
        let data = Data(cleaned.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var values = query
            values[kSecValueData as String] = data
            values[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(values as CFDictionary, nil) == errSecSuccess else { throw NotionExportError.keychain }
        } else if status != errSecSuccess { throw NotionExportError.keychain }
    }
    func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw NotionExportError.keychain }
    }
}

@MainActor
struct NotionClient {
    let token: String
    var session: URLSession = .shared
    func parentTitle(id: String) async throws -> String {
        let page = try await request("pages/\(id)")
        guard page["object"] as? String == "page", page["in_trash"] as? Bool != true, page["archived"] as? Bool != true else {
            throw NotionExportError.invalidParent
        }
        let properties = page["properties"] as? [String: [String: Any]] ?? [:]
        return properties.values.compactMap { $0["title"] as? [[String: Any]] }.first?.compactMap { $0["plain_text"] as? String }.joined() ?? "Notion 페이지"
    }
    func create(parent: String, title: String, markdown: String) async throws -> String {
        let page = try await request("pages", method: "POST", body: ["parent": ["page_id": parent],
            "properties": ["title": ["title": [["text": ["content": title]]]]], "markdown": markdown])
        guard let id = page["id"] as? String, UUID(uuidString: id) != nil else { throw NotionExportError.unknownResult }
        return id
    }
    func ensureDividerAtEnd(parent: String) async throws {
        let page = try await request("pages/\(parent)/markdown")
        guard page["truncated"] as? Bool != true, let markdown = page["markdown"] as? String else {
            throw NotionExportError.invalidParent
        }
        if markdown.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").last == "---" { return }
        do {
            _ = try await request("pages/\(parent)/markdown", method: "PATCH",
                body: ["type": "insert_content", "insert_content": ["content": "\n---\n", "position": ["type": "end"]]])
        } catch { throw NotionExportError.dividerFailed }
    }
    func verifyChild(id: String, parent: String) async throws {
        let page = try await request("pages/\(id)")
        let actual = (page["parent"] as? [String: Any])?["page_id"] as? String
        guard actual?.replacingOccurrences(of: "-", with: "").lowercased() == parent.replacingOccurrences(of: "-", with: "").lowercased(),
              page["in_trash"] as? Bool != true else { throw NotionExportError.invalidParent }
    }
    private func request(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://api.notion.com/v1/\(path)")!)
        request.httpMethod = method
        request.timeoutInterval = 60
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("2026-03-11", forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try body.map { try JSONSerialization.data(withJSONObject: $0) }
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { if method == "POST" { throw NotionExportError.unknownResult }; throw error }
        guard let http = response as? HTTPURLResponse else { throw NotionExportError.unknownResult }
        guard (200..<300).contains(http.statusCode) else {
            if method == "POST", http.statusCode >= 500 { throw NotionExportError.unknownResult }
            throw NotionExportError.http(http.statusCode)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw NotionExportError.unknownResult }
        return object
    }
}

struct NotionExportReceipt: Codable {
    let meetingID: UUID
    let parentID: String
    let contentHash: String
    var pageID: String?
    var verified = false
}

@MainActor
final class NotionExporter: ObservableObject {
    @Published private(set) var isSaving = false
    @Published private(set) var message: String?
    let directory: URL
    init(directory: URL) { self.directory = directory }
    func receipt(meetingID: UUID) throws -> NotionExportReceipt? {
        let url = directory.appendingPathComponent(meetingID.uuidString + ".json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(NotionExportReceipt.self, from: Data(contentsOf: url))
    }
    func save(meeting: MeetingRecord, document: TranscriptDocument, parentLink: String, original: Bool,
              client: NotionClient) async throws -> URL {
        guard !isSaving else { throw NotionExportError.busy }
        isSaving = true
        defer { isSaving = false }
        let parent = try NotionPageLink.id(from: parentLink)
        let markdown = MeetingExportContent.markdown(meeting: meeting, document: document, original: original)
        let hash = SHA256.hash(data: Data(markdown.utf8)).map { String(format: "%02x", $0) }.joined()
        _ = try await client.parentTitle(id: parent)
        if let previous = try receipt(meetingID: meeting.id) {
            guard previous.parentID == parent, previous.contentHash == hash else { throw NotionExportError.changedExport }
            guard let page = previous.pageID else { throw NotionExportError.unknownResult }
            try await client.verifyChild(id: page, parent: parent)
            return NotionPageLink.url(for: page)
        }
        try await client.ensureDividerAtEnd(parent: parent)
        var receipt = NotionExportReceipt(meetingID: meeting.id, parentID: parent, contentHash: hash)
        try persist(receipt)
        let id: String
        do { id = try await client.create(parent: parent, title: MeetingExportContent.title(meeting), markdown: markdown) }
        catch {
            if case NotionExportError.http = error {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(meeting.id.uuidString + ".json"))
            }
            throw error
        }
        receipt.pageID = id
        try persist(receipt)
        try await client.verifyChild(id: id, parent: parent)
        receipt.verified = true
        try persist(receipt)
        return NotionPageLink.url(for: id)
    }
    func connectCreatedPage(meetingID: UUID, link: String, client: NotionClient) async throws -> URL {
        guard !isSaving, var receipt = try receipt(meetingID: meetingID), receipt.pageID == nil else { throw NotionExportError.invalidParent }
        isSaving = true
        defer { isSaving = false }
        let page = try NotionPageLink.id(from: link)
        try await client.verifyChild(id: page, parent: receipt.parentID)
        receipt.pageID = page
        receipt.verified = true
        try persist(receipt)
        return NotionPageLink.url(for: page)
    }
    private func persist(_ receipt: NotionExportReceipt) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(receipt).write(to: directory.appendingPathComponent(receipt.meetingID.uuidString + ".json"), options: .atomic)
    }
}

enum NotionExportError: Error, LocalizedError {
    case invalidLink, invalidParent, missingToken, keychain, unknownResult, changedExport, busy, dividerFailed, http(Int)
    var errorDescription: String? {
        switch self {
        case .invalidLink: "Notion 페이지 링크를 입력해 주세요. 데이터베이스 링크는 지원하지 않습니다."
        case .invalidParent: "저장할 일반 페이지와 접근 권한을 확인해 주세요."
        case .missingToken: "설정의 Notion 화면에서 연결 토큰을 저장해 주세요."
        case .keychain: "Notion 연결 정보를 Keychain에서 읽거나 저장하지 못했습니다."
        case .unknownResult: "저장 결과를 확인하지 못했습니다. 중복 생성을 막기 위해 다시 만들지 않습니다. Notion에서 생성된 페이지를 확인하고 아래에 링크를 연결해 주세요."
        case .changedExport: "이 녹음의 회의록은 이미 추가되었습니다. 추가된 회의록을 열거나 새 내용을 복사해 붙여넣어 주세요."
        case .busy: "다른 회의록을 저장하고 있습니다."
        case .dividerFailed: "구분선 추가 결과를 확인하지 못했습니다. 다시 적용하면 페이지 하단을 확인한 뒤 이어서 처리합니다."
        case .http(let status): switch status {
            case 401: "Notion 연결 토큰을 확인해 주세요."
            case 403, 404: "이 페이지에 접근할 수 없습니다. Notion 페이지의 연결 설정과 쓰기 권한을 확인해 주세요."
            case 429: "Notion 요청이 잠시 제한되었습니다. 잠시 후 다시 시도해 주세요."
            default: "Notion 저장 요청에 실패했습니다 (\(status)). 원문은 Grove에 보존됩니다."
            }
        }
    }
}
