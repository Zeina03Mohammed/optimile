import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class AdminDashboard extends StatefulWidget {
  const AdminDashboard({super.key});

  @override
  State<AdminDashboard> createState() => _AdminDashboardState();
}

class _AdminDashboardState extends State<AdminDashboard> {
  int _selectedIndex = 0;

  final List<Widget> _pages = [
    const DashboardOverview(),
    const DriversManagement(),
    const DeliveriesManagement(),
    const VehiclesManagement(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Optimile Admin Dashboard'),
        backgroundColor: Colors.blue.shade700,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: () async {
              await FirebaseAuth.instance.signOut();
              Navigator.of(context).pushReplacementNamed('/');
            },
          ),
        ],
      ),
      body: Row(
        children: [
          NavigationRail(
            selectedIndex: _selectedIndex,
            onDestinationSelected: (int index) {
              setState(() {
                _selectedIndex = index;
              });
            },
            labelType: NavigationRailLabelType.all,
            backgroundColor: Colors.blue.shade50,
            destinations: const [
              NavigationRailDestination(
                icon: Icon(Icons.dashboard_outlined),
                selectedIcon: Icon(Icons.dashboard),
                label: Text('Dashboard'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.people_outlined),
                selectedIcon: Icon(Icons.people),
                label: Text('Drivers'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.local_shipping_outlined),
                selectedIcon: Icon(Icons.local_shipping),
                label: Text('Deliveries'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.directions_car_outlined),
                selectedIcon: Icon(Icons.directions_car),
                label: Text('Vehicles'),
              ),
            ],
          ),
          const VerticalDivider(thickness: 1, width: 1),
          Expanded(
            child: _pages[_selectedIndex],
          ),
        ],
      ),
    );
  }
}

// Continue with the rest of the admin dashboard code...
// (I'll create it in parts to avoid hitting token limits)

class DashboardOverview extends StatelessWidget {
  const DashboardOverview({super.key});

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Text('Dashboard Overview - Coming Soon'),
    );
  }
}

class DriversManagement extends StatelessWidget {
  const DriversManagement({super.key});

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Text('Drivers Management - Coming Soon'),
    );
  }
}

class DeliveriesManagement extends StatelessWidget {
  const DeliveriesManagement({super.key});

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Text('Deliveries Management - Coming Soon'),
    );
  }
}

class VehiclesManagement extends StatelessWidget {
  const VehiclesManagement({super.key});

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Text('Vehicles Management - Coming Soon'),
    );
  }
}
