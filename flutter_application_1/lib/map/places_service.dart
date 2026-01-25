import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;
import 'env.dart';

/// =================== MODELS ===================

class Place {
  final String placeId;
  final String description;

  Place({required this.placeId, required this.description});
}

class Review {
  final String authorName;
  final String text;
  final double rating;

  Review({required this.authorName, required this.text, required this.rating});
}

class PlaceDetails {
  final String name;
  final String address;
  final List<String> photos;
  final List<Review> reviews;
  final String type;
  final String status;

  /// Compute average rating from reviews
  double get rating {
    if (reviews.isEmpty) return 0.0;
    return reviews.map((r) => r.rating).reduce((a, b) => a + b) / reviews.length;
  }

  PlaceDetails({
    required this.name,
    required this.address,
    required this.photos,
    this.reviews = const [],
    this.type = 'Unknown',
    this.status = 'Unknown',
  });
}

/// =================== SERVICE ===================

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
        'https://maps.googleapis.com/maps/api/place/autocomplete/json?input=$input&key=$apiKey&sessiontoken=$_sessionToken';
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
      '&fields=name,vicinity,photos,rating,business_status,types,reviews'
      '&key=$apiKey';

  final response = await http.get(Uri.parse(url));
  if (response.statusCode != 200) return null;

  final data = json.decode(response.body);
  if (data['status'] != 'OK' || data['result'] == null) return null;

  final place = data['result'];

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

  // Reviews
  List<Review> reviews = [];
  if (place['reviews'] != null) {
    for (var r in place['reviews']) {
      reviews.add(Review(
        authorName: r['author_name'] ?? 'Anonymous',
        text: r['text'] ?? '',
        rating: (r['rating'] != null) ? r['rating'].toDouble() : 0.0,
      ));
    }
  }

  // Type
  String type = 'Unknown';
  if (place['types'] != null && place['types'].isNotEmpty) {
    type = place['types'][0];
  }

  // Status
  String status = place['business_status'] ?? 'Unknown';

  // Rating

  return PlaceDetails(
    name: place['name'] ?? 'Unknown',
    address: place['vicinity'] ?? 'No address',
    photos: photos,
    reviews: reviews,
    type: type,
    status: status,
  );
}


  /// ================= GET DIRECTIONS =================
  Future<Map<String, dynamic>?> getDirections(
      LatLng origin, LatLng destination) async {
    final url =
        'https://maps.googleapis.com/maps/api/directions/json?origin=${origin.latitude},${origin.longitude}&destination=${destination.latitude},${destination.longitude}&key=$apiKey';
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
