import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:blind_assistant/core/providers.dart';
import 'package:blind_assistant/core/theme.dart';
import 'package:blind_assistant/services/backend_connection_manager.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  late TextEditingController _hostController;
  late TextEditingController _portController;
  bool? _connectionOk;
  bool _showQr = false;

  @override
  void initState() {
    super.initState();
    final settings = ref.read(settingsProvider);
    _hostController = TextEditingController(text: settings.host);
    _portController = TextEditingController(text: settings.port.toString());
  }

  @override
  void dispose() {
    _hostController.dispose();
    _portController.dispose();
    super.dispose();
  }

  Future<void> _applyAndTest() async {
    final host = _hostController.text.trim();
    final port = int.tryParse(_portController.text.trim()) ?? 8000;

    // Push new settings through the connection manager so discovery cache is
    // cleared and the new address is re-validated.
    final manager = ref.read(connectionManagerProvider);
    await manager.applyManualSettings(
      ref.read(settingsProvider).copyWith(host: host, port: port),
    );

    setState(() => _connectionOk = manager.isConnected);
  }

  /// Build a QR code containing the backend HTTP base URL.
  /// The URL can be scanned by another device or used as a quick share
  /// mechanism to hand off the server address without typing.
  String _qrData(String host, int port) => 'http://$host:$port/api/v1';

  @override
  Widget build(BuildContext context) {
    final connectionManager = ref.watch(connectionManagerProvider);
    final currentSettings = connectionManager.currentSettings;
    final status = connectionManager.status;

    // Keep text fields in sync if auto-discovery updated the address
    final autoHost = currentSettings.host;
    final autoPort = currentSettings.port;

    final statusColor = switch (status) {
      ConnectionStatus.connected => AppTheme.infoColor,
      ConnectionStatus.connecting => Colors.amber,
      ConnectionStatus.reconnecting => Colors.orange,
      ConnectionStatus.unavailable => AppTheme.urgentColor,
      _ => Colors.white38,
    };

    final statusLabel = switch (status) {
      ConnectionStatus.connected =>
        '✅ Connected — ${currentSettings.host}:${currentSettings.port}',
      ConnectionStatus.connecting => '🔍 ${connectionManager.statusMessage ?? "Searching…"}',
      ConnectionStatus.reconnecting =>
        '🔄 ${connectionManager.statusMessage ?? "Reconnecting…"}',
      ConnectionStatus.unavailable => '❌ Backend unavailable',
      _ => '⏳ Initialising…',
    };

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // --- Connection status ---
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: statusColor.withValues(alpha: 0.12),
                border: Border.all(color: statusColor, width: 1.5),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                statusLabel,
                style: TextStyle(color: statusColor, fontSize: 16, fontWeight: FontWeight.w600),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: 8),
            if (status == ConnectionStatus.connected)
              const Text(
                'Auto-discovered via mDNS or saved address.',
                style: TextStyle(color: Colors.white54, fontSize: 13),
                textAlign: TextAlign.center,
              ),
            const SizedBox(height: 20),

            // --- Auto-discovered address display ---
            if (status == ConnectionStatus.connected &&
                !currentSettings.isDefaultEmulatorAddress) ...[
              const Text(
                'Auto-discovered backend',
                style: TextStyle(fontSize: 15, color: Colors.white70),
              ),
              const SizedBox(height: 4),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: Colors.white10,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SelectableText(
                  '${currentSettings.host}:${currentSettings.port}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
              const SizedBox(height: 20),
            ],

            // --- Manual override ---
            const Text(
              'Manual backend address',
              style: TextStyle(fontSize: 18, color: Colors.white70),
            ),
            const SizedBox(height: 6),
            const Text(
              'Use 10.0.2.2 for the Android emulator.\n'
              'Use your laptop\'s LAN IP (e.g. 192.168.1.5) for a real phone '
              'on the same Wi-Fi.\n'
              'Run the backend with:\n'
              '  uvicorn app.main:app --host 0.0.0.0 --port 8000',
              style: TextStyle(fontSize: 13, color: Colors.white54),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _hostController,
              style: const TextStyle(color: Colors.white, fontSize: 18),
              decoration: const InputDecoration(labelText: 'Host / IP'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _portController,
              keyboardType: TextInputType.number,
              style: const TextStyle(color: Colors.white, fontSize: 18),
              decoration: const InputDecoration(labelText: 'Port'),
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: _applyAndTest,
              style: ElevatedButton.styleFrom(
                shape: const StadiumBorder(),
                minimumSize: const Size(double.infinity, 52),
              ),
              child: const Text('Save & Test Connection', style: TextStyle(fontSize: 18)),
            ),
            const SizedBox(height: 16),
            if (_connectionOk != null)
              Text(
                _connectionOk! ? '✅ Connected to backend' : '❌ Could not reach backend',
                style: TextStyle(
                  fontSize: 16,
                  color: _connectionOk! ? Colors.greenAccent : Colors.redAccent,
                ),
                textAlign: TextAlign.center,
              ),

            const SizedBox(height: 28),

            // --- QR code fallback ---
            const Text(
              'Share server URL via QR',
              style: TextStyle(fontSize: 15, color: Colors.white70),
            ),
            const SizedBox(height: 6),
            const Text(
              'If mDNS is blocked (guest Wi-Fi, VPN), show this QR code to '
              'another device or use it to copy the address quickly.',
              style: TextStyle(fontSize: 13, color: Colors.white38),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              icon: Icon(_showQr ? Icons.qr_code_2 : Icons.qr_code),
              label: Text(_showQr ? 'Hide QR Code' : 'Show QR Code'),
              onPressed: () => setState(() => _showQr = !_showQr),
              style: OutlinedButton.styleFrom(foregroundColor: Colors.white70),
            ),
            if (_showQr) ...[
              const SizedBox(height: 16),
              Center(
                child: QrImageView(
                  data: _qrData(autoHost, autoPort),
                  version: QrVersions.auto,
                  size: 200,
                  backgroundColor: Colors.white,
                  errorStateBuilder: (ctx, err) => const Text(
                    'Could not generate QR code.',
                    style: TextStyle(color: Colors.redAccent),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                _qrData(autoHost, autoPort),
                style: const TextStyle(
                  color: Colors.white54,
                  fontSize: 12,
                  fontFamily: 'monospace',
                ),
                textAlign: TextAlign.center,
              ),
            ],

            const SizedBox(height: 28),

            // --- Discovery limitations notice ---
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.amber.withValues(alpha: 0.08),
                border: Border.all(color: Colors.amber.shade700, width: 1),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Text(
                '⚠️  mDNS Discovery Limitations\n\n'
                '• Guest Wi-Fi networks that block multicast will prevent discovery.\n'
                '• VPN tunnels or routers that block UDP port 5353 will prevent discovery.\n'
                '• Devices on different subnets cannot see each other via mDNS.\n'
                '• In any of these cases, use manual IP entry above or scan the QR code.',
                style: TextStyle(color: Colors.amber, fontSize: 13),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
