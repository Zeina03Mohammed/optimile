import 'package:flutter/material.dart';

class AdminDashboard extends StatelessWidget {
  const AdminDashboard({super.key});

  @override
  Widget build(BuildContext context) {
    Map<String, int> statistics = {
      'Total Deliveries': 120,
      'Active Deliveries': 18,
      'Completed': 95,
      'Failed': 7,
      'Active Drivers': 3,
    };

    List<Map<String, String>> drivers = [
      {'name': 'Driver 1', 'status': 'On Delivery'},
      {'name': 'Driver 2', 'status': 'Active'},
      {'name': 'Driver 3', 'status': 'Offline'},
    ];

    Color getStatusColor(String status) {
      switch (status) {
        case 'On Delivery':
          return Colors.orange;
        case 'Active':
          return Colors.green;
        default:
          return Colors.grey;
      }
    }

    const primaryBlue = Color(0xFF2196F3);
    const darkText = Color.fromARGB(255, 227, 228, 230);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Admin Dashboard'),
        backgroundColor: primaryBlue,
        surfaceTintColor: Colors.transparent,
      ),
      backgroundColor: Colors.grey.shade100,
      body: SingleChildScrollView(
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

            // Drivers Panel
            const Text(
              'Driver Status',
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
                var d = drivers[index];
                return Card(
                  elevation: 2,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: ListTile(
                    leading: Icon(Icons.person, color: primaryBlue),
                    title: Text(
                      d['name']!,
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        color: darkText,
                      ),
                    ),
                    trailing: Text(
                      d['status']!,
                      style: TextStyle(
                        color: getStatusColor(d['status']!),
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

            // Analytics Preview
            const Text(
              'Analytics (Preview)',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: Color.fromARGB(255, 11, 11, 11),
              ),
            ),
            const SizedBox(height: 8),
            Card(
              elevation: 2,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: const [
                    Text('• Peak delivery hours: 2 PM – 6 PM'),
                    Text('• Fastest zone: Nasr City'),
                    Text('• Delays mainly in: Downtown'),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 22),

            // Map Placeholder
            const Text(
              'Live Tracking',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: Color.fromARGB(255, 0, 0, 0),
              ),
            ),
            const SizedBox(height: 8),
            Container(
              height: 160,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                color: Colors.grey.shade400,
              ),
              child: const Center(
                child: Text(
                  'Map Placeholder',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
