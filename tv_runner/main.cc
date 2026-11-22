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
//   Settings) and read what the runner did:
//     setWindowProperty {name, value} -> true
//     log -> [String]

#include <flutter_window.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <chrono>
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

const std::string* StringArg(const flutter::EncodableMap& args,
                             const char* key) {
  auto it = args.find(flutter::EncodableValue(key));
  if (it == args.end()) return nullptr;
  return std::get_if<std::string>(&it->second);
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
    channel_.reset();
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
    channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
        controller_->engine()->messenger(), "yumori/webos",
        &flutter::StandardMethodCodec::GetInstance());
    channel_->SetMethodCallHandler(
        [this](const flutter::MethodCall<flutter::EncodableValue>& call,
               std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                   result) {
          if (call.method_name() == "setWindowProperty") {
            const auto* args =
                std::get_if<flutter::EncodableMap>(call.arguments());
            const std::string* name = args ? StringArg(*args, "name") : nullptr;
            const std::string* value =
                args ? StringArg(*args, "value") : nullptr;
            if (!name || !value) {
              result->Error("args", "name and value (strings) are needed");
              return;
            }
            result->Success(flutter::EncodableValue(SetProperty(*name, *value)));
            return;
          }
          if (call.method_name() == "log") {
            flutter::EncodableList list;
            for (const auto& line : Log()) list.emplace_back(line);
            result->Success(flutter::EncodableValue(list));
            return;
          }
          result->NotImplemented();
        });
    AddLog("channel yumori/webos ready");
  }

  flutter::FlutterViewController* controller_ = nullptr;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

int main(int argc, char** argv) {
  App app;
  return app.Run(argc, argv);
}
