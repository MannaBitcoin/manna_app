import 'dart:async';
import 'package:internet_connection_checker_plus/internet_connection_checker_plus.dart';
import 'package:manna/globals.dart';
import 'package:manna/utils/de_bouncer.dart';

class ConnectivityChecker {
  static const _bufferDurationSeconds = 5;
  static DateTime _lastCheckTime = DateTime.now();
  static bool? _lastStatus;
  static final mutex = MutexRun<bool>();

  static final InternetConnection _instance = InternetConnection.createInstance(
    useDefaultOptions: false,
    customCheckOptions: [
      InternetCheckOption(uri: Uri.parse('https://one.one.one.one'), timeout: const Duration(milliseconds: 2000)),
      InternetCheckOption(uri: Uri.parse('https://icanhazip.com/'), timeout: const Duration(milliseconds: 2000)),
    ],
  );

  static Future<bool> checkConnection({bool force = false}) async {
    return mutex.run(() async {
      if (_lastStatus != null &&
          !force &&
          DateTime.now().difference(_lastCheckTime).inSeconds < _bufferDurationSeconds) {
        return _lastStatus!;
      }
      final res = await _instance.hasInternetAccess;
      _lastCheckTime = DateTime.now();
      _lastStatus = res;
      if (res) {
        globalState.update(isInternetConnected: true);
        return true;
      } else {
        globalState.update(isInternetConnected: false);
      }
      return false;
    });
  }
}
