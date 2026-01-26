import 'package:flutter/material.dart';
import '/services/auth_service.dart';
import '/models/user_model.dart'; // <-- DeliveryDriver

class AuthViewModel extends ChangeNotifier {
  final AuthService _authService = AuthService();

  bool isLoading = false;

  // 🔹 Optional cached driver
  DeliveryDriver? currentDriver;

  void setLoading(bool value) {
    isLoading = value;
    notifyListeners();
  }

  // ================= LOGIN =================
  Future<Map<String, dynamic>> login(String email, String password) async {
    setLoading(true);
    final result = await _authService.login(email, password);

    // 🔥 ADDED (non-breaking)
    if (result['driver'] != null) {
      currentDriver = result['driver'];
      notifyListeners();
    }

    setLoading(false);
    return result;
  }

  // ================= SIGNUP =================
  Future<String?> signup({
    required String name,
    required String email,
    required String password,
    String? phone,
  }) async {
    setLoading(true);
    final result = await _authService.signup(
      name: name,
      email: email,
      password: password,
      phone: phone,
    );
    setLoading(false);
    return result;
  }

  // ================= LOGOUT =================
  Future<void> logout() async {
    currentDriver = null; // 🔹 clear cached driver
    notifyListeners();
    await _authService.logout();
  }
}
