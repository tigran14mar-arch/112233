import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

// Импортируем главный файл для перехода на RitmDeviceShell
import 'main.dart';

// ============================================================================
// ХРАНИЛИЩЕ СЕССИИ (Сохранение в памяти устройства и авто-вход)
// ============================================================================
abstract final class RitmSession {
  static const String apiBaseUrl = 'http://94.228.173.229:8000';

  static const String _keyToken = 'ritm_access_token';
  static const String _keyUserJson = 'ritm_user_json';
  static const String _keyUsername = 'ritm_saved_username';
  static const String _keyPassword = 'ritm_saved_password';

  static String? accessToken;
  static Map<String, dynamic>? currentUser;
  static String? savedUsername;
  static String? savedPassword;

  /// Проверка, вошёл ли уже пользователь в аккаунт (есть ли имя/логин в памяти)
  static bool get isLoggedIn =>
      (currentUser != null &&
          ((currentUser!['full_name'] as String?)?.isNotEmpty == true ||
              (currentUser!['username'] as String?)?.isNotEmpty == true)) ||
          (savedUsername != null && savedUsername!.isNotEmpty);

  static Map<String, String> get authHeaders => {
    'Content-Type': 'application/json',
    'Accept': 'application/json',
    if (accessToken != null && accessToken!.isNotEmpty)
      'Authorization': 'Bearer $accessToken',
  };

  /// Восстановление сохранённой сессии при старте приложения
  static Future<void> restoreFromStorage() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      accessToken = prefs.getString(_keyToken);
      savedUsername = prefs.getString(_keyUsername);
      savedPassword = prefs.getString(_keyPassword);

      final rawUser = prefs.getString(_keyUserJson);
      if (rawUser != null && rawUser.isNotEmpty) {
        currentUser = jsonDecode(rawUser) as Map<String, dynamic>;
      }
    } catch (e) {
      debugPrint('Ошибка чтения сессии из памяти: $e');
    }
  }

  /// Сохранение данных в память после успешного входа
  static Future<void> saveSession({
    required String? token,
    required Map<String, dynamic>? user,
    String? username,
    String? password,
  }) async {
    accessToken = token;
    if (user != null) {
      currentUser = user;
    }
    if (username != null && username.isNotEmpty) {
      savedUsername = username;
    }
    if (password != null && password.isNotEmpty) {
      savedPassword = password;
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      if (token != null) {
        await prefs.setString(_keyToken, token);
      }
      if (currentUser != null) {
        await prefs.setString(_keyUserJson, jsonEncode(currentUser));
      }
      if (savedUsername != null) {
        await prefs.setString(_keyUsername, savedUsername!);
      }
      if (savedPassword != null) {
        await prefs.setString(_keyPassword, savedPassword!);
      }
    } catch (e) {
      debugPrint('Ошибка сохранения сессии в память: $e');
    }
  }

  /// Обновление данных пользователя из БД (например, после GET /api/v1/auth/me)
  static Future<void> updateUser(Map<String, dynamic> user) async {
    currentUser = user;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_keyUserJson, jsonEncode(user));
    } catch (_) {}
  }

  /// Полный выход из аккаунта (очистка памяти)
  static Future<void> clearSession() async {
    accessToken = null;
    currentUser = null;
    savedUsername = null;
    savedPassword = null;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_keyToken);
      await prefs.remove(_keyUserJson);
      await prefs.remove(_keyUsername);
      await prefs.remove(_keyPassword);
    } catch (_) {}
  }
}

// ============================================================================
// РАЗДЕЛ 1: ТОКЕНЫ И ЦВЕТОВАЯ ПАЛИТРА
// ============================================================================
abstract final class RitmRegColors {
  static const Color page = Color(0xFFF4F6F2);
  static const Color surface = Color(0xFFFFFFFF);
  static const Color ink = Color(0xFF18271F);
  static const Color inkSoft = Color(0xFF34443A);
  static const Color muted = Color(0xFF7D8981);
  static const Color line = Color(0xFFE6EBE4);
  static const Color lineStrong = Color(0xFFDCE5DB);

  static const Color accent = Color(0xFF1D523E);
  static const Color accentStrong = Color(0xFF174532);
  static const Color accentSoft = Color(0xFFEAF3E8);
  static const Color accentInk = Color(0xFF426D49);
  static const Color onAccent = Color(0xFFF8FBF4);
  static const Color lime = Color(0xFFD8F28A);

  static const Color inputBg = Color(0xFFFBFCFA);
  static const Color inputFocusBorder = Color(0xFF81A777);

  static const Color error = Color(0xFFC6534C);
  static const Color errorBg = Color(0xFFFFF8F7);
  static const Color errorBorder = Color(0xFFE6AAA4);
  static const Color errorText = Color(0xFFB74640);
}

// ============================================================================
// РАЗДЕЛ 2: КОРНЕВОЙ ВИДЖЕТ И АДАПТИВНАЯ ОБОЛОЧКА
// ============================================================================
class RegistrationScreen extends StatelessWidget {
  const RegistrationScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: RitmRegColors.page,
      body: LayoutBuilder(
        builder: (context, constraints) {
          final isMobile = constraints.maxWidth <= 520;

          if (isMobile) {
            return const SafeArea(
              child: _LoginContent(),
            );
          }

          final maxShellHeight = math.max(620.0, constraints.maxHeight - 48.0);

          return Stack(
            children: [
              Positioned.fill(
                child: DecoratedBox(
                  decoration: const BoxDecoration(color: Color(0xFFE9EEE7)),
                  child: CustomPaint(painter: _PageAmbientBackgroundPainter()),
                ),
              ),
              Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Container(
                    width: 440,
                    constraints: BoxConstraints(
                      maxHeight: maxShellHeight,
                      minHeight: math.min(620.0, maxShellHeight),
                    ),
                    decoration: BoxDecoration(
                      color: RitmRegColors.page,
                      borderRadius: BorderRadius.circular(34),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.88),
                        width: 1,
                      ),
                      boxShadow: const [
                        BoxShadow(
                          color: Color(0x211C3025),
                          blurRadius: 70,
                          offset: Offset(0, 22),
                        ),
                        BoxShadow(
                          color: Color(0x0B1C3025),
                          blurRadius: 12,
                          offset: Offset(0, 3),
                        ),
                      ],
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: const _LoginContent(),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

// ============================================================================
// РАЗДЕЛ 3: КОНТЕНТ ФОРМЫ ВХОДА И API ЗАПРОСЫ
// ============================================================================
class _LoginContent extends StatefulWidget {
  const _LoginContent();

  @override
  State<_LoginContent> createState() => _LoginContentState();
}

class _LoginContentState extends State<_LoginContent> {
  static const String _apiBaseUrl = RitmSession.apiBaseUrl;

  final TextEditingController _loginCtrl = TextEditingController();
  final TextEditingController _pwdCtrl = TextEditingController();

  final FocusNode _loginFocus = FocusNode();
  final FocusNode _pwdFocus = FocusNode();

  bool _isPwdVisible = false;
  bool _isLoading = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _loginCtrl.addListener(_clearError);
    _pwdCtrl.addListener(_clearError);
  }

  void _clearError() {
    if (_errorMessage != null) {
      setState(() => _errorMessage = null);
    }
  }

  @override
  void dispose() {
    _loginCtrl.dispose();
    _pwdCtrl.dispose();
    _loginFocus.dispose();
    _pwdFocus.dispose();
    super.dispose();
  }

  /// Отправка запроса на бэкенд FastAPI (POST /api/v1/auth/login) и сохранение в память
  Future<void> _submitLogin() async {
    final username = _loginCtrl.text.trim();
    final password = _pwdCtrl.text;

    if (username.isEmpty || password.isEmpty) {
      setState(() => _errorMessage = 'Введите логин и пароль.');
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    FocusScope.of(context).unfocus();

    try {
      final url = Uri.parse('$_apiBaseUrl/api/v1/auth/login');
      final response = await http
          .post(
        url,
        headers: const {
          'Content-Type': 'application/json',
          'Accept': 'application/json',
        },
        body: jsonEncode({
          'username': username,
          'password': password,
        }),
      )
          .timeout(const Duration(seconds: 12));

      if (!mounted) return;

      final responseText = utf8.decode(response.bodyBytes);

      if (response.statusCode == 200) {
        final data = jsonDecode(responseText) as Map<String, dynamic>;
        final token = data['access_token'] as String?;
        final userMap = data['user'] as Map<String, dynamic>?;

        // Сохраняем токен, пользователя и логин/пароль в память устройства
        await RitmSession.saveSession(
          token: token,
          user: userMap,
          username: username,
          password: password,
        );

        if (!mounted) return;

        Navigator.of(context).pushReplacement(
          PageRouteBuilder<void>(
            transitionDuration: const Duration(milliseconds: 350),
            pageBuilder: (context, animation, secondaryAnimation) =>
            const RitmDeviceShell(),
            transitionsBuilder:
                (context, animation, secondaryAnimation, child) {
              final curved = CurvedAnimation(
                parent: animation,
                curve: Curves.easeOutCubic,
              );
              return FadeTransition(opacity: curved, child: child);
            },
          ),
        );
      } else {
        String serverDetail = 'Неверный логин или пароль.';
        try {
          final errJson = jsonDecode(responseText) as Map<String, dynamic>;
          if (errJson['detail'] is String) {
            serverDetail = errJson['detail'] as String;
          }
        } catch (_) {}

        if (response.statusCode == 401) {
          setState(() => _errorMessage = serverDetail);
        } else {
          setState(
                () => _errorMessage =
            'Ошибка сервера (${response.statusCode}):$serverDetail',
          );
        }
      }
    } on TimeoutException {
      if (!mounted) return;
      setState(
            () => _errorMessage =
        'Сервер долго не отвечает. Проверьте соединение с $_apiBaseUrl.',
      );
    } catch (e) {
      if (!mounted) return;
      setState(
            () => _errorMessage =
        'Не удалось подключиться к серверу ($_apiBaseUrl).',
      );
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _TopBar(),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(25, 18, 25, 25),
            physics: const BouncingScrollPhysics(),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const _IntroSection(),
                Container(
                  padding: const EdgeInsets.fromLTRB(20, 22, 20, 18),
                  decoration: BoxDecoration(
                    color: RitmRegColors.surface,
                    borderRadius: BorderRadius.circular(23),
                    border: Border.all(color: RitmRegColors.line),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x0E183425),
                        blurRadius: 22,
                        offset: Offset(0, 8),
                      ),
                    ],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text(
                        'Логин',
                        style: TextStyle(
                          color: RitmRegColors.inkSoft,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 8),
                      _CustomTextField(
                        key: const ValueKey('login_field'),
                        controller: _loginCtrl,
                        focusNode: _loginFocus,
                        hint: 'Введите логин',
                        enabled: !_isLoading,
                        textInputAction: TextInputAction.next,
                      ),
                      const SizedBox(height: 17),
                      const Text(
                        'Пароль',
                        style: TextStyle(
                          color: RitmRegColors.inkSoft,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 8),
                      _CustomTextField(
                        key: const ValueKey('pwd_field'),
                        controller: _pwdCtrl,
                        focusNode: _pwdFocus,
                        hint: 'Введите пароль',
                        isPassword: true,
                        isPasswordVisible: _isPwdVisible,
                        enabled: !_isLoading,
                        textInputAction: TextInputAction.done,
                        onSubmitted: _submitLogin,
                        onToggleVisibility: () {
                          setState(() => _isPwdVisible = !_isPwdVisible);
                        },
                      ),
                      const SizedBox(height: 20),
                      _HoverButton(
                        label: 'Войти',
                        isLoading: _isLoading,
                        onTap: _isLoading ? () {} : _submitLogin,
                      ),
                      AnimatedSize(
                        duration: const Duration(milliseconds: 220),
                        curve: Curves.easeOutCubic,
                        child: _errorMessage == null
                            ? const SizedBox(width: double.infinity, height: 0)
                            : Padding(
                          padding: const EdgeInsets.only(top: 14),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              vertical: 11,
                              horizontal: 12,
                            ),
                            decoration: BoxDecoration(
                              color: RitmRegColors.errorBg,
                              border: Border.all(
                                color: RitmRegColors.errorBorder,
                              ),
                              borderRadius: BorderRadius.circular(11),
                            ),
                            child: Text(
                              _errorMessage!,
                              style: const TextStyle(
                                color: RitmRegColors.errorText,
                                fontSize: 14,
                                height: 1.35,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8),
                  child: Text(
                    'Войдите в аккаунт, чтобы продолжить работу с платежами команды.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Color(0xFF89958B),
                      fontSize: 13,
                      height: 1.45,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

// ============================================================================
// РАЗДЕЛ 4: КОМПОНЕНТЫ ИНПУТОВ И КНОПОК
// ============================================================================

class _CustomTextField extends StatefulWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final String hint;
  final bool isPassword;
  final bool isPasswordVisible;
  final bool enabled;
  final VoidCallback? onToggleVisibility;
  final TextInputAction textInputAction;
  final VoidCallback? onSubmitted;

  const _CustomTextField({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.hint,
    this.isPassword = false,
    this.isPasswordVisible = false,
    this.enabled = true,
    this.onToggleVisibility,
    this.textInputAction = TextInputAction.next,
    this.onSubmitted,
  });

  @override
  State<_CustomTextField> createState() => _CustomTextFieldState();
}

class _CustomTextFieldState extends State<_CustomTextField> {
  @override
  void initState() {
    super.initState();
    widget.focusNode.addListener(_handleFocusChange);
  }

  @override
  void didUpdateWidget(_CustomTextField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.focusNode != oldWidget.focusNode) {
      oldWidget.focusNode.removeListener(_handleFocusChange);
      widget.focusNode.addListener(_handleFocusChange);
    }
  }

  @override
  void dispose() {
    widget.focusNode.removeListener(_handleFocusChange);
    super.dispose();
  }

  void _handleFocusChange() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final bool isFocused = widget.focusNode.hasFocus;

    Color borderColor = RitmRegColors.lineStrong;
    Color bgColor = RitmRegColors.inputBg;
    List<BoxShadow> shadow = const [];

    if (isFocused) {
      borderColor = RitmRegColors.inputFocusBorder;
      bgColor = RitmRegColors.surface;
      shadow = const [BoxShadow(color: Color(0x2381A777), spreadRadius: 4)];
    }

    return AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      height: 54,
      decoration: BoxDecoration(
        color: !widget.enabled ? RitmRegColors.line : bgColor,
        borderRadius: BorderRadius.circular(13),
        border: Border.all(color: borderColor),
        boxShadow: shadow,
      ),
      child: Stack(
        alignment: Alignment.centerRight,
        children: [
          TextField(
            controller: widget.controller,
            focusNode: widget.focusNode,
            enabled: widget.enabled,
            obscureText: widget.isPassword && !widget.isPasswordVisible,
            textInputAction: widget.textInputAction,
            onSubmitted:
            widget.onSubmitted != null ? (_) => widget.onSubmitted!() : null,
            style: TextStyle(
              color: widget.enabled ? RitmRegColors.ink : RitmRegColors.muted,
              fontSize: 16,
            ),
            decoration: InputDecoration(
              hintText: widget.hint,
              hintStyle: const TextStyle(color: Color(0xFFA3ADA5)),
              border: InputBorder.none,
              contentPadding: EdgeInsets.only(
                left: 14,
                right:
                widget.isPassword && widget.onToggleVisibility != null
                    ? 54
                    : 14,
                bottom: 2,
              ),
            ),
          ),
          if (widget.isPassword && widget.onToggleVisibility != null)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: widget.enabled ? widget.onToggleVisibility! : null,
                  borderRadius: BorderRadius.circular(10),
                  hoverColor: RitmRegColors.accentSoft,
                  child: Container(
                    width: 42,
                    height: 42,
                    alignment: Alignment.center,
                    child: Icon(
                      widget.isPasswordVisible
                          ? Icons.visibility_off_outlined
                          : Icons.visibility_outlined,
                      color: widget.enabled
                          ? RitmRegColors.accentInk
                          : RitmRegColors.muted,
                      size: 21,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _HoverButton extends StatefulWidget {
  final String label;
  final bool isLoading;
  final VoidCallback onTap;

  const _HoverButton({
    required this.label,
    required this.isLoading,
    required this.onTap,
  });

  @override
  State<_HoverButton> createState() => _HoverButtonState();
}

class _HoverButtonState extends State<_HoverButton> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor:
      widget.isLoading ? SystemMouseCursors.basic : SystemMouseCursors.click,
      child: GestureDetector(
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        onTap: widget.isLoading ? null : widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          transform: Matrix4.translationValues(
            0,
            (_hovered && !widget.isLoading) ? -1.0 : 0.0,
            0,
          ),
          height: 52,
          decoration: BoxDecoration(
            color: (_hovered || _pressed) && !widget.isLoading
                ? RitmRegColors.accentStrong
                : RitmRegColors.accent,
            borderRadius: BorderRadius.circular(13),
            boxShadow: const [
              BoxShadow(
                color: Color(0x26174B3A),
                blurRadius: 11,
                offset: Offset(0, 4),
              ),
            ],
          ),
          alignment: Alignment.center,
          child: widget.isLoading
              ? const SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(
              color: RitmRegColors.onAccent,
              strokeWidth: 2.5,
            ),
          )
              : Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                widget.label,
                style: const TextStyle(
                  color: RitmRegColors.onAccent,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 9),
              const Icon(
                Icons.arrow_forward_rounded,
                color: RitmRegColors.onAccent,
                size: 18,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar();

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Container(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 15),
          color: RitmRegColors.page.withValues(alpha: 0.94),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: RitmRegColors.accentStrong,
                  borderRadius: BorderRadius.circular(14),
                ),
                alignment: Alignment.center,
                child: const SizedBox(
                  width: 25,
                  height: 25,
                  child: CustomPaint(painter: _BrandWavePainter()),
                ),
              ),
              const SizedBox(width: 11),
              const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'ритм',
                    style: TextStyle(
                      color: RitmRegColors.ink,
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                      height: 1.0,
                      letterSpacing: -0.7,
                    ),
                  ),
                  SizedBox(height: 5),
                  Text(
                    'платежи команды',
                    style: TextStyle(
                      color: RitmRegColors.muted,
                      fontSize: 13,
                      height: 1.1,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _IntroSection extends StatelessWidget {
  const _IntroSection();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.fromLTRB(1, 3, 1, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _GreenDot(),
              SizedBox(width: 8),
              Text(
                'ВАШЕ ПРОСТРАНСТВО КОМАНДЫ',
                style: TextStyle(
                  color: RitmRegColors.accentInk,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.7,
                ),
              ),
            ],
          ),
          SizedBox(height: 12),
          Text(
            'Войдите в аккаунт',
            style: TextStyle(
              color: RitmRegColors.ink,
              fontSize: 34,
              fontWeight: FontWeight.w800,
              letterSpacing: -1.1,
              height: 1.06,
            ),
          ),
          SizedBox(height: 8),
          Text(
            'Введите логин и пароль, чтобы перейти к общей сводке платежей.',
            style: TextStyle(
              color: RitmRegColors.muted,
              fontSize: 16,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}

class _GreenDot extends StatelessWidget {
  const _GreenDot();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 7,
      height: 7,
      decoration: const BoxDecoration(
        color: Color(0xFF91BB59),
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: Color(0xFFE4EED9),
            spreadRadius: 4,
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// РАЗДЕЛ 5: ВЕКТОРНЫЕ ИКОНКИ (CustomPainter)
// ============================================================================
class _PageAmbientBackgroundPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final p1 = Paint()
      ..shader = RadialGradient(
        center: const Alignment(-0.72, -0.76),
        radius: 0.55,
        colors: [
          const Color(0xFFD5E6CB).withValues(alpha: 0.7),
          Colors.transparent,
        ],
      ).createShader(Offset.zero & size);
    canvas.drawRect(Offset.zero & size, p1);

    final p2 = Paint()
      ..shader = RadialGradient(
        center: const Alignment(0.76, 0.74),
        radius: 0.55,
        colors: [
          const Color(0xFFD8E8D3).withValues(alpha: 0.55),
          Colors.transparent,
        ],
      ).createShader(Offset.zero & size);
    canvas.drawRect(Offset.zero & size, p2);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _BrandWavePainter extends CustomPainter {
  const _BrandWavePainter();

  @override
  void paint(Canvas canvas, Size size) {
    final sx = size.width / 24.0;
    final sy = size.height / 24.0;

    final strokePaint = Paint()
      ..color = RitmRegColors.lime
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.3 * sx
      ..strokeCap = StrokeCap.round;

    final path = Path()
      ..moveTo(4.0 * sx, 13.2 * sy)
      ..cubicTo(
        6.5 * sx,
        7.3 * sy,
        9.1 * sx,
        7.3 * sy,
        11.6 * sx,
        13.2 * sy,
      )
      ..cubicTo(
        14.1 * sx,
        19.1 * sy,
        16.7 * sx,
        19.1 * sy,
        20.0 * sx,
        11.6 * sy,
      );

    canvas.drawPath(path, strokePaint);

    final fillPaint = Paint()
      ..color = RitmRegColors.lime
      ..style = PaintingStyle.fill;

    canvas.drawCircle(Offset(4.0 * sx, 13.2 * sy), 1.5 * sx, fillPaint);
    canvas.drawCircle(Offset(20.0 * sx, 11.6 * sy), 1.5 * sx, fillPaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}