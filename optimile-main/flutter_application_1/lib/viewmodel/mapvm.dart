import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import '../services/places_service.dart';
import '../services/firestore_service.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import '../models/stop_model.dart';

class MapVM extends ChangeNotifier {
  // ================= SERVICES =================
  final PlacesService _placesService = PlacesService();
  PlacesService get placesService => _placesService;

  final FirestoreService firestoreService = FirestoreService();

  // ================= MAP =================
  GoogleMapController? mapController;
  LatLng? currentLocation;
  LatLng? _liveLocation;

  String? activeDeliveryId;

  Timer? _deviationTimer;
  Timer? _trafficTimer;
  bool _isReoptimizing = false;
  List<LatLng> _plannedRoutePoints = [];
  DateTime? _lastReoptTime;

  // ================= ROUTE =================
  List<Stop> stops = [];
  final Map<Stop, String> stopTitles = {};
  final Set<Marker> markers = {};
  final Set<Polyline> polylines = {};

  bool navigationStarted = false;
  String routeStatus = 'idle';
  String distance = '';
  String duration = '';
  int currentStopIndex = 0;

  StreamSubscription<Position>? positionStream;

  bool _showSearchBar = false;
  bool get showSearchBar => _showSearchBar;

  final TextEditingController searchController = TextEditingController();
  final FocusNode searchFocusNode = FocusNode();

  @override
  void dispose() {
    positionStream?.cancel();
    _deviationTimer?.cancel();
    _trafficTimer?.cancel();
    super.dispose();
  }

  // ================= SEARCH =================
  void openSearchBar() {
    _showSearchBar = true;
    notifyListeners();
    Future.delayed(const Duration(milliseconds: 100), () {
      FocusScope.of(searchFocusNode.context!).requestFocus(searchFocusNode);
    });
  }

  void closeSearchBar() {
    _showSearchBar = false;
    searchController.clear();
    notifyListeners();
    searchFocusNode.unfocus();
  }

  Future<List<Place>> getSuggestions(String query) {
    return _placesService.getSuggestions(query);
  }

  Future<void> selectSuggestion(Place place) async {
    final latLng =
        await _placesService.getCoordinatesFromPlaceId(place.placeId);

    if (latLng != null) {
      final stop = Stop(location: latLng, title: place.description);
      stops.add(stop);
      stopTitles[stop] = place.description;
      rebuildMap();
      mapController?.animateCamera(CameraUpdate.newLatLngZoom(latLng, 15));
    }

    _placesService.resetSession();
    closeSearchBar();
  }

  // ================= LOCATION =================
  Future<void> goToCurrentLocation() async {
    bool enabled = await Geolocator.isLocationServiceEnabled();
    if (!enabled) return;

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.deniedForever ||
        permission == LocationPermission.denied) return;

    final pos = await Geolocator.getCurrentPosition(
      desiredAccuracy: LocationAccuracy.high,
    );

    currentLocation = LatLng(pos.latitude, pos.longitude);

    markers
      ..clear()
      ..add(
        Marker(
          markerId: const MarkerId('start'),
          position: currentLocation!,
          icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen),
        ),
      );

    await mapController?.animateCamera(
      CameraUpdate.newLatLngZoom(currentLocation!, 15),
    );

    notifyListeners();
  }

  // ================= STOPS =================
  void addStop(LatLng point) {
    if (navigationStarted) return;
    final stop = Stop(location: point);
    stops.add(stop);
    rebuildMap();
  }

  void removeStop(int index) {
    if (navigationStarted) return;
    final stopToRemove = stops[index];
    stops.removeAt(index);
    stopTitles.remove(stopToRemove);
    rebuildMap();
  }

  // ================= OPTIMIZE =================
  Future<void> optimizeRoute(BuildContext context) async {
    if (stops.length < 2 || currentLocation == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Add at least two stops")),
      );
      return;
    }

    double initialTotalMinutes = 0;
    LatLng? origin = currentLocation;

    for (var stop in stops) {
      if (origin != null) {
        final route = await _placesService.getDirections(origin, stop.location);
        if (route != null) {
          final seconds = route["legs"][0]["duration"]["value"];
          initialTotalMinutes += seconds / 60.0;
        }
      }
      origin = stop.location;
    }

    final payload = {
      "stops": stops
          .map((s) => {"lat": s.location.latitude, "lng": s.location.longitude})
          .toList(),
      "vehicle": "Van",
      "traffic": "Medium",
      "weather": "Sunny"
    };

    try {
      final response = await http.post(
        Uri.parse("http://10.0.2.2:8000/optimize"),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode(payload),
      );

      final data = jsonDecode(response.body);
      final optimizedRoute = data["optimized_route"] as List<dynamic>;

      final List<Stop> newStops = optimizedRoute.map((s) {
        return Stop(
          location: LatLng(s["lat"], s["lng"]),
        );
      }).toList();

      double optimizedTotalMinutes = 0;
      origin = currentLocation;

      for (var stop in newStops) {
        if (origin != null) {
          final route =
              await _placesService.getDirections(origin, stop.location);
          if (route != null) {
            final seconds = route["legs"][0]["duration"]["value"];
            optimizedTotalMinutes += seconds / 60.0;
          }
        }
        origin = stop.location;
      }

      final saved =
          math.max(initialTotalMinutes - optimizedTotalMinutes, 0);

      stops
        ..clear()
        ..addAll(newStops);

      rebuildMap();

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            "Initial ETA: ${initialTotalMinutes.toStringAsFixed(1)} min\n"
            "Optimized ETA: ${optimizedTotalMinutes.toStringAsFixed(1)} min\n"
            "Saved: ${saved.toStringAsFixed(1)} min",
          ),
          duration: const Duration(seconds: 6),
        ),
      );

      await firestoreService.saveDeliveryToFirestore(
        initialTotalMinutes,
        optimizedTotalMinutes,
        stops,
      );
    } catch (e) {
      debugPrint("Optimization error: $e");
    }
  }

  // ================= REBUILD MAP =================
  Future<void> rebuildMap() async {
    markers.removeWhere((m) => m.markerId.value != 'start');
    polylines.clear();

    LatLng? origin = currentLocation;

    for (int i = 0; i < stops.length; i++) {
      final Stop stop = stops[i];

      markers.add(
        Marker(
          markerId: MarkerId('stop_$i'),
          position: stop.location,
          infoWindow: InfoWindow(
              title: stopTitles[stop] ?? stop.title ?? 'Stop ${i + 1}'),
        ),
      );

      if (origin != null) {
        final route =
            await _placesService.getDirections(origin, stop.location);
        if (route != null) {
          polylines.add(
            Polyline(
              polylineId: PolylineId('route_$i'),
              points: _placesService.decodePolyline(
                  route['overview_polyline']['points']),
              width: 5,
              color: Colors.blue,
            ),
          );

          if (i == stops.length - 1) {
            distance = route['legs'][0]['distance']['text'];
            duration = route['legs'][0]['duration']['text'];
          }
        }
      }

      origin = stop.location;
    }

    notifyListeners();
  }

  // ================= START RIDE =================
  Future<void> startRide(BuildContext context) async {
    if (stops.isEmpty || currentLocation == null) return;

    navigationStarted = true;
    routeStatus = 'active';
    currentStopIndex = 0;
    _plannedRoutePoints.clear();
    notifyListeners();

    positionStream?.cancel();

    positionStream = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 5,
      ),
    ).listen((pos) async {
      _liveLocation = LatLng(pos.latitude, pos.longitude);
      currentLocation = _liveLocation;

      final destination = stops[currentStopIndex].location;

      markers.removeWhere((m) => m.markerId.value == 'start');
      markers.add(
        Marker(
          markerId: const MarkerId('start'),
          position: _liveLocation!,
          icon:
              BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen),
        ),
      );

      final distanceToStop = Geolocator.distanceBetween(
        _liveLocation!.latitude,
        _liveLocation!.longitude,
        destination.latitude,
        destination.longitude,
      );

      if (distanceToStop < 30) {
        _plannedRoutePoints.clear();

        if (currentStopIndex < stops.length - 1) {
          currentStopIndex++;
        } else {
          await stopRide(context: context, completed: true);
          return;
        }
      }

      if (_plannedRoutePoints.isEmpty && !_isReoptimizing) {
        final route =
            await _placesService.getDirections(currentLocation!, destination);

        if (route != null) {
          final points = _placesService.decodePolyline(
              route['overview_polyline']['points']);

          _plannedRoutePoints = List.from(points);

          polylines.removeWhere(
              (p) => p.polylineId.value == 'live_route');
          polylines.add(
            Polyline(
              polylineId: const PolylineId('live_route'),
              points: points,
              width: 6,
              color: Colors.blue,
            ),
          );

          distance = route['legs'][0]['distance']['text'];
          duration = route['legs'][0]['duration']['text'];
          notifyListeners();
        }
      }

      mapController?.animateCamera(
        CameraUpdate.newCameraPosition(
          CameraPosition(
            target: _liveLocation!,
            zoom: 19,
            tilt: 45,
            bearing: pos.heading,
          ),
        ),
      );
    });

    startDeviationMonitor(context);
    startTrafficMonitor(context);
  }

  // ================= STOP =================

void clearRoute({bool keepCurrentLocationMarker = true}) {
  stops.clear();
  stopTitles.clear();
  polylines.clear();
  _plannedRoutePoints.clear();

  currentStopIndex = 0;
  navigationStarted = false;
  routeStatus = 'idle';
  distance = '';
  duration = '';

  markers.removeWhere((m) {
    if (keepCurrentLocationMarker) {
      return m.markerId.value != 'start';
    }
    return true;
  });

  notifyListeners();
}

  Future<void> stopRide(
      {bool completed = false, required BuildContext context}) async {
    await positionStream?.cancel();
    positionStream = null;


    await firestoreService.updateRouteStatusInFirestore(
      completed ? 'completed' : 'done',
    );

    clearRoute();

    if (currentLocation != null) {
      await mapController?.animateCamera(
        CameraUpdate.newLatLngZoom(currentLocation!, 18),
      );
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content:
            Text(completed ? "Route completed 🎉" : "Route marked as done"),
      ),
    );

    await rebuildMap();
  }

  // ================= MONITORS =================
  void startDeviationMonitor(BuildContext context) {
    _deviationTimer?.cancel();

    _deviationTimer =
        Timer.periodic(const Duration(seconds: 10), (_) async {
      if (!navigationStarted ||
          _plannedRoutePoints.isEmpty ||
          currentLocation == null ||
          _isReoptimizing) return;

      double minDist = double.infinity;

      for (final p in _plannedRoutePoints) {
        final d = Geolocator.distanceBetween(
          currentLocation!.latitude,
          currentLocation!.longitude,
          p.latitude,
          p.longitude,
        );
        if (d < minDist) minDist = d;
      }

      if (minDist > 40) {
        _isReoptimizing = true;

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("⚠ You are off route. Re-optimizing…"),
          ),
        );

        await reoptimizeRoute("deviation");
        _plannedRoutePoints.clear();
        _isReoptimizing = false;
      }
    });
  }

  void startTrafficMonitor(BuildContext context) {
    _trafficTimer?.cancel();

    _trafficTimer =
        Timer.periodic(const Duration(minutes: 1), (_) async {
      if (!navigationStarted ||
          currentLocation == null ||
          stops.isEmpty ||
          _isReoptimizing) return;

      if (_lastReoptTime != null) {
        final diff =
            DateTime.now().difference(_lastReoptTime!).inSeconds;
        if (diff < 90) return;
      }

      try {
        final route = await _placesService.getDirections(
          currentLocation!,
          stops.first.location,
        );

        if (route == null) return;

        final leg = route["legs"]?[0];
        final normal = leg?["duration"]?["value"];
        final traffic = leg?["duration_in_traffic"]?["value"];

        if (normal == null || traffic == null) return;

        final ratio = (traffic - normal) / normal;

        if (ratio > 0.30) {
          _isReoptimizing = true;
          _lastReoptTime = DateTime.now();

          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text("🚦 Heavy traffic detected. Re-optimizing..."),
            ),
          );

          await reoptimizeRoute("traffic");
          _isReoptimizing = false;
        }
      } catch (e) {
        debugPrint("❌ Traffic monitor error: $e");
        _isReoptimizing = false;
      }
    });
  }

  // ================= REOPTIMIZE =================
  Future<void> reoptimizeRoute(String reason) async {
    if (!navigationStarted || _isReoptimizing || stops.isEmpty) return;

    _lastReoptTime = DateTime.now();

    try {
      final payload = {
        "current_lat": currentLocation!.latitude,
        "current_lng": currentLocation!.longitude,
        "remaining_stops": stops
            .map((s) =>
                {"lat": s.location.latitude, "lng": s.location.longitude})
            .toList(),
        "vehicle": "Van",
        "traffic": "High",
        "weather": "Sunny",
        "reason": reason
      };

      final response = await http.post(
        Uri.parse("http://10.0.2.2:8000/reoptimize"),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode(payload),
      );

      final data = jsonDecode(response.body);
      final optimizedRoute = data["optimized_route"];

      final List<Stop> newStops = optimizedRoute.map<Stop>((s) {
        return Stop(
          location: LatLng(s["lat"], s["lng"]),
        );
      }).toList();

      stops
        ..clear()
        ..addAll(newStops);

      rebuildMap();
    } catch (e) {
      debugPrint("Re-optimization error: $e");
    }
  }

}
