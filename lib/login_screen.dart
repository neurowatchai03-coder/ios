import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import 'register_screen.dart';
import 'dashboard.dart';
import 'main.dart' show notifyUserLoggedIn;

////////////////////////////////////////////////////////////
/// LOGIN SCREEN
/// Simple email + password form.
/// Validates against Firestore users/{email}.
/// Requires verified == true (email confirmed via OTP).
/// On success → saves session to SharedPreferences
///            → notifies native to start tracker service
///            → Dashboard(userEmail, userName)
////////////////////////////////////////////////////////////

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  // ── Controllers ───────────────────────────────────────────────────────────
  final _emailCtrl    = TextEditingController();
  final _passwordCtrl = TextEditingController();

  // ── State ─────────────────────────────────────────────────────────────────
  bool   _obscure = true;
  bool   _loading = false;
  String _error   = "";

  @override
  void dispose() {
    _emailCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  // ── Login ─────────────────────────────────────────────────────────────────

  Future<void> _login() async {
    final email    = _emailCtrl.text.trim().toLowerCase();
    final password = _passwordCtrl.text.trim();

    if (email.isEmpty || password.isEmpty) {
      setState(() { _error = "Please enter email and password"; });
      return;
    }

    setState(() { _loading = true; _error = ""; });

    try {
      final doc = await FirebaseFirestore.instance
          .collection("users")
          .doc(email)
          .get();

      if (!doc.exists) {
        setState(() {
          _error   = "No account found for this email";
          _loading = false;
        });
        return;
      }

      final data = doc.data()!;

      if ((data["verified"] as bool? ?? false) == false) {
        setState(() {
          _error   = "Email not verified. Please check your inbox.";
          _loading = false;
        });
        return;
      }

      if ((data["password"] as String? ?? "") != password) {
        setState(() { _error = "Invalid password"; _loading = false; });
        return;
      }

      final name = data["name"] as String? ?? email;

      // Save session locally — MUST be saved before notifyUserLoggedIn()
      // so the native service can read userEmail from SharedPreferences
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString("flutter.userEmail", email);
      await prefs.setString("userEmail", email);
      await prefs.setString("userName",  name);
      await prefs.setBool("loggedIn",    true);

      // ── KEY FIX: tell native side to start the tracker service NOW ──
      // Without this, the service only starts when the app is reopened.
      await notifyUserLoggedIn();

      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => Dashboard(userEmail: email, userName: name),
        ),
      );
    } catch (e) {
      setState(() {
        _error   = "Login failed. Check your connection.";
        _loading = false;
      });
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
        contentPadding:
        const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFF000000)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide:
          const BorderSide(color: Color(0xFF000000), width: 1.5),
        ),
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
                  "Welcome Back",
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
                  "Sign in to continue",
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, color: Colors.grey),
                ),
                const SizedBox(height: 32),

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
                  obscureText: _obscure,
                  style: const TextStyle(color: Colors.black),
                  onSubmitted: (_) => _login(),
                  decoration: _dec(
                    "Password",
                    Icons.lock_outline_rounded,
                    suffix: IconButton(
                      icon: Icon(
                        _obscure
                            ? Icons.visibility_off_outlined
                            : Icons.visibility_outlined,
                        color: Colors.black,
                        size: 20,
                      ),
                      onPressed: () =>
                          setState(() { _obscure = !_obscure; }),
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

                // ── Sign In button ─────────────────────────────────────────
                SizedBox(
                  height: 52,
                  child: ElevatedButton(
                    onPressed: _loading ? null : _login,
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
                      "Sign In",
                      style: TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
                const SizedBox(height: 20),

                // ── Sign up link ───────────────────────────────────────────
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Text(
                      "Don't have an account?  ",
                      style: TextStyle(color: Colors.grey, fontSize: 13),
                    ),
                    GestureDetector(
                      onTap: () => Navigator.of(context).pushReplacement(
                        MaterialPageRoute(
                            builder: (_) => const RegisterScreen()),
                      ),
                      child: const Text(
                        "Sign Up",
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