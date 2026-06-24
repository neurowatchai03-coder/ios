// Stub replacement for `workmanager` on platforms where it's unused (iOS/web).
// Mirrors only the symbols main.dart references.
// This file is used via conditional import in main.dart:
//   import 'package:workmanager/workmanager.dart' as wm
//   if (dart.library.html) 'stub_workmanager.dart' as wm;

class Constraints {
  final NetworkType networkType;
  const Constraints({required this.networkType});
}

enum NetworkType { connected, notRequired }

enum ExistingWorkPolicy { keep, replace, append }

class Workmanager {
  static final Workmanager _instance = Workmanager._internal();
  factory Workmanager() => _instance;
  Workmanager._internal();

  Future<void> initialize(Function callback, {bool isInDebugMode = false}) async {}

  Future<void> registerPeriodicTask(
      String uniqueName,
      String taskName, {
        Duration? frequency,
        Constraints? constraints,
        ExistingWorkPolicy? existingWorkPolicy,
      }) async {}

  Future<void> executeTask(
      Future<bool> Function(String, Map<String, dynamic>?) callback,
      ) async {}
}