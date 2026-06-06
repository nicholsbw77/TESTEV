import Flutter
import UIKit
import CoreBluetooth
import ExternalAccessory

class BluetoothSppPlugin: NSObject, FlutterPlugin, FlutterStreamHandler,
                           CBCentralManagerDelegate, CBPeripheralDelegate,
                           EAAccessoryDelegate, StreamDelegate {

    static let METHOD_CHANNEL = "testev/bluetooth"
    static let EVENT_CHANNEL = "testev/bluetooth/data"

    // BLE UART service/characteristic UUIDs (common for ELM327 BLE adapters)
    static let UART_SERVICE_UUID = CBUUID(string: "FFE0")
    static let UART_TX_CHAR_UUID = CBUUID(string: "FFE1")

    // OBDLink MFi protocol string
    static let OBDLINK_PROTOCOL = "com.obdsol.obdlink"

    private var channel: FlutterMethodChannel?
    private var eventSink: FlutterEventSink?

    // CoreBluetooth (BLE ELM327)
    private var centralManager: CBCentralManager?
    private var connectedPeripheral: CBPeripheral?
    private var txCharacteristic: CBCharacteristic?
    private var discoveredPeripherals: [(CBPeripheral, NSNumber)] = []
    private var scanResult: FlutterResult?
    private var connectResult: FlutterResult?

    // ExternalAccessory (MFi OBDLink)
    private var eaSession: EASession?
    private var eaAccessory: EAAccessory?
    private var inputStream: InputStream?
    private var outputStream: OutputStream?
    private var readBuffer = Data()

    private var isConnectedFlag = false
    private var connectionMode: ConnectionMode = .none

    enum ConnectionMode {
        case none
        case ble
        case mfi
    }

    static func register(with registrar: FlutterPluginRegistrar) {
        let instance = BluetoothSppPlugin()
        let methodChannel = FlutterMethodChannel(
            name: METHOD_CHANNEL,
            binaryMessenger: registrar.messenger()
        )
        let eventChannel = FlutterEventChannel(
            name: EVENT_CHANNEL,
            binaryMessenger: registrar.messenger()
        )
        instance.channel = methodChannel
        registrar.addMethodCallDelegate(instance, channel: methodChannel)
        eventChannel.setStreamHandler(instance)
    }

    // MARK: - FlutterPlugin

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "scan":
            scan(result: result)
        case "connect":
            guard let args = call.arguments as? [String: Any],
                  let address = args["address"] as? String else {
                result(FlutterError(code: "INVALID", message: "Missing address", details: nil))
                return
            }
            connect(address: address, result: result)
        case "disconnect":
            disconnect(result: result)
        case "send":
            guard let args = call.arguments as? [String: Any],
                  let data = args["data"] as? FlutterStandardTypedData else {
                result(FlutterError(code: "INVALID", message: "Missing data", details: nil))
                return
            }
            send(data: data.data, result: result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - FlutterStreamHandler

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self.eventSink = events
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        self.eventSink = nil
        return nil
    }

    // MARK: - Scan

    private func scan(result: @escaping FlutterResult) {
        var devices: [[String: Any]] = []

        // MFi accessories (OBDLink via ExternalAccessory)
        let accessories = EAAccessoryManager.shared().connectedAccessories
        for acc in accessories {
            if acc.protocolStrings.contains(BluetoothSppPlugin.OBDLINK_PROTOCOL) ||
               acc.name.contains("OBDLink") || acc.name.contains("ELM327") {
                devices.append([
                    "name": acc.name,
                    "address": "mfi:\(acc.connectionID)",
                    "rssi": 0
                ])
            }
        }

        // BLE scan — quick scan for nearby BLE ELM327 devices
        if centralManager == nil {
            centralManager = CBCentralManager(delegate: self, queue: nil)
        }

        // If BLE is ready, do a quick scan
        if centralManager?.state == .poweredOn {
            discoveredPeripherals.removeAll()
            scanResult = nil
            centralManager?.scanForPeripherals(
                withServices: [BluetoothSppPlugin.UART_SERVICE_UUID],
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
            )

            // Stop scan after 3 seconds and return results
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                guard let self = self else { return }
                self.centralManager?.stopScan()

                for (peripheral, rssi) in self.discoveredPeripherals {
                    devices.append([
                        "name": peripheral.name ?? "BLE Device",
                        "address": "ble:\(peripheral.identifier.uuidString)",
                        "rssi": rssi.intValue
                    ])
                }
                result(devices)
            }
        } else {
            // BLE not ready, return MFi results only
            result(devices)
        }
    }

    // MARK: - Connect

    private func connect(address: String, result: @escaping FlutterResult) {
        if address.hasPrefix("mfi:") {
            connectMfi(connectionId: address, result: result)
        } else if address.hasPrefix("ble:") {
            let uuid = String(address.dropFirst(4))
            connectBle(uuid: uuid, result: result)
        } else {
            // Try MFi first, fall back to BLE
            let accessories = EAAccessoryManager.shared().connectedAccessories
            let match = accessories.first { acc in
                acc.name.contains("OBDLink") || acc.name.contains("ELM327")
            }
            if let acc = match {
                connectMfi(accessory: acc, result: result)
            } else {
                connectBle(uuid: address, result: result)
            }
        }
    }

    private func connectMfi(connectionId: String? = nil, accessory: EAAccessory? = nil, result: @escaping FlutterResult) {
        var acc = accessory
        if acc == nil, let connId = connectionId {
            let idStr = connId.replacingOccurrences(of: "mfi:", with: "")
            if let id = Int(idStr) {
                acc = EAAccessoryManager.shared().connectedAccessories.first {
                    $0.connectionID == id
                }
            }
        }

        guard let accessory = acc else {
            result(FlutterError(code: "NOT_FOUND", message: "MFi accessory not found", details: nil))
            return
        }

        // Find a supported protocol
        let protocol_ = accessory.protocolStrings.first {
            $0.contains("obdlink") || $0.contains("spp") || $0.contains("com.")
        } ?? accessory.protocolStrings.first ?? ""

        guard !protocol_.isEmpty else {
            result(FlutterError(code: "NO_PROTOCOL", message: "No supported protocol on accessory", details: nil))
            return
        }

        guard let session = EASession(accessory: accessory, forProtocol: protocol_) else {
            result(FlutterError(code: "SESSION_FAILED", message: "Failed to create EA session", details: nil))
            return
        }

        eaSession = session
        eaAccessory = accessory
        connectionMode = .mfi
        isConnectedFlag = true

        inputStream = session.inputStream
        outputStream = session.outputStream

        inputStream?.delegate = self
        outputStream?.delegate = self
        inputStream?.schedule(in: .main, forMode: .default)
        outputStream?.schedule(in: .main, forMode: .default)
        inputStream?.open()
        outputStream?.open()

        result(nil)
    }

    private func connectBle(uuid: String, result: @escaping FlutterResult) {
        guard let centralManager = centralManager, centralManager.state == .poweredOn else {
            if centralManager == nil {
                centralManager = CBCentralManager(delegate: self, queue: nil)
            }
            connectResult = result
            return
        }

        connectResult = result

        guard let peripheralUUID = UUID(uuidString: uuid) else {
            result(FlutterError(code: "INVALID_UUID", message: "Invalid BLE UUID", details: nil))
            connectResult = nil
            return
        }

        let peripherals = centralManager.retrievePeripherals(withIdentifiers: [peripheralUUID])
        guard let peripheral = peripherals.first else {
            result(FlutterError(code: "NOT_FOUND", message: "BLE device not found", details: nil))
            connectResult = nil
            return
        }

        connectedPeripheral = peripheral
        peripheral.delegate = self
        centralManager.connect(peripheral, options: nil)
    }

    // MARK: - Disconnect

    private func disconnect(result: @escaping FlutterResult) {
        switch connectionMode {
        case .ble:
            if let peripheral = connectedPeripheral {
                centralManager?.cancelPeripheralConnection(peripheral)
            }
            connectedPeripheral = nil
            txCharacteristic = nil
        case .mfi:
            inputStream?.close()
            outputStream?.close()
            inputStream?.remove(from: .main, forMode: .default)
            outputStream?.remove(from: .main, forMode: .default)
            inputStream = nil
            outputStream = nil
            eaSession = nil
            eaAccessory = nil
        case .none:
            break
        }

        isConnectedFlag = false
        connectionMode = .none
        result(nil)
    }

    // MARK: - Send

    private func send(data: Data, result: @escaping FlutterResult) {
        switch connectionMode {
        case .ble:
            guard let peripheral = connectedPeripheral,
                  let characteristic = txCharacteristic else {
                result(FlutterError(code: "NOT_CONNECTED", message: "BLE not connected", details: nil))
                return
            }
            peripheral.writeValue(data, for: characteristic, type: .withoutResponse)
            result(nil)
        case .mfi:
            guard let stream = outputStream else {
                result(FlutterError(code: "NOT_CONNECTED", message: "MFi not connected", details: nil))
                return
            }
            data.withUnsafeBytes { ptr in
                if let baseAddress = ptr.baseAddress {
                    stream.write(baseAddress.assumingMemoryBound(to: UInt8.self), maxLength: data.count)
                }
            }
            result(nil)
        case .none:
            result(FlutterError(code: "NOT_CONNECTED", message: "Not connected", details: nil))
        }
    }

    // MARK: - CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        // If we have a pending connect, retry
        if central.state == .poweredOn, let result = connectResult {
            // connectResult is waiting — user can re-call connect
            _ = result
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                         advertisementData: [String: Any], rssi RSSI: NSNumber) {
        if !discoveredPeripherals.contains(where: { $0.0.identifier == peripheral.identifier }) {
            discoveredPeripherals.append((peripheral, RSSI))
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectionMode = .ble
        isConnectedFlag = true
        peripheral.discoverServices([BluetoothSppPlugin.UART_SERVICE_UUID])
        connectResult?(nil)
        connectResult = nil
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        connectResult?(FlutterError(code: "CONNECT_FAILED",
                                     message: error?.localizedDescription ?? "Connection failed",
                                     details: nil))
        connectResult = nil
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        isConnectedFlag = false
        connectionMode = .none
        connectedPeripheral = nil
        txCharacteristic = nil
        eventSink?(FlutterEndOfEventStream)
    }

    // MARK: - CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { return }
        for service in services {
            peripheral.discoverCharacteristics(
                [BluetoothSppPlugin.UART_TX_CHAR_UUID],
                for: service
            )
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let characteristics = service.characteristics else { return }
        for char in characteristics {
            if char.uuid == BluetoothSppPlugin.UART_TX_CHAR_UUID {
                txCharacteristic = char
                // Subscribe to notifications for incoming data
                if char.properties.contains(.notify) {
                    peripheral.setNotifyValue(true, for: char)
                }
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value else { return }
        let typedData = FlutterStandardTypedData(bytes: data)
        DispatchQueue.main.async { [weak self] in
            self?.eventSink?(typedData)
        }
    }

    // MARK: - StreamDelegate (ExternalAccessory / MFi)

    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        switch eventCode {
        case .hasBytesAvailable:
            guard let input = aStream as? InputStream else { return }
            var buffer = [UInt8](repeating: 0, count: 1024)
            let bytesRead = input.read(&buffer, maxLength: buffer.count)
            if bytesRead > 0 {
                let data = Data(buffer[0..<bytesRead])
                let typedData = FlutterStandardTypedData(bytes: data)
                DispatchQueue.main.async { [weak self] in
                    self?.eventSink?(typedData)
                }
            }
        case .errorOccurred:
            DispatchQueue.main.async { [weak self] in
                self?.eventSink?(FlutterError(code: "STREAM_ERROR",
                                               message: "Stream error occurred",
                                               details: nil))
            }
        case .endEncountered:
            DispatchQueue.main.async { [weak self] in
                self?.isConnectedFlag = false
                self?.connectionMode = .none
                self?.eventSink?(FlutterEndOfEventStream)
            }
        default:
            break
        }
    }
}
