import SwiftUI

struct AboutView: View {
    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "Version \(v) (\(b))"
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 84, height: 84)
            Text("MasterFabric Cut").font(.title.bold())
            Text(version).foregroundStyle(.secondary)
            Text("Screenshots, screen recording and Recording Studio for macOS.")
                .multilineTextAlignment(.center).font(.callout)
            Divider().padding(.vertical, 4)
            Text("Created by Gürkan Fikret Günak").font(.headline)
            Link("MasterFabric — masterfabric.co", destination: URL(string: "https://masterfabric.co")!)
            Text("Copyright © 2026 Gürkan Fikret Günak, MasterFabric.\nReleased under the MIT License.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(24).frame(width: 360)
    }
}
