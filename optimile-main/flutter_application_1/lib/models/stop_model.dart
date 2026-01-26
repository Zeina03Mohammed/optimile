import 'package:google_maps_flutter/google_maps_flutter.dart';

/// =================== STOP MODEL ===================

class Stop {
  final String id; // Firestore doc ID (optional)
  final LatLng location;
  final String? title;
  final int sequenceOrder;
  String status; // pending, current, completed
  double? estimatedTime; // in minutes
  double? actualTime; // in minutes

  Stop({
    required this.location,
    this.title,
    this.id = '',
    this.sequenceOrder = 0,
    this.status = 'pending',
    this.estimatedTime,
    this.actualTime,
  });

  /// Create Stop from PlaceDetails
  factory Stop.fromPlaceDetails(PlaceDetails place, {int sequenceOrder = 0}) {
    return Stop(
      location: place.location,
      title: place.name,
      sequenceOrder: sequenceOrder,
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
  }) {
    return Stop(
      id: id ?? this.id,
      location: location ?? this.location,
      title: title ?? this.title,
      sequenceOrder: sequenceOrder ?? this.sequenceOrder,
      status: status ?? this.status,
      estimatedTime: estimatedTime ?? this.estimatedTime,
      actualTime: actualTime ?? this.actualTime,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'latitude': location.latitude,
      'longitude': location.longitude,
      'title': title,
      'sequence_order': sequenceOrder,
      'status': status,
      'estimated_time': estimatedTime,
      'actual_time': actualTime,
    };
  }

  factory Stop.fromMap(Map<String, dynamic> map) {
    return Stop(
      location: LatLng(map['latitude'], map['longitude']),
      title: map['title'],
      sequenceOrder: map['sequence_order'] ?? 0,
      status: map['status'] ?? 'pending',
      estimatedTime: map['estimated_time']?.toDouble(),
      actualTime: map['actual_time']?.toDouble(),
      id: map['id'] ?? '',
    );
  }
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
  final LatLng location; // added for map integration
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
