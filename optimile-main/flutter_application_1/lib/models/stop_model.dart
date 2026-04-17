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
    "is_fragile": isFragile,
    "window_start": windowStartMin,
    "window_end": windowEndMin,
    "title": title,
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

/// A single vehicle route (e.g. "Car 1", "Car 2") with its own list of stops.
class RouteModel {
  final String id;
  String name;
  List<Stop> stops;
  final Color color;

  RouteModel({
    required this.id,
    this.name = 'Car 1',
    List<Stop>? stops,
    Color? color,
  })  : stops = stops ?? [],
        color = color ?? Colors.blue;

  RouteModel copyWith({
    String? id,
    String? name,
    List<Stop>? stops,
    Color? color,
  }) {
    return RouteModel(
      id: id ?? this.id,
      name: name ?? this.name,
      stops: stops ?? List.from(this.stops),
      color: color ?? this.color,
    );
  }
}

/// Fixed palette for multiple routes (cars).
const List<Color> kRouteColors = [
  Colors.blue,
  Colors.red,
  Colors.green,
  Colors.orange,
  Colors.purple,
  Colors.teal,
];

// ─────────────────────────────────────────────────────────────────────────────
// XAI — Explainable AI  (EU AI Act Art. 13 + Contrastive XAI, Miller 2018)
// ─────────────────────────────────────────────────────────────────────────────

/// Semantic category of a system decision — drives colour coding in the UI.
enum XaiCategory {
  optimization, // route order change by ALNS / Bellman-Ford
  hazard,       // road hazard detected (OSM)
  weather,      // weather-triggered reroute
  deviation,    // driver went off-route
  fleet,        // multi-vehicle stop transfer
  info,         // neutral status update
}

/// A single structured entry in the real-time XAI event log.
///
/// Fields follow the Contrastive Explanation schema (Miller 2018):
///   WHY this happened  →  [trigger] + [evidence]
///   WHAT was decided   →  [decision] + [method]
///   HOW certain        →  [confidence]
///   HOW MUCH it helped →  [impactMin] (minutes saved, positive = improvement)
///   WHAT IF NOT        →  [counterfactual] (plain-language "without this…")
class EventLogEntry {
  final String      icon;
  final String      message;       // human-readable summary (always present)
  final String      time;

  // ── structured XAI fields ─────────────────────────────────────────────────
  final XaiCategory category;
  final double?     confidence;    // 0.0 – 1.0  (model + algorithm certainty)
  final double?     impactMin;     // minutes saved (>0 = better, <0 = worse)
  final String?     counterfactual; // "Without this action, ETA would be +X min"
  final String?     causalChain;   // "Event → Decision → Outcome" one-liner

  EventLogEntry({
    required this.icon,
    required this.message,
    required this.time,
    this.category      = XaiCategory.info,
    this.confidence,
    this.impactMin,
    this.counterfactual,
    this.causalChain,
  });
}