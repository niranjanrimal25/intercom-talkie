import 'package:flutter/material.dart';

import '../engine/intercom_engine.dart';

/// Small rounded status chip.
class StatusChip extends StatelessWidget {
  const StatusChip({
    super.key,
    required this.label,
    required this.color,
    this.icon,
  });

  final String label;
  final Color color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 16, color: color),
            const SizedBox(width: 6),
          ],
          Text(
            label,
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.w700,
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }
}

/// Formats a duration as mm:ss or h:mm:ss.
String formatDuration(Duration duration) {
  final hours = duration.inHours;
  final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
  final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
  if (hours > 0) {
    return '$hours:$minutes:$seconds';
  }
  return '$minutes:$seconds';
}

/// Big circular action button used on the call panel.
class RoundActionButton extends StatelessWidget {
  const RoundActionButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.active = false,
    this.destructive = false,
    this.onTapDown,
    this.onTapUp,
    this.onTapCancel,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool active;
  final bool destructive;

  /// Optional handlers that turn the button into a hold-to-talk control.
  final VoidCallback? onTapDown;
  final VoidCallback? onTapUp;
  final VoidCallback? onTapCancel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final Color fill;
    final Color foreground;
    if (destructive) {
      fill = scheme.error;
      foreground = scheme.onError;
    } else if (active) {
      fill = scheme.primary;
      foreground = scheme.onPrimary;
    } else {
      fill = scheme.surfaceContainerHighest;
      foreground = scheme.onSurface;
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTapDown: onTapDown == null ? null : (_) => onTapDown!(),
          onTapUp: onTapUp == null ? null : (_) => onTapUp!(),
          onTapCancel: onTapCancel,
          child: IconButton.filled(
            onPressed: onPressed,
            icon: Icon(icon, color: foreground),
            style: IconButton.styleFrom(
              backgroundColor: fill,
              minimumSize: const Size(72, 72),
              maximumSize: const Size(72, 72),
              iconSize: 30,
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: scheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

/// A row of small read-only metrics (RTT, jitter, loss...).
class StatsRow extends StatelessWidget {
  const StatsRow({super.key, required this.engine});

  final IntercomEngine engine;

  @override
  Widget build(BuildContext context) {
    final stats = engine.stats;
    final scheme = Theme.of(context).colorScheme;
    String rtt = '—';
    if (stats.rttMs != null) {
      rtt = '${stats.rttMs!.toStringAsFixed(0)} ms';
    }
    String loss = '—';
    if (stats.sendLossPct != null) {
      loss = '${stats.sendLossPct!.toStringAsFixed(1)}%';
    }
    String jitter = '—';
    if (stats.jitterMs != null) {
      jitter = '${stats.jitterMs!.toStringAsFixed(0)} ms';
    }
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        _Metric(label: 'Latency', value: rtt, icon: Icons.speed),
        _Metric(label: 'Jitter', value: jitter, icon: Icons.waves),
        _Metric(label: 'Loss', value: loss, icon: Icons.percent),
      ],
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value, required this.icon});

  final String label;
  final String value;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: scheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            value,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

/// Live audio level indicator bars.
class LevelIndicator extends StatelessWidget {
  const LevelIndicator({
    super.key,
    required this.level,
    required this.label,
    required this.active,
  });

  final double? level;
  final String label;
  final bool active;

  Color get _color {
    if (!active) {
      return Colors.grey;
    }
    final value = (level ?? 0).clamp(0.0, 1.0);
    if (value > 0.6) {
      return Colors.orangeAccent;
    }
    return Colors.greenAccent;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final value = (level ?? 0).clamp(0.0, 1.0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: TextStyle(
                fontSize: 11, color: scheme.onSurfaceVariant)),
        const SizedBox(height: 4),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: SizedBox(
            width: 120,
            height: 6,
            child: LinearProgressIndicator(
              value: active ? value : 0,
              backgroundColor: scheme.surfaceContainerHighest,
              valueColor: AlwaysStoppedAnimation<Color>(_color),
              minHeight: 6,
            ),
          ),
        ),
      ],
    );
  }
}
