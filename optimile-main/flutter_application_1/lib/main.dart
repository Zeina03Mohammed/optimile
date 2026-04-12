import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:provider/provider.dart';

import 'firebase_options.dart';

import 'viewmodel/authvm.dart';
import 'view/login.dart';
import 'view/map_screen.dart';
import 'view/customer_home_page.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

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

// ================= AUTH WRAPPER =================

class AuthWrapper extends StatelessWidget {
  const AuthWrapper({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snapshot) {

        // 🔄 Loading
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        // ❌ Not logged in → Login Page
        if (!snapshot.hasData || snapshot.data == null) {
          return const LoginPage();
        }

        final user = snapshot.data!;

        // 🔄 Fetch role from Firestore
        return FutureBuilder<DocumentSnapshot>(
          future: FirebaseFirestore.instance
              .collection('users')
              .doc(user.uid)
              .get(),
          builder: (context, userDoc) {

            // 🔄 Loading
            if (userDoc.connectionState == ConnectionState.waiting) {
              return const Scaffold(
                body: Center(child: CircularProgressIndicator()),
              );
            }

            // ❌ Error or no data → back to login
            if (userDoc.hasError ||
                !userDoc.hasData ||
                userDoc.data == null) {
              return const LoginPage();
            }

            final data =
                userDoc.data!.data() as Map<String, dynamic>?;

            if (data == null) {
              return const LoginPage();
            }

            final role =
                (data['role'] ?? '').toString().toLowerCase().trim();

            // 👑 ADMIN
            if (role == 'admin') {
              return const LoginPage(); // change later if needed
            }

            // 🚚 DRIVER
            if (role == 'driver') {
              return const MapScreen();
            }

            // 🧑 CUSTOMER
            if (role == 'customer') {
              return const CustomerHomePage();
            }

            // ❌ Unknown role
            return const LoginPage();
          },
        );
      },
    );
  }
}