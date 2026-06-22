// ai_service.dart
// Put this file anywhere in your Flutter project, e.g. lib/ai_service.dart
// Then add this import to your dashboard.dart:
//   import 'ai_service.dart';
//
// ── 2 things to fill in below ─────────────────────────────────────────────────
//   PROXY_URL  = the URL you get after deploying server.js  (e.g. https://myapp.onrender.com)
//   APP_SECRET = the same random string you set in the server's environment variables
// ─────────────────────────────────────────────────────────────────────────────

import 'dart:convert';
import 'package:http/http.dart' as http;

class AiService {
  static const _proxyUrl  = 'https://my-ai-proxy-v88t.onrender.com'; // ← change this
  static const _appSecret = 'myapp123secret';                       // ← change this

  /// Call this exactly like you called _callGemini() before.
  /// Returns the generated text string.
  /// Throws a String error message on failure.
  static Future<String> generate(
      String prompt, {
        double temperature = 0.7,
        int maxTokens = 500,
      }) async {
    try {
      final response = await http.post(
        Uri.parse('$_proxyUrl/generate'),
        headers: {
          'Content-Type': 'application/json',
          'X-App-Secret': _appSecret,
        },
        body: jsonEncode({
          'prompt':      prompt,
          'temperature': temperature,
          'maxTokens':   maxTokens,
        }),
      ).timeout(const Duration(seconds: 30));

      final body = jsonDecode(response.body) as Map<String, dynamic>;

      if (response.statusCode == 200) {
        final text = body['text'] as String?;
        if (text == null || text.isEmpty) throw 'Empty response from AI';
        return text;
      }

      throw body['error'] as String? ?? 'Error ${response.statusCode}';
    } on String {
      rethrow;
    } catch (e) {
      throw 'Network error: $e';
    }
  }

  /// Use this instead of your old _checkNetwork() method.
  static Future<bool> checkNetwork() async {
    try {
      await http
          .get(Uri.parse('$_proxyUrl/health'))
          .timeout(const Duration(seconds: 6));
      return true;
    } catch (_) {
      return false;
    }
  }
}