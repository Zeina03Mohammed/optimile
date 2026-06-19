class Env {
  // Google Maps / Directions API key
  static const googleMapsApiKey = 'AIzaSyDS_rhIBewLgsjJaKdlcb1bzN-u168rYGs';

  // Default location (Cairo, Egypt)
  static const defaultLat = 30.0444;
  static const defaultLng = 31.2357;

  // Backend base URL â€“ switch for committee demo:
  // â€¢ iOS Simulator (app + backend on same Mac): 'http://127.0.0.1:8000'
  // â€¢ Real iPhone (same Wiâ€‘Fi as Mac): 'http://YOUR_MAC_IP:8000' (e.g. 192.168.1.x)
  // â€¢ Android emulator: 'http://10.0.2.2:8000'
  // If backend unreachable, Simulate button uses offline demo.//'http://192.168.1.13:8000'
  static const backendBaseUrl = 'http://10.0.2.2:8000';

  // Directions API URL
  static const directionsApiUrl =
      'https://maps.googleapis.com/maps/api/directions/json';

  // OpenWeatherMap API key â€” required for live weather readings.
  static const openWeatherApiKey = '601475e7a589300b7d822f2e51d86f88';

}

