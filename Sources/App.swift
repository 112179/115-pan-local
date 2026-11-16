import SwiftUI

@main
struct Pan115LocalApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var auth = AuthStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(auth)
                .tint(.blue)
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var auth: AuthStore

    var body: some View {
        Group {
            if auth.cookie.isEmpty {
                QRLoginView()
            } else {
                MainView()
            }
        }
        .statusBarHidden(false)
    }
}

struct MainView: View {
    @EnvironmentObject private var auth: AuthStore

    var body: some View {
        TabView {
            NavigationStack {
                BrowserList(cid: "0", name: "115 云盘")
                    .navigationTitle("115 云盘")
                    .navigationDestination(for: DirRoute.self) { route in
                        BrowserList(cid: route.id, name: route.name)
                            .navigationTitle(route.name)
                    }
            }
            .tabItem { Label("云盘", systemImage: "cloud") }

            NavigationStack {
                TasksView()
            }
            .tabItem { Label("任务", systemImage: "arrow.down.circle") }

            NavigationStack {
                SettingsView()
            }
            .tabItem { Label("设置", systemImage: "gearshape") }
        }
    }
}
