import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:quran_live_class_client/app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations(
    <DeviceOrientation>[DeviceOrientation.portraitUp],
  );
  runApp(const QuranLiveClassApp());
}
