import 'dart:math' as math;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_application_1/models/stop_model.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

class FirestoreService {
  String? _activeDeliveryId;
  String? get activeDeliveryId => _activeDeliveryId;

  // ================= SAVE TO FIRESTORE =================
  Future<void> saveDeliveryToFirestore(
    double initialEta,
    double optimizedEta,
    List<Stop> stops,
  ) async {
    print("🚀 _saveDeliveryToFirestore CALLED");

    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return;

      final firestore = FirebaseFirestore.instance;

      // Calculate total distance
      double totalDistance = 0;
      for (int i = 0; i < stops.length - 1; i++) {
        totalDistance += _calculateDistance(
          stops[i].location,
          stops[i + 1].location,
        );
      }

      // Create main delivery document
      final deliveryRef = await firestore.collection('deliveries').add({
        'driver_id': user.uid,
        'driver_email': user.email,
        'status': 'pending',
        'created_at': FieldValue.serverTimestamp(),
        'started_at': null,
        'completed_at': null,
        'total_distance': totalDistance,
        'vehicle_id': null,
      });

      _activeDeliveryId = deliveryRef.id;

      // Add stops as subcollection
      final batch = firestore.batch();

      for (int i = 0; i < stops.length; i++) {
        final stop = stops[i];
        final stopRef = deliveryRef.collection('stops').doc();

        batch.set(stopRef, {
          'address': stop.title ?? 'Location ${i + 1}',
          'latitude': stop.location.latitude,
          'longitude': stop.location.longitude,
          'sequence_order': stop.sequenceOrder,
          'estimated_time': stop.estimatedTime ?? 0,
          'actual_time': stop.actualTime,
          'status': stop.status,
          'metadata': {
            'customer_name': '',
            'notes': '',
            'phone': '',
          }
        });
      }

      // Add route optimization data
      final routeRef = deliveryRef.collection('routes').doc();
      batch.set(routeRef, {
        'original_cost': initialEta,
        'optimized_cost': optimizedEta,
        'time_saved': initialEta - optimizedEta,
        'created_at': FieldValue.serverTimestamp(),
        'optimization_data': {
          'algorithm': 'ALNS',
          'iterations': 300,
          'route_order': List.generate(stops.length, (i) => i + 1),
        }
      });

      await batch.commit();

      print("✅ Delivery saved to Firestore with ID: ${deliveryRef.id}");
      print("   - ${stops.length} stops saved");
      print("   - Route optimization data saved");
    } catch (e) {
      print("❌ Error saving to Firestore: $e");
    }
  }

  // ================= UPDATE STATUS =================
  Future<void> updateRouteStatusInFirestore(String status) async {
    if (_activeDeliveryId == null) {
      print("❌ No active delivery ID");
      return;
    }

    try {
      await FirebaseFirestore.instance
          .collection('deliveries')
          .doc(_activeDeliveryId)
          .update({
        'status': status,
        if (status == 'completed')
          'completed_at': FieldValue.serverTimestamp(),
      });

      print("✅ Firestore updated: status = $status");
    } catch (e) {
      print("❌ Failed to update route status: $e");
    }
  }

  // ================= LOCAL DISTANCE HELPER =================
  double _calculateDistance(LatLng from, LatLng to) {
    const R = 6371.0;
    final dLat = (to.latitude - from.latitude) * math.pi / 180;
    final dLon = (to.longitude - from.longitude) * math.pi / 180;

    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(from.latitude * math.pi / 180) *
            math.cos(to.latitude * math.pi / 180) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);

    return R * 2 * math.asin(math.sqrt(a));
  }
}
