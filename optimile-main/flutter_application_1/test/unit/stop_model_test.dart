// Unit tests for lib/models/stop_model.dart
//
// Covers:
//   - Stop construction with required and optional fields
//   - Stop.copyWith() preserves unmodified fields
//   - Stop.toPayload() produces correct map keys and values
//   - Stop.fromPlaceDetails() factory constructor
//   - RouteModel construction and copyWith()
//   - EventLogEntry construction with all XAI fields
//   - XaiCategory enum values
//   - StopConfig construction
//
// Run:
//   flutter test test/unit/stop_model_test.dart

import 'package:flutter/material.dart' show TimeOfDay;
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:flutter_application_1/models/stop_model.dart';

void main() {
  // ─────────────────────────────────────────────────────────────────────────
  // Stop
  // ─────────────────────────────────────────────────────────────────────────

  group('Stop — constructor', () {
    const loc = LatLng(30.0444, 31.2357);

    test('creates stop with required location', () {
      final stop = Stop(location: loc);
      expect(stop.location, equals(loc));
    });

    test('default values', () {
      final stop = Stop(location: loc);
      expect(stop.id, equals(''));
      expect(stop.title, isNull);
      expect(stop.sequenceOrder, equals(0));
      expect(stop.status, equals('pending'));
      expect(stop.estimatedTime, isNull);
      expect(stop.actualTime, isNull);
      expect(stop.isFragile, isFalse);
      expect(stop.windowStartMin, equals(0));
      expect(stop.windowEndMin, equals(24 * 60));
    });

    test('custom values are stored correctly', () {
      final stop = Stop(
        location: loc,
        title: 'Depot',
        id: 'doc_123',
        sequenceOrder: 3,
        status: 'completed',
        estimatedTime: 30.0,
        actualTime: 35.5,
        isFragile: true,
        windowStartMin: 480,
        windowEndMin: 720,
      );
      expect(stop.title, equals('Depot'));
      expect(stop.id, equals('doc_123'));
      expect(stop.sequenceOrder, equals(3));
      expect(stop.status, equals('completed'));
      expect(stop.estimatedTime, equals(30.0));
      expect(stop.actualTime, equals(35.5));
      expect(stop.isFragile, isTrue);
      expect(stop.windowStartMin, equals(480));
      expect(stop.windowEndMin, equals(720));
    });
  });

  group('Stop — copyWith', () {
    const loc = LatLng(30.0444, 31.2357);

    test('copyWith preserves all unchanged fields', () {
      final original = Stop(
        location: loc,
        title: 'Original',
        isFragile: true,
        windowStartMin: 300,
        windowEndMin: 600,
      );
      final copy = original.copyWith();
      expect(copy.location, equals(original.location));
      expect(copy.title, equals(original.title));
      expect(copy.isFragile, equals(original.isFragile));
      expect(copy.windowStartMin, equals(original.windowStartMin));
      expect(copy.windowEndMin, equals(original.windowEndMin));
    });

    test('copyWith overrides specified fields only', () {
      final original = Stop(location: loc, title: 'Old', isFragile: false);
      final copy = original.copyWith(title: 'New', isFragile: true);
      expect(copy.title, equals('New'));
      expect(copy.isFragile, isTrue);
      expect(copy.location, equals(original.location)); // unchanged
    });

    test('copyWith with status change', () {
      final stop = Stop(location: loc, status: 'pending');
      final updated = stop.copyWith(status: 'completed');
      expect(updated.status, equals('completed'));
      expect(stop.status, equals('pending')); // original unchanged
    });
  });

  group('Stop — toPayload', () {
    const loc = LatLng(30.0444, 31.2357);

    test('payload contains lat, lng, is_fragile, window_start, window_end', () {
      final stop = Stop(
        location: loc,
        isFragile: true,
        windowStartMin: 480,
        windowEndMin: 720,
        title: 'Test Stop',
      );
      final payload = stop.toPayload();
      expect(payload['lat'], equals(30.0444));
      expect(payload['lng'], equals(31.2357));
      expect(payload['is_fragile'], isTrue);
      expect(payload['window_start'], equals(480));
      expect(payload['window_end'], equals(720));
      expect(payload['title'], equals('Test Stop'));
    });

    test('payload has correct key names (snake_case for backend)', () {
      final stop = Stop(location: loc);
      final payload = stop.toPayload();
      expect(payload.containsKey('lat'), isTrue);
      expect(payload.containsKey('lng'), isTrue);
      expect(payload.containsKey('is_fragile'), isTrue);
      expect(payload.containsKey('window_start'), isTrue);
      expect(payload.containsKey('window_end'), isTrue);
    });

    test('non-fragile stop payload has is_fragile=false', () {
      final stop = Stop(location: loc, isFragile: false);
      expect(stop.toPayload()['is_fragile'], isFalse);
    });
  });

  group('Stop — fromPlaceDetails', () {
    const loc = LatLng(30.0626, 31.2497);

    PlaceDetails makePlaceDetails() => PlaceDetails(
      name: 'Heliopolis',
      address: 'Cairo, Egypt',
      location: loc,
    );

    test('creates stop from PlaceDetails with correct location', () {
      final stop = Stop.fromPlaceDetails(makePlaceDetails());
      expect(stop.location.latitude, closeTo(30.0626, 0.0001));
      expect(stop.location.longitude, closeTo(31.2497, 0.0001));
    });

    test('title comes from PlaceDetails.name', () {
      final stop = Stop.fromPlaceDetails(makePlaceDetails());
      expect(stop.title, equals('Heliopolis'));
    });

    test('isFragile defaults to false', () {
      final stop = Stop.fromPlaceDetails(makePlaceDetails());
      expect(stop.isFragile, isFalse);
    });

    test('isFragile can be overridden', () {
      final stop = Stop.fromPlaceDetails(makePlaceDetails(), isFragile: true);
      expect(stop.isFragile, isTrue);
    });

    test('sequenceOrder is passed correctly', () {
      final stop = Stop.fromPlaceDetails(makePlaceDetails(), sequenceOrder: 3);
      expect(stop.sequenceOrder, equals(3));
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // RouteModel
  // ─────────────────────────────────────────────────────────────────────────

  group('RouteModel', () {
    test('default name and empty stops', () {
      final route = RouteModel(id: '1');
      expect(route.name, equals('Car 1'));
      expect(route.stops, isEmpty);
    });

    test('custom name', () {
      final route = RouteModel(id: '2', name: 'Truck 2');
      expect(route.name, equals('Truck 2'));
    });

    test('copyWith preserves id', () {
      final route = RouteModel(id: 'abc', name: 'Car 1');
      final copy = route.copyWith(name: 'Car 2');
      expect(copy.id, equals('abc'));
      expect(copy.name, equals('Car 2'));
    });

    test('copyWith with stops creates independent list', () {
      const loc = LatLng(30.0, 31.0);
      final stop = Stop(location: loc);
      final route = RouteModel(id: '1', stops: [stop]);
      final copy = route.copyWith();
      copy.stops.add(Stop(location: const LatLng(30.1, 31.1)));
      // original must not be affected
      expect(route.stops.length, equals(1));
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // XaiCategory enum
  // ─────────────────────────────────────────────────────────────────────────

  group('XaiCategory', () {
    test('all six categories exist', () {
      const categories = XaiCategory.values;
      expect(categories.contains(XaiCategory.optimization), isTrue);
      expect(categories.contains(XaiCategory.hazard),       isTrue);
      expect(categories.contains(XaiCategory.weather),      isTrue);
      expect(categories.contains(XaiCategory.deviation),    isTrue);
      expect(categories.contains(XaiCategory.fleet),        isTrue);
      expect(categories.contains(XaiCategory.info),         isTrue);
    });

    test('XaiCategory has exactly 6 values', () {
      expect(XaiCategory.values.length, equals(6));
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // EventLogEntry
  // ─────────────────────────────────────────────────────────────────────────

  group('EventLogEntry', () {
    test('required fields stored correctly', () {
      final entry = EventLogEntry(
        icon: '✓',
        message: 'Route optimized',
        time: '08:01:00',
      );
      expect(entry.icon, equals('✓'));
      expect(entry.message, equals('Route optimized'));
      expect(entry.time, equals('08:01:00'));
    });

    test('default category is info', () {
      final entry = EventLogEntry(icon: 'i', message: 'msg', time: '00:00:00');
      expect(entry.category, equals(XaiCategory.info));
    });

    test('optional XAI fields default to null', () {
      final entry = EventLogEntry(icon: 'i', message: 'msg', time: '00:00:00');
      expect(entry.confidence, isNull);
      expect(entry.impactMin, isNull);
      expect(entry.counterfactual, isNull);
      expect(entry.causalChain, isNull);
    });

    test('structured XAI fields stored correctly', () {
      final entry = EventLogEntry(
        icon: '🔁',
        message: 'Hazard reroute applied',
        time: '09:15:30',
        category: XaiCategory.hazard,
        confidence: 0.88,
        impactMin: 4.5,
        counterfactual: 'Without rerouting, ETA +4.5 min',
        causalChain: 'OSM hazard → ALNS+BF → safer route',
      );
      expect(entry.category, equals(XaiCategory.hazard));
      expect(entry.confidence, closeTo(0.88, 0.001));
      expect(entry.impactMin, closeTo(4.5, 0.001));
      expect(entry.counterfactual, contains('rerouting'));
      expect(entry.causalChain, contains('ALNS'));
    });

    test('optimization category entry', () {
      final entry = EventLogEntry(
        icon: '✓',
        message: 'Route reordered',
        time: '08:05:00',
        category: XaiCategory.optimization,
        confidence: 0.82,
        impactMin: 3.2,
      );
      expect(entry.category, equals(XaiCategory.optimization));
      expect(entry.confidence, greaterThan(0.0));
      expect(entry.impactMin, greaterThan(0.0));
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // StopConfig
  // ─────────────────────────────────────────────────────────────────────────

  group('StopConfig', () {
    test('stores isFragile', () {
      final config = StopConfig(isFragile: true, start: null, end: null);
      expect(config.isFragile, isTrue);
    });

    test('stores time window', () {
      const startTime = TimeOfDay(hour: 8, minute: 0);
      const endTime   = TimeOfDay(hour: 12, minute: 0);
      final config = StopConfig(isFragile: false, start: startTime, end: endTime);
      expect(config.start!.hour, equals(8));
      expect(config.end!.hour, equals(12));
    });

    test('null time values allowed', () {
      final config = StopConfig(isFragile: false, start: null, end: null);
      expect(config.start, isNull);
      expect(config.end, isNull);
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // PlaceDetails & Place
  // ─────────────────────────────────────────────────────────────────────────

  group('PlaceDetails', () {
    test('default type and status', () {
      final pd = PlaceDetails(
        name: 'Maadi',
        address: 'Cairo, Egypt',
        location: const LatLng(30.0131, 31.2089),
      );
      expect(pd.type, equals('Unknown'));
      expect(pd.status, equals('Unknown'));
    });

    test('custom type and status', () {
      final pd = PlaceDetails(
        name: 'Gas Station',
        address: '123 Road',
        location: const LatLng(30.0, 31.0),
        type: 'fuel',
        status: 'operational',
      );
      expect(pd.type, equals('fuel'));
      expect(pd.status, equals('operational'));
    });
  });

  group('Place', () {
    test('stores placeId and description', () {
      final place = Place(placeId: 'ChIJxxx', description: 'Tahrir Square');
      expect(place.placeId, equals('ChIJxxx'));
      expect(place.description, equals('Tahrir Square'));
    });
  });
}
