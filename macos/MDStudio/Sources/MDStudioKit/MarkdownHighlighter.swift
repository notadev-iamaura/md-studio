// 편집기 마크다운 문법 색칠 규칙 (src/editor.js의 mdHighlight와 같은 모양).
// - 제목은 크게·굵게, 굵게/기울임/취소선, 링크 글자는 강조색, 주소는 흐린 밑줄, 인라인 코드는 고정폭,
//   인용은 흐리게, `#` `-` `**` 같은 기호는 흐린 색
// - 화면과 분리해서 "어느 범위에 어떤 모양"만 계산한다(테스트 가능). 실제 글꼴·색 적용은 편집기가 한다.
// 의존성: Foundation
import Foundation

public enum HighlightStyle: Equatable, Hashable {
    case heading(Int)
    case strong
    case emphasis
    case strike
    /// 링크 글자 [이것]
    case link
    /// 주소 (https://…)
    case url
    /// 인라인 코드와 코드 블록 내용
    case code
    case quote
    /// 마크다운 기호 (#, -, **, `, >, [, ] 등)
    case syntax
}

public struct HighlightSpan: Equatable {
    public var range: NSRange
    public var style: HighlightStyle
}

public enum MarkdownHighlighter {
    private static func re(_ p: String) -> NSRegularExpression {
        do { return try NSRegularExpression(pattern: p) } catch { preconditionFailure("색칠 정규식 오류: \(p)") }
    }

    private static let fence = re("^ {0,3}(```|~~~)")
    private static let heading = re("^ {0,3}(#{1,6})(?:[ \\t]+|$)")
    private static let quote = re("^ {0,3}((?:>[ \\t]?)+)")
    private static let listMarker = re("^([ \\t]*)([-*+]|\\d+[.)])([ \\t]+)(\\[[ xX]\\][ \\t]+)?")
    private static let hrLine = re("^ {0,3}([-*_])(?:[ \\t]*\\1){2,}[ \\t]*$")
    private static let setext = re("^ {0,3}(=+|-+)[ \\t]*$")
    private static let codeSpan = re("(`+)(.+?)\\1")
    private static let strong = re("(\\*\\*|__)(?=\\S)(.+?)(?<=\\S)\\1")
    private static let emphasis = re("(?<![*\\w])(\\*|_)(?=[^\\s*_])(.+?)(?<=[^\\s*_])\\1(?![*\\w])")
    private static let strike = re("(~~?)(?=\\S)(.+?)(?<=\\S)\\1")
    private static let link = re("(!?\\[)([^\\]\\n]*)(\\]\\()([^)\\s]*)((?:\\s+\"[^\"]*\")?\\))")
    private static let autolink = re("<(?:https?://|mailto:)[^>\\s]+>")
    private static let bareURL = re("(?<![(<\\w])(?:https?://|www\\.)[^\\s<>()]+[^\\s<>().,:;!?'\"]")
    private static let tablePipe = re("\\|")

    /// 글 전체의 색칠 범위를 계산한다.
    public static func spans(for text: String) -> [HighlightSpan] {
        let ns = text as NSString
        var out: [HighlightSpan] = []
        var inFence = false
        var lineStart = 0
        while lineStart <= ns.length {
            var start = 0, end = 0, contentsEnd = 0
            ns.getLineStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: lineStart, length: 0))
            let line = NSRange(location: start, length: contentsEnd - start)
            let lineText = ns.substring(with: line)
            highlightLine(lineText, offset: start, inFence: &inFence, into: &out)
            if end <= lineStart || end >= ns.length { break }
            lineStart = end
        }
        return out
    }

    private static func highlightLine(_ line: String, offset: Int, inFence: inout Bool, into out: inout [HighlightSpan]) {
        let ns = line as NSString
        let full = NSRange(location: 0, length: ns.length)
        func add(_ r: NSRange, _ s: HighlightStyle) {
            if r.location != NSNotFound && r.length > 0 {
                out.append(HighlightSpan(range: NSRange(location: r.location + offset, length: r.length), style: s))
            }
        }

        // 코드 울타리 (``` / ~~~)
        if fence.firstMatch(in: line, range: full) != nil {
            add(full, .syntax)
            inFence.toggle()
            return
        }
        if inFence {
            add(full, .code)
            return
        }
        // 들여쓴 코드(4칸)는 목록 안의 글과 헷갈리므로 색칠하지 않는다.

        if hrLine.firstMatch(in: line, range: full) != nil || setext.firstMatch(in: line, range: full) != nil {
            add(full, .syntax)
            return
        }

        var contentStart = 0
        var lineStyle: HighlightStyle?
        if let m = heading.firstMatch(in: line, range: full) {
            add(m.range(at: 1), .syntax)
            let level = m.range(at: 1).length
            contentStart = m.range.length
            lineStyle = .heading(level)
            add(NSRange(location: contentStart, length: ns.length - contentStart), .heading(level))
        } else {
            if let q = quote.firstMatch(in: line, range: full) {
                add(q.range(at: 1), .syntax)
                contentStart = q.range.length
                lineStyle = .quote
                add(NSRange(location: contentStart, length: ns.length - contentStart), .quote)
            }
            let rest = NSRange(location: contentStart, length: ns.length - contentStart)
            if let l = listMarker.firstMatch(in: line, range: rest) {
                add(l.range(at: 2), .syntax)
                add(l.range(at: 4), .syntax)
                contentStart = NSMaxRange(l.range)
            }
        }
        _ = lineStyle

        let body = NSRange(location: contentStart, length: ns.length - contentStart)
        highlightInline(line, body, add)

        // 표 줄의 | 는 흐리게
        if line.trimmingCharacters(in: .whitespaces).hasPrefix("|") {
            for m in tablePipe.matches(in: line, range: body) { add(m.range, .syntax) }
        }
    }

    /// 한 줄 안의 인라인 서식. 코드 안은 다른 서식을 칠하지 않는다.
    private static func highlightInline(_ line: String, _ range: NSRange, _ add: (NSRange, HighlightStyle) -> Void) {
        var blocked: [NSRange] = []
        func free(_ r: NSRange) -> Bool { !blocked.contains { NSIntersectionRange($0, r).length > 0 } }

        for m in codeSpan.matches(in: line, range: range) {
            add(m.range(at: 1), .syntax)
            add(m.range(at: 2), .code)
            add(NSRange(location: NSMaxRange(m.range) - m.range(at: 1).length, length: m.range(at: 1).length), .syntax)
            blocked.append(m.range)
        }
        for m in link.matches(in: line, range: range) where free(m.range) {
            add(m.range(at: 1), .syntax)
            add(m.range(at: 2), .link)
            add(m.range(at: 3), .syntax)
            add(m.range(at: 4), .url)
            add(m.range(at: 5), .syntax)
            blocked.append(NSRange(location: m.range(at: 3).location, length: NSMaxRange(m.range) - m.range(at: 3).location))
        }
        for m in autolink.matches(in: line, range: range) where free(m.range) {
            add(m.range, .url)
            blocked.append(m.range)
        }
        for m in bareURL.matches(in: line, range: range) where free(m.range) {
            add(m.range, .url)
            blocked.append(m.range)
        }
        for (pattern, style) in [(strong, HighlightStyle.strong), (strike, .strike), (emphasis, .emphasis)] {
            for m in pattern.matches(in: line, range: range) where free(m.range) {
                let mark = m.range(at: 1)
                add(mark, .syntax)
                add(m.range(at: 2), style)
                add(NSRange(location: NSMaxRange(m.range) - mark.length, length: mark.length), .syntax)
            }
        }
    }
}
