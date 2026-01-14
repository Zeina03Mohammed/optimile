import 'package:flutter/material.dart';
import 'driver.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Driver Dashboard',
      theme: ThemeData.dark(useMaterial3: true),
      home: const DriverMapTab(),
    );
  }
}
