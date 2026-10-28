// 편집기·미리보기 나누기 칸의 경계 계산과 경계 막대.
// - 경계 위치는 "편집기가 차지하는 비율"로 기억한다. 창 크기가 바뀌어도 같은 비율을 유지한다.
// - 한쪽 칸이 너무 좁아지지 않게 최소 폭을 지킨다. 창이 너무 좁으면 반반으로 나눈다.
// - 경계선은 1px로 그리지만, 마우스로 잡는 범위는 양옆으로 넓힌다(SplitLayout.grabMargin).
// - 경계를 두 번 누르면 반반으로 되돌린다.
// 의존성: AppKit
import AppKit

public enum SplitLayout {
    /// 편집기·미리보기 각 칸의 최소 폭
    public static let minPane: CGFloat = 200
    /// 1px 경계선 양옆으로 마우스가 잡히는 폭
    public static let grabMargin: CGFloat = 4
    /// 기억하는 비율의 허용 범위 (설정 파일이 이상해도 한쪽이 사라지지 않게)
    public static let ratioRange: ClosedRange<Double> = 0.1...0.9

    /// 비율을 경계 위치(편집기 폭)로 바꾼다.
    ///
    /// - Parameters:
    ///   - ratio: 편집기 비율 (0~1)
    ///   - total: 나누기 칸 전체 폭
    ///   - divider: 경계선 두께
    ///   - minPane: 각 칸의 최소 폭
    /// - Returns: 편집기 칸의 폭(정수 픽셀)
    public static func position(ratio: Double, total: CGFloat, divider: CGFloat, minPane: CGFloat = minPane) -> CGFloat {
        let usable = total - divider
        guard usable > 0 else { return 0 }
        // 두 칸 모두 최소 폭을 지킬 수 없을 만큼 좁으면 반반으로 나눈다.
        if usable < minPane * 2 { return (usable / 2).rounded() }
        let r = ratio.isFinite ? ratio : 0.5
        let want = (usable * CGFloat(r)).rounded()
        return min(max(want, minPane), usable - minPane)
    }

    /// 현재 편집기 폭을 비율로 바꾼다.
    public static func ratio(editorWidth: CGFloat, total: CGFloat, divider: CGFloat) -> Double {
        let usable = total - divider
        guard usable > 0, editorWidth.isFinite else { return 0.5 }
        return clampRatio(Double(editorWidth / usable))
    }

    /// 비율을 허용 범위 안으로 맞춘다. 숫자가 아니면 반반.
    public static func clampRatio(_ value: Double) -> Double {
        guard value.isFinite else { return 0.5 }
        return min(max(value, ratioRange.lowerBound), ratioRange.upperBound)
    }
}

/// 편집기·미리보기를 나누는 칸. 사용자가 경계를 끌거나 두 번 눌렀을 때를 알려 준다.
final class EditorSplitView: NSSplitView {
    /// 경계 끌기를 마쳤을 때
    var onDragEnd: (() -> Void)?
    /// 경계를 두 번 눌렀을 때
    var onDoubleClick: (() -> Void)?

    // NSSplitView는 경계(또는 넓힌 잡기 범위)를 누를 때만 mouseDown을 받는다.
    // super.mouseDown은 마우스를 뗄 때까지 끌기를 처리하고 돌아온다.
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount == 2 {
            onDoubleClick?()
        } else {
            onDragEnd?()
        }
    }
}
