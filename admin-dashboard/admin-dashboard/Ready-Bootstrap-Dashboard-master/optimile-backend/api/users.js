app.get('/api/users', async (req, res) => {
  try {
    const snap = await db.collection('users').get();
    
    const users = snap.docs.map(doc => ({
      id: doc.id,
      ...doc.data()
    }));

    res.json(users); // send to front-end
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});
