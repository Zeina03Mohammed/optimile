class Env {
  // Google Maps / Directions API key
  static const googleMapsApiKey = 'AIzaSyBf4OnBLeOxsI97IzCRJRJf6mJSquq85Ts';

  // Default location (Cairo, Egypt)
  static const defaultLat = 30.0444;
  static const defaultLng = 31.2357;

  // Backend base URL – switch for committee demo:
  // • iOS Simulator (app + backend on same Mac): 'http://127.0.0.1:8000'
  // • Real iPhone (same Wi‑Fi as Mac): 'http://YOUR_MAC_IP:8000' (e.g. 192.168.1.x)
  // • Android emulator: 'http://10.0.2.2:8000'
  // If backend unreachable, Simulate button uses offline demo.
  static const backendBaseUrl = 'http://192.168.1.13:8000';

  // Directions API URL
  static const directionsApiUrl =
      'https://maps.googleapis.com/maps/api/directions/json';

  // OpenWeatherMap API key — required for live weather readings.
  static const openWeatherApiKey = '601475e7a589300b7d822f2e51d86f88';

}

