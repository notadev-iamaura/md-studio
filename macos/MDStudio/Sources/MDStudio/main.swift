// MD Studio 실행 파일의 시작점. 앱을 띄우는 일만 한다(기능은 모두 MDStudioKit에 있다).
// 환경 변수 MDSTUDIO_SELFTEST=<결과 폴더>가 있으면 자가 점검을 실행하고 끝난다.
import AppKit
import MDStudioKit

let app = NSApplication.shared
let delegate: AppDelegate
if let out = ProcessInfo.processInfo.environment["MDSTUDIO_SELFTEST"], !out.isEmpty {
    delegate = SelfTest.makeDelegate(outputDirectory: URL(fileURLWithPath: out, isDirectory: true))
} else {
    delegate = AppDelegate()
}
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
