import SwiftUI

/// Skeuomorphic speaker grille that sits below the mic buttons.
///
/// - **Idle**: dots are rendered as dark "punched holes" with a tiny bottom-right
///   highlight pixel each, to suggest depth.
/// - **Speaking**: all dots pulse together (opacity 0 → 0.9 via a sine wave) so the
///   grille reads as actively producing sound.
/// - **Tap to stop**: while TTS is playing, tapping anywhere on the grille calls
///   `onTapToStop`, which interrupts the speech (used to abort hallucinated translations).
///
/// Corner dots are culled via a rounded-rectangle SDF mask so the dot grid forms
/// a stadium / rounded-rect outline rather than a square.
struct SpeakerGrilleView: View {
    var isSpeaking: Bool
    var onTapToStop: (() -> Void)? = nil

    private let columns = 18
    private let rows = 6
    private let dotSize: CGFloat = 5.0
    private let spacing: CGFloat = 11.0
    private let cornerRadius: CGFloat = 16

    private let recessTop = Color(red: 0.10, green: 0.10, blue: 0.12)
    private let recessBottom = Color(red: 0.16, green: 0.16, blue: 0.18)

    var body: some View {
        ZStack {
            // Recessed surface — uses real `Shape.fill(.shadow(.inner(...)))` for the
            // carved-out look, plus a thin top-dark / bottom-light stroke for the rim.
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(
                    LinearGradient(
                        colors: [recessTop, recessBottom],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .shadow(.inner(color: .black.opacity(0.95), radius: 5, x: 0, y: 3))
                    .shadow(.inner(color: .black.opacity(0.6), radius: 1, x: 0, y: 1))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color.black.opacity(0.6),
                                    Color.white.opacity(0.04),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 0.6
                        )
                )

            // Dot grid drawn into a Canvas. Animation is driven by TimelineView,
            // which auto-pauses when not speaking so we don't burn frames.
            TimelineView(.animation(paused: !isSpeaking)) { timeline in
                let time = timeline.date.timeIntervalSinceReferenceDate
                Canvas { context, size in
                    let totalWidth = CGFloat(columns - 1) * spacing
                    let totalHeight = CGFloat(rows - 1) * spacing
                    let offsetX = (size.width - totalWidth) / 2
                    let offsetY = (size.height - totalHeight) / 2
                    let centerX = size.width / 2
                    let centerY = size.height / 2
                    let halfGridW = totalWidth / 2
                    let halfGridH = totalHeight / 2

                    for row in 0..<rows {
                        for col in 0..<columns {
                            let x = offsetX + CGFloat(col) * spacing
                            let y = offsetY + CGFloat(row) * spacing

                            // Rounded-rectangle SDF mask: cull corner dots so the grid
                            // has rounded corners instead of a square outline.
                            let nx = (x - centerX) / halfGridW
                            let ny = (y - centerY) / halfGridH
                            let halfW = 0.96
                            let halfH = 0.92
                            let cornerR = 0.35
                            let qx = max(abs(nx) - halfW + cornerR, 0)
                            let qy = max(abs(ny) - halfH + cornerR, 0)
                            if sqrt(qx * qx + qy * qy) > cornerR { continue }

                            if isSpeaking {
                                // Pulse all dots together (opacity 0 → 0.9, ~1.8s period).
                                // Skip drawing entirely at the trough so the dots truly disappear.
                                let pulse = sin(time * 3.5) * 0.5 + 0.5
                                if pulse < 0.02 { continue }
                                let dotRect = CGRect(
                                    x: x - dotSize / 2,
                                    y: y - dotSize / 2,
                                    width: dotSize,
                                    height: dotSize
                                )
                                context.fill(
                                    Circle().path(in: dotRect),
                                    with: .color(.white.opacity(pulse * 0.9))
                                )
                            } else {
                                // Dark punched hole + bottom-right highlight pixel for depth.
                                let holeRect = CGRect(
                                    x: x - dotSize / 2,
                                    y: y - dotSize / 2,
                                    width: dotSize,
                                    height: dotSize
                                )
                                context.fill(
                                    Circle().path(in: holeRect),
                                    with: .color(.black.opacity(0.45))
                                )
                                let highlightRect = CGRect(
                                    x: x + dotSize / 2 - 0.6,
                                    y: y + dotSize / 2 - 0.6,
                                    width: 0.6,
                                    height: 0.6
                                )
                                context.fill(
                                    Circle().path(in: highlightRect),
                                    with: .color(.white.opacity(0.15))
                                )
                            }
                        }
                    }
                }
            }
            .padding(14)
        }
        .frame(height: 100)
        .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
        .onTapGesture {
            if isSpeaking, let onTapToStop {
                onTapToStop()
            }
        }
    }
}
