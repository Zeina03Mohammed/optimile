import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:flutter/material.dart';
/// =================== STOP MODEL ===================

class Stop {
  final String id; // Firestore doc ID (optional)
  final LatLng location;
  final String? title;

  final int sequenceOrder;
  String status; // pending, current, completed

  double? estimatedTime; // in minutes
  double? actualTime; // in minutes

  /// 🔥 NEW: stop-level fragility
  bool isFragile;

  /// 🔥 NEW: stop-level time window (minutes from midnight)
  int windowStartMin;
  int windowEndMin;

  Stop({
    required this.location,
    this.title,
    this.id = '',
    this.sequenceOrder = 0,
    this.status = 'pending',
    this.estimatedTime,
    this.actualTime,

    // NEW (safe defaults)
    this.isFragile = false,
    this.windowStartMin = 0,        // 00:00
    this.windowEndMin = 24 * 60,    // 24:00
  });

  /// Create Stop from PlaceDetails
  factory Stop.fromPlaceDetails(
    PlaceDetails place, {
    int sequenceOrder = 0,
    bool isFragile = false,
    int windowStartMin = 0,
    int windowEndMin = 24 * 60,
  }) {
    return Stop(
      location: place.location,
      title: place.name,
      sequenceOrder: sequenceOrder,
      isFragile: isFragile,
      windowStartMin: windowStartMin,
      windowEndMin: windowEndMin,
    );
  }

  /// CopyWith method for updating Stop
  Stop copyWith({
    String? id,
    LatLng? location,
    String? title,
    int? sequenceOrder,
    String? status,
    double? estimatedTime,
    double? actualTime,
    bool? isFragile,
    int? windowStartMin,
    int? windowEndMin,
  }) {
    return Stop(
      id: id ?? this.id,
      location: location ?? this.location,
      title: title ?? this.title,
      sequenceOrder: sequenceOrder ?? this.sequenceOrder,
      status: status ?? this.status,
      estimatedTime: estimatedTime ?? this.estimatedTime,
      actualTime: actualTime ?? this.actualTime,
      isFragile: isFragile ?? this.isFragile,
      windowStartMin: windowStartMin ?? this.windowStartMin,
      windowEndMin: windowEndMin ?? this.windowEndMin,
    );
  }

  /// 🔥 Payload for backend optimization
  Map<String, dynamic> toPayload() {
  return {
    "lat": location.latitude,
    "lng": location.longitude,
    "is_fragile": isFragile,          // ✅ REQUIRED
    "window_start": windowStartMin,      // ✅ REQUIRED (nullable ok)
    "window_end": windowEndMin,          // ✅ REQUIRED (nullable ok)
  };
}
}
class StopConfig {
  final bool isFragile;
  final TimeOfDay? start;
  final TimeOfDay? end;

  StopConfig({
    required this.isFragile,
    required this.start,
    required this.end,
  });
}
/// =================== PLACE MODELS (FOR PLACES SERVICE) ===================

class Place {
  final String placeId;
  final String description;

  Place({required this.placeId, required this.description});
}

class PlaceDetails {
  final String name;
  final String address;
  final LatLng location;
  final String type;
  final String status;

  PlaceDetails({
    required this.name,
    required this.address,
    required this.location,
    this.type = 'Unknown',
    this.status = 'Unknown',
  });
}