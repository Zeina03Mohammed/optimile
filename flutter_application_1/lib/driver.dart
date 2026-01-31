import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_typeahead/flutter_typeahead.dart';
import 'package:http/http.dart' as http;

import 'map/places_service.dart';
import 'map/env.dart';

class _Stop {
  final LatLng latLng;
  final String title;

  _Stop({
    required this.latLng,
    required this.title,
  });
}


class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  late GoogleMapController _mapController;
  late PlacesService _placesService;
final Map<LatLng, String> _stopTitles = {};

  LatLng? _currentLocation;
  LatLng? _liveLocation;

  final List<LatLng> _stops = [];
  final Set<Marker> _markers = {};
  final Set<Polyline> _polylines = {};
  

  String _distance = '';
  String _duration = '';
  bool _showSearchBar = false;

  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();


  bool _navigationStarted = false;
  int _currentStopIndex = 0;

  StreamSubscription<Position>? _positionStream;

  static const CameraPosition _initialCameraPosition = CameraPosition(
    target: LatLng(Env.defaultLat, Env.defaultLng),
    zoom: 13,
  );

  @override
  void initState() {
    super.initState();
    _placesService = PlacesService();
  }

  @override
  void dispose() {
    _positionStream?.cancel();
    super.dispose();
  }

  // ================= CURRENT LOCATION =================
  Future<void> _goToCurrentLocation() async {
    final pos = await Geolocator.getCurrentPosition(
      desiredAccuracy: LocationAccuracy.high,
    );

    _currentLocation = LatLng(pos.latitude, pos.longitude);

    _markers
      ..clear()
      ..add(
        Marker(
          markerId: const MarkerId('start'),
          position: _currentLocation!,
          icon: BitmapDescriptor.defaultMarkerWithHue(
            BitmapDescriptor.hueGreen,
          ),
        ),
      );

    await _mapController.animateCamera(
      CameraUpdate.newLatLngZoom(_currentLocation!, 15),
    );

    setState(() {});
  }

Future<void> _selectSuggestion(Place place) async {
  final latLng =
      await _placesService.getCoordinatesFromPlaceId(place.placeId);

  if (latLng != null) {
    _stops.add(latLng);

    // ✅ STORE TITLE HERE
    _stopTitles[latLng] = place.description;

    _rebuildMap();
    _mapController.animateCamera(CameraUpdate.newLatLngZoom(latLng, 15));
  }

  _placesService.resetSession();
  _searchController.clear();
  FocusScope.of(context).unfocus();

  setState(() {
    _showSearchBar = false;
  });
}




  // ================= ADD STOP =================
  void _addStop(LatLng point) {
    if (_navigationStarted) return;

    _stops.add(point);
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




  // ================= START RIDE =================
  void _startRide() {
    if (_stops.isEmpty || _currentLocation == null) return;

    setState(() {
      _navigationStarted = true;
      _currentStopIndex = 0;
    });

    _positionStream?.cancel();

    _positionStream = Geolocator.getPositionStream(
  locationSettings: const LocationSettings(
    accuracy: LocationAccuracy.bestForNavigation,
    distanceFilter: 5,
  ),
).listen((pos) async {
  _liveLocation = LatLng(pos.latitude, pos.longitude);
  _currentLocation = _liveLocation; // ✅ VERY IMPORTANT

  final destination = _stops[_currentStopIndex];

  // 🔄 update start marker
  setState(() {
    _markers.removeWhere((m) => m.markerId.value == 'start');
    _markers.add(
      Marker(
        markerId: const MarkerId('start'),
        position: _liveLocation!,
        icon: BitmapDescriptor.defaultMarkerWithHue(
          BitmapDescriptor.hueGreen,
        ),
      ),
    );
  });

  final distanceToStop = Geolocator.distanceBetween(
    _liveLocation!.latitude,
    _liveLocation!.longitude,
    destination.latitude,
    destination.longitude,
  );

  // ✅ ARRIVED
  if (distanceToStop < 30) {
    _polylines.removeWhere(
      (p) => p.polylineId.value == 'route_$_currentStopIndex',
    );

    if (_currentStopIndex < _stops.length - 1) {
      _currentStopIndex++;
    } else {
      _stopRide(completed: true);
      return;
    }
  }

  final route =
      await _placesService.getDirections(_liveLocation!, destination);

  if (route != null) {
    final points = _placesService.decodePolyline(
      route['overview_polyline']['points'],
    );

    setState(() {
      _polylines.removeWhere((p) => p.polylineId.value == 'live_route');

      _polylines.add(
        Polyline(
          polylineId: const PolylineId('live_route'),
          points: points,
          width: 6,
          color: Colors.blue,
        ),
      );

      _distance = route['legs'][0]['distance']['text'];
      _duration = route['legs'][0]['duration']['text'];
    });
  }

  _mapController.animateCamera(
    CameraUpdate.newCameraPosition(
      CameraPosition(
        target: _liveLocation!,
        zoom: 20,
        tilt: 45,
        bearing: pos.heading,
      ),
    ),
  );
});

  }

  // ================= STOP / EXIT =================
  Future<void> _stopRide({bool completed = false}) async {
    await _positionStream?.cancel();
    _positionStream = null;

    setState(() {
      _navigationStarted = false;
      _stops.clear();        
      _polylines.clear();    
      _distance = '';
      _duration = '';
    });

    if (_currentLocation != null) {
      await _mapController.animateCamera(
        CameraUpdate.newLatLngZoom(_currentLocation!, 18), 
      );
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(completed ? "Ride completed 🎉" : "Ride exited"),
      ),
    );

    _rebuildMap();
  }

  // ================= REBUILD MAP =================
   void _rebuildMap() async {
  if (_navigationStarted) return;

  _markers.removeWhere((m) => m.markerId.value != 'start');
  _polylines.clear();

  LatLng? origin = _currentLocation; 

  for (int i = 0; i < _stops.length; i++) {
    final LatLng stop = _stops[i];

    // 📍 MARKER
    _markers.add(
      Marker(
        markerId: MarkerId('stop_$i'),
        position: stop,
        infoWindow: InfoWindow(
          title: _stopTitles[stop] ?? 'Stop ${i + 1}',
        ),
      ),
    );

    // 🧭 ROUTE + ETA (FROM LAST PIN, NOT CURRENT LOCATION)
    if (origin != null) {
      final route = await _placesService.getDirections(origin, stop);

      if (route != null) {
        _polylines.add(
          Polyline(
            polylineId: PolylineId('route_$i'),
            points: _placesService.decodePolyline(
              route['overview_polyline']['points'],
            ),
            width: 5,
            color: Colors.blue,
          ),
        );

        // show total ETA to FINAL stop
        if (i == _stops.length - 1) {
          _distance = route['legs'][0]['distance']['text'];
          _duration = route['legs'][0]['duration']['text'];
        }
      }
    }

    origin = stop;
  }

  setState(() {});
}




  // ================= UI =================
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          GoogleMap(
            initialCameraPosition: _initialCameraPosition,
            markers: _markers,
            polylines: _polylines,
            myLocationEnabled: true,
            onMapCreated: (c) {
              _mapController = c;
              _goToCurrentLocation();
            },
            onTap: _addStop,
          ),
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

          // 🚗 BOTTOM CARD
          if (_stops.isNotEmpty || _navigationStarted)
            Positioned(
              bottom: 20,
              left: 16,
              right: 16,
              child: Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.15),
                      blurRadius: 10,
                    )
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (_duration.isNotEmpty)
                      Text(
                        _duration,
                        style: const TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    if (_distance.isNotEmpty)
                      Text(
                        _distance,
                        style: TextStyle(color: Colors.grey.shade700),
                      ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        if (!_navigationStarted)
                          Expanded(
                            child: ElevatedButton(
                              onPressed: _startRide,
                              child: const Text("Start"),
                            ),
                          ),
                        if (!_navigationStarted) ...[
                          const SizedBox(width: 8),
                          IconButton(
                            onPressed: _optimizeRoute,
                            icon: const Icon(Icons.route),
                          ),
                        ],
                        if (_navigationStarted)
                          Expanded(
                            child: OutlinedButton(
                              onPressed: () => _stopRide(),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: Colors.red,
                              ),
                              child: const Text("Exit"),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
