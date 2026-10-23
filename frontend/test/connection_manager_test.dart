import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:blind_assistant/core/app_settings.dart';
import 'package:blind_assistant/services/backend_connection_manager.dart';

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
  });

  group('AppSettings URL and WebSocket construction', () {
    test('Default emulator host constructed properly', () {
      const settings = AppSettings();
      expect(settings.host, '10.0.2.2');
      expect(settings.port, 8000);
      expect(settings.httpBase, 'http://10.0.2.2:8000/api/v1');
      expect(settings.wsBase, 'ws://10.0.2.2:8000');
      expect(settings.pingUrl, 'http://10.0.2.2:8000/ping');
      expect(settings.isDefaultEmulatorAddress, isTrue);
    });

    test('Custom LAN host constructed properly', () {
      const settings = AppSettings(host: '192.168.1.5', port: 8000);
      expect(settings.host, '192.168.1.5');
      expect(settings.port, 8000);
      expect(settings.httpBase, 'http://192.168.1.5:8000/api/v1');
      expect(settings.wsBase, 'ws://192.168.1.5:8000');
      expect(settings.pingUrl, 'http://192.168.1.5:8000/ping');
      expect(settings.isDefaultEmulatorAddress, isFalse);
    });

    test('ResolvedEndpoint properties match AppSettings contract', () {
      const endpoint = ResolvedEndpoint('192.168.1.42', 8000);
      expect(endpoint.host, '192.168.1.42');
      expect(endpoint.port, 8000);
      expect(endpoint.httpBase, 'http://192.168.1.42:8000/api/v1');
      expect(endpoint.wsBase, 'ws://192.168.1.42:8000');
      expect(endpoint.pingUrl, 'http://192.168.1.42:8000/ping');
      expect(endpoint.toString(), '192.168.1.42:8000');
    });

    test('Value equality works for AppSettings and ResolvedEndpoint', () {
      const s1 = AppSettings(host: '10.0.0.1', port: 8000);
      const s2 = AppSettings(host: '10.0.0.1', port: 8000);
      const s3 = AppSettings(host: '10.0.0.2', port: 8000);
      expect(s1, equals(s2));
      expect(s1 == s3, isFalse);

      const e1 = ResolvedEndpoint('10.0.0.1', 8000);
      const e2 = ResolvedEndpoint('10.0.0.1', 8000);
      const e3 = ResolvedEndpoint('10.0.0.2', 8000);
      expect(e1, equals(e2));
      expect(e1 == e3, isFalse);
    });
  });

  group('BackendConnectionManager Auto-discovery & Revalidation', () {
    test('Direct-connects if cached/saved address is valid and reachable', () async {
      var pingCalls = 0;
      final mockClient = MockClient((request) async {
        if (request.url.path == '/ping') {
          pingCalls++;
          return http.Response('{"status":"ok"}', 200);
        }
        return http.Response('Not Found', 404);
      });

      var mdnsCalled = false;
      final manager = BackendConnectionManager(
        const AppSettings(host: '192.168.1.5', port: 8000),
        httpClient: mockClient,
        customDiscovery: (_) async {
          mdnsCalled = true;
          return null;
        },
      );

      expect(manager.status, ConnectionStatus.idle);
      await manager.connect();

      expect(manager.status, ConnectionStatus.connected);
      expect(manager.isConnected, isTrue);
      expect(manager.currentSettings.host, '192.168.1.5');
      expect(pingCalls, 1);
      expect(mdnsCalled, isFalse); // Skipped mDNS because cached address was reachable
      manager.dispose();
    });

    test('Stale cached address falls back to mDNS discovery', () async {
      final mockClient = MockClient((request) async {
        if (request.url.host == '192.168.1.5') {
          // Stale address: fails to respond
          throw http.ClientException('Connection refused');
        }
        if (request.url.host == '192.168.1.88' && request.url.path == '/ping') {
          // Discovered address: succeeds
          return http.Response('{"status":"ok"}', 200);
        }
        return http.Response('Not Found', 404);
      });

      var mdnsCalled = false;
      final manager = BackendConnectionManager(
        const AppSettings(host: '192.168.1.5', port: 8000),
        httpClient: mockClient,
        customDiscovery: (_) async {
          mdnsCalled = true;
          return const ResolvedEndpoint('192.168.1.88', 8000);
        },
      );

      await manager.connect();

      expect(mdnsCalled, isTrue);
      expect(manager.status, ConnectionStatus.connected);
      expect(manager.isConnected, isTrue);
      expect(manager.currentSettings.host, '192.168.1.88');
      manager.dispose();
    });

    test('Default emulator address skips direct-connect and uses mDNS', () async {
      final mockClient = MockClient((request) async {
        if (request.url.host == '192.168.1.99' && request.url.path == '/ping') {
          return http.Response('{"status":"ok"}', 200);
        }
        return http.Response('Error', 500);
      });

      var mdnsCalled = false;
      final manager = BackendConnectionManager(
        const AppSettings(), // default 10.0.2.2
        httpClient: mockClient,
        customDiscovery: (_) async {
          mdnsCalled = true;
          return const ResolvedEndpoint('192.168.1.99', 8000);
        },
      );

      await manager.connect();

      expect(mdnsCalled, isTrue);
      expect(manager.status, ConnectionStatus.connected);
      expect(manager.currentSettings.host, '192.168.1.99');
      manager.dispose();
    });

    test('Discovery timeout or no server found schedules retry with exponential backoff', () async {
      final mockClient = MockClient((_) async => http.Response('Error', 500));

      final manager = BackendConnectionManager(
        const AppSettings(),
        httpClient: mockClient,
        customDiscovery: (_) async => null, // Discovery returned nothing
      );

      await manager.connect();

      expect(manager.status, ConnectionStatus.reconnecting);
      expect(manager.isConnected, isFalse);
      expect(manager.retryCount, 1);
      expect(manager.statusMessage, contains('attempt 1 / 8'));
      manager.dispose();
    });

    test('Invalid discovery response (discovered endpoint fails health probe) triggers retry', () async {
      final mockClient = MockClient((request) async {
        // Discovered host is unreachable or unhealthy
        return http.Response('Internal Error', 500);
      });

      final manager = BackendConnectionManager(
        const AppSettings(),
        httpClient: mockClient,
        customDiscovery: (_) async => const ResolvedEndpoint('192.168.1.200', 8000),
      );

      await manager.connect();

      expect(manager.status, ConnectionStatus.reconnecting);
      expect(manager.retryCount, 1);
      manager.dispose();
    });

    test('Duplicate connect() while already connecting is ignored', () async {
      final completer = Completer<ResolvedEndpoint?>();
      var discoveryInvocations = 0;

      final manager = BackendConnectionManager(
        const AppSettings(),
        customDiscovery: (_) {
          discoveryInvocations++;
          return completer.future;
        },
      );

      final f1 = manager.connect();
      final f2 = manager.connect(); // Second call while f1 is pending

      expect(manager.isConnecting, isTrue);
      expect(discoveryInvocations, 1); // Only one discovery cycle initiated

      completer.complete(null);
      await f1;
      await f2;
      manager.dispose();
    });

    test('Manual retry() resets backoff and attempts immediate connection', () async {
      var serverRunning = false;
      final mockClient = MockClient((request) async {
        if (serverRunning && request.url.host == '192.168.1.77' && request.url.path == '/ping') {
          return http.Response('{"status":"ok"}', 200);
        }
        return http.Response('Error', 500);
      });

      final manager = BackendConnectionManager(
        const AppSettings(),
        httpClient: mockClient,
        customDiscovery: (_) async {
          if (serverRunning) {
            return const ResolvedEndpoint('192.168.1.77', 8000);
          }
          return null;
        },
      );

      await manager.connect();
      expect(manager.status, ConnectionStatus.reconnecting);
      expect(manager.retryCount, 1);

      // Backend comes online; trigger manual retry
      serverRunning = true;
      await manager.retry();
      expect(manager.status, ConnectionStatus.connected);
      expect(manager.currentSettings.host, '192.168.1.77');
      manager.dispose();
    });

    test('applyManualSettings updates configuration and verifies new address', () async {
      final mockClient = MockClient((request) async {
        if (request.url.host == '10.0.0.50' && request.url.path == '/ping') {
          return http.Response('{"status":"ok"}', 200);
        }
        return http.Response('Error', 500);
      });

      final manager = BackendConnectionManager(
        const AppSettings(),
        httpClient: mockClient,
        customDiscovery: (_) async => null,
      );

      await manager.connect();
      expect(manager.isConnected, isFalse);

      await manager.applyManualSettings(const AppSettings(host: '10.0.0.50', port: 8000));
      expect(manager.status, ConnectionStatus.connected);
      expect(manager.currentSettings.host, '10.0.0.50');
      manager.dispose();
    });

    test('Dispose cancels pending timers and suppresses state notifications', () async {
      final manager = BackendConnectionManager(
        const AppSettings(),
        customDiscovery: (_) async => null,
      );

      var notifiedAfterDispose = false;
      manager.addListener(() {
        if (notifiedAfterDispose) {
          fail('Listener called after dispose');
        }
      });

      await manager.connect();
      expect(manager.status, ConnectionStatus.reconnecting);

      manager.dispose();
      notifiedAfterDispose = true;

      // Ensure calling retry or connect after dispose does nothing
      await manager.retry();
      await manager.connect();
    });
  });
}
