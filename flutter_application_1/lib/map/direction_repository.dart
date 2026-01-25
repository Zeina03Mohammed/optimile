// directions_repository.dart
import 'dart:convert';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;

/// Model class for Directions
class Directions {
  final List<LatLng> polylinePoints;
  final String totalDistance;
  final String totalDuration;

  Directions({
    required this.polylinePoints,
    required this.totalDistance,
    required this.totalDuration,
  });
}

/// Repository that calls Google Directions API and returns Directions
class DirectionsRepository {
  final String apiKey;

  DirectionsRepository({required this.apiKey});

  /// Get directions from origin to destination
  Future<Directions> getDirections({
    required LatLng origin,
    required LatLng destination,
  }) async {
    final url =
        'https://maps.googleapis.com/maps/api/directions/json'
        '?origin=${origin.latitude},${origin.longitude}'
        '&destination=${destination.latitude},${destination.longitude}'
        '&key=$apiKey';

    final response = await http.get(Uri.parse(url));
    final data = json.decode(response.body);

    if (data['status'] != 'OK') {
      throw Exception('Error fetching directions: ${data['status']}');
    }

    final route = data['routes'][0];
    final leg = route['legs'][0];

    // Distance & Duration
    final totalDistance = leg['distance']['text'];
    final totalDuration = leg['duration']['text'];

    // Decode polyline points
    final polyline = _decodePolyline(route['overview_polyline']['points']);

    return Directions(
      polylinePoints: polyline,
      totalDistance: totalDistance,
      totalDuration: totalDuration,
    );
  }

  /// Decode Google polyline string into list of LatLng
  List<LatLng> _decodePolyline(String encoded) {
    List<LatLng> poly = [];
    int index = 0, len = encoded.length;
    int lat = 0, lng = 0;

    while (index < len) {
      int b, shift = 0, result = 0;
      do {
        b = encoded.codeUnitAt(index++) - 63;
        result |= (b & 0x1F) << shift;
        shift += 5;
      } while (b >= 0x20);
      int dlat = ((result & 1) != 0 ? ~(result >> 1) : (result >> 1));
      lat += dlat;

      shift = 0;
      result = 0;
      do {
        b = encoded.codeUnitAt(index++) - 63;
        result |= (b & 0x1F) << shift;
        shift += 5;
      } while (b >= 0x20);
      int dlng = ((result & 1) != 0 ? ~(result >> 1) : (result >> 1));
      lng += dlng;

      poly.add(LatLng(lat / 1e5, lng / 1e5));
    }

    return poly;
  }
}
