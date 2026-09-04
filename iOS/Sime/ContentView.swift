import SwiftUI

struct ContentView: View {
    @State private var scheme = InputSettings.scheme
    @State private var prediction = InputSettings.predictionEnabled

    // The schemes offered in the picker, in display order.
    private let schemes: [InputScheme] = [
        .fullPinyin, .microsoftShuangpin, .xiaoheShuangpin, .ziranmaShuangpin, .sogouShuangpin
    ]

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                Image(systemName: "keyboard")
                    .font(.system(size: 48))
                    .foregroundStyle(.tint)
                Text("是语输入法")
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
                Divider()
                Text("启用方法")
                    .font(.headline)
                Text("1. 打开“设置” > “通用” > “键盘” > “键盘”\n2. 选择“添加新键盘”\n3. 在第三方键盘中选择“是语键盘”\n4. 在任意输入框长按地球键切换")
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
            .padding(24)
            .navigationTitle("是语输入法")
        }
    }
}
