import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../models/models.dart';
import 'vault.dart' show VaultException;

/// Password-protected backup files, so data can move to a new phone. The
/// on-device vault key never leaves the keystore; a backup is encrypted
/// with its own key derived from the user's password.
///
/// Layout: "CWB1" | PBKDF2 iterations (uint32, big endian) | salt (16) |
/// nonce (12) | AES-256-GCM ciphertext | tag (16). The header is
/// authenticated as associated data.
class Backup {
  Backup._();

  static const List<int> _magic = [0x43, 0x57, 0x42, 0x31]; // "CWB1"
  static const int defaultIterations = 210000;
  static const int minPasswordLength = 8;
  static const int maxFileBytes = 64 * 1024 * 1024;
  static const int _saltLength = 16;
  static const int _headerLength = 4 + 4 + _saltLength;

  static final AesGcm _algo = AesGcm.with256bits();

  static String? validatePassword(String password) =>
      password.length < minPasswordLength
      ? 'Use at least $minPasswordLength characters.'
      : null;

  /// Derives the key off the UI isolate: PBKDF2 in pure Dart takes a moment.
  static Future<SecretKey> _deriveKey(
    String password,
    List<int> salt,
    int iterations,
  ) async {
    final bytes = await Isolate.run(() async {
      final kdf = Pbkdf2(
        macAlgorithm: Hmac.sha256(),
        iterations: iterations,
        bits: 256,
      );
      final key = await kdf.deriveKeyFromPassword(
        password: password,
        nonce: salt,
      );
      return key.extractBytes();
    });
    return SecretKey(bytes);
  }

  static Future<Uint8List> encrypt(
    VaultData data,
    String password, {
    int iterations = defaultIterations,
  }) async {
    final error = validatePassword(password);
    if (error != null) throw VaultException(error);
    final rng = Random.secure();
    final salt = List<int>.generate(_saltLength, (_) => rng.nextInt(256));
    final header = Uint8List(_headerLength)
      ..setRange(0, 4, _magic)
      ..buffer.asByteData().setUint32(4, iterations)
      ..setRange(8, _headerLength, salt);
    final key = await _deriveKey(password, salt, iterations);
    final clear = utf8.encode(jsonEncode(data.toJson()));
    final box = await _algo.encrypt(clear, secretKey: key, aad: header);
    return Uint8List.fromList([...header, ...box.concatenation()]);
  }

  static Future<VaultData> decrypt(Uint8List file, String password) async {
    const minLength = _headerLength + 12 + 16;
    if (file.length < minLength || file.length > maxFileBytes) {
      throw VaultException('This is not a Cardwise backup file.');
    }
    for (var i = 0; i < _magic.length; i++) {
      if (file[i] != _magic[i]) {
        throw VaultException('This is not a Cardwise backup file.');
      }
    }
    final header = Uint8List.sublistView(file, 0, _headerLength);
    final iterations = header.buffer
        .asByteData(header.offsetInBytes)
        .getUint32(4);
    if (iterations < 10000 || iterations > 5000000) {
      throw VaultException('This backup file is damaged.');
    }
    final salt = header.sublist(8, _headerLength);
    final key = await _deriveKey(password, salt, iterations);
    final box = SecretBox.fromConcatenation(
      file.sublist(_headerLength),
      nonceLength: _algo.nonceLength,
      macLength: _algo.macAlgorithm.macLength,
    );
    final List<int> clear;
    try {
      clear = await _algo.decrypt(box, secretKey: key, aad: header);
    } on SecretBoxAuthenticationError {
      throw VaultException('Wrong password, or the backup file is damaged.');
    }
    try {
      final decoded = jsonDecode(utf8.decode(clear));
      return VaultData.fromJson(Map<String, Object?>.from(decoded as Map));
    } catch (_) {
      throw VaultException('This backup file could not be read.');
    }
  }
}
