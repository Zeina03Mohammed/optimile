import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:provider/provider.dart';

import 'viewmodel/authvm.dart';
import 'view/login.dart';
import 'view/map_screen.dart';
// import 'view/admin.dart'; // ❌ REMOVE (we won’t open Flutter admin page)

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => AuthViewModel(),
      child: MaterialApp(
        title: 'Optimile',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          primarySwatch: Colors.blue,
          useMaterial3: true,
        ),
        home: const AuthWrapper(),
      ),
    );
  }
}

// Auth Wrapper - Handles automatic login based on auth state
class AuthWrapper extends StatelessWidget {
  const AuthWrapper({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snapshot) {
        // Loading while checking auth state
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        // Not logged in
        if (!snapshot.hasData || snapshot.data == null) {
          return const LoginPage();
        }

        final user = snapshot.data!;

        // Email not verified -> force login
        if (!user.emailVerified) {
          return const LoginPage();
        }

        // Fetch user role from Firestore
        return FutureBuilder<DocumentSnapshot>(
          future: FirebaseFirestore.instance
              .collection('users')
              .doc(user.uid)
              .get(),
          builder: (context, userDoc) {
            if (userDoc.connectionState == ConnectionState.waiting) {
              return const Scaffold(
                body: Center(child: CircularProgressIndicator()),
              );
            }

            if (userDoc.hasError || !userDoc.hasData || userDoc.data == null) {
              return const LoginPage();
            }

            final userData = userDoc.data!.data() as Map<String, dynamic>?;
            if (userData == null) {
              return const LoginPage();
            }

            final role = (userData['role'] ?? 'driver')
                .toString()
                .toLowerCase()
                .trim();

            // ✅ Admin -> go to login page (then login.dart will open web dashboard)
            if (role == 'admin') {
              return LoginPage(prefilledEmail: user.email);
            }

            // ✅ Driver -> Map screen
            return const MapScreen();
          },
        );
      },
    );
  }
}
