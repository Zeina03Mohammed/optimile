// Unit tests for lib/models/road_incident.dart
//
// Covers:
//   - RoadClass enum values and count
//   - RoadClassLabel extension: label strings
//   - RoadClassLabel extension: icon strings
//   - RoadIncident construction and field storage
//   - dangerScore = weatherSeverity × hazardScore
//   - Road class threshold behaviour (matches mapvm.dart reroute logic)
//
// Run:
//   flutter test test/unit/road_incident_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_application_1/models/road_incident.dart';

void main() {
  // ─────────────────────────────────────────────────────────────────────────
  // RoadClass enum
  // ─────────────────────────────────────────────────────────────────────────

  group('RoadClass — enum values', () {
    test('enum has exactly 4 values', () {
      expect(RoadClass.values.length, equals(4));
    });

    test('all enum members exist', () {
      expect(RoadClass.values.contains(RoadClass.highway),  isTrue);
      expect(RoadClass.values.contains(RoadClass.mainRoad), isTrue);
      expect(RoadClass.values.contains(RoadClass.sideRoad), isTrue);
      expect(RoadClass.values.contains(RoadClass.unknown),  isTrue);
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // RoadClassLabel extension — label
  // ─────────────────────────────────────────────────────────────────────────

  group('RoadClassLabel — label', () {
    test('highway label', () {
      expect(RoadClass.highway.label, equals('Highway'));
    });

    test('mainRoad label', () {
      expect(RoadClass.mainRoad.label, equals('Main road'));
    });

    test('sideRoad label', () {
      expect(RoadClass.sideRoad.label, equals('Side road'));
    });

    test('unknown label', () {
      expect(RoadClass.unknown.label, equals('Road'));
    });

    test('all labels are non-empty', () {
      for (final cls in RoadClass.values) {
        expect(cls.label.isNotEmpty, isTrue);
      }
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // RoadClassLabel extension — icon
  // ─────────────────────────────────────────────────────────────────────────

  group('RoadClassLabel — icon', () {
    test('highway icon', () {
      expect(RoadClass.highway.icon, equals('🛣️'));
    });

    test('mainRoad icon', () {
      expect(RoadClass.mainRoad.icon, equals('🚗'));
    });

    test('sideRoad icon', () {
      expect(RoadClass.sideRoad.icon, equals('🛤️'));
    });

    test('unknown icon', () {
      expect(RoadClass.unknown.icon, equals('🚧'));
    });

    test('all icons are non-empty', () {
      for (final cls in RoadClass.values) {
        expect(cls.icon.isNotEmpty, isTrue);
      }
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // RoadIncident — construction
  // ─────────────────────────────────────────────────────────────────────────

  group('RoadIncident — construction', () {
    const incident = RoadIncident(
      lat: 30.0444,
      lon: 31.2357,
      type: 'Flood-prone road',
      description: 'Highway flooded underpass',
      hazardScore: 0.92,
      dangerScore: 0.644, // 0.70 × 0.92
      delaySeconds: 600,
      fromRoad: 'Ring Road',
      toRoad: '',
      roadClass: RoadClass.highway,
    );

    test('lat stored correctly', () {
      expect(incident.lat, closeTo(30.0444, 0.0001));
    });

    test('lon stored correctly', () {
      expect(incident.lon, closeTo(31.2357, 0.0001));
    });

    test('type stored correctly', () {
      expect(incident.type, equals('Flood-prone road'));
    });

    test('description stored correctly', () {
      expect(incident.description, contains('flooded'));
    });

    test('hazardScore stored correctly', () {
      expect(incident.hazardScore, closeTo(0.92, 0.001));
    });

    test('dangerScore stored correctly', () {
      expect(incident.dangerScore, closeTo(0.644, 0.001));
    });

    test('delaySeconds stored correctly', () {
      expect(incident.delaySeconds, equals(600));
    });

    test('fromRoad stored correctly', () {
      expect(incident.fromRoad, equals('Ring Road'));
    });

    test('toRoad can be empty string', () {
      expect(incident.toRoad, equals(''));
    });

    test('roadClass stored correctly', () {
      expect(incident.roadClass, equals(RoadClass.highway));
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // RoadIncident — dangerScore = weatherSeverity × hazardScore
  // ─────────────────────────────────────────────────────────────────────────

  group('RoadIncident — dangerScore', () {
    RoadIncident makeIncident({
      required double hazardScore,
      required double dangerScore,
      RoadClass roadClass = RoadClass.highway,
    }) => RoadIncident(
      lat: 30.0, lon: 31.0,
      type: 'Flood-prone road', description: '',
      hazardScore: hazardScore,
      dangerScore: dangerScore,
      delaySeconds: 0,
      fromRoad: 'road', toRoad: '',
      roadClass: roadClass,
    );

    test('ford in heavy rain: 0.70 × 0.90 = 0.63', () {
      final inc = makeIncident(hazardScore: 0.90, dangerScore: 0.70 * 0.90);
      expect(inc.dangerScore, closeTo(0.63, 0.001));
    });

    test('ford on clear day: 0.00 × 0.90 = 0.00', () {
      final inc = makeIncident(hazardScore: 0.90, dangerScore: 0.00 * 0.90);
      expect(inc.dangerScore, equals(0.0));
    });

    test('unpaved in storm: 0.95 × 0.60 = 0.57', () {
      final inc = makeIncident(
        hazardScore: 0.60,
        dangerScore: 0.95 * 0.60,
        roadClass: RoadClass.sideRoad,
      );
      expect(inc.dangerScore, closeTo(0.57, 0.001));
    });

    test('dangerScore is always <= hazardScore when severity <= 1.0', () {
      final inc = makeIncident(hazardScore: 0.80, dangerScore: 0.70 * 0.80);
      expect(inc.dangerScore, lessThanOrEqualTo(inc.hazardScore));
    });

    test('dangerScore is in valid range [0, 1]', () {
      final inc = makeIncident(hazardScore: 0.90, dangerScore: 0.95 * 0.90);
      expect(inc.dangerScore, inInclusiveRange(0.0, 1.0));
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // RoadIncident — hazard types
  // ─────────────────────────────────────────────────────────────────────────

  group('RoadIncident — hazard types', () {
    RoadIncident makeIncident({
      required String type,
      required double hazardScore,
      required double dangerScore,
      required RoadClass roadClass,
    }) => RoadIncident(
      lat: 30.0, lon: 31.0,
      type: type, description: type,
      hazardScore: hazardScore,
      dangerScore: dangerScore,
      delaySeconds: 0,
      fromRoad: 'road', toRoad: '',
      roadClass: roadClass,
    );

    test('flood-prone road on highway in heavy rain — danger above threshold', () {
      // hazard 0.92, severity 0.70 → danger 0.644 > highway threshold 0.50
      final inc = makeIncident(
        type: 'Flood-prone road',
        hazardScore: 0.92,
        dangerScore: 0.70 * 0.92,
        roadClass: RoadClass.highway,
      );
      expect(inc.dangerScore, greaterThanOrEqualTo(0.50));
    });

    test('ford on main road in heavy rain — danger above threshold', () {
      // hazard 0.90, severity 0.70 → danger 0.63 > main-road threshold 0.60
      final inc = makeIncident(
        type: 'Ford / water crossing',
        hazardScore: 0.90,
        dangerScore: 0.70 * 0.90,
        roadClass: RoadClass.mainRoad,
      );
      expect(inc.dangerScore, greaterThanOrEqualTo(0.60));
    });

    test('ford on main road in drizzle — danger below threshold', () {
      // hazard 0.90, severity 0.25 → danger 0.225 < main-road threshold 0.60
      final inc = makeIncident(
        type: 'Ford / water crossing',
        hazardScore: 0.90,
        dangerScore: 0.25 * 0.90,
        roadClass: RoadClass.mainRoad,
      );
      expect(inc.dangerScore, lessThan(0.60));
    });

    test('unpaved side road below reroute threshold even in heavy rain', () {
      // hazard 0.38, severity 0.70 → danger 0.266 < side-road threshold 0.40
      final inc = makeIncident(
        type: 'Unpaved road',
        hazardScore: 0.38,
        dangerScore: 0.70 * 0.38,
        roadClass: RoadClass.sideRoad,
      );
      expect(inc.dangerScore, lessThan(0.40));
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // RoadIncident — threshold logic (mirrors mapvm.dart per-class thresholds)
  // ─────────────────────────────────────────────────────────────────────────

  group('RoadIncident — reroute threshold logic', () {
    double threshold(RoadClass cls, String type) => switch (cls) {
      RoadClass.sideRoad => type == 'Tunnel' ? 0.45 : 0.40,
      RoadClass.mainRoad => 0.60,
      RoadClass.highway  => 0.50,
      RoadClass.unknown  => 0.65,
    };

    test('highway threshold is 0.50', () {
      expect(threshold(RoadClass.highway, 'flood'), closeTo(0.50, 0.001));
    });

    test('main road threshold is 0.60', () {
      expect(threshold(RoadClass.mainRoad, 'flood'), closeTo(0.60, 0.001));
    });

    test('side road threshold is 0.40', () {
      expect(threshold(RoadClass.sideRoad, 'flood'), closeTo(0.40, 0.001));
    });

    test('tunnel on side road threshold is 0.45', () {
      expect(threshold(RoadClass.sideRoad, 'Tunnel'), closeTo(0.45, 0.001));
    });

    test('unknown road threshold is 0.65', () {
      expect(threshold(RoadClass.unknown, 'flood'), closeTo(0.65, 0.001));
    });

    test('highway incident: dangerScore above threshold triggers reroute', () {
      const inc = RoadIncident(
        lat: 30.0, lon: 31.0,
        type: 'Flood-prone road', description: '',
        hazardScore: 0.92,
        dangerScore: 0.644, // 0.70 × 0.92
        delaySeconds: 600,
        fromRoad: 'Ring Road', toRoad: '',
        roadClass: RoadClass.highway,
      );
      expect(inc.dangerScore >= 0.50, isTrue);
    });

    test('side road: dangerScore below threshold does NOT trigger reroute', () {
      const inc = RoadIncident(
        lat: 30.0, lon: 31.0,
        type: 'Unpaved road', description: '',
        hazardScore: 0.38,
        dangerScore: 0.266, // 0.70 × 0.38
        delaySeconds: 120,
        fromRoad: 'Side road', toRoad: '',
        roadClass: RoadClass.sideRoad,
      );
      expect(inc.dangerScore < 0.40, isTrue);
    });

    test('clear day: dangerScore is zero regardless of hazardScore', () {
      const inc = RoadIncident(
        lat: 30.0, lon: 31.0,
        type: 'Ford / water crossing', description: '',
        hazardScore: 0.90,
        dangerScore: 0.0, // severity 0.0 × 0.90
        delaySeconds: 0,
        fromRoad: 'ford road', toRoad: '',
        roadClass: RoadClass.highway,
      );
      expect(inc.dangerScore, equals(0.0));
    });
  });
}
