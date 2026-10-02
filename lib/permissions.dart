import 'dart:io';

import 'package:permission_handler/permission_handler.dart';

import 'core/app_log.dart';

/// Requests the permissions required for an intercom session.
///
/// * Microphone — always required.
/// * Bluetooth Connect (Android 12+) — required to route audio to a
///   Bluetooth intercom.
/// * Notifications (Android 13+) — required to show the foreground service
///   notification.
///
/// Returns a human readable problem string, or `null` when everything needed
/// was granted.
Future<String?> ensureSessionPermissions() async {
  final requests = <Permission>[
    Permission.microphone,
    if (Platform.isAndroid) ...<Permission>[
      Permission.bluetoothConnect,
      Permission.notification,
    ],
  ];

  for (final permission in requests) {
    final status = await permission.request();
    AppLog.instance
        .d('perms', '${permission.toString()} → ${status.name}');
    if (status != PermissionStatus.granted &&
        status != PermissionStatus.provisional) {
      return _describe(permission, status);
    }
  }
  return null;
}

String _describe(Permission permission, PermissionStatus status) {
  final label = switch (permission) {
    Permission.microphone => 'Microphone',
    Permission.bluetoothConnect => 'Nearby devices (Bluetooth)',
    Permission.notification => 'Notifications',
    _ => permission.toString(),
  };
  if (status == PermissionStatus.permanentlyDenied) {
    return '$label permission is permanently denied. '
        'Open system settings and enable it manually.';
  }
  return '$label permission is required to use the intercom.';
}
