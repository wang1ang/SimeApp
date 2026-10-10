import SwiftUI

struct ContentView: View {
    @State private var scheme = InputSettings.scheme
    @State private var prediction = InputSettings.predictionEnabled
    @State private var reDecode = InputSettings.reDecodeOnCorrection
    @State private var testText = ""

    // The schemes offered in the picker, in display order.
    private let schemes: [InputScheme] = [
        .fullPinyin, .microsoftShuangpin, .xiaoheShuangpin, .ziranmaShuangpin, .sogouShuangpin
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Image(systemName: "keyboard")
                        .font(.system(size: 48))
                        .foregroundStyle(.tint)
                    Text("乐言输入法")
                        .font(.largeTitle.bold())
                    Text("离线拼音输入法。键盘不会请求完全访问权限，也不会上传输入内容。")
                        .foregroundStyle(.secondary)
                    Picker("输入方案", selection: $scheme) {
                        ForEach(schemes, id: \.self) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                    .onChange(of: scheme) { newValue in
                        InputSettings.scheme = newValue
                    }
                    Text("当前：\(scheme.displayName)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Toggle("联想", isOn: $prediction)
                        .onChange(of: prediction) { enabled in
                            InputSettings.predictionEnabled = enabled
                        }
                    Text(prediction ? "当前：上屏后显示联想候选" : "当前：关闭联想")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Toggle("更正后整句重解", isOn: $reDecode)
                        .onChange(of: reDecode) { enabled in
                            InputSettings.reDecodeOnCorrection = enabled
                        }
                    Text(reDecode ? "当前：手动改字后整句按引擎重新解码" : "当前：改字只覆盖该字，其余不变")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Divider()
                    Text("启用方法")
                        .font(.headline)
                    Text("1. 打开“设置” > “通用” > “键盘” > “键盘”\n2. 选择“添加新键盘”\n3. 在第三方键盘中选择“乐言输入法”\n4. 在任意输入框长按地球键切换")
                        .fixedSize(horizontal: false, vertical: true)
                    Divider()
                    Text("输入测试")
                        .font(.headline)
                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $testText)
                            .scrollContentBackground(.hidden)
                            .padding(8)
                            .background(.quaternary.opacity(0.35))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .accessibilityLabel("输入测试文本框")
                        if testText.isEmpty {
                            Text("在这里输入文字，测试乐言输入法")
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 13)
                                .padding(.vertical, 16)
                                .allowsHitTesting(false)
                        }
                    }
                    .frame(minHeight: 120)
                }
                .padding(24)
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("乐言输入法")
        }
    }
}
