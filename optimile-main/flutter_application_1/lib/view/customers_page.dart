import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class CustomersPage extends StatelessWidget {
  CustomersPage({super.key});

  final FirebaseFirestore db = FirebaseFirestore.instance;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot>(
      stream: db
          .collection("users")
          .where("role", isEqualTo: "customer")
          .snapshots(),
      builder: (context, snap) {
        if (!snap.hasData) {
          return const Center(
            child: CircularProgressIndicator(),
          );
        }

        final users = snap.data!.docs;

        if (users.isEmpty) {
          return const Center(
            child: Text("No customers found"),
          );
        }

        return ListView.builder(
          padding: const EdgeInsets.all(10),
          itemCount: users.length,
          itemBuilder: (_, i) {
            final u = users[i];

            // 🔥 SAFE DATA ACCESS (FIXED)
            final data = u.data() as Map<String, dynamic>;

            final String name = data['name'] ?? 'No name';
            final String email = data['email'] ?? 'No email';

            return Card(
              margin: const EdgeInsets.symmetric(vertical: 6),
              child: ListTile(
                leading: const Icon(Icons.person, color: Colors.blue),

                title: Text(
                  name,
                  overflow: TextOverflow.ellipsis,
                ),

                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      email,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),

                // 🔥 PACKAGE COUNT
                trailing: SizedBox(
                  width: 60,
                  child: FutureBuilder<QuerySnapshot>(
                    future: db
                        .collection("packages")
                        .where("created_by_id", isEqualTo: u.id)
                        .get(),
                    builder: (context, pkgSnap) {
                      if (!pkgSnap.hasData) {
                        return const Text("...");
                      }

                      final count = pkgSnap.data!.docs.length;

                      return Text(
                        "$count",
                        textAlign: TextAlign.right,
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                        ),
                      );
                    },
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}
