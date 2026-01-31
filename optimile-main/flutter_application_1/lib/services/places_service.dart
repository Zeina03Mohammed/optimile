import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;
import '/env.dart';
import '../models/stop_model.dart'; 

class PlacesService {
  final String apiKey;
  String _sessionToken = UniqueKey().toString();

  PlacesService({this.apiKey = Env.googleMapsApiKey});

  /// Reset session token after a selection
  void resetSession() {
    _sessionToken = UniqueKey().toString();
  }

  /// ================= AUTOCOMPLETE SUGGESTIONS =================
  Future<List<Place>> getSuggestions(String input) async {
    final url =
  'https://maps.googleapis.com/maps/api/place/autocomplete/json'
  '?input=$input'
  '&components=country:eg'
  '&key=$apiKey'
  '&sessiontoken=$_sessionToken';

    final response = await http.get(Uri.parse(url));
    if (response.statusCode != 200) return [];

    final data = json.decode(response.body);
    if (data['status'] != 'OK') return [];

    final List<Place> results = [];
    for (var prediction in data['predictions']) {
      results.add(Place(
        placeId: prediction['place_id'],
        description: prediction['description'],
      ));
    }
    return results;
  }

  /// ================= GET LATLNG FROM PLACE ID =================
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

  /// ================= GET PLACE DETAILS (INCLUDING PHOTOS, REVIEWS, TYPE, STATUS) =================
  Future<PlaceDetails?> getPlaceDetailsFromPlaceId(String placeId) async {
    final url =
        'https://maps.googleapis.com/maps/api/place/details/json'
        '?place_id=$placeId'
        '&fields=name,vicinity,geometry,photos,rating,business_status,types,reviews'
        '&key=$apiKey';

    final response = await http.get(Uri.parse(url));
    if (response.statusCode != 200) return null;

    final data = json.decode(response.body);
    if (data['status'] != 'OK' || data['result'] == null) return null;

    final place = data['result'];

    // Location
    final loc = place['geometry'] != null
        ? LatLng(place['geometry']['location']['lat'], place['geometry']['location']['lng'])
        : const LatLng(0, 0);

    // Photos
    final photos = <String>[];
    if (place['photos'] != null) {
      for (var p in place['photos']) {
        photos.add(
          'https://maps.googleapis.com/maps/api/place/photo'
          '?maxwidth=400&photoreference=${p['photo_reference']}&key=$apiKey',
        );
      }
    }


    // Type
    String type = 'Unknown';
    if (place['types'] != null && place['types'].isNotEmpty) {
      type = place['types'][0];
    }

    // Status
    String status = place['business_status'] ?? 'Unknown';

    return PlaceDetails(
      name: place['name'] ?? 'Unknown',
      address: place['vicinity'] ?? 'No address',
      location: loc,
      type: type,
      status: status,
    );
  }

  /// ================= GET DIRECTIONS =================
  /// Set [requestTraffic] true to get duration_in_traffic (for traffic monitor).
 Future<Map<String, dynamic>?> getDirections(
    LatLng origin, LatLng destination) async {
  
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  
  final url =
      'https://maps.googleapis.com/maps/api/directions/json?'
      'origin=${origin.latitude},${origin.longitude}&'
      'destination=${destination.latitude},${destination.longitude}&'
      'departure_time=$now&'  // ← ADD THIS
      'traffic_model=best_guess&'  // ← ADD THIS
      'key=$apiKey';

  final response = await http.get(Uri.parse(Uri.encodeFull(url)));
  if (response.statusCode != 200) return null;

  final data = json.decode(response.body);
  if (data['status'] != 'OK') return null;

  return data['routes'][0];
}


  /// ================= DECODE POLYLINE =================
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
