import 'package:flutter/material.dart';

import '../core/app_log.dart';
import '../engine/intercom_engine.dart';
import '../platform/native_bridge.dart';

/// Bottom sheet that lists the available audio routes (Bluetooth intercom,
/// wired headset, speaker, earpiece) and lets the user pick one.
Future<void> showAudioRouteSheet(BuildContext context, IntercomEngine engine) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) => _RouteSheet(engine: engine),
  );
}

class _RouteSheet extends StatefulWidget {
  const _RouteSheet({required this.engine});

  final IntercomEngine engine;

  @override
  State<_RouteSheet> createState() => _RouteSheetState();
}

class _RouteSheetState extends State<_RouteSheet> {
  List<AudioRoute> _routes = const <AudioRoute>[];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final routes = await widget.engine.bridge.getAudioRoutes();
    if (!mounted) {
      return;
    }
    setState(() {
      _routes = routes;
      _loading = false;
      if (routes.isEmpty) {
        _error = 'No audio routes reported by the system.';
      }
    });
  }

  Future<void> _select(AudioRoute route) async {
    AppLog.instance.i('ui', 'Selecting audio route "${route.name}"');
    final ok = await widget.engine.bridge.setAudioRoute(route.id);
    if (!mounted) {
      return;
    }
    if (ok) {
      Navigator.of(context).pop();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not switch to that route.')),
      );
      await _refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.75,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Row(
                children: [
                  const Icon(Icons.headphones),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Audio route',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.refresh),
                    onPressed: _refresh,
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Text(
                'Pair your Bluetooth intercom in the system Bluetooth '
                'settings first — it then shows up here.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            const Divider(height: 20),
            if (_loading)
              const Padding(
                padding: EdgeInsets.all(32),
                child: CircularProgressIndicator(),
              )
            else if (_routes.isEmpty)
              Padding(
                padding: const EdgeInsets.all(24),
                child: Text(_error ?? 'No routes available.'),
              )
            else
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final route in _routes)
                      ListTile(
                        leading: Icon(_iconFor(route)),
                        title: Text(route.name),
                        subtitle: Text(route.describeType()),
                        trailing: route.selected
                            ? Icon(Icons.check_circle,
                                color: scheme.primary)
                            : null,
                        onTap: () => _select(route),
                      ),
                  ],
                ),
              ),
            const Divider(height: 8),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Quick switches',
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: [
                      ActionChip(
                        avatar: const Icon(Icons.headphones, size: 18),
                        label: const Text('Prefer headset/intercom'),
                        onPressed: () {
                          widget.engine.setSpeakerOn(false);
                          Navigator.of(context).pop();
                        },
                      ),
                      ActionChip(
                        avatar: const Icon(Icons.volume_up, size: 18),
                        label: const Text('Loudspeaker'),
                        onPressed: () {
                          widget.engine.setSpeakerOn(true);
                          Navigator.of(context).pop();
                        },
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  IconData _iconFor(AudioRoute route) {
    switch (route.type) {
      case 'bluetooth':
        return Icons.bluetooth_audio;
      case 'wired':
        return Icons.headset;
      case 'speaker':
        return Icons.volume_up;
      case 'earpiece':
        return Icons.phone_in_talk;
      default:
        return Icons.mic;
    }
  }
}
