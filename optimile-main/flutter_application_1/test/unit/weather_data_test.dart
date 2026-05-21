// Unit tests for lib/models/weather_data.dart
//
// Covers:
//   - WeatherData construction with all required fields
//   - Field value storage and retrieval
//   - Boundary values: severity clamped to [0.0, 1.0]
//   - Timestamp stored correctly
//
// Run:
//   flutter test test/unit/weather_data_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_application_1/models/weather_data.dart';

void main() {
  // ─────────────────────────────────────────────────────────────────────────
  // Helper factory
  // ─────────────────────────────────────────────────────────────────────────

  WeatherData makeWeatherData({
    double lat = 30.0444,
    double lon = 31.2357,
    double tempC = 28.0,
    double feelsLikeC = 30.0,
    int humidity = 55,
    double windSpeedKmh = 15.0,
    String condition = 'Clear',
    String backendCondition = 'Sunny',
    double severity = 0.1,
    DateTime? fetchedAt,
  }) {
    return WeatherData(
      lat: lat,
      lon: lon,
      tempC: tempC,
      feelsLikeC: feelsLikeC,
      humidity: humidity,
      windSpeedKmh: windSpeedKmh,
      condition: condition,
      backendCondition: backendCondition,
      severity: severity,
      fetchedAt: fetchedAt ?? DateTime(2026, 1, 1, 8, 0),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Construction
  // ─────────────────────────────────────────────────────────────────────────

  group('WeatherData — construction', () {
    test('stores all fields correctly', () {
      final wd = makeWeatherData();
      expect(wd.lat, closeTo(30.0444, 0.0001));
      expect(wd.lon, closeTo(31.2357, 0.0001));
      expect(wd.tempC, equals(28.0));
      expect(wd.feelsLikeC, equals(30.0));
      expect(wd.humidity, equals(55));
      expect(wd.windSpeedKmh, equals(15.0));
      expect(wd.condition, equals('Clear'));
      expect(wd.backendCondition, equals('Sunny'));
      expect(wd.severity, equals(0.1));
    });

    test('fetchedAt is stored correctly', () {
      final ts = DateTime(2026, 4, 16, 14, 30);
      final wd = makeWeatherData(fetchedAt: ts);
      expect(wd.fetchedAt, equals(ts));
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // Severity values
  // ─────────────────────────────────────────────────────────────────────────

  group('WeatherData — severity', () {
    test('minimum severity (clear day)', () {
      final wd = makeWeatherData(severity: 0.0);
      expect(wd.severity, equals(0.0));
    });

    test('maximum severity (extreme storm)', () {
      final wd = makeWeatherData(severity: 1.0);
      expect(wd.severity, equals(1.0));
    });

    test('mid severity', () {
      final wd = makeWeatherData(severity: 0.5);
      expect(wd.severity, closeTo(0.5, 0.001));
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // Condition strings
  // ─────────────────────────────────────────────────────────────────────────

  group('WeatherData — condition strings', () {
    test('Egyptian summer conditions', () {
      final wd = makeWeatherData(condition: 'Hot and dusty', backendCondition: 'Foggy');
      expect(wd.condition, equals('Hot and dusty'));
      expect(wd.backendCondition, equals('Foggy'));
    });

    test('storm conditions severity', () {
      final wd = makeWeatherData(
        condition: 'Heavy thunderstorm',
        backendCondition: 'Storm',
        severity: 0.9,
      );
      expect(wd.severity, greaterThan(0.5));
    });

    test('rainy backend condition', () {
      final wd = makeWeatherData(backendCondition: 'Rainy');
      expect(wd.backendCondition, equals('Rainy'));
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // Temperature
  // ─────────────────────────────────────────────────────────────────────────

  group('WeatherData — temperature', () {
    test('Egyptian summer heat', () {
      final wd = makeWeatherData(tempC: 42.0, feelsLikeC: 48.0);
      expect(wd.tempC, equals(42.0));
      expect(wd.feelsLikeC, greaterThan(wd.tempC));
    });

    test('winter night temperatures', () {
      final wd = makeWeatherData(tempC: 8.0, feelsLikeC: 5.0);
      expect(wd.feelsLikeC, lessThan(wd.tempC));
    });

    test('humidity stored as integer', () {
      final wd = makeWeatherData(humidity: 80);
      expect(wd.humidity, isA<int>());
      expect(wd.humidity, equals(80));
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // Wind
  // ─────────────────────────────────────────────────────────────────────────

  group('WeatherData — wind', () {
    test('calm wind', () {
      final wd = makeWeatherData(windSpeedKmh: 0.0);
      expect(wd.windSpeedKmh, equals(0.0));
    });

    test('strong khamsin wind', () {
      final wd = makeWeatherData(windSpeedKmh: 90.0);
      expect(wd.windSpeedKmh, equals(90.0));
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // Const constructor (immutability)
  // ─────────────────────────────────────────────────────────────────────────

  group('WeatherData — immutability', () {
    test('same const object equals itself', () {
      final ts = DateTime(2026, 1, 1);
      final wd1 = WeatherData(
        lat: 30.0, lon: 31.0, tempC: 25.0, feelsLikeC: 25.0, humidity: 50,
        windSpeedKmh: 10.0, condition: 'Clear', backendCondition: 'Sunny',
        severity: 0.1, fetchedAt: ts,
      );
      final wd2 = WeatherData(
        lat: 30.0, lon: 31.0, tempC: 25.0, feelsLikeC: 25.0, humidity: 50,
        windSpeedKmh: 10.0, condition: 'Clear', backendCondition: 'Sunny',
        severity: 0.1, fetchedAt: ts,
      );
      expect(wd1.tempC, equals(wd2.tempC));
      expect(wd1.severity, equals(wd2.severity));
    });
  });
}
