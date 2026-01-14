import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';

class DriverMapTab extends StatefulWidget {
  const DriverMapTab({super.key});

  @override
  State<DriverMapTab> createState() => _DriverMapTabState();
}

class _DriverMapTabState extends State<DriverMapTab> {
  final LatLng initialLocation = LatLng(30.0444, 31.2357); // Cairo
  final List<Marker> markers = [];
  final List<LatLng> routePoints = [];
  final TextEditingController placeController = TextEditingController();
  double totalDistanceKm = 0;
  double totalDurationMin = 0;

  @override
  void initState() {
    super.initState();
    markers.add(
      Marker(
        point: initialLocation,
        width: 40,
        height: 40,
        child: const Icon(Icons.location_on, color: Colors.red, size: 40),
      ),
    );
    routePoints.add(initialLocation);
  }

  Future<void> addStop() async {
    final placeName = placeController.text.trim();
    if (placeName.isEmpty) {
      _showError("Please enter a place name.");
      return;
    }

    try {
      // 1️⃣ Get coordinates from Nominatim
      final nominatimUrl = Uri.parse(
          'https://nominatim.openstreetmap.org/search?q=$placeName&format=json&limit=1');

      final nominatimResponse = await http.get(nominatimUrl, headers: {
        "User-Agent": "FlutterApp"
      });

      if (nominatimResponse.statusCode != 200) {
        _showError(
            "Error finding place. Status code: ${nominatimResponse.statusCode}");
        return;
      }

      final data = json.decode(nominatimResponse.body);
      if (data.isEmpty) {
        _showError("Place not found.");
        return;
      }

      final lat = double.parse(data[0]['lat']);
      final lon = double.parse(data[0]['lon']);
      final newPoint = LatLng(lat, lon);

      // 2️⃣ Fetch route from OpenRouteService
      final routeUrl =
          Uri.parse("https://api.openrouteservice.org/v2/directions/driving-car/geojson");

      final body = json.encode({
        "coordinates": [
          [routePoints.last.longitude, routePoints.last.latitude], // last point
          [newPoint.longitude, newPoint.latitude], // new stop
        ]
      });

      final routeResponse = await http.post(routeUrl,
          headers: {
            "Authorization": "eyJvcmciOiI1YjNjZTM1OTc4NTExMTAwMDFjZjYyNDgiLCJpZCI6IjY0YTdjYTQ3ODA2MDRkMmM4MWJhNWM3NmI0ZTk2MjYyIiwiaCI6Im11cm11cjY0In0=", // replace with your key
            "Content-Type": "application/json"
          },
          body: body);

      if (routeResponse.statusCode != 200) {
        _showError(
            "Error fetching route. Status code: ${routeResponse.statusCode}");
        return;
      }

      final routeData = json.decode(routeResponse.body);
      final coordinates = routeData['features'][0]['geometry']['coordinates'] as List;
      final summary = routeData['features'][0]['properties']['summary'];

      // Convert to LatLng
      List<LatLng> newRoutePoints = coordinates
          .map((c) => LatLng(c[1] as double, c[0] as double))
          .toList();

      setState(() {
        markers.add(
          Marker(
            point: newPoint,
            width: 40,
            height: 40,
            child: const Icon(Icons.place, color: Colors.orange, size: 40),
          ),
        );
        routePoints.addAll(newRoutePoints);

        // Update total distance and duration
        totalDistanceKm += (summary['distance'] as num) / 1000;
        totalDurationMin += (summary['duration'] as num) / 60;
      });

      placeController.clear();
    } catch (e) {
      _showError("Error: $e");
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.red),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Column(
        children: [
          // ===== MAP AREA =====
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: FlutterMap(
                options: MapOptions(
                  center: initialLocation,
                  zoom: 13,
                ),
                children: [
                  TileLayer(
                    urlTemplate:
                        "https://mt1.google.com/vt/lyrs=m&x={x}&y={y}&z={z}&key=AIzaSyCUqESrPfdNpQSCVoPITrphmbvic4hVKfk",
                    userAgentPackageName: 'com.example.flutter_application_1',
                  ),
                  MarkerLayer(markers: markers),
                  PolylineLayer(
                    polylines: [
                      Polyline(
                        points: routePoints,
                        color: Colors.blue,
                        strokeWidth: 4,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),

          // ===== ADD STOPS PANEL =====
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Colors.grey[900],
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(24)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  "Type a place name to add a stop",
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white70, fontSize: 16),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: placeController,
                  decoration: const InputDecoration(
                    hintText: "Place name",
                    filled: true,
                    fillColor: Colors.white10,
                    border: OutlineInputBorder(),
                    hintStyle: TextStyle(color: Colors.white38),
                  ),
                  style: const TextStyle(color: Colors.white),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  height: 50,
                  child: ElevatedButton.icon(
                    onPressed: addStop,
                    icon: const Icon(Icons.add),
                    label: const Text("Add Stop"),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blue,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                if (routePoints.length > 1)
                  Text(
                    "Total Distance: ${totalDistanceKm.toStringAsFixed(1)} km | ETA: ${totalDurationMin.toStringAsFixed(0)} min",
                    style: const TextStyle(color: Colors.white70),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
