const express = require('express');
const app = express();
const path = require('path');
const cors = require('cors');
const admin = require('firebase-admin');

/* ===============================
   FIREBASE ADMIN (BACKEND ONLY)
   =============================== */
const serviceAccount = require('../../optimile-backend/serviceAccountKey.json');

admin.initializeApp({
  credential: admin.credential.cert(serviceAccount),
});

const db = admin.firestore();

/* ===============================
   MIDDLEWARE
   =============================== */
app.use(cors());
app.use(express.json());

/* ===============================
   STATIC FRONTEND
   - Supports both "public" and "Public" folder names
   =============================== */
const publicDirLower = path.join(__dirname, 'public');
const publicDirUpper = path.join(__dirname, 'Public');

let publicDir = publicDirLower;
try {
  // If "public" doesn't exist, fallback to "Public"
  require('fs').accessSync(publicDirLower);
} catch {
  publicDir = publicDirUpper;
}

app.use(express.static(publicDir));

/* ===============================
   HOME PAGE
   =============================== */
app.get('/', (req, res) => {
  // If you have index.html directly in public/Public, this will serve it.
  // Otherwise, it will still allow direct navigation to your template folder.
  res.sendFile(path.join(publicDir, 'index.html'), (err) => {
    if (err) {
      // fallback: if your template is nested like public/Ready-Bootstrap-Dashboard-master/index.html
      res.sendFile(
        path.join(publicDir, 'Ready-Bootstrap-Dashboard-master', 'index.html')
      );
    }
  });
});

/* ===============================
   API: GET USERS
   =============================== */
app.get('/api/users', async (req, res) => {
  try {
    const snap = await db.collection('users').get();
    const users = snap.docs.map(doc => ({ id: doc.id, ...doc.data() }));
    res.json(users);
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

/* ===============================
   API: GET DELIVERIES
   =============================== */
app.get('/api/deliveries', async (req, res) => {
  try {
    const snap = await db.collection('deliveries').get();
    const deliveries = snap.docs.map(doc => ({ id: doc.id, ...doc.data() }));
    res.json(deliveries);
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

/* ===============================
   API: GET DRIVERS + delivered count
   - driver is any user with role === "driver"
   - counts completed deliveries by:
       (status === "completed") OR (completed_at exists)
   - matches delivery to driver by:
       (driver_id === userDocId) OR (driver_email === user.email)
   =============================== */
app.get('/api/drivers', async (req, res) => {
  try {
    const usersSnap = await db.collection('users').get();
    const deliveriesSnap = await db.collection('deliveries').get();

    const deliveries = deliveriesSnap.docs.map(d => ({ id: d.id, ...d.data() }));
    const drivers = [];

    usersSnap.forEach(doc => {
      const user = doc.data();

      if (user?.role === 'driver') {
        const deliveredCount = deliveries.filter(d => {
          const isDelivered = (d.status === 'completed') || (d.completed_at != null);
          const matchesDriver =
            (d.driver_id && d.driver_id === doc.id) ||
            (d.driver_email && user.email && d.driver_email === user.email);

          return isDelivered && matchesDriver;
        }).length;

        drivers.push({
          id: doc.id,
          name: user.name || '-',
          email: user.email || '-',
          phone: user.phone || '-',
          packagesDelivered: deliveredCount,
        });
      }
    });

    res.json(drivers);
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

/* ===============================
   START SERVER
   =============================== */
const PORT = process.env.PORT || 3000;
app.listen(PORT, () => {
  console.log(`Server running on http://localhost:${PORT}`);
});
