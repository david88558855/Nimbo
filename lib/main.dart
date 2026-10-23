import 'package:flutter/material.dart';

import 'app/theme.dart';
import 'pages/shell.dart';
import 'state/app_state.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final state = AppState();
  await state.boot();
  runApp(NimboApp(state: state));
}

class NimboApp extends StatelessWidget {
  const NimboApp({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Nimbo',
      debugShowCheckedModeBanner: false,
      theme: buildNimboTheme(),
      home: AnimatedBuilder(
        animation: state,
        builder: (context, _) => NimboShell(state: state),
      ),
    );
  }
}
