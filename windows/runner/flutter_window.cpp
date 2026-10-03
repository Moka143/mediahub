#include "flutter_window.h"

#include <flutter/method_result_functions.h>
#include <flutter/standard_method_codec.h>
#include <shellapi.h>

#include <memory>
#include <optional>
#include <string>

#include "flutter/generated_plugin_registrant.h"
#include "utils.h"

namespace {

// How long a sign-out or shutdown waits for the Dart teardown. Longer than
// the Dart side's own deadline (kShutdownDeadline, 5 s, in
// lib/services/app_shutdown.dart), so it is only ever the backstop.
constexpr ULONGLONG kSessionEndBackstopMs = 6000;

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
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  // Files dragged in from Explorer arrive as WM_DROPFILES on this window;
  // see HandleDroppedFiles.
  file_drop_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "mediahub/file_drop",
          &flutter::StandardMethodCodec::GetInstance());
  DragAcceptFiles(GetHandle(), TRUE);

  app_exit_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "mediahub/app_exit",
          &flutter::StandardMethodCodec::GetInstance());

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
  file_drop_channel_ = nullptr;
  app_exit_channel_ = nullptr;
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
    case WM_DROPFILES:
      HandleDroppedFiles(reinterpret_cast<HDROP>(wparam));
      return 0;
    case WM_ENDSESSION:
      // Signing out or shutting down. Once this returns, Windows may end the
      // process at any moment, and the rqbit it started goes down with the
      // session with no chance to save. So tear down here, as a close does.
      // Not on WM_QUERYENDSESSION: another app can still cancel the sign-out
      // after that, and the app would carry on with its engine stopped.
      if (wparam) {
        TearDownForSessionEnd();
      }
      return 0;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}

void FlutterWindow::HandleDroppedFiles(HDROP drop) {
  flutter::EncodableList paths;
  const UINT count = DragQueryFileW(drop, 0xFFFFFFFF, nullptr, 0);
  for (UINT i = 0; i < count; ++i) {
    const UINT length = DragQueryFileW(drop, i, nullptr, 0);
    if (length == 0) {
      continue;
    }
    std::wstring path(length, L'\0');
    DragQueryFileW(drop, i, path.data(), length + 1);
    paths.push_back(flutter::EncodableValue(Utf8FromUtf16(path.c_str())));
  }
  DragFinish(drop);

  if (file_drop_channel_ && !paths.empty()) {
    file_drop_channel_->InvokeMethod(
        "filesDropped", std::make_unique<flutter::EncodableValue>(paths));
  }
}

void FlutterWindow::TearDownForSessionEnd() {
  if (!app_exit_channel_) {
    return;
  }
  // Named on the "apps are preventing sign-out" screen if the teardown runs
  // past the few seconds Windows waits before showing it.
  ShutdownBlockReasonCreate(GetHandle(), L"Stopping the torrent engine");

  // Shared rather than a local captured by reference: when the backstop runs
  // out, the reply can still arrive after this function has returned.
  auto done = std::make_shared<bool>(false);
  app_exit_channel_->InvokeMethod(
      "prepareToQuit", nullptr,
      std::make_unique<flutter::MethodResultFunctions<flutter::EncodableValue>>(
          [done](const flutter::EncodableValue*) { *done = true; },
          [done](const std::string&, const std::string&,
                 const flutter::EncodableValue*) { *done = true; },
          [done]() { *done = true; }));

  // The Dart side runs off this thread's message queue, and its reply comes
  // back through it, so keep the queue moving until it answers.
  const ULONGLONG deadline = GetTickCount64() + kSessionEndBackstopMs;
  bool quit = false;
  int quit_code = 0;
  MSG msg;
  while (!*done && !quit) {
    const ULONGLONG now = GetTickCount64();
    if (now >= deadline) {
      break;
    }
    MsgWaitForMultipleObjectsEx(0, nullptr, static_cast<DWORD>(deadline - now),
                                QS_ALLINPUT, MWMO_INPUTAVAILABLE);
    while (PeekMessage(&msg, nullptr, 0, 0, PM_REMOVE)) {
      if (msg.message == WM_QUIT) {
        quit = true;
        quit_code = static_cast<int>(msg.wParam);
        break;
      }
      TranslateMessage(&msg);
      DispatchMessage(&msg);
    }
  }
  if (quit) {
    // Not ours to consume: hand it back to the loop in wWinMain.
    PostQuitMessage(quit_code);
  }
  ShutdownBlockReasonDestroy(GetHandle());
}
