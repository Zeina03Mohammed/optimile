import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class DriversPage extends StatelessWidget {
  DriversPage({super.key});

  final FirebaseFirestore db = FirebaseFirestore.instance;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot>(
      stream: db
          .collection("users")
          .where("role", isEqualTo: "driver")
          .snapshots(),
      builder: (context, snap) {
        if (!snap.hasData) {
          return const Center(
            child: CircularProgressIndicator(),
          );
        }

        final drivers = snap.data!.docs;

        if (drivers.isEmpty) {
          return const Center(
            child: Text("No drivers found"),
          );
        }

        return ListView.builder(
          padding: const EdgeInsets.all(10),
          itemCount: drivers.length,
          itemBuilder: (_, i) {
            final d = drivers[i];

            // 🔥 SAFE DATA ACCESS
            final data = d.data() as Map<String, dynamic>;

            final String name = data['name'] ?? 'No name';
            final String vehicle =
                data.containsKey('vehicle') ? data['vehicle'] : 'Unknown';
            final String status =
                data.containsKey('status') ? data['status'] : 'Unknown';
            final String area =
                data.containsKey('area') ? data['area'] : 'Unknown';

            return Card(
              margin: const EdgeInsets.symmetric(vertical: 6),
              child: ListTile(
                leading: const Icon(
                  Icons.delivery_dining,
                  color: Colors.blue,
                ),

                title: Text(
                  name,
                  overflow: TextOverflow.ellipsis,
                ),

                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text("Vehicle: $vehicle"),
                    Text("Area: $area"),
                  ],
                ),

                trailing: SizedBox(
                  width: 80,
                  child: Text(
                    status,
                    textAlign: TextAlign.right,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: status == "available"
                          ? Colors.green
                          : Colors.red,
                      fontWeight: FontWeight.bold,
                    ),
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