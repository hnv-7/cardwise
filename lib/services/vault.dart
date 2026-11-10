import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

import '../models/models.dart';

class VaultException implements Exception {
  VaultException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Abstraction so the app state can be tested without platform channels.
abstract class VaultStore {
  Future<VaultData> load();
  Future<void> save(VaultData data);
  Future<void> wipe();
}

/// Persists [VaultData] as an AES-256-GCM encrypted file in the app's private
/// documents directory. The 256-bit key is generated with a CSPRNG and kept
/// in the platform keystore (Android Keystore / iOS Keychain) through
/// flutter_secure_storage; it never touches the file system.
class EncryptedFileVault implements VaultStore {
  EncryptedFileVault({FlutterSecureStorage? secureStorage})
    : _secure =
          secureStorage ??
          const FlutterSecureStorage(
            iOptions: IOSOptions(
              accessibility: KeychainAccessibility.first_unlock_this_device,
            ),
          );

  static const _keyName = 'vault_key_v1';
  static const _fileName = 'vault.bin';
  static const _magic = [0x43, 0x43, 0x56, 0x31]; // "CCV1"

  final FlutterSecureStorage _secure;
  final AesGcm _algo = AesGcm.with256bits();

  Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/$_fileName');
  }

  Future<SecretKey> _key({required bool createIfMissing}) async {
    final existing = await _secure.read(key: _keyName);
    if (existing != null) {
      return SecretKey(base64Decode(existing));
    }
    if (!createIfMissing) {
      throw VaultException('Encryption key is missing.');
    }
    final key = await _algo.newSecretKey();
    final bytes = await key.extractBytes();
    await _secure.write(key: _keyName, value: base64Encode(bytes));
    return key;
  }

  @override
  Future<VaultData> load() async {
    try {
      final file = await _file();
      if (!await file.exists()) return const VaultData();
      final raw = await file.readAsBytes();
      if (raw.length < _magic.length + 12 + 16 || !_hasMagic(raw)) {
        throw VaultException('Stored data is corrupted.');
      }
      final key = await _key(createIfMissing: false);
      final body = raw.sublist(_magic.length);
      final box = SecretBox.fromConcatenation(
        body,
        nonceLength: _algo.nonceLength,
        macLength: _algo.macAlgorithm.macLength,
      );
      final clear = await _algo.decrypt(box, secretKey: key);
      final decoded = jsonDecode(utf8.decode(clear));
      return VaultData.fromJson(Map<String, Object?>.from(decoded as Map));
    } on VaultException {
      rethrow;
    } on SecretBoxAuthenticationError {
      throw VaultException('Stored data failed its integrity check.');
    } on FormatException {
      throw VaultException('Stored data could not be read.');
    } on FileSystemException {
      throw VaultException('Could not access device storage.');
    }
  }

  bool _hasMagic(Uint8List raw) {
    for (var i = 0; i < _magic.length; i++) {
      if (raw[i] != _magic[i]) return false;
    }
    return true;
  }

  @override
  Future<void> save(VaultData data) async {
    try {
      final key = await _key(createIfMissing: true);
      final clear = utf8.encode(jsonEncode(data.toJson()));
      final box = await _algo.encrypt(clear, secretKey: key);
      final out = Uint8List.fromList([..._magic, ...box.concatenation()]);
      final file = await _file();
      await file.parent.create(recursive: true);
      // Write to a temp file then rename so a crash cannot truncate the vault.
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsBytes(out, flush: true);
      await tmp.rename(file.path);
    } on FileSystemException {
      throw VaultException('Could not save data to device storage.');
    }
  }

  @override
  Future<void> wipe() async {
    final file = await _file();
    if (await file.exists()) await file.delete();
    await _secure.delete(key: _keyName);
  }
}
