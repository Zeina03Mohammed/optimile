import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

// 🔥 IMPORT YOUR OTHER PAGES
import 'packages_page.dart';
import 'drivers_page.dart';
import 'customers_page.dart';
import 'management_page.dart';

class AdminDashboardApp extends StatefulWidget {
  const AdminDashboardApp({super.key});

  @override
  State<AdminDashboardApp> createState() => _AdminDashboardAppState();
}

class _AdminDashboardAppState extends State<AdminDashboardApp> {
  int currentIndex = 0;

  final List<Widget> pages = [
    DashboardPage(),
    PackagesPage(),
    DriversPage(),
    CustomersPage(),
    ManagementPage(),
  ];

  void navigate(int index) {
    setState(() {
      currentIndex = index;
    });
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Admin Dashboard"),
        centerTitle: true,
      ),

      drawer: Drawer(
        child: ListView(
          children: [
            const DrawerHeader(
              decoration: BoxDecoration(color: Colors.blue),
              child: Text(
                "Admin Panel",
                style: TextStyle(color: Colors.white, fontSize: 20),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.dashboard),
              title: const Text("Dashboard"),
              onTap: () => navigate(0),
            ),
            ListTile(
              leading: const Icon(Icons.inventory),
              title: const Text("Packages"),
              onTap: () => navigate(1),
            ),
            ListTile(
              leading: const Icon(Icons.delivery_dining),
              title: const Text("Drivers"),
              onTap: () => navigate(2),
            ),
            ListTile(
              leading: const Icon(Icons.people),
              title: const Text("Customers"),
              onTap: () => navigate(3),
            ),
            ListTile(
              leading: const Icon(Icons.settings),
              title: const Text("Management"),
              onTap: () => navigate(4),
            ),
          ],
        ),
      ),

      // 🔥 FIX: wrap body in SafeArea + proper layout
      body: SafeArea(
        child: pages[currentIndex],
      ),

      // 🔥 NAVBAR (NOW GUARANTEED TO SHOW)
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: currentIndex,
        onTap: (index) {
          setState(() {
            currentIndex = index;
          });
        },
        type: BottomNavigationBarType.fixed,
        selectedItemColor: Colors.blue,
        unselectedItemColor: Colors.grey,
        backgroundColor: Colors.white,
        elevation: 10,
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.dashboard),
            label: "Home",
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.inventory),
            label: "Packages",
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.delivery_dining),
            label: "Drivers",
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.people),
            label: "Customers",
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.settings),
            label: "Manage",
          ),
        ],
      ),
    );
  }
}

// =======================
// 🔥 DASHBOARD PAGE
// =======================

class DashboardPage extends StatelessWidget {
  DashboardPage({super.key});

  final FirebaseFirestore db = FirebaseFirestore.instance;

  Widget statCard({
    required IconData icon,
    required String title,
    required int value,
    required Color color,
  }) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 10),
      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 24),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        children: [
          Icon(icon, color: Colors.white, size: 44),
          const SizedBox(width: 26),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  decoration: TextDecoration.none,
                  color: Colors.white,
                  fontSize: 17,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                value.toString(),
                style: const TextStyle(
                  decoration: TextDecoration.none,
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget ordersCard({
    required int delivered,
    required int total,
  }) {
    final double percent = total == 0 ? 0 : delivered / total;

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 16, bottom: 20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(3),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(18, 18, 18, 8),
            child: Text(
              "Orders",
              style: TextStyle(
                decoration: TextDecoration.none,
                fontSize: 18,
                color: Color(0xFF5C6068),
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(18, 0, 18, 18),
            child: Text(
              "Complete",
              style: TextStyle(
                decoration: TextDecoration.none,
                fontSize: 13,
                color: Color(0xFF9E9E9E),
              ),
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 28),
            child: Center(
              child: SizedBox(
                width: 120,
                height: 120,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    SizedBox(
                      width: 110,
                      height: 110,
                      child: CircularProgressIndicator(
                        value: percent,
                        strokeWidth: 8,
                        backgroundColor: const Color(0xFFE9E9E9),
                        valueColor:
                            const AlwaysStoppedAnimation<Color>(Colors.red),
                      ),
                    ),
                    Text(
                      "${(percent * 100).toStringAsFixed(0)}%",
                      style: const TextStyle(
                        decoration: TextDecoration.none,
                        fontSize: 22,
                        color: Color(0xFF5C6068),
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFFF2F3F7),
      child: StreamBuilder<QuerySnapshot>(
        stream: db.collection("packages").snapshots(),
        builder: (context, packageSnap) {
          return StreamBuilder<QuerySnapshot>(
            stream: db.collection("users").snapshots(),
            builder: (context, userSnap) {
              if (!packageSnap.hasData || !userSnap.hasData) {
                return const Center(child: CircularProgressIndicator());
              }

              final packageDocs = packageSnap.data!.docs;
              final userDocs = userSnap.data!.docs;

              final int totalPackages = packageDocs.length;
              final int delivered = packageDocs
                  .where((e) => (e['status'] ?? '') == 'delivered')
                  .length;
              final int pending = packageDocs
                  .where((e) => (e['status'] ?? '') == 'pending')
                  .length;
              final int drivers = userDocs
                  .where((e) => (e['role'] ?? '') == 'driver')
                  .length;

              return SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(18, 8, 18, 80), // 🔥 IMPORTANT FIX
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Padding(
                      padding: EdgeInsets.only(bottom: 8),
                      child: Text(
                        "Dashboard",
                        style: TextStyle(
                          decoration: TextDecoration.none,
                          fontSize: 22,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF30343A),
                        ),
                      ),
                    ),
                    statCard(
                      icon: Icons.people_outline,
                      title: "Drivers",
                      value: drivers,
                      color: const Color(0xFFF3AB4D),
                    ),
                    statCard(
                      icon: Icons.bar_chart,
                      title: "Packages",
                      value: totalPackages,
                      color: const Color(0xFF5BCD5C),
                    ),
                    statCard(
                      icon: Icons.receipt_long_outlined,
                      title: "Delivered",
                      value: delivered,
                      color: const Color(0xFFFA6670),
                    ),
                    statCard(
                      icon: Icons.check_circle_outline,
                      title: "Pending",
                      value: pending,
                      color: const Color(0xFF2D65E3),
                    ),
                    ordersCard(
                      delivered: delivered,
                      total: totalPackages,
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