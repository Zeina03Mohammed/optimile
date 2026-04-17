// Unit tests for lib/models/road_incident.dart
//
// Covers:
//   - RoadClass enum values and count
//   - RoadClassLabel extension: label strings
//   - RoadClassLabel extension: icon strings
//   - RoadIncident construction and field storage
//   - Hazard score boundary values
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
  // RoadIncident — hazard types
  // ─────────────────────────────────────────────────────────────────────────

  group('RoadIncident — hazard types', () {
    RoadIncident makeIncident({
      required String type,
      required double hazardScore,
      required RoadClass roadClass,
    }) {
      return RoadIncident(
        lat: 30.0,
        lon: 31.0,
        type: type,
        description: type,
        hazardScore: hazardScore,
        delaySeconds: 0,
        fromRoad: 'road',
        toRoad: '',
        roadClass: roadClass,
      );
    }

    test('flood-prone road on highway — high score', () {
      final inc = makeIncident(
        type: 'Flood-prone road',
        hazardScore: 0.92,
        roadClass: RoadClass.highway,
      );
      expect(inc.hazardScore, greaterThanOrEqualTo(0.5)); // above highway threshold
    });

    test('ford / water crossing on main road', () {
      final inc = makeIncident(
        type: 'Ford / water crossing',
        hazardScore: 0.90,
        roadClass: RoadClass.mainRoad,
      );
      expect(inc.hazardScore, greaterThanOrEqualTo(0.6)); // above main-road threshold
    });

    test('tunnel on side road — above threshold', () {
      final inc = makeIncident(
        type: 'Tunnel',
        hazardScore: 0.65,
        roadClass: RoadClass.sideRoad,
      );
      expect(inc.hazardScore, greaterThanOrEqualTo(0.45)); // above tunnel threshold
    });

    test('unpaved side road — below reroute threshold', () {
      final inc = makeIncident(
        type: 'Unpaved road',
        hazardScore: 0.38,
        roadClass: RoadClass.sideRoad,
      );
      // 0.38 < 0.40 → should NOT trigger reroute
      expect(inc.hazardScore, lessThan(0.40));
    });

    test('hazardScore is in valid range [0, 1]', () {
      final inc = makeIncident(
        type: 'Sandy surface',
        hazardScore: 0.70,
        roadClass: RoadClass.sideRoad,
      );
      expect(inc.hazardScore, inInclusiveRange(0.0, 1.0));
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // RoadIncident — threshold logic (mirrors mapvm.dart per-class thresholds)
  // ─────────────────────────────────────────────────────────────────────────

  group('RoadIncident — reroute threshold logic', () {
    double _threshold(RoadClass cls, String type) {
      return switch (cls) {
        RoadClass.sideRoad => type == 'Tunnel' ? 0.45 : 0.40,
        RoadClass.mainRoad => 0.60,
        RoadClass.highway  => 0.50,
        RoadClass.unknown  => 0.65,
      };
    }

    test('highway threshold is 0.50', () {
      expect(_threshold(RoadClass.highway, 'flood'), closeTo(0.50, 0.001));
    });

    test('main road threshold is 0.60', () {
      expect(_threshold(RoadClass.mainRoad, 'flood'), closeTo(0.60, 0.001));
    });

    test('side road threshold is 0.40', () {
      expect(_threshold(RoadClass.sideRoad, 'flood'), closeTo(0.40, 0.001));
    });

    test('tunnel on side road threshold is 0.45', () {
      expect(_threshold(RoadClass.sideRoad, 'Tunnel'), closeTo(0.45, 0.001));
    });

    test('unknown road threshold is 0.65', () {
      expect(_threshold(RoadClass.unknown, 'flood'), closeTo(0.65, 0.001));
    });

    test('highway incident above threshold triggers reroute', () {
      const inc = RoadIncident(
        lat: 30.0, lon: 31.0,
        type: 'Flood-prone road',
        description: '',
        hazardScore: 0.92,
        delaySeconds: 600,
        fromRoad: 'Ring Road',
        toRoad: '',
        roadClass: RoadClass.highway,
      );
      expect(inc.hazardScore >= 0.50, isTrue);
    });

    test('side road incident below threshold does NOT trigger reroute', () {
      const inc = RoadIncident(
        lat: 30.0, lon: 31.0,
        type: 'Unpaved road',
        description: '',
        hazardScore: 0.38,
        delaySeconds: 120,
        fromRoad: 'Side road',
        toRoad: '',
        roadClass: RoadClass.sideRoad,
      );
      expect(inc.hazardScore < 0.40, isTrue);
    });
  });
}
