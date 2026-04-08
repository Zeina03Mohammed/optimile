import 'dart:convert';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;
import '../models/road_incident.dart';

/// Detects weather-vulnerable road segments using the OSM Overpass API.
/// No API key required.
///
/// OSM highway tag classification used:
///   motorway / trunk              → RoadClass.highway   (high-speed, critical)
///   primary / secondary           → RoadClass.mainRoad  (arterial / city main)
///   tertiary / residential /
///   service / unclassified / ...  → RoadClass.sideRoad  (local streets)
///
/// Hazard scores are multiplied by a road-class weight so that the same
/// flood tag on a motorway scores much higher than on a side road.
class RoadHazardService {
  static const _endpoint = 'https://overpass-api.de/api/interpreter';
  static const _timeout  = Duration(seconds: 15);

  static const double minSeverityToCheck = 0.30;
  static const double _bboxPad = 0.04; // ~4 km buffer

  Future<List<RoadIncident>> fetchIncidents({
    required LatLng currentLocation,
    required List<LatLng> stops,
  }) async {
    final bbox = _buildBbox(currentLocation, stops);

    // Query hazard-tagged ways AND their highway type so we can classify them.
    final query = '''
[out:json][timeout:14];
(
  way["flood_prone"="yes"](${bbox.s},${bbox.w},${bbox.n},${bbox.e});
  way["highway"="ford"](${bbox.s},${bbox.w},${bbox.n},${bbox.e});
  way["tunnel"="yes"](${bbox.s},${bbox.w},${bbox.n},${bbox.e});
  way["surface"~"^(unpaved|dirt|gravel|mud|sand|ground|grass)\$"](${bbox.s},${bbox.w},${bbox.n},${bbox.e});
  node["ford"="yes"](${bbox.s},${bbox.w},${bbox.n},${bbox.e});
);
out center tags;
''';

    try {
      final response = await http
          .post(
            Uri.parse(_endpoint),
            headers: {'Content-Type': 'text/plain'},
            body: query,
          )
          .timeout(_timeout);

      if (response.statusCode != 200) return [];

      final body     = jsonDecode(response.body) as Map<String, dynamic>;
      final elements = body['elements'] as List? ?? [];

      return elements
          .map((e) => _parseElement(e as Map<String, dynamic>))
          .whereType<RoadIncident>()
          .toList();
    } catch (_) {
      return [];
    }
  }

  // ── parsing ───────────────────────────────────────────────────────────────

  static RoadIncident? _parseElement(Map<String, dynamic> el) {
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

      // Road name: prefer name, then ref number, then the highway class value
      final osmHighway = tags['highway'] as String? ?? '';
      final roadName   = (tags['name'] as String?)
                      ?? (tags['ref']  as String?)
                      ?? (osmHighway.isNotEmpty ? osmHighway : 'road');

      final roadClass               = _classifyRoad(osmHighway);
      final (type, baseScore)       = _classifyHazard(tags);
      final hazardScore             = _applyRoadWeight(baseScore, roadClass);

      return RoadIncident(
        lat: lat,
        lon: lon,
        type: type,
        description: _describe(type, roadName, roadClass),
        hazardScore: hazardScore,
        delaySeconds: 0,
        fromRoad: roadName,
        toRoad: '',
        roadClass: roadClass,
      );
    } catch (_) {
      return null;
    }
  }

  // ── road classification ───────────────────────────────────────────────────

  /// Maps an OSM `highway` value to one of three road classes.
  ///
  /// OSM highway hierarchy (high → low importance):
  ///   motorway > trunk > primary > secondary >
  ///   tertiary > unclassified > residential > service > track
  static RoadClass _classifyRoad(String highway) {
    const highways = {
      'motorway', 'motorway_link',
      'trunk',    'trunk_link',
    };
    const mainRoads = {
      'primary',   'primary_link',
      'secondary', 'secondary_link',
    };
    const sideRoads = {
      'tertiary',      'tertiary_link',
      'unclassified',
      'residential',
      'living_street',
      'service',
      'track',
      'path',
      'ford',
    };

    if (highways.contains(highway))  return RoadClass.highway;
    if (mainRoads.contains(highway)) return RoadClass.mainRoad;
    if (sideRoads.contains(highway)) return RoadClass.sideRoad;
    return RoadClass.unknown;
  }

  // ── hazard type from OSM tags ─────────────────────────────────────────────

  static (String, double) _classifyHazard(Map<String, dynamic> tags) {
    if (tags['flood_prone'] == 'yes') { return ('Flood-prone road', 0.80); }
    if (tags['highway'] == 'ford' || tags['ford'] == 'yes') {
      return ('Ford / water crossing', 0.90);
    }
    if (tags['tunnel'] == 'yes') { return ('Tunnel', 0.55); }

    final surface = tags['surface'] as String? ?? '';
    if (surface == 'mud')    { return ('Muddy surface',  0.85); }
    if (surface == 'sand')   { return ('Sandy surface',  0.70); }
    if (surface == 'gravel') { return ('Gravel surface', 0.50); }
    if (surface == 'dirt'    ||
        surface == 'ground'  ||
        surface == 'grass'   ||
        surface == 'unpaved') {
      return ('Unpaved road', 0.60);
    }
    return ('Road hazard', 0.40);
  }

  /// Scales the base hazard score by road importance.
  ///
  /// A flooded motorway is far more disruptive than a flooded side road:
  ///   highway  → ×1.15  (up to 1.0 cap)
  ///   mainRoad → ×1.00  (unchanged)
  ///   sideRoad → ×0.75  (less critical — easier to detour)
  ///   unknown  → ×0.85
  static double _applyRoadWeight(double base, RoadClass cls) {
    final weight = switch (cls) {
      RoadClass.highway  => 1.15,
      RoadClass.mainRoad => 1.00,
      RoadClass.sideRoad => 0.75,
      RoadClass.unknown  => 0.85,
    };
    return (base * weight).clamp(0.0, 1.0);
  }

  // ── description ───────────────────────────────────────────────────────────

  static String _describe(String type, String road, RoadClass cls) {
    final classLabel = cls.label; // "Highway", "Main road", "Side road"
    return switch (type) {
      'Flood-prone road'      => '$classLabel "$road" is flood-prone — may be underwater',
      'Ford / water crossing' => 'Water crossing on $classLabel "$road" — impassable in heavy rain',
      'Tunnel'                => 'Tunnel on $classLabel "$road" — avoid in storms',
      'Muddy surface'         => '$classLabel "$road" has mud surface — impassable when wet',
      _                       => '$classLabel "$road" has unpaved surface — risky in rain/snow',
    };
  }

  // ── bbox ──────────────────────────────────────────────────────────────────

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
}
