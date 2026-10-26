// 맥 파일 시스템 읽기·쓰기 (src/storage.js, electron/main.cjs와 같은 규칙).
// - 폴더 목록: 하위 4단계까지 .md .markdown .mdown .mkd .txt, 숨김 파일과 node_modules .git .obsidian .Trash 제외,
//   최대 2000개, 한글 이름 순 정렬
// - 안전한 쓰기: 같은 폴더의 `.파일명.mdstudio-tmp`에 먼저 쓴 뒤 rename으로 바꿔치기한다.
//   저장 도중 앱이 꺼져도 원본이 반쯤 지워지지 않는다.
// - 새 파일 이름: 같은 이름이 있으면 "이름 2.md"처럼 번호를 붙인다(덮어쓰기 금지).
// 의존성: Foundation
import Foundation

/// 폴더 안의 마크다운 파일 하나
public struct FileEntry: Equatable, Sendable {
    /// 폴더 기준 상대 경로 (예: "하위/메모.md")
    public let path: String
    /// 파일 이름
    public let name: String
    public let url: URL

    /// 목록에 보여 줄 이름(확장자 .md는 뺀다)
    public var displayName: String {
        name.lowercased().hasSuffix(".md") ? String(name.dropLast(3)) : name
    }

    /// 들어 있는 하위 폴더 (최상위면 빈 문자열)
    public var directory: String {
        let dir = String(path.dropLast(name.count))
        return dir.hasSuffix("/") ? String(dir.dropLast()) : dir
    }
}

/// 파일 작업 오류. 사용자에게 보여 줄 한국어 설명을 담는다.
public struct FileStoreError: LocalizedError, Equatable {
    public let message: String
    public var errorDescription: String? { message }
}

public enum FileStore {
    public static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "txt"]
    static let skipDirs: Set<String> = ["node_modules", ".git", ".obsidian", ".trash", ".Trash"]
    public static let maxDepth = 4
    public static let maxFiles = 2000

    /// 마크다운(또는 텍스트) 파일인지 확장자로 판단한다.
    public static func isMarkdown(_ url: URL) -> Bool {
        markdownExtensions.contains(url.pathExtension.lowercased())
    }

    /// 이름 비교·검색용 정규화. 맥 파일 시스템은 이름을 NFD로 돌려줄 때가 있어 NFC로 맞춘다.
    public static func normalized(_ s: String) -> String {
        s.precomposedStringWithCanonicalMapping
    }

    // MARK: - 폴더 목록

    /// 폴더 안의 마크다운 파일 목록을 만든다.
    ///
    /// - Parameter folder: 사용자가 고른 폴더
    /// - Returns: 파일 목록과, 2000개를 넘어 잘렸는지 여부
    /// - Throws: 폴더를 읽을 수 없을 때
    public static func listMarkdownFiles(in folder: URL) throws -> (entries: [FileEntry], truncated: Bool) {
        var out: [FileEntry] = []
        var truncated = false
        let fm = FileManager.default

        func walk(_ dir: URL, prefix: String, depth: Int, isRoot: Bool) throws {
            let items: [URL]
            do {
                items = try fm.contentsOfDirectory(
                    at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [])
            } catch {
                // 최상위 폴더를 못 읽으면 오류, 하위 폴더 하나를 못 읽으면 기록하고 건너뛴다.
                if isRoot { throw error }
                appLog.warn("폴더", "하위 폴더를 읽지 못해 건너뜁니다", ["folder": dir.lastPathComponent, "error": error.localizedDescription])
                return
            }
            for item in items {
                if out.count >= maxFiles { truncated = true; return }
                let name = normalized(item.lastPathComponent)
                if name.hasPrefix(".") { continue }
                let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values?.isDirectory == true {
                    // 심볼릭 링크 폴더는 따라가지 않는다(무한 반복 방지).
                    if values?.isSymbolicLink == true { continue }
                    if depth < maxDepth && !skipDirs.contains(name) {
                        try walk(item, prefix: "\(prefix)\(name)/", depth: depth + 1, isRoot: false)
                    }
                } else if isMarkdown(item) {
                    out.append(FileEntry(path: "\(prefix)\(name)", name: name, url: item))
                }
            }
        }

        try walk(folder, prefix: "", depth: 0, isRoot: true)
        let korean = Locale(identifier: "ko")
        out.sort { $0.path.compare($1.path, options: [], range: nil, locale: korean) == .orderedAscending }
        if truncated { appLog.warn("폴더", "파일이 너무 많아 처음 \(maxFiles)개만 표시합니다") }
        return (out, truncated)
    }

    // MARK: - 읽기·쓰기

    /// 파일을 글자로 읽는다. UTF-8이 아니면 깨진 글자를 대체 문자로 바꿔 읽고 기록한다.
    public static func read(_ url: URL) throws -> (text: String, modified: Date) {
        let data = try Data(contentsOf: url)
        let text: String
        if let s = String(data: data, encoding: .utf8) {
            text = s
        } else {
            appLog.warn("파일", "UTF-8이 아닌 파일이라 일부 글자가 깨질 수 있습니다", ["file": url.lastPathComponent])
            text = String(decoding: data, as: UTF8.self)
        }
        // 맨 앞의 BOM은 편집에 방해되므로 뗀다.
        let clean = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        return (clean, try modificationDate(url))
    }

    public static func modificationDate(_ url: URL) throws -> Date {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let date = attrs[.modificationDate] as? Date else {
            throw FileStoreError(message: "파일의 수정 시각을 알 수 없습니다")
        }
        return date
    }

    /// 안전하게 쓴다: 임시 파일에 먼저 쓰고 rename으로 바꿔치기한다.
    ///
    /// - Parameters:
    ///   - text: 저장할 글
    ///   - url: 저장할 파일
    /// - Returns: 저장 후 파일의 수정 시각
    /// - Throws: 쓰기·바꿔치기에 실패하면. 임시 파일은 지운다.
    @discardableResult
    public static func writeSafely(_ text: String, to url: URL) throws -> Date {
        let dir = url.deletingLastPathComponent()
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).mdstudio-tmp")
        let data = Data(text.utf8)
        do {
            try data.write(to: tmp, options: [])
            // rename(2)은 같은 폴더 안에서 원자적으로 바꿔치기한다.
            if Darwin.rename(tmp.path, url.path) != 0 {
                let code = errno
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(code),
                              userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(code))])
            }
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
        let modified = try modificationDate(url)
        appLog.info("저장", "파일 저장", ["file": url.lastPathComponent, "bytes": "\(data.count)"])
        return modified
    }

    /// 폴더에 새 파일을 만든다. 같은 이름이 있으면 번호를 붙인다.
    ///
    /// - Returns: 만든 파일 위치
    public static func createFile(in folder: URL, name: String, text: String = "") throws -> URL {
        let url = uniqueURL(in: folder, name: name)
        try writeSafely(text, to: url)
        appLog.info("파일", "새 파일 만들기", ["file": url.lastPathComponent])
        return url
    }

    /// 같은 이름이 있으면 "이름 2.md", "이름 3.md"…를 고른다.
    public static func uniqueURL(in folder: URL, name: String) -> URL {
        let ns = name as NSString
        let ext = ns.pathExtension.isEmpty ? "md" : ns.pathExtension
        let base = ns.pathExtension.isEmpty ? name : ns.deletingPathExtension
        var candidate = folder.appendingPathComponent("\(base).\(ext)")
        var i = 2
        while FileManager.default.fileExists(atPath: candidate.path) && i < 1000 {
            candidate = folder.appendingPathComponent("\(base) \(i).\(ext)")
            i += 1
        }
        return candidate
    }

    /// 파일 이름으로 쓸 수 없는 글자를 지우고 확장자를 붙인다(src/main.js cleanFileName).
    public static func cleanFileName(_ name: String, ext: String = "md") -> String {
        let illegal = CharacterSet(charactersIn: "\\/:*?\"<>|").union(.controlCharacters)
        var n = String(String.UnicodeScalarView(name.unicodeScalars.filter { !illegal.contains($0) }))
        n = n.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        n = String(n.prefix(80)).trimmingCharacters(in: .whitespaces)
        if n.isEmpty { n = "새 문서" }
        // 점으로 시작하면 숨김 파일이 되므로 앞의 점을 뗀다.
        while n.hasPrefix(".") { n.removeFirst() }
        if n.isEmpty { n = "새 문서" }
        let lower = n.lowercased()
        switch ext {
        case "md":
            if !markdownExtensions.contains((lower as NSString).pathExtension) { n += ".md" }
        case "html":
            if !(lower.hasSuffix(".html") || lower.hasSuffix(".htm")) { n += ".html" }
        default:
            if !lower.hasSuffix(".\(ext)") { n += ".\(ext)" }
        }
        return n
    }
}

// MARK: - 임시본

/// 저장하지 않은 내용의 임시 보관본
public struct Draft: Codable, Equatable {
    public let key: String
    public let text: String
    /// 보관한 시각
    public let at: Date
}

/// 임시본 저장소: ~/Library/Application Support/MD Studio/drafts/ 에 문서마다 파일 하나로 보관한다.
public final class DraftStore {
    public let directory: URL

    public init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MD Studio/drafts", isDirectory: true)
    }

    /// 키(“untitled”, “file:/경로”)를 파일 이름으로 바꾼다. 경로를 그대로 쓰지 않도록 해시를 쓴다.
    func fileURL(for key: String) -> URL {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325 // FNV-1a 64비트
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return directory.appendingPathComponent(String(format: "%016llx.json", hash))
    }

    public func save(_ text: String, for key: String, at date: Date = Date()) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(Draft(key: key, text: text, at: date))
            try data.write(to: fileURL(for: key), options: .atomic)
            appLog.debug("임시본", "임시본 보관", ["chars": "\(text.count)"])
        } catch {
            appLog.error("임시본", "임시본 보관 실패", error)
        }
    }

    public func load(_ key: String) -> Draft? {
        let url = fileURL(for: key)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let draft = try JSONDecoder().decode(Draft.self, from: Data(contentsOf: url))
            // 해시가 겹친 다른 문서의 임시본이면 쓰지 않는다.
            return draft.key == key ? draft : nil
        } catch {
            appLog.error("임시본", "임시본을 읽지 못했습니다", error)
            return nil
        }
    }

    public func clear(_ key: String) {
        let url = fileURL(for: key)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            appLog.error("임시본", "임시본 지우기 실패", error)
        }
    }
}
