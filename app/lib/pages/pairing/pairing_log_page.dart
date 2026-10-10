import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:localsend_app/config/crash_report.dart';
import 'package:localsend_app/provider/pairing/pairing_controller.dart';
import 'package:refena_flutter/refena_flutter.dart';

class PairingLogPage extends StatefulWidget {
  const PairingLogPage({super.key});

  @override
  State<PairingLogPage> createState() => _PairingLogPageState();
}

class _PairingLogPageState extends State<PairingLogPage> with Refena {
  List<PairingLogEntry> _entries = const [];
  Object? _error;
  String? _lastCrash;
  Object? _crashReadError;
  String? _lastNativeCrash;
  Object? _nativeCrashReadError;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_refresh());
    });
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final entries = await ref.notifier(pairingControllerProvider).readPairingLog();
      if (mounted) setState(() => _entries = entries);
    } catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      try {
        final lastCrash = await readLastCrashReport();
        if (mounted) {
          setState(() {
            _lastCrash = lastCrash;
            _crashReadError = null;
          });
        }
      } catch (error) {
        if (mounted) setState(() => _crashReadError = error);
      }
      try {
        final lastNativeCrash = await ref.notifier(pairingControllerProvider).readLastNativeCrashReport();
        if (mounted) {
          setState(() {
            _lastNativeCrash = lastNativeCrash;
            _nativeCrashReadError = null;
          });
        }
      } catch (error) {
        if (mounted) setState(() => _nativeCrashReadError = error);
      }
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _copy() async {
    final text = _entries
        .map(
          (entry) => '${entry.timestamp.toIso8601String()} [${entry.step}] ${entry.message}',
        )
        .join('\n');
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted)
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Pairing log copied')));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Pairing log'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _loading ? null : _refresh,
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: 'Copy',
            onPressed: _entries.isEmpty ? null : _copy,
            icon: const Icon(Icons.copy),
          ),
        ],
      ),
      body: Column(
        children: [
          if (_lastCrash != null || _crashReadError != null)
            Card(
              margin: const EdgeInsets.all(12),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Last crash',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 180),
                      child: SingleChildScrollView(
                        child: SelectableText(
                          _crashReadError == null ? _lastCrash! : 'Could not read crash report: $_crashReadError',
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          if (_lastNativeCrash != null || _nativeCrashReadError != null)
            Card(
              margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Last native crash',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 180),
                      child: SingleChildScrollView(
                        child: SelectableText(
                          _nativeCrashReadError == null ? _lastNativeCrash! : 'Could not read native crash report: $_nativeCrashReadError',
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text('Could not load pairing log: $_error'),
                    ),
                  )
                : _entries.isEmpty
                ? const Center(child: Text('No pairing log entries'))
                : ListView.builder(
                    itemCount: _entries.length,
                    itemBuilder: (context, index) {
                      final entry = _entries[index];
                      return ListTile(
                        dense: true,
                        title: Text(entry.step),
                        subtitle: Text(
                          '${entry.timestamp.toLocal().toIso8601String()}\n${entry.message}',
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
