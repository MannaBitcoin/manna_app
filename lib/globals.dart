import 'package:flutter/foundation.dart';
import 'package:manna/services/chat_service.dart';
import 'package:manna/services/db_service.dart';
import 'services/log_service.dart';

enum GlobalStream { account, receivingTx, receivedTx }

class GlobalListener {
  // This class allows us to push updates to any part of the app from anywhere,
  // mostly used for rebuilds but can be used for anything.

  // Stream : {listener name : listener}
  static final Map<GlobalStream, Map<String, Function>> _listeners = {};

  static void addListener({
    required GlobalStream stream,
    required String listenerName,
    required bool Function(dynamic data) callback,
  }) {
    removeListener(stream: stream, listenerName: listenerName);
    (_listeners[stream] ??= {})[listenerName] = callback;
  }

  static void removeListener({required GlobalStream stream, required String listenerName}) {
    _listeners[stream]?.remove(listenerName);
    if (_listeners[stream]?.isEmpty == true) _listeners.remove(stream);
  }

  static void update({required GlobalStream stream, dynamic data}) {
    final Map<GlobalStream, String> toRemove = {};
    for (final entry in _listeners[stream]?.entries ?? <MapEntry<String, Function>>[]) {
      try {
        if (entry.value(data)) {
          // if (kDebugMode) {
          // print('ran callback $stream ${entry.key}');
          // }
        }
      } catch (e, s) {
        toRemove[stream] = entry.key;
        logE(e, stackTrace: s);
      }
    }
    for (final e in toRemove.entries) {
      removeListener(stream: e.key, listenerName: e.value);
    }
  }
}

final GlobalStateNotifier globalState = GlobalStateNotifier();

void startLoader() => globalState.update(isLoading: true);

void stopLoader() => globalState.update(isLoading: false);

class GlobalState {
  bool isLoading = false;
  bool isInternetConnected = true;
  bool isAppForeground = false;
  double restoreSyncProgress = 0;
}

class GlobalStateNotifier extends ValueNotifier<GlobalState> {
  GlobalStateNotifier() : super(GlobalState());

  void update({bool? isLoading, bool? isInternetConnected, bool? isForeground, double? restoreSyncProgress}) {
    if (isLoading != null) {
      value.isLoading = isLoading;
    }
    if (isForeground != null) {
      value.isAppForeground = isForeground;
    }
    if (value.isAppForeground) {
      if (restoreSyncProgress != null) {
        value.restoreSyncProgress = restoreSyncProgress;
      }
      if (isInternetConnected != null) {
        if (!value.isInternetConnected && isInternetConnected == true) {
          DbService.init().then((value) => ChatService.init());
        }
        value.isInternetConnected = isInternetConnected;
      }
    }

    notifyListeners();
  }
}
