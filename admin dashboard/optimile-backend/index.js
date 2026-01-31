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

app.get('/', (req, res) =>
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
   ✅ API: DASHBOARD STATS
   - Drivers = users where role == 'driver'
   - Packages = deliveries total
   - Pending  = deliveries where status == 'pending'
   - Delivered = deliveries where status == 'done' OR has completed_at
   =============================== */
app.get('/api/stats', async (req, res) => {
  try {
    const usersRef = db.collection('users');
    const deliveriesRef = db.collection('deliveries');

    // Total drivers
    const driversSnap = await usersRef.where('role', '==', 'driver').get();
    const totalDrivers = driversSnap.size;

    // Total packages
    const deliveriesSnap = await deliveriesRef.get();
    const totalPackages = deliveriesSnap.size;

    // Pending packages (status == pending)
    const pendingSnap = await deliveriesRef.where('status', '==', 'pending').get();
    const pendingPackages = pendingSnap.size;

    // Delivered packages:
    // 1) status == done
    const deliveredByStatusSnap = await deliveriesRef
      .where('status', '==', 'done')
      .get();

    // Combine delivered without double-counting (done OR completed_at)
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
app.get('/api/users', async (req, res) => {
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
   Body: { name, email, phone, role, password }
   Stores: password_hash
   =============================== */
app.post('/api/users', async (req, res) => {
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
      .where('email', '==', String(email).trim())
      .limit(1)
      .get();

    if (!exists.empty) {
      return res.status(409).json({ error: 'Email already exists' });
    }

    const password_hash = await bcrypt.hash(String(password), 10);

    const docRef = await db.collection('users').add({
      name: String(name).trim(),
      email: String(email).trim(),
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
   ✅ API: UPDATE USER (admin / driver)
   If password is provided => update password_hash
   =============================== */
app.put('/api/users/:id', async (req, res) => {
  try {
    const { id } = req.params;
    const { name, email, phone, role, password } = req.body;

    if (!name || !email) {
      return res.status(400).json({ error: 'name and email are required' });
    }

    const updateData = {
      name: String(name).trim(),
      email: String(email).trim(),
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
   API: DELETE USER (admin or driver)
   =============================== */
app.delete('/api/users/:id', async (req, res) => {
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
app.put('/api/drivers/:id', async (req, res) => {
  try {
    const { id } = req.params;
    const { name, email, phone } = req.body;

    if (!name || !email) {
      return res.status(400).json({ error: 'name and email required' });
    }

    await db.collection('users').doc(id).update({
      name: String(name).trim(),
      email: String(email).trim(),
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
app.delete('/api/drivers/:id', async (req, res) => {
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
app.get('/api/deliveries', async (req, res) => {
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
   GET /api/package-status/:packageId
   status "done" => delivered
   =============================== */
app.get('/api/package-status/:packageId', async (req, res) => {
  try {
    const packageId = String(req.params.packageId || '').trim();
    if (!packageId) return res.status(400).json({ error: 'packageId is required' });

    // 1) Try doc ID
    const doc = await db.collection('deliveries').doc(packageId).get();
    if (doc.exists) {
      const data = doc.data() || {};
      const status = data.status || (data.completed_at ? 'done' : 'pending');
      const normalized = String(status).toLowerCase();
      return res.json({ found: true, id: doc.id, status: normalized === 'done' ? 'delivered' : normalized });
    }

    // 2) Try common fields
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
   deliveredCount: status === "done" OR completed_at
   =============================== */
app.get('/api/drivers-with-deliveries', async (req, res) => {
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
   START SERVER
   =============================== */
const PORT = 3000;
app.listen(PORT, () =>
  console.log(`✅ Server running at http://localhost:${PORT}`)
);
