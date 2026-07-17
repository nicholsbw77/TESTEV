import ExternalAccessory
import Flutter

/// Bridges an MFi accessory's EASession streams to Flutter.
///
/// Method channel `testev/ea_accessory`:
///   listAccessories  -> [{name, manufacturer, modelNumber, protocols[]}]
///   declaredProtocols-> [String] from Info.plist UISupportedExternalAccessoryProtocols
///   connect{protocol}-> accessory name (opens EASession)
///   write{data}      -> queues bytes to the accessory
///   disconnect       -> closes the session
/// Event channel `testev/ea_accessory/stream`: incoming bytes as Uint8List.
public class EaAccessoryPlugin: NSObject, FlutterPlugin, FlutterStreamHandler, StreamDelegate {
  private var session: EASession?
  private var eventSink: FlutterEventSink?
  private var pendingWrite = Data()
  private var readBuf = [UInt8](repeating: 0, count: 4096)

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = EaAccessoryPlugin()
    let channel = FlutterMethodChannel(
      name: "testev/ea_accessory", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(instance, channel: channel)
    let events = FlutterEventChannel(
      name: "testev/ea_accessory/stream", binaryMessenger: registrar.messenger())
    events.setStreamHandler(instance)
    EAAccessoryManager.shared().registerForLocalNotifications()
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "listAccessories":
      let list = EAAccessoryManager.shared().connectedAccessories.map { a -> [String: Any] in
        [
          "name": a.name,
          "manufacturer": a.manufacturer,
          "modelNumber": a.modelNumber,
          "protocols": a.protocolStrings,
        ]
      }
      result(list)

    case "declaredProtocols":
      let declared =
        Bundle.main.object(forInfoDictionaryKey: "UISupportedExternalAccessoryProtocols")
        as? [String] ?? []
      result(declared)

    case "connect":
      guard let args = call.arguments as? [String: Any],
        let proto = args["protocol"] as? String
      else {
        result(FlutterError(code: "bad_args", message: "protocol required", details: nil))
        return
      }
      closeSession()
      guard
        let accessory = EAAccessoryManager.shared().connectedAccessories
          .first(where: { $0.protocolStrings.contains(proto) })
      else {
        result(FlutterError(
          code: "not_found",
          message: "No connected accessory advertises \(proto)", details: nil))
        return
      }
      guard let s = EASession(accessory: accessory, forProtocol: proto) else {
        result(FlutterError(
          code: "session_failed",
          message:
            "EASession failed for \(proto) — is it listed in UISupportedExternalAccessoryProtocols?",
          details: nil))
        return
      }
      session = s
      if let input = s.inputStream {
        input.delegate = self
        input.schedule(in: .main, forMode: .common)
        input.open()
      }
      if let output = s.outputStream {
        output.delegate = self
        output.schedule(in: .main, forMode: .common)
        output.open()
      }
      result(accessory.name)

    case "write":
      guard let args = call.arguments as? [String: Any],
        let data = args["data"] as? FlutterStandardTypedData
      else {
        result(FlutterError(code: "bad_args", message: "data required", details: nil))
        return
      }
      pendingWrite.append(data.data)
      flushWrite()
      result(nil)

    case "disconnect":
      closeSession()
      result(nil)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func flushWrite() {
    guard let output = session?.outputStream else { return }
    while output.hasSpaceAvailable && !pendingWrite.isEmpty {
      let written = pendingWrite.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> Int in
        guard let base = ptr.bindMemory(to: UInt8.self).baseAddress else { return 0 }
        return output.write(base, maxLength: pendingWrite.count)
      }
      if written > 0 {
        pendingWrite.removeFirst(written)
      } else {
        break
      }
    }
  }

  private func closeSession() {
    if let s = session {
      s.inputStream?.close()
      s.inputStream?.remove(from: .main, forMode: .common)
      s.inputStream?.delegate = nil
      s.outputStream?.close()
      s.outputStream?.remove(from: .main, forMode: .common)
      s.outputStream?.delegate = nil
    }
    session = nil
    pendingWrite.removeAll()
  }

  // MARK: - StreamDelegate

  public func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
    switch eventCode {
    case .hasBytesAvailable:
      guard let input = session?.inputStream else { return }
      while input.hasBytesAvailable {
        let n = input.read(&readBuf, maxLength: readBuf.count)
        if n > 0 {
          eventSink?(FlutterStandardTypedData(bytes: Data(readBuf[0..<n])))
        } else {
          break
        }
      }
    case .hasSpaceAvailable:
      flushWrite()
    case .errorOccurred, .endEncountered:
      eventSink?(
        FlutterError(code: "stream_closed", message: "accessory stream ended", details: nil))
      closeSession()
    default:
      break
    }
  }

  // MARK: - FlutterStreamHandler

  public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink)
    -> FlutterError?
  {
    eventSink = events
    return nil
  }

  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }
}
