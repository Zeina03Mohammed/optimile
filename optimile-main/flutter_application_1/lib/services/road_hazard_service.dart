import 'dart:convert';
import 'dart:math' as math;
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;
import '../models/road_incident.dart';

/// Detects weather-vulnerable road segments using two sources:
///
/// 1. OSM Overpass API — explicitly tagged hazards (tunnels, fords,
///    flood_prone, unpaved surfaces). No API key required.
///
/// 2. Google Directions API — classifies every road segment on the route
///    by type (highway / main / side road) and infers flood risk based on
///    road class + weather severity. Works anywhere Google Maps has data.
///
/// Results from both sources are merged and returned together.
class RoadHazardService {
  RoadHazardService({required this.googleMapsApiKey});

  final String googleMapsApiKey;

  static const _osmEndpoint        = 'https://overpass-api.de/api/interpreter';
  static const _directionsEndpoint = 'https://maps.googleapis.com/maps/api/directions/json';
  static const _timeout            = Duration(seconds: 15);

  static const double minSeverityToCheck = 0.30;
  static const double _bboxPad           = 0.04; // ~4 km buffer

  Future<List<RoadIncident>> fetchIncidents({
    required LatLng currentLocation,
    required List<LatLng> stops,
    required double weatherSeverity,
    List<LatLng> routePolyline = const [],
  }) async {
    // Run both sources in parallel
    final results = await Future.wait([
      _fetchOsmHazards(
        currentLocation: currentLocation,
        stops: stops,
        weatherSeverity: weatherSeverity,
        routePolyline: routePolyline,
      ),
      _fetchDirectionsHazards(
        currentLocation: currentLocation,
        stops: stops,
        weatherSeverity: weatherSeverity,
      ),
    ]);

    return [...results[0], ...results[1]];
  }

  // ── 1. OSM: explicitly tagged hazards ─────────────────────────────────────

  Future<List<RoadIncident>> _fetchOsmHazards({
    required LatLng currentLocation,
    required List<LatLng> stops,
    required double weatherSeverity,
    List<LatLng> routePolyline = const [],
  }) async {
    final String area;
    if (routePolyline.isNotEmpty) {
      final sampled = _samplePolyline(routePolyline, 200);
      final coords  = sampled.map((p) => '${p.latitude},${p.longitude}').join(',');
      area = '(around:100,$coords)';
    } else {
      final bbox = _buildBbox(currentLocation, stops);
      area = '(${bbox.s},${bbox.w},${bbox.n},${bbox.e})';
    }

    final query = '''
[out:json][timeout:14];
(
  way["flood_prone"="yes"]$area;
  way["highway"="ford"]$area;
  way["tunnel"="yes"]$area;
  way["surface"~"^(unpaved|dirt|gravel|mud|sand|ground|grass)\$"]$area;
  node["ford"="yes"]$area;
);
out center tags;
''';

    try {
      final response = await http
          .post(
            Uri.parse(_osmEndpoint),
            headers: {
              'Content-Type': 'text/plain',
              'Accept': '*/*',
              'User-Agent': 'optimile-app/1.0',
            },
            body: query,
          )
          .timeout(_timeout);

      if (response.statusCode != 200) return [];

      final body     = jsonDecode(response.body) as Map<String, dynamic>;
      final elements = body['elements'] as List? ?? [];

      return elements
          .map((e) => _parseOsmElement(e as Map<String, dynamic>, weatherSeverity))
          .whereType<RoadIncident>()
          .toList();
    } catch (_) {
      return [];
    }
  }

  // ── 2. Google Directions: road-type classification → flood risk inference ──

  Future<List<RoadIncident>> _fetchDirectionsHazards({
    required LatLng currentLocation,
    required List<LatLng> stops,
    required double weatherSeverity,
  }) async {
    if (stops.isEmpty || weatherSeverity < minSeverityToCheck) return [];

    try {
      final origin      = '${currentLocation.latitude},${currentLocation.longitude}';
      final destination = '${stops.last.latitude},${stops.last.longitude}';
      final waypointStr = stops.length > 1
          ? '&waypoints=${stops.take(stops.length - 1).map((s) => '${s.latitude},${s.longitude}').join('|')}'
          : '';

      final url = '$_directionsEndpoint?origin=$origin'
          '&destination=$destination$waypointStr&key=$googleMapsApiKey';

      final response = await http.get(Uri.parse(url)).timeout(_timeout);
      if (response.statusCode != 200) return [];

      final body = jsonDecode(response.body) as Map<String, dynamic>;
      if (body['status'] != 'OK') return [];

      final routes = body['routes'] as List?;
      if (routes == null || routes.isEmpty) return [];

      // Collect all steps across all legs
      final allSteps = <Map<String, dynamic>>[];
      for (final leg in (routes[0]['legs'] as List? ?? [])) {
        allSteps.addAll(
          (leg['steps'] as List? ?? []).cast<Map<String, dynamic>>(),
        );
      }

      return _inferHazardsFromSteps(allSteps, weatherSeverity);
    } catch (_) {
      return [];
    }
  }

  /// Groups route steps by road class and produces one flood-risk incident
  /// per road class that appears significantly (>300 m) on the route.
  /// Base scores are lower than OSM-tagged hazards since this is inferred.
  List<RoadIncident> _inferHazardsFromSteps(
    List<Map<String, dynamic>> steps,
    double weatherSeverity,
  ) {
    // Accumulate total distance per road class; track best representative step
    final classDistance = <RoadClass, double>{};
    final classRepStep  = <RoadClass, Map<String, dynamic>>{};
    final classRoadName = <RoadClass, String>{};

    for (final step in steps) {
      final html      = step['html_instructions'] as String? ?? '';
      final distanceM = (step['distance']?['value'] as num?)?.toDouble() ?? 0.0;
      final roadName  = _extractRoadName(html);
      final roadClass = _classifyFromDirections(roadName, distanceM);

      classDistance[roadClass] = (classDistance[roadClass] ?? 0) + distanceM;

      // Keep the longest individual step as the representative location
      final repDist = (classRepStep[roadClass]?['distance']?['value'] as num?)
              ?.toDouble() ??
          0.0;
      if (distanceM > repDist) {
        classRepStep[roadClass]  = step;
        classRoadName[roadClass] = roadName;
      }
    }

    final incidents = <RoadIncident>[];

    for (final entry in classDistance.entries) {
      final roadClass = entry.key;
      final totalDist = entry.value;

      // Ignore trivial segments
      if (totalDist < 300) continue;

      final step     = classRepStep[roadClass]!;
      final startLoc = step['start_location'] as Map<String, dynamic>?;
      if (startLoc == null) continue;

      final lat      = (startLoc['lat'] as num).toDouble();
      final lon      = (startLoc['lng'] as num).toDouble();
      final roadName = classRoadName[roadClass] ?? 'road';

      // Inferred base scores — intentionally lower than OSM-tagged hazards
      final baseScore = switch (roadClass) {
        RoadClass.sideRoad => 0.50,
        RoadClass.mainRoad => 0.38,
        RoadClass.highway  => 0.28,
        RoadClass.unknown  => 0.35,
      };

      final hazardScore = _applyRoadWeight(baseScore, roadClass);
      final dangerScore = (weatherSeverity * hazardScore).clamp(0.0, 1.0);

      if (dangerScore < 0.10) continue;

      incidents.add(RoadIncident(
        lat: lat,
        lon: lon,
        type: 'Flood-prone road',
        description: _describe('Flood-prone road', roadName, roadClass),
        hazardScore: hazardScore,
        dangerScore: dangerScore,
        delaySeconds: 0,
        fromRoad: roadName,
        toRoad: '',
        roadClass: roadClass,
        source: HazardSource.directions,
      ));
    }

    return incidents;
  }

  // ── helpers ───────────────────────────────────────────────────────────────

  /// Extracts the last road name from Google's HTML step instructions.
  /// Instructions look like: "Turn <b>left</b> onto <b>Ring Road</b>"
  static String _extractRoadName(String html) {
    final matches = RegExp(r'<b>(.*?)</b>').allMatches(html);
    if (matches.isEmpty) return 'road';
    return matches.last.group(1)?.replaceAll(RegExp(r'<[^>]*>'), '') ?? 'road';
  }

  /// Classifies a road segment using its name and step distance as proxies.
  static RoadClass _classifyFromDirections(String roadName, double distanceM) {
    final lower = roadName.toLowerCase();
    if (lower.contains('ring road')    ||
        lower.contains('expressway')   ||
        lower.contains('highway')      ||
        lower.contains('motorway')     ||
        lower.contains('desert road')  ||
        lower.contains('october')      ||
        lower.contains('suez')         ||
        distanceM > 1800) {
      return RoadClass.highway;
    }
    if (distanceM > 400) return RoadClass.mainRoad;
    if (distanceM > 0)   return RoadClass.sideRoad;
    return RoadClass.unknown;
  }

  // ── OSM element parsing ───────────────────────────────────────────────────

  static RoadIncident? _parseOsmElement(
      Map<String, dynamic> el, double weatherSeverity) {
    try {
      final tags = el['tags'] as Map<String, dynamic>? ?? {};

      double lat, lon;
      if (el.containsKey('lat')) {
        lat = (el['lat'] as num).toDouble();
        lon = (el['lon'] as num).toDouble();
      } else {
        final center = el['center'] as Map<String, dynamic>?;
        if (center == null) return null;
        lat = (center['lat'] as num).toDouble();
        lon = (center['lon'] as num).toDouble();
      }

      final osmHighway = tags['highway'] as String? ?? '';
      final roadName   = (tags['name'] as String?)
                      ?? (tags['ref']  as String?)
                      ?? (osmHighway.isNotEmpty ? osmHighway : 'road');

      final roadClass             = _classifyRoad(osmHighway);
      final (type, baseScore)     = _classifyHazard(tags);
      final hazardScore           = _applyRoadWeight(baseScore, roadClass);
      final dangerScore           = (weatherSeverity * hazardScore).clamp(0.0, 1.0);

      return RoadIncident(
        lat: lat,
        lon: lon,
        type: type,
        description: _describe(type, roadName, roadClass),
        hazardScore: hazardScore,
        dangerScore: dangerScore,
        delaySeconds: 0,
        fromRoad: roadName,
        toRoad: '',
        roadClass: roadClass,
        source: HazardSource.osm,
      );
    } catch (_) {
      return null;
    }
  }

  static RoadClass _classifyRoad(String highway) {
    const highways = {'motorway', 'motorway_link', 'trunk', 'trunk_link'};
    const mainRoads = {
      'primary', 'primary_link', 'secondary', 'secondary_link'
    };
    const sideRoads = {
      'tertiary', 'tertiary_link', 'unclassified', 'residential',
      'living_street', 'service', 'track', 'path', 'ford',
    };

    if (highways.contains(highway))  return RoadClass.highway;
    if (mainRoads.contains(highway)) return RoadClass.mainRoad;
    if (sideRoads.contains(highway)) return RoadClass.sideRoad;
    return RoadClass.unknown;
  }

  static (String, double) _classifyHazard(Map<String, dynamic> tags) {
    if (tags['flood_prone'] == 'yes')                           return ('Flood-prone road',      0.80);
    if (tags['highway'] == 'ford' || tags['ford'] == 'yes')    return ('Ford / water crossing',  0.90);
    if (tags['tunnel'] == 'yes')                               return ('Tunnel',                 0.55);

    final surface = tags['surface'] as String? ?? '';
    if (surface == 'mud')    return ('Muddy surface',  0.85);
    if (surface == 'sand')   return ('Sandy surface',  0.70);
    if (surface == 'gravel') return ('Gravel surface', 0.50);
    if (surface == 'dirt' || surface == 'ground' ||
        surface == 'grass'  || surface == 'unpaved') {
      return ('Unpaved road', 0.60);
    }
    return ('Road hazard', 0.40);
  }

  static double _applyRoadWeight(double base, RoadClass cls) {
    final weight = switch (cls) {
      RoadClass.highway  => 1.15,
      RoadClass.mainRoad => 1.00,
      RoadClass.sideRoad => 0.75,
      RoadClass.unknown  => 0.85,
    };
    return (base * weight).clamp(0.0, 1.0);
  }

  static String _describe(String type, String road, RoadClass cls) {
    final classLabel = cls.label;
    return switch (type) {
      'Flood-prone road'      => '$classLabel "$road" is flood-prone — may be underwater',
      'Ford / water crossing' => 'Water crossing on $classLabel "$road" — impassable in heavy rain',
      'Tunnel'                => 'Tunnel on $classLabel "$road" — avoid in storms',
      'Muddy surface'         => '$classLabel "$road" has mud surface — impassable when wet',
      _                       => '$classLabel "$road" has unpaved surface — risky in rain/snow',
    };
  }

  static ({double s, double w, double n, double e}) _buildBbox(
    LatLng origin,
    List<LatLng> stops,
  ) {
    final lats = [origin.latitude,  ...stops.map((p) => p.latitude)];
    final lons = [origin.longitude, ...stops.map((p) => p.longitude)];
    return (
      s: lats.reduce((a, b) => a < b ? a : b) - _bboxPad,
      n: lats.reduce((a, b) => a > b ? a : b) + _bboxPad,
      w: lons.reduce((a, b) => a < b ? a : b) - _bboxPad,
      e: lons.reduce((a, b) => a > b ? a : b) + _bboxPad,
    );
  }

  static List<LatLng> _samplePolyline(List<LatLng> points, double intervalM) {
    if (points.isEmpty) return points;
    final sampled = <LatLng>[points.first];
    double accumulated = 0;
    for (int i = 1; i < points.length; i++) {
      accumulated += _haversineM(points[i - 1], points[i]);
      if (accumulated >= intervalM) {
        sampled.add(points[i]);
        accumulated = 0;
      }
    }
    if (sampled.last != points.last) sampled.add(points.last);
    return sampled;
  }

  static double _haversineM(LatLng a, LatLng b) {
    const R = 6371000.0;
    final dLat = (b.latitude  - a.latitude)  * math.pi / 180;
    final dLon = (b.longitude - a.longitude) * math.pi / 180;
    final x = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(a.latitude * math.pi / 180) *
        math.cos(b.latitude * math.pi / 180) *
        math.sin(dLon / 2) * math.sin(dLon / 2);
    return R * 2 * math.asin(math.sqrt(x));
  }
}
