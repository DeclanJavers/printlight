import SwiftUI

@main
struct PrintlightApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            root
                .environmentObject(model)
                .preferredColorScheme(.dark)
        }
    }

    @ViewBuilder
    private var root: some View {
        #if DEBUG
        // `-PrintlightEditorDemo /path/to.dng` opens the editor straight on a file, so the
        // simulator (no camera, no RAWs in Photos) can be used to check the editor layout.
        if let shot = Self.editorDemoShot {
            EditorView(shot: shot)
        } else {
            CameraView(camera: model.camera)
        }
        #else
        CameraView(camera: model.camera)
        #endif
    }

    #if DEBUG
    private static let editorDemoShot: Shot? = {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-PrintlightEditorDemo"), args.indices.contains(i + 1),
              let dng = FileManager.default.contents(atPath: args[i + 1]) else { return nil }
        return Shot(dng: dng, thumbnail: UIImage(), params: .standard)
    }()
    #endif
}
