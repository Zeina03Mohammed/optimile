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

  final TextEditingController searchController = TextEditingController();

  // ================= SELECT COLLECTION =================
  Widget collectionSelector() {
    return DropdownButtonFormField<String>(
      value: selectedCollection,
      items: const [
        DropdownMenuItem(value: "users", child: Text("Users")),
        DropdownMenuItem(value: "deliveries", child: Text("Deliveries")), // 🔥 FIX
      ],
      onChanged: (v) {
        setState(() {
          selectedCollection = v!;
          selectedId = "";
          searchController.clear();
        });
      },
    );
  }

  // ================= SEARCH =================
  Widget searchField() {
    if (selectedCollection != "deliveries") return const SizedBox();

    return TextField(
      controller: searchController,
      decoration: const InputDecoration(
        labelText: "Search by Delivery ID",
        prefixIcon: Icon(Icons.search),
      ),
      onChanged: (v) {
        setState(() {});
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

        var docs = snap.data!.docs;

        // 🔥 FILTER BY ID (SEARCH)
        if (selectedCollection == "deliveries" &&
            searchController.text.isNotEmpty) {
          docs = docs
              .where((e) =>
                  e.id.toLowerCase().contains(searchController.text.toLowerCase()))
              .toList();
        }

        if (docs.isEmpty) {
          return const Text("No data found");
        }

        return DropdownButtonFormField<String>(
          isExpanded: true,
          hint: const Text("Select item"),
          value: docs.any((e) => e.id == selectedId) ? selectedId : null,
          items: docs.map((e) {
            final data = e.data() as Map<String, dynamic>;

            String title;

            if (selectedCollection == "users") {
              title =
                  "${data['name'] ?? 'No name'} (${data['role'] ?? ''})";
            } else {
              title = e.id; // 🔥 SHOW DELIVERY ID
            }

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
    if (selectedCollection != "users") return; // 🔥 DISABLE FOR DELIVERIES

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

                    if (role == "driver")
                      TextField(
                        controller: area,
                        decoration:
                            const InputDecoration(labelText: "Area"),
                      ),

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
          searchField(), // 🔥 SEARCH FIELD

          const SizedBox(height: 10),
          dataList(),

          const SizedBox(height: 20),

          Wrap(
            spacing: 10,
            children: [
              // 🔥 ONLY SHOW ADD & EDIT FOR USERS
              if (selectedCollection == "users") ...[
                ElevatedButton(
                  onPressed: addItem,
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
                  child: const Text("Add"),
                ),
              ],

              // 🔥 DELETE ALWAYS AVAILABLE
              ElevatedButton(
                onPressed: deleteItem,
                style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                child: const Text("Delete"),
              ),
            ],
          )
        ],
      ),
    );
  }
}