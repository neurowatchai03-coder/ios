import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import 'otp_screen.dart';
import 'login_screen.dart';
import 'services/email_service.dart';

////////////////////////////////////////////////////////////
/// REGISTER SCREEN
/// Single form: Full Name, Email, Password, Confirm Password.
/// On submit → writes a pending record to Firestore and
/// navigates to OtpScreen for email verification.
///
/// Password rules: min 8 chars, letters & digits only.
////////////////////////////////////////////////////////////

class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  // ── Controllers ───────────────────────────────────────────────────────────
  final _nameCtrl     = TextEditingController();
  final _emailCtrl    = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _confirmCtrl  = TextEditingController();

  // ── State ─────────────────────────────────────────────────────────────────
  bool   _obscurePass    = true;
  bool   _obscureConfirm = true;
  bool   _loading        = false;
  String _error          = "";

  @override
  void dispose() {
    _nameCtrl.dispose();
    _emailCtrl.dispose();
    _passwordCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  bool _isValidEmail(String s) =>
      RegExp(r'^[\w\.\-]+@[\w\.\-]+\.\w{2,}$').hasMatch(s);

  bool _isValidPassword(String s) {
    if (s.length < 8) return false;
    if (!RegExp(r'^[a-zA-Z0-9]+$').hasMatch(s)) return false;
    if (!RegExp(r'[a-zA-Z]').hasMatch(s)) return false;
    if (!RegExp(r'[0-9]').hasMatch(s)) return false;
    return true;
  }

  // ── Register ──────────────────────────────────────────────────────────────

  Future<void> _register() async {
    setState(() { _error = ""; });

    final name     = _nameCtrl.text.trim();
    final email    = _emailCtrl.text.trim().toLowerCase();
    final password = _passwordCtrl.text.trim();
    final confirm  = _confirmCtrl.text.trim();

    if (name.isEmpty) {
      setState(() { _error = "Please enter your full name"; });
      return;
    }
    if (email.isEmpty || !_isValidEmail(email)) {
      setState(() { _error = "Enter a valid email address"; });
      return;
    }
    if (!_isValidPassword(password)) {
      setState(() {
        _error = "Password must be 8+ characters using letters & numbers only";
      });
      return;
    }
    if (password != confirm) {
      setState(() { _error = "Passwords do not match"; });
      return;
    }

    setState(() { _loading = true; });

    try {
      // Check if email already registered and verified
      final existing = await FirebaseFirestore.instance
          .collection("users")
          .doc(email)
          .get();

      if (existing.exists && (existing.data()?["verified"] == true)) {
        setState(() {
          _error   = "An account with this email already exists";
          _loading = false;
        });
        return;
      }

      // Generate 6-digit OTP
      final otp = (100000 + (DateTime.now().millisecondsSinceEpoch % 900000))
          .toString();

      // Save user record (keep any existing unverified record — just overwrite)
      await FirebaseFirestore.instance.collection("users").doc(email).set({
        "name":         name,
        "email":        email,
        "password":     password,
        "verified":     false,
        "otp":          otp,
        "otpCreatedAt": DateTime.now().toIso8601String(),
        "registeredAt": DateTime.now().toIso8601String(),
      });

      // Attempt to send OTP email
      final sent = await EmailService.sendOtpEmail(
        email: email,
        otp:   otp,
      );

      setState(() { _loading = false; });

      if (!mounted) return;

      if (!sent) {
        // User record is kept — navigate to OTP screen so they can resend
        setState(() {
          _error = "Could not send email. Use Resend on the next screen.";
        });
      }

      // Always go to OTP screen — user can resend from there
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => OtpScreen(email: email, name: name),
        ),
      );
    } catch (e) {
      setState(() {
        _error   = "Registration failed. Please try again.";
        _loading = false;
      });
      debugPrint("Register error: $e");
    }
  }

  // ── UI helpers ────────────────────────────────────────────────────────────

  InputDecoration _dec(String label, IconData icon, {Widget? suffix}) =>
      InputDecoration(
        labelText:      label,
        labelStyle:     const TextStyle(color: Colors.grey),
        prefixIcon:     Icon(icon, color: Colors.deepPurple, size: 20),
        suffixIcon:     suffix,
        filled:         true,
        fillColor:      const Color(0xFFFFFFFF),
        contentPadding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFF000000)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFF000000), width: 1.5),
        ),
      );

  Widget _eyeButton(bool obscure, VoidCallback onTap) => IconButton(
    icon: Icon(
      obscure ? Icons.visibility_off_outlined : Icons.visibility_outlined,
      color: Colors.deepPurple,
      size: 20,
    ),
    onPressed: onTap,
  );

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
                  "Create Account",
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    color: Colors.deepPurple,
                    letterSpacing: 0.3,
                  ),
                ),
                const SizedBox(height: 6),
                const Text(
                  "Fill in your details to get started",
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, color: Colors.black),
                ),
                const SizedBox(height: 28),

                // ── Full Name ──────────────────────────────────────────────
                TextField(
                  controller: _nameCtrl,
                  style: const TextStyle(color: Colors.black),
                  textCapitalization: TextCapitalization.words,
                  decoration: _dec("Full Name", Icons.person_outline_rounded),
                ),
                const SizedBox(height: 14),

                // ── Email ──────────────────────────────────────────────────
                TextField(
                  controller: _emailCtrl,
                  keyboardType: TextInputType.emailAddress,
                  style: const TextStyle(color: Colors.black),
                  decoration: _dec("Email Address", Icons.email_outlined),
                ),
                const SizedBox(height: 14),

                // ── Password ───────────────────────────────────────────────
                TextField(
                  controller: _passwordCtrl,
                  obscureText: _obscurePass,
                  style: const TextStyle(color: Colors.black),
                  decoration: _dec(
                    "Password",
                    Icons.lock_outline_rounded,
                    suffix: _eyeButton(
                      _obscurePass,
                          () => setState(() { _obscurePass = !_obscurePass; }),
                    ),
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.only(left: 4, top: 5, bottom: 10),
                  child: Text(
                    "Min 8 characters · letters & numbers only",
                    style: TextStyle(fontSize: 11, color: Color(0xFF000000)),
                  ),
                ),

                // ── Confirm Password ───────────────────────────────────────
                TextField(
                  controller: _confirmCtrl,
                  obscureText: _obscureConfirm,
                  style: const TextStyle(color: Colors.black),
                  onSubmitted: (_) => _register(),
                  decoration: _dec(
                    "Confirm Password",
                    Icons.lock_outline_rounded,
                    suffix: _eyeButton(
                      _obscureConfirm,
                          () => setState(() { _obscureConfirm = !_obscureConfirm; }),
                    ),
                  ),
                ),
                const SizedBox(height: 20),

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

                // ── Register button ────────────────────────────────────────
                SizedBox(
                  height: 52,
                  child: ElevatedButton(
                    onPressed: _loading ? null : _register,
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
                      "Create Account",
                      style: TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
                const SizedBox(height: 20),

                // ── Already have account ───────────────────────────────────
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Text(
                      "Already have an account?  ",
                      style: TextStyle(color: Colors.grey, fontSize: 13),
                    ),
                    GestureDetector(
                      onTap: () => Navigator.of(context).pushReplacement(
                        MaterialPageRoute(
                            builder: (_) => const LoginScreen()),
                      ),
                      child: const Text(
                        "Sign In",
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