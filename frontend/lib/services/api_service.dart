import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:blind_assistant/core/app_settings.dart';

class ApiService {
  final AppSettings settings;
  ApiService(this.settings);

  Future<String> startSession() async {
    final res = await http.post(Uri.parse('${settings.httpBase}/session/start'));
    if (res.statusCode != 200) {
      throw Exception('Failed to start session: ${res.statusCode} ${res.body}');
    }
    return (json.decode(res.body) as Map<String, dynamic>)['session_id'] as String;
  }

  Future<void> endSession(String sessionId) async {
    await http.post(Uri.parse('${settings.httpBase}/session/$sessionId/end'));
  }

  /// Ultra-lightweight reachability probe that uses the /ping endpoint.
  /// /ping returns 200 immediately and does NOT trigger model loading.
  /// Falls back to /api/v1/health if /ping is unavailable (older backend).
  Future<bool> checkHealth() async {
    // Primary: /ping (fast, no model initialization)
    try {
      final res = await http
          .get(Uri.parse(settings.pingUrl))
          .timeout(const Duration(seconds: 3));
      if (res.statusCode == 200) return true;
    } catch (_) {}

    // Fallback: /api/v1/health (may trigger model warmup on cold start)
    try {
      final res = await http
          .get(Uri.parse('${settings.httpBase}/health'))
          .timeout(const Duration(seconds: 5));
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  Future<Map<String, dynamic>> describeScene(String sessionId, String imageBase64) async {
    final res = await http.post(
      Uri.parse('${settings.httpBase}/session/$sessionId/describe-scene'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({'image_base64': imageBase64}),
    );
    return json.decode(res.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> readText(String sessionId, String imageBase64) async {
    final res = await http.post(
      Uri.parse('${settings.httpBase}/session/$sessionId/read-text'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({'image_base64': imageBase64}),
    );
    return json.decode(res.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> findObject(
      String sessionId, String imageBase64, String query) async {
    final res = await http.post(
      Uri.parse('${settings.httpBase}/session/$sessionId/find-object'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({'image_base64': imageBase64, 'query': query}),
    );
    return json.decode(res.body) as Map<String, dynamic>;
  }
}
