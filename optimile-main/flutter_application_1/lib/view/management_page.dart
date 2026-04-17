import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class ManagementPage extends StatefulWidget {
  const ManagementPage({super.key});

  @override
  State<ManagementPage> createState() => _ManagementPageState();
}

class _ManagementPageState extends State<ManagementPage> {
  final FirebaseFirestore db = FirebaseFirestore.instance;

  String selectedCollection = "users";
  String selectedId = "";

  // ================= SELECT COLLECTION =================
  Widget collectionSelector() {
    return DropdownButtonFormField<String>(
      value: selectedCollection,
      items: const [
        DropdownMenuItem(value: "users", child: Text("Users")),
        DropdownMenuItem(value: "packages", child: Text("Packages")),
      ],
      onChanged: (v) {
        setState(() {
          selectedCollection = v!;
          selectedId = "";
        });
      },
    );
  }

  // ================= LIST DATA =================
  Widget dataList() {
    return StreamBuilder<QuerySnapshot>(
      stream: db.collection(selectedCollection).snapshots(),
      builder: (context, snap) {
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }

        final docs = snap.data!.docs;

        if (docs.isEmpty) {
          return const Text("No data found");
        }

        return DropdownButtonFormField<String>(
          isExpanded: true,
          hint: const Text("Select item"),

          // ✅ FIX dropdown crash
          value: docs.any((e) => e.id == selectedId) ? selectedId : null,

          items: docs.map((e) {
            final data = e.data() as Map<String, dynamic>;

            String title = selectedCollection == "users"
                ? "${data['name'] ?? 'No name'} (${data['role'] ?? ''})"
                : data['customer_name'] ?? "Package";

            return DropdownMenuItem(
              value: e.id,
              child: Text(title, overflow: TextOverflow.ellipsis),
            );
          }).toList(),
          onChanged: (v) {
            setState(() {
              selectedId = v!;
            });
          },
        );
      },
    );
  }

  // ================= ADD =================
  void addItem() {
    showDialog(
      context: context,
      builder: (_) {
        final name = TextEditingController();
        final email = TextEditingController();
        final area = TextEditingController();

        String role = "customer";
        String vehicle = "Scooter";

        return StatefulBuilder(
          builder: (context, setStateDialog) {
            return AlertDialog(
              title: Text("Add ${role.toUpperCase()}"),
              content: SingleChildScrollView(
                child: Column(
                  children: [
                    TextField(
                        controller: name,
                        decoration: const InputDecoration(labelText: "Name")),
                    TextField(
                        controller: email,
                        decoration: const InputDecoration(labelText: "Email")),

                    const SizedBox(height: 10),

                    // 🔥 ROLE SELECTOR
                    DropdownButtonFormField<String>(
                      value: role,
                      items: const [
                        DropdownMenuItem(value: "admin", child: Text("Admin")),
                        DropdownMenuItem(
                            value: "driver", child: Text("Driver")),
                        DropdownMenuItem(
                            value: "customer", child: Text("Customer")),
                      ],
                      onChanged: (v) {
                        setStateDialog(() {
                          role = v!;
                        });
                      },
                    ),

                    const SizedBox(height: 10),

                    // ✅ AREA ONLY FOR DRIVER
                    if (role == "driver")
                      TextField(
                        controller: area,
                        decoration:
                            const InputDecoration(labelText: "Area"),
                      ),

                    // ✅ VEHICLE ONLY FOR DRIVER
                    if (role == "driver")
                      DropdownButtonFormField<String>(
                        value: vehicle,
                        items: const [
                          DropdownMenuItem(
                              value: "Scooter", child: Text("Scooter")),
                          DropdownMenuItem(value: "Van", child: Text("Van")),
                        ],
                        onChanged: (v) {
                          setStateDialog(() {
                            vehicle = v!;
                          });
                        },
                      ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text("Cancel")),
                ElevatedButton(
                  onPressed: () async {
                    Map<String, dynamic> data = {
                      "name": name.text,
                      "email": email.text,
                      "role": role,
                      "created_at": Timestamp.now(),
                    };

                    // ✅ ADD DRIVER DATA ONLY
                    if (role == "driver") {
                      data["area"] = area.text;
                      data["vehicle"] = vehicle;
                      data["status"] = "available";
                    }

                    await db.collection("users").add(data);

                    Navigator.pop(context);
                  },
                  child: const Text("Save"),
                )
              ],
            );
          },
        );
      },
    );
  }

  // ================= EDIT =================
  void editItem() async {
    if (selectedId.isEmpty) return;

    final doc =
        await db.collection(selectedCollection).doc(selectedId).get();

    final data = doc.data() as Map<String, dynamic>? ?? {};

    final name = TextEditingController(text: data['name'] ?? '');
    final email = TextEditingController(text: data['email'] ?? '');

    showDialog(
      context: context,
      builder: (_) {
        return AlertDialog(
          title: const Text("Edit"),
          content: SingleChildScrollView(
            child: Column(
              children: [
                TextField(
                    controller: name,
                    decoration: const InputDecoration(labelText: "Name")),
                TextField(
                    controller: email,
                    decoration: const InputDecoration(labelText: "Email")),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text("Cancel")),
            ElevatedButton(
              onPressed: () async {
                await db
                    .collection(selectedCollection)
                    .doc(selectedId)
                    .update({
                  "name": name.text,
                  "email": email.text,
                });

                Navigator.pop(context);
              },
              child: const Text("Save"),
            )
          ],
        );
      },
    );
  }

  // ================= DELETE =================
  void deleteItem() async {
    if (selectedId.isEmpty) return;

    await db.collection(selectedCollection).doc(selectedId).delete();

    setState(() {
      selectedId = "";
    });
  }

  // ================= UI =================
  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          const Text("Management", style: TextStyle(fontSize: 20)),
          const SizedBox(height: 10),
          collectionSelector(),
          const SizedBox(height: 10),
          dataList(),
          const SizedBox(height: 20),
          Wrap(
            spacing: 10,
            children: [
              ElevatedButton(
                onPressed: addItem,
                style:
                    ElevatedButton.styleFrom(backgroundColor: Colors.green),
                child: const Text("Add"),
              ),
              ElevatedButton(
                onPressed: editItem,
                style:
                    ElevatedButton.styleFrom(backgroundColor: Colors.blue),
                child: const Text("Edit"),
              ),
              ElevatedButton(
                onPressed: deleteItem,
                style:
                    ElevatedButton.styleFrom(backgroundColor: Colors.red),
                child: const Text("Delete"),
              ),
            ],
          )
        ],
      ),
    );
  }
}