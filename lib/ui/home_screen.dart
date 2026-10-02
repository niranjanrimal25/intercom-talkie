import 'dart:io';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../engine/intercom_engine.dart';
import '../permissions.dart';
import 'log_screen.dart';
import 'route_sheet.dart';
import 'settings_screen.dart';
import 'widgets.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.engine});

  final IntercomEngine engine;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  IntercomEngine get engine => widget.engine;

  final TextEditingController _manualHostController = TextEditingController();

  @override
  void dispose() {
    _manualHostController.dispose();
    super.dispose();
  }

  Future<void> _startHostFlow() async {
    final problem = await ensureSessionPermissions();
    if (!mounted) {
      return;
    }
    if (problem != null) {
      _showSnack(problem, action: 'Settings', onAction: openSystemSettings);
      return;
    }
    await engine.startHost();
  }

  Future<void> _startClientFlow({String? manualHost}) async {
    final problem = await ensureSessionPermissions();
    if (!mounted) {
      return;
    }
    if (problem != null) {
      _showSnack(problem, action: 'Settings', onAction: openSystemSettings);
      return;
    }
    await engine.startClient(manualHost: manualHost);
  }

  void openSystemSettings() {
    openAppSettings();
  }

  void _showSnack(String message, {String? action, VoidCallback? onAction}) {
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        action: action == null
            ? null
            : SnackBarAction(label: action, onPressed: onAction ?? () {}),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Image.asset('assets/logo.png', width: 28, height: 28),
            const SizedBox(width: 10),
            const Text('Talkie'),
          ],
        ),
        centerTitle: false,
        actions: [
          IconButton(
            tooltip: 'Audio routes',
            icon: const Icon(Icons.headphones),
            onPressed: () => showAudioRouteSheet(context, engine),
          ),
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () async {
              await Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => SettingsScreen(engine: engine),
                ),
              );
            },
          ),
          IconButton(
            tooltip: 'Logs',
            icon: const Icon(Icons.receipt_long_outlined),
            onPressed: () async {
              await Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const LogScreen()),
              );
            },
          ),
        ],
      ),
      body: SafeArea(
        child: ListenableBuilder(
          listenable: engine,
          builder: (context, _) {
            final live = engine.isLive ||
                engine.state == IntercomState.reconnecting ||
                engine.state == IntercomState.connecting;
            if (live) {
              return _CallPanel(engine: engine, onEnd: () => engine.stop());
            }
            return _SetupPanel(
              engine: engine,
              onStartHost: _startHostFlow,
              onStartClient: _startClientFlow,
              manualHostController: _manualHostController,
            );
          },
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------
// Setup (idle) panel
// ---------------------------------------------------------------------

class _SetupPanel extends StatelessWidget {
  const _SetupPanel({
    required this.engine,
    required this.onStartHost,
    required this.onStartClient,
    required this.manualHostController,
  });

  final IntercomEngine engine;
  final Future<void> Function() onStartHost;
  final Future<void> Function({String? manualHost}) onStartClient;
  final TextEditingController manualHostController;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final busy = engine.state != IntercomState.idle;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (engine.state == IntercomState.waitingForPeer)
          _WaitingBanner(engine: engine),
        if (engine.state == IntercomState.discovering ||
            engine.state == IntercomState.starting)
          _ProgressBanner(
            engine.state == IntercomState.discovering
                ? 'Looking for the host phone…'
                : 'Starting…',
            onCancel: engine.stop,
          ),
        if (engine.lastError != null)
          Card(
            color: scheme.errorContainer,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Icon(Icons.error_outline, color: scheme.onErrorContainer),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      engine.lastError!,
                      style: TextStyle(color: scheme.onErrorContainer),
                    ),
                  ),
                ],
              ),
            ),
          ),
        _RoleCard(
          icon: Icons.wifi_tethering,
          title: 'Phone 1 — Share Hotspot & Host',
          description:
              'Enable this phone\'s Wi-Fi hotspot, then host. The other phone '
              'joins and your two intercoms get linked.',
          buttonText: 'Host on this phone',
          onPressed: onStartHost,
          highlighted: true,
          busy: busy,
        ),
        const SizedBox(height: 12),
        _RoleCard(
          icon: Icons.wifi_find,
          title: 'Phone 2 — Join Hotspot',
          description:
              'Connect this phone to the other phone\'s hotspot, then join. '
              'The host is found automatically.',
          buttonText: 'Join the other phone',
          onPressed: () => onStartClient(),
          highlighted: false,
          busy: busy,
        ),
        const SizedBox(height: 12),
        _ManualHostCard(
          controller: manualHostController,
          onConnect: onStartClient,
        ),
        const SizedBox(height: 12),
        _GuideCard(),
      ],
    );
  }
}

class _WaitingBanner extends StatelessWidget {
  const _WaitingBanner({required this.engine});

  final IntercomEngine engine;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 12),
            Text(
              'Hosting — waiting for the other phone to join',
              style: Theme.of(context).textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 4),
            Text(
              'On the other phone: connect to this hotspot, open Talkie '
              'and tap "Join the other phone".',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            FilledButton.tonal(
              onPressed: engine.stop,
              child: const Text('Stop hosting'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProgressBanner extends StatelessWidget {
  const _ProgressBanner(this.message, {required this.onCancel});

  final String message;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            ),
            const SizedBox(width: 16),
            Expanded(child: Text(message)),
            TextButton(
              onPressed: onCancel,
              child: const Text('Cancel'),
            ),
          ],
        ),
      ),
    );
  }
}

class _RoleCard extends StatelessWidget {
  const _RoleCard({
    required this.icon,
    required this.title,
    required this.description,
    required this.buttonText,
    required this.onPressed,
    required this.highlighted,
    required this.busy,
  });

  final IconData icon;
  final String title;
  final String description;
  final String buttonText;
  final Future<void> Function() onPressed;
  final bool highlighted;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      elevation: highlighted ? 2 : 0,
      color: highlighted ? scheme.secondaryContainer : null,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: scheme.onSecondaryContainer),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: scheme.onSecondaryContainer,
                        ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              description,
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: busy ? null : () => onPressed(),
              icon: const Icon(Icons.play_arrow),
              label: Text(buttonText),
            ),
          ],
        ),
      ),
    );
  }
}

class _ManualHostCard extends StatelessWidget {
  const _ManualHostCard({
    required this.controller,
    required this.onConnect,
  });

  final TextEditingController controller;
  final Future<void> Function({String? manualHost}) onConnect;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.dns_outlined),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Advanced: connect by address',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Only needed if automatic discovery fails. Enter the host '
              'phone\'s IP (usually 192.168.43.1 on Android hotspots, '
              '172.20.10.1 on iPhone).',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                labelText: 'Host IP address',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.lan_outlined),
                hintText: '192.168.43.1',
                isDense: true,
              ),
            ),
            const SizedBox(height: 8),
            FilledButton.tonalIcon(
              onPressed: () {
                final value = controller.text.trim();
                if (value.isEmpty) {
                  return;
                }
                onConnect(manualHost: value);
              },
              icon: const Icon(Icons.arrow_forward),
              label: const Text('Connect'),
            ),
          ],
        ),
      ),
    );
  }
}

class _GuideCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final isAndroid = Platform.isAndroid;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('How it works — 3 steps',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            const _GuideStep(
              number: '1',
              text: 'Pair each Bluetooth intercom to its phone in the '
                  'system Bluetooth settings (like a headset).',
            ),
            const _GuideStep(
              number: '2',
              text: 'On phone 1 enable the Wi-Fi hotspot, open this app and '
                  'tap "Host on this phone".',
            ),
            const _GuideStep(
              number: '3',
              text: 'On phone 2 join that Wi-Fi, open this app and tap '
                  '"Join the other phone". Talk!',
            ),
            const Divider(height: 24),
            Text(
              'Works fully offline — no cell service, no internet. Audio '
              'flows intercom → phone → Wi-Fi → phone → intercom.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (isAndroid) ...[
              const SizedBox(height: 8),
              Text(
                'Tip: allow the app to run in the background (disable '
                'battery optimization) so the link survives with the screen '
                'off. See Settings → Battery optimization.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _GuideStep extends StatelessWidget {
  const _GuideStep({required this.number, required this.text});

  final String number;
  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: scheme.primaryContainer,
            ),
            child: Center(
              child: Text(
                number,
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: scheme.onPrimaryContainer,
                  fontSize: 12,
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------
// Active call panel
// ---------------------------------------------------------------------

class _CallPanel extends StatelessWidget {
  const _CallPanel({
    required this.engine,
    required this.onEnd,
  });

  final IntercomEngine engine;
  final VoidCallback onEnd;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final paused = engine.state == IntercomState.paused;
    final reconnecting = engine.state == IntercomState.reconnecting;
    final connecting = engine.state == IntercomState.connecting;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          color: paused
              ? scheme.tertiaryContainer
              : scheme.primaryContainer.withValues(alpha: 0.6),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [
                _StateBadge(engine: engine),
                const SizedBox(height: 8),
                Text(
                  engine.peerName.isEmpty ? '…' : engine.peerName,
                  style: Theme.of(context)
                      .textTheme
                      .headlineMedium
                      ?.copyWith(fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 4),
                Text(
                  formatDuration(engine.sessionDuration),
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    StatusChip(
                      label:
                          engine.role == IntercomRole.host ? 'Host' : 'Client',
                      color: scheme.primary,
                      icon: engine.role == IntercomRole.host
                          ? Icons.wifi_tethering
                          : Icons.wifi,
                    ),
                    if (engine.interrupted)
                      const StatusChip(
                        label: 'PAUSED — PHONE CALL',
                        color: Colors.orange,
                        icon: Icons.phone_in_talk,
                      ),
                    if (engine.peerMicMuted)
                      const StatusChip(
                        label: 'Peer muted',
                        color: Colors.grey,
                        icon: Icons.mic_off,
                      ),
                  ],
                ),
                if (paused) ...[
                  const SizedBox(height: 12),
                  Text(
                    'A phone call is active. The intercom mutes itself and '
                    'will resume automatically when the call ends.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                ],
                if (reconnecting || connecting) ...[
                  const SizedBox(height: 12),
                  const LinearProgressIndicator(minHeight: 3),
                  const SizedBox(height: 8),
                  Text(
                    reconnecting
                        ? 'Connection lost — retrying automatically '
                            '(attempt ${engine.reconnectAttempt})'
                        : 'Connecting to ${engine.connectingTarget}…',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        StatsRow(engine: engine),
        const SizedBox(height: 16),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            RoundActionButton(
              icon: engine.micMuted ? Icons.mic_off : Icons.mic,
              label: engine.micMuted ? 'Unmute' : 'Mute',
              active: !engine.micMuted,
              onPressed: () => engine.setMicMuted(!engine.micMuted),
            ),
            if (engine.settings.pushToTalk)
              RoundActionButton(
                icon: Icons.record_voice_over,
                label: engine.pttActive ? 'Talking' : 'Hold to talk',
                active: engine.pttActive,
                onPressed: null,
                onTapDown: () => engine.setPttActive(true),
                onTapUp: () => engine.setPttActive(false),
                onTapCancel: () => engine.setPttActive(false),
              ),
            RoundActionButton(
              icon: engine.speakerOn ? Icons.volume_up : Icons.headphones,
              label: engine.speakerOn ? 'Speaker' : 'Headset',
              active: engine.speakerOn,
              onPressed: () => engine.setSpeakerOn(!engine.speakerOn),
            ),
          ],
        ),
        const SizedBox(height: 24),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            RoundActionButton(
              icon: Icons.call_end,
              label: 'End',
              destructive: true,
              onPressed: onEnd,
            ),
          ],
        ),
        const SizedBox(height: 24),
        LevelIndicator(
          level: engine.stats.audioLevelOut,
          label: 'Your voice',
          active: engine.isLive && !engine.micMuted && !engine.interrupted,
        ),
        const SizedBox(height: 8),
        LevelIndicator(
          level: engine.stats.audioLevelIn,
          label: 'Incoming voice',
          active: engine.isLive,
        ),
      ],
    );
  }
}

class _StateBadge extends StatelessWidget {
  const _StateBadge({required this.engine});

  final IntercomEngine engine;

  @override
  Widget build(BuildContext context) {
    final (label, color, icon) = switch (engine.state) {
      IntercomState.connected => ('CONNECTED', Colors.green, Icons.graphic_eq),
      IntercomState.paused => ('ON HOLD', Colors.orange, Icons.phone_in_talk),
      IntercomState.connecting => ('CONNECTING', Colors.blue, Icons.sync),
      IntercomState.reconnecting =>
        ('RECONNECTING', Colors.amber, Icons.autorenew),
      _ => ('ACTIVE', Colors.blue, Icons.radio),
    };
    return StatusChip(label: label, color: color, icon: icon);
  }
}
