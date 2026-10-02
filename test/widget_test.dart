import 'package:flutter_test/flutter_test.dart';
import 'package:intercom_talkie/engine/intercom_engine.dart';
import 'package:intercom_talkie/engine/settings.dart';
import 'package:intercom_talkie/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('home screen renders the setup panel', (tester) async {
    final settings = IntercomSettings();
    await settings.load();
    final engine = IntercomEngine(settings: settings);

    await tester.pumpWidget(IntercomApp(engine: engine));

    expect(find.text('Talkie'), findsOneWidget);
    expect(find.text('Phone 1 — Share Hotspot & Host'), findsOneWidget);
    expect(find.text('Phone 2 — Join Hotspot'), findsOneWidget);
    expect(find.text('Host on this phone'), findsOneWidget);
    expect(find.text('Join the other phone'), findsOneWidget);
    expect(find.text('How it works — 3 steps'), findsOneWidget);

    await engine.dispose();
  });

  testWidgets('home screen switches to the call panel when live',
      (tester) async {
    final settings = IntercomSettings();
    await settings.load();
    final engine = IntercomEngine(settings: settings);

    await tester.pumpWidget(IntercomApp(engine: engine));

    // Simulate a live session and force a rebuild through the listener.
    engine.peerName = 'Test Peer';
    engine.state = IntercomState.connected;
    // ignore: invalid_use_of_protected_member
    engine.notifyListeners();
    await tester.pumpAndSettle();

    expect(find.text('Test Peer'), findsOneWidget);
    expect(find.text('End'), findsOneWidget);
    expect(find.text('Mute'), findsOneWidget);

    await engine.dispose();
  });
}
