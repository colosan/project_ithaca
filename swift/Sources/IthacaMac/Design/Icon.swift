// Lucide icons drawn from the generated vectors (IconVectors.swift) — the same shapes the workbench draws, never SF Symbols.
import AppKit
import IthacaDesign
import SwiftUI

struct Icon: View {
    let icon: IthacaIcon
    var size: Double = T.Size.iconMd
    var color: Color? = nil

    init(_ icon: IthacaIcon, size: Double = T.Size.iconMd, color: Color? = nil) {
        self.icon = icon
        self.size = size
        self.color = color
    }

    var body: some View {
        let scale = size / IconVectors.viewBox
        LucideShape(elements: icon.elements)
            .stroke(style: StrokeStyle(lineWidth: IconVectors.strokeWidth * scale, lineCap: .round, lineJoin: .round))
            .foregroundStyle(color.map(AnyShapeStyle.init) ?? AnyShapeStyle(.foreground))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

struct LucideShape: Shape {
    let elements: [IconElement]

    func path(in rect: CGRect) -> Path {
        var p = Path()
        for e in elements {
            switch e {
            case .path(let d): SVGPath.append(d, to: &p)
            case let .circle(cx, cy, r): p.addEllipse(in: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r))
            case let .ellipse(cx, cy, rx, ry): p.addEllipse(in: CGRect(x: cx - rx, y: cy - ry, width: 2 * rx, height: 2 * ry))
            case let .rect(x, y, w, h, rx): p.addRoundedRect(in: CGRect(x: x, y: y, width: w, height: h), cornerSize: CGSize(width: rx, height: rx))
            case let .line(x1, y1, x2, y2):
                p.move(to: CGPoint(x: x1, y: y1))
                p.addLine(to: CGPoint(x: x2, y: y2))
            case .polyline(let pts), .polygon(let pts):
                for i in stride(from: 0, to: pts.count - 1, by: 2) {
                    let pt = CGPoint(x: pts[i], y: pts[i + 1])
                    i == 0 ? p.move(to: pt) : p.addLine(to: pt)
                }
                if case .polygon = e { p.closeSubpath() }
            }
        }
        let s = min(rect.width, rect.height) / IconVectors.viewBox
        return p.applying(CGAffineTransform(scaleX: s, y: s).concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY)))
    }
}

/// Minimal SVG path-data parser: M L H V C S Q T A Z (absolute + relative). Arcs become cubic Béziers.
enum SVGPath {
    static func append(_ d: String, to path: inout Path) {
        var s = Scanner(d)
        var cur = CGPoint.zero, start = CGPoint.zero, lastCtrl: CGPoint? = nil, lastQuad: CGPoint? = nil
        var cmd: Character = "M"
        while let c = s.nextCommandOrNumber() {
            if case .command(let k) = c { cmd = k } else { s.unread() }
            let rel = cmd.isLowercase
            let base = rel ? cur : .zero
            func pt() -> CGPoint? {
                guard let x = s.number(), let y = s.number() else { return nil }
                return CGPoint(x: base.x + x, y: base.y + y)
            }
            switch cmd.uppercased().first! {
            case "M":
                guard let p = pt() else { return }
                path.move(to: p); cur = p; start = p
                cmd = rel ? "l" : "L"  // following pairs are line-tos
                lastCtrl = nil; lastQuad = nil
            case "L":
                guard let p = pt() else { return }
                path.addLine(to: p); cur = p; lastCtrl = nil; lastQuad = nil
            case "H":
                guard let x = s.number() else { return }
                cur = CGPoint(x: rel ? cur.x + x : x, y: cur.y); path.addLine(to: cur); lastCtrl = nil; lastQuad = nil
            case "V":
                guard let y = s.number() else { return }
                cur = CGPoint(x: cur.x, y: rel ? cur.y + y : y); path.addLine(to: cur); lastCtrl = nil; lastQuad = nil
            case "C":
                guard let c1 = pt(), let c2 = pt(), let p = pt() else { return }
                path.addCurve(to: p, control1: c1, control2: c2); cur = p; lastCtrl = c2; lastQuad = nil
            case "S":
                guard let c2 = pt(), let p = pt() else { return }
                let c1 = lastCtrl.map { CGPoint(x: 2 * cur.x - $0.x, y: 2 * cur.y - $0.y) } ?? cur
                path.addCurve(to: p, control1: c1, control2: c2); cur = p; lastCtrl = c2; lastQuad = nil
            case "Q":
                guard let c = pt(), let p = pt() else { return }
                path.addQuadCurve(to: p, control: c); cur = p; lastQuad = c; lastCtrl = nil
            case "T":
                guard let p = pt() else { return }
                let c = lastQuad.map { CGPoint(x: 2 * cur.x - $0.x, y: 2 * cur.y - $0.y) } ?? cur
                path.addQuadCurve(to: p, control: c); cur = p; lastQuad = c; lastCtrl = nil
            case "A":
                guard let rx = s.number(), let ry = s.number(), let rot = s.number(), let large = s.flag(), let sweep = s.flag(), let p = pt() else { return }
                arc(&path, from: cur, to: p, rx: rx, ry: ry, rotation: rot, large: large, sweep: sweep)
                cur = p; lastCtrl = nil; lastQuad = nil
            case "Z":
                path.closeSubpath(); cur = start; lastCtrl = nil; lastQuad = nil
            default: return
            }
        }
    }

    /// SVG elliptical arc (endpoint parameterization, W3C SVG implementation notes F.6) as Bézier segments.
    private static func arc(_ path: inout Path, from p0: CGPoint, to p1: CGPoint, rx rx0: Double, ry ry0: Double, rotation: Double, large: Bool, sweep: Bool) {
        var rx = abs(rx0), ry = abs(ry0)
        if rx == 0 || ry == 0 || p0 == p1 { path.addLine(to: p1); return }
        let phi = rotation * .pi / 180, cosP = cos(phi), sinP = sin(phi)
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1 = cosP * dx + sinP * dy, y1 = -sinP * dx + cosP * dy
        let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if lambda > 1 { rx *= lambda.squareRoot(); ry *= lambda.squareRoot() }
        let num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let den = rx * rx * y1 * y1 + ry * ry * x1 * x1
        var coef = (max(0, num / den)).squareRoot()
        if large == sweep { coef = -coef }
        let cxp = coef * rx * y1 / ry, cyp = -coef * ry * x1 / rx
        let cx = cosP * cxp - sinP * cyp + (p0.x + p1.x) / 2
        let cy = sinP * cxp + cosP * cyp + (p0.y + p1.y) / 2
        func angle(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double {
            let a = atan2(ux * vy - uy * vx, ux * vx + uy * vy)
            return a
        }
        let theta1 = angle(1, 0, (x1 - cxp) / rx, (y1 - cyp) / ry)
        var delta = angle((x1 - cxp) / rx, (y1 - cyp) / ry, (-x1 - cxp) / rx, (-y1 - cyp) / ry)
        if !sweep && delta > 0 { delta -= 2 * .pi }
        if sweep && delta < 0 { delta += 2 * .pi }
        let segments = max(1, Int(ceil(abs(delta) / (.pi / 2))))
        let step = delta / Double(segments)
        let k = 4.0 / 3.0 * tan(step / 4)
        var t = theta1
        func point(_ a: Double) -> CGPoint { CGPoint(x: cx + rx * cos(a) * cosP - ry * sin(a) * sinP, y: cy + rx * cos(a) * sinP + ry * sin(a) * cosP) }
        func deriv(_ a: Double) -> CGPoint { CGPoint(x: -rx * sin(a) * cosP - ry * cos(a) * sinP, y: -rx * sin(a) * sinP + ry * cos(a) * cosP) }
        for _ in 0..<segments {
            let a = point(t), b = point(t + step), da = deriv(t), db = deriv(t + step)
            path.addCurve(to: b, control1: CGPoint(x: a.x + k * da.x, y: a.y + k * da.y), control2: CGPoint(x: b.x - k * db.x, y: b.y - k * db.y))
            t += step
        }
    }

    private enum Token { case command(Character), number }

    private struct Scanner {
        let chars: [Character]
        var i = 0
        var mark = 0
        init(_ s: String) { chars = Array(s) }

        mutating func skip() { while i < chars.count, chars[i] == " " || chars[i] == "," || chars[i] == "\n" || chars[i] == "\t" { i += 1 } }

        mutating func nextCommandOrNumber() -> Token? {
            skip()
            guard i < chars.count else { return nil }
            mark = i
            let c = chars[i]
            if c.isLetter && c != "e" && c != "E" { i += 1; return .command(c) }
            return .number
        }

        mutating func unread() { i = mark }

        mutating func flag() -> Bool? {
            skip()
            guard i < chars.count, chars[i] == "0" || chars[i] == "1" else { return nil }
            defer { i += 1 }
            return chars[i] == "1"
        }

        mutating func number() -> Double? {
            skip()
            let from = i
            if i < chars.count, chars[i] == "-" || chars[i] == "+" { i += 1 }
            var dot = false
            while i < chars.count {
                let c = chars[i]
                if c.isNumber { i += 1 } else if c == ".", !dot { dot = true; i += 1 } else if c == "e" || c == "E" {
                    i += 1
                    if i < chars.count, chars[i] == "-" || chars[i] == "+" { i += 1 }
                } else { break }
            }
            guard i > from else { return nil }
            return Double(String(chars[from..<i]))
        }
    }
}

extension Image {
    /// A Lucide icon as a template image, for places that only take an Image (Settings tabs, menus).
    @MainActor init(lucide icon: IthacaIcon, size: Double = T.Size.iconMd) {
        let r = ImageRenderer(content: Icon(icon, size: size, color: .black))
        r.scale = 2
        let ns = r.nsImage ?? NSImage()
        ns.isTemplate = true
        self.init(nsImage: ns)
    }
}
