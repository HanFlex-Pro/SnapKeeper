#include "flutter_window.h"

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <shlobj.h>
#include <shobjidl.h>
#include <shlwapi.h>
#include <windows.h>
#include <wrl/client.h>

#include <algorithm>
#include <memory>
#include <optional>
#include <string>

#include "flutter/generated_plugin_registrant.h"

namespace {

using Microsoft::WRL::ComPtr;

// 삭제 결과를 기록한다. 새 항목이 있어야 휴지통으로 옮겨진 것이다.
class DeleteSink : public IFileOperationProgressSink {
 public:
  bool recycled = false;
  HRESULT delete_result = S_OK;
  std::wstring recycled_path;

  IFACEMETHODIMP QueryInterface(REFIID riid, void** out) override {
    static const QITAB table[] = {
        QITABENT(DeleteSink, IFileOperationProgressSink), {nullptr, 0}};
    return QISearch(this, table, riid, out);
  }
  IFACEMETHODIMP_(ULONG) AddRef() override { return 2; }
  IFACEMETHODIMP_(ULONG) Release() override { return 1; }

  IFACEMETHODIMP PostDeleteItem(DWORD, IShellItem*, HRESULT hr, IShellItem* created) override {
    delete_result = hr;
    if (SUCCEEDED(hr) && created) {
      recycled = true;
      PWSTR path = nullptr;
      if (SUCCEEDED(created->GetDisplayName(SIGDN_DESKTOPABSOLUTEPARSING, &path))) {
        recycled_path = path;
        CoTaskMemFree(path);
      }
    }
    return S_OK;
  }

  IFACEMETHODIMP StartOperations() override { return S_OK; }
  IFACEMETHODIMP FinishOperations(HRESULT) override { return S_OK; }
  IFACEMETHODIMP PreRenameItem(DWORD, IShellItem*, LPCWSTR) override { return S_OK; }
  IFACEMETHODIMP PostRenameItem(DWORD, IShellItem*, LPCWSTR, HRESULT, IShellItem*) override { return S_OK; }
  IFACEMETHODIMP PreMoveItem(DWORD, IShellItem*, IShellItem*, LPCWSTR) override { return S_OK; }
  IFACEMETHODIMP PostMoveItem(DWORD, IShellItem*, IShellItem*, LPCWSTR, HRESULT, IShellItem*) override { return S_OK; }
  IFACEMETHODIMP PreCopyItem(DWORD, IShellItem*, IShellItem*, LPCWSTR) override { return S_OK; }
  IFACEMETHODIMP PostCopyItem(DWORD, IShellItem*, IShellItem*, LPCWSTR, HRESULT, IShellItem*) override { return S_OK; }
  IFACEMETHODIMP PreDeleteItem(DWORD, IShellItem*) override { return S_OK; }
  IFACEMETHODIMP PreNewItem(DWORD, IShellItem*, LPCWSTR) override { return S_OK; }
  IFACEMETHODIMP PostNewItem(DWORD, IShellItem*, LPCWSTR, LPCWSTR, DWORD, HRESULT, IShellItem*) override { return S_OK; }
  IFACEMETHODIMP UpdateProgress(UINT, UINT) override { return S_OK; }
  IFACEMETHODIMP ResetTimer() override { return S_OK; }
  IFACEMETHODIMP PauseTimer() override { return S_OK; }
  IFACEMETHODIMP ResumeTimer() override { return S_OK; }
};

std::wstring ToWide(const std::string& s) {
  int n = MultiByteToWideChar(CP_UTF8, 0, s.c_str(), -1, nullptr, 0);
  std::wstring w(n > 0 ? n - 1 : 0, L'\0');
  if (n > 1) MultiByteToWideChar(CP_UTF8, 0, s.c_str(), -1, w.data(), n);
  return w;
}

std::string ToUtf8(const std::wstring& w) {
  int n = WideCharToMultiByte(CP_UTF8, 0, w.c_str(), -1, nullptr, 0, nullptr, nullptr);
  std::string s(n > 0 ? n - 1 : 0, '\0');
  if (n > 1) WideCharToMultiByte(CP_UTF8, 0, w.c_str(), -1, s.data(), n, nullptr, nullptr);
  return s;
}

// 휴지통 이동. 실패 코드와 메시지를 돌려주며 성공 시 휴지통 안의 경로를 채운다.
std::optional<std::string> MoveToRecycleBin(std::wstring path, std::wstring* recycled_path) {
  // Shell API는 슬래시가 섞인 경로를 거부한다.
  std::replace(path.begin(), path.end(), L'/', L'\\');
  ComPtr<IFileOperation> op;
  HRESULT hr = CoCreateInstance(CLSID_FileOperation, nullptr, CLSCTX_ALL, IID_PPV_ARGS(&op));
  if (FAILED(hr)) return "CoCreateInstance " + std::to_string(hr);
  // FOF_WANTNUKEWARNING: 휴지통에 넣을 수 없으면 조용히 영구 삭제하지 않고 경고한다.
  hr = op->SetOperationFlags(FOF_ALLOWUNDO | FOF_NOCONFIRMATION | FOF_SILENT | FOF_NOERRORUI |
                             FOF_WANTNUKEWARNING | FOFX_RECYCLEONDELETE);
  if (FAILED(hr)) return "SetOperationFlags " + std::to_string(hr);
  ComPtr<IShellItem> item;
  hr = SHCreateItemFromParsingName(path.c_str(), nullptr, IID_PPV_ARGS(&item));
  if (FAILED(hr)) return "파일을 찾을 수 없음 " + std::to_string(hr);
  DeleteSink sink;
  hr = op->DeleteItem(item.Get(), &sink);
  if (FAILED(hr)) return "DeleteItem " + std::to_string(hr);
  hr = op->PerformOperations();
  if (FAILED(hr)) return "PerformOperations " + std::to_string(hr);
  BOOL aborted = FALSE;
  op->GetAnyOperationsAborted(&aborted);
  if (aborted) return "작업 취소됨";
  if (FAILED(sink.delete_result)) return "삭제 실패 " + std::to_string(sink.delete_result);
  if (!sink.recycled) return "휴지통 항목이 만들어지지 않음";
  *recycled_path = sink.recycled_path;
  return std::nullopt;
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());

  static std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> trash_channel;
  trash_channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "snapkeeper/trash",
      &flutter::StandardMethodCodec::GetInstance());
  trash_channel->SetMethodCallHandler([](const auto& call, auto result) {
    const auto* path = std::get_if<std::string>(call.arguments());
    if (call.method_name() != "moveToTrash" || !path) {
      result->NotImplemented();
      return;
    }
    std::wstring recycled;
    if (auto error = MoveToRecycleBin(ToWide(*path), &recycled)) {
      result->Error("trash_failed", *error);
    } else {
      result->Success(flutter::EncodableValue(ToUtf8(recycled)));
    }
  });

  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
