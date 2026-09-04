import SwiftUI
import CoreGraphics
import SealCore

@main
struct PDFSealApp: App {
    @StateObject private var doc = DocumentStore()
    @StateObject private var seals = SealStore()
    @StateObject private var settings = StampSettings()

    var body: some Scene {
        WindowGroup("PDF骑缝章") {
            ContentView()
                .environmentObject(doc)
                .environmentObject(seals)
                .environmentObject(settings)
                .frame(minWidth: 1180, minHeight: 760)
        }
        .windowToolbarStyle(.unified)
    }
}
