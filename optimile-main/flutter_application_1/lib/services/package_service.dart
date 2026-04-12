import 'dart:convert';
import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:csv/csv.dart';
import 'package:firebase_auth/firebase_auth.dart';

class PackageService {
  Future<void> uploadPackagesFromCsv(Uint8List fileBytes) async {
    final currentUser = FirebaseAuth.instance.currentUser;

    if (currentUser == null) {
      throw Exception("User not logged in");
    }

    final csvString = utf8.decode(fileBytes);

    final rows = const CsvToListConverter().convert(csvString);

    if (rows.isEmpty) {
      throw Exception("CSV is empty");
    }

    final headers =
        rows.first.map((e) => e.toString().trim()).toList();

    print("HEADERS: $headers");

    for (int i = 1; i < rows.length; i++) {
      final row = rows[i];

      final data = <String, dynamic>{};

      for (int j = 0; j < headers.length && j < row.length; j++) {
        data[headers[j]] = row[j].toString().trim();
      }

      print("ROW: $row");
      print("DATA: $data");

      // 🔥 CLEAN DATA
      final customerName =
          data['customer_name'] ?? data['Customer Name'] ?? "Unknown";

      final phone =
          data['phone']?.toString().replaceAll('.0', '') ?? "";

      // 🔥 PARSE DELIVERY DATE (WITH TIME)
      DateTime? deliveryDate;

      if (data['delivery_date'] != null &&
          data['delivery_date'].toString().isNotEmpty) {
        try {
          deliveryDate = DateTime.parse(data['delivery_date']);
        } catch (e) {
          print("Invalid delivery_date format");
        }
      }

      // 🔥 SAVE TO FIREBASE
      await FirebaseFirestore.instance.collection('packages').add({
        ...data,

        "customer_name": customerName,
        "phone": phone,

        "driver_id": null,
        "driver_email": null,
        "vehicle_id": null,

        "status": "pending",

        "delivery_date": deliveryDate,

        "created_at": FieldValue.serverTimestamp(),
        "started_at": null,
        "completed_at": null,

        "created_by_id": currentUser.uid,
        "created_by_email": currentUser.email ?? "unknown",
        "created_by_name": currentUser.displayName ?? "unknown",
      });
    }

    print("UPLOAD FINISHED SUCCESSFULLY 🚀");
  }
}