/// Live weather reading fetched from OpenWeatherMap.
///
/// [severity]  0.0–1.0 — how badly weather affects driving; drives re-opt weight.
/// [lat]/[lon] — coordinates this reading belongs to (used for cache invalidation).
class WeatherData {
  const WeatherData({
    required this.lat,
    required this.lon,
    required this.tempC,
    required this.feelsLikeC,
    required this.humidity,
    required this.windSpeedKmh,
    required this.condition,
    required this.backendCondition,
    required this.severity,
    required this.fetchedAt,
  });

  final double lat;
  final double lon;

  /// Actual air temperature (°C).
  final double tempC;

  /// Apparent / "feels like" temperature (°C).
  final double feelsLikeC;

  /// Relative humidity (%).
  final int humidity;

  /// Wind speed at 10 m height (km/h).
  final double windSpeedKmh;

  /// Human-readable condition shown in the UI chip, e.g. "Heavy rain".
  final String condition;

  /// Short label sent to the backend optimizer, e.g. "Rainy", "Storm".
  final String backendCondition;

  /// Driving difficulty weight: 0.0 (clear) → 1.0 (extreme storm).
  /// Used as the severity argument when triggering re-optimization.
  final double severity;

  /// When this reading was fetched.
  final DateTime fetchedAt;
}
