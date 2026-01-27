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
              child: (!vm.navigationStarted && vm.routeStatus != 'done')
                  ? ListView.builder(
                      itemCount: vm.stops.length,
                      itemBuilder: (context, index) {
                        final stop = vm.stops[index];
                        return ListTile(
                          leading: const Text('•',
                              style: TextStyle(color: Colors.white)),
                          title: Text(
                            vm.stopTitles[stop] ??
                                'Stop ${index + 1}',
                            style: const TextStyle(color: Colors.white),
                          ),
                          trailing: IconButton(
                            icon: const Icon(Icons.delete, color: Colors.red),
                            onPressed: () => vm.removeStop(index),
                          ),
                        );
                      },
                    )
                  : Container(),
            ),
            const Divider(color: Colors.grey),
            ListTile(
              leading: const Icon(Icons.logout, color: Colors.white),
              title: const Text('Logout',
                  style: TextStyle(color: Colors.white)),
              onTap: () async {
                await vm.logout(context);
              },
            ),
          ],
        ),
      ),
    );
  }
}
