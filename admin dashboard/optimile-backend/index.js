const express = require('express');
const path = require('path');
const admin = require('firebase-admin');
const bcrypt = require('bcryptjs');

const app = express();
app.use(express.json());

/* ===============================
   SERVE FRONTEND
   =============================== */
app.use('/assets', express.static(path.join(__dirname, '../Public/assets')));
app.use('/js', express.static(path.join(__dirname, '../Public/js')));

// ✅ IMPORTANT: serve ALL Public files so /index.html works
app.use(express.static(path.join(__dirname, '../Public')));

app.get('/', (req, res) =>
  res.sendFile(path.join(__dirname, '../Public/index.html'))
);

// ✅ ADD: allow direct access to /index.html (fix Cannot GET /index.html)
app.get('/index.html', (req, res) =>
  res.sendFile(path.join(__dirname, '../Public/index.html'))
);

app.get('/drivers.html', (req, res) =>
  res.sendFile(path.join(__dirname, '../Public/drivers.html'))
);
app.get('/forms.html', (req, res) =>
  res.sendFile(path.join(__dirname, '../Public/forms.html'))
);
app.get('/tables.html', (req, res) =>
  res.sendFile(path.join(__dirname, '../Public/tables.html'))
);

/* ===============================
   FIREBASE ADMIN (FIRESTORE)
   =============================== */
const serviceAccount = require('./serviceAccountKey.json');

admin.initializeApp({
  credential: admin.credential.cert(serviceAccount),
});

const db = admin.firestore();

/* ===============================
   ✅ AUTH MIDDLEWARE (Bearer Token)
   Frontend sends:
     Authorization: Bearer <Firebase ID Token>
   =============================== */
async function requireAuth(req, res, next) {
  try {
    const header = req.headers.authorization || '';
    const match = header.match(/^Bearer\s+(.+)$/i);

    if (!match) {
      // helpful debug
      console.log('❌ Missing Authorization header for:', req.method, req.originalUrl);
      return res.status(401).json({ error: 'Missing Authorization Bearer token' });
    }

    const idToken = match[1].trim();
    const decoded = await admin.auth().verifyIdToken(idToken);

    req.user = decoded; // { uid, email, ... }
    next();
  } catch (err) {
    console.error('Auth error:', err.message);
    return res.status(401).json({ error: 'Invalid or expired token', details: err.message });
  }
}

/* ===============================
   ✅ ADMIN CHECK
   IMPORTANT FIX:
   - First: try users/{uid}
   - If not found: fallback search users where email == decoded.email
   This solves the common mismatch between Auth UID and Firestore docId.
   =============================== */
async function requireAdmin(req, res, next) {
  try {
    const uid = req.user?.uid;
    const email = (req.user?.email || '').toLowerCase();

    if (!uid) return res.status(401).json({ error: 'Not authenticated' });

    // 1) Try doc id = uid
    let snap = await db.collection('users').doc(uid).get();

    // 2) Fallback: match by email
    if (!snap.exists && email) {
      const emailSnap = await db
        .collection('users')
        .where('email', '==', email)
        .limit(1)
        .get();

      if (!emailSnap.empty) {
        snap = emailSnap.docs[0];
      }
    }

    if (!snap.exists && snap.data === undefined) {
      console.log('❌ Admin check: user not found in Firestore. uid=', uid, 'email=', email);
      return res.status(403).json({ error: 'User not found in Firestore (uid/email not matched)' });
    }

    const data = snap.data ? snap.data() : snap.data(); // handles both DocumentSnapshot and QueryDocumentSnapshot
    const role = String(data?.role || '').toLowerCase();

    if (role !== 'admin') {
      console.log('❌ Admin check failed. role=', role, 'uid=', uid, 'email=', email);
      return res.status(403).json({ error: 'Admin only' });
    }

    req.profile = { id: snap.id, ...(data || {}) };
    next();
  } catch (err) {
    console.error('Admin check error:', err.message);
    return res.status(500).json({ error: 'Server error', details: err.message });
  }
}

/* ===============================
   ✅ API: ME (for sidebar admin name)
   GET /api/me  -> { id, name, email, role }
   =============================== */
app.get('/api/me', requireAuth, async (req, res) => {
  try {
    const uid = req.user.uid;
    const email = (req.user.email || '').toLowerCase();

    // try uid first
    let snap = await db.collection('users').doc(uid).get();

    // fallback by email
    if (!snap.exists && email) {
      const emailSnap = await db
        .collection('users')
        .where('email', '==', email)
        .limit(1)
        .get();

      if (!emailSnap.empty) {
        snap = emailSnap.docs[0];
      }
    }

    if (!snap.exists && snap.data === undefined) {
      return res.json({
        id: uid,
        name: req.user.name || null,
        email: req.user.email || null,
        role: null,
      });
    }

    const data = snap.data ? snap.data() : snap.data();
    res.json({
      id: snap.id,
      name: data?.name || null,
      email: data?.email || req.user.email || null,
      role: data?.role || null,
    });
  } catch (err) {
    console.error('/api/me error:', err);
    res.status(500).json({ error: err.message });
  }
});

/* ===============================
   ✅ API: LOGOUT
   (No server session; frontend clears token)
   =============================== */
app.post('/api/logout', (req, res) => {
  res.json({ message: 'Logged out (client token cleared)' });
});

/* ===============================
   ✅ API: DASHBOARD STATS
   =============================== */
app.get('/api/stats', requireAuth, requireAdmin, async (req, res) => {
  try {
    const usersRef = db.collection('users');
    const deliveriesRef = db.collection('deliveries');

    const driversSnap = await usersRef.where('role', '==', 'driver').get();
    const totalDrivers = driversSnap.size;

    const deliveriesSnap = await deliveriesRef.get();
    const totalPackages = deliveriesSnap.size;

    const pendingSnap = await deliveriesRef.where('status', '==', 'pending').get();
    const pendingPackages = pendingSnap.size;

    const deliveredByStatusSnap = await deliveriesRef
      .where('status', '==', 'done')
      .get();

    const deliveredSet = new Set();
    deliveredByStatusSnap.forEach(doc => deliveredSet.add(doc.id));

    deliveriesSnap.forEach(doc => {
      const d = doc.data() || {};
      if (d.completed_at) deliveredSet.add(doc.id);
    });

    const deliveredPackages = deliveredSet.size;

    res.json({
      totalDrivers,
      totalPackages,
      pendingPackages,
      deliveredPackages,
    });
  } catch (err) {
    console.error('Stats error:', err);
    res.status(500).json({ error: err.message });
  }
});

/* ===============================
   API: USERS (GET ALL)
   =============================== */
app.get('/api/users', requireAuth, requireAdmin, async (req, res) => {
  try {
    const snap = await db.collection('users').get();
    const users = snap.docs.map(doc => ({
      id: doc.id,
      ...doc.data(),
    }));
    res.json(users);
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

/* ===============================
   ✅ API: CREATE USER (admin or driver)
   =============================== */
app.post('/api/users', requireAuth, requireAdmin, async (req, res) => {
  try {
    const { name, email, phone, role, password } = req.body;

    if (!name || !email || !role || !password) {
      return res.status(400).json({ error: 'name, email, role, password are required' });
    }

    if (String(password).length < 6) {
      return res.status(400).json({ error: 'Password must be at least 6 characters' });
    }

    const exists = await db
      .collection('users')
      .where('email', '==', String(email).trim().toLowerCase())
      .limit(1)
      .get();

    if (!exists.empty) {
      return res.status(409).json({ error: 'Email already exists' });
    }

    const password_hash = await bcrypt.hash(String(password), 10);

    const docRef = await db.collection('users').add({
      name: String(name).trim(),
      email: String(email).trim().toLowerCase(),
      phone: phone ? String(phone).trim() : '',
      role: String(role).toLowerCase(),
      password_hash,
      created_at: admin.firestore.FieldValue.serverTimestamp(),
    });

    res.status(201).json({ id: docRef.id });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

/* ===============================
   ✅ API: UPDATE USER
   =============================== */
app.put('/api/users/:id', requireAuth, requireAdmin, async (req, res) => {
  try {
    const { id } = req.params;
    const { name, email, phone, role, password } = req.body;

    if (!name || !email) {
      return res.status(400).json({ error: 'name and email are required' });
    }

    const updateData = {
      name: String(name).trim(),
      email: String(email).trim().toLowerCase(),
      phone: phone ? String(phone).trim() : '',
      ...(role ? { role: String(role).toLowerCase() } : {}),
      updated_at: admin.firestore.FieldValue.serverTimestamp(),
    };

    if (password && String(password).trim().length > 0) {
      if (String(password).length < 6) {
        return res.status(400).json({ error: 'Password must be at least 6 characters' });
      }
      updateData.password_hash = await bcrypt.hash(String(password), 10);
    }

    await db.collection('users').doc(id).update(updateData);

    res.json({ message: 'User updated' });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

/* ===============================
   API: DELETE USER
   =============================== */
app.delete('/api/users/:id', requireAuth, requireAdmin, async (req, res) => {
  try {
    const { id } = req.params;
    await db.collection('users').doc(id).delete();
    res.json({ message: 'User deleted' });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

/* ===============================
   API: DRIVER UPDATE (edit only)
   =============================== */
app.put('/api/drivers/:id', requireAuth, requireAdmin, async (req, res) => {
  try {
    const { id } = req.params;
    const { name, email, phone } = req.body;

    if (!name || !email) {
      return res.status(400).json({ error: 'name and email required' });
    }

    await db.collection('users').doc(id).update({
      name: String(name).trim(),
      email: String(email).trim().toLowerCase(),
      phone: phone ? String(phone).trim() : '',
      role: 'driver',
      updated_at: admin.firestore.FieldValue.serverTimestamp(),
    });

    res.json({ message: 'Driver updated' });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

/* ===============================
   API: DRIVER DELETE (single)
   =============================== */
app.delete('/api/drivers/:id', requireAuth, requireAdmin, async (req, res) => {
  try {
    const { id } = req.params;
    await db.collection('users').doc(id).delete();
    res.json({ message: 'Driver deleted' });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

/* ===============================
   API: DELIVERIES (ALL)
   =============================== */
app.get('/api/deliveries', requireAuth, requireAdmin, async (req, res) => {
  try {
    const snap = await db.collection('deliveries').get();
    const deliveries = snap.docs.map(doc => ({
      id: doc.id,
      ...doc.data(),
    }));
    res.json(deliveries);
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

/* ===============================
   ✅ API: PACKAGE STATUS
   =============================== */
app.get('/api/package-status/:packageId', requireAuth, requireAdmin, async (req, res) => {
  try {
    const packageId = String(req.params.packageId || '').trim();
    if (!packageId) return res.status(400).json({ error: 'packageId is required' });

    const doc = await db.collection('deliveries').doc(packageId).get();
    if (doc.exists) {
      const data = doc.data() || {};
      const status = data.status || (data.completed_at ? 'done' : 'pending');
      const normalized = String(status).toLowerCase();
      return res.json({ found: true, id: doc.id, status: normalized === 'done' ? 'delivered' : normalized });
    }

    const fields = ['package_id', 'packageId', 'package'];
    for (const f of fields) {
      const snap = await db.collection('deliveries').where(f, '==', packageId).limit(1).get();
      if (!snap.empty) {
        const foundDoc = snap.docs[0];
        const data = foundDoc.data() || {};
        const status = data.status || (data.completed_at ? 'done' : 'pending');
        const normalized = String(status).toLowerCase();
        return res.json({ found: true, id: foundDoc.id, status: normalized === 'done' ? 'delivered' : normalized });
      }
    }

    return res.json({ found: false, status: null });
  } catch (err) {
    return res.status(500).json({ error: err.message });
  }
});

/* ===============================
   API: DRIVERS WITH DELIVERIES
   =============================== */
app.get('/api/drivers-with-deliveries', requireAuth, requireAdmin, async (req, res) => {
  try {
    const usersSnap = await db.collection('users').get();
    const deliveriesSnap = await db.collection('deliveries').get();

    const deliveries = deliveriesSnap.docs.map(d => ({
      id: d.id,
      ...d.data(),
    }));

    const drivers = [];

    usersSnap.forEach(doc => {
      const user = doc.data();
      if (user?.role !== 'driver') return;

      const assigned = deliveries.filter(d =>
        d.driver_id === doc.id ||
        (d.driver_email && user.email && d.driver_email === user.email)
      );

      const deliveredCount = assigned.filter(
        d => d.completed_at || String(d.status || '').toLowerCase() === 'done'
      ).length;

      drivers.push({
        id: doc.id,
        name: user.name || '-',
        email: user.email || '-',
        phone: user.phone || '-',
        assignedCount: assigned.length,
        deliveredCount,
        deliveries: assigned,
      });
    });

    res.json(drivers);
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

/* ===============================
   ✅ OPTIONAL: health check (helps debug)
   =============================== */
app.get('/api/health', (req, res) => {
  res.json({ ok: true, message: 'Server is running' });
});

/* ===============================
   START SERVER
   =============================== */
const PORT = 3000;
app.listen(PORT, () =>
  console.log(`✅ Server running at http://localhost:${PORT}`)
);
