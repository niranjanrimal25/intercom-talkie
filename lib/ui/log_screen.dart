import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/app_log.dart';

class LogScreen extends StatefulWidget {
  const LogScreen({super.key});

  @override
  State<LogScreen> createState() => _LogScreenState();
}

class _LogScreenState extends State<LogScreen> {
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Logs'),
        actions: [
          IconButton(
            tooltip: 'Copy all',
            icon: const Icon(Icons.copy),
            onPressed: () async {
              await Clipboard.setData(
                  ClipboardData(text: AppLog.instance.export()));
              if (!mounted) {
                return;
              }
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Logs copied to clipboard')),
              );
            },
          ),
          IconButton(
            tooltip: 'Clear',
            icon: const Icon(Icons.delete_outline),
            onPressed: () {
              AppLog.instance.clear();
            },
          ),
        ],
      ),
      body: ValueListenableBuilder<int>(
        valueListenable: AppLog.instance.revision,
        builder: (context, _, __) {
          final entries = AppLog.instance.snapshot();
          if (entries.isEmpty) {
            return const Center(child: Text('No log entries yet.'));
          }
          return ListView.builder(
            reverse: true,
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: entries.length,
            itemBuilder: (context, index) {
              final entry = entries[entries.length - 1 - index];
              final color = switch (entry.level) {
                LogLevel.debug => scheme.onSurfaceVariant,
                LogLevel.info => scheme.onSurface,
                LogLevel.warn => Colors.orange.shade300,
                LogLevel.error => scheme.error,
              };
              return Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
                child: Text(
                  entry.format(),
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11,
                    color: color,
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
