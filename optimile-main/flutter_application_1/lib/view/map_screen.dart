import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:provider/provider.dart';
import '../viewmodel/mapvm.dart';
import '../env.dart';
import '../viewmodel/authvm.dart';
import 'package:flutter_typeahead/flutter_typeahead.dart';
import '../models/stop_model.dart';

/// Maps XAI event category to its colour-coded strip colour.
/// Colours follow the DARPA XAI + EU AI Act Art. 13 visual convention:
///   optimization → blue  |  hazard → red  |  weather → orange
///   deviation → amber    |  fleet  → purple  |  info → green
Color _xaiCategoryColor(XaiCategory cat) => switch (cat) {
  XaiCategory.optimization => const Color(0xFF4FC3F7), // light blue
  XaiCategory.hazard       => const Color(0xFFEF5350), // red
  XaiCategory.weather      => const Color(0xFFFFB74D), // orange
  XaiCategory.deviation    => const Color(0xFFFFD54F), // amber
  XaiCategory.fleet        => const Color(0xFFCE93D8), // purple
  XaiCategory.info         => const Color(0xFF69F0AE), // green
};

class MapScreen extends StatelessWidget {
  const MapScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final authVm = Provider.of<AuthViewModel>(context, listen: false);
    final driverId = authVm.currentDriver?.driverId;

    return ChangeNotifierProvider(
      create: (_) => MapVM()..goToCurrentLocation(),
      child: _MapView(driverId: driverId),
    );
  }
}

class _MapView extends StatelessWidget {
  final int? driverId;
  const _MapView({this.driverId});

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<MapVM>();
    Provider.of<AuthViewModel>(context, listen: false);

    return Scaffold(
      endDrawer: _buildDrawer(context, vm),
      body: Stack(
        children: [
          GoogleMap(
            initialCameraPosition: const CameraPosition(
              target: LatLng(Env.defaultLat, Env.defaultLng),
              zoom: 13,
            ),
            markers: vm.markers,
            polylines: vm.polylines,
            myLocationEnabled: true,
            onMapCreated: (c) {
              vm.mapController = c;
              // Load orders after map is ready so camera zoom to Cairo works
              if (driverId != null) {
                Future.delayed(const Duration(milliseconds: 500), () {
                  vm.loadDriverOrders(driverId);
                });
              }
            },
            onTap: (latLng) async {
              // Unified stop configuration: fragile + time window
              final config = await vm.showStopConfigDialog(context);
              if (config == null) return;

              final now = TimeOfDay.now();
              final nowMinutes = now.hour * 60 + now.minute;

              if (config.end != null) {
                final endMinutes = config.end!.hour * 60 + config.end!.minute;
                if (endMinutes < nowMinutes) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text(
                        "Deadline is in the past. Please choose a later time.",
                      ),
                    ),
                  );
                  return;
                }
              }

              vm.addStop(
                latLng,
                isFragile: config.isFragile,
                startTime: config.start,
                endTime: config.end,
              );
            },
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

          // ── DRIVER GREETING BANNER ──
          if (!vm.showSearchBar && !vm.navigationStarted)
            Positioned(
              top: MediaQuery.of(context).padding.top + 10,
              left: 65,
              right: 65,
              child: _GreetingBanner(),
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

          // ========== WEATHER CHIP ==========
          if (vm.weatherData != null && !vm.showSearchBar)
            Positioned(
              top: MediaQuery.of(context).padding.top + 10,
              right: 60,
              child: _WeatherChip(vm: vm),
            ),

          // ========== EVENT LOG (during navigation) ==========
          if (vm.navigationStarted && vm.eventLog.isNotEmpty)
            Positioned(
              bottom: 210,
              left: 16,
              right: 16,
              child: GestureDetector(
                onTap: vm.toggleEventLog,
                child: Container(
                  constraints: BoxConstraints(
                    maxHeight: vm.eventLogExpanded ? 200 : 100,
                  ),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.85),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.terminal, color: Colors.greenAccent, size: 14),
                          const SizedBox(width: 6),
                          const Text(
                            "Live Activity",
                            style: TextStyle(
                              color: Colors.greenAccent,
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const Spacer(),
                          Icon(
                            vm.eventLogExpanded ? Icons.expand_less : Icons.expand_more,
                            color: Colors.white54,
                            size: 16,
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Flexible(
                        child: ListView.builder(
                          shrinkWrap: true,
                          padding: EdgeInsets.zero,
                          physics: vm.eventLogExpanded
                              ? const AlwaysScrollableScrollPhysics()
                              : const NeverScrollableScrollPhysics(),
                          itemCount: vm.eventLogExpanded
                              ? vm.eventLog.length
                              : (vm.eventLog.length > 3 ? 3 : vm.eventLog.length),
                          itemBuilder: (_, i) {
                            final e = vm.eventLog[i];
                            final catColor = _xaiCategoryColor(e.category);
                            return Padding(
                              padding: const EdgeInsets.symmetric(vertical: 2),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  // Category colour strip (EU AI Act Art. 13 visual signal)
                                  Container(
                                    width: 3,
                                    height: 40,
                                    margin: const EdgeInsets.only(right: 6),
                                    decoration: BoxDecoration(
                                      color: catColor,
                                      borderRadius: BorderRadius.circular(2),
                                    ),
                                  ),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            Text(
                                              e.time,
                                              style: const TextStyle(
                                                color: Colors.white38,
                                                fontSize: 10,
                                                fontFamily: 'monospace',
                                              ),
                                            ),
                                            const SizedBox(width: 4),
                                            Text(e.icon, style: const TextStyle(fontSize: 11)),
                                            const Spacer(),
                                            // Confidence badge — plain words, not raw %
                                            if (e.confidence != null)
                                              Container(
                                                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                                                decoration: BoxDecoration(
                                                  color: catColor.withValues(alpha: 0.15),
                                                  borderRadius: BorderRadius.circular(4),
                                                ),
                                                child: Text(
                                                  e.confidence! >= 0.90
                                                      ? 'Very sure'
                                                      : e.confidence! >= 0.75
                                                          ? 'Sure'
                                                          : 'Likely',
                                                  style: TextStyle(
                                                    color: catColor,
                                                    fontSize: 9,
                                                    fontWeight: FontWeight.bold,
                                                  ),
                                                ),
                                              ),
                                            // Impact — "saves X min" or "adds X min"
                                            if (e.impactMin != null && e.impactMin!.abs() >= 0.5) ...[
                                              const SizedBox(width: 4),
                                              Text(
                                                e.impactMin! >= 0
                                                    ? 'saves ${e.impactMin!.abs().toStringAsFixed(0)} min'
                                                    : 'adds ${e.impactMin!.abs().toStringAsFixed(0)} min',
                                                style: TextStyle(
                                                  color: e.impactMin! >= 0
                                                      ? Colors.greenAccent
                                                      : Colors.redAccent,
                                                  fontSize: 9,
                                                  fontWeight: FontWeight.bold,
                                                ),
                                              ),
                                            ],
                                          ],
                                        ),
                                        Text(
                                          e.message,
                                          style: const TextStyle(
                                            color: Colors.white70,
                                            fontSize: 11,
                                          ),
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        // Counterfactual explanation (italic, dimmed)
                                        if (e.counterfactual != null)
                                          Padding(
                                            padding: const EdgeInsets.only(top: 1),
                                            child: Text(
                                              e.counterfactual!,
                                              style: const TextStyle(
                                                color: Colors.white30,
                                                fontSize: 9,
                                                fontStyle: FontStyle.italic,
                                              ),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

          // ========== BOTTOM CONTROL CARD ==========
          if (vm.hasAnyStops || vm.navigationStarted)
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
                    // Live ETA during navigation
                    if (vm.navigationStarted) ...[
                      // Vehicle name + stop progress
                      Row(
                        children: [
                          if (vm.routes.length > 1) ...[
                            Container(
                              width: 10, height: 10,
                              decoration: BoxDecoration(
                                color: vm.routes[vm.activeRouteIndex].color,
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              vm.routes[vm.activeRouteIndex].name,
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                                color: Colors.blue.shade700,
                              ),
                            ),
                            const SizedBox(width: 8),
                          ],
                          if (vm.stopProgress.isNotEmpty)
                            Text(
                              vm.stopProgress,
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: Colors.blue.shade700,
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          if (vm.nextStopEta.isNotEmpty) ...[
                            const Icon(Icons.navigate_next, size: 16, color: Colors.black54),
                            const SizedBox(width: 2),
                            Text(
                              "Next: ${vm.nextStopEta}",
                              style: const TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                          if (vm.nextStopEta.isNotEmpty && vm.totalEta.isNotEmpty)
                            const SizedBox(width: 16),
                          if (vm.totalEta.isNotEmpty) ...[
                            const Icon(Icons.flag, size: 14, color: Colors.black38),
                            const SizedBox(width: 2),
                            Text(
                              "Total: ${vm.totalEta}",
                              style: TextStyle(
                                fontSize: 14,
                                color: Colors.grey.shade600,
                              ),
                            ),
                          ],
                        ],
                      ),
                      // Per-vehicle ETA
                      if (vm.activeVehicleEta.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Row(
                          children: [
                            Icon(Icons.local_shipping, size: 14, color: Colors.orange.shade700),
                            const SizedBox(width: 4),
                            Text(
                              "${vm.routes[vm.activeRouteIndex].name} ETA: ${vm.activeVehicleEta}",
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: Colors.orange.shade700,
                              ),
                            ),
                          ],
                        ),
                      ],
                      if (vm.distance.isNotEmpty)
                        Text(
                          vm.distance,
                          style: TextStyle(color: Colors.grey.shade700, fontSize: 12),
                        ),
                    ],
                    // Pre-navigation info
                    if (!vm.navigationStarted) ...[
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
                      if (vm.routes.length > 1) ...[
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            Text(
                              "Stops go to: ",
                              style: TextStyle(color: Colors.grey.shade700, fontSize: 12),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                              decoration: BoxDecoration(
                                color: vm.routes[vm.selectedRouteIndex].color.withOpacity(0.3),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: DropdownButton<int>(
                                value: vm.selectedRouteIndex,
                                isDense: true,
                                underline: const SizedBox(),
                                items: List.generate(
                                  vm.routes.length,
                                  (i) => DropdownMenuItem(
                                    value: i,
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Container(
                                          width: 10,
                                          height: 10,
                                          decoration: BoxDecoration(
                                            color: vm.routes[i].color,
                                            shape: BoxShape.circle,
                                          ),
                                        ),
                                        const SizedBox(width: 6),
                                        Text(vm.routes[i].name),
                                      ],
                                    ),
                                  ),
                                ),
                                onChanged: (i) {
                                  if (i != null) vm.setSelectedRoute(i);
                                },
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        const Text("Vehicle:", style: TextStyle(color: Color.fromARGB(255, 0, 0, 0))),
                        const SizedBox(width: 12),
                        DropdownButton<String>(
                          dropdownColor: const Color.fromARGB(255, 249, 245, 245),
                          value: vm.vehicleType,
                          items: const [
                            DropdownMenuItem(value: "motorcycle", child: Text("Motorcycle")),
                            DropdownMenuItem(value: "scooter", child: Text("Scooter")),
                            DropdownMenuItem(value: "van", child: Text("Van")),
                          ],
                          onChanged: vm.navigationStarted
                              ? null
                              : (v) => vm.setVehicleType(v!),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        if (!vm.navigationStarted) ...[
                          Expanded(
                            child: ElevatedButton.icon(
                              onPressed: vm.canStart
                                  ? () async {
                                      await vm.optimizeRoute(context);
                                      await vm.startRide(context);
                                    }
                                  : null,
                              icon: const Icon(Icons.play_arrow),
                              label: const Text("Start"),
                            ),
                          ),
                        ],
                        if (vm.navigationStarted) ...[
                          Expanded(
                            child: ElevatedButton.icon(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.green.shade600,
                                foregroundColor: Colors.white,
                              ),
                              onPressed: () =>
                                  vm.markCurrentStopDelivered(context),
                              icon: const Icon(Icons.check_circle, size: 18),
                              label: const Text("Mark Delivered"),
                            ),
                          ),
                          const SizedBox(width: 8),
                          OutlinedButton(
                            onPressed: () async =>
                                await vm.stopRide(context: context),
                            child: const Text("Exit"),
                          ),
                        ],
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
            child: vm.hasAnyStops || vm.routes.isNotEmpty
                ? ListView(
                    children: [
                      if (!vm.navigationStarted)
                        ListTile(
                          leading: const Icon(Icons.add_circle_outline,
                              color: Colors.white),
                          title: const Text(
                            'Add route (another car)',
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          onTap: () {
                            vm.addRoute();
                          },
                        ),
                      const Divider(color: Colors.grey),
                      Theme(
                        data: Theme.of(context).copyWith(
                          dividerColor: Colors.transparent,
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: vm.routes.asMap().entries.map((routeEntry) {
                          final routeIndex = routeEntry.key;
                          final routeModel = routeEntry.value;
                          final routeStops = routeModel.stops;
                          final isSelected =
                              vm.selectedRouteIndex == routeIndex;
                          final isActive =
                              vm.navigationStarted &&
                                  vm.activeRouteIndex == routeIndex;

                          return ExpansionTile(
                            initiallyExpanded: isSelected || routeStops.isNotEmpty,
                            title: Row(
                              children: [
                                Container(
                                  width: 12,
                                  height: 12,
                                  decoration: BoxDecoration(
                                    color: routeModel.color,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    routeModel.name,
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontWeight: isSelected
                                          ? FontWeight.bold
                                          : FontWeight.normal,
                                    ),
                                  ),
                                ),
                                if (vm.routes.length > 1 && !vm.navigationStarted)
                                  IconButton(
                                    icon: const Icon(Icons.close, color: Colors.white54, size: 20),
                                    onPressed: () => vm.removeRoute(routeIndex),
                                  ),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: isActive
                                        ? Colors.green
                                        : isSelected
                                            ? Colors.blue
                                            : Colors.grey,
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Text(
                                    isActive
                                        ? 'ACTIVE'
                                        : isSelected
                                            ? 'SELECTED'
                                            : 'IDLE',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 10,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            iconColor: Colors.white,
                            collapsedIconColor: Colors.white,
                            onExpansionChanged: (expanded) {
                              if (expanded) vm.setSelectedRoute(routeIndex);
                            },
                            children: [
                              ListTile(
                                title: Text(
                                  routeStops.isEmpty
                                      ? 'Tap map to add stops'
                                      : '${routeStops.length} stop(s)',
                                  style: const TextStyle(
                                    color: Colors.white70,
                                    fontSize: 12,
                                  ),
                                ),
                                onTap: () {
                                  vm.setSelectedRoute(routeIndex);
                                  Navigator.of(context).pop();
                                },
                              ),
                              ...routeStops.asMap().entries.map((entry) {
                                final index = entry.key;
                                final stop = entry.value;

                                Color color;
                                if (vm.navigationStarted && isActive) {
                                  if (index < vm.currentStopIndex) {
                                    color = Colors.green;
                                  } else if (index == vm.currentStopIndex) {
                                    color = Colors.blue;
                                  } else {
                                    color = Colors.orange;
                                  }
                                } else {
                                  color = routeModel.color;
                                }

                                final start = TimeOfDay(
                                    hour: (stop.windowStartMin ~/ 60),
                                    minute: (stop.windowStartMin % 60));
                                final end = TimeOfDay(
                                    hour: (stop.windowEndMin ~/ 60),
                                    minute: (stop.windowEndMin % 60));
                                final windowLabel =
                                    "${start.format(context)}–${end.format(context)}";

                                return ListTile(
                                  leading: Icon(
                                    Icons.location_on,
                                    color: color,
                                    size: 18,
                                  ),
                                  title: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Expanded(
                                            child: Text(
                                              stop.title ?? 'Stop ${index + 1}',
                                              style: const TextStyle(color: Colors.white),
                                            ),
                                          ),
                                          if (stop.isFragile)
                                            const Icon(Icons.warning,
                                                color: Colors.red, size: 16),
                                        ],
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        "Window: $windowLabel",
                                        style: const TextStyle(
                                          color: Colors.white70,
                                          fontSize: 12,
                                        ),
                                      ),
                                    ],
                                  ),
                                  onTap: () async {
                                    vm.setSelectedRoute(routeIndex);
                                    await vm.mapController?.animateCamera(
                                      CameraUpdate.newCameraPosition(
                                        CameraPosition(
                                          target: stop.location,
                                          zoom: 17,
                                        ),
                                      ),
                                    );
                                    if (context.mounted) {
                                      Navigator.of(context).pop();
                                    }
                                  },
                                );
                              }),
                            ],
                          );
                        }).toList(),
                        ),
                      ),
                    ],
                  )
                : const Center(
                    child: Text(
                      'No routes. Add a route and tap the map to add stops.',
                      style: TextStyle(color: Colors.grey),
                      textAlign: TextAlign.center,
                    ),
                  ),
          ),

          if (vm.navigationStarted) ...[
            const Divider(color: Colors.grey),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red.shade700,
                  foregroundColor: Colors.white,
                  minimumSize: const Size.fromHeight(44),
                ),
                icon: const Icon(Icons.water_damage, size: 18),
                label: const Text('Simulate Road Hazard'),
                onPressed: () {
                  Navigator.of(context).pop();
                  vm.simulateRoadHazard(context);
                },
              ),
            ),
          ],
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
              Navigator.of(context).pop(); // close drawer first
              await authVM.logout();
            },
          ),
        ],
      ),
    ),
  );
}

}

// ========== WEATHER CHIP WIDGET ==========
class _WeatherChip extends StatelessWidget {
  const _WeatherChip({required this.vm});
  final MapVM vm;

  static IconData _iconFor(String condition) {
    final c = condition.toLowerCase();
    if (c.contains('storm') || c.contains('thunder')) return Icons.thunderstorm;
    if (c.contains('snow')) return Icons.ac_unit;
    if (c.contains('fog') || c.contains('haze')) return Icons.foggy;
    if (c.contains('rain') || c.contains('drizzle')) return Icons.umbrella;
    if (c.contains('cloud')) return Icons.cloud;
    if (c.contains('night')) return Icons.nightlight_round;
    return Icons.wb_sunny;
  }

  static Color _colorFor(String condition) {
    final c = condition.toLowerCase();
    if (c.contains('storm') || c.contains('thunder')) return Colors.deepPurple.shade700;
    if (c.contains('snow')) return Colors.lightBlue.shade200;
    if (c.contains('fog') || c.contains('haze')) return Colors.blueGrey.shade400;
    if (c.contains('rain') || c.contains('drizzle')) return Colors.indigo.shade400;
    if (c.contains('cloud')) return Colors.blueGrey.shade600;
    if (c.contains('night')) return Colors.indigo.shade900;
    return Colors.orange.shade600;
  }

  @override
  Widget build(BuildContext context) {
    final w = vm.weatherData!;
    final icon = _iconFor(w.condition);
    final color = _colorFor(w.condition);

    return GestureDetector(
      onTap: () => vm.refreshWeather(force: true),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.15),
              blurRadius: 6,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18, color: color),
            const SizedBox(width: 5),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  "${w.tempC.toStringAsFixed(1)}°C",
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    height: 1.1,
                  ),
                ),
                Text(
                  w.condition,
                  style: TextStyle(
                    fontSize: 10,
                    color: Colors.grey.shade600,
                    height: 1.1,
                  ),
                ),
                Text(
                  "💨 ${w.windSpeedKmh.toStringAsFixed(0)} km/h · 💧${w.humidity}%",
                  style: TextStyle(
                    fontSize: 9,
                    color: Colors.grey.shade500,
                    height: 1.2,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ── GREETING BANNER ──────────────────────────────────────────────────
class _GreetingBanner extends StatelessWidget {
  String _greeting() {
    final h = DateTime.now().hour;
    if (h < 12) return 'Good morning';
    if (h < 17) return 'Good afternoon';
    return 'Good evening';
  }

  @override
  Widget build(BuildContext context) {
    final authVm = Provider.of<AuthViewModel>(context, listen: false);
    final driver = authVm.currentDriver;
    if (driver == null) return const SizedBox.shrink();

    final firstName = driver.name.split(' ').first;
    final vm = context.watch<MapVM>();
    final stopCount = vm.currentStops.length;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.15),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Text('👋', style: TextStyle(fontSize: 14)),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              '${_greeting()}, $firstName!',
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Colors.black87,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (stopCount > 0) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: const Color(0xFF6366F1),
                borderRadius: BorderRadius.circular(99),
              ),
              child: Text(
                '$stopCount stops',
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}