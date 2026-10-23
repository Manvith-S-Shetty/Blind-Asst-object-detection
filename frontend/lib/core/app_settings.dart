import 'package:shared_preferences/shared_preferences.dart';

/// Centralized settings. Backend URL is configurable at runtime since a
/// student demoing on a phone needs to point at their laptop's LAN IP,
/// not localhost (localhost on the phone means the phone itself).
///
/// The default host (10.0.2.2) is the Android emulator's reverse proxy to
/// the host machine and is deliberately NOT a real LAN address.  The
/// [BackendConnectionManager] will detect this default, skip direct-connect,
/// and run mDNS discovery first.
class AppSettings {
  static const _kBackendHostKey = 'backend_host';
  static const _kBackendPortKey = 'backend_port';

  /// 10.0.2.2 is Android emulator loopback to the host machine.
  /// On a physical device this address is unreachable — used as the sentinel
  /// value to trigger mDNS discovery instead of direct-connect.
  static const defaultHost = '10.0.2.2';
  static const defaultPort = 8000;

  final String host;
  final int port;

  const AppSettings({this.host = defaultHost, this.port = defaultPort});

  /// Full HTTP base URL including the API prefix, e.g.:
  ///   http://192.168.1.5:8000/api/v1
  String get httpBase => 'http://$host:$port/api/v1';

  /// WebSocket base URL (no path), e.g.:
  ///   ws://192.168.1.5:8000
  String get wsBase => 'ws://$host:$port';

  /// Ultra-lightweight ping endpoint — does NOT trigger model loading.
  /// Used by BackendConnectionManager for fast reachability checks.
  String get pingUrl => 'http://$host:$port/ping';

  /// True when this is the sentinel emulator address (discovery not yet run).
  bool get isDefaultEmulatorAddress =>
      host == defaultHost && port == defaultPort;

  static Future<AppSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    return AppSettings(
      host: prefs.getString(_kBackendHostKey) ?? defaultHost,
      port: prefs.getInt(_kBackendPortKey) ?? defaultPort,
    );
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kBackendHostKey, host);
    await prefs.setInt(_kBackendPortKey, port);
  }

  AppSettings copyWith({String? host, int? port}) =>
      AppSettings(host: host ?? this.host, port: port ?? this.port);

  @override
  String toString() => 'AppSettings($host:$port)';

  @override
  bool operator ==(Object other) =>
      other is AppSettings && other.host == host && other.port == port;

  @override
  int get hashCode => Object.hash(host, port);
}
