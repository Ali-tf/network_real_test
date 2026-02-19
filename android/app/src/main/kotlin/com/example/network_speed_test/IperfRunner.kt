package com.example.network_speed_test

import android.content.Context
import java.io.BufferedReader
import java.io.File
import java.io.InputStreamReader
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject

class IperfRunner(private val context: Context) {

    private var process: Process? = null

    suspend fun runIperf(
        host: String,
        port: Int,
        duration: Int,
        streams: Int,
        protocol: String, // "tcp" or "udp"
        bandwidth: String, // e.g. "1000M"
        reverse: Boolean,
        onProgress: (String) -> Unit
    ): String = withContext(Dispatchers.IO) {
        
        // Use the native library directory where Android extracts .so files
        // We packaged iperf3 as libiperf3.so so it gets installed with +x permissions
        val nativeDir = context.applicationInfo.nativeLibraryDir
        val iperfPath = "$nativeDir/libiperf3.so"
        
        val iperfFile = File(iperfPath)
        if (!iperfFile.exists()) {
             throw Exception("iperf3 binary not found at $iperfPath. Architecture mismatch or not extracted?")
        }
        
        // Double check executable, though system should have handled it
        if (!iperfFile.canExecute()) {
             iperfFile.setExecutable(true)
        }

        val command = ArrayList<String>()
        command.add(iperfPath)
        command.add("-c")
        command.add(host)
        command.add("-p")
        command.add(port.toString())
        command.add("-t")
        command.add(duration.toString())
        command.add("-P")
        command.add(streams.toString())
        
        if (protocol == "udp") {
            command.add("-u")
        }
        
        if (bandwidth.isNotEmpty() && bandwidth != "0") {
            command.add("-b")
            command.add(bandwidth)
        }

        // Add Omit (Warm-up) period
        command.add("-O")
        command.add("2") // Omit first 2 seconds from final calculation
        
        if (reverse) {
            command.add("-R")
        }

        // SWAPPED TO TEXT OUTPUT FOR LIVE STREAMING
        // command.add("-J") // Removing JSON to get periodic text updates
        command.add("-i")
        command.add("0.5") // Update every 0.5 seconds
        command.add("-f")
        command.add("m") // Force Mbits/sec
        command.add("--forceflush")
        
        // Remove --logfile to get output in stdout
        command.remove("--logfile")
        command.remove("iperf_log.json")

        val pb = ProcessBuilder(command)
        pb.redirectErrorStream(true)
        process = pb.start()

        val reader = BufferedReader(InputStreamReader(process!!.inputStream))
        val output = StringBuilder()
        var line: String? 
        while (reader.readLine().also { line = it } != null) {
            val safeLine = line ?: ""
            output.append(safeLine).append("\n")
            onProgress(safeLine) // Stream line to Flutter
        }

        val exitCode = process!!.waitFor()
        if (exitCode == 0) {
            return@withContext output.toString()
        } else {
             throw Exception("iperf3 exited with code $exitCode: $output")
        }
    }

    fun stopTest() {
        process?.destroy()
    }
}
