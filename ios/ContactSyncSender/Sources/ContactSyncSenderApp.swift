import SwiftUI

@main
struct ContactSyncSenderApp: App {
    @StateObject private var sync = SyncManager.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(sync)
                .onAppear { sync.start() }
        }
        .backgroundTask(.appRefresh(SyncManager.refreshTaskId)) {
            await SyncManager.shared.backgroundRefresh()
        }
    }
}
