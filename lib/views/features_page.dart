// ignore_for_file: library_private_types_in_public_api

import 'package:demo_ai_even/views/faces/face_settings_page.dart';
import 'package:demo_ai_even/views/features/bmp_page.dart';
import 'package:demo_ai_even/views/features/notification/notification_page.dart';
import 'package:demo_ai_even/views/features/text_page.dart';
import 'package:flutter/material.dart';

class FeaturesPage extends StatefulWidget {
  const FeaturesPage({super.key});

  @override
  _FeaturesPageState createState() => _FeaturesPageState();
}

class _FeaturesPageState extends State<FeaturesPage> {
  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: const Color(0xFFF2F3F5),
        appBar: AppBar(
          title: const Text('Features'),
          backgroundColor: Colors.white,
          elevation: 0,
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 44),
          children: [
            _tile(
              icon: Icons.watch_later_outlined,
              title: 'Even Faces',
              subtitle:
                  'Uhr, eigener Text und Diagnose auf der Brille — mit Tippen umschalten',
              highlighted: true,
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (context) => const FaceSettingsPage()),
              ),
            ),
            _tile(
              icon: Icons.image_outlined,
              title: 'BMP',
              subtitle: 'Ein einzelnes 1-Bit-Bild an beide Gläser schicken',
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const BmpPage()),
              ),
            ),
            _tile(
              icon: Icons.notifications_none,
              title: 'Notification',
              subtitle: 'Eine Testbenachrichtigung an die Brille senden',
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (context) => const NotificationPage()),
              ),
            ),
            _tile(
              icon: Icons.text_fields,
              title: 'Text',
              subtitle: 'Text seitenweise auf dem Display anzeigen',
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const TextPage()),
              ),
            ),
          ],
        ),
      );

  Widget _tile({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    bool highlighted = false,
  }) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Material(
          color: Colors.white,
          borderRadius: BorderRadius.circular(kRadius),
          child: InkWell(
            borderRadius: BorderRadius.circular(kRadius),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
              child: Row(
                children: [
                  Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: highlighted
                          ? const Color(0xFF14351F)
                          : const Color(0xFFF0F1F3),
                      borderRadius: BorderRadius.circular(11),
                    ),
                    child: Icon(icon,
                        size: 20,
                        color: highlighted ? kPanelGreen : Colors.black54),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title,
                            style: const TextStyle(
                                fontSize: 15.5, fontWeight: FontWeight.w600)),
                        const SizedBox(height: 3),
                        Text(subtitle,
                            style: const TextStyle(
                                fontSize: 12.5,
                                height: 1.3,
                                color: Colors.black54)),
                      ],
                    ),
                  ),
                  const Icon(Icons.chevron_right,
                      size: 20, color: Colors.black26),
                ],
              ),
            ),
          ),
        ),
      );
}
