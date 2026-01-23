import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class AdminDashboard extends StatefulWidget {
  const AdminDashboard({super.key});

  @override
  State<AdminDashboard> createState() => _AdminDashboardState();
}

class _AdminDashboardState extends State<AdminDashboard> {

  @override
  Widget build(BuildContext context) {

    const primaryBlue = Color(0xFF2196F3);
    const darkText = Color.fromARGB(255, 227, 228, 230);

    const primaryBlue = Color(0xFF2196F3);
    const darkText = Color.fromARGB(255, 227, 228, 230);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Admin Dashboard'),
        backgroundColor: primaryBlue,
        surfaceTintColor: Colors.transparent,
      ),
      backgroundColor: Colors.grey.shade100,
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance.collection('deliveries').snapshots(),
        builder: (context, deliverySnapshot) {
          if (!deliverySnapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }

          final deliveries = deliverySnapshot.data!.docs;
          final totalDeliveries = deliveries.length;
          final completedDeliveries =
              deliveries.where((d) => d['status'] == 'completed').length;

          // Calculate total time saved
          double totalTimeSaved = 0;
          for (var delivery in deliveries) {
            totalTimeSaved += (delivery['timeSaved'] ?? 0);
          }

          return StreamBuilder<QuerySnapshot>(
            stream: FirebaseFirestore.instance.collection('users').where('role', isEqualTo: 'driver').snapshots(),
            builder: (context, driverSnapshot) {
              if (!driverSnapshot.hasData) {
                return const Center(child: CircularProgressIndicator());
              }

              final drivers = driverSnapshot.data!.docs;
              final activeDrivers = drivers.length;

              Map<String, int> statistics = {
                'Total Deliveries': totalDeliveries,
                'Completed': completedDeliveries,
                'Active Drivers': activeDrivers,
                'Time Saved (min)': totalTimeSaved.round(),
              };

              return SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Operational Overview',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                        color: Color.fromARGB(255, 7, 7, 7),
                      ),
                    ),
                    const SizedBox(height: 12),

                    // Stats Grid
                    Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: statistics.entries.map((entry) {
                        return Container(
                          width: MediaQuery.of(context).size.width / 2.2,
                          child: Card(
                            elevation: 3,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 18,
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    entry.key,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 14,
                                      color: darkText,
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    entry.value.toString(),
                                    style: const TextStyle(
                                      fontSize: 22,
                                      fontWeight: FontWeight.bold,
                                      color: primaryBlue,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      }).toList(),
                    ),

                    const SizedBox(height: 22),
                    Divider(color: Colors.grey.shade300),
                    const SizedBox(height: 10),

                    // Recent Deliveries
                    const Text(
                      'Recent Deliveries',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: Color.fromARGB(255, 10, 10, 10),
                      ),
                    ),
                    const SizedBox(height: 10),

                    ListView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: deliveries.length > 5 ? 5 : deliveries.length,
                      itemBuilder: (context, index) {
                        var delivery = deliveries[index];
                        var data = delivery.data() as Map<String, dynamic>;
                        return Card(
                          elevation: 2,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: ListTile(
                            leading: const Icon(Icons.local_shipping, color: primaryBlue),
                            title: Text(
                              data['driverEmail'] ?? 'Unknown Driver',
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                color: darkText,
                              ),
                            ),
                            subtitle: Text(
                              'Stops: ${(data['stops'] as List).length} | Saved: ${data['timeSaved'].toStringAsFixed(1)} min',
                              style: const TextStyle(fontSize: 12),
                            ),
                            trailing: Text(
                              data['status'] ?? 'Unknown',
                              style: const TextStyle(
                                color: Colors.green,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        );
                      },
                    ),

                    const SizedBox(height: 22),
                    Divider(color: Colors.grey.shade300),
                    const SizedBox(height: 10),

                    // Drivers Panel
                    const Text(
                      'Registered Drivers',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: Color.fromARGB(255, 10, 10, 10),
                      ),
                    ),
                    const SizedBox(height: 10),

                    ListView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: drivers.length,
                      itemBuilder: (context, index) {
                        var driver = drivers[index];
                        var driverData = driver.data() as Map<String, dynamic>;
                        return Card(
                          elevation: 2,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: ListTile(
                            leading: const Icon(Icons.person, color: primaryBlue),
                            title: Text(
                              driverData['name'] ?? 'Unknown',
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                color: darkText,
                              ),
                            ),
                            subtitle: Text(
                              driverData['email'] ?? '',
                              style: const TextStyle(fontSize: 12),
                            ),
                            trailing: const Text(
                              'Active',
                              style: TextStyle(
                                color: Colors.green,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}
