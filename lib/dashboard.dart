import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import 'login_screen.dart';
import 'loved_ones_tab.dart';
import 'ai_service.dart';

enum _StatusLevel { good, moderate, bad, neutral }

class _ChipData {
  final IconData icon;
  final Color iconColor;
  final Color iconBg;
  final String label;
  final String statusText;
  final _StatusLevel level;

  const _ChipData({
    required this.icon,
    required this.iconColor,
    required this.iconBg,
    required this.label,
    required this.statusText,
    required this.level,
  });
}

class Dashboard extends StatefulWidget {
  final String userEmail;
  final String userName;

  const Dashboard({
    super.key,
    required this.userEmail,
    required this.userName,
  });

  @override
  State<Dashboard> createState() => _DashboardState();
}

class _StatCard {
  final IconData icon;
  final Color iconColor;
  final Color iconBg;
  final String label;
  final String value;
  final int? currentVal;
  final int? previousVal;
  final bool deltaIsGoodWhenPositive;

  const _StatCard({
    required this.icon,
    required this.iconColor,
    required this.iconBg,
    required this.label,
    required this.value,
    this.currentVal,
    this.previousVal,
    this.deltaIsGoodWhenPositive = true,
  });
}

class _DashboardState extends State<Dashboard> {
  // Only used on Android
  static const _channel = MethodChannel('com.example.untitled5/usage');

  // Whether we're on Android
  bool get _isAndroid => defaultTargetPlatform == TargetPlatform.android;

  int _currentIndex = 0;

  final List<DateTime> _days = List.generate(
    30,
        (i) => DateTime.now().subtract(Duration(days: 29 - i)),
  );
  late DateTime _selectedDay = _days.last;

  final Set<String> _firebaseDaysWithData = {};
  final Set<String> _localDaysWithData    = {};
  bool _localDaysChecked = false;

  StreamSubscription? _reportSub;
  String _rawReport     = "";
  String _myLastUpdated = "";
  bool _reportLoaded    = false;

  bool _localLoaded      = false;
  bool _usingLocalData   = false;
  bool _permissionGranted = true;

  List<AppRow> _appRows        = [];
  Map<String, dynamic> _iconsMap = {};

  int? _focusMinutes;
  int? _pickups;
  int? _prevTotalMins;
  int? _prevApps;
  int? _prevFocusMins;
  int? _prevPickups;

  String? _screenTimeStatus;
  String? _focusTimeStatus;
  String? _sleepImpactStatus;

  Map<String, int> _continuousUsage = {};

  bool _othersExpanded = false;

  @override
  void initState() {
    super.initState();
    _subscribeDay(_selectedDay);
    if (_isAndroid) {
      Future.microtask(_loadLocalDaysWithData);
      Future.microtask(_checkFirebaseDaysWithData);
    } else {
      // On iOS just mark local checks as done
      setState(() {
        _localDaysChecked  = true;
        _localLoaded       = true;
        _permissionGranted = true;
      });
      Future.microtask(_checkFirebaseDaysWithData);
    }
  }

  @override
  void dispose() {
    _reportSub?.cancel();
    super.dispose();
  }

  // ── Android-only: local usage channel calls ───────────────────────────────

  Future<void> _loadLocalDaysWithData() async {
    if (!_isAndroid) {
      setState(() { _localDaysChecked = true; });
      return;
    }
    try {
      final raw = await _channel.invokeMethod<String>('getLocalDaysWithData');
      if (raw == null || !mounted) return;
      final list = (jsonDecode(raw) as List).cast<String>();
      setState(() {
        _localDaysWithData.addAll(list);
        _localDaysChecked  = true;
        _permissionGranted = true;
      });
    } on PlatformException catch (e) {
      if (e.code == 'PERMISSION_DENIED') {
        if (mounted) setState(() { _permissionGranted = false; _localDaysChecked = true; });
      } else {
        if (mounted) setState(() => _localDaysChecked = true);
      }
    } catch (_) {
      if (mounted) setState(() => _localDaysChecked = true);
    }
  }

  Future<void> _fetchLocalUsageForDay(DateTime day) async {
    if (!_isAndroid) {
      setState(() { _localLoaded = true; });
      return;
    }
    final key = _dateKey(day);
    try {
      String? result;
      if (_isToday(day)) {
        result = await _channel.invokeMethod<String>('getTodayUsage');
      } else {
        result = await _channel.invokeMethod<String>(
          'getUsageForDate', {'dateKey': key},
        );
      }
      if (!mounted) return;
      if (result == null) {
        setState(() { _permissionGranted = false; _localLoaded = true; });
        return;
      }
      final json = jsonDecode(result) as Map<String, dynamic>;
      _applyLocalData(json, day);
    } on PlatformException catch (e) {
      if (mounted) {
        setState(() {
          _permissionGranted = e.code != 'PERMISSION_DENIED';
          _localLoaded       = true;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _localLoaded = true);
    }
  }

  void _applyLocalData(Map<String, dynamic> json, DateTime day) {
    if (!mounted) return;
    if (_rawReport.isNotEmpty && !_usingLocalData) {
      setState(() => _localLoaded = true);
      return;
    }
    if (_dateKey(day) != _dateKey(_selectedDay)) {
      setState(() => _localLoaded = true);
      return;
    }

    final icons      = Map<String, dynamic>.from(json['icons'] ?? {});
    final rawReport  = json['report'] as String? ?? '';
    final rawCont    = Map<String, dynamic>.from(json['continuousUsage'] ?? {});
    final parsedCont = <String, int>{};
    rawCont.forEach((k, v) {
      final mins = (v as num?)?.toInt();
      if (mins != null && mins >= 40) parsedCont[k] = mins;
    });

    setState(() {
      _localLoaded       = true;
      _permissionGranted = true;
      _usingLocalData    = rawReport.isNotEmpty &&
          !rawReport.contains('No app usage recorded');
      if (_usingLocalData) {
        _rawReport         = rawReport;
        _iconsMap          = icons;
        _appRows           = _parseReport(rawReport, icons);
        _reportLoaded      = true;
        _myLastUpdated     = json['updatedAt'] as String? ?? '';
        _focusMinutes      = (json['focusMinutes'] as num?)?.toInt();
        _pickups           = (json['pickups'] as num?)?.toInt();
        _screenTimeStatus  = json['screenTimeStatus'] as String?;
        _focusTimeStatus   = json['focusTimeStatus'] as String?;
        _sleepImpactStatus = json['sleepImpactStatus'] as String?;
        _continuousUsage   = parsedCont;
      } else {
        _reportLoaded = true;
      }
    });
  }

  Future<void> _openUsageSettings() async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod('openUsageSettings');
    } catch (_) {}
  }

  // ── Firebase ──────────────────────────────────────────────────────────────

  Future<void> _checkFirebaseDaysWithData() async {
    final futures = <Future>[];
    for (final day in _days) {
      if (_isToday(day)) {
        futures.add(
          FirebaseFirestore.instance
              .collection("reports")
              .doc(widget.userEmail)
              .get()
              .then((snap) {
            if (snap.exists && mounted) {
              setState(() => _firebaseDaysWithData.add(_dateKey(day)));
            }
          }).catchError((_) {}),
        );
      } else {
        final key = _dateKey(day);
        futures.add(
          FirebaseFirestore.instance
              .collection("reports")
              .doc(widget.userEmail)
              .collection("days")
              .doc(key)
              .get()
              .then((snap) {
            if (snap.exists && mounted) {
              setState(() => _firebaseDaysWithData.add(key));
            }
          }).catchError((_) {}),
        );
      }
    }
    await Future.wait(futures);
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  String _dateKey(DateTime d) =>
      "${d.year.toString().padLeft(4, '0')}-"
          "${d.month.toString().padLeft(2, '0')}-"
          "${d.day.toString().padLeft(2, '0')}";

  bool _isToday(DateTime d) {
    final now = DateTime.now();
    return d.year == now.year && d.month == now.month && d.day == now.day;
  }

  String _dayLabel(DateTime d) {
    if (_isToday(d)) return "Today";
    final diff = DateTime.now().difference(d).inDays;
    if (diff == 1) return "Yesterday";
    const months = [
      "Jan","Feb","Mar","Apr","May","Jun",
      "Jul","Aug","Sep","Oct","Nov","Dec"
    ];
    return "${d.day} ${months[d.month - 1]}";
  }

  String _shortDay(DateTime d) {
    const days = ["Mon","Tue","Wed","Thu","Fri","Sat","Sun"];
    return days[d.weekday - 1];
  }

  String _fmtMins(int mins) {
    final h = mins ~/ 60;
    final m = mins % 60;
    if (h == 0) return "${m}m";
    return "${h}:${m.toString().padLeft(2, '0')}";
  }

  List<AppRow> _parseReport(String report, Map<String, dynamic> iconsMap) {
    final rows       = <AppRow>[];
    if (report.isEmpty) return rows;
    final lines      = report.split('\n');
    final durationRe = RegExp(r'(\d+h\s+\d+m|\d+m|\d+s)');

    for (final line in lines) {
      if (line.startsWith('─') ||
          line.startsWith('📅') ||
          line.trim().isEmpty) continue;

      String parseLine = line;
      String pkg       = '';
      final pipeIdx    = line.lastIndexOf('|');
      if (pipeIdx != -1) {
        pkg       = line.substring(pipeIdx + 1).trim();
        parseLine = line.substring(0, pipeIdx);
      }

      final dMatch = durationRe.firstMatch(parseLine);
      if (dMatch == null) continue;

      final duration = dMatch.group(0)!.trim();
      final appName  = parseLine.substring(0, dMatch.start).trim();
      if (appName == 'TOTAL' || appName.isEmpty) continue;

      final hMatch = RegExp(r'(\d+)h').firstMatch(duration);
      final mMatch = RegExp(r'(\d+)m').firstMatch(duration);
      final sMatch = RegExp(r'(\d+)s').firstMatch(duration);
      final h = int.tryParse(hMatch?.group(1) ?? '0') ?? 0;
      final m = int.tryParse(mMatch?.group(1) ?? '0') ?? 0;
      final s = int.tryParse(sMatch?.group(1) ?? '0') ?? 0;
      final durMs = (h * 3600 + m * 60 + s) * 1000;

      Uint8List? iconBytes;
      if (pkg.isNotEmpty) {
        final b64 = iconsMap[pkg] as String? ?? '';
        if (b64.isNotEmpty) {
          try { iconBytes = base64Decode(b64); } catch (_) {}
        }
      }

      rows.add(AppRow(
        packageName: pkg,
        appName:     appName,
        duration:    duration,
        durationMs:  durMs,
        iconBytes:   iconBytes,
      ));
    }
    return rows;
  }

  int _parseTotalMins() {
    for (final line in _rawReport.split('\n')) {
      if (line.trim().startsWith('TOTAL')) {
        final hMatch = RegExp(r'(\d+)h').firstMatch(line);
        final mMatch = RegExp(r'(\d+)m').firstMatch(line);
        return (int.tryParse(hMatch?.group(1) ?? '0') ?? 0) * 60 +
            (int.tryParse(mMatch?.group(1) ?? '0') ?? 0);
      }
    }
    return 0;
  }

  void _subscribeDay(DateTime day) {
    _reportSub?.cancel();
    setState(() {
      _selectedDay       = day;
      _rawReport         = "";
      _appRows           = [];
      _iconsMap          = {};
      _reportLoaded      = false;
      _localLoaded       = !_isAndroid; // iOS: skip local loading
      _usingLocalData    = false;
      _focusMinutes      = null;
      _pickups           = null;
      _prevTotalMins     = null;
      _prevApps          = null;
      _prevFocusMins     = null;
      _prevPickups       = null;
      _screenTimeStatus  = null;
      _focusTimeStatus   = null;
      _sleepImpactStatus = null;
      _continuousUsage   = {};
      _othersExpanded    = false;
    });

    // Only fetch local data on Android
    if (_isAndroid && _permissionGranted) {
      Future.microtask(() => _fetchLocalUsageForDay(day));
    }

    final docRef = _isToday(day)
        ? FirebaseFirestore.instance
        .collection("reports")
        .doc(widget.userEmail)
        : FirebaseFirestore.instance
        .collection("reports")
        .doc(widget.userEmail)
        .collection("days")
        .doc(_dateKey(day));

    _reportSub = docRef.snapshots().listen((snap) {
      if (!snap.exists) {
        if (mounted) {
          setState(() {
            if (!_usingLocalData) {
              _rawReport         = "";
              _appRows           = [];
              _reportLoaded      = _localLoaded;
              _screenTimeStatus  = null;
              _focusTimeStatus   = null;
              _sleepImpactStatus = null;
              _continuousUsage   = {};
            }
          });
        }
        return;
      }

      final data  = snap.data()!;
      final icons = Map<String, dynamic>.from(data["icons"] ?? {});
      final rawCont    = Map<String, dynamic>.from(data["continuousUsage"] ?? {});
      final parsedCont = <String, int>{};
      rawCont.forEach((k, v) {
        final mins = (v as num?)?.toInt();
        if (mins != null && mins >= 40) parsedCont[k] = mins;
      });

      if (mounted) {
        setState(() {
          _usingLocalData    = false;
          _rawReport         = data["report"] ?? "";
          _myLastUpdated     = data["updatedAt"] ?? "";
          _iconsMap          = icons;
          _appRows           = _parseReport(_rawReport, icons);
          _reportLoaded      = true;
          _localLoaded       = true;
          _focusMinutes      = (data["focusMinutes"] as num?)?.toInt();
          _pickups           = (data["pickups"] as num?)?.toInt();
          _prevTotalMins     = (data["prevTotalMins"] as num?)?.toInt();
          _prevApps          = (data["prevApps"] as num?)?.toInt();
          _prevFocusMins     = (data["prevFocusMins"] as num?)?.toInt();
          _prevPickups       = (data["prevPickups"] as num?)?.toInt();
          _screenTimeStatus  = data["screenTimeStatus"] as String?;
          _focusTimeStatus   = data["focusTimeStatus"] as String?;
          _sleepImpactStatus = data["sleepImpactStatus"] as String?;
          _continuousUsage   = parsedCont;
          _firebaseDaysWithData.add(_dateKey(day));
        });
      }
    }, onError: (e) {
      if (mounted) {
        setState(() {
          if (!_usingLocalData) { _rawReport = ""; _appRows = []; }
          _reportLoaded = true;
          _localLoaded  = true;
        });
      }
    });
  }

  Future<void> _signOut() async {
    _reportSub?.cancel();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove("userEmail");
    await prefs.remove("userName");
    await prefs.setBool("loggedIn", false);
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const LoginScreen()),
    );
  }

  // ── Stat cards ────────────────────────────────────────────────────────────

  List<_StatCard> _buildStatData() {
    final totalMins = _parseTotalMins();
    final appCount  = _appRows.where((r) => r.durationMs >= 60000).length;
    return [
      _StatCard(
        icon: Icons.smartphone_rounded,
        iconColor: const Color(0xFF6C5CE7),
        iconBg: const Color(0xFFEDE9FB),
        label: "Screen Time",
        value: totalMins == 0 ? "—" : _fmtMins(totalMins),
        currentVal: totalMins,
        previousVal: _prevTotalMins,
        deltaIsGoodWhenPositive: false,
      ),
      _StatCard(
        icon: Icons.apps_rounded,
        iconColor: const Color(0xFF0984E3),
        iconBg: const Color(0xFFE3F2FF),
        label: "App Usage",
        value: appCount == 0 ? "—" : "$appCount Apps",
        currentVal: appCount,
        previousVal: _prevApps,
        deltaIsGoodWhenPositive: false,
      ),
      _StatCard(
        icon: Icons.track_changes_rounded,
        iconColor: const Color(0xFF00B894),
        iconBg: const Color(0xFFDFFAF4),
        label: "Focus Time",
        value: _focusMinutes == null ? "—" : _fmtMins(_focusMinutes!),
        currentVal: _focusMinutes,
        previousVal: _prevFocusMins,
        deltaIsGoodWhenPositive: true,
      ),
      _StatCard(
        icon: Icons.phone_iphone_rounded,
        iconColor: const Color(0xFFE17055),
        iconBg: const Color(0xFFFEEDE9),
        label: "Pickups",
        value: _pickups == null ? "—" : "${_pickups!} Times",
        currentVal: _pickups,
        previousVal: _prevPickups,
        deltaIsGoodWhenPositive: false,
      ),
    ];
  }

  // ── Status chips ──────────────────────────────────────────────────────────

  _StatusLevel _levelFor(
      String? value, Map<String, _StatusLevel> map) =>
      map[value] ?? _StatusLevel.neutral;

  Color _chipIconColor(_StatusLevel level) {
    switch (level) {
      case _StatusLevel.good:     return const Color(0xFF4CAF50);
      case _StatusLevel.moderate: return const Color(0xFFFFA726);
      case _StatusLevel.bad:      return const Color(0xFFE53935);
      case _StatusLevel.neutral:  return Colors.grey;
    }
  }

  Color _chipIconBg(_StatusLevel level) {
    switch (level) {
      case _StatusLevel.good:     return const Color(0xFFE8F5E9);
      case _StatusLevel.moderate: return const Color(0xFFFFF3E0);
      case _StatusLevel.bad:      return const Color(0xFFFFEBEE);
      case _StatusLevel.neutral:  return const Color(0xFFF5F5F5);
    }
  }

  Widget _buildStatusChips() {
    final stLevel = _levelFor(_screenTimeStatus, {
      "Within Limit": _StatusLevel.good,
      "Over Limit":   _StatusLevel.moderate,
      "Way Over":     _StatusLevel.bad,
    });
    final ftLevel = _levelFor(_focusTimeStatus, {
      "Excellent": _StatusLevel.good,
      "Good":      _StatusLevel.good,
      "Low":       _StatusLevel.moderate,
      "None":      _StatusLevel.bad,
    });
    final siLevel = _levelFor(_sleepImpactStatus, {
      "Low":      _StatusLevel.good,
      "Moderate": _StatusLevel.moderate,
      "High":     _StatusLevel.bad,
    });

    final chips = [
      _ChipData(
        icon: Icons.shield_outlined,
        iconColor: _chipIconColor(stLevel),
        iconBg: _chipIconBg(stLevel),
        label: "Screen Time",
        statusText: _screenTimeStatus ?? "—",
        level: stLevel,
      ),
      _ChipData(
        icon: Icons.track_changes_rounded,
        iconColor: _chipIconColor(ftLevel),
        iconBg: _chipIconBg(ftLevel),
        label: "Focus Time",
        statusText: _focusTimeStatus ?? "—",
        level: ftLevel,
      ),
      _ChipData(
        icon: Icons.bedtime_outlined,
        iconColor: _chipIconColor(siLevel),
        iconBg: _chipIconBg(siLevel),
        label: "Sleep Impact",
        statusText: _sleepImpactStatus ?? "—",
        level: siLevel,
      ),
    ];

    return Row(
      children: chips.asMap().entries.map((entry) => Expanded(
        child: Padding(
          padding: EdgeInsets.only(
              right: entry.key < chips.length - 1 ? 6.0 : 0),
          child: Container(
            padding: const EdgeInsets.all(13),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFFEEEEEE)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.05),
                  blurRadius: 10,
                  offset: const Offset(0, 3),
                )
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 36, height: 36,
                  decoration: BoxDecoration(
                    color: entry.value.iconBg,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(entry.value.icon,
                      color: entry.value.iconColor, size: 20),
                ),
                const SizedBox(height: 10),
                Text(entry.value.label,
                    style: const TextStyle(
                        color: Colors.grey,
                        fontSize: 11,
                        fontWeight: FontWeight.w500),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
                const SizedBox(height: 4),
                Text(entry.value.statusText,
                    style: TextStyle(
                      color: _chipIconColor(entry.value.level),
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.3,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
        ),
      )).toList(),
    );
  }

  // ── iOS info banner ───────────────────────────────────────────────────────

  Widget _buildIosBanner() {
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFFE3F2FD),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF1E88E5).withOpacity(0.4)),
      ),
      child: const Row(children: [
        Icon(Icons.info_outline_rounded, color: Color(0xFF1E88E5), size: 18),
        SizedBox(width: 10),
        Expanded(
          child: Text(
            "Screen time tracking is available on Android only. "
                "Cloud-synced reports from your Android device will appear here.",
            style: TextStyle(
                color: Color(0xFF1E88E5),
                fontSize: 12,
                fontWeight: FontWeight.w500),
          ),
        ),
      ]),
    );
  }

  // ── Permission card (Android only) ────────────────────────────────────────

  Widget _buildPermissionCard() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF8E1),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFFFB300)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            width: 40, height: 40,
            decoration: BoxDecoration(
              color: const Color(0xFFFFB300).withOpacity(0.15),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Icons.lock_clock_rounded,
                color: Color(0xFFFFB300), size: 22),
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text("Usage Access Required",
                      style: TextStyle(
                          color: Colors.black,
                          fontSize: 14,
                          fontWeight: FontWeight.w700)),
                  SizedBox(height: 2),
                  Text("Grant permission to see your app usage",
                      style: TextStyle(color: Colors.black54, fontSize: 12)),
                ]),
          ),
        ]),
        const SizedBox(height: 14),
        const Text(
          "To show your screen time and app usage report, this app needs "
              "Usage Access permission.\n\nGo to Settings → Apps → Special App "
              "Access → Usage Access and enable it for this app.",
          style: TextStyle(color: Colors.black87, fontSize: 12, height: 1.6),
        ),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          height: 46,
          child: ElevatedButton.icon(
            onPressed: _openUsageSettings,
            icon: const Icon(Icons.settings_rounded, size: 18),
            label: const Text("Open Usage Access Settings",
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFFFB300),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
              elevation: 0,
            ),
          ),
        ),
        const SizedBox(height: 10),
        SizedBox(
          width: double.infinity,
          height: 40,
          child: TextButton.icon(
            onPressed: () async {
              setState(() {
                _localLoaded       = false;
                _permissionGranted = true;
                _localDaysChecked  = false;
              });
              await _loadLocalDaysWithData();
              if (_permissionGranted) {
                await _fetchLocalUsageForDay(_selectedDay);
              }
            },
            icon: const Icon(Icons.refresh_rounded, size: 16),
            label: const Text("I've granted it — refresh",
                style: TextStyle(fontSize: 12)),
            style: TextButton.styleFrom(
                foregroundColor: const Color(0xFFFFB300)),
          ),
        ),
      ]),
    );
  }

  Widget _buildLocalDataBanner() => Container(
    margin: const EdgeInsets.only(bottom: 14),
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
    decoration: BoxDecoration(
      color: const Color(0xFFE3F2FD),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(
          color: const Color(0xFF1E88E5).withOpacity(0.4)),
    ),
    child: const Row(children: [
      SizedBox(
        width: 14, height: 14,
        child: CircularProgressIndicator(
            color: Color(0xFF1E88E5), strokeWidth: 2),
      ),
      SizedBox(width: 10),
      Expanded(
        child: Text(
          "Showing live on-device data — syncing to cloud…",
          style: TextStyle(
              color: Color(0xFF1E88E5),
              fontSize: 12,
              fontWeight: FontWeight.w500),
        ),
      ),
    ]),
  );

  Widget _buildLocalPastBanner() => Container(
    margin: const EdgeInsets.only(bottom: 14),
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
    decoration: BoxDecoration(
      color: const Color(0xFFF3E5F5),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(
          color: const Color(0xFF9C27B0).withOpacity(0.4)),
    ),
    child: const Row(children: [
      Icon(Icons.phone_android_rounded,
          color: Color(0xFF9C27B0), size: 16),
      SizedBox(width: 10),
      Expanded(
        child: Text(
          "Showing on-device history — not yet synced to cloud",
          style: TextStyle(
              color: Color(0xFF9C27B0),
              fontSize: 12,
              fontWeight: FontWeight.w500),
        ),
      ),
    ]),
  );

  // ── AI analysis ───────────────────────────────────────────────────────────

  Widget _buildAiAnalysis() {
    if (!_reportLoaded) return const SizedBox.shrink();
    final overused = _continuousUsage.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Container(
          width: 36, height: 36,
          decoration: BoxDecoration(
            color: const Color(0xFFF3E5F5),
            borderRadius: BorderRadius.circular(10),
          ),
          child: const Icon(Icons.auto_awesome_rounded,
              color: Color(0xFF9C27B0), size: 20),
        ),
        const SizedBox(width: 12),
        const Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text("AI Analysis",
                    style: TextStyle(
                        color: Colors.black,
                        fontSize: 16,
                        fontWeight: FontWeight.w700)),
                Text("Insights based on your usage patterns",
                    style: TextStyle(color: Colors.grey, fontSize: 12)),
              ]),
        ),
      ]),
      const SizedBox(height: 14),
      if (overused.isEmpty)
        _aiInfoCard(
          icon: Icons.check_circle_outline_rounded,
          iconColor: const Color(0xFF4CAF50),
          iconBg: const Color(0xFFE8F5E9),
          title: "Great balance today!",
          body: "No app was used continuously for more than 40 minutes. "
              "Balanced usage helps your focus and sleep quality.",
        )
      else
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFFFFCDD2)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.04),
                blurRadius: 10,
                offset: const Offset(0, 3),
              )
            ],
          ),
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Container(
                    width: 38, height: 38,
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFCDD2),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.warning_amber_rounded,
                        color: Color(0xFFD32F2F), size: 20),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            "${overused.length} app${overused.length > 1 ? 's' : ''} "
                                "detected with extended continuous use",
                            style: const TextStyle(
                                color: Colors.black,
                                fontSize: 13,
                                fontWeight: FontWeight.w700),
                          ),
                          const SizedBox(height: 4),
                          const Text(
                            "Apps used 40–60 min continuously are flagged as High Usage. "
                                "Apps used 60+ min without a break are Way Over Used. "
                                "Try the 20-20-20 rule: every 20 min, look 20 ft away for 20 sec.",
                            style: TextStyle(
                                color: Colors.grey, fontSize: 12, height: 1.5),
                          ),
                        ]),
                  ),
                ]),
                const SizedBox(height: 14),
                GestureDetector(
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => _FullInsightPage(
                        overused:           overused,
                        appRows:            _appRows,
                        iconsMap:           _iconsMap,
                        totalMins:          _parseTotalMins(),
                        focusMinutes:       _focusMinutes,
                        pickups:            _pickups,
                        screenTimeStatus:   _screenTimeStatus,
                        sleepImpactStatus:  _sleepImpactStatus,
                      ),
                    ),
                  ),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                        vertical: 12, horizontal: 16),
                    decoration: BoxDecoration(
                      color: const Color(0xFF48249A),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text("View Full Insight",
                              style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700)),
                          SizedBox(width: 8),
                          Icon(Icons.arrow_forward_rounded,
                              color: Colors.white, size: 16),
                        ]),
                  ),
                ),
              ]),
        ),
    ]);
  }

  Widget _aiInfoCard({
    required IconData icon,
    required Color iconColor,
    required Color iconBg,
    required String title,
    required String body,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: iconBg),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 10,
            offset: const Offset(0, 3),
          )
        ],
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: 38, height: 38,
          decoration: BoxDecoration(
              color: iconBg, borderRadius: BorderRadius.circular(10)),
          child: Icon(icon, color: iconColor, size: 20),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(
                        color: Colors.black,
                        fontSize: 13,
                        fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                Text(body,
                    style: const TextStyle(
                        color: Colors.grey, fontSize: 12, height: 1.5)),
              ]),
        ),
      ]),
    );
  }

  // ── Overview cards ────────────────────────────────────────────────────────

  Widget _buildOverviewCards() {
    final cards = _buildStatData();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(
        _isToday(_selectedDay)
            ? "Today's Device Usage Overview"
            : "${_dayLabel(_selectedDay)}'s Overview",
        style: const TextStyle(
            color: Colors.black,
            fontSize: 16,
            fontWeight: FontWeight.w700),
      ),
      const SizedBox(height: 4),
      Text(
        _isToday(_selectedDay)
            ? "See how you've used your phone today"
            : "Usage summary for ${_dayLabel(_selectedDay)}",
        style: const TextStyle(color: Colors.grey, fontSize: 13),
      ),
      const SizedBox(height: 16),
      LayoutBuilder(builder: (context, constraints) {
        final cardWidth = (constraints.maxWidth - 24) / 4;
        return Row(
          children: cards.asMap().entries.map((entry) => Padding(
            padding: EdgeInsets.only(
                right: entry.key < cards.length - 1 ? 8.0 : 0),
            child: SizedBox(
                width: cardWidth,
                child: _statCardTile(entry.value)),
          )).toList(),
        );
      }),
    ]);
  }

  Widget _statCardTile(_StatCard card) {
    Widget? deltaChip;
    if (card.currentVal != null &&
        card.previousVal != null &&
        card.previousVal! > 0) {
      final diff       = card.currentVal! - card.previousVal!;
      final pct        = ((diff / card.previousVal!) * 100).round().abs();
      final isPositive = diff > 0;
      final isGood =
      card.deltaIsGoodWhenPositive ? isPositive : !isPositive;
      final color =
      isGood ? const Color(0xFF00B894) : const Color(0xFFE17055);
      deltaChip = Text(
        "${isPositive ? '↑' : '↓'} $pct%",
        style: TextStyle(
            color: color, fontSize: 11, fontWeight: FontWeight.w600),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      );
    } else if (!_reportLoaded) {
      deltaChip = Container(
        height: 9,
        width: 40,
        decoration: BoxDecoration(
          color: Colors.grey.withOpacity(0.15),
          borderRadius: BorderRadius.circular(4),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFEEEEEE)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 10,
            offset: const Offset(0, 3),
          )
        ],
      ),
      child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 36, height: 36,
              decoration: BoxDecoration(
                color: card.iconBg,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(card.icon, color: card.iconColor, size: 20),
            ),
            const SizedBox(height: 10),
            Text(card.label,
                style: const TextStyle(
                    color: Colors.grey,
                    fontSize: 11,
                    fontWeight: FontWeight.w500),
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
            const SizedBox(height: 4),
            Text(
              !_reportLoaded ? "—" : card.value,
              style: const TextStyle(
                color: Color(0xFF1A1A2E),
                fontSize: 14,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.3,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            if (deltaChip != null) ...[
              const SizedBox(height: 5),
              deltaChip,
            ],
          ]),
    );
  }

  // ── App row tile ──────────────────────────────────────────────────────────

  Widget _appRowTile(AppRow row) {
    Widget icon;
    if (row.iconBytes != null) {
      icon = ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.memory(row.iconBytes!,
            width: 36, height: 36, fit: BoxFit.cover),
      );
    } else {
      icon = Container(
        width: 36, height: 36,
        decoration: BoxDecoration(
          color: const Color(0xFF2A2A2A),
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Icon(Icons.android_rounded,
            color: Colors.grey, size: 20),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(children: [
        icon,
        const SizedBox(width: 12),
        Expanded(
          child: Text(row.appName,
              style: const TextStyle(
                  color: Color(0xFF1B1A1A),
                  fontSize: 13,
                  fontWeight: FontWeight.w500),
              overflow: TextOverflow.ellipsis),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: const Color(0xFF48249A).withOpacity(0.08),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(row.duration,
              style: const TextStyle(
                  color: Color(0xFF48249A),
                  fontSize: 12,
                  fontWeight: FontWeight.w600)),
        ),
      ]),
    );
  }

  bool _isEmptyReport(String report) =>
      report.trim().isEmpty ||
          report.contains('No app usage recorded');

  // ── Report card ───────────────────────────────────────────────────────────

  Widget _reportCard() {
    final mainRows =
    _appRows.where((r) => r.durationMs >= 60000).toList();
    final othersRows = _appRows
        .where((r) => r.durationMs > 0 && r.durationMs < 60000)
        .toList();
    String total = "";
    for (final line in _rawReport.split('\n')) {
      if (line.trim().startsWith('TOTAL')) {
        final parts = line.trim().split(RegExp(r'\s{2,}'));
        if (parts.length >= 2) total = parts.last.trim();
        break;
      }
    }
    final title =
        "${widget.userName} — ${_dayLabel(_selectedDay)}'s Usage";
    final isEmpty =
        _appRows.isEmpty && _isEmptyReport(_rawReport);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFF9F7FF),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF916DEF)),
      ),
      child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Icon(Icons.bar_chart_rounded,
                  color: Color(0xFF4CAF50), size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(title,
                    style: const TextStyle(
                        color: Colors.black,
                        fontSize: 15,
                        fontWeight: FontWeight.w600),
                    overflow: TextOverflow.ellipsis),
              ),
              if (_myLastUpdated.isNotEmpty)
                Text(
                  _myLastUpdated.length > 19
                      ? _myLastUpdated.substring(0, 19)
                      : _myLastUpdated,
                  style:
                  const TextStyle(color: Colors.black, fontSize: 10),
                ),
            ]),
            const Divider(color: Color(0xFFDDDDDD), height: 20),
            if (isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Center(
                  child: Column(children: [
                    Container(
                      width: 56, height: 56,
                      decoration: const BoxDecoration(
                          color: Color(0xFFEDE9FB),
                          shape: BoxShape.circle),
                      child: const Icon(Icons.smartphone_rounded,
                          color: Color(0xFF48249A), size: 28),
                    ),
                    const SizedBox(height: 12),
                    const Text("No usage recorded this day",
                        style: TextStyle(
                            color: Colors.black,
                            fontSize: 14,
                            fontWeight: FontWeight.w600)),
                    const SizedBox(height: 6),
                    Padding(
                      padding:
                      const EdgeInsets.symmetric(horizontal: 16),
                      child: Text(
                        _isAndroid
                            ? "The device was either not used or the tracker "
                            "was not running on this day."
                            : "No usage data synced from your Android device "
                            "for this day.",
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            color: Colors.grey,
                            fontSize: 12,
                            height: 1.5),
                      ),
                    ),
                  ]),
                ),
              )
            else if (mainRows.isEmpty &&
                othersRows.isEmpty &&
                _rawReport.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(_rawReport,
                    style: const TextStyle(
                        color: Color(0xFF1B1A1A),
                        fontSize: 13,
                        height: 1.6,
                        fontFamily: "monospace")),
              )
            else ...[
                if (mainRows.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 6),
                    child: Text(
                      "No apps used for 1+ minute yet today.",
                      style: TextStyle(color: Colors.grey, fontSize: 12),
                    ),
                  )
                else
                  ...mainRows.map(_appRowTile),
                if (total.isNotEmpty) ...[
                  const Divider(color: Color(0xFFDDDDDD), height: 20),
                  Row(
                      mainAxisAlignment:
                      MainAxisAlignment.spaceBetween,
                      children: [
                        const Text("Total screen time",
                            style: TextStyle(
                                color: Colors.black,
                                fontSize: 13,
                                fontWeight: FontWeight.w600)),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: const Color(0xFF4CAF50)
                                .withOpacity(0.12),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(total,
                              style: const TextStyle(
                                  color: Color(0xFF2E7D32),
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700)),
                        ),
                      ]),
                ],
                if (othersRows.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  GestureDetector(
                    onTap: () => setState(
                            () => _othersExpanded = !_othersExpanded),
                    behavior: HitTestBehavior.opaque,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 10),
                      decoration: BoxDecoration(
                        color: const Color(0xFFEDE9FB),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(children: [
                        Container(
                          width: 28, height: 28,
                          decoration: BoxDecoration(
                            color: const Color(0xFF48249A)
                                .withOpacity(0.12),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: const Icon(Icons.apps_rounded,
                              color: Color(0xFF48249A), size: 16),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            "Others (${othersRows.length} "
                                "app${othersRows.length > 1 ? 's' : ''}"
                                " · < 1 min each)",
                            style: const TextStyle(
                                color: Color(0xFF48249A),
                                fontSize: 12,
                                fontWeight: FontWeight.w600),
                          ),
                        ),
                        Icon(
                          _othersExpanded
                              ? Icons.keyboard_arrow_up_rounded
                              : Icons.keyboard_arrow_down_rounded,
                          color: const Color(0xFF48249A),
                          size: 20,
                        ),
                      ]),
                    ),
                  ),
                  if (_othersExpanded) ...[
                    const SizedBox(height: 6),
                    Container(
                      constraints:
                      const BoxConstraints(maxHeight: 260),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                            color: const Color(0xFFDDD8F0)),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: ListView.separated(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 8),
                          shrinkWrap: true,
                          itemCount: othersRows.length,
                          separatorBuilder: (_, __) => const Divider(
                              color: Color(0xFFF0EEF9), height: 1),
                          itemBuilder: (_, i) =>
                              _appRowTile(othersRows[i]),
                        ),
                      ),
                    ),
                  ],
                ],
              ],
          ]),
    );
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFFFFFF),
      appBar: AppBar(
        backgroundColor: const Color(0xFF48249A),
        elevation: 0,
        title: Text(
          _currentIndex == 0 ? "My Dashboard" : "Loved Ones",
          style: const TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w600),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout_rounded, color: Colors.white),
            tooltip: "Sign out",
            onPressed: _signOut,
          )
        ],
      ),
      body: SafeArea(
        child: _currentIndex == 0
            ? _buildMyReportTab()
            : LovedOnesTab(
          userEmail: widget.userEmail,
          userName: widget.userName,
        ),
      ),
      bottomNavigationBar: BottomNavigationBar(
        backgroundColor: const Color(0xFF48249A),
        selectedItemColor: const Color(0xFFFFFFFF),
        unselectedItemColor: Colors.white70,
        currentIndex: _currentIndex,
        onTap: (i) => setState(() => _currentIndex = i),
        items: const [
          BottomNavigationBarItem(
              icon: Icon(Icons.bar_chart_rounded),
              label: "My Report"),
          BottomNavigationBarItem(
              icon: Icon(Icons.favorite_outlined),
              label: "Loved Ones"),
        ],
      ),
    );
  }

  Widget _buildMyReportTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── Greeting card ─────────────────────────────────────────────
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: const Color(0xFFF7F6FC),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                    color: const Color(0xFF48249A).withOpacity(0.4)),
              ),
              child: Row(children: [
                Container(
                  width: 48, height: 48,
                  decoration: BoxDecoration(
                    color: const Color(0xFF4CAF50).withOpacity(0.15),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.shield_outlined,
                      color: Color(0xFF4CAF50), size: 26),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          "Hi, ${widget.userName} 👋",
                          style: const TextStyle(
                              color: Colors.deepPurple,
                              fontSize: 16,
                              fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _isAndroid
                              ? "Tracking Active"
                              : "Cloud View Active",
                          style: const TextStyle(
                              color: Color(0xFF48249A), fontSize: 13),
                        ),
                        const SizedBox(height: 2),
                        Text(widget.userEmail,
                            style: const TextStyle(
                                color: Colors.black, fontSize: 11),
                            overflow: TextOverflow.ellipsis),
                      ]),
                ),
              ]),
            ),

            const SizedBox(height: 20),
            _buildOverviewCards(),
            const SizedBox(height: 20),

            // ── iOS info banner ───────────────────────────────────────────
            if (!_isAndroid) _buildIosBanner(),

            // ── Day selector ──────────────────────────────────────────────
            SizedBox(
              height: 72,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: _days.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (_, i) {
                  final day      = _days[i];
                  final selected =
                      _dateKey(day) == _dateKey(_selectedDay);
                  final hasFirebase =
                  _firebaseDaysWithData.contains(_dateKey(day));
                  final hasLocal =
                  _localDaysWithData.contains(_dateKey(day));
                  final isToday = _isToday(day);

                  return GestureDetector(
                    onTap: () {
                      if (!selected) _subscribeDay(day);
                    },
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      width: 56,
                      decoration: BoxDecoration(
                        color: selected
                            ? const Color(0xFF48249A)
                            : const Color(0xFFF3F0FB),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: selected
                              ? const Color(0xFF48249A)
                              : const Color(0xFFDDD8F0),
                        ),
                      ),
                      child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              _shortDay(day),
                              style: TextStyle(
                                fontSize: 11,
                                color: selected
                                    ? Colors.white70
                                    : Colors.grey,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              day.day.toString(),
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                                color: selected
                                    ? Colors.white
                                    : const Color(0xFF48249A),
                              ),
                            ),
                            Container(
                              margin: const EdgeInsets.only(top: 3),
                              width: 5, height: 5,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: selected
                                    ? Colors.white
                                    : (isToday || hasFirebase)
                                    ? const Color(0xFF4CAF50)
                                    : hasLocal
                                    ? const Color(0xFF9C27B0)
                                    : !_localDaysChecked
                                    ? Colors.grey
                                    .withOpacity(0.4)
                                    : Colors.grey
                                    .withOpacity(0.25),
                              ),
                            ),
                          ]),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 6),
            Text(
              _isToday(_selectedDay)
                  ? _isAndroid
                  ? "Today · uploading every 30 seconds"
                  : "Today · showing cloud data"
                  : _dayLabel(_selectedDay),
              textAlign: TextAlign.center,
              style: const TextStyle(
                  fontSize: 11, color: Color(0xFF000000)),
            ),
            const SizedBox(height: 16),

            // ── Permission card (Android only) ────────────────────────────
            if (_isAndroid &&
                _localLoaded &&
                !_permissionGranted) ...[
              _buildPermissionCard(),
              const SizedBox(height: 16),
            ],

            // ── Local data banners (Android only) ─────────────────────────
            if (_isAndroid && _usingLocalData && _isToday(_selectedDay))
              _buildLocalDataBanner()
            else if (_isAndroid &&
                _usingLocalData &&
                !_isToday(_selectedDay))
              _buildLocalPastBanner(),

            // ── Loading / report ──────────────────────────────────────────
            if (!_reportLoaded && _permissionGranted)
              const Center(
                child: Padding(
                  padding: EdgeInsets.symmetric(vertical: 32),
                  child: Column(children: [
                    CircularProgressIndicator(
                        color: Color(0xFF4CAF50), strokeWidth: 2),
                    SizedBox(height: 12),
                    Text("Loading your report…",
                        style: TextStyle(
                            color: Colors.grey, fontSize: 13)),
                  ]),
                ),
              )
            else if (_reportLoaded)
              _reportCard(),

            const SizedBox(height: 14),
            _buildStatusChips(),
            const SizedBox(height: 20),
            _buildAiAnalysis(),
            const SizedBox(height: 20),
          ]),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// SENTIMENT RESULT
// ─────────────────────────────────────────────────────────────────────────────

class _SentimentResult {
  final String sentiment;
  final int score;
  final String summary;
  final List<String> tags;
  final String mood;

  const _SentimentResult({
    required this.sentiment,
    required this.score,
    required this.summary,
    required this.tags,
    required this.mood,
  });

  factory _SentimentResult.fromJson(Map<String, dynamic> j) =>
      _SentimentResult(
        sentiment: j['sentiment'] as String? ?? 'Neutral',
        score:     (j['score'] as num?)?.toInt() ?? 50,
        summary:   j['summary'] as String? ?? '',
        tags: (j['tags'] as List<dynamic>?)
            ?.map((e) => e.toString())
            .toList() ??
            [],
        mood: j['mood'] as String? ?? '😐',
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// FULL INSIGHT PAGE
// ─────────────────────────────────────────────────────────────────────────────

class _FullInsightPage extends StatefulWidget {
  final List<MapEntry<String, int>> overused;
  final List<AppRow> appRows;
  final Map<String, dynamic> iconsMap;
  final int totalMins;
  final int? focusMinutes;
  final int? pickups;
  final String? screenTimeStatus;
  final String? sleepImpactStatus;

  const _FullInsightPage({
    required this.overused,
    required this.appRows,
    required this.iconsMap,
    this.totalMins = 0,
    this.focusMinutes,
    this.pickups,
    this.screenTimeStatus,
    this.sleepImpactStatus,
  });

  @override
  State<_FullInsightPage> createState() => _FullInsightPageState();
}

class _FullInsightPageState extends State<_FullInsightPage> {
  String _aiAnalysis = '';
  bool   _aiLoading  = true;
  String _aiError    = '';

  _SentimentResult? _sentiment;
  bool   _sentimentLoading = true;
  String _sentimentError   = '';

  final FlutterTts _tts            = FlutterTts();
  bool   _ttsPlaying               = false;
  bool   _ttsPaused                = false;
  String _selectedLanguage         = 'en-US';
  final Map<String, String> _translationCache = {};
  bool _translating                = false;

  static const Map<String, String> _languages = {
    'English':  'en-US',
    'Hindi':    'hi-IN',
    'Gujarati': 'gu-IN',
  };

  static const Map<String, String> _languageNames = {
    'en-US': 'English',
    'hi-IN': 'Hindi',
    'gu-IN': 'Gujarati',
  };

  @override
  void initState() {
    super.initState();
    _fetchGeminiAnalysis();
    _fetchSentimentAnalysis();
    _initTts();
  }

  @override
  void dispose() {
    _tts.stop();
    super.dispose();
  }

  Future<void> _initTts() async {
    await _tts.setLanguage(_selectedLanguage);
    await _tts.setSpeechRate(0.5);
    await _tts.setVolume(1.0);
    await _tts.setPitch(1.0);

    _tts.setStartHandler(() {
      if (mounted) setState(() { _ttsPlaying = true; _ttsPaused = false; });
    });
    _tts.setCompletionHandler(() {
      if (mounted) setState(() { _ttsPlaying = false; _ttsPaused = false; });
    });
    _tts.setCancelHandler(() {
      if (mounted) setState(() { _ttsPlaying = false; _ttsPaused = false; });
    });
    _tts.setPauseHandler(() {
      if (mounted) setState(() { _ttsPaused = true; _ttsPlaying = false; });
    });
    _tts.setContinueHandler(() {
      if (mounted) setState(() { _ttsPaused = false; _ttsPlaying = true; });
    });
    _tts.setErrorHandler((_) {
      if (mounted) setState(() { _ttsPlaying = false; _ttsPaused = false; });
    });
  }

  Future<String> _getTextForLanguage(String langCode) async {
    if (langCode == 'en-US') return _aiAnalysis;
    if (_translationCache.containsKey(langCode)) {
      return _translationCache[langCode]!;
    }

    final langName = _languageNames[langCode] ?? 'Hindi';
    final prompt =
    '''Translate the following wellness coaching message into $langName.
Keep the tone warm, personal, and natural — as if a real wellness coach is speaking.
Keep all app names (like Instagram, YouTube, WhatsApp, etc.) in English as they are.
Keep time values translated naturally into $langName words.
Return ONLY the translated text, nothing else.

Text to translate:
$_aiAnalysis''';

    final translated =
    await AiService.generate(prompt, temperature: 0.3, maxTokens: 400);
    final result = translated.trim();
    _translationCache[langCode] = result;
    return result;
  }

  Future<void> _speak() async {
    if (_aiAnalysis.isEmpty) return;
    await _tts.stop();
    await Future.delayed(const Duration(milliseconds: 150));

    if (_selectedLanguage != 'en-US' &&
        !_translationCache.containsKey(_selectedLanguage)) {
      if (mounted) setState(() => _translating = true);
    }

    String textToSpeak;
    try {
      textToSpeak = await _getTextForLanguage(_selectedLanguage);
    } catch (_) {
      textToSpeak = _aiAnalysis;
    } finally {
      if (mounted) setState(() => _translating = false);
    }

    if (!mounted) return;

    final isAvailable =
    await _tts.isLanguageAvailable(_selectedLanguage);
    if (!isAvailable && mounted) {
      final langName = _languages.entries
          .firstWhere((e) => e.value == _selectedLanguage)
          .key;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
          '$langName language pack not installed on this device. '
              'Falling back to English.',
        ),
        duration: const Duration(seconds: 3),
      ));
    }

    await _tts.setLanguage(isAvailable ? _selectedLanguage : 'en-US');
    await Future.delayed(const Duration(milliseconds: 100));
    await _tts.speak(textToSpeak);
  }

  Future<void> _pause()  async => _tts.pause();
  Future<void> _resume() async => _speak();

  Future<void> _stop() async {
    await _tts.stop();
    if (mounted) setState(() { _ttsPlaying = false; _ttsPaused = false; });
  }

  Widget _buildTtsControls() {
    if (_aiLoading || _aiError.isNotEmpty || _aiAnalysis.isEmpty) {
      return const SizedBox.shrink();
    }

    return Container(
      margin: const EdgeInsets.only(top: 14),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.12),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Icon(Icons.language_rounded,
                  color: Colors.white70, size: 16),
              const SizedBox(width: 8),
              const Text("Language",
                  style: TextStyle(color: Colors.white70, fontSize: 12)),
              const SizedBox(width: 12),
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: _languages.entries.map((entry) {
                      final selected = _selectedLanguage == entry.value;
                      return GestureDetector(
                        onTap: () async {
                          await _stop();
                          await Future.delayed(
                              const Duration(milliseconds: 200));
                          if (mounted) {
                            setState(
                                    () => _selectedLanguage = entry.value);
                          }
                        },
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          margin: const EdgeInsets.only(right: 8),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 6),
                          decoration: BoxDecoration(
                            color: selected
                                ? Colors.white
                                : Colors.white.withOpacity(0.15),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(entry.key,
                              style: TextStyle(
                                color: selected
                                    ? const Color(0xFF48249A)
                                    : Colors.white,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              )),
                        ),
                      );
                    }).toList(),
                  ),
                ),
              ),
            ]),
            const SizedBox(height: 14),
            Row(children: [
              Expanded(
                child: GestureDetector(
                  onTap: _translating
                      ? null
                      : () async {
                    if (_ttsPlaying) {
                      await _pause();
                    } else if (_ttsPaused) {
                      await _resume();
                    } else {
                      await _speak();
                    }
                  },
                  child: Container(
                    padding:
                    const EdgeInsets.symmetric(vertical: 12),
                    decoration: BoxDecoration(
                      color: _translating
                          ? Colors.white.withOpacity(0.6)
                          : Colors.white,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: _translating
                        ? const Row(
                        mainAxisAlignment:
                        MainAxisAlignment.center,
                        children: [
                          SizedBox(
                            width: 16, height: 16,
                            child: CircularProgressIndicator(
                                color: Color(0xFF48249A),
                                strokeWidth: 2),
                          ),
                          SizedBox(width: 8),
                          Text("Translating…",
                              style: TextStyle(
                                  color: Color(0xFF48249A),
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700)),
                        ])
                        : Row(
                        mainAxisAlignment:
                        MainAxisAlignment.center,
                        children: [
                          Icon(
                            _ttsPlaying
                                ? Icons.pause_rounded
                                : _ttsPaused
                                ? Icons.play_arrow_rounded
                                : Icons.volume_up_rounded,
                            color: const Color(0xFF48249A),
                            size: 20,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            _ttsPlaying
                                ? "Pause"
                                : _ttsPaused
                                ? "Resume"
                                : "Read Aloud",
                            style: const TextStyle(
                                color: Color(0xFF48249A),
                                fontSize: 13,
                                fontWeight: FontWeight.w700),
                          ),
                        ]),
                  ),
                ),
              ),
              if (_ttsPlaying || _ttsPaused) ...[
                const SizedBox(width: 10),
                GestureDetector(
                  onTap: _stop,
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.2),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(Icons.stop_rounded,
                        color: Colors.white, size: 20),
                  ),
                ),
              ],
            ]),
            if (_ttsPlaying) ...[
              const SizedBox(height: 10),
              Row(children: [
                const SizedBox(
                  width: 12, height: 12,
                  child: CircularProgressIndicator(
                      color: Colors.white70, strokeWidth: 2),
                ),
                const SizedBox(width: 8),
                Text(
                  "Speaking in ${_languages.entries.firstWhere((e) => e.value == _selectedLanguage).key}…",
                  style: const TextStyle(
                      color: Colors.white70, fontSize: 11),
                ),
              ]),
            ],
            if (!_translating &&
                _selectedLanguage != 'en-US' &&
                _translationCache.containsKey(_selectedLanguage)) ...[
              const SizedBox(height: 8),
              Row(children: [
                const Icon(Icons.translate_rounded,
                    color: Colors.white54, size: 13),
                const SizedBox(width: 6),
                Text(
                  "AI-translated to "
                      "${_languageNames[_selectedLanguage] ?? ''}",
                  style: const TextStyle(
                      color: Colors.white54, fontSize: 11),
                ),
              ]),
            ],
          ]),
    );
  }

  String _nameForPkg(String pkg) {
    for (final row in widget.appRows) {
      if (row.packageName == pkg) return row.appName;
    }
    return pkg.split('.').last.replaceFirst(
        pkg.split('.').last[0],
        pkg.split('.').last[0].toUpperCase());
  }

  Uint8List? _iconForPkg(String pkg) {
    final b64 = widget.iconsMap[pkg] as String? ?? '';
    if (b64.isEmpty) return null;
    try {
      return base64Decode(b64);
    } catch (_) {
      return null;
    }
  }

  (String, Color, Color) _severityFor(int mins) => mins >= 60
      ? ("Way Over Used", const Color(0xFFD32F2F),
  const Color(0xFFFFCDD2))
      : ("High Usage", const Color(0xFFE65100),
  const Color(0xFFFFE0B2));

  String _fmtMins(int mins) {
    final h = mins ~/ 60;
    final m = mins % 60;
    if (h == 0) return "${m}m";
    return "${h}:${m.toString().padLeft(2, '0')}";
  }

  String _tipForMins(int mins) => mins >= 60
      ? "60+ min of continuous use detected. Take a long break — "
      "stand up, stretch, and rest your eyes."
      : "40–60 min of continuous use detected. Try a 5-minute break "
      "before continuing.";

  String _usageSummary() {
    final buf = StringBuffer();
    buf.writeln("Total screen time: ${_fmtMins(widget.totalMins)}");
    if (widget.focusMinutes != null) {
      buf.writeln("Focus time: ${_fmtMins(widget.focusMinutes!)}");
    }
    if (widget.pickups != null) {
      buf.writeln("Pickups: ${widget.pickups}");
    }
    if (widget.screenTimeStatus != null) {
      buf.writeln(
          "Screen time status: ${widget.screenTimeStatus}");
    }
    if (widget.sleepImpactStatus != null) {
      buf.writeln("Sleep impact: ${widget.sleepImpactStatus}");
    }
    if (widget.overused.isNotEmpty) {
      buf.writeln("Extended continuous use detected in:");
      for (final e in widget.overused) {
        buf.writeln(
            "  - ${_nameForPkg(e.key)}: ${_fmtMins(e.value)} without break");
      }
    }
    return buf.toString();
  }

  Future<bool> _checkNetwork() async {
    try {
      await http
          .get(Uri.parse('https://www.google.com'))
          .timeout(const Duration(seconds: 6));
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _fetchGeminiAnalysis() async {
    setState(() {
      _aiLoading  = true;
      _aiError    = '';
      _aiAnalysis = '';
      _translationCache.clear();
    });
    final hasNetwork = await _checkNetwork();
    if (!hasNetwork) {
      if (mounted) {
        setState(() {
          _aiError   =
          'No internet connection. Please check your WiFi or mobile data and try again.';
          _aiLoading = false;
        });
      }
      return;
    }
    try {
      final prompt =
      """You are a caring personal AI Wellness Coach. Based on the phone usage data below, write a short personal coaching message to the user. Cover these 4 things in order:

1. 💬 What their usage today says about them (be honest but kind)
2. ⚠️ One specific concern based on their actual apps and screen time
3. 😴 Whether their usage will affect their sleep or health tonight
4. 💪 One very specific actionable advice just for them based on their data

Rules:
- Talk directly to the user as "you"
- Mention their actual app names and times
- Keep total response under 100 words
- Sound like a real coach, not a robot
- No bullet points, write as natural flowing sentences

USAGE DATA:
${_usageSummary()}""";

      final text = await AiService.generate(
          prompt, temperature: 0.7, maxTokens: 350);
      if (mounted) {
        setState(() { _aiAnalysis = text.trim(); _aiLoading = false; });
      }
    } catch (e) {
      if (mounted) {
        setState(() { _aiError = 'AI error: $e'; _aiLoading = false; });
      }
    }
  }

  Future<void> _fetchSentimentAnalysis() async {
    setState(() {
      _sentimentLoading = true;
      _sentimentError   = '';
      _sentiment        = null;
    });
    final hasNetwork = await _checkNetwork();
    if (!hasNetwork) {
      if (mounted) {
        setState(() {
          _sentimentError   =
          'No internet connection. Please check your WiFi or mobile data and try again.';
          _sentimentLoading = false;
        });
      }
      return;
    }
    try {
      final prompt =
      """Analyse this phone usage and reply with ONLY a JSON object. No text before or after. No markdown. No backticks. Start your reply with { and end with }.

{"sentiment":"Positive or Neutral or Negative","score":0-100,"summary":"one sentence about their habits","mood":"one emoji","tags":["tag1","tag2"]}

Tags pick 2-3 from: Great Balance, Doom Scrolling Risk, Good Focus, Sleep Risk, Overuse Detected, Healthy Habits, Too Many Pickups, Productive Day, Rest Needed, Eye Strain Risk.

DATA: ${_usageSummary()}""";

      final raw = await AiService.generate(
          prompt, temperature: 0.2, maxTokens: 200);
      if (!mounted) return;

      final cleaned = raw
          .replaceAll('```json', '')
          .replaceAll('```', '')
          .replaceAll('\n', ' ')
          .trim();
      final start = cleaned.indexOf('{');
      final end   = cleaned.lastIndexOf('}');

      if (start == -1 || end == -1 || end <= start) {
        final fallback = {
          'sentiment': 'Neutral',
          'score':     50,
          'summary':
          'Could not analyse sentiment. Please retry.',
          'mood': '😐',
          'tags': ['Retry Needed'],
        };
        if (mounted) {
          setState(() {
            _sentiment        = _SentimentResult.fromJson(fallback);
            _sentimentLoading = false;
          });
        }
        return;
      }

      final parsed = jsonDecode(cleaned.substring(start, end + 1))
      as Map<String, dynamic>;
      if (mounted) {
        setState(() {
          _sentiment        = _SentimentResult.fromJson(parsed);
          _sentimentLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _sentimentError   = 'Sentiment error: $e';
          _sentimentLoading = false;
        });
      }
    }
  }

  Widget _legendBadge(
      String label, Color textColor, Color bgColor) =>
      Container(
        padding: const EdgeInsets.symmetric(
            horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: textColor.withOpacity(0.4)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 8, height: 8,
            decoration: BoxDecoration(
                color: textColor, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(label,
              style: TextStyle(
                  color: textColor,
                  fontSize: 11,
                  fontWeight: FontWeight.w600)),
        ]),
      );

  Color _sentimentPrimary() {
    if (_sentiment == null) return Colors.grey;
    switch (_sentiment!.sentiment) {
      case 'Positive': return const Color(0xFF2E7D32);
      case 'Negative': return const Color(0xFFB71C1C);
      default:         return const Color(0xFFE65100);
    }
  }

  Color _sentimentBg() {
    if (_sentiment == null) return const Color(0xFFF5F5F5);
    switch (_sentiment!.sentiment) {
      case 'Positive': return const Color(0xFFE8F5E9);
      case 'Negative': return const Color(0xFFFFEBEE);
      default:         return const Color(0xFFFFF3E0);
    }
  }

  Color _sentimentBar() {
    if (_sentiment == null) return Colors.grey;
    final score = _sentiment!.score;
    if (score >= 70) return const Color(0xFF4CAF50);
    if (score >= 40) return const Color(0xFFFFA726);
    return const Color(0xFFE53935);
  }

  Widget _buildSentimentCard() {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFEEEEEE)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.06),
            blurRadius: 16,
            offset: const Offset(0, 4),
          )
        ],
      ),
      child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: const BoxDecoration(
                color: Color(0xFF48249A),
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(20),
                  topRight: Radius.circular(20),
                ),
              ),
              child: Row(children: [
                Container(
                  width: 42, height: 42,
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(Icons.psychology_rounded,
                      color: Colors.white, size: 24),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text("Behaviour Sentiment",
                            style: TextStyle(
                                color: Colors.white,
                                fontSize: 15,
                                fontWeight: FontWeight.w700)),
                        Text("AI-powered analysis of your digital habits",
                            style: TextStyle(
                                color: Colors.white60, fontSize: 11)),
                      ]),
                ),
                if (!_sentimentLoading)
                  GestureDetector(
                    onTap: _fetchSentimentAnalysis,
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.15),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(Icons.refresh_rounded,
                          color: Colors.white, size: 16),
                    ),
                  ),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: _sentimentLoading
                  ? const Center(
                  child: Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Column(children: [
                      CircularProgressIndicator(
                          color: Color(0xFF48249A), strokeWidth: 2),
                      SizedBox(height: 12),
                      Text("Analysing your behaviour…",
                          style: TextStyle(
                              color: Colors.grey, fontSize: 13)),
                    ]),
                  ))
                  : _sentimentError.isNotEmpty
                  ? Row(
                  crossAxisAlignment:
                  CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.error_outline_rounded,
                        color: Colors.redAccent, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                        child: Text(_sentimentError,
                            style: const TextStyle(
                                color: Colors.redAccent,
                                fontSize: 12))),
                  ])
                  : _sentiment == null
                  ? const SizedBox.shrink()
                  : Column(
                  crossAxisAlignment:
                  CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Container(
                        width: 56, height: 56,
                        decoration: BoxDecoration(
                          color: _sentimentBg(),
                          shape: BoxShape.circle,
                        ),
                        child: Center(
                            child: Text(_sentiment!.mood,
                                style: const TextStyle(
                                    fontSize: 28))),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                            crossAxisAlignment:
                            CrossAxisAlignment.start,
                            children: [
                              Container(
                                padding:
                                const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 4),
                                decoration: BoxDecoration(
                                  color: _sentimentBg(),
                                  borderRadius:
                                  BorderRadius.circular(20),
                                  border: Border.all(
                                      color: _sentimentPrimary()
                                          .withOpacity(0.3)),
                                ),
                                child: Text(_sentiment!.sentiment,
                                    style: TextStyle(
                                        color:
                                        _sentimentPrimary(),
                                        fontSize: 13,
                                        fontWeight:
                                        FontWeight.w800)),
                              ),
                              const SizedBox(height: 6),
                              Text(_sentiment!.summary,
                                  style: const TextStyle(
                                      color: Colors.black87,
                                      fontSize: 12,
                                      height: 1.4)),
                            ]),
                      ),
                    ]),
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment:
                      MainAxisAlignment.spaceBetween,
                      children: [
                        const Text("Wellness Score",
                            style: TextStyle(
                                color: Colors.black,
                                fontSize: 13,
                                fontWeight:
                                FontWeight.w600)),
                        Text(
                            "${_sentiment!.score}/100",
                            style: TextStyle(
                                color: _sentimentBar(),
                                fontSize: 13,
                                fontWeight:
                                FontWeight.w800)),
                      ],
                    ),
                    const SizedBox(height: 8),
                    ClipRRect(
                      borderRadius:
                      BorderRadius.circular(6),
                      child: LinearProgressIndicator(
                        value: _sentiment!.score / 100,
                        minHeight: 10,
                        backgroundColor:
                        const Color(0xFFEEEEEE),
                        valueColor:
                        AlwaysStoppedAnimation<Color>(
                            _sentimentBar()),
                      ),
                    ),
                    const SizedBox(height: 16),
                    const Text("Behaviour Tags",
                        style: TextStyle(
                            color: Colors.black,
                            fontSize: 13,
                            fontWeight: FontWeight.w600)),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children:
                      _sentiment!.tags.map((tag) {
                        final isWarning = tag.contains(
                            'Risk') ||
                            tag.contains('Doom') ||
                            tag.contains('Overuse') ||
                            tag.contains('Distracted') ||
                            tag.contains('Strain') ||
                            tag.contains('Needed') ||
                            tag.contains('Too Many');
                        final tagColor = isWarning
                            ? const Color(0xFFE65100)
                            : const Color(0xFF2E7D32);
                        final tagBg = isWarning
                            ? const Color(0xFFFFF3E0)
                            : const Color(0xFFE8F5E9);
                        return Container(
                          padding:
                          const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 6),
                          decoration: BoxDecoration(
                            color: tagBg,
                            borderRadius:
                            BorderRadius.circular(20),
                            border: Border.all(
                                color: tagColor
                                    .withOpacity(0.3)),
                          ),
                          child: Row(
                              mainAxisSize:
                              MainAxisSize.min,
                              children: [
                                Icon(
                                  isWarning
                                      ? Icons
                                      .warning_amber_rounded
                                      : Icons
                                      .check_circle_outline_rounded,
                                  color: tagColor,
                                  size: 14,
                                ),
                                const SizedBox(width: 5),
                                Text(tag,
                                    style: TextStyle(
                                        color: tagColor,
                                        fontSize: 12,
                                        fontWeight:
                                        FontWeight.w600)),
                              ]),
                        );
                      }).toList(),
                    ),
                  ]),
            ),
          ]),
    );
  }

  Widget _buildGeminiCard() {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF48249A), Color(0xFF7B2FBE)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF48249A).withOpacity(0.35),
            blurRadius: 16,
            offset: const Offset(0, 6),
          )
        ],
      ),
      child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Container(
                width: 40, height: 40,
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.auto_awesome_rounded,
                    color: Colors.white, size: 22),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text("AI Wellness Coach",
                          style: TextStyle(
                              color: Colors.white,
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                              letterSpacing: -0.3)),
                      Text(
                          "Personalised insights based on your usage",
                          style: TextStyle(
                              color: Colors.white60, fontSize: 11)),
                    ]),
              ),
              if (!_aiLoading)
                GestureDetector(
                  onTap: () async {
                    await _stop();
                    _fetchGeminiAnalysis();
                  },
                  child: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.refresh_rounded,
                        color: Colors.white, size: 16),
                  ),
                ),
            ]),
            const SizedBox(height: 16),
            if (_aiLoading)
              Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Column(children: [
                    const SizedBox(
                      width: 28, height: 28,
                      child: CircularProgressIndicator(
                          color: Colors.white, strokeWidth: 2.5),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      "Generating your wellness coaching…",
                      style: TextStyle(
                          color: Colors.white.withOpacity(0.7),
                          fontSize: 13),
                    ),
                  ]),
                ),
              )
            else if (_aiError.isNotEmpty)
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.error_outline_rounded,
                          color: Colors.white70, size: 18),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(_aiError,
                            style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 12,
                                height: 1.5)),
                      ),
                    ]),
              )
            else
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Text(_aiAnalysis,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        height: 1.65,
                        letterSpacing: 0.1)),
              ),
            _buildTtsControls(),
          ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFFFFFF),
      appBar: AppBar(
        backgroundColor: const Color(0xFF48249A),
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded,
              color: Colors.white),
          onPressed: () {
            _stop();
            Navigator.of(context).pop();
          },
        ),
        title: const Text("Full Insight",
            style: TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w600)),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildSentimentCard(),
              _buildGeminiCard(),
              const SizedBox(height: 4),
              Row(children: [
                _legendBadge("High Usage", const Color(0xFFE65100),
                    const Color(0xFFFFE0B2)),
                const SizedBox(width: 8),
                _legendBadge("Way Over Used",
                    const Color(0xFFD32F2F),
                    const Color(0xFFFFCDD2)),
              ]),
              const SizedBox(height: 16),
              ...widget.overused.map((entry) {
                final pkg       = entry.key;
                final mins      = entry.value;
                final name      = _nameForPkg(pkg);
                final iconBytes = _iconForPkg(pkg);
                final severity  = _severityFor(mins);

                return Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: severity.$2),
                      boxShadow: [
                        BoxShadow(
                          color: severity.$2.withOpacity(0.10),
                          blurRadius: 12,
                          offset: const Offset(0, 4),
                        )
                      ],
                    ),
                    child: Column(
                        crossAxisAlignment:
                        CrossAxisAlignment.start,
                        children: [
                          Row(children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(10),
                              child: iconBytes != null
                                  ? Image.memory(iconBytes,
                                  width: 42,
                                  height: 42,
                                  fit: BoxFit.cover)
                                  : Container(
                                  width: 42, height: 42,
                                  color:
                                  const Color(0xFFF3F0FB),
                                  child: const Icon(
                                      Icons.android_rounded,
                                      color: Colors.grey,
                                      size: 24)),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                  crossAxisAlignment:
                                  CrossAxisAlignment.start,
                                  children: [
                                    Text(name,
                                        style: const TextStyle(
                                            color: Colors.black,
                                            fontSize: 14,
                                            fontWeight:
                                            FontWeight.w700),
                                        overflow:
                                        TextOverflow.ellipsis),
                                    const SizedBox(height: 2),
                                    Text(
                                        "Used ${_fmtMins(mins)} without a break",
                                        style: TextStyle(
                                            color: severity.$2,
                                            fontSize: 12,
                                            fontWeight:
                                            FontWeight.w500)),
                                  ]),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 4),
                              decoration: BoxDecoration(
                                color: severity.$2,
                                borderRadius:
                                BorderRadius.circular(20),
                              ),
                              child: Text(severity.$1,
                                  style: TextStyle(
                                      color: severity.$3,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700,
                                      letterSpacing: -0.2)),
                            ),
                          ]),
                          const SizedBox(height: 12),
                          Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: severity.$3,
                              borderRadius:
                              BorderRadius.circular(10),
                            ),
                            child: Row(
                                crossAxisAlignment:
                                CrossAxisAlignment.start,
                                children: [
                                  Icon(
                                      Icons.lightbulb_outline_rounded,
                                      color: severity.$2,
                                      size: 16),
                                  const SizedBox(width: 8),
                                  Expanded(
                                      child: Text(_tipForMins(mins),
                                          style: TextStyle(
                                              color: severity.$2,
                                              fontSize: 12,
                                              height: 1.5))),
                                ]),
                          ),
                        ]),
                  ),
                );
              }),
            ]),
      ),
    );
  }
}