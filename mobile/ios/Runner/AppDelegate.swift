import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let documentImporter = DocumentImporter()

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    engineBridge.pluginRegistry.registrar(forPlugin: "RnoteDocumentImporter")?
      .addSceneDelegate(documentImporter)
  }
}

/// Copies `.rnote` files opened from other apps (Files, Mail, AirDrop, ...)
/// into the library folder, where the Flutter side picks them up when the app
/// becomes active.
class DocumentImporter: NSObject, FlutterSceneLifeCycleDelegate {

  func scene(
    _ scene: UIScene, willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions?
  ) -> Bool {
    if let contexts = connectionOptions?.urlContexts { importDocuments(contexts) }
    return false
  }

  func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) -> Bool {
    return importDocuments(URLContexts)
  }

  @discardableResult
  private func importDocuments(_ contexts: Set<UIOpenURLContext>) -> Bool {
    guard
      let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    else { return false }
    let library = docs.appendingPathComponent("Rnote", isDirectory: true)
    try? FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)

    var handled = false
    for context in contexts {
      let url = context.url
      guard url.isFileURL, url.pathExtension.lowercased() == "rnote" else { continue }
      handled = true
      // files already inside the library are opened in place
      if url.standardizedFileURL.path.hasPrefix(library.standardizedFileURL.path) { continue }

      let scoped = url.startAccessingSecurityScopedResource()
      defer { if scoped { url.stopAccessingSecurityScopedResource() } }

      let base = url.deletingPathExtension().lastPathComponent
      var target = library.appendingPathComponent("\(base).rnote")
      var i = 2
      while FileManager.default.fileExists(atPath: target.path) {
        target = library.appendingPathComponent("\(base) (\(i)).rnote")
        i += 1
      }
      var coordinatorError: NSError?
      NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinatorError) {
        readURL in
        try? FileManager.default.copyItem(at: readURL, to: target)
      }
      // documents handed over through the inbox are no longer needed there
      if url.path.contains("/Inbox/") { try? FileManager.default.removeItem(at: url) }
    }
    return handled
  }
}
