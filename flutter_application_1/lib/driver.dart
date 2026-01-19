import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'map/env.dart';

/// ------------------ MERGED DIRECTIONS REPOSITORY + MODEL ------------------
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

class DirectionsRepository {
  final String apiKey;

  DirectionsRepository(this.apiKey);

  Future<Directions> getDirections({required LatLng origin, required LatLng destination}) async {
    final url =
        'https://maps.googleapis.com/maps/api/directions/json'
        '?origin=${origin.latitude},${origin.longitude}'
        '&destination=${destination.latitude},${destination.longitude}'
        '&key=$apiKey';

    final response = await http.get(Uri.parse(url));
    final data = json.decode(response.body);

    if (data['status'] != 'OK') throw Exception('Directions error: ${data['status']}');

    final route = data['routes'][0];
    final leg = route['legs'][0];
    final distance = leg['distance']['text'];
    final duration = leg['duration']['text'];

    final polyline = _decodePolyline(route['overview_polyline']['points']);

    return Directions(
      polylinePoints: polyline,
      totalDistance: distance,
      totalDuration: duration,
    );
  }

  Future<LatLng?> getCoordinates(String address) async {
    final url =
        'https://maps.googleapis.com/maps/api/geocode/json'
        '?address=${Uri.encodeComponent(address)}'
        '&key=$apiKey';

    final response = await http.get(Uri.parse(url));
    final data = json.decode(response.body);

    if (data['results'].isEmpty) return null;

    final loc = data['results'][0]['geometry']['location'];
    return LatLng(loc['lat'], loc['lng']);
  }

  List<LatLng> _decodePolyline(String encoded) {
    List<LatLng> poly = [];
    int index = 0, lat = 0, lng = 0;

    while (index < encoded.length) {
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

/// ------------------ MAP SCREEN ------------------
class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  late GoogleMapController _mapController;
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  late DirectionsRepository directionsRepo;

  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();

  LatLng? _currentLocation;
  final List<LatLng> _stops = [];

  final Set<Marker> _markers = {};
  final Set<Polyline> _polylines = {};

  String _distance = '';
  String _duration = '';
  bool _showSearchBar = false;

  static final CameraPosition _initialCameraPosition = CameraPosition(
    target: LatLng(Env.defaultLat, Env.defaultLng),
    zoom: 13,
  );

  @override
  void initState() {
    super.initState();
    directionsRepo = DirectionsRepository(Env.googleMapsApiKey);
  }

  /// ------------------ CURRENT LOCATION ------------------
  Future<void> _goToCurrentLocation() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) return;

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) permission = await Geolocator.requestPermission();
    if (permission == LocationPermission.deniedForever || permission == LocationPermission.denied) return;

    final position = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);
    final latLng = LatLng(position.latitude, position.longitude);

    setState(() {
      _currentLocation = latLng;
      _markers.clear();
      _markers.add(Marker(
        markerId: const MarkerId('start'),
        position: latLng,
        infoWindow: const InfoWindow(title: 'Start'),
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen),
      ));
    });

    _mapController.animateCamera(CameraUpdate.newLatLngZoom(latLng, 15));
    _rebuildMap();
  }

  /// ------------------ ADD / REMOVE STOPS ------------------
  void _addStop(LatLng point) {
    _stops.add(point);
    _rebuildMap();
  }

  void _removeStop(int index) {
    _stops.removeAt(index);
    _rebuildMap();
  }

  /// ------------------ REBUILD MAP ------------------
  Future<void> _rebuildMap() async {
    _markers.removeWhere((m) => m.markerId.value != 'start');
    _polylines.clear();
    _distance = '';
    _duration = '';

    for (int i = 0; i < _stops.length; i++) {
      _markers.add(Marker(markerId: MarkerId('stop_$i'), position: _stops[i]));
    }

    LatLng? origin = _currentLocation;
    for (int i = 0; i < _stops.length; i++) {
      if (origin == null) break;
      try {
        final directions = await directionsRepo.getDirections(origin: origin, destination: _stops[i]);
        _polylines.add(Polyline(
          polylineId: PolylineId('route_$i'),
          points: directions.polylinePoints,
          color: Colors.blue,
          width: 5,
        ));
        _distance = directions.totalDistance;
        _duration = directions.totalDuration;
      } catch (e) {
        print('Error fetching directions: $e');
      }
      origin = _stops[i];
    }

    setState(() {});
  }

  /// ------------------ SEARCH ------------------
  void _searchAndAddStop() async {
    final query = _searchController.text.trim();
    if (query.isEmpty) return;

    FocusScope.of(context).unfocus();

    final latLng = await directionsRepo.getCoordinates(query);
    if (latLng != null) {
      _addStop(latLng);
      _mapController.animateCamera(CameraUpdate.newLatLngZoom(latLng, 14));
    }

    setState(() => _showSearchBar = false);
  }

  void _clearAll() {
    _stops.clear();
    _polylines.clear();
    _markers.removeWhere((m) => m.markerId.value != 'start');
    _distance = '';
    _duration = '';
    setState(() {});
  }

  /// ------------------ UI ------------------
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: _scaffoldKey,
      endDrawer: Drawer(
        child: Container(
          color: Colors.black,
          child: Column(
            children: [
              const DrawerHeader(
                child: Text('Stops', style: TextStyle(fontSize: 24, color: Colors.white)),
              ),
              Expanded(
                child: ListView.builder(
                  itemCount: _stops.length,
                  itemBuilder: (context, index) {
                    final stop = _stops[index];
                    return ListTile(
                      leading: const Text('•', style: TextStyle(fontSize: 24, color: Colors.white)),
                      title: Text(
                        'Stop ${index + 1}: ${stop.latitude.toStringAsFixed(4)}, ${stop.longitude.toStringAsFixed(4)}',
                        style: const TextStyle(color: Colors.white),
                      ),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete, color: Colors.red),
                        onPressed: () => _removeStop(index),
                      ),
                    );
                  },
                ),
              ),
            ],
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
            myLocationButtonEnabled: false,
            onMapCreated: (c) => _mapController = c,
            onTap: _addStop,
          ),
          // ---------------- SEARCH BAR / ICON ----------------
          Positioned(
            top: 10 + MediaQuery.of(context).padding.top + 10,
            left: 15,
            right: 15,
            child: Row(
              children: [
                if (_showSearchBar)
                  Expanded(
                    child: TextField(
                      focusNode: _searchFocusNode,
                      controller: _searchController,
                      decoration: InputDecoration(
                        hintText: 'Search location',
                        filled: true,
                        fillColor: Colors.white,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                    ),
                  ),
                if (_showSearchBar) const SizedBox(width: 8),
                if (_showSearchBar)
                  ElevatedButton(
                    onPressed: _searchAndAddStop,
                    child: const Text('Go'),
                  ),
                IconButton(
                  icon: const Icon(Icons.search, color: Colors.black),
                  onPressed: () {
                    setState(() {
                      _showSearchBar = !_showSearchBar;
                      if (_showSearchBar) _searchFocusNode.requestFocus();
                    });
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.menu, color: Colors.black),
                  onPressed: () => _scaffoldKey.currentState?.openEndDrawer(),
                ),
              ],
            ),
          ),
          if (_distance.isNotEmpty)
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
      floatingActionButton: FloatingActionButton(
        child: const Icon(Icons.my_location),
        onPressed: _goToCurrentLocation,
      ),
    );
  }
}
