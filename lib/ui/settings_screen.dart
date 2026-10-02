import 'dart:io';

import 'package:flutter/material.dart';

import '../engine/intercom_engine.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.engine});

  final IntercomEngine engine;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _nameController;
  late final TextEditingController _passcodeController;
  Map<String, String> _platformInfo = const <String, String>{};

  IntercomEngine get engine => widget.engine;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: engine.settings.deviceName);
    _passcodeController =
        TextEditingController(text: engine.settings.passcode);
    _loadPlatformInfo();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _passcodeController.dispose();
    super.dispose();
  }

  Future<void> _loadPlatformInfo() async {
    final info = await engine.bridge.platformInfo();
    if (mounted) {
      setState(() {
        _platformInfo = info;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = engine.settings;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListenableBuilder(
        listenable: engine,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _SectionHeader('Identity'),
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(
                labelText: 'Device name (shown to your peer)',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: (value) async {
                settings.deviceName = value;
                await settings.save();
              },
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _passcodeController,
              decoration: const InputDecoration(
                labelText: 'Pairing passcode (empty = open)',
                helperText:
                    'Both phones must use the same passcode. Keeps strangers '
                    'on the hotspot from connecting.',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: (value) async {
                settings.passcode = value;
                await settings.save();
              },
            ),
            const SizedBox(height: 24),
            _SectionHeader('Audio'),
            SwitchListTile(
              secondary: const Icon(Icons.record_voice_over),
              title: const Text('Push-to-talk mode'),
              subtitle: const Text(
                  'Mic stays closed until you hold the TALK button. Use this '
                  'if you hear echo with two open intercoms.'),
              value: settings.pushToTalk,
              onChanged: (value) async {
                setState(() => settings.pushToTalk = value);
                await settings.save();
                engine.setPttActive(false);
              },
            ),
            SwitchListTile(
              secondary: const Icon(Icons.graphic_eq),
              title: const Text('Discontinuous transmission (DTX)'),
              subtitle: const Text(
                  'Saves battery and bandwidth during silence.'),
              value: settings.enableDtx,
              onChanged: (value) async {
                setState(() => settings.enableDtx = value);
                await settings.save();
              },
            ),
            ListTile(
              leading: const Icon(Icons.speed),
              title: Text(
                  'Opus target bitrate: ${_formatBitrate(settings.opusBitrateBps)}'),
              subtitle: Slider(
                value: settings.opusBitrateBps.toDouble(),
                min: 16000,
                max: 64000,
                divisions: 12,
                label: '${(settings.opusBitrateBps / 1000).round()} kbps',
                onChanged: (value) async {
                  setState(
                      () => settings.opusBitrateBps = value.round());
                  await settings.save();
                },
              ),
            ),
            const SizedBox(height: 24),
            _SectionHeader('Reliability'),
            SwitchListTile(
              secondary: const Icon(Icons.autorenew),
              title: const Text('Auto-reconnect'),
              subtitle: const Text(
                  'Rebuild the link automatically when it drops.'),
              value: settings.autoReconnect,
              onChanged: (value) async {
                setState(() => settings.autoReconnect = value);
                await settings.save();
              },
            ),
            SwitchListTile(
              secondary: const Icon(Icons.brightness_high),
              title: const Text('Keep screen on while active'),
              value: settings.keepScreenOn,
              onChanged: (value) async {
                setState(() => settings.keepScreenOn = value);
                await settings.save();
                if (engine.isLive) {
                  await engine.bridge.setKeepScreenOn(value);
                }
              },
            ),
            if (Platform.isAndroid)
              ListTile(
                leading: const Icon(Icons.battery_saver),
                title: const Text('Disable battery optimization'),
                subtitle: const Text(
                    'Strongly recommended so Android keeps the intercom '
                    'alive with the screen off.'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () async {
                  final shown =
                      await engine.bridge.requestIgnoreBatteryOptimizations();
                  if (!shown && mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                          content: Text(
                              'Open Android Settings → Apps → Talkie '
                              '→ Battery to allow background use.')),
                    );
                  }
                },
              ),
            const SizedBox(height: 24),
            _SectionHeader('Diagnostics'),
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('Platform'),
              subtitle: Text(
                _platformInfo.isEmpty
                    ? '…'
                    : _platformInfo.entries
                        .map((e) => '${e.key}: ${e.value}')
                        .join('\n'),
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.wifi),
              title: const Text('Last connected host'),
              subtitle: Text(settings.lastHostAddress.isEmpty
                  ? 'none'
                  : settings.lastHostAddress),
            ),
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(
                'Tip: enable the Wi-Fi hotspot on the host phone BEFORE '
                'tapping Host. On iPhone: Settings → Personal Hotspot.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatBitrate(int bps) => '${(bps / 1000).round()} kbps';
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, top: 4),
      child: Text(
        title.toUpperCase(),
        style: TextStyle(
          fontWeight: FontWeight.w700,
          fontSize: 12,
          letterSpacing: 1.2,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }
}
