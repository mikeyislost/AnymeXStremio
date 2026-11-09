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
// AirPlay: a hidden AVPlayer sends the video to the TV (mpv can't) and the
// app's own controls drive it. Bonjour finds Chromecasts and AirPlay TVs
// without the multicast entitlement sideloaded apps don't get.

final class PlusBonjourSearch: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
  private let browser = NetServiceBrowser()
  private var services: [NetService] = []
  private(set) var found: [[String: Any]] = []

  func run(type: String, seconds: Double, done: @escaping ([[String: Any]]) -> Void) {
    browser.delegate = self
    browser.searchForServices(ofType: type, inDomain: "local.")
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [self] in
      browser.stop()
      services.forEach { $0.stop() }
      done(found)
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
        found.append(["name": name, "host": host, "port": sender.port])
      }
    }
  }
}

final class PlusAirPlay: NSObject {
  static let shared = PlusAirPlay()
  private var player: AVPlayer?
  private var statusObserver: NSKeyValueObservation?
  private var externalObserver: NSKeyValueObservation?
  private var pending: FlutterResult?
  private var timeout: DispatchWorkItem?
  private var wasExternal = false
  private var searches: [PlusBonjourSearch] = []

  func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "anymexplus/airplay", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      let args = call.arguments as? [String: Any] ?? [:]
      switch call.method {
      case "start": self.start(args, result: result)
      case "status": result(self.status())
      case "play": self.player?.play(); result(nil)
      case "pause": self.player?.pause(); result(nil)
      case "seek":
        let ms = (args["positionMs"] as? NSNumber)?.doubleValue ?? 0
        self.player?.seek(to: CMTime(seconds: ms / 1000, preferredTimescale: 600))
        result(nil)
      case "pickRoute": self.showRoutePicker(); result(nil)
      case "stop": result(self.stop())
      case "findChromecasts": self.search(type: "_googlecast._tcp.", result: result)
      case "findAirPlay": self.search(type: "_airplay._tcp.", result: result)
      default: result(FlutterMethodNotImplemented)
      }
    }
  }

  private func search(type: String, result: @escaping FlutterResult) {
    let s = PlusBonjourSearch()
    searches.append(s)
    s.run(type: type, seconds: 3.5) { [weak self] found in
      self?.searches.removeAll { $0 === s }
      result(found)
    }
  }

  // MARK: AirPlay

  private func start(_ args: [String: Any], result: @escaping FlutterResult) {
    _ = stop()
    guard let raw = args["url"] as? String, !raw.isEmpty,
          let url = raw.hasPrefix("/") ? URL(fileURLWithPath: raw) : URL(string: raw) else {
      result(FlutterError(code: "no_url", message: "No video", details: nil)); return
    }
    var options: [String: Any] = [:]
    if let headers = args["headers"] as? [String: String], !headers.isEmpty {
      options["AVURLAssetHTTPHeaderFieldsKey"] = headers
    }
    let startMs = (args["positionMs"] as? NSNumber)?.doubleValue ?? 0

    try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
    try? AVAudioSession.sharedInstance().setActive(true)

    let item = AVPlayerItem(asset: AVURLAsset(url: url, options: options))
    if let title = args["title"] as? String, !title.isEmpty {
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
    wasExternal = false
    pending = result

    let work = DispatchWorkItem { [weak self] in
      self?.fail(code: "timeout", message: "The video took too long to load")
    }
    timeout = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 25, execute: work)

    statusObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
      DispatchQueue.main.async {
        guard let self = self, self.player?.currentItem === item else { return }
        switch item.status {
        case .readyToPlay: self.ready(startMs: startMs)
        case .failed:
          self.fail(code: "unsupported",
                    message: item.error?.localizedDescription ?? "This video can't be played with AirPlay")
        default: break
        }
      }
    }
    // Play once the TV is picked; pause if the TV disconnects.
    externalObserver = player.observe(\.isExternalPlaybackActive, options: [.new]) { [weak self] p, _ in
      DispatchQueue.main.async {
        guard let self = self, self.player === p else { return }
        if p.isExternalPlaybackActive {
          self.wasExternal = true
          p.play()
        } else if self.wasExternal {
          p.pause()
        }
      }
    }
  }

  private func ready(startMs: Double) {
    guard let player = player, let r = pending else { return }
    pending = nil
    timeout?.cancel(); timeout = nil
    statusObserver = nil
    if startMs > 1000 {
      player.seek(to: CMTime(seconds: startMs / 1000, preferredTimescale: 600))
    }
    r(true)
    if player.isExternalPlaybackActive {
      wasExternal = true
      player.play()
    } else {
      showRoutePicker()
    }
  }

  private func fail(code: String, message: String) {
    timeout?.cancel(); timeout = nil
    statusObserver = nil
    externalObserver = nil
    player?.pause(); player = nil
    if let r = pending { pending = nil; r(FlutterError(code: code, message: message, details: nil)) }
  }

  private func status() -> [String: Any] {
    guard let p = player else { return ["active": false] }
    let pos = p.currentTime().seconds
    let dur = p.currentItem?.duration.seconds ?? 0
    let route = AVAudioSession.sharedInstance().currentRoute.outputs
      .first(where: { $0.portType == .airPlay })?.portName
    return [
      "active": true,
      "external": p.isExternalPlaybackActive,
      "playing": p.rate > 0,
      "positionMs": pos.isFinite ? Int(pos * 1000) : 0,
      "durationMs": dur.isFinite ? Int(dur * 1000) : 0,
      "route": route ?? "",
    ]
  }

  private func stop() -> Int {
    timeout?.cancel(); timeout = nil
    statusObserver = nil
    externalObserver = nil
    guard let p = player else { return 0 }
    let s = p.currentTime().seconds
    p.pause()
    p.replaceCurrentItem(with: nil)
    player = nil
    // Back to iOS's default so the app's own player doesn't keep playing in the background.
    try? AVAudioSession.sharedInstance().setCategory(.soloAmbient)
    if let r = pending { pending = nil; r(FlutterError(code: "stopped", message: "Stopped", details: nil)) }
    return s.isFinite ? Int(s * 1000) : 0
  }

  private func showRoutePicker() {
    var top = UIApplication.shared.connectedScenes
      .compactMap { ($0 as? UIWindowScene)?.windows.first(where: { $0.isKeyWindow }) }
      .first?.rootViewController
    while let next = top?.presentedViewController { top = next }
    guard let view = top?.view else { return }
    let picker = AVRoutePickerView(frame: CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1))
    picker.prioritizesVideoDevices = true
    picker.alpha = 0.01
    view.addSubview(picker)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
      picker.subviews.compactMap { $0 as? UIButton }.first?.sendActions(for: .touchUpInside)
      DispatchQueue.main.asyncAfter(deadline: .now() + 1) { picker.removeFromSuperview() }
    }
  }
}
