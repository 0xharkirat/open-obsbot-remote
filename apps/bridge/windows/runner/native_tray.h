#ifndef RUNNER_NATIVE_TRAY_H_
#define RUNNER_NATIVE_TRAY_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <memory>
#include <optional>
#include <string>
#include <vector>

// Windows twin of macos/Runner/NativeTray.swift: a notification-area icon
// plus popup menu, driven by the same `obsbot.bridge/tray` method channel so
// lib/native_tray.dart and lib/tray_controller.dart run unchanged.
//
//   setIcon {bytes, isTemplate}   PNG bytes from the Flutter asset bundle
//   setTooltip {text}
//   setTitle {title}              no Windows equivalent; becomes the tooltip
//   setMenu {items}               [{type, key, label, disabled}]
//   destroy
//
// Clicks go back as `onMenuClick {key}`. A left click on the icon sends
// `show_window`, which is what a Windows user expects a tray icon to do;
// the right click opens the menu.
class NativeTray {
 public:
  NativeTray(flutter::BinaryMessenger* messenger, HWND window);
  ~NativeTray();

  // Called from FlutterWindow::MessageHandler before anything else.
  std::optional<LRESULT> HandleMessage(HWND hwnd, UINT message, WPARAM wparam,
                                       LPARAM lparam);

 private:
  struct Item {
    bool separator = false;
    std::string key;
    std::wstring label;
    bool disabled = false;
  };

  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  void EnsureAdded();
  void Remove();
  void SetIconFromPng(const std::vector<uint8_t>& png, bool is_template);
  void SetTooltip(const std::wstring& text);
  void ShowMenu();
  void SendClick(const std::string& key);

  HWND window_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  NOTIFYICONDATAW nid_{};
  bool added_ = false;
  HICON icon_ = nullptr;
  std::vector<Item> items_;
  UINT taskbar_created_msg_ = 0;
};

#endif  // RUNNER_NATIVE_TRAY_H_
