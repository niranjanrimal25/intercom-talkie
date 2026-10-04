import AVFoundation
import Flutter
import UIKit

/// Native bridge for Talkie.
///
/// Implements the `intercom.native` method channel and the
/// `intercom.native/events` event channel that the Dart side expects
/// (mirroring the Kotlin implementation on Android).
@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var eventSink: FlutterEventSink?
  private var backgroundTaskId = UIBackgroundTaskIdentifier.invalid

  // -------------------------------------------------------------------
  // App lifecycle
  // -------------------------------------------------------------------

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    registerAudioObservers()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "IntercomTalkieNativeBridge") else { return }
    let messenger = registrar.messenger()

    let methodChannel = FlutterMethodChannel(name: "intercom.native", binaryMessenger: messenger)
    methodChannel.setMethodCallHandler { [weak self] call, result in
      self?.handleMethodCall(call, result: result)
    }

    let eventChannel = FlutterEventChannel(name: "intercom.native/events", binaryMessenger: messenger)
    eventChannel.setStreamHandler(self)
  }

  // -------------------------------------------------------------------
  // Method channel
  // -------------------------------------------------------------------

  private func handleMethodCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "startService":
      // iOS has no foreground service; keep the process alive with a
      // background task while audio runs. The audio background mode in
      // Info.plist does the heavy lifting.
      beginKeepAliveTask()
      result(nil)

    case "updateService":
      result(nil)

    case "stopService":
      endKeepAliveTask()
      result(nil)

    case "recoverAudio":
      recoverAudio(result: result)

    case "getAudioRoutes":
      result(audioRoutes())

    case "setAudioRoute":
      let id = (call.arguments as? [String: Any])?["id"] as? String ?? ""
      result(selectAudioRoute(id: id))

    case "setKeepScreenOn":
      let enabled = (call.arguments as? [String: Any])?["enabled"] as? Bool ?? false
      DispatchQueue.main.async {
        UIApplication.shared.isIdleTimerDisabled = enabled
      }
      result(nil)

    case "openHotspotSettings":
      // Apple does not allow deep-linking into the hotspot settings; open
      // the app's settings page as the closest safe destination.
      if let url = URL(string: UIApplication.openSettingsURLString) {
        UIApplication.shared.open(url)
      }
      result(nil)

    case "requestIgnoreBatteryOptimizations":
      result(false)

    case "platformInfo":
      var systemInfo = utsname()
      uname(&systemInfo)
      let machine = withUnsafeBytes(of: &systemInfo.machine) { raw in
        String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
      }
      let device = UIDevice.current
      result([
        "platform": device.systemName,
        "osVersion": "\(device.systemName) \(device.systemVersion)",
        "model": device.model + " (" + machine + ")",
      ])

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // -------------------------------------------------------------------
  // Audio session helpers
  // -------------------------------------------------------------------

  private var audioSession: AVAudioSession {
    AVAudioSession.sharedInstance()
  }

  private func recoverAudio(result: @escaping FlutterResult) {
    let session = audioSession
    do {
      try session.setCategory(
        .playAndRecord,
        mode: .voiceChat,
        options: [.allowBluetooth, .mixWithOthers]
      )
      try session.setActive(true)
      result(nil)
    } catch {
      // The WebRTC audio session manager retries activation as well.
      NSLog("IntercomTalkie: audio session recovery failed: \(error)")
      result(nil)
    }
  }

  private func routeType(for portType: AVAudioSession.Port) -> String {
    switch portType {
    case .bluetoothHFP, .bluetoothLE:
      return "bluetooth"
    case .headphones, .usbAudio, .carAudio:
      return "wired"
    case .builtInSpeaker:
      return "speaker"
    case .builtInMic, .builtInReceiver:
      return "builtin"
    default:
      return "unknown"
    }
  }

  private func friendlyName(for portType: AVAudioSession.Port) -> String {
    switch portType {
    case .bluetoothHFP: return "Bluetooth headset"
    case .bluetoothLE: return "Bluetooth LE headset"
    case .headphones: return "Wired headphones"
    case .usbAudio: return "USB audio"
    case .builtInSpeaker: return "Speakerphone"
    case .builtInMic: return "Built-in microphone"
    case .builtInReceiver: return "Earpiece"
    default: return "Audio device"
    }
  }

  private func audioRoutes() -> [[String: Any]] {
    let session = audioSession
    var routes = [[String: Any]]()
    let preferredInput = session.preferredInput?.uid

    let inputs = session.availableInputs ?? []
    for input in inputs {
      let type = routeType(for: input.portType)
      if type == "unknown" {
        continue
      }
      let name = input.portName.isEmpty ? friendlyName(for: input.portType) : input.portName
      routes.append([
        "id": input.uid,
        "name": name,
        "type": type,
        "selected": input.uid == preferredInput || (preferredInput == nil && input.uid == session.currentRoute.inputs.first?.uid),
      ])
    }

    // Always offer the loudspeaker as a selectable route.
    if !routes.contains(where: { ($0["type"] as? String) == "speaker" }) {
      routes.append([
        "id": "io:builtin-speaker",
        "name": "Speakerphone",
        "type": "speaker",
        "selected": session.currentRoute.outputs.contains { $0.portType == .builtInSpeaker },
      ])
    }
    return routes
  }

  /// Selects a Bluetooth headset as the preferred input the moment one
  /// shows up, so call audio flows through it with no user action.
  @discardableResult
  private func preferBluetoothInput() -> Bool {
    let session = audioSession
    guard
      let bluetooth = session.availableInputs?.first(where: {
        $0.portType == .bluetoothHFP || $0.portType == .bluetoothLE
      })
    else { return false }
    do {
      try session.setPreferredInput(bluetooth)
      try session.setActive(true)
      return true
    } catch {
      NSLog("IntercomTalkie: Bluetooth route failed: \(error)")
      return false
    }
  }

  private func selectAudioRoute(id: String) -> Bool {
    let session = audioSession
    if id == "io:builtin-speaker" {
      do {
        try session.overrideOutputAudioPort(.speaker)
        return true
      } catch {
        return false
      }
    }
    guard let inputs = session.availableInputs,
          let port = inputs.first(where: { $0.uid == id })
    else {
      return false
    }
    do {
      try session.setPreferredInput(port)
      return true
    } catch {
      NSLog("IntercomTalkie: setPreferredInput failed: \(error)")
      return false
    }
  }

  // -------------------------------------------------------------------
  // Audio notifications (interruptions = phone calls)
  // -------------------------------------------------------------------

  private func registerAudioObservers() {
    let center = NotificationCenter.default

    center.addObserver(
      forName: AVAudioSession.interruptionNotification,
      object: audioSession,
      queue: .main
    ) { [weak self] notification in
      guard
        let userInfo = notification.userInfo,
        let typeRaw = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
        let type = AVAudioSession.InterruptionType(rawValue: typeRaw)
      else { return }

      switch type {
      case .began:
        // A phone call, FaceTime, Siri... is taking over audio.
        self?.sendEvent("interruptionBegan")
      case .ended:
        // Re-activate the session immediately (the call that interrupted us
        // has released it); the Dart engine then re-asserts the whole audio
        // pipeline. Unconditional: the intercom must always come back.
        if let self = self {
          try? self.audioSession.setActive(true)
        }
        let optionsRaw = (userInfo[AVAudioSessionInterruptionOptionKey] as? UInt) ?? 0
        let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
        self?.sendEvent("interruptionEnded", options.contains(.shouldResume) ? "resume" : nil)
      @unknown default:
        break
      }
    }

    center.addObserver(
      forName: AVAudioSession.routeChangeNotification,
      object: audioSession,
      queue: .main
    ) { [weak self] notification in
      let reasonText: String
      if
        let userInfo = notification.userInfo,
        let reasonRaw = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
        let reason = AVAudioSession.RouteChangeReason(rawValue: reasonRaw)
      {
        switch reason {
        case .newDeviceAvailable:
          // A headset just connected — move call audio to it immediately.
          if let self = self, self.preferBluetoothInput() {
            reasonText = "bluetooth connected"
          } else {
            reasonText = "new device available"
          }
        case .oldDeviceUnavailable: reasonText = "old device unavailable"
        case .categoryChange: reasonText = "category change"
        case .override: reasonText = "override"
        case .wakeFromSleep: reasonText = "wake from sleep"
        case .noSuitableRouteForCategory: reasonText = "no suitable route"
        default: reasonText = "other"
        }
      } else {
        reasonText = "unknown"
      }
      let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        .map { "\($0.portName) (\($0.portType.rawValue))" }
        .joined(separator: ", ")
      self?.sendEvent("routeChanged", "\(reasonText): \(outputs)")
    }

    center.addObserver(
      forName: AVAudioSession.mediaServicesWereResetNotification,
      object: audioSession,
      queue: .main
    ) { [weak self] _ in
      // The media server crashed; audio must be fully restarted.
      self?.sendEvent("mediaServicesReset")
    }
  }

  private func sendEvent(_ type: String, _ data: String? = nil) {
    DispatchQueue.main.async { [weak self] in
      guard let sink = self?.eventSink else { return }
      var payload: [String: Any] = ["type": type]
      if let data = data {
        payload["data"] = data
      }
      sink(payload)
    }
  }

  // -------------------------------------------------------------------
  // Keep-alive background task
  // -------------------------------------------------------------------

  private func beginKeepAliveTask() {
    endKeepAliveTask()
    backgroundTaskId = UIApplication.shared.beginBackgroundTask(withName: "intercom-session") {
      // Expiration: the audio background mode should have taken over by
      // now; if not, end the task cleanly.
      self.endKeepAliveTask()
    }
  }

  private func endKeepAliveTask() {
    guard backgroundTaskId != UIBackgroundTaskIdentifier.invalid else { return }
    let id = backgroundTaskId
    backgroundTaskId = UIBackgroundTaskIdentifier.invalid
    UIApplication.shared.endBackgroundTask(id)
  }
}

// MARK: - FlutterEventChannel.StreamHandler

extension AppDelegate: FlutterStreamHandler {
  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    eventSink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }
}
