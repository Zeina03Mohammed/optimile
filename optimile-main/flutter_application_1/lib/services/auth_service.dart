import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/user_model.dart'; // <-- DeliveryDriver model
///1
class AuthService {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  // Login
  Future<Map<String, dynamic>> login(String email, String password) async {
    if (email.isEmpty || password.isEmpty) {
      return {'error': 'Please enter email and password'};
    }

    try {
      UserCredential userCred =
          await _auth.signInWithEmailAndPassword(
        email: email,
        password: password,
      );

      final userDoc =
          await _db.collection('users').doc(userCred.user!.uid).get();

      if (!userDoc.exists) {
        return {'error': 'User profile not found'};
      }

      // 🔹 Map Firestore data to DeliveryDriver
      final driver = DeliveryDriver.fromMap(
        userDoc.id,
        userDoc.data()!,
      );

      return {
        'user': userCred.user,
        'role': driver.role,
        'driver': driver, // 👈 ADDED (non-breaking)
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
      }
      return {'error': msg};
    } catch (e) {
      return {'error': e.toString()};
    }
  }

  // Signup
  Future<String?> signup({
    required String name,
    required String email,
    required String password,
    String? phone,
  }) async {
    if (name.isEmpty || email.isEmpty || password.isEmpty) {
      return 'Please fill all required fields';
    }
    if (password.length < 6) {
      return 'Password must be at least 6 characters';
    }

    try {
      UserCredential userCred =
          await _auth.createUserWithEmailAndPassword(
        email: email,
        password: password,
      );

      // 🔹 Data matches DeliveryDriver.toMap()
      await _db.collection('users').doc(userCred.user!.uid).set({
        'name': name,
        'email': email,
        'phone': phone ?? '',
        'role': 'driver',
        'created_at': FieldValue.serverTimestamp(),
      });

      await userCred.user!.updateDisplayName(name);

      return null; // success
    } on FirebaseAuthException catch (e) {
      switch (e.code) {
        case 'weak-password':
          return 'The password is too weak';
        case 'email-already-in-use':
          return 'An account already exists for this email';
        case 'invalid-email':
          return 'Invalid email';
        default:
          return 'Signup failed: ${e.code}';
      }
    } catch (e) {
      return 'Error: ${e.toString()}';
    }
  }

  // Sign out
  Future<void> logout() async {
    await _auth.signOut();
  }

  // 🔹 OPTIONAL helper (uses your model)
  Future<DeliveryDriver?> getCurrentDriver() async {
    final user = _auth.currentUser;
    if (user == null) return null;

    final doc = await _db.collection('users').doc(user.uid).get();
    if (!doc.exists) return null;

    return DeliveryDriver.fromMap(doc.id, doc.data()!);
  }
}
