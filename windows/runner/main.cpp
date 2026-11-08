#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>
#include <string>
#include "flutter_window.h"
#include "utils.h"
#include "app_links/app_links_plugin_c_api.h"

// AnymeX+: keep the sign-in browser's (WebView2) data in the user's own
// folder, %LOCALAPPDATA%\<kWebViewDataFolder>\WebView2. By default WebView2
// puts it next to anymex.exe, which isn't writable when the app is installed
// for all users (Program Files), so sign-in windows open black ("Cannot
// create the InAppWebView instance").
static const wchar_t kWebViewDataFolder[] = L"AnymeXStremio";

static void UseUserWebViewFolder() {
  wchar_t existing[2];
  if (::GetEnvironmentVariableW(L"WEBVIEW2_USER_DATA_FOLDER", existing, 2) > 0) {
    return;
  }
  wchar_t local[MAX_PATH];
  const DWORD len = ::GetEnvironmentVariableW(L"LOCALAPPDATA", local, MAX_PATH);
  if (len == 0 || len >= MAX_PATH) {
    return;
  }
  std::wstring dir = std::wstring(local) + L"\\" + kWebViewDataFolder;
  ::CreateDirectoryW(dir.c_str(), nullptr);
  dir += L"\\WebView2";
  ::CreateDirectoryW(dir.c_str(), nullptr);
  ::SetEnvironmentVariableW(L"WEBVIEW2_USER_DATA_FOLDER", dir.c_str());
}

bool SendAppLinkToInstance(const std::wstring& title) {
  // Find our exact window
  HWND hwnd = ::FindWindow(L"FLUTTER_RUNNER_WIN32_WINDOW", title.c_str());

  if (hwnd) {
    // Dispatch new link to current window
    SendAppLink(hwnd);

    // (Optional) Restore our window to front in same state
    WINDOWPLACEMENT place = { sizeof(WINDOWPLACEMENT) };
    GetWindowPlacement(hwnd, &place);

    switch(place.showCmd) {
      case SW_SHOWMAXIMIZED:
          ShowWindow(hwnd, SW_SHOWMAXIMIZED);
          break;
      case SW_SHOWMINIMIZED:
          ShowWindow(hwnd, SW_RESTORE);
          break;
      default:
          ShowWindow(hwnd, SW_NORMAL);
          break;
    }

    SetWindowPos(0, HWND_TOP, 0, 0, 0, 0, SWP_SHOWWINDOW | SWP_NOSIZE | SWP_NOMOVE);
    SetForegroundWindow(hwnd);
    // END (Optional) Restore

    // Window has been found, don't create another one.
    return true;
  }

  return false;
}

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  if (SendAppLinkToInstance(L"AnymeX")) {
    return EXIT_SUCCESS;
  }
  UseUserWebViewFolder();
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");
  project.set_ui_thread_policy(flutter::UIThreadPolicy::RunOnSeparateThread);

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"AnymeX", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
