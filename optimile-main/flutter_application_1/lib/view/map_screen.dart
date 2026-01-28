import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:provider/provider.dart';
import '../viewmodel/mapvm.dart';
import '../env.dart';
import '../viewmodel/authvm.dart';
import 'package:flutter_typeahead/flutter_typeahead.dart';
import '../models/stop_model.dart';

class MapScreen extends StatelessWidget {
  const MapScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => MapVM()..goToCurrentLocation(),
      child: const _MapView(),
    );
  }
}

class _MapView extends StatelessWidget {
  const _MapView();

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<MapVM>();
    Provider.of<AuthViewModel>(context, listen: false);

    return Scaffold(
      endDrawer: _buildDrawer(context, vm),
      body: Stack(
        children: [
          GoogleMap(
            initialCameraPosition: CameraPosition(
              target: LatLng(Env.defaultLat, Env.defaultLng),
              zoom: 13,
            ),
            markers: vm.markers,
            polylines: vm.polylines,
            myLocationEnabled: true,
            onMapCreated: (c) => vm.mapController = c,
            onTap: (latLng) => vm.addStop(latLng),
          ),

          Positioned(
            top: MediaQuery.of(context).padding.top + 10,
            left: 15,
            child: Builder(
              builder: (context) => FloatingActionButton(
                mini: true,
                backgroundColor: Colors.white,
                onPressed: () => Scaffold.of(context).openEndDrawer(),
                child: const Icon(Icons.menu, color: Colors.black),
              ),
            ),
          ),

          if (vm.showSearchBar)
            Positioned(
              top: 40,
              left: 16,
              right: 16,
              child: Material(
                elevation: 6,
                borderRadius: BorderRadius.circular(12),
                child: TypeAheadField<Place>(
                  controller: vm.searchController,
                  focusNode: vm.searchFocusNode,
                  suggestionsCallback: vm.getSuggestions,
                  itemBuilder: (context, place) =>
                      ListTile(title: Text(place.description)),
                  onSelected: vm.selectSuggestion,
                  builder: (context, controller, focusNode) {
                    return TextField(
                      controller: controller,
                      focusNode: focusNode,
                      decoration: InputDecoration(
                        hintText: "Search place",
                        prefixIcon: const Icon(Icons.search),
                        suffixIcon: IconButton(
                          icon: const Icon(Icons.close),
                          onPressed: vm.closeSearchBar,
                        ),
                        border: InputBorder.none,
                        contentPadding: const EdgeInsets.all(14),
                      ),
                    );
                  },
                ),
              ),
            ),

          if (!vm.showSearchBar)
            Positioned(
              top: 40,
              right: 16,
              child: IconButton(
                icon: const Icon(Icons.search, size: 30),
                color: Colors.black,
                onPressed: () => vm.openSearchBar(),
              ),
            ),

          if (vm.stops.isNotEmpty || vm.navigationStarted)
            Positioned(
              bottom: 20,
              left: 16,
              right: 16,
              child: Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.15),
                      blurRadius: 10,
                    )
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (vm.duration.isNotEmpty)
                      Text(
                        vm.duration,
                        style: const TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    if (vm.distance.isNotEmpty)
                      Text(
                        vm.distance,
                        style: TextStyle(color: Colors.grey.shade700),
                      ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        if (!vm.navigationStarted) ...[
                          Expanded(
                            child: ElevatedButton.icon(
                              onPressed: () async {
                                await vm.optimizeRoute(context);
                                await vm.startRide(context);
                              },
                              icon: const Icon(Icons.play_arrow),
                              label: const Text("Start"),
                            ),
                          ),
                        ],
                        if (vm.navigationStarted)
                          Expanded(
                            child: OutlinedButton(
                              onPressed: () async =>
                                  await vm.stopRide(context: context),
                              child: const Text("Exit"),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

 Drawer _buildDrawer(BuildContext context, MapVM vm) {
  return Drawer(
    child: Container(
      color: Colors.black,
      child: Column(
        children: [
          Expanded(
            child: vm.stops.isNotEmpty
                ? ListView(
                    children: [
                      Theme(
                        data: Theme.of(context).copyWith(
                          dividerColor: Colors.transparent,
                        ),
                        child: ExpansionTile(
                          initiallyExpanded: true,
                          title: Row(
                            children: [
                              const Text(
                                'Current Route',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: vm.navigationStarted
                                      ? Colors.blue
                                      : Colors.grey,
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Text(
                                  vm.navigationStarted ? 'ACTIVE' : 'IDLE',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          iconColor: Colors.white,
                          collapsedIconColor: Colors.white,
                          children: vm.stops.asMap().entries.map(
                            (entry) {
                              final index = entry.key;
                              final stop = entry.value;

                              Color color;
                              if (vm.navigationStarted &&
                                  index < vm.currentStopIndex) {
                                color = Colors.green;
                              } else if (vm.navigationStarted &&
                                  index == vm.currentStopIndex) {
                                color = Colors.blue;
                              } else {
                                color = Colors.orange;
                              }

                              return ListTile(
                                leading: Icon(
                                  Icons.location_on,
                                  color: color,
                                  size: 18,
                                ),
                                title: Text(
                                  stop.title ?? 'Stop ${index + 1}',
                                  style: const TextStyle(color: Colors.white),
                                ),
                              );
                            },
                          ).toList(),
                        ),
                      ),
                    ],
                  )
                : const Center(
                    child: Text(
                      'No active route',
                      style: TextStyle(color: Colors.grey),
                    ),
                  ),
          ),

          const Divider(color: Colors.grey),
          // LOGOUT
          ListTile(
            leading: const Icon(Icons.logout, color: Colors.white),
            title: const Text(
              'Logout',
              style: TextStyle(color: Colors.white),
            ),
            onTap: () async {
    final authVM =
        Provider.of<AuthViewModel>(context, listen: false);

    await authVM.logout();
            },
          ),
        ],
      ),
    ),
  );
}

}
