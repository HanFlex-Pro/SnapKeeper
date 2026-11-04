import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    let trashChannel = FlutterMethodChannel(
      name: "snapkeeper/trash",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    trashChannel.setMethodCallHandler { call, result in
      guard call.method == "moveToTrash", let path = call.arguments as? String else {
        result(FlutterMethodNotImplemented)
        return
      }
      do {
        var trashedURL: NSURL?
        try FileManager.default.trashItem(
          at: URL(fileURLWithPath: path), resultingItemURL: &trashedURL)
        result(trashedURL?.path)
      } catch {
        result(
          FlutterError(code: "trash_failed", message: error.localizedDescription, details: nil))
      }
    }

    super.awakeFromNib()
  }
}
