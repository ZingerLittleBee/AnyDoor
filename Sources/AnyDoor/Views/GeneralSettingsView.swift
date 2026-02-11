import SwiftUI

struct GeneralSettingsView: View {
    var body: some View {
        VStack {
            Text("通用设置")
                .font(.headline)
            Text("暂无可配置项")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
