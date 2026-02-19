package com.example.network_speed_test

import androidx.annotation.NonNull
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

import io.flutter.plugin.common.EventChannel

class MainActivity: FlutterActivity() {
    private val METHOD_CHANNEL = "com.example.network_speed_test/iperf"
    private val EVENT_CHANNEL = "com.example.network_speed_test/iperf_stream"
    private lateinit var iperfRunner: IperfRunner
    private var eventSink: EventChannel.EventSink? = null

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        iperfRunner = IperfRunner(context)

        // Setup EventChannel for streaming
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENT_CHANNEL).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    eventSink = events
                }

                override fun onCancel(arguments: Any?) {
                    eventSink = null
                }
            }
        )

        // Setup MethodChannel for control
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, METHOD_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "startTest" -> {
                    val host = call.argument<String>("host") ?: "127.0.0.1"
                    val port = call.argument<Int>("port") ?: 5201
                    val duration = call.argument<Int>("duration") ?: 10
                    val streams = call.argument<Int>("streams") ?: 1
                    val protocol = call.argument<String>("protocol") ?: "tcp"
                    
                    val bandwidth = call.argument<String>("bandwidth") ?: "0"
                    val reverse = call.argument<Boolean>("reverse") ?: false
                    
                    // Launch new coroutine on Main thread
                    CoroutineScope(Dispatchers.Main).launch {
                        try {
                            val output = iperfRunner.runIperf(
                                host,
                                port,
                                duration,
                                streams,
                                protocol,
                                bandwidth,
                                reverse
                            ) { progressLine ->
                                // Send progress line to Flutter
                                runOnUiThread {
                                    eventSink?.success(progressLine)
                                }
                            }
                            result.success(output)
                        } catch (e: Exception) {
                            result.error("IPERF_ERROR", e.message, null)
                        }
                    }
                }
                "stopTest" -> {
                    iperfRunner.stopTest()
                    result.success(null)
                }
                else -> {
                    result.notImplemented()
                }
            }
        }
    }
}
