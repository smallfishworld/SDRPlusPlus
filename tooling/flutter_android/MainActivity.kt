package com.smallfishworld.sdrpp_flutter

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbDeviceConnection
import android.hardware.usb.UsbManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "sdrpp_receiver/usb"
    private val usbPermissionAction =
        "com.smallfishworld.sdrpp_flutter.USB_PERMISSION"

    private lateinit var usbManager: UsbManager
    private var activeConnection: UsbDeviceConnection? = null
    private var pendingDevice: UsbDevice? = null
    private var pendingResult: MethodChannel.Result? = null
    private var receiverRegistered = false

    private val rtlVidPid = setOf(
        0x0bda to 0x2832,
        0x0bda to 0x2838,
        0x0413 to 0x6680,
        0x0413 to 0x6f0f,
        0x0458 to 0x707f,
        0x0ccd to 0x00a9,
        0x0ccd to 0x00b3,
        0x0ccd to 0x00b4,
        0x0ccd to 0x00b5,
        0x0ccd to 0x00b7,
        0x0ccd to 0x00b8,
        0x0ccd to 0x00b9,
        0x0ccd to 0x00c0,
        0x0ccd to 0x00c6,
        0x0ccd to 0x00d3,
        0x0ccd to 0x00d7,
        0x0ccd to 0x00e0,
        0x1554 to 0x5020,
        0x15f4 to 0x0131,
        0x15f4 to 0x0133,
        0x185b to 0x0620,
        0x185b to 0x0650,
        0x185b to 0x0680,
        0x1b80 to 0xd393,
        0x1b80 to 0xd394,
        0x1b80 to 0xd395,
        0x1b80 to 0xd397,
        0x1b80 to 0xd398,
        0x1b80 to 0xd39d,
        0x1b80 to 0xd3a4,
        0x1b80 to 0xd3a8,
        0x1b80 to 0xd3af,
        0x1b80 to 0xd3b0,
        0x1d19 to 0x1101,
        0x1d19 to 0x1102,
        0x1d19 to 0x1103,
        0x1d19 to 0x1104,
        0x1f4d to 0xa803,
        0x1f4d to 0xb803,
        0x1f4d to 0xc803,
        0x1f4d to 0xd286,
        0x1f4d to 0xd803,
    )

    private val permissionReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action != usbPermissionAction) {
                return
            }

            val device = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                intent.getParcelableExtra(
                    UsbManager.EXTRA_DEVICE,
                    UsbDevice::class.java,
                )
            } else {
                @Suppress("DEPRECATION")
                intent.getParcelableExtra(UsbManager.EXTRA_DEVICE)
            }

            val granted = intent.getBooleanExtra(
                UsbManager.EXTRA_PERMISSION_GRANTED,
                false,
            )
            val result = pendingResult
            pendingResult = null
            pendingDevice = null

            if (!granted || device == null) {
                result?.error(
                    "USB_PERMISSION_DENIED",
                    "USB permission was not granted",
                    null,
                )
                return
            }
            openGrantedDevice(device, result)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        usbManager = getSystemService(Context.USB_SERVICE) as UsbManager
        registerPermissionReceiver()

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            channelName,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "listRtlSdrDevices" -> listDevices(result)
                "openRtlSdr" -> openDevice(call, result)
                "closeRtlSdr" -> {
                    closeActiveConnection()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun registerPermissionReceiver() {
        if (receiverRegistered) {
            return
        }
        val filter = IntentFilter(usbPermissionAction)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(
                permissionReceiver,
                filter,
                Context.RECEIVER_NOT_EXPORTED,
            )
        } else {
            @Suppress("DEPRECATION")
            registerReceiver(permissionReceiver, filter)
        }
        receiverRegistered = true
    }

    private fun isRtlSdr(device: UsbDevice): Boolean =
        rtlVidPid.contains(device.vendorId to device.productId)

    private fun deviceMap(device: UsbDevice): Map<String, Any> = mapOf(
        "deviceName" to device.deviceName,
        "vendorId" to device.vendorId,
        "productId" to device.productId,
        "productName" to (device.productName ?: "RTL-SDR"),
    )

    private fun listDevices(result: MethodChannel.Result) {
        val devices = usbManager.deviceList.values
            .filter(::isRtlSdr)
            .map(::deviceMap)
        result.success(devices)
    }

    private fun openDevice(
        call: MethodCall,
        result: MethodChannel.Result,
    ) {
        val deviceName = call.argument<String>("deviceName")
        val device = usbManager.deviceList[deviceName]
        if (device == null || !isRtlSdr(device)) {
            result.error(
                "RTL_SDR_NOT_FOUND",
                "Selected RTL-SDR USB device is no longer available",
                null,
            )
            return
        }

        if (usbManager.hasPermission(device)) {
            openGrantedDevice(device, result)
            return
        }

        if (pendingResult != null) {
            result.error(
                "USB_PERMISSION_PENDING",
                "Another USB permission request is already active",
                null,
            )
            return
        }

        pendingDevice = device
        pendingResult = result

        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            PendingIntent.FLAG_MUTABLE
        } else {
            0
        }
        val permissionIntent = PendingIntent.getBroadcast(
            this,
            0,
            Intent(usbPermissionAction).setPackage(packageName),
            flags,
        )
        usbManager.requestPermission(device, permissionIntent)
    }

    private fun openGrantedDevice(
        device: UsbDevice,
        result: MethodChannel.Result?,
    ) {
        closeActiveConnection()

        val connection = usbManager.openDevice(device)
        if (connection == null) {
            result?.error(
                "RTL_SDR_OPEN_FAILED",
                "Android UsbManager could not open the RTL-SDR",
                null,
            )
            return
        }

        activeConnection = connection
        result?.success(
            deviceMap(device) + mapOf(
                "fd" to connection.fileDescriptor,
            ),
        )
    }

    private fun closeActiveConnection() {
        activeConnection?.close()
        activeConnection = null
    }

    override fun onDestroy() {
        pendingResult?.error(
            "ACTIVITY_DESTROYED",
            "USB request was cancelled",
            null,
        )
        pendingResult = null
        pendingDevice = null

        closeActiveConnection()
        if (receiverRegistered) {
            unregisterReceiver(permissionReceiver)
            receiverRegistered = false
        }
        super.onDestroy()
    }
}
