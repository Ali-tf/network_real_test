import 'dart:async';
import 'dart:io';

/// A centralized registry for tracking and forcefully cleaning up all resources
/// (sockets, clients, streams, timers, workers) associated with a speed test.
///
/// Ensures 100% cleanup of background "zombies" when a test is cancelled
/// by the user or timed out by the orchestrator.
class TestLifecycle {
  // Simple boolean flags replace scattered `_isCancelled` variables.
  bool _isUserCancelled = false;
  bool _isTimedOut = false;

  /// True if the user pressed the Cancel button.
  bool get isUserCancelled => _isUserCancelled;

  /// True if a lifecycle Timer expired (e.g., 15s phase limit).
  bool get isTimedOut => _isTimedOut;

  /// The single source of truth for flow-control loops.
  bool get shouldStop => _isUserCancelled || _isTimedOut;

  // ── Resource Registries ──
  final List<HttpClient> _clients = [];
  final List<Socket> _sockets = [];
  final List<Timer> _timers = [];
  final List<Future<void>> _workers = [];

  // ── Phase Synchronization ──
  Completer<void>? _phaseCompleter;

  // ══════════════════════════════════════════════════════════════════
  // Registration Methods (Contract 1: Register at Birth)
  // ══════════════════════════════════════════════════════════════════

  /// Tracks an HttpClient. If already stopped, it is closed immediately.
  void registerClient(HttpClient client) {
    if (shouldStop) {
      client.close(force: true);
      return;
    }
    _clients.add(client);
  }

  /// Tracks a raw Socket. If already stopped, it is destroyed immediately.
  void registerSocket(Socket socket) {
    if (shouldStop) {
      socket.destroy();
      return;
    }
    _sockets.add(socket);
  }

  /// Tracks a Timer. If already stopped, it is cancelled immediately.
  void registerTimer(Timer timer) {
    if (shouldStop) {
      timer.cancel();
      return;
    }
    _timers.add(timer);
  }

  // ══════════════════════════════════════════════════════════════════
  // Worker Tracking (Contract 2: Await at Death)
  // ══════════════════════════════════════════════════════════════════

  /// Launches a strictly tracked asynchronous worker.
  /// The future returned by [workerBody] is safely swallowed internally
  /// to prevent unhandled rejection crashes, but monitored for completion.
  void launchWorker(Future<void> Function() workerBody) {
    final future = workerBody().catchError((_) {
      // Swallowed: We don't care about SocketExceptions during cancellation.
    });
    _workers.add(future);
  }

  /// Blocks until every launched worker finishes its Future.
  /// Must be called at the very end of EVERY distinct phase (download/upload)
  /// BEFORE returning the phase result or moving to the next phase.
  Future<void> awaitAllWorkers() async {
    await Future.wait(_workers);
    _workers.clear(); // Ready for next phase (if any)
  }

  // ══════════════════════════════════════════════════════════════════
  // Lifecycle Mutators
  // ══════════════════════════════════════════════════════════════════

  /// Prepares the lifecycle for a brand new test.
  /// Clears all registries and sets flags to false.
  void reset() {
    _isUserCancelled = false;
    _isTimedOut = false;
    _clients.clear();
    _sockets.clear();
    _timers.clear();
    _workers.clear();
    _phaseCompleter = null;
  }

  /// Start a new phase (e.g., Download or Upload).
  /// Required if you use [completePhase] and [awaitPhaseComplete].
  void beginPhase() {
    _isTimedOut = false;
    _phaseCompleter = Completer<void>();
  }

  /// Signal that the phase has naturally reached its conclusion.
  void completePhase() {
    if (_phaseCompleter != null && !_phaseCompleter!.isCompleted) {
      _phaseCompleter!.complete();
    }
  }

  /// Wait for [completePhase] or [timeoutPhase] to be called.
  Future<void> awaitPhaseComplete() {
    if (_phaseCompleter == null) {
      return Future.value();
    }
    return _phaseCompleter!.future;
  }

  /// Simulates a natural test timeout (e.g. 15s max per phase).
  /// Force-closes all network connections to force workers to drop.
  void timeoutPhase() {
    if (shouldStop) return;
    _isTimedOut = true;
    _nukeResources();
    completePhase();
  }

  // ══════════════════════════════════════════════════════════════════
  // Cancellation Execution (Contract 3: Cancel is Total & Instant)
  // ══════════════════════════════════════════════════════════════════

  /// Fired by the user pressing the red Cancel button on the UI.
  /// Unconditionally destroys everything. Does NOT wait for workers.
  void cancel() {
    if (shouldStop) return;
    _isUserCancelled = true;
    _nukeResources();
    completePhase(); // Unblock anyone waiting on the phase logic
  }

  /// The internal execution loop that destroys all tracked handles.
  void _nukeResources() {
    for (final timer in _timers) {
      timer.cancel();
    }
    _timers.clear();

    for (final socket in _sockets) {
      try {
        socket.destroy();
      } catch (_) {}
    }
    _sockets.clear();

    for (final client in _clients) {
      try {
        // Contract 4: Force-close always. TCP FIN is too slow.
        client.close(force: true);
      } catch (_) {}
    }
    _clients.clear();
  }
}
