import SwiftUI

/// Lightweight charcoal background with subtle radial accent and noise texture.
/// Lighter than pure black so the skeuomorphic device elements pop.
struct AnimatedBackgroundView: View {
    var body: some View {
        ZStack {
            // Charcoal base (RGB: 28, 28, 33)
            Color(red: 0.11, green: 0.11, blue: 0.13)

            // Soft radial accent from top
            RadialGradient(
                colors: [
                    // Accent color (RGB: 46, 41, 56)
                    Color(red: 0.18, green: 0.16, blue: 0.22),
                    // Charcoal base (RGB: 28, 28, 33)
                    Color(red: 0.11, green: 0.11, blue: 0.13),
                ],
                center: .top,
                startRadius: 80,
                endRadius: 700
            )

            // Faint noise overlay for fabric-like texture
            NoiseOverlay()
                .opacity(0.06)
                .blendMode(.overlay)
        }
        .ignoresSafeArea()
    }
}

private struct NoiseOverlay: View {
    var body: some View {
        Canvas { context, size in
            var generator = SystemRandomNumberGenerator()
            let dotCount = Int(size.width * size.height / 180)
            for _ in 0..<dotCount {
                let x = CGFloat.random(in: 0..<size.width, using: &generator)
                let y = CGFloat.random(in: 0..<size.height, using: &generator)
                let opacity = Double.random(in: 0.1...0.5, using: &generator)
                context.fill(
                    Path(CGRect(x: x, y: y, width: 1, height: 1)),
                    with: .color(.white.opacity(opacity))
                )
            }
        }
        .drawingGroup()
    }
}
