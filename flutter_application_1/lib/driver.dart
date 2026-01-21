import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_typeahead/flutter_typeahead.dart';

import 'map/places_service.dart';
import 'map/env.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;


class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  late GoogleMapController _mapController;
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  late PlacesService _placesService;

  LatLng? _currentLocation;
  final List<LatLng> _stops = [];
  final Set<Marker> _markers = {};
  final Set<Polyline> _polylines = {};

  String _distance = '';
  String _duration = '';

  bool _showSearchBar = false;

  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();

  static final CameraPosition _initialCameraPosition = CameraPosition(
    target: LatLng(Env.defaultLat, Env.defaultLng),
    zoom: 13,
  );

  @override
  void initState() {
    super.initState();
    _placesService = PlacesService();
    _goToCurrentLocation();
  }

  // ================= CURRENT LOCATION =================
  Future<void> _goToCurrentLocation() async {
    bool enabled = await Geolocator.isLocationServiceEnabled();
    if (!enabled) return;

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.deniedForever ||
        permission == LocationPermission.denied) return;

    final pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high);

    final latLng = LatLng(pos.latitude, pos.longitude);

    setState(() {
      _currentLocation = latLng;
      _markers.clear();
      _markers.add(Marker(
        markerId: const MarkerId('start'),
        position: latLng,
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen),
      ));
    });

    _mapController.animateCamera(
      CameraUpdate.newLatLngZoom(latLng, 15),
    );
    _rebuildMap();
  }

  // ================= ADD / REMOVE STOPS =================
  void _addStop(LatLng point) {
    _stops.add(point);
    _rebuildMap();
  }

  void _removeStop(int index) {
    _stops.removeAt(index);
    _rebuildMap();
  }
  // ================= OPTIMIZE =================

Future<void> _optimizeRoute() async {
  if (_stops.length < 2) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("Add at least two stops")),
    );
    return;
  }

  print("🔍 Stops before optimize: ${_stops.length}");
  for (var s in _stops) {
    print("Stop: ${s.latitude}, ${s.longitude}");
  }

  // ==============================
  // 1. CALCULATE REAL ETA (BEFORE)
  // ==============================
  double initialTotalMinutes = 0;
  LatLng? origin = _currentLocation;

  for (var stop in _stops) {
    if (origin != null) {
      final route = await _placesService.getDirections(origin, stop);
      if (route != null) {
        final seconds = route["legs"][0]["duration"]["value"];
        initialTotalMinutes += seconds / 60.0;
      }
    }
    origin = stop;
  }

  print("⏱ Initial REAL ETA: ${initialTotalMinutes.toStringAsFixed(1)} min");

  // ==============================
  // 2. SEND STOPS TO BACKEND
  // ==============================
  final stopsPayload = _stops.map((s) {
    return {
      "Order_ID": "STOP_${_stops.indexOf(s) + 1}",
      "Drop_Latitude": s.latitude,
      "Drop_Longitude": s.longitude,
      "Store_Latitude": _currentLocation?.latitude ?? s.latitude,
      "Store_Longitude": _currentLocation?.longitude ?? s.longitude,
      "Agent_Rating": 4.5,
      "Agent_Age": 30,
      "Weather": "Sunny",
      "Traffic": "Medium",
      "Vehicle": "van",
      "Area": "Urban",
      "Category": "Electronics",
      "hour": DateTime.now().hour,
      "dayofweek": DateTime.now().weekday % 7
    };
  }).toList();

  final body = {"stops": stopsPayload};

  try {
    final response = await http.post(
      Uri.parse("http://127.0.0.1:8000/optimize"),
      headers: {"Content-Type": "application/json"},
      body: jsonEncode(body),
    );

    print("RAW BACKEND RESPONSE: ${response.body}");

    final data = jsonDecode(response.body);
    final optimizedRoute = data["optimized_route"] as List<dynamic>;

    // ==============================
    // 3. BUILD NEW STOP LIST
    // ==============================
    final List<LatLng> newStops = [];

    for (var stop in optimizedRoute) {
      newStops.add(
        LatLng(
          stop["Drop_Latitude"],
          stop["Drop_Longitude"],
        ),
      );
    }

    // ==============================
    // 4. CALCULATE REAL ETA (AFTER)
    // ==============================
    double optimizedTotalMinutes = 0;
    origin = _currentLocation;

    for (var stop in newStops) {
      if (origin != null) {
        final route = await _placesService.getDirections(origin, stop);
        if (route != null) {
          final seconds = route["legs"][0]["duration"]["value"];
          optimizedTotalMinutes += seconds / 60.0;
        }
      }
      origin = stop;
    }

    print("⏱ Optimized REAL ETA: ${optimizedTotalMinutes.toStringAsFixed(1)} min");
    print("💡 Time Saved: ${(initialTotalMinutes - optimizedTotalMinutes).toStringAsFixed(1)} min");

    // ==============================
    // 5. APPLY OPTIMIZED ROUTE
    // ==============================
    setState(() {
      _stops
        ..clear()
        ..addAll(newStops);
    });

    _rebuildMap();

    // ==============================
    // 6. SHOW RESULT TO USER
    // ==============================
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          "Initial ETA: ${initialTotalMinutes.toStringAsFixed(1)} min\n"
          "Optimized ETA: ${optimizedTotalMinutes.toStringAsFixed(1)} min\n"
          "Saved: ${(initialTotalMinutes - optimizedTotalMinutes).toStringAsFixed(1)} min",
        ),
        duration: const Duration(seconds: 6),
      ),
    );

  } catch (e) {
    print("Optimization error: $e");
  }
}






  // ================= REBUILD MAP =================
  void _rebuildMap() async {
    print("🔄 Rebuilding map with ${_stops.length} stops");
    _markers.removeWhere((m) => m.markerId.value != 'start');
    _polylines.clear();
    _distance = '';
    _duration = '';

    LatLng? origin = _currentLocation;

    for (int i = 0; i < _stops.length; i++) {
      final destination = _stops[i];
      _markers.add(Marker(markerId: MarkerId('stop_$i'), position: destination));

      if (origin != null) {
        final route = await _placesService.getDirections(origin, destination);
        if (route != null) {
          final points = _placesService.decodePolyline(
              route['overview_polyline']['points']);
          _polylines.add(Polyline(
            polylineId: PolylineId('route_$i'),
            points: points,
            width: 5,
            color: Colors.blue,
          ));

          if (i == _stops.length - 1) {
            _distance = route['legs'][0]['distance']['text'];
            _duration = route['legs'][0]['duration']['text'];
          }
        }
      }

      origin = destination;
    }

    setState(() {});
    
  }

  // ================= SELECT SUGGESTION =================
  Future<void> _selectSuggestion(Place place) async {
    final latLng = await _placesService.getCoordinatesFromPlaceId(place.placeId);
    if (latLng != null) {
      _addStop(latLng);
      _mapController.animateCamera(CameraUpdate.newLatLngZoom(latLng, 15));
    }
    _placesService.resetSession();
    _searchController.clear();
    FocusScope.of(context).unfocus();
    setState(() {
      _showSearchBar = false;
    });
  }

  // ================= UI =================
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: _scaffoldKey,
      endDrawer: Drawer(
        child: Container(
          color: Colors.black,
          child: ListView.builder(
            itemCount: _stops.length,
            itemBuilder: (context, index) {
              final stop = _stops[index];
              return ListTile(
                leading: const Text('•', style: TextStyle(color: Colors.white)),
                title: Text(
                  'Stop ${index + 1}: ${stop.latitude.toStringAsFixed(4)}, ${stop.longitude.toStringAsFixed(4)}',
                  style: const TextStyle(color: Colors.white),
                ),
                onTap: () => _mapController.animateCamera(
                  CameraUpdate.newLatLngZoom(stop, 15),
                ),
                trailing: IconButton(
                  icon: const Icon(Icons.delete, color: Colors.red),
                  onPressed: () => _removeStop(index),
                ),
              );
            },
          ),
        ),
      ),
      body: Stack(
        children: [
          GoogleMap(
            initialCameraPosition: _initialCameraPosition,
            markers: _markers,
            polylines: _polylines,
            myLocationEnabled: true,
            onMapCreated: (c) => _mapController = c,
            onTap: _addStop,
          ),

          // 🔍 SEARCH BAR TOGGLE
          Positioned(
            top: 10 + MediaQuery.of(context).padding.top,
            left: 15,
            right: 15,
            child: _showSearchBar
                ? TypeAheadField<Place>(
  debounceDuration: const Duration(milliseconds: 300),
  suggestionsCallback: (pattern) async {
    if (pattern.isEmpty) return [];
    return _placesService.getSuggestions(pattern);
  },
  itemBuilder: (context, place) {
    return ListTile(
      leading: const Icon(Icons.location_on),
      title: Text(place.description),
    );
  },
  onSelected: _selectSuggestion, // ✅ Corrected
  builder: (context, controller, focusNode) {
    _searchController.value = controller.value;
    return TextField(
      controller: controller,
      focusNode: focusNode,
      decoration: InputDecoration(
        hintText: 'Search location',
        filled: true,
        fillColor: Colors.white,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
        ),
      ),
    );
  },
)

                : Align(
                    alignment: Alignment.topRight,
                    child: IconButton(
                      icon: const Icon(Icons.search, size: 30),
                      color: Colors.black,
                      onPressed: () {
                        setState(() {
                          _showSearchBar = true;
                          FocusScope.of(context).requestFocus(_searchFocusNode);
                        });
                      },
                    ),
                  ),
          ),

          // 🧭 Distance / ETA Display
          if (_distance.isNotEmpty && _duration.isNotEmpty)
            Positioned(
              bottom: 20,
              left: 20,
              right: 20,
              child: Container(
                padding: const EdgeInsets.all(12),
                color: Colors.white,
                child: Text(
                  'Distance: $_distance | Duration: $_duration',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
            ),
        ],
      ),
      floatingActionButton: Column(
  mainAxisSize: MainAxisSize.min,
  children: [
    FloatingActionButton(
      onPressed: _goToCurrentLocation,
      heroTag: "locate",
      child: const Icon(Icons.my_location),
    ),
    const SizedBox(height: 10),
    FloatingActionButton(
      onPressed: _optimizeRoute,
      child: const Icon(Icons.route),
    ),

  ],
),
    );
  }
}
