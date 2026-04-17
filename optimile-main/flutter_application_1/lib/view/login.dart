import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'dart:ui' as ui;
import '../viewmodel/authvm.dart';
import 'map_screen.dart';
import 'signup.dart';
import 'customer_home_page.dart';
import 'admin_dashboard.dart';

class LoginPage extends StatefulWidget {
  final String? prefilledEmail;

  const LoginPage({super.key, this.prefilledEmail});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final TextEditingController emailController = TextEditingController();
  final TextEditingController passwordController = TextEditingController();
  bool _obscurePassword = true;

  @override
  void initState() {
    super.initState();
    if (widget.prefilledEmail != null) {
      emailController.text = widget.prefilledEmail!;
    }
  }

  void _showSnack(String message, [Color color = Colors.red]) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: color,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _showPasswordResetDialog() {
    final resetEmailController = TextEditingController();

    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Reset Password'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
                'Enter your email address to receive a password reset link.'),
            const SizedBox(height: 16),
            TextField(
              controller: resetEmailController,
              decoration: InputDecoration(
                labelText: 'Email',
                prefixIcon: const Icon(Icons.email),
                border:
                    OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () async {
              final email = resetEmailController.text.trim();
              if (email.isEmpty) {
                _showSnack('Please enter your email');
                return;
              }

              Navigator.pop(context);

              final authVM =
                  Provider.of<AuthViewModel>(context, listen: false);
              final result = await authVM.resetPassword(email);

              if (result == null) {
                _showSnack('Password reset email sent!', Colors.green);
              } else {
                _showSnack(result);
              }
            },
            child: const Text('Send Reset Link'),
          ),
        ],
      ),
    );
  }

  // 🔥 FIXED LOGIN FUNCTION
  void login() async {
    final email = emailController.text.trim();
    final password = passwordController.text.trim();

    final authVM = Provider.of<AuthViewModel>(context, listen: false);

    try {
      final result = await authVM.login(email, password);

      // ❌ NULL RESULT
      if (result == null) {
        _showSnack("Login failed");
        return;
      }

      // ❌ ERROR
      if (result is Map && result.containsKey('error')) {
        _showSnack(result['error']);
        return;
      }

      // ❗ EMAIL NOT VERIFIED
      if (result is Map &&
          result.containsKey('emailNotVerified') &&
          result['emailNotVerified'] == true) {
        _showEmailVerificationDialog();
        return;
      }

      // ✅ SAFE ROLE EXTRACTION
      final role = (result is Map && result['role'] != null)
          ? result['role'].toString().toLowerCase()
          : '';

      // 🔥 NAVIGATION
      if (role == 'admin') {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => const AdminDashboardApp()),
        );
      } else if (role == 'driver') {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => const MapScreen()),
        );
      } else if (role == 'customer') {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => const CustomerHomePage()),
        );
      } else {
        _showSnack("User role not found in database");
      }
    } catch (e) {
      _showSnack("Network error or server issue");
      print("LOGIN ERROR: $e");
    }
  }

  void _showEmailVerificationDialog() {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text("Verify Email"),
        content: const Text("Please verify your email first."),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text("OK"))
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isLoading = context.watch<AuthViewModel>().isLoading;

    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [Colors.blue.shade700, Colors.blue.shade900],
          ),
        ),
        child: Center(
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: SizedBox(
                width: 450,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: BackdropFilter(
                    filter: ui.ImageFilter.blur(sigmaX: 15, sigmaY: 15),
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.2),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: Colors.white30),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(32),
                        child: Column(
                          children: [
                            const Icon(Icons.local_shipping,
                                size: 60, color: Colors.white),
                            const SizedBox(height: 20),

                            TextField(
                              controller: emailController,
                              decoration: InputDecoration(
                                labelText: "Email",
                                filled: true,
                                fillColor: Colors.white,
                                border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(12)),
                              ),
                            ),

                            const SizedBox(height: 15),

                            TextField(
                              controller: passwordController,
                              obscureText: _obscurePassword,
                              decoration: InputDecoration(
                                labelText: "Password",
                                filled: true,
                                fillColor: Colors.white,
                                suffixIcon: IconButton(
                                  icon: Icon(_obscurePassword
                                      ? Icons.visibility
                                      : Icons.visibility_off),
                                  onPressed: () {
                                    setState(() {
                                      _obscurePassword = !_obscurePassword;
                                    });
                                  },
                                ),
                                border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(12)),
                              ),
                            ),

                            const SizedBox(height: 20),

                            SizedBox(
                              width: double.infinity,
                              height: 50,
                              child: ElevatedButton(
                                onPressed: isLoading ? null : login,
                                child: isLoading
                                    ? const CircularProgressIndicator()
                                    : const Text("Sign In"),
                              ),
                            ),

                            const SizedBox(height: 10),

                            TextButton(
                              onPressed: _showPasswordResetDialog,
                              child: const Text("Forgot Password?"),
                            ),

                            TextButton(
                              onPressed: () {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                      builder: (_) => const SignupPage()),
                                );
                              },
                              child: const Text("Create Account"),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}