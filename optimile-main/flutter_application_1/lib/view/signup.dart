import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '/viewmodel/authvm.dart';

class SignupPage extends StatefulWidget {
  const SignupPage({super.key});

  @override
  State<SignupPage> createState() => _SignupPageState();
}

class _SignupPageState extends State<SignupPage> {
  final TextEditingController nameController = TextEditingController();
  final TextEditingController emailController = TextEditingController();
  final TextEditingController passwordController = TextEditingController();
  final TextEditingController phoneController = TextEditingController();

  bool _obscurePassword = true;
  bool _isDriver = true; // 🔹 Default to driver

  void _showSnack(String message, [Color color = Colors.red]) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: color,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  // Email validation
  bool _isValidEmail(String email) {
    final emailRegex = RegExp(r'^[\w-\.]+@([\w-]+\.)+[\w-]{2,4}$');
    return emailRegex.hasMatch(email);
  }

  // Password validation
  String? _validatePassword(String password) {
    if (password.length < 6) {
      return 'Password must be at least 6 characters';
    }
    if (!password.contains(RegExp(r'[A-Z]'))) {
      return 'Password must contain at least one uppercase letter';
    }
    if (!password.contains(RegExp(r'[0-9]'))) {
      return 'Password must contain at least one number';
    }
    return null;
  }

  void signup() async {
    final authVM = Provider.of<AuthViewModel>(context, listen: false);

    // Validation
    if (nameController.text.isEmpty ||
        emailController.text.isEmpty ||
        passwordController.text.isEmpty) {
      _showSnack("Please fill all required fields");
      return;
    }

    // Email validation
    if (!_isValidEmail(emailController.text.trim())) {
      _showSnack("Please enter a valid email address");
      return;
    }

    // Password validation
    final passwordError = _validatePassword(passwordController.text);
    if (passwordError != null) {
      _showSnack(passwordError);
      return;
    }

    final result = await authVM.signup(
      name: nameController.text.trim(),
      email: emailController.text.trim(),
      password: passwordController.text,
      phone: phoneController.text.isEmpty ? null : phoneController.text.trim(),
      role: _isDriver ? 'driver' : 'user', // 🔹 Pass role based on checkbox
    );

    if (result != null) {
      // error message returned
      _showSnack(result);
    } else {
      // success
      _showSnack("Account created successfully! Please verify your email.",
          Colors.green);
      Navigator.pop(context, emailController.text.trim());
    }
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
                    filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
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
                            const Icon(Icons.person_add,
                                size: 64, color: Colors.white),
                            const SizedBox(height: 16),
                            const Text(
                              'Create Account',
                              style: TextStyle(
                                fontSize: 28,
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                              ),
                            ),
                            const SizedBox(height: 32),

                            // Name
                            TextField(
                              controller: nameController,
                              decoration: InputDecoration(
                                labelText: 'Name',
                                prefixIcon: const Icon(Icons.person),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                filled: true,
                                fillColor: Colors.grey.shade50,
                              ),
                            ),
                            const SizedBox(height: 16),

                            // Email
                            TextField(
                              controller: emailController,
                              keyboardType: TextInputType.emailAddress,
                              decoration: InputDecoration(
                                labelText: 'Email',
                                prefixIcon: const Icon(Icons.email),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                filled: true,
                                fillColor: Colors.grey.shade50,
                              ),
                            ),
                            const SizedBox(height: 16),

                            // Phone (optional)
                            TextField(
                              controller: phoneController,
                              keyboardType: TextInputType.phone,
                              decoration: InputDecoration(
                                labelText: 'Phone (optional)',
                                prefixIcon: const Icon(Icons.phone),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                filled: true,
                                fillColor: Colors.grey.shade50,
                              ),
                            ),
                            const SizedBox(height: 16),

                            // Password
                            TextField(
                              controller: passwordController,
                              obscureText: _obscurePassword,
                              decoration: InputDecoration(
                                labelText: 'Password',
                                prefixIcon: const Icon(Icons.lock),
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
                                helperText:
                                    'Min 6 chars, 1 uppercase, 1 number',
                                helperMaxLines: 2,
                              ),
                            ),
                            const SizedBox(height: 16),

                            // 🔹 Driver Checkbox
                            Container(
                              decoration: BoxDecoration(
                                color: Colors.grey.shade50,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(color: Colors.grey.shade400),
                              ),
                              child: CheckboxListTile(
                                title: const Row(
                                  children: [
                                    Icon(Icons.local_shipping, size: 20),
                                    SizedBox(width: 8),
                                    Text('I am a driver'),
                                  ],
                                ),
                                value: _isDriver,
                                onChanged: (value) {
                                  setState(() {
                                    _isDriver = value ?? true;
                                  });
                                },
                                activeColor: Colors.blue.shade700,
                                controlAffinity:
                                    ListTileControlAffinity.leading,
                              ),
                            ),
                            const SizedBox(height: 24),

                            SizedBox(
                              width: double.infinity,
                              height: 50,
                              child: ElevatedButton(
                                onPressed: isLoading ? null : signup,
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
                                        'Sign Up',
                                        style: TextStyle(
                                            fontWeight: FontWeight.bold),
                                      ),
                              ),
                            ),

                            const SizedBox(height: 16),

                            TextButton(
                              onPressed: () => Navigator.pop(context),
                              child: const Text(
                                  'Already have an account? Sign In',
                                  style: TextStyle(color: Colors.white)),
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
