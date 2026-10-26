// 원본 src/output.js의 CSS와 인라인 스타일을 그대로 옮긴 상수. (node로 원본에서 뽑아 생성했다. 손으로 고치지 말 것)
// - reportCSS: HTML 보고서의 <style> 내용 (REPORT_CSS)
// - inlineStyles: 서식 복사에서 태그마다 직접 넣는 스타일 (INLINE_STYLES)
// - fontStack, monoStack: 글꼴 목록
// 의존성: 없음
enum WebStyles {
    static let fontStack = "-apple-system, BlinkMacSystemFont, 'Apple SD Gothic Neo', 'Malgun Gothic', 'Segoe UI', Arial, sans-serif"
    static let monoStack = "Menlo, Consolas, 'D2Coding', monospace"

    static let inlineStyles: [String: String] = [
        "h1": "font-size:24px;font-weight:700;margin:20px 0 10px;line-height:1.3;",
        "h2": "font-size:20px;font-weight:700;margin:18px 0 8px;line-height:1.3;",
        "h3": "font-size:17px;font-weight:700;margin:16px 0 6px;line-height:1.35;",
        "h4": "font-size:15px;font-weight:700;margin:14px 0 6px;",
        "h5": "font-size:14px;font-weight:700;margin:12px 0 4px;",
        "h6": "font-size:13px;font-weight:700;margin:12px 0 4px;color:#59636e;",
        "p": "margin:0 0 10px;line-height:1.6;",
        "ul": "margin:0 0 10px;padding-left:24px;",
        "ol": "margin:0 0 10px;padding-left:24px;",
        "li": "margin:2px 0;line-height:1.6;",
        "table": "border-collapse:collapse;margin:0 0 12px;",
        "th": "border:1px solid #d0d7de;padding:6px 10px;background:#f6f8fa;font-weight:700;",
        "td": "border:1px solid #d0d7de;padding:6px 10px;",
        "blockquote": "margin:0 0 10px;padding:2px 12px;border-left:4px solid #d0d7de;color:#59636e;",
        "pre": "margin:0 0 12px;padding:10px 12px;background:#f6f8fa;border-radius:6px;font-family:Menlo, Consolas, 'D2Coding', monospace;font-size:13px;line-height:1.5;white-space:pre-wrap;",
        "code": "font-family:Menlo, Consolas, 'D2Coding', monospace;font-size:90%;background:#eff1f3;padding:1px 4px;border-radius:4px;",
        "a": "color:#0969da;text-decoration:underline;",
        "hr": "border:none;border-top:1px solid #d0d7de;margin:16px 0;",
        "img": "max-width:100%;",
    ]

    static let reportCSS = #"""
:root{--fg:#1f2328;--muted:#59636e;--line:#d8dee4;--soft:#f6f8fa;--accent:#0b57d0}
*{box-sizing:border-box}
html{-webkit-text-size-adjust:100%}
body{margin:0;background:#eef1f4;color:var(--fg);font:16px/1.7 -apple-system, BlinkMacSystemFont, 'Apple SD Gothic Neo', 'Malgun Gothic', 'Segoe UI', Arial, sans-serif;word-break:keep-all;overflow-wrap:anywhere}
.page{max-width:860px;margin:32px auto;background:#fff;border-radius:12px;box-shadow:0 1px 3px rgba(0,0,0,.08),0 8px 24px rgba(0,0,0,.05);padding:56px 64px}
.report-header{border-bottom:2px solid var(--fg);padding-bottom:18px;margin-bottom:28px}
.report-header h1{font-size:30px;line-height:1.3;margin:0 0 8px;letter-spacing:-.01em}
.report-meta{color:var(--muted);font-size:14px}
.toc{background:var(--soft);border:1px solid var(--line);border-radius:8px;padding:16px 22px;margin:0 0 32px}
.toc-title{font-weight:700;font-size:14px;color:var(--muted);margin-bottom:6px}
.toc ol{margin:0;padding-left:20px}
.toc li{margin:2px 0}
.toc .lv3{margin-left:18px;list-style:circle}
.toc a{color:var(--fg);text-decoration:none}
.toc a:hover{color:var(--accent);text-decoration:underline}
.content h1,.content h2,.content h3,.content h4{line-height:1.35;margin:1.8em 0 .6em;scroll-margin-top:16px}
.content h1{font-size:26px}
.content h2{font-size:22px;padding-bottom:6px;border-bottom:1px solid var(--line)}
.content h3{font-size:18px}
.content h4{font-size:16px}
.content > :first-child{margin-top:0}
.content p{margin:0 0 1em}
.content ul,.content ol{padding-left:1.6em;margin:0 0 1em}
.content li{margin:.2em 0}
.content li:has(> input[type=checkbox]){list-style:none}
.content input[type=checkbox]{margin:0 .45em 0 0;vertical-align:-1px}
.content a{color:var(--accent)}
.content blockquote{margin:0 0 1em;padding:.4em 1em;border-left:4px solid var(--accent);background:#f4f7fd;color:#3b4552;border-radius:0 6px 6px 0}
.content blockquote > :last-child{margin-bottom:0}
.content code{font-family:Menlo, Consolas, 'D2Coding', monospace;font-size:.88em;background:#eff1f3;padding:.12em .4em;border-radius:4px}
.content pre{background:#f6f8fa;border:1px solid var(--line);border-radius:8px;padding:14px 16px;overflow:auto;line-height:1.5}
.content pre code{background:none;padding:0;font-size:13.5px}
.table-wrap{overflow-x:auto;margin:0 0 1.2em}
.content table{border-collapse:collapse;width:100%;font-size:15px}
.content th,.content td{border:1px solid var(--line);padding:8px 12px;vertical-align:top}
.content thead th{background:#f0f3f6;font-weight:700;text-align:left}
.content tbody tr:nth-child(even){background:#fafbfc}
.content img{max-width:100%;border-radius:6px}
.content hr{border:none;border-top:1px solid var(--line);margin:2em 0}
.report-footer{margin-top:48px;padding-top:14px;border-top:1px solid var(--line);color:var(--muted);font-size:12px}
@media (max-width:720px){.page{margin:0;border-radius:0;padding:28px 18px}.report-header h1{font-size:24px}}
@media print{
  @page{margin:18mm 16mm}
  body{background:#fff;font-size:11pt}
  .page{box-shadow:none;margin:0;padding:0;max-width:none;border-radius:0}
  .toc a{color:var(--fg)}
  .content a{color:var(--fg);text-decoration:underline}
  h1,h2,h3,h4{break-after:avoid}
  pre,blockquote,table,img{break-inside:avoid}
  tr{break-inside:avoid}
  .table-wrap{overflow:visible}
}
"""#
}
