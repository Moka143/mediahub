import 'dart:async';

import 'package:flutter/foundation.dart';

/// A utility class for debouncing function calls.
///
/// Debouncing ensures that a function is only called after a specified
/// delay has passed since the last invocation. This is useful for
/// reducing API calls during rapid user interactions.
class Debouncer {
  final Duration delay;
  Timer? _timer;

  /// Creates a debouncer with the specified [delay].
  ///
  /// Default delay is 300 milliseconds.
  Debouncer({this.delay = const Duration(milliseconds: 300)});

  /// Runs the [action] after the debounce delay.
  ///
  /// If called again before the delay expires, the previous
  /// pending action is cancelled and the timer resets.
  void run(VoidCallback action) {
    _timer?.cancel();
    _timer = Timer(delay, action);
  }

  /// Cancels any pending action.
  void cancel() {
    _timer?.cancel();
    _timer = null;
  }

  /// Whether there's a pending action.
  bool get isPending => _timer?.isActive ?? false;

  /// Disposes the debouncer, cancelling any pending action.
  void dispose() {
    cancel();
  }
}

/// A debouncer that also tracks the last value passed to it.
///
/// Useful for debouncing search inputs where you need to
/// access the most recent value.
class ValueDebouncer<T> {
  final Duration delay;
  Timer? _timer;
  T? _lastValue;

  ValueDebouncer({this.delay = const Duration(milliseconds: 300)});

  /// The last value that was passed to [run].
  T? get lastValue => _lastValue;

  /// Runs the [action] with the given [value] after the debounce delay.
  void run(T value, void Function(T) action) {
    _lastValue = value;
    _timer?.cancel();
    _timer = Timer(delay, () => action(value));
  }

  /// Cancels any pending action.
  void cancel() {
    _timer?.cancel();
    _timer = null;
  }

  /// Whether there's a pending action.
  bool get isPending => _timer?.isActive ?? false;

  /// Disposes the debouncer.
  void dispose() {
    cancel();
  }
}
