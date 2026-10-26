// MDCore의 공개 입구. 마크다운을 텍스트 복사용 글자와 Slack용 HTML로 바꾼다.
// - toPlainText: 텍스트 복사 (제목 ■□, 목록 •◦▪, 표는 목록 또는 고정폭 표로 풀기)
// - toSlackHtml: Slack 복사 (Slack이 살리는 태그만 사용)
// - extractTitle: 첫 제목 (파일 이름·보고서 제목 후보)
// 규칙의 기준은 src/convert.js와 test/fixtures/golden.json이다.
// 의존성: Foundation, os (로그)
import Foundation
import os

/// 변환 옵션. 기본값은 웹 버전의 DEFAULT_OPTIONS와 같다.
public struct MDOptions: Equatable, Sendable {
    /// 표를 바꾸는 방식
    public enum TableMode: String, CaseIterable, Sendable {
        /// 제목형: 첫 칸이 굵은 항목, 나머지는 "머리글: 값" 하위 항목
        case title
        /// 한 줄형: "첫칸 — 머리글: 값 · 머리글: 값"
        case inline
        /// 고정폭 표: 열 너비를 맞춘 표
        case grid
    }

    public var tableMode: TableMode
    /// 문단 안의 엔터 한 번을 실제 줄바꿈으로 볼지 여부
    public var breaks: Bool

    public init(tableMode: TableMode = .title, breaks: Bool = true) {
        self.tableMode = tableMode
        self.breaks = breaks
    }
}

/// 로그 기록기. 문서 본문은 절대 기록하지 않고 길이와 걸린 시간만 남긴다.
enum MDLog {
    static let core = Logger(subsystem: "local.mdstudio.app", category: "MDCore")
    /// 이보다 오래 걸린 변환은 느린 변환으로 기록한다(밀리초).
    static let slowThresholdMs = 80.0

    static func measure<T>(_ kind: String, inputLength: Int, _ work: () -> T) -> T {
        let start = DispatchTime.now().uptimeNanoseconds
        let result = work()
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        if ms > slowThresholdMs {
            core.notice("느린 변환: \(kind, privacy: .public) 입력 \(inputLength)바이트, \(ms, format: .fixed(precision: 1))ms")
        } else {
            core.debug("변환: \(kind, privacy: .public) 입력 \(inputLength)바이트, \(ms, format: .fixed(precision: 1))ms")
        }
        return result
    }
}

public enum MDConverter {
    /// 마크다운을 텍스트 복사용 글자로 바꾼다. 결과 끝에는 항상 줄바꿈이 하나 붙는다.
    ///
    /// - Parameters:
    ///   - markdown: 마크다운 원문
    ///   - options: 표 변환 방식, 줄바꿈 옵션
    /// - Returns: 일반 텍스트
    public static func toPlainText(_ markdown: String, options: MDOptions = MDOptions()) -> String {
        MDLog.measure("plain", inputLength: markdown.utf8.count) {
            let renderer = PlainRenderer(options: options)
            let joined = renderer.blocks(MarkdownTree.parse(markdown))
            return PlainRenderer.finish(joined)
        }
    }

    /// 마크다운을 Slack 입력창에 붙여 넣을 HTML로 바꾼다.
    ///
    /// - Parameters:
    ///   - markdown: 마크다운 원문
    ///   - options: 표 변환 방식, 줄바꿈 옵션
    /// - Returns: b, i, s, code, pre, a, ul, ol, li, blockquote, p, br만 쓰는 HTML
    public static func toSlackHtml(_ markdown: String, options: MDOptions = MDOptions()) -> String {
        MDLog.measure("slack", inputLength: markdown.utf8.count) {
            SlackRenderer(options: options).document(MarkdownTree.parse(markdown))
        }
    }

    /// 첫 번째 제목의 글자를 돌려준다. 제목이 없으면 빈 문자열.
    ///
    /// - Parameter markdown: 마크다운 원문
    /// - Returns: 앞뒤 공백을 뗀 제목 글자
    public static func extractTitle(_ markdown: String) -> String {
        for block in MarkdownTree.parse(markdown) {
            if case .heading(_, let content) = block {
                return TextUtils.jsTrim(PlainRenderer.inlineText(content, inCell: false))
            }
        }
        return ""
    }

    /// 고정폭 글꼴에서 글자가 차지하는 칸 수(한글·한자·전각·이모지는 2칸).
    public static func textWidth(_ s: String) -> Int {
        TextUtils.textWidth(s)
    }
}
