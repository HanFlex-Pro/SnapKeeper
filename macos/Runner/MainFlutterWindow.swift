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

    // M0 기술 검증용. App Nap이 스캔 속도에 주는 영향을 확인한다.
    let activityChannel = FlutterMethodChannel(
      name: "snapkeeper/activity",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    var activityToken: NSObjectProtocol?
    activityChannel.setMethodCallHandler { _, result in
      activityToken = ProcessInfo.processInfo.beginActivity(
        options: .userInitiated, reason: "사진 스캔")
      result(activityToken != nil)
    }

    // M0 기술 검증용. 샌드박스 재실행 후 폴더 접근을 확인한다.
    let bookmarkChannel = FlutterMethodChannel(
      name: "snapkeeper/bookmark",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    bookmarkChannel.setMethodCallHandler { call, result in
      guard let argument = call.arguments as? String else {
        result(FlutterMethodNotImplemented)
        return
      }
      do {
        switch call.method {
        case "create":
          let data = try URL(fileURLWithPath: argument).bookmarkData(
            options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
          result(data.base64EncodedString())
        case "resolve":
          var stale = false
          let url = try URL(
            resolvingBookmarkData: Data(base64Encoded: argument) ?? Data(),
            options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
          _ = url.startAccessingSecurityScopedResource()
          result(url.path)
        default:
          result(FlutterMethodNotImplemented)
        }
      } catch {
        result(
          FlutterError(code: "bookmark_failed", message: error.localizedDescription, details: nil))
      }
    }

    super.awakeFromNib()
  }
}
