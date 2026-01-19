import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_typeahead/flutter_typeahead.dart';

import 'map/places_service.dart';
import 'map/env.dart';

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

  // ================= REBUILD MAP =================
  void _rebuildMap() async {
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
      floatingActionButton: FloatingActionButton(
        onPressed: _goToCurrentLocation,
        child: const Icon(Icons.my_location),
      ),
    );
  }
}
