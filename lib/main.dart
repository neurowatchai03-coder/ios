import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_core/firebase_core.dart';

import 'login_screen.dart';
import 'register_screen.dart';
import 'dashboard.dart';

// Only import workmanager on Android
import 'package:workmanager/workmanager.dart' as wm
if (dart.library.html) 'stub_workmanager.dart';

////////////////////////////////////////////////////////////
/// Lifecycle channel — Android only
////////////////////////////////////////////////////////////

const _lifecycleChannel = MethodChannel('com.example.untitled5/lifecycle');

Future<void> notifyUserLoggedIn() async {
if (defaultTargetPlatform != TargetPlatform.android) return;
try {
await _lifecycleChannel.invokeMethod('onUserLoggedIn');
} catch (_) {}
}

////////////////////////////////////////////////////////////
/// WORKMANAGER — Android only
////////////////////////////////////////////////////////////

@pragma('vm:entry-point')
void callbackDispatcher() {
wm.Workmanager().executeTask((task, inputData) async {
try {
await Firebase.initializeApp();
} catch (e) {
debugPrint("BG TASK ERROR: $e");
}
return Future.value(true);
});
}

Future<void> ensureBackgroundTask() async {
if (defaultTargetPlatform != TargetPlatform.android) return;
try {
await wm.Workmanager().initialize(
callbackDispatcher,
isInDebugMode: false,
);
await wm.Workmanager().registerPeriodicTask(
"usage_report_task",
"autoReport",
frequency: const Duration(minutes: 15),
constraints: wm.Constraints(
networkType: wm.NetworkType.connected,
),
existingWorkPolicy: wm.ExistingWorkPolicy.keep,
);
} catch (e) {
debugPrint("WorkManager error: $e");
}
}

////////////////////////////////////////////////////////////
/// MAIN
////////////////////////////////////////////////////////////

Future<void> main() async {
WidgetsFlutterBinding.ensureInitialized();

// Keep Android navigation buttons visible
await SystemChrome.setEnabledSystemUIMode(
SystemUiMode.edgeToEdge,

);

await Firebase.initializeApp();

if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
try {
await ensureBackgroundTask();
} catch (e) {
debugPrint("Background task init error: $e");
}
}

runApp(const MyApp());
}

////////////////////////////////////////////////////////////
/// APP
////////////////////////////////////////////////////////////

class MyApp extends StatelessWidget {
const MyApp({super.key});

@override
Widget build(BuildContext context) {
return MaterialApp(
debugShowCheckedModeBanner: false,
theme: ThemeData.dark(),
home: const SplashScreen(),
);
}
}

////////////////////////////////////////////////////////////
/// SPLASH SCREEN
////////////////////////////////////////////////////////////

class SplashScreen extends StatefulWidget {
const SplashScreen({super.key});

@override
State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
@override
void initState() {
super.initState();
_initAndNavigate();
}

Future<void> _initAndNavigate() async {
try {
final prefs = await SharedPreferences.getInstance();
final loggedIn  = prefs.getBool("loggedIn")   ?? false;
final userEmail = prefs.getString("userEmail") ?? "";
final userName  = prefs.getString("userName")  ?? "";

if (loggedIn && userEmail.isNotEmpty) {
// Android-only background tasks
if (defaultTargetPlatform == TargetPlatform.android) {
await ensureBackgroundTask();
await notifyUserLoggedIn();
}

if (!mounted) return;
Navigator.of(context).pushReplacement(
MaterialPageRoute(
builder: (_) => Dashboard(
userEmail: userEmail,
userName: userName,
),
),
);
} else if (userEmail.isNotEmpty) {
if (!mounted) return;
Navigator.of(context).pushReplacement(
MaterialPageRoute(builder: (_) => const LoginScreen()),
);
} else {
if (!mounted) return;
Navigator.of(context).pushReplacement(
MaterialPageRoute(builder: (_) => const RegisterScreen()),
);
}
} catch (e) {
debugPrint("Splash init error: $e");
// On any error, fallback to register screen
if (!mounted) return;
Navigator.of(context).pushReplacement(
MaterialPageRoute(builder: (_) => const RegisterScreen()),
);
}
}

@override
Widget build(BuildContext context) {
return Scaffold(
backgroundColor: Colors.black,
body: SizedBox.expand(
child: Image.asset(
'assets/splash_logo.png',
fit: BoxFit.cover,
),
),
);
}
}