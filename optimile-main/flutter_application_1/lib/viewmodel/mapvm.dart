import 'dart:async';
import 'dart:math' as math;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import '../services/places_service.dart';
import '../services/firestore_service.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import '../view/login.dart';
import '../models/stop_model.dart'; // <-- import Stop model

class MapVM extends ChangeNotifier {
  // ================= SERVICES =================
  final PlacesService _placesService = PlacesService();
  PlacesService get placesService => _placesService;
  final FirestoreService firestoreService = FirestoreService();

  // ================= MAP =================
  GoogleMapController? mapController;
  LatLng? currentLocation;
  String? activeDeliveryId;

  // ================= ROUTE =================
  final List<Stop> stops = []; // <-- now a list of Stop objects
  final Map<Stop, String> stopTitles = {}; // <-- keys are Stop objects
  final Set<Marker> markers = {};
  final Set<Polyline> polylines = {};

  bool navigationStarted = false;
  String routeStatus = 'idle'; // idle | navigating | done
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
    super.dispose();
  }

  void openSearchBar() {
    _showSearchBar = true;
    notifyListeners();
    Future.delayed(const Duration(milliseconds: 100), () {
      FocusScope.of(searchFocusNode.context!).requestFocus(searchFocusNode);
    });
  }

  Future<List<Place>> getSuggestions(String query) {
    return placesService.getSuggestions(query);
  }

  void closeSearchBar() {
    _showSearchBar = false;
    searchController.clear();
    notifyListeners();
    searchFocusNode.unfocus();
  }

  /// ================= SELECT PLACE / ADD STOP =================
  Future<void> selectSuggestion(Place place) async {
    final latLng = await placesService.getCoordinatesFromPlaceId(place.placeId);

    if (latLng != null) {
      final stop = Stop(location: latLng, title: place.description);
      stops.add(stop);
      stopTitles[stop] = place.description;
      rebuildMap();
      mapController?.animateCamera(CameraUpdate.newLatLngZoom(latLng, 15));
    }
    placesService.resetSession();
    closeSearchBar();
  }

  // ================= OPTIMIZE =================
  Future<void> optimizeRoute(BuildContext context) async {
    if (stops.length < 2) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Add at least two stops")),
      );
      return;
    }

    print("🔍 Stops before optimize: ${stops.length}");
    for (var s in stops) {
      print("Stop: ${s.location.latitude}, ${s.location.longitude}");
    }

    double initialTotalMinutes = 0;
    LatLng? origin = currentLocation;

    for (var stop in stops) {
      if (origin != null) {
        final route = await placesService.getDirections(origin, stop.location);
        if (route != null) {
          final seconds = route["legs"][0]["duration"]["value"];
          initialTotalMinutes += seconds / 60.0;
        }
      }
      origin = stop.location;
    }

    print("⏱ Initial REAL ETA: ${initialTotalMinutes.toStringAsFixed(1)} min");

    final stopsPayload = stops.map((s) {
      return {
        "Order_ID": "STOP_${stops.indexOf(s) + 1}",
        "Drop_Latitude": s.location.latitude,
        "Drop_Longitude": s.location.longitude,
        "Store_Latitude": currentLocation?.latitude ?? s.location.latitude,
        "Store_Longitude": currentLocation?.longitude ?? s.location.longitude,
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
        Uri.parse("http://10.0.2.2:8000/optimize"),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode(body),
      );

      print("RAW BACKEND RESPONSE: ${response.body}");

      final data = jsonDecode(response.body);
      final optimizedRoute = data["optimized_route"] as List<dynamic>;

      final List<Stop> newStops = optimizedRoute.map((stop) {
        return Stop(
          location: LatLng(stop["Drop_Latitude"], stop["Drop_Longitude"]),
        );
      }).toList();

      double optimizedTotalMinutes = 0;
      origin = currentLocation;

      for (var stop in newStops) {
        if (origin != null) {
          final route = await placesService.getDirections(origin, stop.location);
          if (route != null) {
            optimizedTotalMinutes += route["legs"][0]["duration"]["value"] / 60.0;
          }
        }
        origin = stop.location;
      }

      print("⏱ Optimized REAL ETA: ${optimizedTotalMinutes.toStringAsFixed(1)} min");
      print("💡 Time Saved: ${(initialTotalMinutes - optimizedTotalMinutes).toStringAsFixed(1)} min");

      stops
        ..clear()
        ..addAll(newStops);

      await rebuildMap();

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            "Initial ETA: ${initialTotalMinutes.toStringAsFixed(1)} min\n"
           "Optimized ETA: ${optimizedTotalMinutes.toStringAsFixed(1)} min\n"
  "Saved: ${(initialTotalMinutes - optimizedTotalMinutes).toStringAsFixed(1)} min",
  textAlign: TextAlign.center,
          ),
          duration: const Duration(seconds: 6),
        ),
      );

      if (activeDeliveryId == null) {
        await firestoreService.saveDeliveryToFirestore(
          initialTotalMinutes,
          optimizedTotalMinutes,
          stops.map((s) => s.location).cast<Stop>().toList(),
          this,
        );
      }
    } catch (e) {
      print("Optimization error: $e");
    }

    notifyListeners();
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

  // ================= REBUILD MAP =================
  Future<void> rebuildMap() async {
    if (navigationStarted) return;

    markers.removeWhere((m) => m.markerId.value != 'start');
    polylines.clear();

    LatLng? origin = currentLocation;

    for (int i = 0; i < stops.length; i++) {
      final Stop stop = stops[i];

      // MARKER
      markers.add(
        Marker(
          markerId: MarkerId('stop_$i'),
          position: stop.location,
          infoWindow: InfoWindow(title: stopTitles[stop] ?? stop.title ?? 'Stop ${i + 1}'),
        ),
      );

      // POLYLINE
      if (origin != null) {
        final route = await placesService.getDirections(origin, stop.location);
        if (route != null) {
          polylines.add(
            Polyline(
              polylineId: PolylineId('route_$i'),
              points: placesService.decodePolyline(route['overview_polyline']['points']),
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

  String stopStatus(int index) {
    if (!navigationStarted) return 'pending';
    if (index < currentStopIndex) return 'completed';
    if (index == currentStopIndex) return 'current';
    return 'pending';
  }

  // ================= NAVIGATION =================
  Future<void> startRide(BuildContext context) async {
    if (stops.isEmpty || currentLocation == null) return;

    if (firestoreService.activeDeliveryId == null) {
      print("❌ Cannot start ride: no delivery ID. Save delivery first!");
      return;
    }

    navigationStarted = true;
    routeStatus = 'active';
    currentStopIndex = 0;

    positionStream?.cancel();
    positionStream = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 5,
      ),
    ).listen((pos) async {
      final liveLocation = LatLng(pos.latitude, pos.longitude);
      currentLocation = liveLocation;

      final destination = stops[currentStopIndex].location;

      // Update marker
      markers.removeWhere((m) => m.markerId.value == 'start');
      markers.add(
        Marker(
          markerId: const MarkerId('start'),
          position: liveLocation,
          icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen),
        ),
      );

      notifyListeners();

      // Update Firestore status
      if (firestoreService.activeDeliveryId != null) {
        await firestoreService.updateRouteStatusInFirestore('active');
      }

      final distanceToStop = Geolocator.distanceBetween(
        liveLocation.latitude,
        liveLocation.longitude,
        destination.latitude,
        destination.longitude,
      );

      // ARRIVED
      if (distanceToStop < 30) {
        polylines.removeWhere((p) => p.polylineId.value == 'route_$currentStopIndex');

        if (currentStopIndex < stops.length - 1) {
          currentStopIndex++;
        } else {
          stopRide(completed: true, context: context);
          return;
        }
      }

      // Update live polyline
      final route = await placesService.getDirections(liveLocation, destination);

      if (route != null) {
        final points = placesService.decodePolyline(route['overview_polyline']['points']);

        polylines.removeWhere((p) => p.polylineId.value == 'live_route');
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

      // Move camera
      mapController?.animateCamera(
        CameraUpdate.newCameraPosition(
          CameraPosition(
            target: liveLocation,
            zoom: 20,
            tilt: 45,
            bearing: pos.heading,
          ),
        ),
      );
    });

    notifyListeners();
  }

// ================= STOP / EXIT =================
Future<void> stopRide({bool completed = false, required BuildContext context}) async {
  // Stop location stream
  await positionStream?.cancel();
  positionStream = null;

  // Update state
  navigationStarted = false;
  routeStatus = 'done';
  distance = '';
  duration = '';

  // Clear all stops and map visuals
  stops.clear(); // remove all pinned locations
  stopTitles.clear(); // clear stop names
  markers.removeWhere((m) => m.markerId.value != 'start'); // keep current location marker
  polylines.clear(); // remove all blue lines

  notifyListeners();

  // Update Firestore status
  await firestoreService.updateRouteStatusInFirestore(
    completed ? 'completed' : 'done',
  );

  // Optional: confirm in Firestore
  if (firestoreService.activeDeliveryId != null) {
    final snap = await FirebaseFirestore.instance
        .collection('deliveries')
        .doc(firestoreService.activeDeliveryId)
        .get();
    print("🔥 DB CONFIRM STATUS: ${snap['status']}");
  }

  // Animate camera to current location
  if (currentLocation != null) {
    await mapController?.animateCamera(
      CameraUpdate.newLatLngZoom(currentLocation!, 18),
    );
  }

  // Show feedback
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(
        completed ? "Route completed 🎉" : "Route marked as done",
      ),
    ),
  );

  // Rebuild map (will only show current location now)
  await rebuildMap();
}


  // ================= UTILS =================
  double calculateDistance(LatLng a, LatLng b) {
    const R = 6371.0;
    final dLat = (b.latitude - a.latitude) * math.pi / 180;
    final dLon = (b.longitude - a.longitude) * math.pi / 180;

    final aa = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(a.latitude * math.pi / 180) *
            math.cos(b.latitude * math.pi / 180) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);

    return R * 2 * math.asin(math.sqrt(aa));
  }

  Future<void> logout(BuildContext context) async {
    try {
      await FirebaseAuth.instance.signOut();
      print("User logged out");

      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(builder: (_) => const LoginPage()),
        (route) => false,
      );
    } catch (e) {
      print("Logout failed: $e");
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("Logout failed: ${e.toString()}"),
          backgroundColor: Colors.red.shade600,
        ),
      );
    }
  }
}
