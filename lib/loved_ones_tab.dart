import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:cloud_firestore/cloud_firestore.dart';

// ─────────────────────────────────────────────────────────────────────────────
// SHARED MODELS (imported by both files)
// ─────────────────────────────────────────────────────────────────────────────

enum StatusLevel { good, moderate, bad, neutral }

class AppRow {
  final String packageName;
  final String appName;
  final String duration;
  final Uint8List? iconBytes;
  final int durationMs;

  const AppRow({
    required this.packageName,
    required this.appName,
    required this.duration,
    required this.durationMs,
    this.iconBytes,
  });
}

class ChipData {
  final IconData icon;
  final Color iconColor;
  final Color iconBg;
  final String label;
  final String statusText;
  final StatusLevel level;

  const ChipData({
    required this.icon,
    required this.iconColor,
    required this.iconBg,
    required this.label,
    required this.statusText,
    required this.level,
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// LOVED ONES TAB
// ─────────────────────────────────────────────────────────────────────────────

class LovedOnesTab extends StatefulWidget {
  final String userEmail;
  final String userName;

  const LovedOnesTab({
    super.key,
    required this.userEmail,
    required this.userName,
  });

  @override
  State<LovedOnesTab> createState() => _LovedOnesTabState();
}

class _LovedOnesTabState extends State<LovedOnesTab> {
  final _shareEmailCtrl    = TextEditingController();
  final _receiveEmailCtrl  = TextEditingController();
  final _receivePasswordCtrl = TextEditingController();

  bool   _receiveObscure    = true;
  bool   _shareLoading      = false;
  String _shareError        = "";
  String _shareSuccess      = "";
  List<String> _sharingWith = [];

  bool   _receiveConnecting  = false;
  bool   _receiveLiveActive  = false;
  String _receiveError       = "";
  List<AppRow> _receivedRows = [];
  Map<String, dynamic> _receivedIconsMap = {};
  String _receivedLastUpdated   = "";
  String _receivedPersonName    = "";
  StreamSubscription? _receiveSub;
  int?   _receivedTotalMins;
  int?   _receivedPickups;
  int?   _receivedFocusMinutes;
  String? _receivedScreenTimeStatus;
  String? _receivedFocusTimeStatus;
  String? _receivedSleepImpactStatus;
  String _receivedRawReport = "";

  bool _shareExpanded   = false;
  bool _receiveExpanded = false;
  bool _receivedOthersExpanded = false;

  @override
  void initState() {
    super.initState();
    _loadSharingWith();
  }

  @override
  void dispose() {
    _receiveSub?.cancel();
    _shareEmailCtrl.dispose();
    _receiveEmailCtrl.dispose();
    _receivePasswordCtrl.dispose();
    super.dispose();
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  String _fmtMins(int mins) {
    final h = mins ~/ 60;
    final m = mins % 60;
    if (h == 0) return "${m}m";
    return "${h}:${m.toString().padLeft(2, '0')}";
  }

  List<AppRow> _parseReport(String report, Map<String, dynamic> iconsMap) {
    final rows      = <AppRow>[];
    if (report.isEmpty) return rows;
    final lines      = report.split('\n');
    final durationRe = RegExp(r'(\d+h\s+\d+m|\d+m|\d+s)');

    for (final line in lines) {
      if (line.startsWith('─') || line.startsWith('📅') || line.trim().isEmpty) continue;

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
      final h      = int.tryParse(hMatch?.group(1) ?? '0') ?? 0;
      final m      = int.tryParse(mMatch?.group(1) ?? '0') ?? 0;
      final s      = int.tryParse(sMatch?.group(1) ?? '0') ?? 0;
      final durMs  = (h * 3600 + m * 60 + s) * 1000;

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

  // ── Firebase ───────────────────────────────────────────────────────────────

  Future<void> _loadSharingWith() async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection("shared").doc(widget.userEmail).get();
      if (doc.exists) {
        final list = (doc.data()?["sharedWith"] as List<dynamic>? ?? [])
            .map((e) => e.toString()).toList();
        if (mounted) setState(() => _sharingWith = list);
      }
    } catch (_) {}
  }

  Future<void> _addShareTarget() async {
    final target = _shareEmailCtrl.text.trim().toLowerCase();
    setState(() { _shareError = ""; _shareSuccess = ""; });

    if (target.isEmpty || !RegExp(r'^[\w\.\-]+@[\w\.\-]+\.\w{2,}$').hasMatch(target)) {
      setState(() => _shareError = "Enter a valid email address");
      return;
    }
    if (target == widget.userEmail) {
      setState(() => _shareError = "You cannot share with yourself");
      return;
    }
    if (_sharingWith.contains(target)) {
      setState(() => _shareError = "Already sharing with this person");
      return;
    }
    setState(() => _shareLoading = true);
    try {
      final userDoc = await FirebaseFirestore.instance
          .collection("users").doc(target).get();
      if (!userDoc.exists || (userDoc.data()?["verified"] as bool? ?? false) == false) {
        setState(() { _shareError = "No verified account found for this email"; _shareLoading = false; });
        return;
      }
      final newList = [..._sharingWith, target];
      await FirebaseFirestore.instance
          .collection("shared").doc(widget.userEmail)
          .set({"sharedWith": newList}, SetOptions(merge: true));
      _shareEmailCtrl.clear();
      setState(() {
        _sharingWith  = newList;
        _shareSuccess = "Your report is now shared with $target";
        _shareLoading = false;
      });
    } catch (_) {
      setState(() { _shareError = "Failed to update. Check your connection."; _shareLoading = false; });
    }
  }

  Future<void> _removeShareTarget(String target) async {
    try {
      final newList = _sharingWith.where((e) => e != target).toList();
      await FirebaseFirestore.instance
          .collection("shared").doc(widget.userEmail)
          .set({"sharedWith": newList});
      if (mounted) setState(() => _sharingWith = newList);
    } catch (_) {}
  }

  Future<void> _startReceiveView() async {
    final theirEmail    = _receiveEmailCtrl.text.trim().toLowerCase();
    final theirPassword = _receivePasswordCtrl.text.trim();
    setState(() => _receiveError = "");

    if (theirEmail.isEmpty || theirPassword.isEmpty) {
      setState(() => _receiveError = "Please enter their email and password");
      return;
    }
    setState(() { _receiveConnecting = true; _receivedRows = []; });

    try {
      final userDoc = await FirebaseFirestore.instance
          .collection("users").doc(theirEmail).get();
      if (!userDoc.exists) {
        setState(() { _receiveError = "No account found for this email"; _receiveConnecting = false; });
        return;
      }
      final userData = userDoc.data()!;
      if ((userData["verified"] as bool? ?? false) == false) {
        setState(() { _receiveError = "This account's email is not verified"; _receiveConnecting = false; });
        return;
      }
      if ((userData["password"] as String? ?? "") != theirPassword) {
        setState(() { _receiveError = "Incorrect password"; _receiveConnecting = false; });
        return;
      }

      final sharedDoc  = await FirebaseFirestore.instance
          .collection("shared").doc(theirEmail).get();
      final sharedWith = (sharedDoc.data()?["sharedWith"] as List<dynamic>? ?? [])
          .map((e) => e.toString()).toList();

      if (!sharedWith.contains(widget.userEmail)) {
        setState(() { _receiveError = "This person has not shared their report with you yet"; _receiveConnecting = false; });
        return;
      }

      _receivedPersonName = userData["name"] as String? ?? theirEmail;
      _receiveSub?.cancel();
      _receiveSub = FirebaseFirestore.instance
          .collection("reports").doc(theirEmail)
          .snapshots()
          .listen((snap) {
        if (!snap.exists) {
          if (mounted) {
            setState(() {
              _receivedRows              = [];
              _receivedIconsMap          = {};
              _receivedRawReport         = "";
              _receivedTotalMins         = null;
              _receivedPickups           = null;
              _receivedFocusMinutes      = null;
              _receivedScreenTimeStatus  = null;
              _receivedFocusTimeStatus   = null;
              _receivedSleepImpactStatus = null;
              _receiveConnecting         = false;
              _receiveLiveActive         = true;
            });
          }
          return;
        }
        final data  = snap.data()!;
        final icons = Map<String, dynamic>.from(data["icons"] ?? {});
        final rawReport = data["report"] as String? ?? "";
        if (mounted) {
          setState(() {
            _receivedIconsMap          = icons;
            _receivedRows              = _parseReport(rawReport, icons);
            _receivedRawReport         = rawReport;
            _receivedLastUpdated       = data["updatedAt"] ?? "";
            _receivedTotalMins         = (data["totalMins"] as num?)?.toInt();
            _receivedPickups           = (data["pickups"] as num?)?.toInt();
            _receivedFocusMinutes      = (data["focusMinutes"] as num?)?.toInt();
            _receivedScreenTimeStatus  = data["screenTimeStatus"] as String?;
            _receivedFocusTimeStatus   = data["focusTimeStatus"] as String?;
            _receivedSleepImpactStatus = data["sleepImpactStatus"] as String?;
            _receiveConnecting         = false;
            _receiveLiveActive         = true;
          });
        }
      }, onError: (e) {
        if (mounted) setState(() { _receiveError = "Stream error: $e"; _receiveConnecting = false; _receiveLiveActive = false; });
      });
    } catch (_) {
      setState(() { _receiveError = "Verification failed. Check your connection."; _receiveConnecting = false; });
    }
  }

  void _stopReceiveView() {
    _receiveSub?.cancel();
    setState(() {
      _receiveLiveActive         = false;
      _receivedRows              = [];
      _receivedIconsMap          = {};
      _receivedRawReport         = "";
      _receivedLastUpdated       = "";
      _receivedTotalMins         = null;
      _receivedPickups           = null;
      _receivedFocusMinutes      = null;
      _receivedScreenTimeStatus  = null;
      _receivedFocusTimeStatus   = null;
      _receivedSleepImpactStatus = null;
      _receiveError              = "";
    });
  }

  // ── UI helpers ─────────────────────────────────────────────────────────────

  InputDecoration _dec(String label, IconData icon, {Widget? suffix}) =>
      InputDecoration(
        labelText:   label,
        labelStyle:  const TextStyle(color: Colors.black54),
        prefixIcon:  Icon(icon, color: Colors.deepPurple, size: 20),
        suffixIcon:  suffix,
        filled:      true,
        fillColor:   const Color(0xFFFFFFFF),
        contentPadding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFF000000))),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFF916DEF), width: 1.5)),
      );

  Widget _appRowTile(AppRow row) {
    Widget icon;
    if (row.iconBytes != null) {
      icon = ClipRRect(borderRadius: BorderRadius.circular(8),
          child: Image.memory(row.iconBytes!, width: 36, height: 36, fit: BoxFit.cover));
    } else {
      icon = Container(width: 36, height: 36,
          decoration: BoxDecoration(color: const Color(0xFF2A2A2A), borderRadius: BorderRadius.circular(8)),
          child: const Icon(Icons.android_rounded, color: Colors.grey, size: 20));
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(children: [
        icon, const SizedBox(width: 12),
        Expanded(child: Text(row.appName, style: const TextStyle(color: Color(0xFF1B1A1A), fontSize: 13, fontWeight: FontWeight.w500), overflow: TextOverflow.ellipsis)),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(color: const Color(0xFF48249A).withOpacity(0.08), borderRadius: BorderRadius.circular(20)),
          child: Text(row.duration, style: const TextStyle(color: Color(0xFF48249A), fontSize: 12, fontWeight: FontWeight.w600)),
        ),
      ]),
    );
  }

  bool _isEmptyReport(String report) =>
      report.trim().isEmpty || report.contains('No app usage recorded');

  Widget _reportCard({
    required String title,
    required String lastUpdated,
    required List<AppRow> rows,
    required String rawReport,
    bool othersExpanded = false,
    VoidCallback? onToggleOthers,
  }) {
    final mainRows   = rows.where((r) => r.durationMs >= 60000).toList();
    final othersRows = rows.where((r) => r.durationMs > 0 && r.durationMs < 60000).toList();
    String total = "";
    for (final line in rawReport.split('\n')) {
      if (line.trim().startsWith('TOTAL')) {
        final parts = line.trim().split(RegExp(r'\s{2,}'));
        if (parts.length >= 2) total = parts.last.trim();
        break;
      }
    }
    final isEmpty = rows.isEmpty && _isEmptyReport(rawReport);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFF9F7FF),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF916DEF)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.bar_chart_rounded, color: Color(0xFF4CAF50), size: 18),
          const SizedBox(width: 8),
          Expanded(child: Text(title, style: const TextStyle(color: Colors.black, fontSize: 15, fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis)),
          if (lastUpdated.isNotEmpty)
            Text(lastUpdated.length > 19 ? lastUpdated.substring(0, 19) : lastUpdated,
                style: const TextStyle(color: Colors.black, fontSize: 10)),
        ]),
        const Divider(color: Color(0xFFDDDDDD), height: 20),
        if (isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Center(child: Column(children: [
              Container(width: 56, height: 56, decoration: const BoxDecoration(color: Color(0xFFEDE9FB), shape: BoxShape.circle),
                  child: const Icon(Icons.smartphone_rounded, color: Color(0xFF48249A), size: 28)),
              const SizedBox(height: 12),
              const Text("No usage recorded this day", style: TextStyle(color: Colors.black, fontSize: 14, fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              const Padding(padding: EdgeInsets.symmetric(horizontal: 16),
                  child: Text("The device was either not used or the tracker was not running on this day.",
                      textAlign: TextAlign.center, style: TextStyle(color: Colors.grey, fontSize: 12, height: 1.5))),
            ])),
          )
        else if (mainRows.isEmpty && othersRows.isEmpty && rawReport.isNotEmpty)
          Padding(padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(rawReport, style: const TextStyle(color: Color(0xFF1B1A1A), fontSize: 13, height: 1.6, fontFamily: "monospace")))
        else ...[
            if (mainRows.isEmpty)
              const Padding(padding: EdgeInsets.symmetric(vertical: 6),
                  child: Text("No apps used for 1+ minute yet today.", style: TextStyle(color: Colors.grey, fontSize: 12)))
            else
              ...mainRows.map(_appRowTile),
            if (total.isNotEmpty) ...[
              const Divider(color: Color(0xFFDDDDDD), height: 20),
              Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                const Text("Total screen time", style: TextStyle(color: Colors.black, fontSize: 13, fontWeight: FontWeight.w600)),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(color: const Color(0xFF4CAF50).withOpacity(0.12), borderRadius: BorderRadius.circular(20)),
                  child: Text(total, style: const TextStyle(color: Color(0xFF2E7D32), fontSize: 13, fontWeight: FontWeight.w700)),
                ),
              ]),
            ],
            if (othersRows.isNotEmpty) ...[
              const SizedBox(height: 10),
              GestureDetector(
                onTap: onToggleOthers,
                behavior: HitTestBehavior.opaque,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(color: const Color(0xFFEDE9FB), borderRadius: BorderRadius.circular(12)),
                  child: Row(children: [
                    Container(width: 28, height: 28,
                        decoration: BoxDecoration(color: const Color(0xFF48249A).withOpacity(0.12), borderRadius: BorderRadius.circular(8)),
                        child: const Icon(Icons.apps_rounded, color: Color(0xFF48249A), size: 16)),
                    const SizedBox(width: 10),
                    Expanded(child: Text("Others (${othersRows.length} app${othersRows.length > 1 ? 's' : ''} · < 1 min each)",
                        style: const TextStyle(color: Color(0xFF48249A), fontSize: 12, fontWeight: FontWeight.w600))),
                    Icon(othersExpanded ? Icons.keyboard_arrow_up_rounded : Icons.keyboard_arrow_down_rounded,
                        color: const Color(0xFF48249A), size: 20),
                  ]),
                ),
              ),
              if (othersExpanded) ...[
                const SizedBox(height: 6),
                Container(
                  constraints: const BoxConstraints(maxHeight: 260),
                  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: const Color(0xFFDDD8F0))),
                  child: ClipRRect(borderRadius: BorderRadius.circular(12),
                      child: ListView.separated(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        shrinkWrap: true,
                        itemCount: othersRows.length,
                        separatorBuilder: (_, __) => const Divider(color: Color(0xFFF0EEF9), height: 1),
                        itemBuilder: (_, i) => _appRowTile(othersRows[i]),
                      )),
                ),
              ],
            ],
          ],
      ]),
    );
  }

  StatusLevel _levelFor(String? value, Map<String, StatusLevel> map) =>
      map[value] ?? StatusLevel.neutral;

  Color _chipIconColor(StatusLevel level) {
    switch (level) {
      case StatusLevel.good:     return const Color(0xFF4CAF50);
      case StatusLevel.moderate: return const Color(0xFFFFA726);
      case StatusLevel.bad:      return const Color(0xFFE53935);
      case StatusLevel.neutral:  return Colors.grey;
    }
  }

  Color _chipIconBg(StatusLevel level) {
    switch (level) {
      case StatusLevel.good:     return const Color(0xFFE8F5E9);
      case StatusLevel.moderate: return const Color(0xFFFFF3E0);
      case StatusLevel.bad:      return const Color(0xFFFFEBEE);
      case StatusLevel.neutral:  return const Color(0xFFF5F5F5);
    }
  }

  Widget _buildStatusChips({
    String? screenTimeStatus,
    String? focusTimeStatus,
    String? sleepImpactStatus,
  }) {
    final stLevel = _levelFor(screenTimeStatus, {"Within Limit": StatusLevel.good, "Over Limit": StatusLevel.moderate, "Way Over": StatusLevel.bad});
    final ftLevel = _levelFor(focusTimeStatus,  {"Excellent": StatusLevel.good, "Good": StatusLevel.good, "Low": StatusLevel.moderate, "None": StatusLevel.bad});
    final siLevel = _levelFor(sleepImpactStatus, {"Low": StatusLevel.good, "Moderate": StatusLevel.moderate, "High": StatusLevel.bad});

    final chips = [
      ChipData(icon: Icons.shield_outlined,        iconColor: _chipIconColor(stLevel), iconBg: _chipIconBg(stLevel), label: "Screen Time", statusText: screenTimeStatus ?? "—", level: stLevel),
      ChipData(icon: Icons.track_changes_rounded,  iconColor: _chipIconColor(ftLevel), iconBg: _chipIconBg(ftLevel), label: "Focus Time",  statusText: focusTimeStatus  ?? "—", level: ftLevel),
      ChipData(icon: Icons.bedtime_outlined,       iconColor: _chipIconColor(siLevel), iconBg: _chipIconBg(siLevel), label: "Sleep Impact", statusText: sleepImpactStatus ?? "—", level: siLevel),
    ];

    return Row(
      children: chips.asMap().entries.map((entry) => Expanded(
        child: Padding(
          padding: EdgeInsets.only(right: entry.key < chips.length - 1 ? 6.0 : 0),
          child: Container(
            padding: const EdgeInsets.all(13),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0xFFEEEEEE)),
                boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 10, offset: const Offset(0, 3))]),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Container(width: 36, height: 36,
                  decoration: BoxDecoration(color: entry.value.iconBg, borderRadius: BorderRadius.circular(10)),
                  child: Icon(entry.value.icon, color: entry.value.iconColor, size: 20)),
              const SizedBox(height: 10),
              Text(entry.value.label, style: const TextStyle(color: Colors.grey, fontSize: 11, fontWeight: FontWeight.w500), maxLines: 1, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 4),
              Text(entry.value.statusText, style: TextStyle(color: _chipIconColor(entry.value.level), fontSize: 14, fontWeight: FontWeight.w800, letterSpacing: -0.3), maxLines: 1, overflow: TextOverflow.ellipsis),
            ]),
          ),
        ),
      )).toList(),
    );
  }

  Widget _buildReceivedStatsRow() {
    final items = [
      (icon: Icons.smartphone_rounded,    color: const Color(0xFF6C5CE7), bg: const Color(0xFFEDE9FB), label: "Screen Time", value: _receivedTotalMins    == null ? "—" : _fmtMins(_receivedTotalMins!)),
      (icon: Icons.track_changes_rounded, color: const Color(0xFF00B894), bg: const Color(0xFFDFFAF4), label: "Focus Time",  value: _receivedFocusMinutes == null ? "—" : _fmtMins(_receivedFocusMinutes!)),
      (icon: Icons.phone_iphone_rounded,  color: const Color(0xFFE17055), bg: const Color(0xFFFEEDE9), label: "Pickups",     value: _receivedPickups      == null ? "—" : "${_receivedPickups!} Times"),
    ];

    return LayoutBuilder(builder: (context, constraints) {
      final cardWidth = (constraints.maxWidth - 16) / 3;
      return Row(
        children: items.asMap().entries.map((entry) {
          final i = entry.key; final item = entry.value;
          return Padding(
            padding: EdgeInsets.only(right: i < items.length - 1 ? 8.0 : 0),
            child: SizedBox(width: cardWidth,
              child: Container(
                padding: const EdgeInsets.all(13),
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: const Color(0xFFEEEEEE)),
                    boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 10, offset: const Offset(0, 3))]),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                  Container(width: 36, height: 36, decoration: BoxDecoration(color: item.bg, borderRadius: BorderRadius.circular(10)),
                      child: Icon(item.icon, color: item.color, size: 20)),
                  const SizedBox(height: 10),
                  Text(item.label, style: const TextStyle(color: Colors.grey, fontSize: 11, fontWeight: FontWeight.w500), maxLines: 1, overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 4),
                  Text(item.value, style: const TextStyle(color: Color(0xFF1A1A2E), fontSize: 14, fontWeight: FontWeight.w800, letterSpacing: -0.3), maxLines: 1, overflow: TextOverflow.ellipsis),
                ]),
              ),
            ),
          );
        }).toList(),
      );
    });
  }

  Widget _sectionCard({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool expanded,
    required VoidCallback onToggle,
    required Widget child,
  }) {
    return Container(
      decoration: BoxDecoration(color: const Color(0xFFFFFFFF), borderRadius: BorderRadius.circular(16), border: Border.all(color: const Color(0xFF916DEF))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        GestureDetector(
          onTap: onToggle,
          behavior: HitTestBehavior.opaque,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(children: [
              Container(width: 40, height: 40,
                  decoration: BoxDecoration(color: const Color(0xFF4CAF50).withOpacity(0.12), borderRadius: BorderRadius.circular(10)),
                  child: Icon(icon, color: const Color(0xFF4CAF50), size: 20)),
              const SizedBox(width: 12),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: const TextStyle(color: Colors.black, fontSize: 14, fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(subtitle, style: const TextStyle(color: Colors.black54, fontSize: 11)),
              ])),
              Icon(expanded ? Icons.keyboard_arrow_up_rounded : Icons.keyboard_arrow_down_rounded, color: Colors.grey),
            ]),
          ),
        ),
        if (expanded)
          Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 16), child: child),
      ]),
    );
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [

        // ── SHARE ────────────────────────────────────────────────────────────
        _sectionCard(
          icon: Icons.share_rounded,
          title: "Share My Report",
          subtitle: "Let a loved one view your usage report",
          expanded: _shareExpanded,
          onToggle: () => setState(() { _shareExpanded = !_shareExpanded; _shareError = ""; _shareSuccess = ""; }),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const SizedBox(height: 16),
            if (_sharingWith.isNotEmpty) ...[
              const Text("Currently sharing with:", style: TextStyle(color: Colors.grey, fontSize: 12)),
              const SizedBox(height: 8),
              ..._sharingWith.map((email) => Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(color: const Color(0xFFF3EFFF), borderRadius: BorderRadius.circular(10), border: Border.all(color: const Color(0xFF000000).withOpacity(0.3))),
                child: Row(children: [
                  const Icon(Icons.check_circle_outline_rounded, color: Color(0xFF4CAF50), size: 16),
                  const SizedBox(width: 10),
                  Expanded(child: Text(email, style: const TextStyle(color: Colors.black, fontSize: 13), overflow: TextOverflow.ellipsis)),
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => _removeShareTarget(email),
                    child: const Padding(padding: EdgeInsets.all(6), child: Icon(Icons.close_rounded, color: Colors.grey, size: 18)),
                  ),
                ]),
              )),
              const SizedBox(height: 14),
            ],
            const Text("Add a loved one's email to share your report:", style: TextStyle(color: Colors.grey, fontSize: 12)),
            const SizedBox(height: 8),
            TextField(controller: _shareEmailCtrl, keyboardType: TextInputType.emailAddress, style: const TextStyle(color: Colors.black), decoration: _dec("Their Email Address", Icons.email_outlined)),
            const SizedBox(height: 12),
            if (_shareError.isNotEmpty)   Padding(padding: const EdgeInsets.only(bottom: 10), child: Text(_shareError,   style: const TextStyle(color: Colors.redAccent,       fontSize: 12))),
            if (_shareSuccess.isNotEmpty) Padding(padding: const EdgeInsets.only(bottom: 10), child: Text(_shareSuccess, style: const TextStyle(color: Color(0xFF4CAF50),       fontSize: 12))),
            SizedBox(
              height: 46,
              child: ElevatedButton.icon(
                onPressed: _shareLoading ? null : _addShareTarget,
                icon: _shareLoading
                    ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                    : const Icon(Icons.add_rounded, size: 18),
                label: const Text("Share My Report", style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF4CAF50), foregroundColor: Colors.white, disabledBackgroundColor: const Color(0xFF4CAF50).withOpacity(0.4), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)), elevation: 0),
              ),
            ),
          ]),
        ),

        const SizedBox(height: 16),

        // ── RECEIVE ──────────────────────────────────────────────────────────
        _sectionCard(
          icon: Icons.visibility_rounded,
          title: "Receive Report",
          subtitle: "View a loved one's usage report",
          expanded: _receiveExpanded,
          onToggle: () {
            if (_receiveExpanded && _receiveLiveActive) _stopReceiveView();
            setState(() { _receiveExpanded = !_receiveExpanded; _receiveError = ""; });
          },
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const SizedBox(height: 16),
            const Text("Enter their email and password to view their report.\nThey must have shared their report with you first.",
                style: TextStyle(color: Colors.grey, fontSize: 12, height: 1.5)),
            const SizedBox(height: 12),
            TextField(controller: _receiveEmailCtrl, keyboardType: TextInputType.emailAddress, style: const TextStyle(color: Colors.black), enabled: !_receiveLiveActive, decoration: _dec("Their Email Address", Icons.email_outlined)),
            const SizedBox(height: 12),
            TextField(
              controller: _receivePasswordCtrl,
              obscureText: _receiveObscure,
              style: const TextStyle(color: Colors.black),
              enabled: !_receiveLiveActive,
              onSubmitted: (_) { if (!_receiveLiveActive) _startReceiveView(); },
              decoration: _dec("Their Password", Icons.lock_outline_rounded,
                  suffix: IconButton(
                    icon: Icon(_receiveObscure ? Icons.visibility_off_outlined : Icons.visibility_outlined, color: Colors.grey, size: 20),
                    onPressed: () => setState(() => _receiveObscure = !_receiveObscure),
                  )),
            ),
            const SizedBox(height: 14),
            if (_receiveError.isNotEmpty)
              Padding(padding: const EdgeInsets.only(bottom: 10), child: Text(_receiveError, style: const TextStyle(color: Colors.redAccent, fontSize: 12))),
            Row(children: [
              Expanded(
                child: SizedBox(height: 46,
                  child: ElevatedButton.icon(
                    onPressed: (_receiveConnecting || _receiveLiveActive) ? null : _startReceiveView,
                    icon: _receiveConnecting
                        ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                        : const Icon(Icons.live_tv_rounded, size: 18),
                    label: Text(_receiveConnecting ? "Connecting…" : _receiveLiveActive ? "Live ●" : "Start Live View", style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                    style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF4CAF50), foregroundColor: Colors.white, disabledBackgroundColor: const Color(0xFF4CAF50).withOpacity(0.4), disabledForegroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)), elevation: 0),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(height: 46,
                child: ElevatedButton.icon(
                  onPressed: _receiveLiveActive ? _stopReceiveView : null,
                  icon: const Icon(Icons.stop_rounded, size: 18),
                  label: const Text("Stop", style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white, disabledBackgroundColor: Colors.red.withOpacity(0.4), disabledForegroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)), elevation: 0),
                ),
              ),
            ]),
            const SizedBox(height: 16),
            if (_receiveLiveActive) ...[
              if (_receivedRows.isEmpty && _receivedRawReport.isEmpty)
                const Center(child: Padding(padding: EdgeInsets.symmetric(vertical: 16),
                    child: Column(children: [
                      CircularProgressIndicator(color: Color(0xFF4CAF50), strokeWidth: 2),
                      SizedBox(height: 12),
                      Text("Waiting for next report upload…", style: TextStyle(color: Colors.grey, fontSize: 13)),
                    ])))
              else ...[
                Text("${_receivedPersonName.isNotEmpty ? _receivedPersonName : 'Their'}'s Overview",
                    style: const TextStyle(color: Colors.black, fontSize: 14, fontWeight: FontWeight.w600)),
                const SizedBox(height: 10),
                _buildReceivedStatsRow(),
                const SizedBox(height: 16),
                _reportCard(
                  title: _receivedPersonName.isNotEmpty ? "$_receivedPersonName — Today's Usage" : "Today's Usage",
                  lastUpdated: _receivedLastUpdated,
                  rows: _receivedRows,
                  rawReport: _receivedRawReport,
                  othersExpanded: _receivedOthersExpanded,
                  onToggleOthers: () => setState(() => _receivedOthersExpanded = !_receivedOthersExpanded),
                ),
                const SizedBox(height: 14),
                _buildStatusChips(screenTimeStatus: _receivedScreenTimeStatus, focusTimeStatus: _receivedFocusTimeStatus, sleepImpactStatus: _receivedSleepImpactStatus),
                const SizedBox(height: 8),
              ],
            ],
          ]),
        ),

        const SizedBox(height: 20),
      ]),
    );
  }
}
