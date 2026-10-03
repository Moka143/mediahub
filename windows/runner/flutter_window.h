#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/encodable_value.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>

#include <memory>

#include "win32_window.h"

// After win32_window.h, which brings in <windows.h>: HDROP comes from here.
#include <shellapi.h>

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // Reports files dropped on the window to Dart ("mediahub/file_drop"),
  // where the .torrent ones open the add dialog.
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      file_drop_channel_;

  // Forwards the paths of a WM_DROPFILES drop and releases it.
  void HandleDroppedFiles(HDROP drop);

  // The channel the Dart side tears down on ("mediahub/app_exit", the one
  // the macOS app delegate uses) — stopping the torrent engine above all.
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      app_exit_channel_;

  // Runs the Dart teardown for a sign-out or shutdown and waits for it.
  void TearDownForSessionEnd();
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
