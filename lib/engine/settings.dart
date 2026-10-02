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
  }
}
