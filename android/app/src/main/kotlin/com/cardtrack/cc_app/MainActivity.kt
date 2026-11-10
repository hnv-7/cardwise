package com.cardtrack.cc_app

import android.Manifest
import android.content.pm.PackageManager
import android.os.Handler
import android.os.Looper
import android.provider.Telephony
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val channelName = "com.cardtrack.cc_app/sms"
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                if (call.method != "readInbox") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                if (checkSelfPermission(Manifest.permission.READ_SMS)
                    != PackageManager.PERMISSION_GRANTED
                ) {
                    result.error("PERMISSION_DENIED", "SMS permission not granted", null)
                    return@setMethodCallHandler
                }
                val since = (call.argument<Number>("sinceMillis") ?: 0L).toLong()
                val limit = (call.argument<Number>("limit") ?: 2000).toInt().coerceIn(1, 10000)
                worker.execute {
                    try {
                        val rows = readInbox(since, limit)
                        main.post { result.success(rows) }
                    } catch (e: SecurityException) {
                        main.post { result.error("PERMISSION_DENIED", "SMS access denied", null) }
                    } catch (e: Exception) {
                        main.post { result.error("READ_FAILED", "Could not read messages", null) }
                    }
                }
            }
    }

    /** Reads inbox messages newer than [since], newest first, bounded by [limit]. */
    private fun readInbox(since: Long, limit: Int): List<Map<String, Any>> {
        val out = ArrayList<Map<String, Any>>()
        val projection = arrayOf(Telephony.Sms.BODY, Telephony.Sms.DATE)
        contentResolver.query(
            Telephony.Sms.Inbox.CONTENT_URI,
            projection,
            "${Telephony.Sms.DATE} >= ?",
            arrayOf(since.toString()),
            "${Telephony.Sms.DATE} DESC"
        )?.use { cursor ->
            val bodyIdx = cursor.getColumnIndexOrThrow(Telephony.Sms.BODY)
            val dateIdx = cursor.getColumnIndexOrThrow(Telephony.Sms.DATE)
            while (cursor.moveToNext() && out.size < limit) {
                val body = cursor.getString(bodyIdx) ?: continue
                out.add(mapOf("body" to body, "date" to cursor.getLong(dateIdx)))
            }
        }
        return out
    }
}
