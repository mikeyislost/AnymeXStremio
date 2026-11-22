// Yumori / AnymeX+ for LG TVs: the webOS runner.
//
// Replaces the main.cc that `flutter-webos create` makes (the TV workflow
// copies this file over webos/runner/main.cc). Same as LG's template, plus:
//
// - The remote's Back button. LG's SDK doesn't hand Back to Flutter apps yet
//   (github.com/lg-flutter-webos/flutter-webos/issues/12): webOS shows its own
//   "exit app?" popup instead. webOS gives Back to an app whose window has the
//   property _WEBOS_ACCESS_POLICY_KEYS_BACK = "true" (what LG's web app
//   manager sets for web apps with disableBackHistoryAPI). LG's view wrapper
//   can set window properties, so the runner sets it as soon as the window
//   exists.
// - A channel, "yumori/webos", so the app can set it again later (on/off from
//   Settings) and read what the runner did. Plain UTF-8 text both ways (Dart
//   side: BasicMessageChannel with StringCodec), on LG's C messenger API (the
//   C++ channel/codec helpers aren't linked into the runner):
//     "set\n<name>\n<value>" -> "ok" | "no window"
//     "log"                   -> the runner's notes, one per line

#include <flutter_messenger.h>
#include <flutter_plugin_registrar.h>
#include <flutter_window.h>

#include <ctime>
#include <memory>
#include <string>
#include <vector>

#include "flutter/generated_plugin_registrant.h"

namespace {

constexpr char kBackProperty[] = "_WEBOS_ACCESS_POLICY_KEYS_BACK";

std::vector<std::string>& Log() {
  static std::vector<std::string> lines;
  return lines;
}

void AddLog(const std::string& line) {
  std::time_t now = std::time(nullptr);
  char stamp[16] = {0};
  std::strftime(stamp, sizeof(stamp), "%H:%M:%S", std::localtime(&now));
  auto& lines = Log();
  lines.push_back(std::string(stamp) + "  " + line);
  if (lines.size() > 20) lines.erase(lines.begin());
}

std::string Join(const std::vector<std::string>& lines) {
  std::string out;
  for (const auto& l : lines) {
    if (!out.empty()) out += "\n";
    out += l;
  }
  return out;
}

}  // namespace

class App : public FlutterWindow {
 public:
  bool OnCreate() override {
    if (!FlutterWindow::OnCreate()) return false;
    RegisterPlugins(GetRegistrar());
    SetProperty(kBackProperty, "true");
    StartChannel();
    return true;
  }

  void OnDestroy() override {
    if (messenger_) {
      FlutterDesktopMessengerSetCallback(messenger_, "yumori/webos", nullptr,
                                         nullptr);
      messenger_ = nullptr;
    }
    controller_ = nullptr;
    FlutterWindow::OnDestroy();
  }

 protected:
  std::unique_ptr<flutter::FlutterViewController> CreateController(
      const flutter::FlutterViewController::ViewProperties& vp,
      const flutter::DartProject& project,
      const std::vector<std::string>& engine_switches) override {
    auto controller =
        FlutterWindow::CreateController(vp, project, engine_switches);
    controller_ = controller.get();
    return controller;
  }

 private:
  bool SetProperty(const std::string& name, const std::string& value) {
    if (!controller_ || !controller_->view()) {
      AddLog("no window yet: " + name + "=" + value + " not set");
      return false;
    }
    controller_->view()->SetWindowProperty(name, value);
    AddLog("set " + name + "=" + value);
    return true;
  }

  void StartChannel() {
    if (!controller_ || !controller_->engine()) {
      AddLog("no engine: channel not started");
      return;
    }
    FlutterDesktopPluginRegistrarRef registrar =
        controller_->engine()->GetRegistrarForPlugin("YumoriWebos");
    messenger_ =
        registrar ? FlutterDesktopPluginRegistrarGetMessenger(registrar) : nullptr;
    if (!messenger_) {
      AddLog("no messenger: channel not started");
      return;
    }
    FlutterDesktopMessengerSetCallback(messenger_, "yumori/webos", &App::OnMessage,
                                       this);
    AddLog("channel yumori/webos ready");
  }

  static void OnMessage(FlutterDesktopMessengerRef messenger,
                        const FlutterDesktopMessage* message, void* user_data) {
    auto* self = static_cast<App*>(user_data);
    std::string text;
    if (message->message && message->message_size > 0) {
      text.assign(reinterpret_cast<const char*>(message->message),
                  message->message_size);
    }
    std::string reply;
    if (text == "log") {
      reply = Join(Log());
    } else if (text.rfind("set\n", 0) == 0) {
      const auto nl = text.find('\n', 4);
      if (nl == std::string::npos) {
        reply = "bad message";
      } else {
        const std::string name = text.substr(4, nl - 4);
        const std::string value = text.substr(nl + 1);
        reply = self->SetProperty(name, value) ? "ok" : "no window";
      }
    } else {
      reply = "unknown";
    }
    if (message->response_handle) {
      FlutterDesktopMessengerSendResponse(
          messenger, message->response_handle,
          reinterpret_cast<const uint8_t*>(reply.data()), reply.size());
    }
  }

  flutter::FlutterViewController* controller_ = nullptr;
  FlutterDesktopMessengerRef messenger_ = nullptr;
};

int main(int argc, char** argv) {
  App app;
  return app.Run(argc, argv);
}
