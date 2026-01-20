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
  // ================= OPTIMIZE ROUTE (CALL BACKEND) =================
Future<void> _optimizeRoute() async {
  if (_currentLocation == null || _stops.length < 2) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("Add at least 2 stops to optimize")),
    );
    return;
  }

  final stopsPayload = _stops.asMap().entries.map((entry) {
    final i = entry.key;
    final stop = entry.value;

    return {
      "Order_ID": "STOP_${i + 1}", // ✅ REQUIRED BY BACKEND
      "Drop_Latitude": stop.latitude,
      "Drop_Longitude": stop.longitude,
      "Store_Latitude": _currentLocation!.latitude,
      "Store_Longitude": _currentLocation!.longitude,
      "Agent_Rating": 4.5,
      "Agent_Age": 30,
      "Weather": "Sunny",
      "Traffic": "Medium",
      "Vehicle": "van",
      "Area": "Urban",
      "Category": "Electronics",
      "hour": 8,
      "dayofweek": 2,
    };
  }).toList();

  final body = {
    "stops": stopsPayload,
  };

  try {
    final response = await http.post(
      Uri.parse("http://10.0.2.2:8000/optimize"),
      headers: {"Content-Type": "application/json"},
      body: jsonEncode(body),
    );
    print("RAW BACKEND RESPONSE: ${response.body}");


    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);

      final List optimizedStops = data["optimized_route"];
      final double initialCost = (data["initial_cost"] as num).toDouble();
      final double optimizedCost = (data["optimized_cost"] as num).toDouble();
      final double saved = initialCost - optimizedCost;

      print("=== ROUTE COMPARISON ===");
      print("Initial Cost: $initialCost");
      print("Optimized Cost: $optimizedCost");
      print("Saved Time: $saved minutes");

      // 🔁 Rebuild stops list in optimized order
      _stops.clear();
      setState(() {
      _stops.clear();

      for (final stop in optimizedStops) {
          _stops.add(
          LatLng(
            stop["Drop_Latitude"],
           stop["Drop_Longitude"],
           ),
         );
       }
    });

      // 🔄 Force map redraw with new order
      _rebuildMap();

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Route optimized successfully")),
      );
    } else {
      debugPrint("Optimization failed: ${response.body}");
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Optimization failed")),
      );
    }
  } catch (e) {
    debugPrint("Optimization error: $e");
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("Server error during optimization")),
    );
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
    FloatingActionButton.extended(
      onPressed: _optimizeRoute,
      heroTag: "optimize",
      label: const Text("Optimize"),
      icon: const Icon(Icons.auto_graph),
    ),
  ],
),
    );
  }
}
