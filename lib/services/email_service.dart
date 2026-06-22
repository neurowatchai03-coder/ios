import 'dart:convert';
import 'package:http/http.dart' as http;

class EmailService {
  // ── Brevo API Config ──────────────────────────────────────────────────
  // Get your API key from: https://app.brevo.com/settings/keys/api
  static const String _apiKey      = "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"; // starts with xkeysib-
  static const String _fromEmail   = "neurowatchai03@gmail.com";
  static const String _fromName    = "OTP Verification";

  static Future<bool> sendOtpEmail({
    required String email,
    required String otp,
  }) async {
    print('[EmailService] Attempting to send OTP: $otp to: $email');

    try {
      final response = await http.post(
        Uri.parse('https://api.brevo.com/v3/smtp/email'),
        headers: {
          'api-key': _apiKey,
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'sender': {
            'name':  _fromName,
            'email': _fromEmail,
          },
          'to': [
            {'email': email}
          ],
          'subject': 'Your Verification Code',
          'htmlContent': _buildHtml(otp, email),
        }),
      );

      if (response.statusCode == 201) {
        print('[EmailService] Sent successfully');
        return true;
      }

      print('[EmailService] Failed: ${response.statusCode} ${response.body}');
      return false;
    } catch (e) {
      print('[EmailService] Exception: $e');
      return false;
    }
  }

  static String _buildHtml(String otp, String email) => """
<!DOCTYPE html>
<html>
<body style="margin:0;padding:0;background:#f4f4f4;font-family:Arial,sans-serif;">
  <table width="100%" cellpadding="0" cellspacing="0">
    <tr>
      <td align="center" style="padding:40px 0;">
        <table width="480" cellpadding="0" cellspacing="0"
               style="background:#ffffff;border-radius:12px;
                      box-shadow:0 2px 8px rgba(0,0,0,0.08);
                      padding:40px 36px;">
          <tr>
            <td align="center" style="padding-bottom:24px;">
              <div style="font-size:28px;font-weight:700;color:#48249A;">
                Email Verification
              </div>
            </td>
          </tr>
          <tr>
            <td style="font-size:15px;color:#444444;line-height:1.6;padding-bottom:28px;">
              Hi there,<br><br>
              Use the code below to verify <strong>$email</strong>.
              It expires in <strong>10 minutes</strong>.
            </td>
          </tr>
          <tr>
            <td align="center" style="padding-bottom:28px;">
              <div style="display:inline-block;
                          background:#f0ebff;
                          border:2px dashed #48249A;
                          border-radius:12px;
                          padding:18px 40px;
                          font-size:36px;
                          font-weight:700;
                          letter-spacing:10px;
                          color:#48249A;">
                $otp
              </div>
            </td>
          </tr>
          <tr>
            <td style="font-size:13px;color:#888888;line-height:1.5;">
              If you did not request this, you can safely ignore this email.
            </td>
          </tr>
        </table>
      </td>
    </tr>
  </table>
</body>
</html>
""";
}

