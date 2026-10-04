import 'package:shared_preferences/shared_preferences.dart';

/// User-facing settings, persisted with `shared_preferences`.
class IntercomSettings {
  IntercomSettings();

  static const _prefix = 'intercom.';

  String deviceName = '';
  String passcode = '';
  bool pushToTalk = false;
  int opusBitrateBps = 30000;
  bool enableDtx = true;
  bool autoReconnect = true;
  bool keepScreenOn = false;

  /// Last host this device successfully connected to (as a client).
  String lastHostAddress = '';

  /// Role of the last active session ('host', 'client' or ''). Persists
  /// across process death so the app can silently rejoin on relaunch.
  /// Cleared only by an explicit user stop (End button / notification).
  String lastRole = '';

  /// Rejoin the last session automatically when the app is opened again
  /// after being killed by the user or the OS.
  bool autoRejoin = true;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    deviceName = prefs.getString('${_prefix}deviceName') ?? '';
    passcode = prefs.getString('${_prefix}passcode') ?? '';
    pushToTalk = prefs.getBool('${_prefix}pushToTalk') ?? false;
    opusBitrateBps = prefs.getInt('${_prefix}opusBitrateBps') ?? 30000;
    enableDtx = prefs.getBool('${_prefix}enableDtx') ?? true;
    autoReconnect = prefs.getBool('${_prefix}autoReconnect') ?? true;
    keepScreenOn = prefs.getBool('${_prefix}keepScreenOn') ?? false;
    lastHostAddress = prefs.getString('${_prefix}lastHostAddress') ?? '';
    lastRole = prefs.getString('${_prefix}lastRole') ?? '';
    autoRejoin = prefs.getBool('${_prefix}autoRejoin') ?? true;
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('${_prefix}deviceName', deviceName);
    await prefs.setString('${_prefix}passcode', passcode);
    await prefs.setBool('${_prefix}pushToTalk', pushToTalk);
    await prefs.setInt('${_prefix}opusBitrateBps', opusBitrateBps);
    await prefs.setBool('${_prefix}enableDtx', enableDtx);
    await prefs.setBool('${_prefix}autoReconnect', autoReconnect);
    await prefs.setBool('${_prefix}keepScreenOn', keepScreenOn);
    await prefs.setString('${_prefix}lastHostAddress', lastHostAddress);
    await prefs.setString('${_prefix}lastRole', lastRole);
    await prefs.setBool('${_prefix}autoRejoin', autoRejoin);
  }
}
