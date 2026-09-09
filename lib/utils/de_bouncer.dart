import 'dart:async';

class DeBouncer {
  DeBouncer(this.duration);

  Timer? timer;
  final Duration duration;

  void call(void Function() fn) {
    timer?.cancel();
    timer = Timer(duration, fn);
  }

  void cancel() => timer?.cancel();
}

class Throttler {
  Throttler(this.duration);

  final Duration duration;
  DateTime? _lastRun;

  Future<void> run(Future Function() action) async {
    final now = DateTime.now();
    if (_lastRun == null || now.difference(_lastRun!) > duration) {
      await action().then((value) => _lastRun = now);
    }
  }
}

class MutexRun<T> {
  Future<T>? _running;

  Future<T> run(Future<T> Function() action) {
    if (_running != null) {
      return _running!;
    }

    _running = action().whenComplete(() {
      _running = null;
    });

    return _running!;
  }
}

class QueueRun {
  final _queue = <_QueueItem>[];
  bool _isRunning = false;

  Future<T> run<T>(Future<T> Function() action) {
    final completer = Completer<T>();

    _queue.add(
      _QueueItem(
        action: () async => completer.complete(await action()),
        onError: (e, st) => completer.completeError(e, st),
      ),
    );

    _processQueue();
    return completer.future;
  }

  void _processQueue() async {
    if (_isRunning || _queue.isEmpty) return;
    _isRunning = true;

    while (_queue.isNotEmpty) {
      final item = _queue.removeAt(0);
      try {
        await item.action();
      } catch (e, st) {
        item.onError(e, st);
      }
    }

    _isRunning = false;
  }
}

class _QueueItem {
  _QueueItem({required this.action, required this.onError});
  final Future<void> Function() action;
  final Function(Object, StackTrace) onError;
}
