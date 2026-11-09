import Flutter
import UIKit
import AVFoundation
import AVKit

@UIApplicationMain
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    let controller = window?.rootViewController as! FlutterViewController
    let channel = FlutterMethodChannel(name: "com.anymex.app/thumbnail", binaryMessenger: controller.binaryMessenger)

    cleanupOldThumbnails()
    PlusAirPlay.shared.register(messenger: controller.binaryMessenger) // AnymeX+

    channel.setMethodCallHandler { (call: FlutterMethodCall, result: @escaping FlutterResult) in
      if call.method == "getVideoThumbnail" {
        guard let args = call.arguments as? [String: Any],
              let videoPath = args["videoPath"] as? String else {
          result(FlutterError(code: "INVALID_ARGUMENT", message: "videoPath is null", details: nil))
          return
        }
        self.extractThumbnail(videoPath: videoPath, result: result)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  private func extractThumbnail(videoPath: String, result: @escaping FlutterResult) {
    DispatchQueue.global(qos: .userInitiated).async {
      let url = URL(fileURLWithPath: videoPath)
      let asset = AVAsset(url: url)
      let generator = AVAssetImageGenerator(asset: asset)
      generator.appliesPreferredTrackTransform = true
      generator.maximumSize = CGSize(width: 320, height: 240)

      let durationSeconds = CMTimeGetSeconds(asset.duration)
      let targetSeconds: Double
      if durationSeconds > 60 {
        targetSeconds = min(30.0, durationSeconds * 0.10)
      } else if durationSeconds > 10 {
        targetSeconds = min(5.0, durationSeconds * 0.10)
      } else if durationSeconds > 0 {
        targetSeconds = max(0.5, durationSeconds * 0.10)
      } else {
        targetSeconds = 1.0
      }

      let time = CMTime(seconds: targetSeconds, preferredTimescale: 60)
      do {
        let cgImage = try generator.copyCGImage(at: time, actualTime: nil)
        let uiImage = UIImage(cgImage: cgImage)
        if let data = uiImage.jpegData(compressionQuality: 0.85) {
          let tempDir = NSTemporaryDirectory()
          let fileName = "thumb_\(Int(Date().timeIntervalSince1970))_\(UUID().uuidString).jpg"
          let filePath = (tempDir as NSString).appendingPathComponent(fileName)
          try data.write(to: URL(fileURLWithPath: filePath))

          DispatchQueue.main.async { result(filePath) }
          return
        }
      } catch {
        DispatchQueue.main.async {
          result(FlutterError(code: "EXTRACTION_FAILED", message: error.localizedDescription, details: nil))
        }
      }
    }
  }

  private func cleanupOldThumbnails() {
    DispatchQueue.global(qos: .background).async {
      let tempDir = NSTemporaryDirectory()
      let fileManager = FileManager.default
      guard let files = try? fileManager.contentsOfDirectory(atPath: tempDir) else { return }
      let now = Date().timeIntervalSince1970
      for file in files where file.hasPrefix("thumb_") && file.hasSuffix(".jpg") {
        let path = (tempDir as NSString).appendingPathComponent(file)
        if let attrs = try? fileManager.attributesOfItem(atPath: path),
           let modDate = attrs[.modificationDate] as? Date,
           now - modDate.timeIntervalSince1970 > 86400 {
          try? fileManager.removeItem(atPath: path)
        }
      }
    }
  }
}

// MARK: - AnymeX+: AirPlay and cast device search
// Apple's player handles AirPlay (mpv can't); Bonjour finds Chromecasts
// without the multicast entitlement sideloaded apps don't get.

final class PlusAirPlayViewController: AVPlayerViewController {
  var onClose: (() -> Void)?
  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    if isBeingDismissed { onClose?(); onClose = nil }
  }
}

final class PlusAirPlay: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
  static let shared = PlusAirPlay()
  private var player: AVPlayer?
  private var statusObserver: NSKeyValueObservation?
  private var pending: FlutterResult?
  private var timeout: DispatchWorkItem?
  private var browser: NetServiceBrowser?
  private var services: [NetService] = []
  private var found: [[String: Any]] = []

  func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "anymexplus/airplay", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      switch call.method {
      case "play": self.play(call.arguments as? [String: Any] ?? [:], result: result)
      case "findChromecasts": self.findChromecasts(result: result)
      default: result(FlutterMethodNotImplemented)
      }
    }
  }

  // MARK: AirPlay

  private func play(_ args: [String: Any], result: @escaping FlutterResult) {
    guard pending == nil, player == nil else {
      result(FlutterError(code: "busy", message: "AirPlay is already open", details: nil)); return
    }
    guard let raw = args["url"] as? String, !raw.isEmpty else {
      result(FlutterError(code: "no_url", message: "No video", details: nil)); return
    }
    let url: URL? = raw.hasPrefix("/") ? URL(fileURLWithPath: raw) : URL(string: raw)
    guard let videoUrl = url else {
      result(FlutterError(code: "no_url", message: "Bad video address", details: nil)); return
    }
    var options: [String: Any] = [:]
    if let headers = args["headers"] as? [String: String], !headers.isEmpty {
      options["AVURLAssetHTTPHeaderFieldsKey"] = headers
    }
    let startMs = (args["positionMs"] as? NSNumber)?.doubleValue ?? 0
    let title = args["title"] as? String

    try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
    try? AVAudioSession.sharedInstance().setActive(true)

    let item = AVPlayerItem(asset: AVURLAsset(url: videoUrl, options: options))
    if let title = title, !title.isEmpty {
      let meta = AVMutableMetadataItem()
      meta.identifier = .commonIdentifierTitle
      meta.value = title as NSString
      meta.extendedLanguageTag = "und"
      item.externalMetadata = [meta]
    }
    let player = AVPlayer(playerItem: item)
    player.allowsExternalPlayback = true
    player.usesExternalPlaybackWhileExternalScreenIsActive = true
    self.player = player
    pending = result

    let work = DispatchWorkItem { [weak self] in
      self?.fail(code: "timeout", message: "The video took too long to load")
    }
    timeout = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 25, execute: work)

    statusObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
      DispatchQueue.main.async {
        guard let self = self else { return }
        switch item.status {
        case .readyToPlay: self.present(startMs: startMs)
        case .failed:
          self.fail(code: "unsupported",
                    message: item.error?.localizedDescription ?? "This video can't be played with AirPlay")
        default: break
        }
      }
    }
  }

  private func fail(code: String, message: String) {
    timeout?.cancel(); timeout = nil
    statusObserver = nil
    player?.pause(); player = nil
    if let r = pending { pending = nil; r(FlutterError(code: code, message: message, details: nil)) }
  }

  private func topController() -> UIViewController? {
    var top = UIApplication.shared.connectedScenes
      .compactMap { ($0 as? UIWindowScene)?.windows.first(where: { $0.isKeyWindow }) }
      .first?.rootViewController
    while let next = top?.presentedViewController { top = next }
    return top
  }

  private func present(startMs: Double) {
    guard let player = player, pending != nil else { return }
    timeout?.cancel(); timeout = nil
    statusObserver = nil
    if startMs > 1000 {
      player.seek(to: CMTime(seconds: startMs / 1000, preferredTimescale: 600))
    }
    let vc = PlusAirPlayViewController()
    vc.player = player
    vc.modalPresentationStyle = .fullScreen
    vc.allowsPictureInPicturePlayback = false
    vc.onClose = { [weak self] in self?.closed() }
    guard let host = topController() else {
      fail(code: "no_view", message: "Couldn't open the player"); return
    }
    host.present(vc, animated: true) {
      player.play()
      // Open the AirPlay device list straight away.
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
        let picker = AVRoutePickerView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        picker.alpha = 0.01
        vc.view.addSubview(picker)
        if let button = picker.subviews.compactMap({ $0 as? UIButton }).first {
          button.sendActions(for: .touchUpInside)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { picker.removeFromSuperview() }
      }
    }
  }

  private func closed() {
    guard let player = player else { return }
    let seconds = player.currentTime().seconds
    player.pause()
    self.player = nil
    let ms = seconds.isFinite ? Int(seconds * 1000) : 0
    if let r = pending { pending = nil; r(["positionMs": ms]) }
  }

  // MARK: Chromecast search (Bonjour)

  private func findChromecasts(result: @escaping FlutterResult) {
    browser?.stop()
    services = []
    found = []
    let b = NetServiceBrowser()
    b.delegate = self
    browser = b
    b.searchForServices(ofType: "_googlecast._tcp.", inDomain: "local.")
    DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
      guard let self = self else { return }
      self.browser?.stop(); self.browser = nil
      result(self.found)
    }
  }

  func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
    services.append(service)
    service.delegate = self
    service.resolve(withTimeout: 3)
  }

  func netServiceDidResolveAddress(_ sender: NetService) {
    guard let addresses = sender.addresses else { return }
    var name = sender.name
    if let txt = sender.txtRecordData() {
      let dict = NetService.dictionary(fromTXTRecord: txt)
      if let fn = dict["fn"], let s = String(data: fn, encoding: .utf8), !s.isEmpty { name = s }
    }
    for data in addresses {
      let host: String? = data.withUnsafeBytes { ptr in
        guard let sa = ptr.baseAddress?.assumingMemoryBound(to: sockaddr.self),
              sa.pointee.sa_family == sa_family_t(AF_INET) else { return nil }
        var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(sa, socklen_t(data.count), &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0
        else { return nil }
        return String(cString: buf)
      }
      if let host = host, !found.contains(where: { ($0["host"] as? String) == host }) {
        found.append(["name": name, "host": host, "port": sender.port > 0 ? sender.port : 8009])
      }
    }
  }
}
