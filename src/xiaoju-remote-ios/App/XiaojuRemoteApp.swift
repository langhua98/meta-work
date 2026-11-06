import SwiftUI

@main
struct XiaojuRemoteApp: App {
    @StateObject private var store = Store()

    var body: some Scene {
        WindowGroup {
            RootView(store: store)
        }
    }
}

struct RootView: View {
    @ObservedObject var store: Store
    @StateObject private var engine: RemoteEngine

    init(store: Store) {
        self.store = store
        _engine = StateObject(wrappedValue: RemoteEngine(store: store))
    }

    var body: some View {
        ContentView()
            .environmentObject(store)
            .environmentObject(engine)
    }
}
