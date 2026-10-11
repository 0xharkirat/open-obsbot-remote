#include "native_tray.h"

#include <flutter/standard_method_codec.h>
#include <shellapi.h>
#include <wincodec.h>
#include <wrl/client.h>

using Microsoft::WRL::ComPtr;

namespace {

constexpr UINT kTrayCallback = WM_APP + 0x51;
constexpr UINT kTrayId = 1;
constexpr UINT kFirstCommand = 1000;

std::wstring Utf16(const std::string& s) {
  if (s.empty()) return {};
  int n = ::MultiByteToWideChar(CP_UTF8, 0, s.c_str(), -1, nullptr, 0);
  std::wstring out(n > 0 ? n - 1 : 0, L'\0');
  if (n > 1) ::MultiByteToWideChar(CP_UTF8, 0, s.c_str(), -1, out.data(), n);
  return out;
}

const flutter::EncodableValue* Field(const flutter::EncodableMap& m,
                                     const char* key) {
  auto it = m.find(flutter::EncodableValue(std::string(key)));
  return it == m.end() ? nullptr : &it->second;
}

std::string StringField(const flutter::EncodableMap& m, const char* key) {
  auto* v = Field(m, key);
  if (v == nullptr) return {};
  if (auto* s = std::get_if<std::string>(v)) return *s;
  return {};
}

bool BoolField(const flutter::EncodableMap& m, const char* key) {
  auto* v = Field(m, key);
  if (v == nullptr) return false;
  if (auto* b = std::get_if<bool>(v)) return *b;
  return false;
}

// The taskbar follows the system theme, not the app theme. A macOS template
// glyph is black-on-transparent, which disappears on the default dark
// taskbar, so template icons are recoloured to whichever of black or white
// contrasts with it.
bool TaskbarIsLight() {
  DWORD value = 0;
  DWORD size = sizeof(value);
  if (::RegGetValueW(
          HKEY_CURRENT_USER,
          L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
          L"SystemUsesLightTheme", RRF_RT_REG_DWORD, nullptr, &value,
          &size) != ERROR_SUCCESS) {
    return false;
  }
  return value != 0;
}

// Decode PNG bytes to a small-icon-sized HICON with WIC.
HICON IconFromPng(const std::vector<uint8_t>& png, bool is_template) {
  ComPtr<IWICImagingFactory> wic;
  if (FAILED(::CoCreateInstance(CLSID_WICImagingFactory, nullptr,
                                CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&wic)))) {
    return nullptr;
  }
  ComPtr<IWICStream> stream;
  if (FAILED(wic->CreateStream(&stream)) ||
      FAILED(stream->InitializeFromMemory(const_cast<BYTE*>(png.data()),
                                          static_cast<DWORD>(png.size())))) {
    return nullptr;
  }
  ComPtr<IWICBitmapDecoder> decoder;
  if (FAILED(wic->CreateDecoderFromStream(stream.Get(), nullptr,
                                          WICDecodeMetadataCacheOnDemand,
                                          &decoder))) {
    return nullptr;
  }
  ComPtr<IWICBitmapFrameDecode> frame;
  if (FAILED(decoder->GetFrame(0, &frame))) return nullptr;

  const UINT size = static_cast<UINT>(::GetSystemMetrics(SM_CXSMICON));
  ComPtr<IWICBitmapScaler> scaler;
  if (FAILED(wic->CreateBitmapScaler(&scaler)) ||
      FAILED(scaler->Initialize(frame.Get(), size, size,
                                WICBitmapInterpolationModeFant))) {
    return nullptr;
  }
  ComPtr<IWICFormatConverter> conv;
  if (FAILED(wic->CreateFormatConverter(&conv)) ||
      FAILED(conv->Initialize(scaler.Get(), GUID_WICPixelFormat32bppBGRA,
                              WICBitmapDitherTypeNone, nullptr, 0.0,
                              WICBitmapPaletteTypeCustom))) {
    return nullptr;
  }

  BITMAPV5HEADER bi{};
  bi.bV5Size = sizeof(bi);
  bi.bV5Width = static_cast<LONG>(size);
  bi.bV5Height = -static_cast<LONG>(size);  // top-down
  bi.bV5Planes = 1;
  bi.bV5BitCount = 32;
  bi.bV5Compression = BI_BITFIELDS;
  bi.bV5RedMask = 0x00FF0000;
  bi.bV5GreenMask = 0x0000FF00;
  bi.bV5BlueMask = 0x000000FF;
  bi.bV5AlphaMask = 0xFF000000;
  void* bits = nullptr;
  HDC dc = ::GetDC(nullptr);
  HBITMAP color = ::CreateDIBSection(dc, reinterpret_cast<BITMAPINFO*>(&bi),
                                     DIB_RGB_COLORS, &bits, nullptr, 0);
  ::ReleaseDC(nullptr, dc);
  if (color == nullptr) return nullptr;

  const UINT stride = size * 4;
  if (FAILED(conv->CopyPixels(nullptr, stride, stride * size,
                              static_cast<BYTE*>(bits)))) {
    ::DeleteObject(color);
    return nullptr;
  }
  if (is_template) {
    const BYTE ink = TaskbarIsLight() ? 0 : 255;
    auto* px = static_cast<BYTE*>(bits);
    for (UINT i = 0; i < size * size; ++i) {
      px[i * 4 + 0] = ink;
      px[i * 4 + 1] = ink;
      px[i * 4 + 2] = ink;
    }
  }

  HBITMAP mask = ::CreateBitmap(size, size, 1, 1, nullptr);
  ICONINFO ii{};
  ii.fIcon = TRUE;
  ii.hbmColor = color;
  ii.hbmMask = mask;
  HICON icon = ::CreateIconIndirect(&ii);
  ::DeleteObject(color);
  ::DeleteObject(mask);
  return icon;
}

}  // namespace

NativeTray::NativeTray(flutter::BinaryMessenger* messenger, HWND window)
    : window_(window) {
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "obsbot.bridge/tray",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    HandleMethodCall(call, std::move(result));
  });
  // Explorer broadcasts this after it restarts; every tray icon must be
  // re-added or it silently vanishes.
  taskbar_created_msg_ = ::RegisterWindowMessageW(L"TaskbarCreated");

  nid_.cbSize = sizeof(nid_);
  nid_.hWnd = window_;
  nid_.uID = kTrayId;
  nid_.uCallbackMessage = kTrayCallback;
  nid_.uVersion = NOTIFYICON_VERSION_4;
  wcscpy_s(nid_.szTip, L"Open OBSBOT Bridge");
}

NativeTray::~NativeTray() {
  Remove();
  if (icon_ != nullptr) ::DestroyIcon(icon_);
}

void NativeTray::EnsureAdded() {
  if (added_) return;
  nid_.uFlags = NIF_MESSAGE | NIF_TIP | NIF_SHOWTIP | (icon_ ? NIF_ICON : 0);
  nid_.hIcon = icon_;
  if (::Shell_NotifyIconW(NIM_ADD, &nid_)) {
    ::Shell_NotifyIconW(NIM_SETVERSION, &nid_);
    added_ = true;
  }
}

void NativeTray::Remove() {
  if (!added_) return;
  ::Shell_NotifyIconW(NIM_DELETE, &nid_);
  added_ = false;
}

void NativeTray::SetIconFromPng(const std::vector<uint8_t>& png,
                                bool is_template) {
  HICON icon = IconFromPng(png, is_template);
  if (icon == nullptr) return;
  if (icon_ != nullptr) ::DestroyIcon(icon_);
  icon_ = icon;
  nid_.hIcon = icon_;
  if (added_) {
    nid_.uFlags = NIF_ICON;
    ::Shell_NotifyIconW(NIM_MODIFY, &nid_);
  } else {
    EnsureAdded();
  }
}

void NativeTray::SetTooltip(const std::wstring& text) {
  wcsncpy_s(nid_.szTip, text.c_str(), _TRUNCATE);
  if (added_) {
    nid_.uFlags = NIF_TIP | NIF_SHOWTIP;
    ::Shell_NotifyIconW(NIM_MODIFY, &nid_);
  }
}

void NativeTray::SendClick(const std::string& key) {
  flutter::EncodableMap args{
      {flutter::EncodableValue("key"), flutter::EncodableValue(key)}};
  channel_->InvokeMethod("onMenuClick",
                         std::make_unique<flutter::EncodableValue>(args));
}

void NativeTray::ShowMenu() {
  HMENU menu = ::CreatePopupMenu();
  if (menu == nullptr) return;
  for (size_t i = 0; i < items_.size(); ++i) {
    const auto& it = items_[i];
    if (it.separator) {
      ::AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
    } else {
      UINT flags = MF_STRING | (it.disabled ? MF_GRAYED : 0);
      ::AppendMenuW(menu, flags, kFirstCommand + i, it.label.c_str());
    }
  }
  POINT pt;
  ::GetCursorPos(&pt);
  // Without this the menu does not close when the user clicks elsewhere
  // (documented TrackPopupMenu quirk for notification-area menus).
  ::SetForegroundWindow(window_);
  const UINT cmd = static_cast<UINT>(::TrackPopupMenu(
      menu, TPM_RETURNCMD | TPM_NONOTIFY | TPM_RIGHTBUTTON | TPM_BOTTOMALIGN,
      pt.x, pt.y, 0, window_, nullptr));
  ::PostMessage(window_, WM_NULL, 0, 0);
  ::DestroyMenu(menu);
  if (cmd >= kFirstCommand && cmd - kFirstCommand < items_.size()) {
    SendClick(items_[cmd - kFirstCommand].key);
  }
}

std::optional<LRESULT> NativeTray::HandleMessage(HWND hwnd, UINT message,
                                                 WPARAM wparam,
                                                 LPARAM lparam) {
  if (message == taskbar_created_msg_ && taskbar_created_msg_ != 0) {
    added_ = false;
    EnsureAdded();
    return std::nullopt;
  }
  if (message != kTrayCallback) return std::nullopt;
  // NOTIFYICON_VERSION_4: the event is in LOWORD(lparam).
  switch (LOWORD(lparam)) {
    case NIN_SELECT:
    case NIN_KEYSELECT:
      SendClick("show_window");
      break;
    case WM_CONTEXTMENU:
      ShowMenu();
      break;
  }
  return 0;
}

void NativeTray::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
  const std::string& method = call.method_name();

  if (method == "setIcon" && args != nullptr) {
    auto* bytes = Field(*args, "bytes");
    if (bytes != nullptr) {
      if (auto* v = std::get_if<std::vector<uint8_t>>(bytes)) {
        SetIconFromPng(*v, BoolField(*args, "isTemplate"));
      }
    }
    result->Success();
  } else if (method == "setTooltip" && args != nullptr) {
    SetTooltip(Utf16(StringField(*args, "text")));
    result->Success();
  } else if (method == "setTitle" && args != nullptr) {
    SetTooltip(Utf16(StringField(*args, "title")));
    EnsureAdded();
    result->Success();
  } else if (method == "setMenu" && args != nullptr) {
    items_.clear();
    auto* list = Field(*args, "items");
    if (list != nullptr) {
      if (auto* l = std::get_if<flutter::EncodableList>(list)) {
        for (const auto& e : *l) {
          auto* m = std::get_if<flutter::EncodableMap>(&e);
          if (m == nullptr) continue;
          Item item;
          item.separator = StringField(*m, "type") == "separator";
          item.key = StringField(*m, "key");
          item.label = Utf16(StringField(*m, "label"));
          item.disabled = BoolField(*m, "disabled");
          items_.push_back(std::move(item));
        }
      }
    }
    EnsureAdded();
    result->Success();
  } else if (method == "destroy") {
    Remove();
    result->Success();
  } else {
    result->NotImplemented();
  }
}
