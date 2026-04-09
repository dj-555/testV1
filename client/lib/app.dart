import 'package:flutter/material.dart';

import 'quran_live_class_page.dart';

class QuranLiveClassApp extends StatelessWidget {
  const QuranLiveClassApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Quran Live Class',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        useMaterial3: true,
      ),
      home: const QuranLiveClassPage(),
    );
  }
}
