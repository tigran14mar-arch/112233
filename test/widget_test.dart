import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hacaton_plat/main.dart';
import 'package:hacaton_plat/reg.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await RitmSession.clearSession();
  });

  for (final size in [const Size(320, 640), const Size(390, 844), const Size(1280, 800)]) {
    testWidgets('Login fits viewport $size without layout errors', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(const RitmApp());
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Войти'), findsOneWidget);
      expect(find.text('Логин'), findsOneWidget);
      expect(find.text('Пароль'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  test('Missing credentials cannot silently log in as administrator', () async {
    await expectLater(RitmApiService.ensureAuthorized(), throwsA(isA<ApiRequestException>()));
    expect(RitmSession.accessToken, isNull);
  });

  test('Password is not persisted and legacy stored password is removed', () async {
    await RitmSession.saveSession(token: 'test-token', user: {'username': 'demo'},
        username: 'demo', password: 'test-only-password');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('ritm_saved_password'), isNull);
    await prefs.setString('ritm_saved_password', 'legacy-test-password');
    await RitmSession.restoreFromStorage();
    expect(RitmSession.savedPassword, isNull);
    expect(prefs.getString('ritm_saved_password'), isNull);
    expect(RitmSession.accessToken, 'test-token');
  });
}
