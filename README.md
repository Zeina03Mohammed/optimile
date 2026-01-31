# 🚚 Optimile - Delivery Route Optimizer

A mobile app designed to help delivery drivers plan and optimize their delivery routes. The app provides real-time mapping, route planning, and an admin dashboard for managing deliveries.

---

## 📱 What Does This App Do?

**Optimile** helps delivery companies and drivers:
- **Plan delivery routes** on an interactive map
- **Search for delivery locations** using Google Places
- **View optimized routes** between multiple stops
- **Track deliveries** in real-time
- **Manage operations** through an admin dashboard

**Two User Types:**
1. **Admin** - Can view statistics and manage all deliveries
2. **Driver** - Can plan routes and navigate to delivery locations

---

## 🎯 Prerequisites (What You Need Before Starting)

Before you can run this app, you need to install and set up the following:

### 1. Install Flutter
Flutter is the framework that powers this app.

**Windows:**
1. Download Flutter from: https://docs.flutter.dev/get-started/install/windows
2. Extract the zip file to `C:\src\flutter`
3. Add Flutter to your PATH:
   - Search "Environment Variables" in Windows
   - Edit "Path" variable
   - Add `C:\src\flutter\bin`
4. Open Command Prompt and run: `flutter doctor`

**Mac:**
1. Download Flutter from: https://docs.flutter.dev/get-started/install/macos
2. Extract and add to PATH in your `.zshrc` or `.bash_profile`:
   ```bash
   export PATH="$PATH:~/development/flutter/bin"
   ```
3. Run: `flutter doctor`

### 2. Install an IDE (Code Editor)
Choose one:
- **VS Code** (Recommended for beginners): https://code.visualstudio.com/
  - Install the "Flutter" extension from the Extensions marketplace
- **Android Studio**: https://developer.android.com/studio

### 3. Set Up Android Emulator or iOS Simulator

**For Android (Windows/Mac):**
1. Install Android Studio
2. Open Android Studio → More Actions → Virtual Device Manager
3. Create a new virtual device (e.g., Pixel 5)
4. Download a system image (e.g., Android 13)

**For iOS (Mac only):**
1. Install Xcode from the Mac App Store
2. Open Xcode → Preferences → Components → Download a simulator
3. Run: `sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer`
4. Run: `sudo xcodebuild -runFirstLaunch`

### 4. Verify Installation
Run this command in your terminal:
```bash
flutter doctor
```

You should see green checkmarks. If you see any issues, follow the instructions to fix them.

---

## 🔧 Installation & Setup

### Step 1: Get the Code
```bash
# Navigate to where you want the project
cd C:\Users\YourName\Projects

# Clone or download this repository
# If you have the zip file, extract it here
```

### Step 2: Open the Project
```bash
cd optimile
```

### Step 3: Install Dependencies
This downloads all the packages the app needs:
```bash
flutter pub get
```

### Step 4: Set Up Firebase

Firebase is used for user authentication and database.

1. **Go to Firebase Console:**
   - Visit: https://console.firebase.google.com/
   - Sign in with your Google account
   - Click "Add project" or select an existing project

2. **Add Android App:**
   - Click the Android icon
   - **Package name:** `com.example.flutter_application_1` (found in `android/app/build.gradle.kts`)
   - Download `google-services.json`
   - Place it in: `android/app/google-services.json`

3. **Add iOS App (if using Mac):**
   - Click the iOS icon
   - **Bundle ID:** `com.example.flutterApplication1` (found in `ios/Runner.xcodeproj`)
   - Download `GoogleService-Info.plist`
   - Place it in: `ios/Runner/GoogleService-Info.plist`

4. **Enable Authentication:**
   - In Firebase Console, go to "Authentication"
   - Click "Get started"
   - Enable "Email/Password" sign-in method

5. **Create Firestore Database:**
   - Go to "Firestore Database"
   - Click "Create database"
   - Choose "Start in test mode"
   - Select a location close to you

6. **Configure FlutterFire:**
   ```bash
   # Install FlutterFire CLI
   dart pub global activate flutterfire_cli

   # Run configuration (this updates firebase_options.dart)
   flutterfire configure
   ```

### Step 5: Set Up Google Maps API

The app needs Google Maps to display the map and search for places.

1. **Go to Google Cloud Console:**
   - Visit: https://console.cloud.google.com/
   - Select your Firebase project (or create a new one)

2. **Enable Required APIs:**
   - Go to "APIs & Services" → "Library"
   - Search and enable these APIs:
     - ✅ **Maps SDK for Android**
     - ✅ **Maps SDK for iOS**
     - ✅ **Directions API**
     - ✅ **Places API**
     - ✅ **Geocoding API**

3. **Create API Key:**
   - Go to "APIs & Services" → "Credentials"
   - Click "Create Credentials" → "API Key"
   - Copy your API key (looks like: `AIza...`)

4. **Restrict API Key (Important for Security):**
   - Click on your API key to edit it
   - Under "API restrictions", select "Restrict key"
   - Select only the APIs you enabled above
   - Under "Application restrictions":
     - For Android: Add your package name and SHA-1 key
     - For iOS: Add your bundle ID

5. **Add API Key to the App:**

   **For Android:**
   - Open: `android/app/src/main/AndroidManifest.xml`
   - Find the line with `android:name="com.google.android.geo.API_KEY"`
   - Replace `YOUR_API_KEY` with your actual API key

   **For iOS:**
   - Open: `ios/Runner/AppDelegate.swift`
   - Find the line with `GMSServices.provideAPIKey`
   - Replace `YOUR_API_KEY` with your actual API key

   **For the App Code:**
   - Open: `lib/env.dart`
   - Replace the `googleMapsApiKey` value with your API key:
     ```dart
     static const googleMapsApiKey = 'YOUR_API_KEY_HERE';
     ```

### Step 6: Create Admin User

Before you can log in, you need to create users in Firebase.

1. **Go to Firebase Console → Authentication**
2. **Click "Add user"**
3. **Enter email and password** (e.g., `admin@optimile.com` / `admin123`)
4. **Copy the User UID** (long string like: `xYz123...`)
5. **Go to Firestore Database**
6. **Create a collection called "users"**
7. **Add a document with the User UID as the document ID**
8. **Add these fields:**
   ```
   email: admin@optimile.com
   name: Admin User
   role: admin
   ```

9. **Create a Driver User (Optional):**
   - Repeat steps 2-8 but set `role: driver`

---

## ▶️ Running the App

### Option 1: Using Command Line
```bash
# Make sure an emulator/simulator is running first
flutter run
```

### Option 2: Using VS Code
1. Open the project in VS Code
2. Select a device from the bottom-right corner (Android/iOS)
3. Press `F5` or click "Run → Start Debugging"

### Option 3: Using Android Studio
1. Open the project in Android Studio
2. Select a device from the device dropdown
3. Click the green "Run" button

---

## 📂 Project Structure (What's What?)

```
optimile/
├── lib/                          # Main app code
│   ├── main.dart                # App entry point
│   ├── env.dart                 # API keys and configuration
│   ├── firebase_options.dart   # Firebase configuration
│   │
│   ├── models/                  # Data structures
│   │   ├── user_model.dart     # User data
│   │   └── stop_model.dart     # Delivery stop data
│   │
│   ├── services/                # Business logic
│   │   ├── auth_service.dart   # Login/signup
│   │   ├── firestore_service.dart  # Database operations
│   │   └── places_service.dart # Google Places search
│   │
│   ├── viewmodel/               # App logic (MVVM pattern)
│   │   ├── authvm.dart         # Authentication logic
│   │   └── mapvm.dart          # Map and route logic
│   │
│   └── view/                    # User interface screens
│       ├── login.dart          # Login/signup screen
│       ├── admin.dart          # Admin dashboard
│       └── map_screen.dart     # Driver map screen
│
├── android/                     # Android-specific files
├── ios/                        # iOS-specific files
├── web/                        # Web-specific files
├── windows/                    # Windows-specific files
├── macos/                      # macOS-specific files
├── linux/                      # Linux-specific files
│
├── pubspec.yaml               # App dependencies
├── firebase.json              # Firebase configuration
└── README.md                  # This file!
```

---

## 🎮 How to Use the App

### For Admins:
1. **Login** with your admin credentials
2. **View Dashboard** with delivery statistics
3. **Monitor** active drivers and deliveries

### For Drivers:
1. **Login** with your driver credentials
2. **View the Map** showing your current location
3. **Search for Places:**
   - Click the search icon (top-right menu)
   - Type an address or place name
   - Select from suggestions
4. **Add Delivery Stops:**
   - Tap anywhere on the map to add a stop
   - OR use the search to find and add a location
5. **Plan Route:**
   - Click "Optimize Route" in the menu
   - The app will calculate the best order
   - View the route line on the map
6. **View Route List:**
   - Open the side menu
   - See all stops in optimized order
7. **Navigate:**
   - Click on any stop to see details
   - Use your preferred navigation app to get there

---

## 🔑 Key Features

### Authentication
- ✅ Email/password login
- ✅ Role-based access (Admin vs Driver)
- ✅ Secure Firebase authentication

### Map Features
- ✅ Real-time location tracking
- ✅ Interactive Google Maps
- ✅ Tap to add delivery stops
- ✅ Route visualization with polylines
- ✅ Place search with autocomplete

### Route Optimization
- ✅ Calculate optimal delivery order
- ✅ Distance and duration estimates
- ✅ Turn-by-turn directions support

### Admin Dashboard
- ✅ Delivery statistics
- ✅ Driver status monitoring
- ✅ Operational overview

---

## ⚠️ Troubleshooting

### "Gradle build failed" (Android)
```bash
cd android
./gradlew clean
cd ..
flutter clean
flutter pub get
```

### "CocoaPods not installed" (iOS)
```bash
sudo gem install cocoapods
cd ios
pod install
cd ..
```

### "No devices found"
- Make sure an emulator is running
- Check: `flutter devices`
- Restart your IDE

### Map doesn't show / Blank screen
- Verify your Google Maps API key is correct in:
  - `lib/env.dart`
  - `android/app/src/main/AndroidManifest.xml`
  - `ios/Runner/AppDelegate.swift`
- Make sure you enabled all required APIs in Google Cloud Console

### "API key not valid"
- Check that you enabled all required APIs
- Wait 5-10 minutes for API key activation
- Verify API restrictions are not blocking your app

### Places search doesn't work
- Make sure "Places API" is enabled in Google Cloud Console
- Check your API key has proper restrictions
- Verify your billing is enabled (Google requires it even for free tier)

### Can't login / Firebase errors
- Verify `google-services.json` (Android) or `GoogleService-Info.plist` (iOS) is in the correct location
- Re-run: `flutterfire configure`
- Check that Authentication and Firestore are enabled in Firebase Console

### App crashes on startup
```bash
flutter clean
flutter pub get
flutter run
```

---

## 🌐 Important URLs

- **Flutter Documentation:** https://docs.flutter.dev/
- **Firebase Console:** https://console.firebase.google.com/
- **Google Cloud Console:** https://console.cloud.google.com/
- **Flutter Packages:** https://pub.dev/

---

## 📦 Dependencies Used

This app uses these packages (defined in `pubspec.yaml`):

- **google_maps_flutter** - Display maps
- **firebase_core** - Firebase initialization
- **firebase_auth** - User authentication
- **cloud_firestore** - Database
- **provider** - State management
- **http** - API calls
- **flutter_typeahead** - Search autocomplete
- **flutter_polyline_points** - Route visualization
- **geolocator** - GPS location
- **uuid** - Generate unique IDs

---

## 📝 Common Tasks

### Update App Name
1. Open `pubspec.yaml`
2. Change `name: flutter_application_1` to your app name
3. Update `AndroidManifest.xml` and `Info.plist` with the new package name

### Change App Icon
1. Add your icon image to `assets/icon.png`
2. Install icon generator: `flutter pub add flutter_launcher_icons`
3. Configure in `pubspec.yaml`
4. Run: `flutter pub run flutter_launcher_icons`

### Add New Dependencies
1. Find package on https://pub.dev/
2. Add to `pubspec.yaml` under `dependencies:`
3. Run: `flutter pub get`

### Build Release APK (Android)
```bash
flutter build apk --release
# Find APK in: build/app/outputs/flutter-apk/app-release.apk
```

### Build for iOS (Mac only)
```bash
flutter build ios --release
# Then open ios/Runner.xcworkspace in Xcode and archive
```

---

## 🆘 Getting Help

If you're stuck:
1. **Read error messages carefully** - they often tell you exactly what's wrong
2. **Google the error** - someone has probably solved it before
3. **Check Flutter documentation** - https://docs.flutter.dev/
4. **Ask on Stack Overflow** - Tag your question with `flutter`
5. **Flutter Discord** - https://discord.gg/flutter

---

## 🔒 Security Notes

⚠️ **Important:**
- **NEVER commit API keys to public repositories**
- The `lib/env.dart` file contains a Google Maps API key and should be in `.gitignore`
- `google-services.json` and `GoogleService-Info.plist` should also be in `.gitignore`
- Always restrict your API keys in Google Cloud Console
- Use Firebase Security Rules in production to protect your database

---

## 📄 License

This project is for educational purposes. Modify and use as needed for your delivery business.

---

## 🎓 Learning Resources

**New to Flutter?**
- [Flutter Basics Course](https://www.youtube.com/watch?v=1ukSR1GRtMU) - Free YouTube course
- [Flutter Codelabs](https://docs.flutter.dev/codelabs) - Step-by-step tutorials
- [Widget Catalog](https://docs.flutter.dev/development/ui/widgets) - See all available widgets

**Understanding the Code:**
- **MVVM Pattern** - Separates UI (View) from logic (ViewModel)
- **Provider** - Manages app state and updates UI automatically
- **Firebase** - Backend-as-a-Service (no server needed!)
- **Google Maps API** - Provides mapping and location services

---

## ✅ Quick Start Checklist

- [ ] Install Flutter
- [ ] Install Android Studio / VS Code
- [ ] Set up Android Emulator or iOS Simulator
- [ ] Run `flutter doctor` (all green checks)
- [ ] Clone/download this project
- [ ] Run `flutter pub get`
- [ ] Create Firebase project
- [ ] Download and add `google-services.json` (Android)
- [ ] Download and add `GoogleService-Info.plist` (iOS)
- [ ] Enable Authentication in Firebase
- [ ] Create Firestore database
- [ ] Run `flutterfire configure`
- [ ] Enable Google Maps APIs
- [ ] Create and add Google Maps API key
- [ ] Create admin user in Firebase
- [ ] Run `flutter run`
- [ ] Test login and map features

---

**Happy Coding! 🚀**

If this README helped you, please star the project!
