import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'dart:ui' as ui;
import '/viewmodel/authvm.dart';
import '/view/map_screen.dart';
import '/view/signup.dart';
import 'package:url_launcher/url_launcher.dart';

// ✅ ADDED: to get Firebase ID token and pass it to Node dashboard
import 'package:firebase_auth/firebase_auth.dart';

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

  // Password Reset Dialog
  void _showPasswordResetDialog() {
    final resetEmailController = TextEditingController();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Reset Password'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
                'Enter your email address to receive a password reset link.'),
            const SizedBox(height: 16),
            TextField(
              controller: resetEmailController,
              keyboardType: TextInputType.emailAddress,
              decoration: InputDecoration(
                labelText: 'Email',
                prefixIcon: const Icon(Icons.email),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              final email = resetEmailController.text.trim();
              if (email.isEmpty) {
                _showSnack('Please enter your email');
                return;
              }

              Navigator.pop(context);

              final authVM = Provider.of<AuthViewModel>(context, listen: false);
              final result = await authVM.resetPassword(email);

              if (result == null) {
                _showSnack('Password reset email sent! Check your inbox.',
                    Colors.green);
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

  // Launch admin dashboard on your PC from Android emulator
  Future<void> _launchAdminDashboard() async {
    // ✅ Android emulator uses 10.0.2.2 to access your PC (host machine)

    try {
      // ✅ IMPORTANT: pass Firebase ID token so Node can call /api/me and show REAL admin name
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        _showSnack('No logged in user found.');
        return;
      }

      final idToken = await user.getIdToken(true);

      // ✅ Use /index.html to avoid "Cannot GET /index.html" issues if / is different
      final Uri url = Uri.parse('http://10.0.2.2:3000/index.html').replace(
        queryParameters: {'token': idToken},
      );

      // ✅ Use launchUrl directly (more reliable than canLaunchUrl on some devices)
      final opened = await launchUrl(
        url,
        mode: LaunchMode.externalApplication,
      );

      if (opened) {
        _showSnack('Opening admin dashboard...', Colors.green);
      } else {
        _showSnack('Could not open admin dashboard at 10.0.2.2:3000');
      }
    } catch (e) {
      _showSnack('Error opening admin dashboard: ${e.toString()}');
    }
  }

  void login() async {
    final authVM = Provider.of<AuthViewModel>(context, listen: false);

    final result =
        await authVM.login(emailController.text, passwordController.text);

    if (result.containsKey('error')) {
      _showSnack(result['error']);
    } else if (result.containsKey('emailNotVerified') &&
        result['emailNotVerified'] == true) {
      _showEmailVerificationDialog();
    } else {
      final role = (result['role'] ?? '').toString().toLowerCase().trim();

      if (role == 'admin') {
        // Admin: Open dashboard in browser (with token)
        await _launchAdminDashboard();
      } else {
        // Driver: Navigate to MapScreen
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => const MapScreen()),
        );
      }
    }
  }

  // Email Verification Dialog
  void _showEmailVerificationDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Email Not Verified'),
        content: const Text(
          'Please verify your email address before logging in. Check your inbox for the verification link.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
          ElevatedButton(
            onPressed: () async {
              final authVM = Provider.of<AuthViewModel>(context, listen: false);
              await authVM.resendVerificationEmail();
              Navigator.pop(context);
              _showSnack('Verification email sent!', Colors.green);
            },
            child: const Text('Resend Email'),
          ),
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
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
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
                        color: Colors.white.withOpacity(0.18),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: Colors.white.withOpacity(0.3),
                          width: 1.5,
                        ),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(32),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.local_shipping,
                                size: 64, color: Colors.white),
                            const SizedBox(height: 16),
                            const Text(
                              'Optimile',
                              style: TextStyle(
                                fontSize: 32,
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                              ),
                            ),
                            const SizedBox(height: 32),
                            TextField(
                              controller: emailController,
                              keyboardType: TextInputType.emailAddress,
                              decoration: InputDecoration(
                                labelText: 'Email',
                                prefixIcon: const Icon(Icons.email_outlined),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                filled: true,
                                fillColor: Colors.grey.shade50,
                              ),
                            ),
                            const SizedBox(height: 16),
                            TextField(
                              controller: passwordController,
                              obscureText: _obscurePassword,
                              decoration: InputDecoration(
                                labelText: 'Password',
                                prefixIcon: const Icon(Icons.lock_outline),
                                suffixIcon: IconButton(
                                  icon: Icon(
                                    _obscurePassword
                                        ? Icons.visibility_outlined
                                        : Icons.visibility_off_outlined,
                                  ),
                                  onPressed: () {
                                    setState(() {
                                      _obscurePassword = !_obscurePassword;
                                    });
                                  },
                                ),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                filled: true,
                                fillColor: Colors.grey.shade50,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Align(
                              alignment: Alignment.centerRight,
                              child: TextButton(
                                onPressed: _showPasswordResetDialog,
                                child: const Text(
                                  'Forgot Password?',
                                  style: TextStyle(color: Colors.white),
                                ),
                              ),
                            ),
                            const SizedBox(height: 8),
                            SizedBox(
                              width: double.infinity,
                              height: 50,
                              child: ElevatedButton(
                                onPressed: isLoading ? null : login,
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.blue.shade700,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                ),
                                child: isLoading
                                    ? const CircularProgressIndicator(
                                        color: Colors.white,
                                        strokeWidth: 2,
                                      )
                                    : const Text(
                                        'Sign In',
                                        style: TextStyle(
                                            fontWeight: FontWeight.bold,
                                            color: Colors.white),
                                      ),
                              ),
                            ),
                            const SizedBox(height: 16),
                            TextButton(
                              onPressed: () async {
                                final email = await Navigator.push<String>(
                                  context,
                                  MaterialPageRoute(
                                      builder: (_) => const SignupPage()),
                                );
                                if (email != null) {
                                  emailController.text = email;
                                }
                              },
                              child: const Text(
                                "Don't have an account? Sign up",
                                style: TextStyle(color: Colors.white),
                              ),
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
