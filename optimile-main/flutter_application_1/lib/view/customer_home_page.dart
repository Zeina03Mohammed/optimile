import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:file_picker/file_picker.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:csv/csv.dart';

import 'login.dart';
import '../services/package_service.dart';

class CustomerHomePage extends StatefulWidget {
  const CustomerHomePage({super.key});

  @override
  State<CustomerHomePage> createState() => _CustomerHomePageState();
}

class _CustomerHomePageState extends State<CustomerHomePage> {
  bool isUploading = false;

  String get userEmail {
    final email = FirebaseAuth.instance.currentUser?.email;
    if (email == null || email.isEmpty) {
      throw Exception("User not logged in properly");
    }
    return email;
  }

  User get currentUser => FirebaseAuth.instance.currentUser!;

  Future<void> uploadCsv() async {
    setState(() => isUploading = true);

    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['csv'],
        withData: true,
        allowMultiple: false,
      );

      if (result == null || result.files.isEmpty) {
        setState(() => isUploading = false);
        return;
      }

      final file = result.files.first;

      Uint8List? fileBytes = file.bytes;

      if (fileBytes == null && file.path != null) {
        fileBytes = await File(file.path!).readAsBytes();
      }

      if (fileBytes == null) {
        _showSnack("File not loaded ❌");
        return;
      }

      final service = PackageService();
      await service.uploadPackagesFromCsv(fileBytes);

      _showSnack("Upload Success 🚀", success: true);

    } catch (e) {
      print("UPLOAD ERROR: $e");
      _showSnack("Error: $e");
    } finally {
      if (mounted) setState(() => isUploading = false);
    }
  }

  Future<void> _showEditDialog(String docId, Map<String, dynamic> data) async {
    final nameController =
        TextEditingController(text: data['customer_name']);
    final phoneController =
        TextEditingController(text: data['phone']);

    String status = data['status'] ?? 'pending';

    DateTime? deliveryDate = data['delivery_date'] != null
        ? (data['delivery_date'] as Timestamp).toDate()
        : null;

    await showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setStateDialog) {
            return AlertDialog(
              title: const Text("Edit Order"),
              content: SingleChildScrollView(
                child: Column(
                  children: [
                    TextField(
                      controller: nameController,
                      decoration:
                          const InputDecoration(labelText: "Customer Name"),
                    ),
                    TextField(
                      controller: phoneController,
                      decoration:
                          const InputDecoration(labelText: "Phone"),
                    ),
                    DropdownButtonFormField<String>(
                      value: status,
                      items: const [
                        DropdownMenuItem(value: 'pending', child: Text('Pending')),
                        DropdownMenuItem(value: 'delivered', child: Text('Delivered')),
                        DropdownMenuItem(value: 'cancelled', child: Text('Cancelled')),
                      ],
                      onChanged: (value) {
                        if (value != null) {
                          setStateDialog(() => status = value);
                        }
                      },
                      decoration: const InputDecoration(labelText: "Status"),
                    ),
                    const SizedBox(height: 15),

                    // DATE
                    ElevatedButton(
                      onPressed: () async {
                        final pickedDate = await showDatePicker(
                          context: context,
                          initialDate: deliveryDate ?? DateTime.now(),
                          firstDate: DateTime(2020),
                          lastDate: DateTime(2030),
                        );

                        if (pickedDate != null) {
                          setStateDialog(() {
                            if (deliveryDate == null) {
                              deliveryDate = DateTime(
                                pickedDate.year,
                                pickedDate.month,
                                pickedDate.day,
                              );
                            } else {
                              deliveryDate = DateTime(
                                pickedDate.year,
                                pickedDate.month,
                                pickedDate.day,
                                deliveryDate!.hour,
                                deliveryDate!.minute,
                              );
                            }
                          });
                        }
                      },
                      child: Text(
                        deliveryDate == null
                            ? "Select Delivery Date 📅"
                            : "Date: ${deliveryDate!.toLocal().toString().split(' ')[0]}",
                      ),
                    ),

                    const SizedBox(height: 10),

                    // TIME
                    ElevatedButton(
                      onPressed: () async {
                        final pickedTime = await showTimePicker(
                          context: context,
                          initialTime: TimeOfDay.fromDateTime(
                            deliveryDate ?? DateTime.now(),
                          ),
                        );

                        if (pickedTime != null) {
                          setStateDialog(() {
                            deliveryDate = DateTime(
                              deliveryDate?.year ?? DateTime.now().year,
                              deliveryDate?.month ?? DateTime.now().month,
                              deliveryDate?.day ?? DateTime.now().day,
                              pickedTime.hour,
                              pickedTime.minute,
                            );
                          });
                        }
                      },
                      child: Text(
                        deliveryDate == null ||
                                (deliveryDate!.hour == 0 &&
                                    deliveryDate!.minute == 0)
                            ? "Select Time ⏰"
                            : "Time: ${deliveryDate!.hour}:${deliveryDate!.minute.toString().padLeft(2, '0')}",
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text("Cancel"),
                ),
                ElevatedButton(
                  onPressed: () async {
                    await FirebaseFirestore.instance
                        .collection('packages')
                        .doc(docId)
                        .update({
                      "customer_name": nameController.text,
                      "phone": phoneController.text,
                      "status": status,
                      "delivery_date": deliveryDate ?? FieldValue.serverTimestamp(),
                    });

                    Navigator.pop(context);
                  },
                  child: const Text("Save"),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _showSnack(String msg, {bool success = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: success ? Colors.green : Colors.red,
      ),
    );
  }

  Color _statusColor(String status) {
    switch (status) {
      case 'delivered':
        return Colors.green;
      case 'pending':
        return Colors.orange;
      case 'cancelled':
        return Colors.red;
      default:
        return Colors.grey;
    }
  }

  IconData _statusIcon(String status) {
    switch (status) {
      case 'delivered':
        return Icons.check_circle;
      case 'pending':
        return Icons.pending;
      case 'cancelled':
        return Icons.cancel;
      default:
        return Icons.help;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("My Orders"),
        centerTitle: true,
        elevation: 2,
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: () async {
              await FirebaseAuth.instance.signOut();
              Navigator.pushAndRemoveUntil(
                context,
                MaterialPageRoute(
                  builder: (context) => const LoginPage(),
                ),
                (route) => false,
              );
            },
          ),
          IconButton(
            icon: isUploading
                ? const Padding(
                    padding: EdgeInsets.all(8),
                    child: CircularProgressIndicator(
                      color: Colors.white,
                      strokeWidth: 2,
                    ),
                  )
                : const Icon(Icons.upload),
            onPressed: isUploading ? null : uploadCsv,
          ),
        ],
      ),

      body: RefreshIndicator(
        onRefresh: () async {
          setState(() {});
        },
        child: StreamBuilder<QuerySnapshot>(
          stream: FirebaseFirestore.instance
              .collection('packages')
              .where("created_by_id", isEqualTo: currentUser.uid)
              .orderBy("created_at", descending: true)
              .snapshots(),
          builder: (context, snapshot) {
            if (snapshot.connectionState ==
                ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }

            if (snapshot.hasError) {
              return Center(child: Text("Error: ${snapshot.error}"));
            }

            final orders = snapshot.data?.docs ?? [];

            if (orders.isEmpty) {
              return ListView(
                children: const [
                  SizedBox(height: 150),
                  Icon(Icons.inbox, size: 80, color: Colors.grey),
                  SizedBox(height: 10),
                  Center(
                    child: Text(
                      "No orders yet",
                      style: TextStyle(fontSize: 18, color: Colors.grey),
                    ),
                  ),
                ],
              );
            }

            return ListView.builder(
              padding: const EdgeInsets.all(10),
              itemCount: orders.length,
              itemBuilder: (context, index) {
                final data =
                    orders[index].data() as Map<String, dynamic>;

                final status = data['status'] ?? 'pending';

                return Card(
                  elevation: 4,
                  margin: const EdgeInsets.symmetric(vertical: 6),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment:
                          CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment:
                              MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              data['customer_name'] ?? "Unknown",
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            Row(
                              children: [
                                Icon(
                                  _statusIcon(status),
                                  color: _statusColor(status),
                                ),
                                const SizedBox(width: 5),
                                Text(
                                  status,
                                  style: TextStyle(
                                    color: _statusColor(status),
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                        const Divider(),
                        _infoRow("📍 Area", data['area'] ?? "-"),
                        _infoRow("📦 Package", data['package_size'] ?? "-"),
                        _infoRow("🚚 Driver",
                            data['driver_name'] ?? "Not assigned"),
                        _infoRow("📞 Phone", data['phone'] ?? "-"),
                        _infoRow(
                          "📅 Delivery",
                          data['delivery_date'] != null
                              ? (data['delivery_date'] as Timestamp)
                                  .toDate()
                                  .toString()
                              : "Not set",
                        ),
                        const SizedBox(height: 10),
                        ElevatedButton(
                          onPressed: () {
                            _showEditDialog(orders[index].id, data);
                          },
                          child: const Text("Edit ✏️"),
                        ),
                      ],
                    ),
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }

  Widget _infoRow(String title, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Text("$title: ",
              style: const TextStyle(fontWeight: FontWeight.bold)),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }
}