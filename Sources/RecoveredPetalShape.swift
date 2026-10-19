// NativePetalGlassShape reconstruction, original Tangerine 2.0.2 arm64.
// Source evidence: function 0x1000505b4, ARM64 disassembly; witness 0x100050b04.
// This is a readable transcription of measured path math, not recovered Swift source.
// Visual/runtime comparison remains required before calling it an exact match.
import SwiftUI

struct RecoveredPetalShape: Shape {
    var centerAngle: Double
    var sectorAngle: Double
    var gapWidth: Double
    var innerRadius: Double
    var outerRadius: Double

    // 0x100050b70/0x100050b8c: sectorAngle is NOT interpolated.
    var animatableData: AnimatablePair<AnimatablePair<Double, Double>, AnimatablePair<Double, Double>> {
        get { .init(.init(centerAngle, gapWidth), .init(innerRadius, outerRadius)) }
        set {
            centerAngle = newValue.first.first
            gapWidth = newValue.first.second
            innerRadius = newValue.second.first
            outerRadius = newValue.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let start = centerAngle - sectorAngle * 0.5
        let end = centerAngle + sectorAngle * 0.5
        let halfGap = max(gapWidth * 0.5, 0)
        func insetAngle(_ radius: Double) -> Double {
            asin(min(halfGap / max(radius, halfGap + 0.01), 0.95))
        }
        func point(_ radius: Double, _ angle: Double) -> CGPoint {
            CGPoint(x: center.x + radius * cos(angle), y: center.y - radius * sin(angle))
        }
        let innerStart = start + insetAngle(innerRadius)
        let innerEnd = end - insetAngle(innerRadius)
        let innerCornerAngle = min((innerEnd - innerStart) * 0.18, 0.18)
        let innerControlRadius = innerRadius / max(cos(innerCornerAngle), 0.01)
        let innerSideRadius = innerControlRadius + innerRadius * tan(innerCornerAngle)
        let outerSideRadius = max(outerRadius - 20.160000000000004, 0)
        let outerStart = start + insetAngle(outerRadius)
        let outerEnd = end - insetAngle(outerRadius)
        let outerCornerAngle = min((outerEnd - outerStart) * 0.24, 0.15)

        let innerSideStart = point(innerSideRadius, start + insetAngle(innerSideRadius))
        let innerSideEnd = point(innerSideRadius, end - insetAngle(innerSideRadius))
        let innerControlStart = point(innerControlRadius, start + insetAngle(innerControlRadius))
        let innerControlEnd = point(innerControlRadius, end - insetAngle(innerControlRadius))
        let outerSideStart = point(outerSideRadius, start + insetAngle(outerSideRadius))
        let outerSideEnd = point(outerSideRadius, end - insetAngle(outerSideRadius))
        var result = Path()
        result.move(to: innerSideStart)
        result.addLine(to: outerSideStart)
        result.addQuadCurve(to: point(outerRadius, outerStart + outerCornerAngle), control: point(outerRadius, outerStart))
        result.addArc(center: center, radius: outerRadius,
                      startAngle: .radians(-outerStart - outerCornerAngle),
                      endAngle: .radians(outerCornerAngle - outerEnd), clockwise: true)
        result.addQuadCurve(to: outerSideEnd, control: point(outerRadius, outerEnd))
        result.addLine(to: innerSideEnd)
        result.addQuadCurve(to: point(innerRadius, innerEnd - innerCornerAngle), control: innerControlEnd)
        result.addArc(center: center, radius: innerRadius,
                      startAngle: .radians(innerCornerAngle - innerEnd),
                      endAngle: .radians(-innerStart - innerCornerAngle), clockwise: false)
        result.addQuadCurve(to: innerSideStart, control: innerControlStart)
        result.closeSubpath()
        return result
    }
}
