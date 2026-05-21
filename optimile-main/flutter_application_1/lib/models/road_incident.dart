/// Road class derived from OSM's `highway` tag.
/// Used to distinguish how critical a hazard is based on road importance.
enum RoadClass {
  highway,   // motorway, trunk — high speed, many vehicles
  mainRoad,  // primary, secondary — intercity / city arterials
  sideRoad,  // tertiary, residential, service, unclassified — local streets
  unknown,
}

extension RoadClassLabel on RoadClass {
  String get label => switch (this) {
    RoadClass.highway  => 'Highway',
    RoadClass.mainRoad => 'Main road',
    RoadClass.sideRoad => 'Side road',
    RoadClass.unknown  => 'Road',
  };

  String get icon => switch (this) {
    RoadClass.highway  => '🛣️',
    RoadClass.mainRoad => '🚗',
    RoadClass.sideRoad => '🛤️',
    RoadClass.unknown  => '🚧',
  };
}

/// A road segment with a weather-related hazard, sourced from OpenStreetMap.
class RoadIncident {
  const RoadIncident({
    required this.lat,
    required this.lon,
    required this.type,
    required this.description,
    required this.hazardScore,
    required this.dangerScore,
    required this.delaySeconds,
    required this.fromRoad,
    required this.toRoad,
    required this.roadClass,
  });

  /// Incident coordinates.
  final double lat;
  final double lon;

  /// Short hazard type, e.g. "Flood-prone road", "Ford / water crossing".
  final String type;

  /// Human-readable description.
  final String description;

  /// 0.0–1.0 hazard weight — scaled by both hazard type AND road class.
  final double hazardScore;

  /// 0.0–1.0 combined danger: hazardScore × weather severity.
  /// Zero on a clear day, full hazardScore in the worst weather.
  final double dangerScore;

  /// Estimated extra delay in seconds (0 for OSM-sourced data).
  final int delaySeconds;

  /// Road name / ref where hazard starts.
  final String fromRoad;

  /// Road name / ref where hazard ends (empty for point hazards).
  final String toRoad;

  /// Road classification derived from OSM highway tag.
  final RoadClass roadClass;
}
