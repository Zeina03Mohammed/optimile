import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class PackagesPage extends StatelessWidget {
  PackagesPage({super.key});

  final FirebaseFirestore db = FirebaseFirestore.instance;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot>(
      stream: db.collection("deliveries").snapshots(),
      builder: (context, snap) {
        if (!snap.hasData) {
          return const Center(
            child: CircularProgressIndicator(),
          );
        }

        final docs = snap.data!.docs;

        if (docs.isEmpty) {
          return const Center(
            child: Text("No packages found"),
          );
        }

        return ListView.builder(
          padding: const EdgeInsets.all(10),
          itemCount: docs.length,
          itemBuilder: (_, i) {
            // 🔥 SAFE MAP ACCESS
            final data = docs[i].data() as Map<String, dynamic>;

            final String name = data.containsKey('customer_name')
                ? data['customer_name'] ?? 'No name'
                : 'No name';

            final String status = data.containsKey('status')
                ? data['status'] ?? 'unknown'
                : 'unknown';

            final String area = data.containsKey('area')
                ? data['area'] ?? ''
                : '';

            return Card(
              margin: const EdgeInsets.symmetric(vertical: 6),
              child: ListTile(
                leading: const Icon(Icons.inventory, color: Colors.blue),

                title: Text(
                  name,
                  overflow: TextOverflow.ellipsis,
                ),

                subtitle: Text(
                  "Status: $status",
                  overflow: TextOverflow.ellipsis,
                ),

                trailing: SizedBox(
                  width: 80,
                  child: Text(
                    area,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.right,
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