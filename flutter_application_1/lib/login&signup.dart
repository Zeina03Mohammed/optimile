import 'package:flutter/material.dart';

// Fake user database
Map<String, String> users = {
  'admin@example.com': 'admin',
  'driver@example.com': 'driver',
};

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final TextEditingController emailController = TextEditingController();
  final TextEditingController passwordController = TextEditingController();

  void login() {
    String email = emailController.text.trim();

    if (users.containsKey(email)) {
      String role = users[email]!;

      if (role == 'admin') {
        Navigator.pushReplacement(
            context,
            MaterialPageRoute(
                builder: (context) => const AdminDashboard()));
      } else if (role == 'driver') {
        Navigator.pushReplacement(
            context,
            MaterialPageRoute(
                builder: (context) => const DriverDashboard()));
      }
    } else {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Invalid credentials')));
    }
  }

  void goToSignup() {
    Navigator.push(
        context, MaterialPageRoute(builder: (context) => const SignupPage()));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Login')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            TextField(
              controller: emailController,
              decoration: const InputDecoration(labelText: 'Email'),
            ),
            TextField(
              controller: passwordController,
              decoration: const InputDecoration(labelText: 'Password'),
              obscureText: true,
            ),
            const SizedBox(height: 20),
            ElevatedButton(onPressed: login, child: const Text('Login')),
            TextButton(onPressed: goToSignup, child: const Text('Signup')),
          ],
        ),
      ),
    );
  }
}

class SignupPage extends StatelessWidget {
  const SignupPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Signup')),
      body: const Center(
        child: Text('Signup Page - Add your signup form here'),
      ),
    );
  }
}

// Dashboards
class AdminDashboard extends StatelessWidget {
  const AdminDashboard({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Admin Dashboard')),
      body: const Center(child: Text('Welcome, Admin!')),
    );
  }
}

class DriverDashboard extends StatelessWidget {
  const DriverDashboard({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Driver Dashboard')),
      body: const Center(child: Text('Welcome, Driver!')),
    );
  }
}
