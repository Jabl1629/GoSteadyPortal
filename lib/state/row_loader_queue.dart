import 'dart:async';
import 'dart:collection';

/// Throttled async work queue.
///
/// Per phase-2b-fac-r-facility-reads.md L5 — Census list-view per-row
/// stats fetches (`rowStatsFor` + `notificationsFor`) need a concurrency
/// cap so a 200-patient cold-load doesn't burst past dev API Gateway's
/// 25 RPS sustained throttle. The Census view wraps each row in a
/// `VisibilityDetector` and enqueues the row's load when it first
/// scrolls into view; the queue runs up to [maxConcurrent] tasks at
/// once and serializes the rest.
///
/// Dedup: callers pass a `key` (`patientId`). Re-enqueueing the same
/// key while the prior task is still pending (queued or in-flight)
/// returns the existing Future — useful since `VisibilityDetector`
/// fires `onVisibilityChanged` repeatedly as the user scrolls.
///
/// Errors propagate to the caller's Future; the queue itself does
/// not retry. Successful completion drops the key from the in-flight
/// map and pumps the next pending task.
class RowLoaderQueue<T> {
  RowLoaderQueue({this.maxConcurrent = 5});

  final int maxConcurrent;

  final Map<String, Future<T>> _inFlight = {};
  final Queue<_Pending<T>> _pending = Queue();
  int _running = 0;

  /// Enqueue [task] under [key]. Returns the existing Future if the
  /// same key is already pending or in-flight (dedup).
  Future<T> enqueue(String key, Future<T> Function() task) {
    final existing = _inFlight[key];
    if (existing != null) return existing;

    final completer = Completer<T>();
    _inFlight[key] = completer.future;
    _pending.add(_Pending(key, task, completer));
    _pump();
    return completer.future;
  }

  /// Drop a key from tracking — useful when a row scrolls off-screen
  /// and the caller no longer cares about the result. Does not cancel
  /// an in-flight task (Dart Futures are not cancellable); a future
  /// re-enqueue after this clear will fire a fresh task.
  void forget(String key) {
    _inFlight.remove(key);
  }

  void clear() {
    _inFlight.clear();
    _pending.clear();
  }

  void _pump() {
    while (_running < maxConcurrent && _pending.isNotEmpty) {
      final next = _pending.removeFirst();
      _running++;
      next.task().then((value) {
        _running--;
        _inFlight.remove(next.key);
        next.completer.complete(value);
        _pump();
      }, onError: (Object error, StackTrace stack) {
        _running--;
        _inFlight.remove(next.key);
        next.completer.completeError(error, stack);
        _pump();
      });
    }
  }
}

class _Pending<T> {
  _Pending(this.key, this.task, this.completer);

  final String key;
  final Future<T> Function() task;
  final Completer<T> completer;
}
