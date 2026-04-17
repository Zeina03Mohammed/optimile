import 'package:flutter/material.dart';
import 'admin_dashboard.dart'; // your DashboardPage file
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Admin Dashboard")),

      body: pages[currentIndex],

      bottomNavigationBar: BottomNavigationBar(
        currentIndex: currentIndex,
        onTap: (i) => setState(() => currentIndex = i),
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.home), label: "Home"),
          BottomNavigationBarItem(icon: Icon(Icons.inventory), label: "Packages"),
          BottomNavigationBarItem(icon: Icon(Icons.delivery_dining), label: "Drivers"),
          BottomNavigationBarItem(icon: Icon(Icons.people), label: "Customers"),
          BottomNavigationBarItem(icon: Icon(Icons.settings), label: "Manage"),
        ],
      ),
    );
  }
}