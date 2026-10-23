import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:nsd/nsd.dart';
import 'package:blind_assistant/core/app_settings.dart';

/// Connection states exposed to the UI.
enum ConnectionStatus {
  /// Initial state — no attempt has been made yet.
  idle,

  /// Actively trying to reach the backend (first attempt or reconnecting).
  connecting,

  /// Backend is reachable and the last health probe succeeded.
  connected,

  /// A previously successful connection was lost; retry is in progress.
  reconnecting,

  /// All discovery and retry attempts have been exhausted.
  unavailable,
}

/// Result from a single resolve+validate cycle.
class ResolvedEndpoint {
  final String host;
  final int port;

  const ResolvedEndpoint(this.host, this.port);

  String get httpBase => 'http://$host:$port/api/v1';
  String get wsBase => 'ws://$host:$port';
  String get pingUrl => 'http://$host:$port/ping';

  @override
  String toString() => '$host:$port';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ResolvedEndpoint &&
          runtimeType == other.runtimeType &&
          host == other.host &&
          port == other.port;

  @override
  int get hashCode => host.hashCode ^ port.hashCode;
}

/// Manages backend URL discovery, health validation, bounded reconnect,
/// and lifecycle transitions.  Consumers watch [status] and [currentSettings]
/// via [ChangeNotifier].
///
/// Priority order:
///   1. Production URL if configured via [AppSettings] (host != emulator defaults).
///   2. mDNS/DNS-SD discovery of _blindassist._tcp.local.
///   3. Cached last-known working address (re-validated before use).
///   4. Manual fallback (user must open Settings).
///
/// NOTE ON mDNS: Discovery requires the `nsd` Flutter package and the
/// CHANGE_NETWORK_STATE + ACCESS_WIFI_STATE permissions on Android.
/// It will fail silently if:
///   - The network blocks multicast (guest Wi-Fi isolation).
///   - The device is on a different subnet or behind a VPN.
///   - The backend's mDNS service (zeroconf) is not running.
/// In any failure case the manager logs a warning and offers manual fallback.
class BackendConnectionManager extends ChangeNotifier {
  static const _mDnsServiceType = '_blindassist._tcp';
  static const _pingTimeoutMs = 3000;
  static const _discoveryTimeoutMs = 5000;
  static const _maxRetryIntervalMs = 30000;
  static const _baseRetryIntervalMs = 1000;
  static const int _maxRetryAttempts = 8;

  AppSettings _settings;
  final http.Client? _httpClient;
  final Future<ResolvedEndpoint?> Function(Duration timeout)? _customDiscovery;
  ConnectionStatus _status = ConnectionStatus.idle;
  String? _statusMessage;
  int _retryCount = 0;
  bool _disposed = false;
  Timer? _retryTimer;
  Discovery? _discovery; // nsd discovery handle

  BackendConnectionManager(
    this._settings, {
    http.Client? httpClient,
    Future<ResolvedEndpoint?> Function(Duration timeout)? customDiscovery,
  })  : _httpClient = httpClient,
        _customDiscovery = customDiscovery;

  // --- Public state ---

  ConnectionStatus get status => _status;
  String? get statusMessage => _statusMessage;
  AppSettings get currentSettings => _settings;
  int get retryCount => _retryCount;

  bool get isConnected => _status == ConnectionStatus.connected;
  bool get isConnecting =>
      _status == ConnectionStatus.connecting ||
      _status == ConnectionStatus.reconnecting;

  // --- Lifecycle ---

  /// Begin connection process.  Call once after the widget tree is ready.
  Future<void> connect() async {
    if (_disposed) return;
    if (_status == ConnectionStatus.connecting ||
        _status == ConnectionStatus.reconnecting) {
      return;
    }

    _retryCount = 0;
    _setStatus(ConnectionStatus.connecting, 'Searching for backend…');
    await _attemptConnection();
  }

  /// Manually trigger a retry from the UI (e.g. after user taps "Retry").
  Future<void> retry() async {
    _retryTimer?.cancel();
    _retryTimer = null;
    _retryCount = 0;
    _setStatus(ConnectionStatus.connecting, 'Retrying…');
    await _attemptConnection();
  }

  /// Update the manually-configured backend URL (called from Settings screen).
  Future<void> applyManualSettings(AppSettings newSettings) async {
    _retryTimer?.cancel();
    _settings = newSettings;
    await newSettings.save();
    _retryCount = 0;
    _setStatus(ConnectionStatus.connecting, 'Trying saved address…');
    await _attemptConnection();
  }

  @override
  void dispose() {
    _disposed = true;
    _retryTimer?.cancel();
    _stopDiscovery();
    super.dispose();
  }

  // --- Connection logic ---

  Future<void> _attemptConnection() async {
    if (_disposed) return;

    // 1. Check if a non-default host is manually configured (production URL or
    //    a previously saved LAN IP).  Re-validate it before trusting it.
    final configured = _settings;
    final isDefaultEmulatorHost =
        configured.host == AppSettings.defaultHost &&
        configured.port == AppSettings.defaultPort;

    if (!isDefaultEmulatorHost) {
      final endpoint = ResolvedEndpoint(configured.host, configured.port);
      if (await _ping(endpoint)) {
        _onConnected(endpoint);
        return;
      }
      // Saved address is stale — fall through to mDNS discovery.
      _statusMessage = 'Saved address unreachable, searching…';
    }

    // 2. mDNS discovery
    final discovered = await _discoverViaMdns();
    if (discovered != null) {
      // Validate the resolved endpoint before trusting it
      if (await _ping(discovered)) {
        _onConnected(discovered);
        return;
      }
    }

    // 3. All attempts failed — schedule retry with bounded exponential backoff
    _scheduleRetry();
  }

  Future<ResolvedEndpoint?> _discoverViaMdns() async {
    _setStatus(
      _status == ConnectionStatus.reconnecting
          ? ConnectionStatus.reconnecting
          : ConnectionStatus.connecting,
      'Scanning local network via mDNS…',
    );

    if (_customDiscovery != null) {
      return await _customDiscovery(const Duration(milliseconds: _discoveryTimeoutMs));
    }

    final completer = Completer<ResolvedEndpoint?>();
    Discovery? discovery;

    try {
      discovery = await startDiscovery(_mDnsServiceType);
      _discovery = discovery;

      // Listen for the first resolved service
      discovery.addListener(() {
        if (completer.isCompleted) return;
        final services = discovery?.services ?? [];
        for (final svc in services) {
          final host = svc.host;
          final port = svc.port;
          if (host != null && host.isNotEmpty && port != null && port > 0) {
            completer.complete(ResolvedEndpoint(host, port));
            return;
          }
        }
      });

      // Race against timeout
      final result = await completer.future.timeout(
        const Duration(milliseconds: _discoveryTimeoutMs),
        onTimeout: () => null,
      );
      return result;
    } catch (e) {
      debugPrint('BackendConnectionManager: mDNS discovery error: $e');
      return null;
    } finally {
      _stopDiscovery();
    }
  }

  Future<bool> _ping(ResolvedEndpoint endpoint) async {
    try {
      final uri = Uri.parse(endpoint.pingUrl);
      final response = _httpClient != null
          ? await _httpClient.get(uri).timeout(const Duration(milliseconds: _pingTimeoutMs))
          : await http.get(uri).timeout(const Duration(milliseconds: _pingTimeoutMs));
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  void _onConnected(ResolvedEndpoint endpoint) {
    if (_disposed) return;
    _retryCount = 0;
    // Persist the working address so next launch can revalidate it
    final updatedSettings = AppSettings(host: endpoint.host, port: endpoint.port);
    updatedSettings.save(); // fire-and-forget
    _settings = updatedSettings;
    _setStatus(
      ConnectionStatus.connected,
      'Connected to ${endpoint.host}:${endpoint.port}',
    );
  }

  void _scheduleRetry() {
    if (_disposed) return;
    if (_retryCount >= _maxRetryAttempts) {
      _setStatus(
        ConnectionStatus.unavailable,
        'Backend unavailable.  Check that the server is running and tap Retry.',
      );
      return;
    }

    final delayMs = min(
      _baseRetryIntervalMs * (1 << _retryCount), // 1s, 2s, 4s, 8s … capped
      _maxRetryIntervalMs,
    );
    _retryCount++;
    _setStatus(
      ConnectionStatus.reconnecting,
      'Backend unreachable — retrying in ${(delayMs / 1000).toStringAsFixed(0)}s '
      '(attempt $_retryCount / $_maxRetryAttempts)…',
    );

    _retryTimer?.cancel();
    _retryTimer = Timer(Duration(milliseconds: delayMs), () {
      if (!_disposed) _attemptConnection();
    });
  }

  void _setStatus(ConnectionStatus status, [String? message]) {
    if (_disposed) return;
    _status = status;
    _statusMessage = message;
    notifyListeners();
  }

  void _stopDiscovery() {
    final d = _discovery;
    _discovery = null;
    if (d != null) {
      try {
        stopDiscovery(d);
      } catch (_) {}
    }
  }
}
