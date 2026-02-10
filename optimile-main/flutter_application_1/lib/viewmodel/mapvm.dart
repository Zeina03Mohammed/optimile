import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import '../env.dart';
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
String vehicleType = "van";
bool isFragile = false;
  /// When true, backend uses Bellman–Ford on the chosen locations (and current position).
  bool useBellmanFord = true;
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

  // ================= ROUTE (multi-route = multiple cars) =================
  List<RouteModel> _routes = [
    RouteModel(id: '1', name: 'Car 1', color: kRouteColors[0]),
  ];
  int _selectedRouteIndex = 0;
  /// When navigation is started, this is the route we're actually driving.
  int _activeRouteIndex = 0;

  List<RouteModel> get routes => _routes;
  int get selectedRouteIndex => _selectedRouteIndex;
  int get activeRouteIndex => _activeRouteIndex;

  /// Stops of the route currently selected for editing (or active when navigating).
  List<Stop> get currentStops =>
      _routes[_selectedRouteIndex].stops;
  /// When navigating: active route's stops. Otherwise: selected route's stops (for backward compat).
  List<Stop> get stops =>
      navigationStarted ? _routes[_activeRouteIndex].stops : currentStops;

  bool get hasAnyStops => _routes.any((r) => r.stops.isNotEmpty);

  bool get canStart =>
      currentLocation != null && _routes.any((r) => r.stops.length >= 2);

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


void setVehicleType(String value) {
  vehicleType = value.toLowerCase();
  notifyListeners();
}

void setFragile(bool value) {
  isFragile = value;
  notifyListeners();
}

void setUseBellmanFord(bool value) {
  useBellmanFord = value;
  notifyListeners();
}
  Future<List<Place>> getSuggestions(String query) {
    return _placesService.getSuggestions(query);
  }

  Future<void> selectSuggestion(Place place) async {
    final latLng =
        await _placesService.getCoordinatesFromPlaceId(place.placeId);

    if (latLng != null) {
      final stop = Stop(location: latLng, title: place.description);
      _routes[_selectedRouteIndex].stops.add(stop);
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
        permission == LocationPermission.denied) {
      return;
    }

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
void addStop(
  LatLng point, {
  bool isFragile = false,
  TimeOfDay? startTime,
  TimeOfDay? endTime,
}) {
  if (navigationStarted) return;

  // Reject deadlines that are already in the past (same-day check)
  final now = TimeOfDay.now();
  final nowMinutes = now.hour * 60 + now.minute;

  if (endTime != null) {
    final endMinutes = endTime.hour * 60 + endTime.minute;
    if (endMinutes < nowMinutes) {
      debugPrint("Rejected stop: deadline already in the past.");
      return;
    }
  }

  final int windowStartMin = startTime != null
      ? startTime.hour * 60 + startTime.minute
      : 0; // open from midnight

  final int windowEndMin = endTime != null
      ? endTime.hour * 60 + endTime.minute
      : 24 * 60; // open until end of day

  final stop = Stop(
    location: point,
    isFragile: isFragile,
    // keep estimated/actual for analytics, but windows drive optimization
    estimatedTime: startTime != null
        ? startTime.hour * 60 + startTime.minute.toDouble()
        : null,
    actualTime: endTime != null
        ? endTime.hour * 60 + endTime.minute.toDouble()
        : null,
    windowStartMin: windowStartMin,
    windowEndMin: windowEndMin,
  );

  _routes[_selectedRouteIndex].stops.add(stop);
  rebuildMap();
}

  void removeStop(int index) {
    if (navigationStarted) return;
    final route = _routes[_selectedRouteIndex];
    if (index >= route.stops.length) return;
    final stopToRemove = route.stops[index];
    route.stops.removeAt(index);
    stopTitles.remove(stopToRemove);
    rebuildMap();
  }

  void addRoute() {
    if (navigationStarted) return;
    final nextId = '${_routes.length + 1}';
    final color = kRouteColors[_routes.length % kRouteColors.length];
    _routes.add(RouteModel(
      id: nextId,
      name: 'Car ${_routes.length + 1}',
      color: color,
    ));
    _selectedRouteIndex = _routes.length - 1;
    notifyListeners();
  }

  void removeRoute(int index) {
    if (navigationStarted) return;
    if (_routes.length <= 1) return;
    for (final s in _routes[index].stops) stopTitles.remove(s);
    _routes.removeAt(index);
    if (_selectedRouteIndex >= _routes.length) _selectedRouteIndex = _routes.length - 1;
    if (_activeRouteIndex >= _routes.length) _activeRouteIndex = _routes.length - 1;
    rebuildMap();
  }

  void setSelectedRoute(int index) {
    if (index >= 0 && index < _routes.length) {
      _selectedRouteIndex = index;
      notifyListeners();
    }
  }

  // ================= OPTIMIZE =================
  Future<void> optimizeRoute(BuildContext context) async {
  if (currentLocation == null) return;
  final routesToOptimize = <int>[];
  for (int i = 0; i < _routes.length; i++) {
    if (_routes[i].stops.length >= 2) routesToOptimize.add(i);
  }
  if (routesToOptimize.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("Add at least two stops to a route")),
    );
    return;
  }

  final now = TimeOfDay.now();
  final startMinutes = now.hour * 60 + now.minute;
  int optimizedCount = 0;

  try {
    for (final routeIndex in routesToOptimize) {
      final route = _routes[routeIndex];
      final routeStops = route.stops;

      double initialEta = 0;
      LatLng origin = currentLocation!;
      for (final stop in routeStops) {
        final r = await _placesService.getDirections(origin, stop.location);
        if (r == null) continue;
        initialEta += r["legs"][0]["duration"]["value"] / 60.0;
        origin = stop.location;
      }

      final List<Stop> originalStops = List.from(routeStops);
      final payload = {
        "stops": routeStops.map((s) => s.toPayload()).toList(),
        "vehicle": vehicleType,
        "traffic": "Medium",
        "weather": "Sunny",
        "start_time": startMinutes,
        "use_bellman_ford": false,
      };

      final response = await http.post(
        Uri.parse("${Env.backendBaseUrl}/optimize"),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode(payload),
      );

      if (response.statusCode != 200) continue;

      final body = jsonDecode(response.body) as Map<String, dynamic>;
      final optimizedStops =
          (body["optimized_route"] as List)
              .map<Stop>((s) {
        final int windowStart = (s["window_start"] as int?) ?? 0;
        final int windowEnd = (s["window_end"] as int?) ?? 24 * 60;
        return Stop(
          location: LatLng(s["lat"], s["lng"]),
          isFragile: s["is_fragile"] ?? false,
          windowStartMin: windowStart,
          windowEndMin: windowEnd,
          estimatedTime: windowStart.toDouble(),
          actualTime: windowEnd.toDouble(),
        );
      }).toList();

      double optimizedEta = 0;
      origin = currentLocation!;
      for (final stop in optimizedStops) {
        final r = await _placesService.getDirections(origin, stop.location);
        if (r == null) break;
        optimizedEta += r["legs"][0]["duration"]["value"] / 60.0;
        origin = stop.location;
      }

      final improvement = initialEta - optimizedEta;
      if (improvement > 0.5) {
        route.stops
          ..clear()
          ..addAll(optimizedStops);
        optimizedCount++;
      }
    }

    await rebuildMap();

    if (context.mounted) {
      if (optimizedCount > 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              optimizedCount == routesToOptimize.length
                  ? "All $optimizedCount route(s) optimized"
                  : "$optimizedCount of ${routesToOptimize.length} route(s) optimized",
            ),
            duration: const Duration(seconds: 3),
          ),
        );
        if (optimizedCount == 1) {
          final idx = routesToOptimize.first;
          await firestoreService.saveDeliveryToFirestore(
            0,
            0,
            _routes[idx].stops,
          );
        }
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Routes already near-optimal")),
        );
      }
    }
  } catch (e) {
    debugPrint("Optimization error: $e");
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Optimization failed: $e")),
      );
    }
  }
}
  // ================= REBUILD MAP =================
  Future<void> rebuildMap() async {
  markers.removeWhere((m) => m.markerId.value != 'start');
  polylines.clear();

  if (currentLocation == null) return;

  double totalSeconds = 0;
  double totalMeters = 0;

  for (int r = 0; r < _routes.length; r++) {
    final routeModel = _routes[r];
    final routeStops = routeModel.stops;
    if (routeStops.isEmpty) continue;

    LatLng origin = currentLocation!;
    for (int i = 0; i < routeStops.length; i++) {
      final stop = routeStops[i];
      markers.add(
        Marker(
          markerId: MarkerId('stop_r${r}_s$i'),
          position: stop.location,
          infoWindow: InfoWindow(
            title: stopTitles[stop] ?? '${routeModel.name} Stop ${i + 1}',
          ),
          icon: BitmapDescriptor.defaultMarkerWithHue(
            HSVColor.fromColor(routeModel.color).hue,
          ),
        ),
      );

      final route = await _placesService.getDirections(origin, stop.location);
      if (route == null) continue;

      final leg = route["legs"][0];
      totalSeconds += leg["duration"]["value"];
      totalMeters += leg["distance"]["value"];

      polylines.add(
        Polyline(
          polylineId: PolylineId('poly_r${r}_s$i'),
          points: _placesService.decodePolyline(
            route["overview_polyline"]["points"],
          ),
          width: 5,
          color: routeModel.color,
        ),
      );

      origin = stop.location;
    }
  }

  distance = "${(totalMeters / 1000).toStringAsFixed(1)} km";
  duration = "${(totalSeconds / 60).round()} min";

  notifyListeners();
  }
  // ================= START RIDE =================
  Future<void> startRide(BuildContext context) async {
    if (currentLocation == null) return;
    int firstWithStops = -1;
    for (int i = 0; i < _routes.length; i++) {
      if (_routes[i].stops.isNotEmpty) {
        firstWithStops = i;
        break;
      }
    }
    if (firstWithStops < 0) return;

    _activeRouteIndex = firstWithStops;
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
  for (final r in _routes) {
    for (final s in r.stops) stopTitles.remove(s);
    r.stops.clear();
  }
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

  /// Simulate traffic: run ALNS and ALNS+Bellman–Ford on the same route/incident, then apply the better result.
  Future<void> simulateTraffic(BuildContext context) async {
    if (!navigationStarted || stops.isEmpty) return;

    _isReoptimizing = true;
    _lastReoptTime = DateTime.now();

    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("🔧 Simulating: ALNS vs ALNS+BF on same incident…")),
      );
    }

    final payload = {
      "current_lat": currentLocation!.latitude,
      "current_lng": currentLocation!.longitude,
      "remaining_stops":
          stops.skip(currentStopIndex).map((s) => s.toPayload()).toList(),
      "vehicle": vehicleType,
      "traffic": "Heavy",
      "weather": "Sunny",
      "reason": "traffic_jam",
      "severity": 0.5,
      "simulate": true,
      "google_maps_api_key": Env.googleMapsApiKey,
    };

    try {
      // 1) ALNS
      final payloadAlns = {...payload, "use_bellman_ford": false};
      final responseAlns = await http
          .post(
            Uri.parse("${Env.backendBaseUrl}/reoptimize"),
            headers: {"Content-Type": "application/json"},
            body: jsonEncode(payloadAlns),
          )
          .timeout(const Duration(seconds: 12));

      // 2) ALNS + Bellman–Ford
      final payloadBf = {...payload, "use_bellman_ford": true};
      final responseBf = await http
          .post(
            Uri.parse("${Env.backendBaseUrl}/reoptimize"),
            headers: {"Content-Type": "application/json"},
            body: jsonEncode(payloadBf),
          )
          .timeout(const Duration(seconds: 12));

      double? etaAlns;
      List<Stop>? routeAlns;
      if (responseAlns.statusCode == 200) {
        final body = jsonDecode(responseAlns.body) as Map<String, dynamic>;
        if (body["rerouted"] == true && body["optimized_route"] != null) {
          routeAlns = _parseOptimizedRoute(body["optimized_route"] as List);
          etaAlns = await _measureEtaFromStops(routeAlns!);
        }
      }

      double? etaBf;
      List<Stop>? routeBf;
      if (responseBf.statusCode == 200) {
        final body = jsonDecode(responseBf.body) as Map<String, dynamic>;
        if (body["rerouted"] == true && body["optimized_route"] != null) {
          routeBf = _parseOptimizedRoute(body["optimized_route"] as List);
          etaBf = await _measureEtaFromStops(routeBf!);
        }
      }

      // Baseline ETA (current route)
      double before = 0;
      LatLng origin = currentLocation!;
      for (final stop in stops) {
        final route = await _placesService.getDirections(origin, stop.location);
        if (route == null) break;
        before += route["legs"][0]["duration"]["value"] / 60.0;
        origin = stop.location;
      }

      // Apply the better of the two (or the only one we got)
      List<Stop>? toApply;
      String message;
      if (routeAlns != null && routeBf != null && etaAlns != null && etaBf != null) {
        if (etaAlns <= etaBf) {
          toApply = routeAlns;
          message = "Simulate: ALNS ${etaAlns.toStringAsFixed(1)} min, ALNS+BF ${etaBf.toStringAsFixed(1)} min — applied ALNS";
        } else {
          toApply = routeBf;
          message = "Simulate: ALNS ${etaAlns.toStringAsFixed(1)} min, ALNS+BF ${etaBf.toStringAsFixed(1)} min — applied ALNS+BF";
        }
      } else if (routeAlns != null && etaAlns != null) {
        toApply = routeAlns;
        message = "Simulate: ALNS ${etaAlns.toStringAsFixed(1)} min (ALNS+BF unavailable)";
      } else if (routeBf != null && etaBf != null) {
        toApply = routeBf;
        message = "Simulate: ALNS+BF ${etaBf.toStringAsFixed(1)} min (ALNS unavailable)";
      } else {
        message = "Simulate: no reroute from backend";
      }

      if (toApply != null) {
        final after = toApply == routeAlns ? (etaAlns ?? 0) : (etaBf ?? 0);
        stops
          ..clear()
          ..addAll(toApply);
        await rebuildMap();
        if (context.mounted) {
          final extra = after < before
              ? " (${(before - after).toStringAsFixed(1)} min faster)"
              : " — no improvement over current route";
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text("$message$extra"), duration: const Duration(seconds: 4)),
          );
        }
      } else if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
        );
      }
    } catch (e) {
      debugPrint("Simulate error: $e");
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Simulate failed: $e")),
        );
      }
    } finally {
      _isReoptimizing = false;
    }
  }

  static List<Stop> _parseOptimizedRoute(List list) {
    return list.map<Stop>((s) {
      final m = s as Map<String, dynamic>;
      final int windowStart = (m["window_start"] as int?) ?? 0;
      final int windowEnd = (m["window_end"] as int?) ?? 24 * 60;
      return Stop(
        location: LatLng(m["lat"], m["lng"]),
        isFragile: m["is_fragile"] ?? false,
        windowStartMin: windowStart,
        windowEndMin: windowEnd,
        estimatedTime: windowStart.toDouble(),
        actualTime: windowEnd.toDouble(),
      );
    }).toList();
  }

  Future<double?> _measureEtaFromStops(List<Stop> stopList) async {
    if (currentLocation == null) return null;
    double eta = 0;
    LatLng origin = currentLocation!;
    for (final stop in stopList) {
      final route = await _placesService.getDirections(origin, stop.location);
      if (route == null) return null;
      eta += route["legs"][0]["duration"]["value"] / 60.0;
      origin = stop.location;
    }
    return eta;
  }

  /// Offline demo: reroute remaining stops locally (for committee when backend unreachable).
  Future<void> _runOfflineDemoReroute(BuildContext context) async {
    if (stops.length < 2 || currentStopIndex >= stops.length - 1) return;
    final remaining = stops.skip(currentStopIndex).toList();
    if (remaining.length < 2) return;
    // Swap first two remaining stops to simulate ALNS reordering
    final reordered = [
      remaining[1],
      remaining[0],
      ...remaining.skip(2),
    ];
    stops
      ..removeRange(currentStopIndex, stops.length)
      ..addAll(reordered);
    await rebuildMap();
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("✓ Demo: Route adapted (incident simulated, offline)"),
          duration: Duration(seconds: 4),
        ),
      );
    }
  }

  // ================= MONITORS =================
void startDeviationMonitor(BuildContext context) {
  _deviationTimer?.cancel();

  _deviationTimer = Timer.periodic(
    const Duration(seconds: 10),
    (_) async {
      if (!navigationStarted ||
          _plannedRoutePoints.isEmpty ||
          currentLocation == null ||
          _isReoptimizing) {
        return;
      }

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

      // 40m off the planned polyline = real deviation
      if (minDist > 40) {
        _isReoptimizing = true;
        _lastReoptTime = DateTime.now();

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("⚠ Off route detected. Re-optimizing…"),
          ),
        );

        await reoptimizeRoute(
          context: context,
          reason: "deviation",
          severity: 1.0, // full severity — route is invalid
          affectedStopIndex: currentStopIndex,
        );

        _plannedRoutePoints.clear();
        _isReoptimizing = false;
      }
    },
  );
}

void startTrafficMonitor(BuildContext context) {
  _trafficTimer?.cancel();

  _trafficTimer = Timer.periodic(
    const Duration(seconds: 45),
    (_) async {
      if (!navigationStarted ||
          currentLocation == null ||
          stops.isEmpty ||
          _isReoptimizing) {
        return;
      }

      // Prevent rapid re-optimizations
      if (_lastReoptTime != null) {
        final diff =
            DateTime.now().difference(_lastReoptTime!).inSeconds;
        if (diff < 60) return;
      }

      try {
        final route = await _placesService.getDirections(
          currentLocation!,
          stops[currentStopIndex].location,
        );

        if (route == null) return;

        final leg = route["legs"]?[0];
        final normal = leg?["duration"]?["value"];
        final traffic = leg?["duration_in_traffic"]?["value"];

        if (normal == null) return;
        final trafficVal = traffic ?? normal;
        final ratio = (trafficVal - normal) / normal;

        if (ratio > 0.15) {
          _isReoptimizing = true;
          _lastReoptTime = DateTime.now();

          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text("🚦 Heavy traffic detected. Re-optimizing..."),
            ),
          );

          await reoptimizeRoute(
            context: context,
            reason: "traffic_jam",
            severity: ratio,
            affectedStopIndex: currentStopIndex,
          );
        }
      } catch (e) {
        debugPrint("❌ Traffic monitor error: $e");
      } finally {
        _isReoptimizing = false;
      }
    },
  );
}
// ================= REOPTIMIZE =================
/// Returns true if reroute succeeded (backend + ETA improved), false otherwise.
/// [useBellmanFord] when true uses ALNS + Bellman–Ford reoptimize.
Future<bool> reoptimizeRoute({
  BuildContext? context,
  required String reason,
  required double severity,
  required int affectedStopIndex,
  bool useBellmanFord = false,
}) async {
  if (!navigationStarted || _isReoptimizing || stops.isEmpty) return false;

  _isReoptimizing = true;
  _lastReoptTime = DateTime.now();

  try {
    // ---------- BASELINE ETA ----------
    double before = 0;
    LatLng origin = currentLocation!;

    for (final stop in stops) {
      final route = await _placesService.getDirections(origin, stop.location);
      if (route == null) return false;
      before += route["legs"][0]["duration"]["value"] / 60.0;
      origin = stop.location;
    }
    final payload = {
      "current_lat": currentLocation!.latitude,
      "current_lng": currentLocation!.longitude,
      "remaining_stops":
          stops.skip(currentStopIndex).map((s) => s.toPayload()).toList(),
      "vehicle": vehicleType,
      "traffic": "Heavy",
      "weather": "Sunny",
      "reason": reason,
      "severity": severity,
      "use_bellman_ford": useBellmanFord,
      if (useBellmanFord) "google_maps_api_key": Env.googleMapsApiKey,
    };

    final response = await http
        .post(
          Uri.parse("${Env.backendBaseUrl}/reoptimize"),
          headers: {"Content-Type": "application/json"},
          body: jsonEncode(payload),
        )
        .timeout(const Duration(seconds: 8));

    if (response.statusCode != 200) {
      if (context != null && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Backend error ${response.statusCode}")),
        );
      }
      return false;
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    if (body["rerouted"] != true) {
      if (context != null && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Reroute skipped (no improvement)")),
        );
      }
      return false;
    }

    final optimizedStops =
        (body["optimized_route"] as List)
            .map<Stop>((s) {
      final int windowStart = (s["window_start"] as int?) ?? 0;
      final int windowEnd = (s["window_end"] as int?) ?? 24 * 60;

      return Stop(
        location: LatLng(s["lat"], s["lng"]),
        isFragile: s["is_fragile"] ?? false,
        windowStartMin: windowStart,
        windowEndMin: windowEnd,
        estimatedTime: windowStart.toDouble(),
        actualTime: windowEnd.toDouble(),
      );
    }).toList();

    // ---------- NEW ETA ----------
    double after = 0;
    origin = currentLocation!;

    for (final stop in optimizedStops) {
      final route = await _placesService.getDirections(origin, stop.location);
      if (route == null) return false;
      after += route["legs"][0]["duration"]["value"] / 60.0;
      origin = stop.location;
    }

    final delta = before - after;
    final percent = (delta / before) * 100;

    final algo = useBellmanFord ? "ALNS+Bellman–Ford" : "ALNS";
    debugPrint(
        "$algo /reoptimize reason=$reason "
        "baseline=${before.toStringAsFixed(2)} min, "
        "optimized=${after.toStringAsFixed(2)} min, "
        "improvement=${delta.toStringAsFixed(2)} min "
        "(${percent.toStringAsFixed(1)}%)");

    if (after >= before) {
      _isReoptimizing = false;
      if (context != null && context.mounted) {
        final algoLabel = useBellmanFord ? "ALNS+Bellman–Ford" : "ALNS";
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("$algoLabel: route unchanged (same ETA – already optimal)"),
            duration: const Duration(seconds: 3),
          ),
        );
      }
      return false; // no improvement
    }

    final liveIncidentsFound = body["live_incidents_found"] == true;
    final incidentKind = body["incident_kind"] as String? ?? reason;
    if (context != null && context.mounted) {
      if (liveIncidentsFound) {
        final kindLabel = incidentKind == "road_closed"
            ? "Road closed"
            : incidentKind == "accident"
                ? "Accident"
                : "Traffic incident";
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("⚠ $kindLabel ahead (TomTom). Rerouting to avoid."),
            duration: const Duration(seconds: 5),
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("✓ Route updated (${percent.toStringAsFixed(0)}% faster)"),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    }

    stops
      ..clear()
      ..addAll(optimizedStops);

    await rebuildMap();
    return true;
  } catch (e, st) {
    debugPrint("Reoptimization error: $e\n$st");
    if (context != null && context.mounted) {
      final msg = e.toString().contains("Connection refused")
          ? "Backend not running. Start server (uvicorn) on port 8000 or check Env.backendBaseUrl."
          : "Backend unreachable. Use offline demo.";
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), duration: const Duration(seconds: 4)),
      );
    }
    return false;
  } finally {
    _isReoptimizing = false;
  }
}
Future<StopConfig?> showStopConfigDialog(BuildContext context) async {
  bool isFragile = false;
  TimeOfDay? start;
  TimeOfDay? end;

  return showDialog<StopConfig>(
    context: context,
    builder: (_) {
      return StatefulBuilder(
        builder: (context, setState) {
          return AlertDialog(
            title: const Text("Stop Configuration"),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SwitchListTile(
                  title: const Text("Fragile package"),
                  value: isFragile,
                  onChanged: (v) => setState(() => isFragile = v),
                ),

                const SizedBox(height: 8),

                ListTile(
                  title: Text(
                    start == null
                        ? "Select start time"
                        : "Start: ${start!.format(context)}",
                  ),
                  onTap: () async {
                    final t = await showTimePicker(
                      context: context,
                      initialTime: const TimeOfDay(hour: 8, minute: 0),
                    );
                    if (t != null) setState(() => start = t);
                  },
                ),

                ListTile(
                  title: Text(
                    end == null
                        ? "Select end time"
                        : "End: ${end!.format(context)}",
                  ),
                  onTap: () async {
                    final t = await showTimePicker(
                      context: context,
                      initialTime: const TimeOfDay(hour: 12, minute: 0),
                    );
                    if (t != null) setState(() => end = t);
                  },
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, null),
                child: const Text("Cancel"),
              ),
              ElevatedButton(
                onPressed: () {
                  Navigator.pop(
                    context,
                    StopConfig(
                      isFragile: isFragile,
                      start: start,
                      end: end,
                    ),
                  );
                },
                child: const Text("Add Stop"),
              ),
            ],
          );
        },
      );
    },
  );
}
}
