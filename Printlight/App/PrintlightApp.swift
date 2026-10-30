import SwiftUI

@main
struct PrintlightApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            CameraView(camera: model.camera)
                .environmentObject(model)
                .preferredColorScheme(.dark)
        }
    }
}
