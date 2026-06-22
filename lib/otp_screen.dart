import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import 'login_screen.dart';
import 'services/email_service.dart';

////////////////////////////////////////////////////////////
/// OTP SCREEN
/// Shows 6 individual digit boxes.
/// Reads the OTP stored in Firestore users/{email}.otp
/// (written by RegisterScreen).
/// On success → marks verified:true in Firestore → LoginScreen.
///
/// In production, replace the Firestore OTP read with an
/// email-delivery service (SendGrid, Firebase Extensions, etc.)
/// and remove the OTP from the Firestore document.
////////////////////////////////////////////////////////////

class OtpScreen extends StatefulWidget {
  final String email;
  final String name;

  const OtpScreen({super.key, required this.email, required this.name});

  @override
  State<OtpScreen> createState() => _OtpScreenState();
}

class _OtpScreenState extends State<OtpScreen> {
  // ── 6 controllers + focus nodes ───────────────────────────────────────────
  final List<TextEditingController> _controllers =
  List.generate(6, (_) => TextEditingController());
  final List<FocusNode> _focusNodes =
  List.generate(6, (_) => FocusNode());

  bool   _loading = false;
  bool   _resending = false;
  String _error   = "";
  String _success = "";

  @override
  void dispose() {
    for (final c in _controllers) { c.dispose(); }
    for (final f in _focusNodes)  { f.dispose(); }
    super.dispose();
  }

  // ── Get entered OTP ───────────────────────────────────────────────────────

  String get _enteredOtp =>
      _controllers.map((c) => c.text).join();

  // ── Verify ────────────────────────────────────────────────────────────────

  Future<void> _verify() async {
    setState(() { _error = ""; _success = ""; });

    final entered = _enteredOtp.trim();
    if (entered.length < 6) {
      setState(() { _error = "Please enter all 6 digits"; });
      return;
    }

    setState(() { _loading = true; });

    try {
      final doc = await FirebaseFirestore.instance
          .collection("users")
          .doc(widget.email)
          .get();

      if (!doc.exists) {
        setState(() {
          _error   = "Registration record not found. Please register again.";
          _loading = false;
        });
        return;
      }

      final data = doc.data()!;
      final storedOtp = data["otp"] as String? ?? "";

      // Optional: check OTP expiry (10 minutes)
      final createdAt = data["otpCreatedAt"] as String? ?? "";
      if (createdAt.isNotEmpty) {
        final created = DateTime.tryParse(createdAt);
        if (created != null &&
            DateTime.now().difference(created).inMinutes > 10) {
          setState(() {
            _error   = "OTP expired. Please request a new one.";
            _loading = false;
          });
          return;
        }
      }

      if (entered != storedOtp) {
        setState(() {
          _error   = "Incorrect OTP. Please try again.";
          _loading = false;
        });
        return;
      }

      // Mark verified & clear OTP
      await FirebaseFirestore.instance
          .collection("users")
          .doc(widget.email)
          .update({
        "verified": true,
        "otp": FieldValue.delete(),
        "otpCreatedAt": FieldValue.delete(),
        "verifiedAt": DateTime.now().toIso8601String(),
      });

      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const LoginScreen()),
      );
    } catch (e) {
      setState(() {
        _error   = "Verification failed. Please try again.";
        _loading = false;
      });
      debugPrint("OTP verify error: $e");
    }
  }

  // ── Resend OTP ────────────────────────────────────────────────────────────

  Future<void> _resend() async {
    setState(() {
      _resending = true;
      _error = "";
      _success = "";
    });

    try {
      final otp =
      (100000 + (DateTime.now().millisecondsSinceEpoch % 900000))
          .toString();

      // Update OTP in Firestore
      await FirebaseFirestore.instance
          .collection("users")
          .doc(widget.email)
          .update({
        "otp": otp,
        "otpCreatedAt": DateTime.now().toIso8601String(),
      });

      // Send OTP email
      final emailSent = await EmailService.sendOtpEmail(
        email: widget.email,
        otp: otp,
      );

      if (!emailSent) {
        setState(() {
          _error = "Failed to send email OTP.";
          _resending = false;
        });
        return;
      }

      setState(() {
        _success = "A new OTP has been sent to ${widget.email}";
        _resending = false;
      });

      for (final c in _controllers) {
        c.clear();
      }

      _focusNodes[0].requestFocus();
    } catch (e) {
      setState(() {
        _error = "Failed to resend OTP. Try again.";
        _resending = false;
      });

      debugPrint("Resend OTP error: $e");
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFFFFFF),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(28, 0, 28, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [

                // ── Logo ───────────────────────────────────────────────────
                Center(
                  child: Image.asset(
                    'assets/logo.png',
                    height: 200,
                    width: 500,
                    fit: BoxFit.fill,
                    errorBuilder: (_, __, ___) => const Icon(
                      Icons.security_rounded,
                      size: 100,
                      color: Color(0xFF4CAF50),
                    ),
                  ),
                ),

                // ── Heading ────────────────────────────────────────────────
                const Text(
                  "Verify Your Email",
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    color: Colors.deepPurple,
                    letterSpacing: 0.3,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  "We've sent a 6-digit code to\n${widget.email}",
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 13, color: Colors.black54),
                ),
                const SizedBox(height: 32),

                // ── 6 OTP boxes ────────────────────────────────────────────
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: List.generate(6, (index) {
                    return SizedBox(
                      width: 46,
                      height: 56,
                      child: TextField(
                        controller: _controllers[index],
                        focusNode: _focusNodes[index],
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.black,
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                        ),
                        keyboardType: TextInputType.number,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                          LengthLimitingTextInputFormatter(1),
                        ],
                        decoration: InputDecoration(
                          filled: true,
                          fillColor: const Color(0xFFF5F5F5),
                          counterText: "",
                          contentPadding: EdgeInsets.zero,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide:
                            const BorderSide(color: Color(0xFFDDDDDD)),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: const BorderSide(
                                color: Color(0xFF48249A), width: 2),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide:
                            const BorderSide(color: Color(0xFFDDDDDD)),
                          ),
                        ),
                        onChanged: (val) {
                          if (val.isNotEmpty && index < 5) {
                            _focusNodes[index + 1].requestFocus();
                          } else if (val.isEmpty && index > 0) {
                            _focusNodes[index - 1].requestFocus();
                          }
                          // Auto-submit when last digit entered
                          if (index == 5 && val.isNotEmpty) {
                            _verify();
                          }
                        },
                      ),
                    );
                  }),
                ),
                const SizedBox(height: 28),

                // ── Error ──────────────────────────────────────────────────
                if (_error.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 14),
                    child: Text(
                      _error,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          color: Colors.redAccent, fontSize: 13),
                    ),
                  ),

                // ── Success ────────────────────────────────────────────────
                if (_success.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 14),
                    child: Text(
                      _success,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          color: Color(0xFF4CAF50), fontSize: 13),
                    ),
                  ),

                // ── Verify button ──────────────────────────────────────────
                SizedBox(
                  height: 52,
                  child: ElevatedButton(
                    onPressed: _loading ? null : _verify,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF48249A),
                      foregroundColor: Colors.white,
                      disabledBackgroundColor:
                      const Color(0xFF48249A).withOpacity(0.5),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                      elevation: 0,
                    ),
                    child: _loading
                        ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                          color: Colors.white, strokeWidth: 2.5),
                    )
                        : const Text(
                      "Verify & Continue",
                      style: TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
                const SizedBox(height: 20),

                // ── Resend ─────────────────────────────────────────────────
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Text(
                      "Didn't receive a code?  ",
                      style: TextStyle(color: Colors.grey, fontSize: 13),
                    ),
                    GestureDetector(
                      onTap: _resending ? null : _resend,
                      child: _resending
                          ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                            color: Color(0xFF3A0CA3), strokeWidth: 2),
                      )
                          : const Text(
                        "Resend",
                        style: TextStyle(
                          color: Color(0xFF3A0CA3),
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
              ],
            ),
          ),
        ),
      ),
    );
  }
}