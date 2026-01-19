import 'package:flutter/material.dart';
import 'driver.dart';

void main() => runApp(MyApp());

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Driver Map App',
      theme: ThemeData(primarySwatch: Colors.blue),
      home: MapScreen(),
    );
  }
}
