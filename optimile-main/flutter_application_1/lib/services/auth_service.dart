import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/user_model.dart';

class AuthService {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  // Login with email verification check
  Future<Map<String, dynamic>> login(String email, String password) async {
    if (email.isEmpty || password.isEmpty) {
      return {'error': 'Please enter email and password'};
    }

    try {
      UserCredential userCred = await _auth.signInWithEmailAndPassword(
        email: email,
        password: password,
      );

      // Check if email is verified
      if (!userCred.user!.emailVerified) {
        await _auth.signOut(); // Sign out unverified user
        return {
          'error': 'Please verify your email before logging in',
          'emailNotVerified': true,
        };
      }

      final userDoc =
          await _db.collection('users').doc(userCred.user!.uid).get();

      if (!userDoc.exists) {
        return {'error': 'User profile not found'};
      }

      // Map Firestore data to DeliveryDriver
      final driver = DeliveryDriver.fromMap(
        userDoc.id,
        userDoc.data()!,
      );

      return {
        'user': userCred.user,
        'role': driver.role,
        'driver': driver,
      };
    } on FirebaseAuthException catch (e) {
      String msg = 'Login failed';
      switch (e.code) {
        case 'user-not-found':
          msg = 'No user found with this email';
          break;
        case 'wrong-password':
          msg = 'Wrong password';
          break;
        case 'invalid-email':
          msg = 'Invalid email';
          break;
        case 'invalid-credential':
          msg = 'Invalid credentials';
          break;
        case 'user-disabled':
          msg = 'This account has been disabled';
          break;
        case 'too-many-requests':
          msg = 'Too many attempts. Please try again later';
          break;
      }
      return {'error': msg};
    } catch (e) {
      return {'error': 'An unexpected error occurred'};
    }
  }

  // Signup with email verification and role selection
  Future<String?> signup({
    required String name,
    required String email,
    required String password,
    String? phone,
    required String role, // Made required to avoid confusion
  }) async {
    if (name.isEmpty || email.isEmpty || password.isEmpty) {
      return 'Please fill all required fields';
    }
    if (password.length < 6) {
      return 'Password must be at least 6 characters';
    }

    // Validate role - must be 'driver' or 'admin'
    if (role != 'driver' && role != 'admin') {
      return 'Invalid role selected';
    }

    try {
      UserCredential userCred = await _auth.createUserWithEmailAndPassword(
        email: email,
        password: password,
      );

      // Create user document in Firestore with selected role
      // This matches the admin dashboard query: where('role', isEqualTo: 'driver')
      await _db.collection('users').doc(userCred.user!.uid).set({
        'name': name,
        'email': email,
        'phone': phone ?? '',
        'role': role, // Stores 'driver' or 'admin' exactly as selected
        'created_at': FieldValue.serverTimestamp(),
        'email_verified': false,
      });

      // Update display name
      await userCred.user!.updateDisplayName(name);

      // Send verification email
      await userCred.user!.sendEmailVerification();

      // Sign out user until they verify email
      await _auth.signOut();

      return null; // success
    } on FirebaseAuthException catch (e) {
      switch (e.code) {
        case 'weak-password':
          return 'The password is too weak';
        case 'email-already-in-use':
          return 'An account already exists for this email';
        case 'invalid-email':
          return 'Invalid email';
        case 'operation-not-allowed':
          return 'Email/password accounts are not enabled';
        default:
          return 'Signup failed: ${e.code}';
      }
    } catch (e) {
      return 'Error: ${e.toString()}';
    }
  }

  // Resend verification email
  Future<String?> resendVerificationEmail() async {
    try {
      final user = _auth.currentUser;
      if (user == null) {
        return 'No user is currently signed in';
      }

      if (user.emailVerified) {
        return 'Email is already verified';
      }

      await user.sendEmailVerification();
      return null; // success
    } on FirebaseAuthException catch (e) {
      switch (e.code) {
        case 'too-many-requests':
          return 'Too many requests. Please wait before requesting another verification email';
        default:
          return 'Failed to send verification email: ${e.code}';
      }
    } catch (e) {
      return 'Error: ${e.toString()}';
    }
  }

  // Password Reset
  Future<String?> resetPassword(String email) async {
    if (email.isEmpty) {
      return 'Please enter your email';
    }

    try {
      await _auth.sendPasswordResetEmail(email: email);
      return null; // success
    } on FirebaseAuthException catch (e) {
      switch (e.code) {
        case 'user-not-found':
          return 'No user found with this email';
        case 'invalid-email':
          return 'Invalid email address';
        case 'too-many-requests':
          return 'Too many requests. Please try again later';
        default:
          return 'Failed to send reset email: ${e.code}';
      }
    } catch (e) {
      return 'Error: ${e.toString()}';
    }
  }

  // Sign out
  Future<void> logout() async {
    await _auth.signOut();
  }

  // Get current driver
  Future<DeliveryDriver?> getCurrentDriver() async {
    final user = _auth.currentUser;
    if (user == null) return null;

    final doc = await _db.collection('users').doc(user.uid).get();
    if (!doc.exists) return null;

    return DeliveryDriver.fromMap(doc.id, doc.data()!);
  }

  // Check if user is logged in
  User? get currentUser => _auth.currentUser;

  // Auth state changes stream
  Stream<User?> get authStateChanges => _auth.authStateChanges();
}
