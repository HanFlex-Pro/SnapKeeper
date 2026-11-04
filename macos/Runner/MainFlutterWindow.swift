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

    // 샌드박스는 재실행하면 폴더 접근 권한을 회수한다. 보안 북마크로 되찾는다.
    var accessedURL: URL?
    let folderChannel = FlutterMethodChannel(
      name: "snapkeeper/folder_access",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    folderChannel.setMethodCallHandler { call, result in
      func fail(_ message: String) {
        result(FlutterError(code: "folder_access_failed", message: message, details: nil))
      }
      func makeBookmark(_ url: URL) throws -> String {
        try url.bookmarkData(
          options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil
        ).base64EncodedString()
      }
      switch call.method {
      case "create":
        guard let path = call.arguments as? String else { return fail("경로 없음") }
        do { result(try makeBookmark(URL(fileURLWithPath: path))) } catch {
          fail(error.localizedDescription)
        }
      case "resolve":
        guard let bookmark = call.arguments as? String,
          let data = Data(base64Encoded: bookmark)
        else { return fail("북마크 형식 오류") }
        do {
          var stale = false
          let url = try URL(
            resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil,
            bookmarkDataIsStale: &stale)
          accessedURL?.stopAccessingSecurityScopedResource()
          accessedURL = nil
          guard url.startAccessingSecurityScopedResource() else { return fail("접근 권한 없음") }
          accessedURL = url
          result(["path": url.path, "bookmark": stale ? try makeBookmark(url) : nil])
        } catch {
          fail(error.localizedDescription)
        }
      case "release":
        accessedURL?.stopAccessingSecurityScopedResource()
        accessedURL = nil
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    super.awakeFromNib()
  }
}
