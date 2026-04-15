import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:csv/csv.dart';
import '../env.dart';
import '../models/weather_data.dart';
import '../models/road_incident.dart';
import '../services/places_service.dart';
import '../services/firestore_service.dart';
import '../services/weather_service.dart';
import '../services/road_hazard_service.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import '../models/stop_model.dart';

class MapVM extends ChangeNotifier {
  // ================= SERVICES =================
  final PlacesService _placesService = PlacesService();
  PlacesService get placesService => _placesService;
  final WeatherService _weatherService = WeatherService();
  final RoadHazardService _roadHazardService = RoadHazardService();
  WeatherData? weatherData;
  List<RoadIncident> roadIncidents = [];
  Timer? _weatherTimer;

  final FirestoreService firestoreService = FirestoreService();
String vehicleType = "van";
bool isFragile = false;
  /// When true, backend uses Bellman–Ford on the chosen locations (and current position).
  bool useBellmanFord = true;

  /// Fleet mode: simulated position of the 2nd vehicle (stationary at its first stop).
  LatLng? _simulatedVehicle2Pos;
  /// True when a fleet transfer has happened during this ride.
  bool fleetTransferOccurred = false;
  String get weatherForBackend => weatherData?.backendCondition ?? "Sunny";
  double get weatherRoadRisk   => weatherData?.roadRisk ?? 0.0;
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

  // ================= EVENT LOG =================
  final List<EventLogEntry> eventLog = [];
  bool eventLogExpanded = false;

  void addEvent(String icon, String message) {
    final now = DateTime.now();
    final ts = '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}';
    eventLog.insert(0, EventLogEntry(icon: icon, message: message, time: ts));
    if (eventLog.length > 50) eventLog.removeLast();
    notifyListeners();
  }

  String _severityBand(double severity) {
    if (severity >= 0.75) return "critical";
    if (severity >= 0.45) return "high";
    if (severity >= 0.20) return "moderate";
    return "low";
  }

  String _methodLabel(String method) {
    final m = method.toLowerCase();
    if (m.contains("alns") && m.contains("bellman")) return "smart rerouting";
    if (m.contains("alns")) return "smart rerouting";
    if (m.contains("fleet")) return "fleet balancing";
    if (m.contains("direction")) return "live map data";
    if (m.contains("fallback")) return "offline mode";
    if (m.contains("solver")) return "best option check";
    return "route logic";
  }

  String _xaiEvent({
    required String trigger,
    required String evidence,
    required String decision,
    required String method,
    String? outcome,
    double? severity,
  }) {
    final level = severity == null ? null : _severityBand(severity);
    final riskText = level == null ? "" : "Risk: $level. ";
    final actionText = "Action: $decision (${_methodLabel(method)}).";
    final resultText = outcome == null ? "" : " Result: $outcome.";
    return "${riskText}Why: $trigger ($evidence). $actionText$resultText";
  }

  void toggleEventLog() {
    eventLogExpanded = !eventLogExpanded;
    notifyListeners();
  }

  // ================= LIVE ETA =================
  String nextStopEta = '';
  String totalEta = '';
  String stopProgress = '';

  StreamSubscription<Position>? positionStream;

  bool _showSearchBar = false;
  bool get showSearchBar => _showSearchBar;

  final TextEditingController searchController = TextEditingController();
  final FocusNode searchFocusNode = FocusNode();

  void _updateStopProgress() {
    if (!navigationStarted || stops.isEmpty) {
      stopProgress = '';
      return;
    }
    stopProgress = 'Stop ${currentStopIndex + 1} of ${stops.length}';
  }

  Future<void> _updateTotalEta() async {
    if (currentLocation == null || stops.isEmpty) {
      totalEta = '';
      return;
    }
    double totalSec = 0;
    LatLng origin = currentLocation!;
    for (int i = currentStopIndex; i < stops.length; i++) {
      final route = await _placesService.getDirections(origin, stops[i].location);
      if (route == null) break;
      totalSec += route["legs"][0]["duration"]["value"];
      origin = stops[i].location;
    }
    totalEta = '${(totalSec / 60).round()} min';
  }

  /// ETA label for the active vehicle (shown in the bottom card).
  String activeVehicleEta = '';

  /// Compute ETA for the active vehicle from current position through all its remaining stops.
  Future<void> _computeActiveVehicleEta() async {
    if (currentLocation == null || stops.isEmpty) {
      activeVehicleEta = '';
      return;
    }
    double totalSec = 0;
    LatLng origin = currentLocation!;
    for (int i = currentStopIndex; i < stops.length; i++) {
      final route = await _placesService.getDirections(origin, stops[i].location);
      if (route == null) break;
      totalSec += route["legs"][0]["duration"]["value"];
      origin = stops[i].location;
    }
    final mins = totalSec / 60;
    activeVehicleEta = '${mins.toStringAsFixed(1)} min';
    addEvent(
      "⏱",
      _xaiEvent(
        trigger: "eta update",
        evidence: "${_routes[_activeRouteIndex].name} $activeVehicleEta",
        decision: "display eta",
        method: "directions",
      ),
    );
  }

  @override
  void dispose() {
    positionStream?.cancel();
    _deviationTimer?.cancel();
    _trafficTimer?.cancel();
    _weatherTimer?.cancel();
    super.dispose();
  }

  Future<void> refreshWeather({bool force = false}) async {
    if (currentLocation == null) return;
    final previous = weatherData?.backendCondition;
    final snapshot = await _weatherService.fetchCurrent(
      currentLocation!.latitude,
      currentLocation!.longitude,
      force: force,
    );
    if (snapshot == null) return;

    weatherData = snapshot;

    // Check real road incidents whenever conditions are bad enough to matter
    if (snapshot.severity >= RoadHazardService.minSeverityToCheck) {
      await _checkRoadHazards();
    } else {
      roadIncidents = [];
    }

    notifyListeners();

    if (navigationStarted &&
        previous != null &&
        previous != snapshot.backendCondition &&
        !_isReoptimizing) {
      addEvent(
        "🌦",
        _xaiEvent(
          trigger: "weather shift",
          evidence:
              "${snapshot.condition}, risk ${snapshot.roadRisk.toStringAsFixed(2)}",
          decision: "re-optimize remaining stops",
          method: "ALNS + Bellman-Ford",
          severity: snapshot.severity,
        ),
      );
      unawaited(
        reoptimizeRoute(
          reason: "weather_change",
          severity: snapshot.severity,
          affectedStopIndex: currentStopIndex,
          useBellmanFord: true,
        ),
      );
    }
  }

  Future<void> _checkRoadHazards() async {
    if (currentLocation == null) return;
    final routePoints = stops.map((s) => s.location).toList();
    final incidents = await _roadHazardService.fetchIncidents(
      currentLocation: currentLocation!,
      stops: routePoints,
    );
    roadIncidents = incidents;

    // ── Log each incident with road-class-aware detail ──────────────────────
    for (final inc in incidents) {
      final hazardIcon = _hazardIcon(inc.type);
      final classIcon  = inc.roadClass.icon;      // 🛣️ / 🚗 / 🛤️
      final classLabel = inc.roadClass.label;     // Highway / Main road / Side road
      final road       = inc.fromRoad.isNotEmpty ? inc.fromRoad : 'route';
      final pct        = (inc.hazardScore * 100).toStringAsFixed(0);
      addEvent(
        '$hazardIcon$classIcon',
        _xaiEvent(
          trigger: "hazard scan",
          evidence: '$classLabel "$road" $pct%',
          decision: "monitor",
          method: inc.type,
          severity: inc.hazardScore,
        ),
      );
    }

    if (!navigationStarted || _isReoptimizing || incidents.isEmpty) return;

    // ── Per road-class re-routing thresholds ────────────────────────────────
    //
    // Different road types flood / become dangerous at different severity levels:
    //
    //   Side roads   → reroute threshold 0.40
    //     Small streets flood quickly and have no drainage;
    //     even moderate rain makes them risky.
    //
    //   Tunnels      → reroute threshold 0.45
    //     Tunnels accumulate water fast and offer no escape —
    //     triggered slightly above side roads.
    //
    //   Main roads   → reroute threshold 0.60
    //     Arterials have better drainage but heavy rain still floods them.
    //
    //   Highways     → reroute threshold 0.50
    //     Higher speed makes any hazard more dangerous; threshold is lower
    //     than main roads because consequences of getting it wrong are worse.
    //
    RoadIncident? triggerIncident;
    double        triggerSeverity = 0;

    for (final inc in incidents) {
      final threshold = switch (inc.roadClass) {
        RoadClass.sideRoad => inc.type == 'Tunnel' ? 0.45 : 0.40,
        RoadClass.mainRoad => 0.60,
        RoadClass.highway  => 0.50,
        RoadClass.unknown  => 0.65,
      };

      if (inc.hazardScore >= threshold &&
          inc.hazardScore > triggerSeverity) {
        triggerIncident = inc;
        triggerSeverity = inc.hazardScore;
      }
    }

    if (triggerIncident == null) return;

    final classLabel = triggerIncident.roadClass.label;
    final road       = triggerIncident.fromRoad.isNotEmpty
        ? triggerIncident.fromRoad
        : 'route';
    addEvent(
      '🔁',
      _xaiEvent(
        trigger: "$classLabel hazard",
        evidence:
            '$road: ${triggerIncident.type}, score ${triggerIncident.hazardScore.toStringAsFixed(2)}',
        decision: "avoid risky segment and reroute",
        method: "ALNS + Bellman-Ford",
        severity: triggerIncident.hazardScore,
      ),
    );

    unawaited(
      reoptimizeRoute(
        reason: 'road_hazard',
        severity: triggerSeverity,
        affectedStopIndex: currentStopIndex,
        useBellmanFord: true,
      ),
    );
  }

  static String _hazardIcon(String type) => switch (type) {
    'Flood-prone road'      => '🌊',
    'Ford / water crossing' => '🌊',
    'Tunnel'                => '🚇',
    'Muddy surface'         => '🟫',
    'Sandy surface'         => '🏜️',
    'Gravel surface'        => '🪨',
    'Unpaved road'          => '🛤️',
    _                       => '⚠️',
  };

  void _ensureWeatherTimer() {
    _weatherTimer ??= Timer.periodic(
      const Duration(minutes: 15),
      (_) => unawaited(refreshWeather()),
    );
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

    await refreshWeather(force: true);
    _ensureWeatherTimer();
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

  // ================= AUTO-LOAD STOPS FROM CSV =================
  bool isLoadingStops = false;
  String loadingStatus = '';

  Future<void> loadStopsFromCsv(String driverName) async {
    if (driverName.isEmpty) return;
    isLoadingStops = true;
    loadingStatus = 'Loading your deliveries...';
    notifyListeners();

    try {
      final csvStr = await rootBundle.loadString('assets/data/deliveries.csv');
      final rows = const CsvToListConverter().convert(csvStr, eol: '\n');
      if (rows.isEmpty) {
        loadingStatus = 'No delivery data found.';
        isLoadingStops = false;
        notifyListeners();
        return;
      }

      final headers = rows[0].map((h) => h.toString().trim()).toList();
      final driverIdx   = headers.indexOf('driver_name');
      final addressIdx  = headers.indexOf('address');
      final areaIdx     = headers.indexOf('area');
      final fragileIdx  = headers.indexOf('fragile');
      final customerIdx = headers.indexOf('customer_name');

      final myRows = rows.skip(1).where((row) {
        if (row.length <= driverIdx) { return false; }
        return row[driverIdx].toString().trim().toLowerCase() ==
            driverName.trim().toLowerCase();
      }).toList();

      if (myRows.isEmpty) {
        loadingStatus = 'No stops assigned to $driverName.';
        isLoadingStops = false;
        notifyListeners();
        return;
      }

      int loaded = 0;
      for (final row in myRows) {
        loadingStatus = 'Geocoding stop ${loaded + 1} of ${myRows.length}...';
        notifyListeners();

        final address =
            '${row[addressIdx]}, ${row[areaIdx]}, Cairo, Egypt';
        final isFragile =
            row[fragileIdx].toString().trim().toLowerCase() == 'yes';
        final customerName =
            customerIdx >= 0 ? row[customerIdx].toString() : '';

        final latLng = await _placesService.geocodeAddress(address);
        if (latLng == null) { continue; }

        final stop = Stop(
          location: latLng,
          title: '$customerName – ${row[addressIdx]}',
          isFragile: isFragile,
        );
        _routes[0].stops.add(stop);
        loaded++;
      }

      loadingStatus = loaded > 0
          ? '$loaded stops loaded'
          : 'No stops could be geocoded for $driverName.';

      if (loaded > 0) { await rebuildMap(); }
    } catch (e) {
      loadingStatus = 'Error loading stops.';
      debugPrint('loadStopsFromCsv error: $e');
    }

    isLoadingStops = false;
    notifyListeners();
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
        "weather": weatherForBackend,
        "road_risk": weatherRoadRisk,
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
          title: s["title"] as String?,
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
        for (final s in route.stops) stopTitles.remove(s);
        route.stops
          ..clear()
          ..addAll(optimizedStops);
        for (final s in route.stops) {
          if (s.title != null && s.title!.isNotEmpty) stopTitles[s] = s.title!;
        }
        optimizedCount++;
        addEvent(
          "✓",
          _xaiEvent(
            trigger: "initial optimize",
            evidence: "eta -${improvement.toStringAsFixed(1)}m",
            decision: "apply new order",
            method: "ALNS",
          ),
        );
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
  markers.removeWhere((m) => m.markerId.value != 'start' && m.markerId.value != 'vehicle2');
  polylines.clear();

  if (currentLocation == null) return;

  // Show simulated 2nd vehicle marker during navigation
  if (navigationStarted && _simulatedVehicle2Pos != null && _routes.length >= 2) {
    markers.removeWhere((m) => m.markerId.value == 'vehicle2');
    markers.add(
      Marker(
        markerId: const MarkerId('vehicle2'),
        position: _simulatedVehicle2Pos!,
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueViolet),
        infoWindow: const InfoWindow(title: 'Vehicle 2'),
      ),
    );
  }

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

    // Collect routes that have stops
    final routesWithStops = <int>[];
    for (int i = 0; i < _routes.length; i++) {
      if (_routes[i].stops.isNotEmpty) routesWithStops.add(i);
    }
    if (routesWithStops.isEmpty) return;

    // If multiple cars have stops, let the user choose which one to drive
    int chosenRoute = routesWithStops.first;
    if (routesWithStops.length > 1) {
      final picked = await showDialog<int>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text("Select your vehicle"),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: routesWithStops.map((idx) {
              final r = _routes[idx];
              return ListTile(
                leading: Container(
                  width: 14, height: 14,
                  decoration: BoxDecoration(color: r.color, shape: BoxShape.circle),
                ),
                title: Text("${r.name}  (${r.stops.length} stops)"),
                onTap: () => Navigator.pop(context, idx),
              );
            }).toList(),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, null),
              child: const Text("Cancel"),
            ),
          ],
        ),
      );
      if (picked == null) return; // user cancelled
      chosenRoute = picked;
    }

    _activeRouteIndex = chosenRoute;
    navigationStarted = true;
    routeStatus = 'active';
    currentStopIndex = 0;
    _plannedRoutePoints.clear();
    fleetTransferOccurred = false;
    eventLog.clear();

    // Set up simulated positions for non-active vehicles
    for (int r = 0; r < _routes.length; r++) {
      if (r != _activeRouteIndex && _routes[r].stops.isNotEmpty) {
        _simulatedVehicle2Pos = _routes[r].stops.first.location;
        break;
      }
    }

    final fleetInfo = _routes.length > 1
        ? " (fleet: ${_routes.length} vehicles)"
        : "";
    addEvent(
      "▶",
      _xaiEvent(
        trigger: "ride start",
        evidence: "${_routes[_activeRouteIndex].name}, ${stops.length} stops$fleetInfo",
        decision: "start monitoring",
        method: "live control",
      ),
    );

    // Compute and display per-vehicle ETA for the chosen car
    _updateStopProgress();
    await _computeActiveVehicleEta();
    notifyListeners();

    // Fleet check at start: routes were optimized individually by ALNS,
    // so cross-vehicle transfers may improve the overall assignment
    final hasOtherVehicle = _routes.length >= 2 &&
        _routes.any((r) => r != _routes[_activeRouteIndex] && r.stops.isNotEmpty);
    if (hasOtherVehicle) {
      addEvent(
        "🔄",
        _xaiEvent(
          trigger: "fleet pre-check",
          evidence: "${_routes.length} active vehicles",
          decision: "evaluate transfers",
          method: "fleet optimizer",
        ),
      );
      await fleetReoptimize(context);
    }

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
        addEvent(
          "📍",
          _xaiEvent(
            trigger: "stop reached",
            evidence: "stop ${currentStopIndex + 1}/${stops.length}",
            decision: "advance route state",
            method: "gps proximity",
          ),
        );

        if (currentStopIndex < stops.length - 1) {
          currentStopIndex++;
          _updateStopProgress();
          addEvent(
            "→",
            _xaiEvent(
              trigger: "next leg",
              evidence: "target ${currentStopIndex + 1}/${stops.length}",
              decision: "navigate next stop",
              method: "sequence engine",
            ),
          );
        } else {
          addEvent(
            "🏁",
            _xaiEvent(
              trigger: "route complete",
              evidence: "${stops.length}/${stops.length} stops served",
              decision: "close ride",
              method: "delivery flow",
            ),
          );
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

          // Update live ETA
          final durationSec = route['legs'][0]['duration']['value'] as int;
          nextStopEta = '${(durationSec / 60).round()} min';
          _updateTotalEta();

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
  nextStopEta = '';
  totalEta = '';
  stopProgress = '';
  activeVehicleEta = '';

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

    addEvent(
      "🔧",
      _xaiEvent(
        trigger: "simulated traffic disruption",
        evidence: "same stops, same incident, dual-solver comparison",
        decision: "pick lower-ETA candidate",
        method: "ALNS vs ALNS + Bellman-Ford",
        severity: 0.5,
      ),
    );

    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _xaiEvent(
              trigger: "simulation",
              evidence: "same incident, dual solver",
              decision: "compare candidates",
              method: "ALNS vs ALNS+BF",
              severity: 0.5,
            ),
          ),
        ),
      );
    }

    final payload = {
      "current_lat": currentLocation!.latitude,
      "current_lng": currentLocation!.longitude,
      "remaining_stops":
          stops.skip(currentStopIndex).map((s) => s.toPayload()).toList(),
      "vehicle": vehicleType,
      "traffic": "Heavy",
      "weather": weatherForBackend,
      "road_risk": weatherRoadRisk,
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
      String appliedAlgo = "";
      if (routeAlns != null && routeBf != null && etaAlns != null && etaBf != null) {
        if (etaAlns <= etaBf) {
          toApply = routeAlns;
          appliedAlgo = "ALNS";
          message = "ALNS ${etaAlns.toStringAsFixed(1)} min vs Bellman-Ford ${etaBf.toStringAsFixed(1)} min → applied ALNS";
        } else {
          toApply = routeBf;
          appliedAlgo = "ALNS + Bellman-Ford";
          message = "ALNS ${etaAlns.toStringAsFixed(1)} min vs Bellman-Ford ${etaBf.toStringAsFixed(1)} min → applied Bellman-Ford";
        }
      } else if (routeAlns != null && etaAlns != null) {
        toApply = routeAlns;
        appliedAlgo = "ALNS";
        message = "ALNS ${etaAlns.toStringAsFixed(1)} min (Bellman-Ford unavailable)";
      } else if (routeBf != null && etaBf != null) {
        toApply = routeBf;
        appliedAlgo = "ALNS + Bellman-Ford";
        message = "Bellman-Ford ${etaBf.toStringAsFixed(1)} min (ALNS unavailable)";
      } else {
        message = "No reroute from backend";
      }

      if (toApply != null) {
        final after = toApply == routeAlns ? (etaAlns ?? 0) : (etaBf ?? 0);
        // Migrate stopTitles to new Stop objects
        for (final s in stops) stopTitles.remove(s);
        stops
          ..clear()
          ..addAll(toApply);
        for (final s in stops) {
          if (s.title != null && s.title!.isNotEmpty) {
            stopTitles[s] = s.title!;
          }
        }
        await rebuildMap();
        final saved = before - after;
        if (saved > 0) {
          addEvent(
            "✓",
            _xaiEvent(
              trigger: "traffic incident response",
              evidence: "baseline ${before.toStringAsFixed(1)} min vs optimized ${after.toStringAsFixed(1)} min",
              decision: "apply $appliedAlgo candidate",
              method: "deterministic ETA comparison (no ML)",
              outcome: "saved ${saved.toStringAsFixed(1)} min",
              severity: 0.5,
            ),
          );
        } else {
          addEvent(
            "—",
            _xaiEvent(
              trigger: "traffic incident response",
              evidence:
                  "optimized ETA ${after.toStringAsFixed(1)} min is not better than baseline ${before.toStringAsFixed(1)} min",
              decision: "keep current sequence",
              method: "$appliedAlgo evaluation",
              outcome: "no ETA gain",
              severity: 0.5,
            ),
          );
        }
        if (context.mounted) {
          final extra = after < before
              ? " (${(before - after).toStringAsFixed(1)} min faster)"
              : " — no improvement over current route";
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text("$message$extra"), duration: const Duration(seconds: 4)),
          );
        }

        // Auto fleet check: rerouted path may now overlap with other vehicles
        final hasOtherVehicle = _routes.length >= 2 &&
            _routes.any((r) => r != _routes[_activeRouteIndex] && r.stops.isNotEmpty);
        if (hasOtherVehicle) {
          _isReoptimizing = false;
          addEvent(
            "🔄",
            _xaiEvent(
              trigger: "post-reroute fleet check",
              evidence: "possible path overlap",
              decision: "evaluate transfers",
              method: "fleet optimizer",
            ),
          );
          await fleetReoptimize(context);
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
        title: m["title"] as String?,
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

  // ================= ROAD HAZARD SIMULATION =================
  Future<void> simulateRoadHazard(BuildContext context) async {
    if (!navigationStarted || stops.isEmpty) return;

    _isReoptimizing = true;
    notifyListeners();

    // ── 1. Build incidents that cover all three road classes ─────────────────
    //   This lets the demo show exactly how each class triggers differently:
    //
    //   🛣️  Highway     → flooded underpass, score 0.92 → threshold 0.50 → TRIGGERS
    //   🚗  Main road   → flood-prone stretch, score 0.75 → threshold 0.60 → TRIGGERS
    //   🛤️  Side road   → waterlogged unpaved lane, score 0.38 → threshold 0.40 → SKIPPED
    //   🚇  Tunnel      → tunnel flooding, score 0.65 → threshold 0.45 → TRIGGERS
    //
    final remaining = stops.skip(currentStopIndex).toList();
    final fakeIncidents = <RoadIncident>[];

    LatLng midpoint(LatLng a, LatLng b) =>
        LatLng((a.latitude + b.latitude) / 2, (a.longitude + b.longitude) / 2);

    final base = currentLocation!;

    // Highway flood — most critical, triggers first
    fakeIncidents.add(RoadIncident(
      lat: base.latitude  + 0.003,
      lon: base.longitude + 0.003,
      type: 'Flood-prone road',
      description: 'Highway — flooded underpass, water level rising',
      hazardScore: 0.92,
      delaySeconds: 600,
      fromRoad: 'Highway (simulated)',
      toRoad: '',
      roadClass: RoadClass.highway,
    ));

    // Tunnel ahead — dangerous in any heavy rain
    if (remaining.isNotEmpty) {
      final mid = midpoint(base, remaining.first.location);
      fakeIncidents.add(RoadIncident(
        lat: mid.latitude,
        lon: mid.longitude,
        type: 'Tunnel',
        description: 'Tunnel — accumulates water fast, risk of flooding',
        hazardScore: 0.65,
        delaySeconds: 360,
        fromRoad: 'Tunnel ahead (simulated)',
        toRoad: '',
        roadClass: RoadClass.sideRoad, // tunnels live on side/local roads here
      ));
    }

    // Main road flood-prone stretch
    if (remaining.length >= 2) {
      final mid = midpoint(remaining[0].location, remaining[1].location);
      fakeIncidents.add(RoadIncident(
        lat: mid.latitude,
        lon: mid.longitude,
        type: 'Flood-prone road',
        description: 'Main road — historically floods in heavy rain',
        hazardScore: 0.75,
        delaySeconds: 480,
        fromRoad: 'Main road (simulated)',
        toRoad: '',
        roadClass: RoadClass.mainRoad,
      ));
    }

    // Side road — waterlogged, unpaved lane (below threshold, shown but not rerouted)
    if (remaining.length >= 2) {
      fakeIncidents.add(RoadIncident(
        lat: base.latitude  - 0.002,
        lon: base.longitude - 0.002,
        type: 'Unpaved road',
        description: 'Side road — dirt lane, impassable when wet (below reroute threshold)',
        hazardScore: 0.38,
        delaySeconds: 120,
        fromRoad: 'Side road (simulated)',
        toRoad: '',
        roadClass: RoadClass.sideRoad,
      ));
    }

    roadIncidents = fakeIncidents;
    final simWorstScore = fakeIncidents
        .map((i) => i.hazardScore)
        .reduce((a, b) => a > b ? a : b);

    // ── 2. Log all incidents with road-class icons ───────────────────────────
    for (final inc in fakeIncidents) {
      final hazardIcon = _hazardIcon(inc.type);
      final classIcon  = inc.roadClass.icon;
      final classLabel = inc.roadClass.label;
      final pct        = (inc.hazardScore * 100).toStringAsFixed(0);
      final threshold  = switch (inc.roadClass) {
        RoadClass.sideRoad => inc.type == 'Tunnel' ? 0.45 : 0.40,
        RoadClass.mainRoad => 0.60,
        RoadClass.highway  => 0.50,
        RoadClass.unknown  => 0.65,
      };
      final willReroute = inc.hazardScore >= threshold;
      addEvent(
        '$hazardIcon$classIcon',
        _xaiEvent(
          trigger: "sim hazard",
          evidence: '$classLabel "${inc.fromRoad}" $pct%',
          decision: willReroute ? "reroute candidate" : "monitor",
          method: inc.type,
          severity: inc.hazardScore,
        ),
      );
    }

    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _xaiEvent(
              trigger: "sim hazard set",
              evidence: "${fakeIncidents.length} incidents",
              decision: "reoptimize",
              method: "ALNS+Bellman-Ford",
              severity: simWorstScore,
            ),
          ),
          duration: const Duration(seconds: 3),
        ),
      );
    }

    // ── 3. Measure baseline ETA ─────────────────────────────────────────────
    double before = 0;
    LatLng origin = currentLocation!;
    for (final stop in remaining) {
      final r = await _placesService.getDirections(origin, stop.location);
      if (r == null) break;
      before += r['legs'][0]['duration']['value'] / 60.0;
      origin = stop.location;
    }

    // ── 4. Call backend — only pass incidents that cross their road-class threshold
    final triggeringIncidents = fakeIncidents.where((inc) {
      final threshold = switch (inc.roadClass) {
        RoadClass.sideRoad => inc.type == 'Tunnel' ? 0.45 : 0.40,
        RoadClass.mainRoad => 0.60,
        RoadClass.highway  => 0.50,
        RoadClass.unknown  => 0.65,
      };
      return inc.hazardScore >= threshold;
    }).toList();

    final worstScore = triggeringIncidents.isEmpty
        ? 0.5
        : triggeringIncidents
            .map((i) => i.hazardScore)
            .reduce((a, b) => a > b ? a : b);

    final payload = {
      'current_lat': currentLocation!.latitude,
      'current_lng': currentLocation!.longitude,
      'remaining_stops': remaining.map((s) => s.toPayload()).toList(),
      'vehicle': vehicleType,
      'traffic': 'Heavy',
      'weather': weatherForBackend,
      'road_risk': worstScore,
      'road_incidents': triggeringIncidents.map((i) => {
        'type': i.type,
        'lat': i.lat,
        'lon': i.lon,
        'hazard_score': i.hazardScore,
        'delay_seconds': i.delaySeconds,
        'from': i.fromRoad,
        'to': i.toRoad,
      }).toList(),
      'reason': 'road_hazard',
      'severity': worstScore,
      'simulate': true,
      'use_bellman_ford': true,
      'google_maps_api_key': Env.googleMapsApiKey,
    };

    try {
      final response = await http
          .post(
            Uri.parse('${Env.backendBaseUrl}/reoptimize'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(payload),
          )
          .timeout(const Duration(seconds: 12));

      if (response.statusCode == 200) {
        final body = jsonDecode(response.body) as Map<String, dynamic>;
        if (body['rerouted'] == true) {
          final newStops = _parseOptimizedRoute(body['optimized_route'] as List);
          final after = await _measureEtaFromStops(newStops);
          final saved = (before - (after ?? before))
              .clamp(0.0, 999.0)
              .toStringAsFixed(1);

          _routes[_activeRouteIndex].stops
            ..removeRange(currentStopIndex, _routes[_activeRouteIndex].stops.length)
            ..addAll(newStops);
          await rebuildMap();

          addEvent(
            '✅',
            _xaiEvent(
              trigger: "hazard reroute",
              evidence: "eta -$saved m",
              decision: "apply safer route",
              method: "ALNS+Bellman-Ford",
              severity: worstScore,
            ),
          );
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  _xaiEvent(
                    trigger: "hazard reroute",
                    evidence: "eta -$saved m",
                    decision: "route updated",
                    method: "ALNS+Bellman-Ford",
                    severity: worstScore,
                  ),
                ),
                duration: const Duration(seconds: 5),
              ),
            );
          }
        } else {
          addEvent(
            'ℹ️',
            _xaiEvent(
              trigger: "hazard reroute",
              evidence: "no lower ETA candidate",
              decision: "keep current route",
              method: "ALNS+Bellman-Ford",
              severity: worstScore,
            ),
          );
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  _xaiEvent(
                    trigger: "hazard reroute",
                    evidence: "no lower ETA candidate",
                    decision: "keep route",
                    method: "ALNS+Bellman-Ford",
                    severity: worstScore,
                  ),
                ),
              ),
            );
          }
        }
      } else {
        // Backend unreachable — offline demo
        addEvent(
          '🔁',
          _xaiEvent(
            trigger: "backend fallback",
            evidence: "reoptimize HTTP ${response.statusCode}",
            decision: "run offline demo",
            method: "local fallback",
          ),
        );
        if (context.mounted) await _runOfflineDemoReroute(context);
      }
    } catch (_) {
      addEvent(
        '🔁',
        _xaiEvent(
          trigger: "backend fallback",
          evidence: "network exception",
          decision: "run offline demo",
          method: "local fallback",
        ),
      );
      if (context.mounted) await _runOfflineDemoReroute(context);
    } finally {
      _isReoptimizing = false;
      notifyListeners();
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
        addEvent(
          "⚠",
          _xaiEvent(
            trigger: "deviation",
            evidence: "${minDist.toStringAsFixed(0)}m from path",
            decision: "reoptimize remaining stops",
            method: "ALNS",
            severity: 1.0,
          ),
        );

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              _xaiEvent(
                trigger: "deviation",
                evidence: "${minDist.toStringAsFixed(0)}m off route",
                decision: "reoptimize",
                method: "ALNS",
                severity: 1.0,
              ),
            ),
          ),
        );

        final success = await reoptimizeRoute(
          context: context,
          reason: "deviation",
          severity: 1.0, // full severity — route is invalid
          affectedStopIndex: currentStopIndex,
        );

        if (success) {
          addEvent(
            "✓",
            _xaiEvent(
              trigger: "deviation handled",
              evidence: "feasible reroute found",
              decision: "apply updated route",
              method: "ALNS",
              severity: 1.0,
            ),
          );
        }

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
        if (diff < 45) return;
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

        addEvent(
          "🔍",
          _xaiEvent(
            trigger: "periodic traffic probe",
            evidence:
                "next-leg delay ${(ratio * 100).toStringAsFixed(0)}% (live vs free-flow)",
            decision: "continue monitoring",
            method: "Directions API delta",
            severity: ratio,
          ),
        );

        if (ratio > 0.10) {
          addEvent(
            "🚦",
            _xaiEvent(
              trigger: "delay threshold exceeded",
              evidence: "+${(ratio * 100).toStringAsFixed(0)}% on active leg",
              decision: "evaluate alternate route orders",
              method: "ALNS vs ALNS + Bellman-Ford",
              severity: ratio,
            ),
          );

          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  _xaiEvent(
                    trigger: "traffic threshold",
                    evidence: "+${(ratio * 100).toStringAsFixed(0)}%",
                    decision: "reoptimize",
                    method: "ALNS vs ALNS+BF",
                    severity: ratio,
                  ),
                ),
              ),
            );
          }

          _isReoptimizing = true;
          _lastReoptTime = DateTime.now();

          // Run both algorithms and compare
          final payload = {
            "current_lat": currentLocation!.latitude,
            "current_lng": currentLocation!.longitude,
            "remaining_stops":
                stops.skip(currentStopIndex).map((s) => s.toPayload()).toList(),
            "vehicle": vehicleType,
            "traffic": "Heavy",
            "weather": weatherForBackend,
            "road_risk": weatherRoadRisk,
            "reason": "traffic_jam",
            "severity": ratio,
            "simulate": false,
            "google_maps_api_key": Env.googleMapsApiKey,
          };

          // 1) ALNS only
          final payloadAlns = {...payload, "use_bellman_ford": false};
          final responseAlns = await http
              .post(
                Uri.parse("${Env.backendBaseUrl}/reoptimize"),
                headers: {"Content-Type": "application/json"},
                body: jsonEncode(payloadAlns),
              )
              .timeout(const Duration(seconds: 12));

          // 2) ALNS + Bellman-Ford
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
            final b = jsonDecode(responseAlns.body) as Map<String, dynamic>;
            if (b["rerouted"] == true && b["optimized_route"] != null) {
              routeAlns = _parseOptimizedRoute(b["optimized_route"] as List);
              etaAlns = await _measureEtaFromStops(routeAlns);
            }
          }

          double? etaBf;
          List<Stop>? routeBf;
          if (responseBf.statusCode == 200) {
            final b = jsonDecode(responseBf.body) as Map<String, dynamic>;
            if (b["rerouted"] == true && b["optimized_route"] != null) {
              routeBf = _parseOptimizedRoute(b["optimized_route"] as List);
              etaBf = await _measureEtaFromStops(routeBf);
            }
          }

          // Baseline ETA
          double before = 0;
          LatLng etaOrigin = currentLocation!;
          for (int si = currentStopIndex; si < stops.length; si++) {
            final r2 = await _placesService.getDirections(etaOrigin, stops[si].location);
            if (r2 == null) break;
            before += r2["legs"][0]["duration"]["value"] / 60.0;
            etaOrigin = stops[si].location;
          }

          // Pick the best
          List<Stop>? toApply;
          String appliedAlgo = "";
          if (routeAlns != null && routeBf != null && etaAlns != null && etaBf != null) {
            addEvent(
              "📊",
              _xaiEvent(
                trigger: "dual-solver evaluation",
                evidence:
                    "ALNS ${etaAlns.toStringAsFixed(1)} min vs ALNS+BF ${etaBf.toStringAsFixed(1)} min",
                decision: etaAlns <= etaBf ? "choose ALNS candidate" : "choose ALNS+BF candidate",
                method: "lower ETA wins",
                severity: ratio,
              ),
            );
            if (etaAlns <= etaBf) {
              toApply = routeAlns;
              appliedAlgo = "ALNS";
            } else {
              toApply = routeBf;
              appliedAlgo = "ALNS + Bellman-Ford";
            }
          } else if (routeAlns != null && etaAlns != null) {
            addEvent(
              "📊",
              _xaiEvent(
                trigger: "solver comparison",
                evidence: "ALNS ${etaAlns.toStringAsFixed(1)}m, BF unavailable",
                decision: "use ALNS candidate",
                method: "single-available solver",
                severity: ratio,
              ),
            );
            toApply = routeAlns;
            appliedAlgo = "ALNS";
          } else if (routeBf != null && etaBf != null) {
            addEvent(
              "📊",
              _xaiEvent(
                trigger: "solver comparison",
                evidence: "ALNS+BF ${etaBf.toStringAsFixed(1)}m, ALNS unavailable",
                decision: "use ALNS+BF candidate",
                method: "single-available solver",
                severity: ratio,
              ),
            );
            toApply = routeBf;
            appliedAlgo = "ALNS + Bellman-Ford";
          }

          if (toApply != null) {
            final after = toApply == routeAlns ? (etaAlns ?? 0) : (etaBf ?? 0);
            // Migrate stopTitles
            for (final s in stops) { stopTitles.remove(s); }
            stops
              ..clear()
              ..addAll(toApply);
            for (final s in stops) {
              if (s.title != null && s.title!.isNotEmpty) stopTitles[s] = s.title!;
            }
            await rebuildMap();
            final saved = before - after;
            if (saved > 0) {
              addEvent(
                "✓",
                _xaiEvent(
                  trigger: "traffic-aware reroute",
                  evidence:
                      "baseline ${before.toStringAsFixed(1)} min vs updated ${after.toStringAsFixed(1)} min",
                  decision: "apply $appliedAlgo plan",
                  method: "deterministic ETA objective",
                  outcome: "saved ${saved.toStringAsFixed(1)} min",
                  severity: ratio,
                ),
              );
            } else {
              addEvent(
                "✓",
                _xaiEvent(
                  trigger: "traffic-aware reroute",
                  evidence:
                      "candidate ETA ${after.toStringAsFixed(1)} min did not beat current plan",
                  decision: "retain current effective order",
                  method: "$appliedAlgo check",
                  outcome: "already near-optimal",
                  severity: ratio,
                ),
              );
            }
            activeVehicleEta = '${after.toStringAsFixed(1)} min';
          }

          // Fleet check after reroute
          final hasOtherVehicle = _routes.length >= 2 &&
              _routes.any((r) => r != _routes[_activeRouteIndex] && r.stops.isNotEmpty);
          if (hasOtherVehicle) {
            _isReoptimizing = false;
            addEvent(
              "🔄",
              _xaiEvent(
                trigger: "post-reroute fleet check",
                evidence: "possible path overlap",
                decision: "evaluate transfers",
                method: "fleet optimizer",
              ),
            );
            if (context.mounted) await fleetReoptimize(context);
          }
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
      "weather": weatherForBackend,
      "road_risk": weatherRoadRisk,
      "road_incidents": roadIncidents.map((i) => {
        "type": i.type,
        "lat": i.lat,
        "lon": i.lon,
        "hazard_score": i.hazardScore,
        "delay_seconds": i.delaySeconds,
        "from": i.fromRoad,
        "to": i.toRoad,
      }).toList(),
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
        title: s["title"] as String?,
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

    for (final s in stops) { stopTitles.remove(s); }
    stops
      ..clear()
      ..addAll(optimizedStops);
    for (final s in stops) {
      if (s.title != null && s.title!.isNotEmpty) stopTitles[s] = s.title!;
    }

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
// ================= FLEET REOPTIMIZE =================
/// Called when traffic hits the active vehicle and there's a 2nd route.
/// Sends all vehicles' positions + stops to /fleet-reoptimize and applies
/// any stop transfers.
Future<void> fleetReoptimize(BuildContext context) async {
  if (!navigationStarted || _routes.length < 2) return;
  if (_isReoptimizing) return;

  _isReoptimizing = true;
  _lastReoptTime = DateTime.now();

  addEvent(
    "🚛",
    _xaiEvent(
      trigger: "fleet optimize",
      evidence: "${_routes.length} vehicles",
      decision: "evaluate stop transfer plan",
      method: "fleet endpoint",
      severity: 0.6,
    ),
  );

  try {
    // ---------- MEASURE ETA BEFORE (real Google Maps minutes) ----------
    double etaBeforeMin = 0;
    {
      LatLng origin = currentLocation ?? _routes[_activeRouteIndex].stops.first.location;
      final activeStops = _routes[_activeRouteIndex].stops;
      for (int i = currentStopIndex; i < activeStops.length; i++) {
        final r = await _placesService.getDirections(origin, activeStops[i].location);
        if (r != null) etaBeforeMin += r["legs"][0]["duration"]["value"] / 60.0;
        origin = activeStops[i].location;
      }
    }

    // Build vehicle states for the request
    final List<Map<String, dynamic>> vehicleStates = [];

    for (int r = 0; r < _routes.length; r++) {
      final route = _routes[r];
      final isActive = r == _activeRouteIndex;

      // Active vehicle: use live position + remaining stops
      // Other vehicles: use simulated position (first stop or stored position)
      final LatLng vehiclePos;
      final List<Stop> remainingStops;

      if (isActive) {
        vehiclePos = currentLocation ?? route.stops.first.location;
        remainingStops = route.stops.skip(currentStopIndex).toList();
      } else {
        // Simulated vehicle: stays at its position (start of its route)
        vehiclePos = _simulatedVehicle2Pos ??
            (route.stops.isNotEmpty ? route.stops.first.location : currentLocation!);
        remainingStops = List.from(route.stops);
      }

      vehicleStates.add({
        "current_lat": vehiclePos.latitude,
        "current_lng": vehiclePos.longitude,
        "remaining_stops": remainingStops.map((s) => s.toPayload()).toList(),
        "vehicle": vehicleType,
        "traffic": isActive ? "Heavy" : "Normal",
        "weather": weatherForBackend,
        "road_risk": weatherRoadRisk,
      });
    }

    final payload = {
      "vehicles": vehicleStates,
      "reason": "traffic_jam",
      "severity": 0.6,
      "affected_vehicle": _activeRouteIndex,
    };

    final response = await http
        .post(
          Uri.parse("${Env.backendBaseUrl}/fleet-reoptimize"),
          headers: {"Content-Type": "application/json"},
          body: jsonEncode(payload),
        )
        .timeout(const Duration(seconds: 15));

    if (response.statusCode != 200) {
      addEvent(
        "✗",
        _xaiEvent(
          trigger: "fleet optimize",
          evidence: "HTTP ${response.statusCode}",
          decision: "skip transfer update",
          method: "fleet endpoint",
          severity: 0.6,
        ),
      );
      return;
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final rerouted = body["rerouted"] == true;
    final transfers = (body["transfers"] as List?) ?? [];
    final vehicleRoutes = body["vehicle_routes"] as List?;

    if (!rerouted || transfers.isEmpty) {
      addEvent(
        "—",
        _xaiEvent(
          trigger: "fleet optimize",
          evidence: "0 beneficial transfers",
          decision: "keep current assignment",
          method: "fleet objective",
          severity: 0.6,
        ),
      );
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("Fleet: no stop transfers needed"),
            duration: Duration(seconds: 2),
          ),
        );
      }
      return;
    }

    // Build a lookup from (lat,lng) → title so names survive the transfer
    final Map<String, String> coordToTitle = {};
    for (final route in _routes) {
      for (final s in route.stops) {
        final name = stopTitles[s] ?? s.title;
        if (name != null && name.isNotEmpty) {
          final key = '${s.location.latitude.toStringAsFixed(6)},${s.location.longitude.toStringAsFixed(6)}';
          coordToTitle[key] = name;
        }
      }
    }

    // Apply the optimized routes to each vehicle
    if (vehicleRoutes != null) {
      for (int r = 0; r < vehicleRoutes.length && r < _routes.length; r++) {
        final routeStops = (vehicleRoutes[r] as List).map<Stop>((s) {
          final m = s as Map<String, dynamic>;
          final int windowStart = (m["window_start"] as int?) ?? 0;
          final int windowEnd = (m["window_end"] as int?) ?? 24 * 60;
          final lat = (m["lat"] as num).toDouble();
          final lng = (m["lng"] as num).toDouble();
          // Restore title from backend response or coordinate lookup
          final backendTitle = m["title"] as String?;
          final coordKey = '${lat.toStringAsFixed(6)},${lng.toStringAsFixed(6)}';
          final resolvedTitle = backendTitle ?? coordToTitle[coordKey];
          return Stop(
            location: LatLng(lat, lng),
            title: resolvedTitle,
            isFragile: m["is_fragile"] ?? false,
            windowStartMin: windowStart,
            windowEndMin: windowEnd,
            estimatedTime: windowStart.toDouble(),
            actualTime: windowEnd.toDouble(),
          );
        }).toList();

        // Clear old stopTitles for this route's stops
        for (final s in _routes[r].stops) {
          stopTitles.remove(s);
        }

        if (r == _activeRouteIndex) {
          final visited = _routes[r].stops.sublist(0, currentStopIndex);
          _routes[r].stops
            ..clear()
            ..addAll(visited)
            ..addAll(routeStops);
        } else {
          _routes[r].stops
            ..clear()
            ..addAll(routeStops);
        }

        // Re-populate stopTitles for the new Stop objects
        for (final s in _routes[r].stops) {
          if (s.title != null && s.title!.isNotEmpty) {
            stopTitles[s] = s.title!;
          }
        }
      }
    }

    fleetTransferOccurred = true;

    // Log each transfer with stop name
    for (final t in transfers) {
      final fromV = t["from_vehicle"] as int;
      final toV = t["to_vehicle"] as int;
      final sLat = (t["stop_lat"] as num?)?.toDouble();
      final sLng = (t["stop_lng"] as num?)?.toDouble();
      String stopLabel = "stop";
      if (sLat != null && sLng != null) {
        final key = '${sLat.toStringAsFixed(6)},${sLng.toStringAsFixed(6)}';
        stopLabel = coordToTitle[key] ?? "stop";
      }
      addEvent(
        "↔",
        _xaiEvent(
          trigger: "fleet transfer",
          evidence: "'$stopLabel' ${_routes[fromV].name}->${_routes[toV].name}",
          decision: "reassign stop",
          method: "fleet objective",
          severity: 0.6,
        ),
      );
    }

    await rebuildMap();
    _updateStopProgress();

    // ---------- MEASURE ETA AFTER (real Google Maps minutes) ----------
    double etaAfterMin = 0;
    {
      LatLng origin = currentLocation ?? _routes[_activeRouteIndex].stops.first.location;
      final activeStops = _routes[_activeRouteIndex].stops;
      for (int i = currentStopIndex; i < activeStops.length; i++) {
        final r = await _placesService.getDirections(origin, activeStops[i].location);
        if (r != null) etaAfterMin += r["legs"][0]["duration"]["value"] / 60.0;
        origin = activeStops[i].location;
      }
    }

    final minutesSaved = etaBeforeMin - etaAfterMin;
    activeVehicleEta = '${etaAfterMin.toStringAsFixed(1)} min';

    addEvent(
      "✓",
      _xaiEvent(
        trigger: "fleet optimize",
        evidence: "${transfers.length} transfer(s), eta -${minutesSaved.toStringAsFixed(1)}m",
        decision: "apply assignment",
        method: "fleet objective",
        severity: 0.6,
      ),
    );

    if (context.mounted) {
      final savedLabel = minutesSaved > 0
          ? "saved ${minutesSaved.toStringAsFixed(1)} min"
          : "no time improvement";
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            "Fleet: ${transfers.length} stop(s) transferred — $savedLabel",
          ),
          duration: const Duration(seconds: 4),
        ),
      );
    }
  } catch (e) {
    debugPrint("Fleet reoptimize error: $e");
    addEvent(
      "✗",
      _xaiEvent(
        trigger: "fleet optimize",
        evidence: "exception",
        decision: "keep current assignment",
        method: "fleet endpoint",
        severity: 0.6,
      ),
    );
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Fleet reoptimize error: $e")),
      );
    }
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
