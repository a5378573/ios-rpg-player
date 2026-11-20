import SwiftUI

/// 覆盖在游戏画面上的虚拟键盘。编辑模式下可拖动、可缩放，普通模式下按压触发按键。
struct VirtualControlsOverlay: View {
    @Binding var layout: ControlLayout
    var isEditing: Bool
    var onPress: (GameKey, String?) -> Void
    var onRelease: (GameKey, String?) -> Void

    private let coordinateSpaceName = "virtual_controls_canvas"

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                ForEach($layout.buttons) { $button in
                    if button.isVisible {
                        VirtualButtonView(
                            button: $button,
                            canvasSize: proxy.size,
                            isEditing: isEditing,
                            globalOpacity: layout.globalOpacity,
                            coordinateSpaceName: coordinateSpaceName,
                            onPress: {
                                onPress(button.function,
                                        button.function == .custom ? button.customKey : nil)
                            },
                            onRelease: {
                                onRelease(button.function,
                                          button.function == .custom ? button.customKey : nil)
                            }
                        )
                        .position(x: button.x * proxy.size.width,
                                  y: button.y * proxy.size.height)
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .coordinateSpace(name: coordinateSpaceName)
        }
        .allowsHitTesting(layout.isEnabled || isEditing)
    }
}

struct VirtualButtonView: View {
    @Binding var button: VirtualButton
    let canvasSize: CGSize
    let isEditing: Bool
    let globalOpacity: Double
    let coordinateSpaceName: String
    var onPress: () -> Void
    var onRelease: () -> Void

    @State private var isPressed = false

    var body: some View {
        ZStack {
            Circle()
                .fill(isPressed ? Color.white.opacity(0.40) : Color.white.opacity(0.14))
            Circle()
                .strokeBorder(Color.white.opacity(isEditing ? 0.95 : 0.45),
                              lineWidth: isEditing ? 2 : 1)
            Text(button.effectiveLabel)
                .font(.system(size: max(12, button.size * 0.36), weight: .semibold))
                .foregroundColor(.white)
                .shadow(color: .black.opacity(0.5), radius: 2, x: 0, y: 1)
        }
        .frame(width: button.size, height: button.size)
        .opacity(button.opacity * globalOpacity)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0,
                        coordinateSpace: .named(coordinateSpaceName))
                .onChanged { value in
                    if isEditing {
                        let nx = min(max(value.location.x / max(canvasSize.width, 1), 0.02), 0.98)
                        let ny = min(max(value.location.y / max(canvasSize.height, 1), 0.02), 0.98)
                        button.x = nx
                        button.y = ny
                    } else {
                        guard !isPressed else { return }
                        isPressed = true
                        onPress()
                    }
                }
                .onEnded { _ in
                    guard !isEditing else { return }
                    isPressed = false
                    onRelease()
                }
        )
        .animation(.easeOut(duration: 0.08), value: isPressed)
    }
}
