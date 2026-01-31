import 'dart:async';
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
String vehicleType = "van";
bool isFragile = false;
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


void setVehicleType(String value) {
  vehicleType = value.toLowerCase();
  notifyListeners();
}

void setFragile(bool value) {
  isFragile = value;
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

  // ---------- BASELINE ETA (Google Maps) ----------
  double initialEta = 0;
  LatLng origin = currentLocation!;

  for (final stop in stops) {
    final route = await _placesService.getDirections(origin, stop.location);
    if (route == null) return;
    initialEta += route["legs"][0]["duration"]["value"] / 60.0;
    origin = stop.location;
  }

  // Keep original order SAFE
  final List<Stop> originalStops = List.from(stops);

  // ---------- BACKEND CALL ----------
  final now = TimeOfDay.now();
  final startMinutes = now.hour * 60 + now.minute;

  final payload = {
    "stops": stops.map((s) => s.toPayload()).toList(),
    "vehicle": vehicleType, // motorcycle | scooter | van
    "traffic": "Medium",
    "weather": "Sunny",
    "start_time": startMinutes, // minutes since midnight
  };

  try {
    final response = await http.post(
      Uri.parse("http://10.0.2.2:8000/optimize"),
      headers: {"Content-Type": "application/json"},
      body: jsonEncode(payload),
    );

    if (response.statusCode != 200) {
      throw Exception("Backend error");
    }

    final optimizedStops =
        (jsonDecode(response.body)["optimized_route"] as List)
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

    // ---------- OPTIMIZED ETA ----------
    double optimizedEta = 0;
    origin = currentLocation!;

    for (final stop in optimizedStops) {
      final route = await _placesService.getDirections(origin, stop.location);
      if (route == null) return;
      optimizedEta += route["legs"][0]["duration"]["value"] / 60.0;
      origin = stop.location;
    }

    // ---------- VALIDATION ----------
    final improvement = initialEta - optimizedEta;
    final percent = (improvement / initialEta) * 100;

    debugPrint(
        "ALNS /optimize baseline=${initialEta.toStringAsFixed(2)} min, "
        "optimized=${optimizedEta.toStringAsFixed(2)} min, "
        "improvement=${improvement.toStringAsFixed(2)} min "
        "(${percent.toStringAsFixed(1)}%)");

    if (improvement <= 0.5) {
      // Reject bad optimization
      stops
        ..clear()
        ..addAll(originalStops);
      rebuildMap();

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Route already near-optimal")),
      );
      return;
    }

    // ---------- ACCEPT OPTIMIZATION ----------
    stops
      ..clear()
      ..addAll(optimizedStops);

    await rebuildMap();

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          "Improvement: ${percent.toStringAsFixed(1)}%",
        ),
        duration: const Duration(seconds: 6),
      ),
    );

    await firestoreService.saveDeliveryToFirestore(
      initialEta,
      optimizedEta,
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

  if (currentLocation == null) return;

  LatLng origin = currentLocation!;
  double totalSeconds = 0;
  double totalMeters = 0;

  for (int i = 0; i < stops.length; i++) {
    final stop = stops[i];

    markers.add(
      Marker(
        markerId: MarkerId('stop_$i'),
        position: stop.location,
        infoWindow: InfoWindow(title: stopTitles[stop] ?? 'Stop ${i + 1}'),
      ),
    );

    final route = await _placesService.getDirections(origin, stop.location);
    if (route == null) continue;

    final leg = route["legs"][0];
    totalSeconds += leg["duration"]["value"];
    totalMeters += leg["distance"]["value"];

    polylines.add(
      Polyline(
        polylineId: PolylineId('route_$i'),
        points: _placesService.decodePolyline(
          route["overview_polyline"]["points"],
        ),
        width: 5,
        color: Colors.blue,
      ),
    );

    origin = stop.location;
  }

  distance = "${(totalMeters / 1000).toStringAsFixed(1)} km";
  duration = "${(totalSeconds / 60).round()} min";

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
    const Duration(minutes: 1),
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
        if (diff < 90) return;
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

          await reoptimizeRoute(
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
Future<void> reoptimizeRoute({
  required String reason,
  required double severity,
  required int affectedStopIndex,
}) async {
  if (!navigationStarted || _isReoptimizing || stops.isEmpty) return;

  _isReoptimizing = true;
  _lastReoptTime = DateTime.now();

  try {
    // ---------- BASELINE ETA ----------
    double before = 0;
    LatLng origin = currentLocation!;

    for (final stop in stops) {
      final route = await _placesService.getDirections(origin, stop.location);
      if (route == null) return;
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
    };

    final response = await http.post(
      Uri.parse("http://10.0.2.2:8000/reoptimize"),
      headers: {"Content-Type": "application/json"},
      body: jsonEncode(payload),
    );

    if (response.statusCode != 200) return;

    final optimizedStops =
        (jsonDecode(response.body)["optimized_route"] as List)
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
      if (route == null) return;
      after += route["legs"][0]["duration"]["value"] / 60.0;
      origin = stop.location;
    }

    final delta = before - after;
    final percent = (delta / before) * 100;

    debugPrint(
        "ALNS /reoptimize reason=$reason "
        "baseline=${before.toStringAsFixed(2)} min, "
        "optimized=${after.toStringAsFixed(2)} min, "
        "improvement=${delta.toStringAsFixed(2)} min "
        "(${percent.toStringAsFixed(1)}%)");

    if (after >= before) {
      _isReoptimizing = false;
      return; // reject bad reoptimization
    }

    stops
      ..clear()
      ..addAll(optimizedStops);

    await rebuildMap();
  } catch (e) {
    debugPrint("Reoptimization error: $e");
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
