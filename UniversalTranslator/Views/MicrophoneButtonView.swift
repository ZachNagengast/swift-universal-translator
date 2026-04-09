import SwiftUI

/// Press-and-hold microphone button with a Liquid Glass capsule.
///
/// Uses a `DragGesture(minimumDistance: 0)` instead of a tap gesture so we can
/// distinguish "press started" from "press released" cleanly. While listening,
/// shows an animated pulse ring around the glass button.
struct MicrophoneButtonView: View {
    let color: Color
    let label: String
    let isListening: Bool
    let isDisabled: Bool
    let onPressStart: () -> Void
    let onPressEnd: () -> Void

    @State private var pulseScale: CGFloat = 1.0
    @State private var isPressed = false

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                // Animated pulse ring while listening.
                if isListening {
                    Circle()
                        .stroke(color.opacity(0.4), lineWidth: 2)
                        .frame(width: 72, height: 72)
                        .scaleEffect(pulseScale)
                        .opacity(2 - Double(pulseScale))
                }

                // Liquid Glass capsule, tinted to the side's color (red or blue).
                Image(systemName: isListening ? "waveform" : "mic.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white)
                    .symbolEffect(.variableColor.iterative, isActive: isListening)
                    .frame(width: 72, height: 72)
                    .glassEffect(
                        .regular
                            .tint(isListening ? color : color.opacity(0.85))
                            .interactive(),
                        in: .circle
                    )
                    .scaleEffect(isPressed ? 0.92 : 1.0)
                    .shadow(
                        color: color.opacity(isListening ? 0.55 : 0.25),
                        radius: isListening ? 14 : 6,
                        y: 2
                    )
            }
            .frame(width: 84, height: 84)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !isDisabled, !isPressed else { return }
                        isPressed = true
                        onPressStart()
                    }
                    .onEnded { _ in
                        guard isPressed else { return }
                        isPressed = false
                        onPressEnd()
                    }
            )

            Text(label)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.white.opacity(0.85))
        }
        .opacity(isDisabled ? 0.35 : 1.0)
        .animation(.easeOut(duration: 0.15), value: isPressed)
        .onChange(of: isListening) { _, listening in
            if listening {
                withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                    pulseScale = 1.6
                }
            } else {
                withAnimation(.easeOut(duration: 0.2)) {
                    pulseScale = 1.0
                }
            }
        }
    }
}
