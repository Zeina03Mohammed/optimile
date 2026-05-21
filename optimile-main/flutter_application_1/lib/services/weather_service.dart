import 'dart:convert';
import 'package:http/http.dart' as http;
import '../env.dart';
import '../models/weather_data.dart';

/// Fetches real-time weather from the OpenWeatherMap "Current Weather" API.
///
/// Endpoint:
///   GET https://api.openweathermap.org/data/2.5/weather
///       ?lat=<lat>&lon=<lon>&appid=<key>&units=metric
class WeatherService {
  static const _timeout = Duration(seconds: 12);
  static const _cacheDuration = Duration(minutes: 10);

  WeatherData? _cached;
  DateTime? _lastFetch;

  bool _cacheValid(double lat, double lon) {
    if (_cached == null || _lastFetch == null) return false;
    if (DateTime.now().difference(_lastFetch!) >= _cacheDuration) return false;
    return (_cached!.lat - lat).abs() < 0.01 &&
        (_cached!.lon - lon).abs() < 0.01;
  }

  Future<WeatherData?> fetchCurrent(
    double latitude,
    double longitude, {
    bool force = false,
  }) async {
    if (!force && _cacheValid(latitude, longitude)) return _cached;

    final apiKey = Env.openWeatherApiKey.trim();
    if (apiKey.isEmpty) return null;

    final uri = Uri.https('api.openweathermap.org', '/data/2.5/weather', {
      'lat': latitude.toStringAsFixed(6),
      'lon': longitude.toStringAsFixed(6),
      'appid': apiKey,
      'units': 'metric',
    });

    try {
      final response = await http.get(uri).timeout(_timeout);
      if (response.statusCode != 200) return null;

      final body = jsonDecode(response.body) as Map<String, dynamic>;

      final weatherList = body['weather'] as List?;
      final first = weatherList?.first as Map<String, dynamic>?;
      final id = (first?['id'] as num?)?.toInt() ?? 800;
      final rawDesc = first?['description'] as String? ?? '';
      final owmCondition = rawDesc.isNotEmpty
          ? '${rawDesc[0].toUpperCase()}${rawDesc.substring(1)}'
          : null;

      final main    = body['main'] as Map<String, dynamic>? ?? {};
      final windMap = body['wind'] as Map<String, dynamic>? ?? {};
      final sys     = body['sys']  as Map<String, dynamic>? ?? {};

      final temp      = (main['temp']       as num?)?.toDouble() ?? 0.0;
      final feelsLike = (main['feels_like'] as num?)?.toDouble() ?? temp;
      final humidity  = (main['humidity']   as num?)?.toInt()    ?? 0;
      final windMs    = (windMap['speed']   as num?)?.toDouble() ?? 0.0;
      final windKmh   = windMs * 3.6;

      final now     = (body['dt']      as num?)?.toInt() ?? 0;
      final sunrise = (sys['sunrise']  as num?)?.toInt() ?? 0;
      final sunset  = (sys['sunset']   as num?)?.toInt() ?? 0;
      final isDay   = sunrise > 0 && now >= sunrise && now < sunset;

      final (_, backendCondition, severity) = _decode(id, isDay: isDay);

      _cached = WeatherData(
        lat: latitude,
        lon: longitude,
        tempC: temp,
        feelsLikeC: feelsLike,
        humidity: humidity,
        windSpeedKmh: windKmh,
        condition: owmCondition ?? (isDay ? 'Clear sky' : 'Clear night'),
        backendCondition: backendCondition,
        severity: severity,
        fetchedAt: DateTime.now(),
      );
      _lastFetch = DateTime.now();
      return _cached;
    } catch (_) {
      return null;
    }
  }

  static (String, String, double) _decode(int id, {required bool isDay}) {
    if (id == 200) return ('Thunderstorm with light rain',  'Storm', 0.85);
    if (id == 201) return ('Thunderstorm with rain',        'Storm', 0.90);
    if (id == 202) return ('Thunderstorm with heavy rain',  'Storm', 0.95);
    if (id == 210) return ('Light thunderstorm',            'Storm', 0.75);
    if (id == 211) return ('Thunderstorm',                  'Storm', 0.90);
    if (id == 212) return ('Heavy thunderstorm',            'Storm', 0.95);
    if (id == 221) return ('Ragged thunderstorm',           'Storm', 0.90);
    if (id == 230) return ('Thunderstorm + light drizzle',  'Storm', 0.80);
    if (id == 231) return ('Thunderstorm + drizzle',        'Storm', 0.85);
    if (id == 232) return ('Thunderstorm + heavy drizzle',  'Storm', 0.90);

    if (id == 300) return ('Light drizzle',         'Rainy', 0.25);
    if (id == 301) return ('Drizzle',               'Rainy', 0.35);
    if (id == 302) return ('Heavy drizzle',         'Rainy', 0.45);
    if (id == 310) return ('Light drizzle rain',    'Rainy', 0.30);
    if (id == 311) return ('Drizzle rain',          'Rainy', 0.40);
    if (id == 312) return ('Heavy drizzle rain',    'Rainy', 0.50);
    if (id == 313) return ('Shower rain & drizzle', 'Rainy', 0.50);
    if (id == 314) return ('Heavy shower & drizzle','Rainy', 0.60);
    if (id == 321) return ('Shower drizzle',        'Rainy', 0.40);

    if (id == 500) return ('Light rain',        'Rainy', 0.40);
    if (id == 501) return ('Moderate rain',     'Rainy', 0.55);
    if (id == 502) return ('Heavy rain',        'Rainy', 0.70);
    if (id == 503) return ('Very heavy rain',   'Rainy', 0.80);
    if (id == 504) return ('Extreme rain',      'Rainy', 0.90);
    if (id == 511) return ('Freezing rain',     'Rainy', 0.75);
    if (id == 520) return ('Light showers',     'Rainy', 0.40);
    if (id == 521) return ('Showers',           'Rainy', 0.55);
    if (id == 522) return ('Heavy showers',     'Rainy', 0.70);
    if (id == 531) return ('Ragged showers',    'Rainy', 0.60);

    if (id == 600) return ('Light snow',        'Snowy', 0.50);
    if (id == 601) return ('Snow',              'Snowy', 0.65);
    if (id == 602) return ('Heavy snow',        'Snowy', 0.80);
    if (id == 611) return ('Sleet',             'Snowy', 0.70);
    if (id == 612) return ('Light shower sleet','Snowy', 0.60);
    if (id == 613) return ('Shower sleet',      'Snowy', 0.65);
    if (id == 615) return ('Light rain & snow', 'Snowy', 0.55);
    if (id == 616) return ('Rain & snow',       'Snowy', 0.65);
    if (id == 620) return ('Light snow showers','Snowy', 0.50);
    if (id == 621) return ('Snow showers',      'Snowy', 0.65);
    if (id == 622) return ('Heavy snow showers','Snowy', 0.80);

    if (id == 701) return ('Mist',              'Fog',   0.30);
    if (id == 711) return ('Smoke',             'Fog',   0.35);
    if (id == 721) return ('Haze',              'Fog',   0.25);
    if (id == 731) return ('Dust/sand',         'Fog',   0.45);
    if (id == 741) return ('Fog',               'Fog',   0.45);
    if (id == 751) return ('Sand',              'Fog',   0.40);
    if (id == 761) return ('Dust',              'Fog',   0.40);
    if (id == 762) return ('Volcanic ash',      'Fog',   0.70);
    if (id == 771) return ('Squalls',           'Storm', 0.75);
    if (id == 781) return ('Tornado',           'Storm', 1.00);

    if (id == 800) {
      return isDay
          ? ('Clear sky',   'Sunny', 0.00)
          : ('Clear night', 'Sunny', 0.00);
    }

    if (id == 801) return ('Few clouds (11–25%)',       'Partly cloudy', 0.05);
    if (id == 802) return ('Scattered clouds (25–50%)', 'Partly cloudy', 0.10);
    if (id == 803) return ('Broken clouds (51–84%)',    'Cloudy',        0.15);
    if (id == 804) return ('Overcast (85–100%)',        'Cloudy',        0.20);

    return ('Unknown', 'Sunny', 0.00);
  }
}
