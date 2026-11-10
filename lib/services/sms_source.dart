import 'dart:io';

import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

class RawSms {
  const RawSms(this.body, this.received);
  final String body;
  final DateTime received;
}

enum SmsAccess { granted, denied, permanentlyDenied, unsupported }

/// Abstraction over the device message store (testable).
abstract class SmsSource {
  bool get isSupported;
  Future<SmsAccess> status();
  Future<SmsAccess> request();
  Future<List<RawSms>> readInbox({required DateTime since, int limit});
  Future<void> openSettings();
}

/// Android reads the SMS inbox through a small native channel
/// (see MainActivity.kt). iOS does not allow any app to read SMS, so it is
/// reported as unsupported and the UI offers paste-to-import instead.
class PlatformSmsSource implements SmsSource {
  static const _channel = MethodChannel('com.cardtrack.cc_app/sms');

  @override
  bool get isSupported => Platform.isAndroid;

  SmsAccess _map(PermissionStatus s) {
    if (s.isGranted) return SmsAccess.granted;
    if (s.isPermanentlyDenied) return SmsAccess.permanentlyDenied;
    return SmsAccess.denied;
  }

  @override
  Future<SmsAccess> status() async {
    if (!isSupported) return SmsAccess.unsupported;
    return _map(await Permission.sms.status);
  }

  @override
  Future<SmsAccess> request() async {
    if (!isSupported) return SmsAccess.unsupported;
    return _map(await Permission.sms.request());
  }

  @override
  Future<void> openSettings() async {
    await openAppSettings();
  }

  @override
  Future<List<RawSms>> readInbox({
    required DateTime since,
    int limit = 2000,
  }) async {
    if (!isSupported) return const [];
    final result = await _channel.invokeListMethod<Map<Object?, Object?>>(
      'readInbox',
      {'sinceMillis': since.millisecondsSinceEpoch, 'limit': limit},
    );
    final out = <RawSms>[];
    for (final m in result ?? const <Map<Object?, Object?>>[]) {
      final body = m['body'];
      final date = m['date'];
      if (body is String && date is int) {
        out.add(RawSms(body, DateTime.fromMillisecondsSinceEpoch(date)));
      }
    }
    return out;
  }
}
