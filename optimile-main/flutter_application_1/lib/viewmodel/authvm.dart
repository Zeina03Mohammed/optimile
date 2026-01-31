import 'package:flutter/material.dart';
import '/services/auth_service.dart';
import '/models/user_model.dart'; // <-- DeliveryDriver

class AuthViewModel extends ChangeNotifier {
  final AuthService _authService = AuthService();

  bool isLoading = false;

  // Optional cached driver
  DeliveryDriver? currentDriver;

  void setLoading(bool value) {
    isLoading = value;
    notifyListeners();
  }

  // ================= LOGIN =================
  Future<Map<String, dynamic>> login(String email, String password) async {
    setLoading(true);

    final result = await _authService.login(email, password);

    if (result['driver'] != null) {
      currentDriver = result['driver'];
      notifyListeners();
    }

    setLoading(false);
    return result;
  }

  // ================= SIGNUP with Role =================
  Future<String?> signup({
    required String name,
    required String email,
    required String password,
    required String role, // ✅ REQUIRED (fixes your error)
    String? phone,
    required String role, // 🔹 ADDED: Required role parameter
  }) async {
    setLoading(true);

    final result = await _authService.signup(
      name: name,
      email: email,
      password: password,
      role: role, // ✅ forward role to service
      phone: phone,
      role: role, // 🔹 Pass role to service
    );

    setLoading(false);
    return result;
  }

<<<<<<< Updated upstream
  // ================= PASSWORD RESET =================
  // 🔹 ADDED: Password reset method
  Future<String?> resetPassword(String email) async {
    setLoading(true);
    final result = await _authService.resetPassword(email);
    setLoading(false);
    return result;
  }

  // ================= RESEND VERIFICATION EMAIL =================
  // 🔹 ADDED: Resend verification email method
  Future<String?> resendVerificationEmail() async {
    setLoading(true);
    final result = await _authService.resendVerificationEmail();
    setLoading(false);
    return result;
=======
  // ================= RESET PASSWORD =================
  // Used in: lib/view/login.dart
  Future<String?> resetPassword(String email) async {
    setLoading(true);
    try {
      final result = await _authService.resetPassword(email);
      return result; // usually null if success, or error message
    } finally {
      setLoading(false);
    }
  }

  // ================= RESEND VERIFICATION EMAIL =================
  // Used in: lib/view/login.dart
  Future<String?> resendVerificationEmail() async {
    setLoading(true);
    try {
      final result = await _authService.resendVerificationEmail();
      return result; // usually null if success, or error message
    } finally {
      setLoading(false);
    }
>>>>>>> Stashed changes
  }

  // ================= LOGOUT =================
  Future<void> logout() async {
    currentDriver = null;
    notifyListeners();
    await _authService.logout();
  }

  // ================= GET CURRENT DRIVER =================
  Future<void> loadCurrentDriver() async {
    final driver = await _authService.getCurrentDriver();
    if (driver != null) {
      currentDriver = driver;
      notifyListeners();
    }
  }
}
