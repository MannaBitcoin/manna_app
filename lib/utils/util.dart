import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:manna/app_state.dart';
import 'package:manna/services/log_service.dart';
import 'package:manna/services/secure_storage.dart';
import 'package:manna/utils/toast_service.dart';
import 'package:manna_core/manna_core.dart';
import 'package:native_dio_adapter/native_dio_adapter.dart';
import 'package:path_provider_foundation/path_provider_foundation.dart';
import 'package:pretty_qr_code/pretty_qr_code.dart';
import 'package:uuid/uuid.dart';
import 'package:path/path.dart' as path;

bool get isMobile => defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS;

bool get isDesktop =>
    defaultTargetPlatform == TargetPlatform.macOS ||
    defaultTargetPlatform == TargetPlatform.windows ||
    defaultTargetPlatform == TargetPlatform.linux;

bool get isApple => defaultTargetPlatform == TargetPlatform.macOS || defaultTargetPlatform == TargetPlatform.iOS;

final sensitivityService = SensitiveContentService();
void makeScreenRecordable(bool shouldBeRecordable) async {
  if (await sensitivityService.isSupported()) {
    await sensitivityService.setContentSensitivity(
      shouldBeRecordable ? ContentSensitivity.notSensitive : ContentSensitivity.sensitive,
    );
  }
}

double mapRange(double input, double fromA, double fromB, double toA, double toB) =>
    (input - fromA) * (toB - toA) / (fromB - fromA) + toA;

Uint8List randomByteSlice(int length) {
  final Uint8List data = Uint8List(length);
  final random = Random.secure();
  for (var i = 0; i < length; i++) {
    data[i] = random.nextInt(256);
  }
  return data;
}

Future<String> getDeviceId() async {
  final deviceId = AppState.prefs.getString('device_id') ?? '';
  if (deviceId.isNotEmpty) {
    return deviceId;
  }
  final newId = const Uuid().v4();
  await AppState.prefs.setString('device_id', newId);
  return newId;
}

final globalDio = Dio(
  BaseOptions(
    validateStatus: (status) {
      if (status == 429) {
        ToastService.show('Too many requests, please try again later!');
      }
      return true;
    },
  ),
)..httpClientAdapter = NativeAdapter();

Future<String?> getAppGroupPath({String? subPath}) async {
  if (!Platform.isIOS) return null;
  try {
    final appGroupPath = await PathProviderFoundation().getContainerPath(
      appGroupIdentifier: 'group.com.lightning.manna',
    );
    if (subPath != null && appGroupPath != null) {
      return path.join(appGroupPath, subPath);
    }
    return appGroupPath;
  } catch (_) {}
  return null;
}

void copyDirectory(Directory source, Directory dest) {
  for (final entity in source.listSync(recursive: true)) {
    if (entity is Directory) {
      final newDirectory = Directory(path.join(dest.absolute.path, path.basename(entity.path)));
      newDirectory.createSync();
      copyDirectory(entity.absolute, newDirectory);
    } else if (entity is File) {
      entity.copySync(path.join(dest.path, path.basename(entity.path)));
    }
  }
}

String sortedJsonEncode(Map<String, dynamic> data) =>
    jsonEncode(Map.fromEntries(data.entries.toList()..sort((a, b) => a.key.compareTo(b.key))));

PrettyQrDecoration qrDecoration(String data) => PrettyQrDecoration(
  image: const PrettyQrDecorationImage(
    image: AssetImage('assets/images/manna_small.png'),
    isAntiAlias: true,
    filterQuality: FilterQuality.high,
  ),
  quietZone: const PrettyQrModulesQuietZone(2),
  shape: PrettyQrSmoothSymbol(roundFactor: data.length > 150 ? 0.5 : 1),
  background: Colors.white,
);

// accountId, path, network
final Map<(String, String), U8Array32> _derivationCache = {};
Future<U8Array32?> getDerivationPrivKey({required String accountId, required String derivationPath}) async {
  final cachedValue = _derivationCache[(accountId, derivationPath)];
  if (cachedValue != null) return cachedValue;

  final utf8Bytes = await SecureStorage.fetch('acc-$accountId', useSecureEnclave: true);
  if (utf8Bytes == null) return null;
  final mnemonic = utf8.decode(utf8Bytes);

  final privateKey = (await Bip32.fromMnemonics(mnemonic: mnemonic)).derivePath(path: derivationPath).getPrivateKey();
  if (privateKey != null) _derivationCache[(accountId, derivationPath)] = privateKey;

  return privateKey;
}

void benchMarkRunTime(Function runner) async {
  final sw = Stopwatch()..start();
  await runner();
  logD('Function took : ${sw.elapsed.inMilliseconds}ms');
}
