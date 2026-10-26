// 화면 색과 글꼴. 웹 버전 src/styles.css의 색 변수(밝게/어둡게)를 그대로 옮겼다.
// 색은 시스템 모양(밝게/어둡게)이 바뀌면 저절로 따라 바뀐다(동적 색).
// PDF·RTF처럼 종이에 맞춰야 하는 곳은 Palette.light를 쓴다.
// 의존성: AppKit
import AppKit

/// 색 묶음 하나 (밝게 또는 어둡게)
public struct Palette {
    public var bg, fg, muted, line, soft, panel, hover, accent, accentFg, accentSoft, danger: NSColor
    public var codeBg, codeFg, syntax, activeLine, selection, searchMatch: NSColor
    /// 표의 짝수 행 배경
    public var stripe: NSColor
    /// Slack 미리보기 링크·코드 색
    public var slackLink, slackCode: NSColor

    static func hex(_ v: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
                blue: CGFloat(v & 0xff) / 255, alpha: alpha)
    }

    public static let light = Palette(
        bg: hex(0xffffff), fg: hex(0x1f2328), muted: hex(0x656d76), line: hex(0xd8dee4), soft: hex(0xf6f8fa),
        panel: hex(0xf7f8fa), hover: hex(0xeef1f4), accent: hex(0x1f6feb), accentFg: hex(0xffffff),
        accentSoft: hex(0xe8f0fe), danger: hex(0xcf222e), codeBg: hex(0xeff1f3), codeFg: hex(0x953800),
        syntax: hex(0x8c959f), activeLine: NSColor(srgbRed: 31 / 255, green: 111 / 255, blue: 235 / 255, alpha: 0.04),
        selection: NSColor(srgbRed: 31 / 255, green: 111 / 255, blue: 235 / 255, alpha: 0.22),
        searchMatch: NSColor(srgbRed: 1, green: 196 / 255, blue: 0, alpha: 0.4),
        stripe: hex(0xfafbfc), slackLink: hex(0x1264a3), slackCode: hex(0xe01e5a))

    public static let dark = Palette(
        bg: hex(0x0f1216), fg: hex(0xe6edf3), muted: hex(0x8d96a0), line: hex(0x2d333b), soft: hex(0x161b22),
        panel: hex(0x13171c), hover: hex(0x1f252d), accent: hex(0x4c8dff), accentFg: hex(0x0b0e12),
        accentSoft: hex(0x15233b), danger: hex(0xff6b6b), codeBg: hex(0x1d232b), codeFg: hex(0xffa657),
        syntax: hex(0x6e7681), activeLine: NSColor(srgbRed: 76 / 255, green: 141 / 255, blue: 1, alpha: 0.06),
        selection: NSColor(srgbRed: 76 / 255, green: 141 / 255, blue: 1, alpha: 0.3),
        searchMatch: NSColor(srgbRed: 1, green: 196 / 255, blue: 0, alpha: 0.3),
        stripe: hex(0x13181e), slackLink: hex(0x4c9fe8), slackCode: hex(0xe8678e))
}

/// 모양(밝게/어둡게)에 따라 바뀌는 색
public enum Theme {
    private static func dynamic(_ name: String, _ pick: @escaping (Palette) -> NSColor) -> NSColor {
        NSColor(name: NSColor.Name("md." + name)) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return pick(isDark ? Palette.dark : Palette.light)
        }
    }

    public static let bg = dynamic("bg") { $0.bg }
    public static let fg = dynamic("fg") { $0.fg }
    public static let muted = dynamic("muted") { $0.muted }
    public static let line = dynamic("line") { $0.line }
    public static let soft = dynamic("soft") { $0.soft }
    public static let panel = dynamic("panel") { $0.panel }
    public static let hover = dynamic("hover") { $0.hover }
    public static let accent = dynamic("accent") { $0.accent }
    public static let accentFg = dynamic("accentFg") { $0.accentFg }
    public static let accentSoft = dynamic("accentSoft") { $0.accentSoft }
    public static let danger = dynamic("danger") { $0.danger }
    public static let codeBg = dynamic("codeBg") { $0.codeBg }
    public static let codeFg = dynamic("codeFg") { $0.codeFg }
    public static let syntax = dynamic("syntax") { $0.syntax }
    public static let activeLine = dynamic("activeLine") { $0.activeLine }
    public static let selection = dynamic("selection") { $0.selection }
    public static let stripe = dynamic("stripe") { $0.stripe }
    public static let slackLink = dynamic("slackLink") { $0.slackLink }
    public static let slackCode = dynamic("slackCode") { $0.slackCode }

    /// 화면에 쓰는 동적 색 묶음 (미리보기 렌더러가 받는 형식)
    public static var dynamicPalette: Palette {
        Palette(bg: bg, fg: fg, muted: muted, line: line, soft: soft, panel: panel, hover: hover, accent: accent,
                accentFg: accentFg, accentSoft: accentSoft, danger: danger, codeBg: codeBg, codeFg: codeFg,
                syntax: syntax, activeLine: activeLine, selection: selection, searchMatch: Palette.light.searchMatch,
                stripe: stripe, slackLink: slackLink, slackCode: slackCode)
    }

    // MARK: - 글꼴

    /// 본문 글꼴 (시스템 글꼴: 한글은 Apple SD Gothic Neo로 자동 대체)
    public static func ui(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: weight)
    }

    /// 고정폭 글꼴 (SF Mono)
    public static func mono(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    }

    /// 기울임. 한글 글꼴에는 기울임 모양이 없어서, 기울임 글꼴이 없으면 글자를 비스듬히 그린다.
    public static func italicAttributes(for font: NSFont) -> [NSAttributedString.Key: Any] {
        let italic = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        if italic.fontDescriptor.symbolicTraits.contains(.italic) {
            return [.font: italic, .obliqueness: 0.12]
        }
        return [.font: font, .obliqueness: 0.18]
    }

    public static func bold(_ font: NSFont) -> NSFont {
        NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
    }
}
