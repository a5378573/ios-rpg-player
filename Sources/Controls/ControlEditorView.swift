import SwiftUI

struct ControlEditorView: View {
    @Binding var layout: ControlLayout
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            Form {
                Section {
                    Toggle("显示虚拟键盘", isOn: $layout.isEnabled)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("整体透明度")
                            Spacer()
                            Text(String(format: "%.0f%%", layout.globalOpacity * 100))
                                .foregroundColor(.secondary)
                        }
                        Slider(value: $layout.globalOpacity, in: 0.15...1.0)
                    }
                } header: {
                    Text("全局")
                }

                Section {
                    ForEach($layout.buttons) { $button in
                        NavigationLink {
                            ButtonDetailEditor(button: $button)
                        } label: {
                            HStack(spacing: 12) {
                                Text(button.effectiveLabel)
                                    .font(.system(size: 18, weight: .semibold))
                                    .frame(width: 30)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(button.function.displayName)
                                    Text(button.function == .custom ? "映射：\(button.customKey)" : "预设功能")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                if !button.isVisible {
                                    Text("隐藏")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                    .onDelete { offsets in
                        layout.buttons.remove(atOffsets: offsets)
                    }
                } header: {
                    Text("按键（左滑删除）")
                }

                Section {
                    Button {
                        layout.buttons.append(VirtualButton(function: .custom,
                                                            customKey: "A",
                                                            label: "A",
                                                            x: 0.5,
                                                            y: 0.5))
                    } label: {
                        Label("添加自定义按键", systemImage: "plus.circle")
                    }

                    Button(role: .destructive) {
                        layout = .default
                    } label: {
                        Label("恢复默认布局", systemImage: "arrow.counterclockwise")
                    }
                }
            }
            .navigationTitle("按键设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}

struct ButtonDetailEditor: View {
    @Binding var button: VirtualButton

    private let presetFunctions: [GameKey] = [.up, .down, .left, .right,
                                              .confirm, .cancel, .menu, .shift, .custom]

    var body: some View {
        Form {
            Section("功能") {
                Picker("功能", selection: $button.function) {
                    ForEach(presetFunctions) { key in
                        Text(key.displayName).tag(key)
                    }
                }
                .onChange(of: button.function) { newValue in
                    if newValue != .custom, button.label.isEmpty || button.label == "★" {
                        button.label = newValue.defaultLabel
                    }
                }
            }

            if button.function == .custom {
                Section {
                    TextField("键盘按键", text: $button.customKey)
                        .autocapitalization(.allCharacters)
                        .disableAutocorrection(true)
                } header: {
                    Text("映射")
                } footer: {
                    Text("支持单个字母或数字（A、1）、功能键（F1–F12）以及 Space、Enter、Escape、Tab、Shift、Ctrl、Alt 等写法。")
                }
            }

            Section("外观") {
                HStack {
                    Text("显示文字")
                    Spacer()
                    TextField("文字", text: $button.label)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 120)
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("大小")
                        Spacer()
                        Text("\(Int(button.size)) pt").foregroundColor(.secondary)
                    }
                    Slider(value: $button.size, in: 32...110, step: 2)
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("不透明度")
                        Spacer()
                        Text(String(format: "%.0f%%", button.opacity * 100))
                            .foregroundColor(.secondary)
                    }
                    Slider(value: $button.opacity, in: 0.15...1.0)
                }
                Toggle("显示此按键", isOn: $button.isVisible)
            }

            Section("位置") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("水平")
                        Spacer()
                        Text(String(format: "%.0f%%", button.x * 100)).foregroundColor(.secondary)
                    }
                    Slider(value: $button.x, in: 0.02...0.98)
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("垂直")
                        Spacer()
                        Text(String(format: "%.0f%%", button.y * 100)).foregroundColor(.secondary)
                    }
                    Slider(value: $button.y, in: 0.02...0.98)
                }
            }
        }
        .navigationTitle(button.function.displayName)
        .navigationBarTitleDisplayMode(.inline)
    }
}
