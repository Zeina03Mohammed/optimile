import 'package:cloud_firestore/cloud_firestore.dart';

class DeliveryDriver {
  final String id;
  final String name;
  final String email;
  final String phone;
  final String role;
  final DateTime? createdAt;
  final int? driverId; // Links to backend numerical driver ID

  DeliveryDriver({
    required this.id,
    required this.name,
    required this.email,
    this.phone = '',
    this.role = 'driver',
    this.createdAt,
    this.driverId,
  });

  Map<String, dynamic> toMap() {
    return {
      'name': name,
      'email': email,
      'phone': phone,
      'role': role,
      'created_at': createdAt,
      if (driverId != null) 'driverId': driverId,
    };
  }

  factory DeliveryDriver.fromMap(String id, Map<String, dynamic> map) {
    return DeliveryDriver(
      id: id,
      name: map['name'] ?? '',
      email: map['email'] ?? '',
      phone: map['phone'] ?? '',
      role: map['role'] ?? 'driver',
      createdAt: map['created_at'] != null
          ? (map['created_at'] as Timestamp).toDate()
          : null,
      driverId: map['driverId'] != null ? (map['driverId'] as num).toInt() : null,
    );
  }
}
