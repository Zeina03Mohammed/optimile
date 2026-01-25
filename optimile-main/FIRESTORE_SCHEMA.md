# Firestore Database Schema for Optimile

## Collections Structure

### 1. users
```
users/{userId}
├── email: string
├── role: string (driver/admin)
├── name: string
├── phone: string
├── created_at: timestamp
```

**Note:** Password is managed by Firebase Authentication, not stored in Firestore.

### 2. deliveries
```
deliveries/{deliveryId}
├── driver_id: string (reference to users collection)
├── driver_email: string
├── status: string (pending/in_progress/completed/cancelled)
├── created_at: timestamp
├── started_at: timestamp (nullable)
├── completed_at: timestamp (nullable)
├── total_distance: number
└── vehicle_id: string (reference to vehicles collection, nullable)
```

### 3. delivery_stops (subcollection of deliveries)
```
deliveries/{deliveryId}/stops/{stopId}
├── address: string
├── latitude: number
├── longitude: number
├── sequence_order: number (position in route)
├── estimated_time: number (minutes)
├── actual_time: number (minutes, nullable)
├── status: string (pending/completed/skipped)
└── metadata: map
    ├── customer_name: string
    ├── notes: string
    └── phone: string
```

### 4. routes (subcollection of deliveries)
```
deliveries/{deliveryId}/routes/{routeId}
├── original_cost: number (minutes)
├── optimized_cost: number (minutes)
├── time_saved: number (minutes)
├── created_at: timestamp
└── optimization_data: map
    ├── algorithm: string
    ├── iterations: number
    └── route_order: array of stop_ids
```

### 5. vehicles
```
vehicles/{vehicleId}
├── driver_id: string (reference to users collection)
├── type: string (motorcycle/scooter/car/van/bike)
├── plate_number: string
├── is_active: boolean
└── created_at: timestamp
```

## Firestore Security Rules

```javascript
rules_version = '2';
service cloud.firestore {
  match /databases/{database}/documents {

    // Users collection
    match /users/{userId} {
      allow read: if request.auth != null;
      allow create: if request.auth != null;
      allow update, delete: if request.auth.uid == userId ||
                               get(/databases/$(database)/documents/users/$(request.auth.uid)).data.role == 'admin';
    }

    // Deliveries collection
    match /deliveries/{deliveryId} {
      allow read: if request.auth != null;
      allow create: if request.auth != null;
      allow update: if request.auth != null &&
                      (request.auth.uid == resource.data.driver_id ||
                       get(/databases/$(database)/documents/users/$(request.auth.uid)).data.role == 'admin');
      allow delete: if get(/databases/$(database)/documents/users/$(request.auth.uid)).data.role == 'admin';

      // Subcollection: stops
      match /stops/{stopId} {
        allow read, write: if request.auth != null;
      }

      // Subcollection: routes
      match /routes/{routeId} {
        allow read, write: if request.auth != null;
      }
    }

    // Vehicles collection
    match /vehicles/{vehicleId} {
      allow read: if request.auth != null;
      allow create: if request.auth != null;
      allow update, delete: if request.auth != null &&
                               (request.auth.uid == resource.data.driver_id ||
                                get(/databases/$(database)/documents/users/$(request.auth.uid)).data.role == 'admin');
    }
  }
}
```

## Indexes Required

Create these composite indexes in Firebase Console:

1. **deliveries** collection:
   - `driver_id` (Ascending) + `created_at` (Descending)
   - `status` (Ascending) + `created_at` (Descending)

2. **delivery_stops** subcollection:
   - `sequence_order` (Ascending)
   - `status` (Ascending) + `sequence_order` (Ascending)

3. **vehicles** collection:
   - `driver_id` (Ascending) + `is_active` (Descending)
