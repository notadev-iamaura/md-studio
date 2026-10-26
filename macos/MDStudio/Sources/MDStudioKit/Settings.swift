// 앱 설정. 기본값은 웹 버전(src/main.js의 DEFAULT_SETTINGS)과 같다.
// UserDefaults에 JSON 한 덩어리로 저장한다. 모르는 값이나 빠진 값은 기본값으로 채운다.
// 의존성: Foundation, MDCore(표 변환 방식)
import Foundation
import MDCore

public enum ViewMode: String, Codable, CaseIterable, Sendable {
    case edit, split, preview

    /// 보기 전환(⌘\) 순서: 편집 → 분할 → 보기
    public var next: ViewMode {
        switch self {
        case .edit: return .split
        case .split: return .preview
        case .preview: return .edit
        }
    }
}

public enum PreviewTab: String, Codable, CaseIterable, Sendable {
    case doc, slack, plain
}

public enum EditorFont: String, Codable, CaseIterable, Sendable {
    case sans, mono
}

public enum ThemeSetting: String, Codable, CaseIterable, Sendable {
    case system, light, dark
}

public struct AppSettings: Codable, Equatable, Sendable {
    public var tableMode: String = MDOptions.TableMode.title.rawValue
    public var breaks = true
    public var pasteConvert = true
    public var autosave = true
    public var syncScroll = true
    public var lineWrap = true
    public var editorFont: EditorFont = .sans
    public var editorFontSize = 15
    public var theme: ThemeSetting = .system
    public var view: ViewMode = .split
    public var sidebar = true
    public var previewTab: PreviewTab = .doc
    /// 지난 폴더(절대 경로)
    public var lastFolder: String?
    /// 지난 폴더 안에서 마지막으로 연 파일(폴더 기준 상대 경로)
    public var lastFile: String?
    public var welcomed = false
    /// 확대·축소 배율 (⌘+ / ⌘-)
    public var zoom = 1.0

    public init() {}

    /// 변환 옵션
    public var renderOptions: MDOptions {
        MDOptions(tableMode: MDOptions.TableMode(rawValue: tableMode) ?? .title, breaks: breaks)
    }

    // 하나라도 빠지거나 모르는 값이 있으면 그 항목만 기본값으로 둔다(나머지 설정은 살린다).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        tableMode = (try? c.decodeIfPresent(String.self, forKey: .tableMode)).flatMap { $0 } ?? d.tableMode
        if MDOptions.TableMode(rawValue: tableMode) == nil { tableMode = d.tableMode }
        breaks = (try? c.decodeIfPresent(Bool.self, forKey: .breaks)).flatMap { $0 } ?? d.breaks
        pasteConvert = (try? c.decodeIfPresent(Bool.self, forKey: .pasteConvert)).flatMap { $0 } ?? d.pasteConvert
        autosave = (try? c.decodeIfPresent(Bool.self, forKey: .autosave)).flatMap { $0 } ?? d.autosave
        syncScroll = (try? c.decodeIfPresent(Bool.self, forKey: .syncScroll)).flatMap { $0 } ?? d.syncScroll
        lineWrap = (try? c.decodeIfPresent(Bool.self, forKey: .lineWrap)).flatMap { $0 } ?? d.lineWrap
        editorFont = (try? c.decodeIfPresent(EditorFont.self, forKey: .editorFont)).flatMap { $0 } ?? d.editorFont
        editorFontSize = (try? c.decodeIfPresent(Int.self, forKey: .editorFontSize)).flatMap { $0 } ?? d.editorFontSize
        theme = (try? c.decodeIfPresent(ThemeSetting.self, forKey: .theme)).flatMap { $0 } ?? d.theme
        view = (try? c.decodeIfPresent(ViewMode.self, forKey: .view)).flatMap { $0 } ?? d.view
        sidebar = (try? c.decodeIfPresent(Bool.self, forKey: .sidebar)).flatMap { $0 } ?? d.sidebar
        previewTab = (try? c.decodeIfPresent(PreviewTab.self, forKey: .previewTab)).flatMap { $0 } ?? d.previewTab
        lastFolder = (try? c.decodeIfPresent(String.self, forKey: .lastFolder)).flatMap { $0 }
        lastFile = (try? c.decodeIfPresent(String.self, forKey: .lastFile)).flatMap { $0 }
        welcomed = (try? c.decodeIfPresent(Bool.self, forKey: .welcomed)).flatMap { $0 } ?? d.welcomed
        zoom = (try? c.decodeIfPresent(Double.self, forKey: .zoom)).flatMap { $0 } ?? d.zoom
        editorFontSize = min(max(editorFontSize, 10), 32)
        zoom = min(max(zoom, 0.6), 2.0)
    }
}

/// 설정 읽기·쓰기
public final class SettingsStore {
    private let defaults: UserDefaults
    private let key = "md-studio.settings"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> AppSettings {
        guard let data = defaults.data(forKey: key) else { return AppSettings() }
        do {
            return try JSONDecoder().decode(AppSettings.self, from: data)
        } catch {
            appLog.error("설정", "설정을 읽지 못해 기본값을 씁니다", error)
            return AppSettings()
        }
    }

    public func save(_ settings: AppSettings) {
        do {
            defaults.set(try JSONEncoder().encode(settings), forKey: key)
        } catch {
            appLog.error("설정", "설정 저장 실패", error)
        }
    }
}
