import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;
import 'env.dart';

class Place {
  final String placeId;
  final String description;

  Place({required this.placeId, required this.description});
}

class PlacesService {
  final String apiKey;
  String _sessionToken = UniqueKey().toString();

  PlacesService({this.apiKey = Env.googleMapsApiKey});

  // Reset session token after a selection
  void resetSession() {
    _sessionToken = UniqueKey().toString();
  }

  // Get suggestions for autocomplete
  Future<List<Place>> getSuggestions(String input) async {
    final url =
        'https://maps.googleapis.com/maps/api/place/autocomplete/json?input=$input&key=$apiKey&sessiontoken=$_sessionToken';
    final response = await http.get(Uri.parse(url));
    if (response.statusCode != 200) return [];

    final data = json.decode(response.body);
    if (data['status'] != 'OK') return [];

    final List<Place> results = [];
    for (var prediction in data['predictions']) {
      results.add(Place(
          placeId: prediction['place_id'],
          description: prediction['description']));
    }
    return results;
  }

  // Get LatLng from placeId
  Future<LatLng?> getCoordinatesFromPlaceId(String placeId) async {
    final url =
        'https://maps.googleapis.com/maps/api/place/details/json?place_id=$placeId&key=$apiKey&sessiontoken=$_sessionToken';
    final response = await http.get(Uri.parse(url));
    if (response.statusCode != 200) return null;

    final data = json.decode(response.body);
    if (data['status'] != 'OK') return null;

    final location = data['result']['geometry']['location'];
    return LatLng(location['lat'], location['lng']);
  }

  // Get directions between two points
  Future<Map<String, dynamic>?> getDirections(LatLng origin, LatLng destination) async {
    final url =
        'https://maps.googleapis.com/maps/api/directions/json?origin=${origin.latitude},${origin.longitude}&destination=${destination.latitude},${destination.longitude}&key=$apiKey';
    final response = await http.get(Uri.parse(Uri.encodeFull(url)));
    if (response.statusCode != 200) return null;

    final data = json.decode(response.body);
    if (data['status'] != 'OK') return null;

    return data['routes'][0];
  }

  // Decode polyline into list of LatLng
  List<LatLng> decodePolyline(String encoded) {
    List<LatLng> polyline = [];
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

      polyline.add(LatLng(lat / 1e5, lng / 1e5));
    }
    return polyline;
  }
}
