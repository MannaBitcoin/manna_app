import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:manna/services/log_service.dart';

enum AndroidAccessLevel {
  evenLocked,
  onlyUnlocked,
  authenticated,

  /// if biometric enrollment changes — the secret becomes irrecoverable.
  authenticatedFatal,
}

enum AppleAccessLevel {
  whenUnlocked,
  afterFirstUnlock,
  afterFirstUnlockThisDeviceOnly,
  whenPasscodeSetThisDeviceOnly,
  whenUnlockedThisDeviceOnly,
}

class SecureStorage {
  static const _platformChannel = MethodChannel('com.lightning.manna/secure_storage');

  static bool get isAndroid => defaultTargetPlatform == TargetPlatform.android;
  static bool get isApple =>
      defaultTargetPlatform == TargetPlatform.iOS || defaultTargetPlatform == TargetPlatform.macOS;

  static void _platformCheck() {
    if (!(isAndroid || isApple)) throw UnsupportedError('Unsupported platform: $defaultTargetPlatform');
  }

  static Map<String, dynamic> appleOptions = {};

  /// [iOSAccessGroup] : groupId to share this keychain item to (applies to apple devices only)
  static Future<void> init({
    AndroidAccessLevel androidAccessLevel = AndroidAccessLevel.evenLocked,
    AppleAccessLevel appleAccessLevel = AppleAccessLevel.afterFirstUnlockThisDeviceOnly,
    String? iOSAccessGroup,
  }) async {
    try {
      _platformCheck();
      if (isAndroid) {
        final androidOptions = <String, dynamic>{
          'accessMode': androidAccessLevel.name,
          // 'version': 1,
          // 'prefix': 'manna',
          // 'unlockedDeviceRequired': false,
          'strongBox': false,
          // 'userAuthenticationRequired': false,
          // 'invalidatedByBiometricEnrollment': false,
        };
        await _platformChannel.invokeMethod('init', androidOptions);
      }

      appleOptions = {
        // 'service':null,
        'accessibility': appleAccessLevel.name,
        // 'authenticationRequired':false,
        // 'biometryCurrentSetOnly':true, // if biometric enrollment changes — the secret becomes irrecoverable.
        // 'authenticationPrompt':null,
        'accessGroup': iOSAccessGroup,
      };
    } catch (e, s) {
      logE(e, stackTrace: s);
    }
  }

  /// [useSecureEnclave] only works on apple devices
  static Future<bool> store(String key, Uint8List value, {bool useSecureEnclave = false}) async {
    try {
      _platformCheck();
      await _platformChannel.invokeMethod('store', {
        'key': key,
        'value': value,
        if (isApple) ...{...appleOptions, 'useSecureEnclave': useSecureEnclave},
      });
      return true;
    } catch (e, s) {
      logE(e, stackTrace: s);
    }
    return false;
  }

  /// [useSecureEnclave] only works on apple devices
  static Future<Uint8List?> fetch(String key, {bool useSecureEnclave = false}) async {
    try {
      _platformCheck();
      return await _platformChannel.invokeMethod<Uint8List>('fetch', {
        'key': key,
        if (isApple) ...{...appleOptions, 'useSecureEnclave': useSecureEnclave},
      });
    } catch (e, s) {
      logE(e, stackTrace: s);
    }
    return null;
  }

  static Future<bool> delete(String key, {bool useSecureEnclave = false}) async {
    try {
      _platformCheck();
      await _platformChannel.invokeMethod('delete', {
        'key': key,
        if (isApple) ...{...appleOptions, 'useSecureEnclave': useSecureEnclave},
      });
      return true;
    } catch (e, s) {
      logE(e, stackTrace: s);
    }
    return false;
  }

  static Future<bool> exists(String key, {bool useSecureEnclave = false}) async {
    try {
      _platformCheck();
      return await _platformChannel.invokeMethod<bool>('exists', {
            'key': key,
            if (isApple) ...{...appleOptions, 'useSecureEnclave': useSecureEnclave},
          }) ??
          false;
    } catch (e, s) {
      logE(e, stackTrace: s);
    }
    return false;
  }

  /// returns whether device support strongbox (android only)
  static Future<bool> isStrongBoxAvailable() async {
    try {
      if (isAndroid) {
        return await _platformChannel.invokeMethod<bool>('isStrongBoxAvailable') ?? false;
      }
    } catch (e, s) {
      logE(e, stackTrace: s);
    }
    return false;
  }
}
