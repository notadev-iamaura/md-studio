// 변환에 쓰는 글자 처리 도구 모음.
// - HTML 엔티티 풀기/이스케이프, 태그 제거, 위험한 링크 차단, 고정폭 글자 너비 계산
// - 모두 src/convert.js의 같은 이름 함수를 그대로 옮겼다. 정규식도 원본과 같다.
// 의존성: Foundation (NSRegularExpression)
import Foundation

/// 정규식 하나를 미리 만들어 두는 작은 도우미.
/// 패턴은 코드에 고정된 상수라서, 만들기에 실패하면 프로그램 오류이므로 즉시 멈춘다.
struct Pattern {
    let regex: NSRegularExpression

    init(_ pattern: String, _ options: NSRegularExpression.Options = []) {
        do {
            regex = try NSRegularExpression(pattern: pattern, options: options)
        } catch {
            preconditionFailure("MDCore 정규식 오류: \(pattern) — \(error)")
        }
    }

    /// 일치하는 부분을 모두 찾아 바꾼다. transform은 (전체 일치, 캡처 그룹들)을 받아 바꿀 글자를 돌려준다.
    func replace(_ s: String, _ transform: (String, [String?]) -> String) -> String {
        let ns = s as NSString
        let matches = regex.matches(in: s, range: NSRange(location: 0, length: ns.length))
        if matches.isEmpty { return s }
        var out = ""
        var last = 0
        for m in matches {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let groups: [String?] = (0..<m.numberOfRanges).dropFirst().map { i in
                let r = m.range(at: i)
                return r.location == NSNotFound ? nil : ns.substring(with: r)
            }
            out += transform(ns.substring(with: m.range), groups)
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }

    /// 일치하는 부분을 모두 고정된 글자로 바꾼다.
    func replace(_ s: String, with template: String) -> String {
        replace(s) { _, _ in template }
    }

    func matches(_ s: String) -> Bool {
        regex.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
    }
}

enum TextUtils {
    // 원본(convert.js)이 직접 풀어 주는 이름 엔티티는 이것뿐이다. nbsp는 일반 공백으로 바꾼다.
    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "#39": "'",
    ]
    private static let entityPattern = Pattern("&(#x[0-9a-f]+|#\\d+|[a-z]+\\d*|#39);", .caseInsensitive)
    private static let unescapedAmp = Pattern("&(?!(#x[0-9a-f]+|#\\d+|[a-z]+\\d*);)", .caseInsensitive)
    private static let brTag = Pattern("<br\\s*/?>", .caseInsensitive)
    private static let anyTag = Pattern("<[^>]*>")
    private static let brOnly = Pattern("^<br\\s*/?>$", .caseInsensitive)
    private static let dangerousScheme = Pattern("^(javascript|vbscript|data):", .caseInsensitive)
    private static let whitespace = Pattern("\\s+")

    /// `&amp;` `&#39;` `&#x41;` 같은 엔티티를 문자로 푼다. 모르는 이름은 그대로 둔다.
    static func decodeEntities(_ s: String) -> String {
        entityPattern.replace(s) { whole, groups in
            guard let code = groups.first ?? nil else { return whole }
            let lower = code.lowercased()
            if lower.hasPrefix("#") {
                let isHex = lower.dropFirst().first == "x"
                let digits = isHex ? String(lower.dropFirst(2)) : String(lower.dropFirst())
                guard let n = UInt32(digits, radix: isHex ? 16 : 10), n > 0, n <= 0x10FFFF,
                      let scalar = Unicode.Scalar(n) else { return whole }
                return String(Character(scalar))
            }
            return namedEntities[lower] ?? whole
        }
    }

    /// HTML 특수문자를 이스케이프한다. 이미 엔티티로 쓰인 부분(`&amp;` 등)은 다시 이스케이프하지 않는다.
    static func escapeHtml(_ s: String) -> String {
        unescapedAmp.replace(s, with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// 속성 값용 이스케이프. 작은따옴표까지 바꾼다.
    static func escapeAttr(_ s: String) -> String {
        escapeHtml(s).replacingOccurrences(of: "'", with: "&#39;")
    }

    /// 분석기가 이미 엔티티를 풀어 준 일반 글자를 이스케이프한다.
    /// marked는 원문(`&amp;`)을 그대로 주지만 swift-markdown은 풀린 글자(`&`)를 준다.
    /// 풀린 글자 안의 `&`는 모두 진짜 `&`이므로 예외 없이 `&amp;`로 바꿔야 원본과 같은 화면이 된다.
    static func escapeDecodedText(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// HTML 태그를 지우고 글자만 남긴다. `<br>`은 줄바꿈으로 바꾼다.
    static func stripTags(_ html: String) -> String {
        decodeEntities(anyTag.replace(brTag.replace(html, with: "\n"), with: ""))
    }

    /// `<br>` 하나뿐인 HTML인지 확인한다.
    static func isBrHtml(_ raw: String) -> Bool {
        brOnly.matches(jsTrim(raw))
    }

    /// 안전하지 않은 링크(javascript: 등)는 빈 주소로 바꾼다.
    static func safeHref(_ href: String?) -> String {
        let h = jsTrim(href ?? "")
        if dangerousScheme.matches(whitespace.replace(h, with: "")) { return "" }
        return h
    }

    /// 고정폭 글꼴에서 차지하는 칸 수. 한글·한자·전각·이모지는 2칸, 폭 없는 문자는 0칸.
    static func textWidth(_ s: String) -> Int {
        var w = 0
        for scalar in s.unicodeScalars {
            let c = scalar.value
            if c == 0x200B || (0x300...0x36F).contains(c) { continue }
            let wide =
                (0x1100...0x115F).contains(c) ||
                (0x2E80...0xA4CF).contains(c) ||
                (0xAC00...0xD7A3).contains(c) ||
                (0xF900...0xFAFF).contains(c) ||
                (0xFE30...0xFE4F).contains(c) ||
                (0xFF00...0xFF60).contains(c) ||
                (0xFFE0...0xFFE6).contains(c) ||
                (0x1F300...0x1FAFF).contains(c)
            w += wide ? 2 : 1
        }
        return w
    }

    /// 오른쪽을 공백으로 채워 지정한 칸 수에 맞춘다.
    static func padEnd(_ s: String, _ width: Int) -> String {
        s + String(repeating: " ", count: max(0, width - textWidth(s)))
    }

    /// JavaScript `String.prototype.trim()`과 같은 앞뒤 공백 제거.
    static func jsTrim(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// JavaScript `trimEnd()`와 같은 뒤쪽 공백 제거.
    static func jsTrimEnd(_ s: String) -> String {
        var scalars = Substring(s).unicodeScalars
        while let last = scalars.last, CharacterSet.whitespacesAndNewlines.contains(last) {
            scalars.removeLast()
        }
        return String(scalars)
    }
}
