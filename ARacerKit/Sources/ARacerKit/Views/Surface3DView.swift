import SwiftUI

/// Dependency-free rotatable 3D surface of a table grid. Drag to rotate.
struct Surface3DView: View {
    let rows: [[Double]]
    let unit: String
    @State private var yaw: Double = -0.6
    @State private var pitch: Double = 0.9

    var body: some View {
        GeometryReader { g in
            Canvas { ctx, size in
                guard rows.count > 1, let w = rows.first?.count, w > 1 else { return }
                let lo = rows.flatMap { $0 }.min() ?? 0, hi = rows.flatMap { $0 }.max() ?? 1
                let span = max(hi - lo, 0.001)
                let nx = w, ny = rows.count
                let cx = size.width / 2, cy = size.height / 2 + 40
                let sxy = min(size.width, size.height) / Double(max(nx, ny)) * 0.8
                let hScale = min(size.width, size.height) * 0.30
                func proj(_ xi: Int, _ yi: Int) -> CGPoint {
                    let x = Double(xi) - Double(nx - 1) / 2
                    let y = Double(yi) - Double(ny - 1) / 2
                    let z = (rows[yi][xi] - lo) / span - 0.5
                    let x1 = x * cos(yaw) - y * sin(yaw)
                    let y1 = x * sin(yaw) + y * cos(yaw)
                    let sx = cx + x1 * sxy
                    let sy = cy + (y1 * sin(pitch)) * sxy - z * hScale
                    return CGPoint(x: sx, y: sy)
                }
                // draw quads back-to-front
                for yi in 0..<(ny - 1) {
                    for xi in 0..<(nx - 1) {
                        var p = Path()
                        p.move(to: proj(xi, yi)); p.addLine(to: proj(xi + 1, yi))
                        p.addLine(to: proj(xi + 1, yi + 1)); p.addLine(to: proj(xi, yi + 1)); p.closeSubpath()
                        let v = (rows[yi][xi] - lo) / span
                        ctx.fill(p, with: .color(Color(hue: 0.6 - 0.6 * v, saturation: 0.7, brightness: 0.95).opacity(0.8)))
                        ctx.stroke(p, with: .color(.black.opacity(0.15)), lineWidth: 0.5)
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture().onChanged { v in
                yaw = -0.6 + v.translation.width / 120
                pitch = max(0.2, min(1.4, 0.9 - v.translation.height / 200))
            })
        }
    }
}
