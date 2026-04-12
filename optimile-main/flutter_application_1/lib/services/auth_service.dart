import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/user_model.dart';

class AuthService {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  // ================= LOGIN =================
  Future<Map<String, dynamic>> login(String email, String password) async {
    if (email.isEmpty || password.isEmpty) {
      return {'error': 'Please enter email and password'};
    }

    try {
      UserCredential userCred = await _auth.signInWithEmailAndPassword(
        email: email,
        password: password,
      );

      // ✅ Check email verification
      if (!userCred.user!.emailVerified) {
        await _auth.signOut();
        return {
          'error': 'Please verify your email before logging in',
          'emailNotVerified': true,
        };
      }

      // ✅ Get Firestore user document
      final userDoc =
          await _db.collection('users').doc(userCred.user!.uid).get();

      if (!userDoc.exists) {
        return {'error': 'User profile not found in database'};
      }

      final data = userDoc.data();

      // ✅ Safety checks (VERY IMPORTANT)
      if (data == null) {
        return {'error': 'User data is empty'};
      }

      if (!data.containsKey('role')) {
        return {'error': 'User role not found'};
      }

      // ✅ Safe mapping
      final driver = DeliveryDriver.fromMap(
        userDoc.id,
        data,
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
        default:
          msg = e.message ?? e.code;
      }

      return {'error': msg};
    } catch (e) {
      print("🔥 LOGIN ERROR: $e");
      return {'error': e.toString()};
    }
  }

  // ================= SIGNUP =================
  Future<String?> signup({
    required String name,
    required String email,
    required String password,
    String? phone,
    required String role,
  }) async {
    if (name.isEmpty || email.isEmpty || password.isEmpty) {
      return 'Please fill all required fields';
    }
    if (password.length < 6) {
      return 'Password must be at least 6 characters';
    }

    // 🔥🔥🔥 FIXED HERE ONLY
    if (role != 'driver' && role != 'admin' && role != 'customer') {
      return 'Invalid role selected';
    }

    try {
      UserCredential userCred = await _auth.createUserWithEmailAndPassword(
        email: email,
        password: password,
      );

      await _db.collection('users').doc(userCred.user!.uid).set({
        'name': name,
        'email': email,
        'phone': phone ?? '',
        'role': role,
        'created_at': FieldValue.serverTimestamp(),
        'email_verified': false,
      });

      await userCred.user!.updateDisplayName(name);
      await userCred.user!.sendEmailVerification();
      await _auth.signOut();

      return null;
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

  // ================= RESET PASSWORD =================
  Future<String?> resetPassword(String email) async {
    if (email.isEmpty) {
      return 'Please enter your email';
    }

    try {
      await _auth.sendPasswordResetEmail(email: email);
      return null;
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

  // ================= RESEND VERIFICATION =================
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
      return null;
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

  // ================= LOGOUT =================
  Future<void> logout() async {
    await _auth.signOut();
  }

  // ================= GET CURRENT DRIVER =================
  Future<DeliveryDriver?> getCurrentDriver() async {
    final user = _auth.currentUser;
    if (user == null) return null;

    final doc = await _db.collection('users').doc(user.uid).get();
    if (!doc.exists) return null;

    final data = doc.data();
    if (data == null) return null;

    return DeliveryDriver.fromMap(doc.id, data);
  }

  // ================= HELPERS =================
  User? get currentUser => _auth.currentUser;

  Stream<User?> get authStateChanges => _auth.authStateChanges();
}