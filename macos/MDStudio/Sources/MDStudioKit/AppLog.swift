// 앱 로그: 파일(~/Library/Logs/MD Studio/app.log)과 메모리(로그 창)에 함께 남긴다.
// - 기록하는 것: 시작, 폴더·파일 열기, 저장(파일 이름·바이트), 복사(종류·글자 수·선택 여부), 내보내기, 외부 변경, 오류, 느린 렌더링
// - 기록하지 않는 것: 문서 본문
// - 파일이 1MB를 넘으면 app.log.old로 돌리고 새로 쓴다.
// - debug 단계는 메모리(로그 창의 "상세 로그")에만 남기고 파일에는 쓰지 않는다.
// 의존성: Foundation, os
import Foundation
import os

public enum LogLevel: String, Comparable, CaseIterable, Sendable {
    case debug, info, warn, error

    private var rank: Int {
        switch self {
        case .debug: return 0
        case .info: return 1
        case .warn: return 2
        case .error: return 3
        }
    }

    public static func < (a: LogLevel, b: LogLevel) -> Bool { a.rank < b.rank }
}

/// 로그 한 줄
public struct LogEntry: Equatable, Sendable {
    public let time: Date
    public let level: LogLevel
    public let scope: String
    public let message: String
    /// 덧붙이는 정보(파일 이름, 길이 등). 문서 본문은 넣지 않는다.
    public let data: [String: String]

    /// "[22:40:01.123] INFO [저장] 메시지 key=value" 형식
    public var formatted: String {
        let extra = data.keys.sorted().map { "\($0)=\(data[$0] ?? "")" }.joined(separator: " ")
        return "[\(LogEntry.clock.string(from: time))] \(level.rawValue.uppercased()) [\(scope)] \(message)\(extra.isEmpty ? "" : " " + extra)"
    }

    static let clock: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
    static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()
}

/// 로그 저장소. 여러 곳에서 동시에 불러도 안전하도록 잠금을 쓴다.
public final class AppLog: @unchecked Sendable {
    /// 자가 점검(MDSTUDIO_SELFTEST) 중에는 사용자 로그와 섞이지 않게 결과 폴더의 logs에 쓴다.
    public static let shared: AppLog = {
        if let out = ProcessInfo.processInfo.environment["MDSTUDIO_SELFTEST"], !out.isEmpty {
            return AppLog(directory: URL(fileURLWithPath: out, isDirectory: true).appendingPathComponent("logs", isDirectory: true))
        }
        return AppLog()
    }()

    /// 로그 파일 위치
    public let fileURL: URL
    private let maxEntries = 1000
    private let maxFileBytes = 1024 * 1024
    private let lock = NSLock()
    private var entries: [LogEntry] = []
    private var listeners: [UUID: (LogEntry) -> Void] = [:]
    private let osLog = Logger(subsystem: "local.mdstudio.app", category: "app")
    private var fileHandle: FileHandle?

    public init(directory: URL? = nil) {
        let dir = directory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/MD Studio", isDirectory: true)
        fileURL = dir.appendingPathComponent("app.log")
    }

    /// 로그 폴더
    public var directoryURL: URL { fileURL.deletingLastPathComponent() }

    public func debug(_ scope: String, _ message: String, _ data: [String: String] = [:]) { write(.debug, scope, message, data) }
    public func info(_ scope: String, _ message: String, _ data: [String: String] = [:]) { write(.info, scope, message, data) }
    public func warn(_ scope: String, _ message: String, _ data: [String: String] = [:]) { write(.warn, scope, message, data) }

    /// 오류 기록. 오류 객체가 있으면 원인을 함께 남긴다.
    public func error(_ scope: String, _ message: String, _ error: Error? = nil, _ data: [String: String] = [:]) {
        var d = data
        if let error {
            let ns = error as NSError
            d["error"] = "\(ns.domain)(\(ns.code)): \(ns.localizedDescription)"
        }
        write(.error, scope, message, d)
    }

    /// 걸린 시간을 재서 기록한다. 기준(밀리초)을 넘으면 느린 작업으로 info에 남긴다.
    @discardableResult
    public func time<T>(_ scope: String, _ label: String, slowMs: Double = 80, _ data: [String: String] = [:], _ work: () throws -> T) rethrows -> T {
        let start = DispatchTime.now().uptimeNanoseconds
        let result = try work()
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        var d = data
        d["ms"] = String(format: "%.1f", ms)
        if ms > slowMs {
            write(.info, scope, "\(label)이(가) 느립니다", d)
        } else {
            write(.debug, scope, "\(label) 완료", d)
        }
        return result
    }

    private func write(_ level: LogLevel, _ scope: String, _ message: String, _ data: [String: String]) {
        let entry = LogEntry(time: Date(), level: level, scope: scope, message: message, data: data)
        lock.lock()
        entries.append(entry)
        if entries.count > maxEntries { entries.removeFirst(entries.count - maxEntries) }
        let currentListeners = Array(listeners.values)
        if level >= .info { appendToFile(entry) }
        lock.unlock()

        switch level {
        case .debug: osLog.debug("\(entry.formatted, privacy: .public)")
        case .info: osLog.info("\(entry.formatted, privacy: .public)")
        case .warn: osLog.warning("\(entry.formatted, privacy: .public)")
        case .error: osLog.error("\(entry.formatted, privacy: .public)")
        }
        for listener in currentListeners { listener(entry) }
    }

    /// 파일에 한 줄 추가. 실패해도 앱을 멈추지 않되, 시스템 로그에는 남긴다. (잠금 안에서 부른다)
    private func appendToFile(_ entry: LogEntry) {
        do {
            if fileHandle == nil {
                try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
                rotateIfNeeded()
                if !FileManager.default.fileExists(atPath: fileURL.path) {
                    FileManager.default.createFile(atPath: fileURL.path, contents: nil)
                }
                fileHandle = try FileHandle(forWritingTo: fileURL)
                try fileHandle?.seekToEnd()
            }
            let extra = entry.data.keys.sorted().map { "\($0)=\(entry.data[$0] ?? "")" }.joined(separator: " ")
            let line = "[\(LogEntry.stamp.string(from: entry.time))] \(entry.level.rawValue.uppercased()) [\(entry.scope)] \(entry.message)\(extra.isEmpty ? "" : " " + extra)\n"
            try fileHandle?.write(contentsOf: Data(line.utf8))
            if let size = try fileHandle?.offset(), size > UInt64(maxFileBytes) {
                try fileHandle?.close()
                fileHandle = nil
            }
        } catch {
            osLog.error("로그 파일 쓰기 실패: \(error.localizedDescription, privacy: .public)")
            try? fileHandle?.close()
            fileHandle = nil
        }
    }

    private func rotateIfNeeded() {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: fileURL.path),
              let size = attrs[.size] as? NSNumber, size.intValue > maxFileBytes else { return }
        let old = fileURL.appendingPathExtension("old")
        do {
            if fm.fileExists(atPath: old.path) { try fm.removeItem(at: old) }
            try fm.moveItem(at: fileURL, to: old)
        } catch {
            osLog.error("로그 파일 돌리기 실패: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - 로그 창용

    public func allEntries() -> [LogEntry] {
        lock.lock(); defer { lock.unlock() }
        return entries
    }

    public func clearEntries() {
        lock.lock(); entries.removeAll(); lock.unlock()
    }

    /// 새 로그가 생길 때마다 불린다. 돌려받은 값으로 해제한다.
    @discardableResult
    public func addListener(_ fn: @escaping (LogEntry) -> Void) -> UUID {
        let id = UUID()
        lock.lock(); listeners[id] = fn; lock.unlock()
        return id
    }

    public func removeListener(_ id: UUID) {
        lock.lock(); listeners[id] = nil; lock.unlock()
    }

    /// 열린 파일을 닫는다(테스트·종료 시).
    public func flush() {
        lock.lock(); defer { lock.unlock() }
        try? fileHandle?.synchronize()
    }
}

/// 앱 전체에서 쓰는 로거
public let appLog = AppLog.shared
