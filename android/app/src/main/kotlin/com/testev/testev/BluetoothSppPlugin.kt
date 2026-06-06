package com.testev.testev

import android.Manifest
import android.app.Activity
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothSocket
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.ActivityCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.util.UUID

class BluetoothSppPlugin private constructor(
    private val activity: Activity
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    companion object {
        private const val METHOD_CHANNEL = "testev/bluetooth"
        private const val EVENT_CHANNEL = "testev/bluetooth/data"
        private val SPP_UUID: UUID = UUID.fromString("00001101-0000-1000-8000-00805F9B34FB")

        fun registerWith(engine: FlutterEngine, activity: Activity) {
            val plugin = BluetoothSppPlugin(activity)
            MethodChannel(engine.dartExecutor.binaryMessenger, METHOD_CHANNEL)
                .setMethodCallHandler(plugin)
            EventChannel(engine.dartExecutor.binaryMessenger, EVENT_CHANNEL)
                .setStreamHandler(plugin)
        }
    }

    private var socket: BluetoothSocket? = null
    private var inputStream: InputStream? = null
    private var outputStream: OutputStream? = null
    private var readerThread: Thread? = null
    private var eventSink: EventChannel.EventSink? = null
    @Volatile private var reading = false

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "scan" -> scan(result)
            "connect" -> {
                val address = call.argument<String>("address")
                if (address == null) {
                    result.error("INVALID", "Missing address", null)
                } else {
                    connect(address, result)
                }
            }
            "disconnect" -> disconnect(result)
            "send" -> {
                val data = call.argument<ByteArray>("data")
                if (data != null) {
                    send(data, result)
                } else {
                    result.error("INVALID", "Missing data", null)
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun hasPermission(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            ActivityCompat.checkSelfPermission(
                activity, Manifest.permission.BLUETOOTH_CONNECT
            ) == PackageManager.PERMISSION_GRANTED
        } else {
            true
        }
    }

    private fun scan(result: MethodChannel.Result) {
        if (!hasPermission()) {
            result.error("PERMISSION", "Bluetooth permission not granted", null)
            return
        }

        val manager = activity.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
        val adapter = manager?.adapter
        if (adapter == null) {
            result.error("UNAVAILABLE", "Bluetooth not available", null)
            return
        }

        val devices = adapter.bondedDevices.map { device ->
            mapOf(
                "name" to (device.name ?: "Unknown"),
                "address" to device.address,
                "rssi" to 0
            )
        }
        result.success(devices.toList())
    }

    private fun connect(address: String, result: MethodChannel.Result) {
        if (!hasPermission()) {
            result.error("PERMISSION", "Bluetooth permission not granted", null)
            return
        }

        Thread {
            try {
                val manager = activity.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
                val adapter = manager.adapter
                val device: BluetoothDevice = adapter.getRemoteDevice(address)

                adapter.cancelDiscovery()

                val sock = device.createRfcommSocketToServiceRecord(SPP_UUID)
                sock.connect()

                socket = sock
                inputStream = sock.inputStream
                outputStream = sock.outputStream

                startReading()

                activity.runOnUiThread { result.success(null) }
            } catch (e: Exception) {
                activity.runOnUiThread {
                    result.error("CONNECT_FAILED", e.message, null)
                }
            }
        }.start()
    }

    private fun startReading() {
        reading = true
        readerThread = Thread {
            val buffer = ByteArray(1024)
            while (reading) {
                try {
                    val count = inputStream?.read(buffer) ?: -1
                    if (count > 0) {
                        val data = buffer.copyOf(count)
                        activity.runOnUiThread {
                            eventSink?.success(data)
                        }
                    } else if (count < 0) {
                        break
                    }
                } catch (e: IOException) {
                    if (reading) {
                        activity.runOnUiThread {
                            eventSink?.error("READ_ERROR", e.message, null)
                        }
                    }
                    break
                }
            }
            activity.runOnUiThread {
                eventSink?.endOfStream()
            }
        }
        readerThread?.isDaemon = true
        readerThread?.start()
    }

    private fun disconnect(result: MethodChannel.Result) {
        reading = false
        try {
            socket?.close()
        } catch (_: Exception) {}
        socket = null
        inputStream = null
        outputStream = null
        result.success(null)
    }

    private fun send(data: ByteArray, result: MethodChannel.Result) {
        try {
            outputStream?.write(data)
            outputStream?.flush()
            result.success(null)
        } catch (e: Exception) {
            result.error("SEND_FAILED", e.message, null)
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }
}
