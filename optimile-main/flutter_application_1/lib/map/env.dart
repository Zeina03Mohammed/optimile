class Env {
  // Google Maps / Directions API key
  static const googleMapsApiKey = 'AIzaSyCUqESrPfdNpQSCVoPITrphmbvic4hVKfk';

  // Default location (optional)
  static const defaultLat = 30.0444;
  static const defaultLng = 31.2357;

  // Directions API URL
  static const directionsApiUrl =
      'https://maps.googleapis.com/maps/api/directions/json';

  /// Backend API base URL. Empty = same origin (use when app is served from FastAPI).
  /// For local dev with separate backend use 'http://127.0.0.1:8000'.
  static const String backendBaseUrl = '';
}

