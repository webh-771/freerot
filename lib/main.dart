import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'data/catalog.dart';
import 'data/library.dart';
import 'data/web/web_session.dart';
import 'ui/shell.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(appOverlayStyle);
  await Library.init();
  Catalog.instance.warmUp();
  runApp(const FreeRotApp());
}

class FreeRotApp extends StatelessWidget {
  const FreeRotApp({super.key});

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: appOverlayStyle,
      child: MaterialApp(
        title: 'FreeRot',
        debugShowCheckedModeBanner: false,
        theme: buildAppTheme(),
        darkTheme: buildAppTheme(),
        themeMode: ThemeMode.dark,
        builder: (context, child) => WebSessionHost(child: child!),
        home: const AppShell(),
      ),
    );
  }
}
