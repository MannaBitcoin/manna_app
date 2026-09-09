import 'package:local_auth/local_auth.dart';
import 'package:manna/app_state.dart';
import 'package:manna/services/log_service.dart';
import 'package:manna/utils/toast_service.dart';

class BiometricService {
  static final auth = LocalAuthentication();

  static bool get isBiometricOn => AppState.prefs.getBool('isBiometricOn') ?? false;

  static Future<void> disableBiometric() async {
    if (await authenticateBiometricsIfExists(
      message: 'Verify your device to disable biometric authentication',
      isForce: true,
    )) {
      await AppState.prefs.remove('isBiometricOn');
      ToastService.show('Biometric disabled');
    }
  }

  static Future<void> enableBiometric() async {
    if (await auth.canCheckBiometrics && await auth.isDeviceSupported()) {
      if (await authenticateBiometricsIfExists(
        message: 'Verify your device to enable biometric authentication',
        isForce: true,
      )) {
        await AppState.prefs.setBool('isBiometricOn', true);
        ToastService.show('Biometric enabled');
      }
    } else {
      ToastService.show('Your device does not support biometric authentication');
    }
  }

  static Future<bool> authenticateBiometricsIfExists({String? message, bool isForce = false}) async {
    try {
      if (await auth.canCheckBiometrics && await auth.isDeviceSupported()) {
        if (isForce || (AppState.prefs.getBool('isBiometricOn') ?? false)) {
          return await auth.authenticate(localizedReason: message ?? 'Please authenticate to access the app');
        } else {
          await AppState.prefs.setBool('isBiometricOn', false);
          return true;
        }
      } else {
        return true;
      }
    } catch (e, s) {
      logE(e, stackTrace: s);
    }
    return false;
  }
}
