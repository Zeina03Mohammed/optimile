import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:http/http.dart' as http;
import 'package:geolocator/geolocator.dart';

class Stop {
  String? name;
  LatLng? location;
  Stop({this.name, this.location});
}

class DriverMapTab extends StatefulWidget {
  const DriverMapTab({super.key});

  @override
  State<DriverMapTab> createState() => _DriverMapTabState();
}

class _DriverMapTabState extends State<DriverMapTab> {
  LatLng? currentLocation;
  final List<Marker> markers = [];
  final List<LatLng> routePoints = [];
  List<Stop> stops = [];
  int selectedStopIndex = 0;

  double totalDistanceKm = 0;
  double totalDurationMin = 0;

  final String orsApiKey =
      "eyJvcmciOiI1YjNjZTM1OTc4NTExMTAwMDFjZjYyNDgiLCJpZCI6IjY0YTdjYTQ3ODA2MDRkMmM4MWJhNWM3NmI0ZTk2MjYyIiwiaCI6Im11cm11cjY0In0=";
  final String googleApiKey =
      "AIzaSyCUqESrPfdNpQSCVoPITrphmbvic4hVKfk";

  StreamSubscription<Position>? positionStream;

  final TextEditingController newStopController = TextEditingController();
  final MapController mapController = MapController();

  @override
  void initState() {
    super.initState();
    loadCurrentLocation();
  }

  @override
  void dispose() {
    positionStream?.cancel();
    newStopController.dispose();
    super.dispose();
  }

  // ================= LOCATION =================

  Future<void> loadCurrentLocation() async {
    try {
      LatLng loc = await getMobileLocation();
      setState(() {
        currentLocation = loc;
        routePoints.add(loc);
        markers.add(Marker(
          point: loc,
          width: 40,
          height: 40,
          child: const Icon(Icons.my_location, color: Colors.blue, size: 40),
        ));
        stops.add(Stop(name: "Your location", location: loc));
      });

      mapController.move(loc, 16);

      if (!kIsWeb) startMobileLocationUpdates();
    } catch (e) {
      _showError("Failed to get location: $e");
    }
  }

  Future<LatLng> getMobileLocation() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) throw Exception("Location services disabled");

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.deniedForever) {
      throw Exception("Location permission permanently denied");
    }

    Position pos = await Geolocator.getCurrentPosition(
      desiredAccuracy: LocationAccuracy.bestForNavigation,
    );

    return LatLng(pos.latitude, pos.longitude);
  }

  void startMobileLocationUpdates() {
    positionStream = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 5,
      ),
    ).listen((Position pos) {
      setState(() {
        currentLocation = LatLng(pos.latitude, pos.longitude);
        if (markers.isNotEmpty) {
          markers[0] = Marker(
            point: currentLocation!,
            width: 40,
            height: 40,
            child:
                const Icon(Icons.my_location, color: Colors.blue, size: 40),
          );
        }
        stops[0].location = currentLocation;
      });
      recalculateRoute();
    });
  }

  void _showError(String msg) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  // ================= GOOGLE GEOCODE =================

  Future<LatLng?> geocodeWithGoogle(String input) async {
    final url = Uri.parse(
        "https://maps.googleapis.com/maps/api/geocode/json?address=${Uri.encodeComponent(input)}&key=$googleApiKey");

    final response = await http.get(url);
    final data = json.decode(response.body);

    if (data['status'] == 'OK' && data['results'].isNotEmpty) {
      final location = data['results'][0]['geometry']['location'];
      return LatLng(location['lat'], location['lng']);
    }
    return null;
  }

  // ================= ADD STOP =================

  Future<void> addStop({LatLng? destination, String? name}) async {
    if (currentLocation == null) return;

    String? stopName = name ?? newStopController.text.trim();

    if (destination == null && (stopName.isEmpty)) {
      _showError("Enter a place, Plus Code, or coordinates");
      return;
    }

    if (destination == null) {
      destination = await geocodeWithGoogle(stopName);
      if (destination == null) {
        _showError("Place not found");
        return;
      }
    }

    setState(() {
      stops.add(Stop(name: stopName, location: destination));
      markers.add(
        Marker(
          point: destination!,
          width: 40,
          height: 40,
          child: const Icon(Icons.place, color: Colors.orange, size: 40),
        ),
      );
      routePoints.add(destination);
      newStopController.clear();
    });

    mapController.move(destination, 16);
    recalculateRoute();
  }

  // ================= REMOVE STOP =================
// ================= REMOVE STOP =================
void removeStop(int index) {
  if (index == 0) return; // can't remove your location
  setState(() {
    stops.removeAt(index);
    markers.removeAt(index);
    recalculateRoute(); // recalc route after deletion
  });
}

// ================= RECALCULATE ROUTE =================
Future<void> recalculateRoute() async {
  if (stops.isEmpty) {
    routePoints.clear();
    totalDistanceKm = 0;
    totalDurationMin = 0;
    return;
  }

  // Reset everything
  routePoints.clear();
  totalDistanceKm = 0;
  totalDurationMin = 0;

  routePoints.add(stops[0].location!); // start from first stop

  if (stops.length < 2) return;

  for (int i = 1; i < stops.length; i++) {
    LatLng start = stops[i - 1].location!;
    LatLng end = stops[i].location!;

    final routeUrl = Uri.parse(
        "https://api.openrouteservice.org/v2/directions/driving-car/geojson");

    final body = json.encode({
      "coordinates": [
        [start.longitude, start.latitude],
        [end.longitude, end.latitude],
      ]
    });

    final routeResponse = await http.post(
      routeUrl,
      headers: {
        "Authorization": orsApiKey,
        "Content-Type": "application/json",
      },
      body: body,
    );

    final routeData = json.decode(routeResponse.body);
    final coords =
        routeData['features'][0]['geometry']['coordinates'] as List;
    final summary = routeData['features'][0]['properties']['summary'];

    final List<LatLng> newRoute = coords
        .map((c) => LatLng(
              (c[1] as num).toDouble(),
              (c[0] as num).toDouble(),
            ))
        .toList();

    // Append segment to routePoints
    routePoints.addAll(newRoute.sublist(1)); // skip duplicate start point

    totalDistanceKm += (summary['distance'] as num) / 1000;
    totalDurationMin += (summary['duration'] as num) / 60;
  }
}


  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Column(
        children: [
          Expanded(
            child: currentLocation == null
                ? const Center(child: CircularProgressIndicator())
                : FlutterMap(
                    mapController: mapController,
                    options: MapOptions(
                      center: currentLocation,
                      zoom: 16,
                      onTap: (tapPos, point) {
                        addStop(destination: point, name: "Custom point");
                      },
                    ),
                    children: [
                      TileLayer(
                        urlTemplate:
                            "https://mt1.google.com/vt/lyrs=m&x={x}&y={y}&z={z}&key=$googleApiKey",
                        subdomains: ['mt0', 'mt1', 'mt2', 'mt3'],
                      ),
                      PolylineLayer(
                        polylines: [
                          Polyline(
                            points: routePoints,
                            strokeWidth: 5,
                            color: Colors.blue,
                          ),
                        ],
                      ),
                      MarkerLayer(markers: markers),
                    ],
                  ),
          ),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.grey[900],
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(24)),
            ),
            child: Column(
              children: [
                ListView.builder(
                  shrinkWrap: true,
                  itemCount: stops.length,
                  itemBuilder: (context, index) {
                    final stop = stops[index];
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4.0),
                      child: Row(
                        children: [
                          Radio<int>(
                            value: index,
                            groupValue: selectedStopIndex,
                            onChanged: (value) {
                              if (value == null) return;
                              setState(() {
                                selectedStopIndex = value;
                              });
                              final loc = stops[value].location;
                              if (loc != null) mapController.move(loc, 16);
                            },
                          ),
                          Expanded(
                            child: Text(
                              stop.name ?? "Unknown",
                              style: const TextStyle(color: Colors.white),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (index != 0)
                            IconButton(
                              icon: const Icon(Icons.close, color: Colors.red),
                              onPressed: () {
                                removeStop(index);
                              },
                            ),
                        ],
                      ),
                    );
                  },
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: newStopController,
                        style: const TextStyle(color: Colors.white),
                        decoration: const InputDecoration(
                          hintText: "Add destination",
                          hintStyle: TextStyle(color: Colors.white38),
                          filled: true,
                          fillColor: Colors.white10,
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.add, color: Colors.green),
                      onPressed: () {
                        addStop();
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                if (totalDistanceKm > 0)
                  Text(
                    "Distance: ${totalDistanceKm.toStringAsFixed(1)} km | "
                    "ETA: ${totalDurationMin.toStringAsFixed(0)} min",
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
