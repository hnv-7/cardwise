import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'services/sms_source.dart';
import 'services/vault.dart';
import 'state/app_state.dart';
import 'ui/home_shell.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterError.onError = (details) {
    // Keep details out of the UI; surface only in debug console.
    FlutterError.dumpErrorToConsole(details);
  };
  runApp(
    ChangeNotifierProvider(
      create: (_) =>
          AppState(vault: EncryptedFileVault(), sms: PlatformSmsSource())
            ..load(),
      child: const CardwiseApp(),
    ),
  );
}

class CardwiseApp extends StatelessWidget {
  const CardwiseApp({super.key});

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF3B5BDB);
    return MaterialApp(
      title: 'Cardwise',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: seed),
        useMaterial3: true,
        cardTheme: const CardThemeData(margin: EdgeInsets.zero),
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: seed,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
        cardTheme: const CardThemeData(margin: EdgeInsets.zero),
      ),
      home: const HomeShell(),
    );
  }
}
