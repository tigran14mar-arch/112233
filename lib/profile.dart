import 'dart:convert';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'main.dart';
import 'reg.dart';


String _initialsFromName(String name, {String fallback = 'А'}) {
  final words = name
      .trim()
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty)
      .toList();

  if (words.isEmpty) return fallback;

  String firstChar(String word) =>
      String.fromCharCode(word.runes.first).toUpperCase();

  if (words.length == 1) return firstChar(words[0]);
  return firstChar(words[0]) + firstChar(words[1]);
}
// ============================================================================
// РАЗДЕЛ 1: МОДЕЛЬ ПОЛЬЗОВАТЕЛЯ КОМАНДЫ И РАБОТА С API /api/v1/users
// ============================================================================

class TeamUserDto {
  final int id;
  final String username;
  final String fullName;
  final String role;
  final bool isEnvAdmin;
  final bool isActive;
  final int? telegramUserId;

  const TeamUserDto({
    required this.id,
    required this.username,
    required this.fullName,
    required this.role,
    required this.isEnvAdmin,
    required this.isActive,
    this.telegramUserId,
  });

  String get displayName =>
      fullName.trim().isNotEmpty ? fullName.trim() : username;

  String get firstLetter => _initialsFromName(displayName, fallback: 'У');

  factory TeamUserDto.fromJson(Map<String, dynamic> json) {
    return TeamUserDto(
      id: json['id'] as int? ?? 0,
      username: json['username'] as String? ?? '',
      fullName: json['full_name'] as String? ?? '',
      role: json['role'] as String? ?? 'user',
      isEnvAdmin: json['is_env_admin'] as bool? ?? false,
      isActive: json['is_active'] as bool? ?? true,
      telegramUserId: json['telegram_user_id'] as int?,
    );
  }
}

abstract final class TeamUsersApiService {
  /// Получить список всех пользователей: GET /api/v1/users
  static Future<List<TeamUserDto>> fetchUsers() async {
    await RitmApiService.ensureAuthorized();
    final response = await RitmApiService.getJson(
      '/api/v1/users',
      queryParameters: {'include_inactive': 'true'},
    );

    final rawList = response['data'];
    if (rawList is List) {
      return rawList
          .whereType<Map<String, dynamic>>()
          .map(TeamUserDto.fromJson)
          .toList();
    }
    return const [];
  }

  /// Создать нового пользователя команды: POST /api/v1/users
  static Future<TeamUserDto> createUser({
    required String fullName,
    required String username,
    required String password,
  }) async {
    await RitmApiService.ensureAuthorized();
    final response = await RitmApiService.postJson(
      '/api/v1/users',
      body: {
        'username': username,
        'password': password,
        'full_name': fullName,
        'is_active': true,
      },
    );
    return TeamUserDto.fromJson(response);
  }

  /// Изменить существующего пользователя: PATCH /api/v1/users/{id}
  static Future<TeamUserDto> updateUser({
    required int userId,
    required String fullName,
    required String username,
    String? password,
  }) async {
    await RitmApiService.ensureAuthorized();
    final body = <String, dynamic>{
      'full_name': fullName,
      'username': username,
    };
    if (password != null && password.trim().isNotEmpty) {
      body['password'] = password.trim();
    }

    final response = await RitmApiService.patchJson(
      '/api/v1/users/$userId',
      body: body,
    );
    return TeamUserDto.fromJson(response);
  }

  /// Удалить пользователя: DELETE /api/v1/users/{id}
  static Future<void> deleteUser(int userId) async {
    await RitmApiService.ensureAuthorized();
    final uri = Uri.parse('${RitmApiService.baseUrl}/api/v1/users/$userId');
    final response = await http
        .delete(uri, headers: RitmSession.authHeaders)
        .timeout(const Duration(seconds: 10));

    if (response.statusCode < 200 || response.statusCode >= 300) {
      String detail = 'Ошибка удаления (${response.statusCode})';
      try {
        final decoded =
        jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
        if (decoded['detail'] is String) {
          detail = decoded['detail'] as String;
        }
      } catch (_) {}
      throw ApiRequestException(
        statusCode: response.statusCode,
        detail: detail,
      );
    }
  }
}

// ============================================================================
// РАЗДЕЛ 2: ГЛАВНЫЙ ВИДЖЕТ ЭКРАНА «ПРОФИЛЬ» (ProfileScreen)
// ============================================================================

class ProfileScreen extends StatefulWidget {
  final RitmController controller;
  final VoidCallback onBackToHome;

  const ProfileScreen({
    super.key,
    required this.controller,
    required this.onBackToHome,
  });

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  bool _isLoggingOut = false;

  @override
  void initState() {
    super.initState();
    _syncCurrentUserProfile();
  }

  /// Подтягиваем свежие данные текущего пользователя с сервера: GET /api/v1/auth/me
  Future<void> _syncCurrentUserProfile() async {
    try {
      await RitmApiService.ensureAuthorized();
      final me = await RitmApiService.getJson('/api/v1/auth/me');
      await RitmSession.updateUser(me);
      if (mounted) {
        setState(() {});
      }
    } catch (_) {}
  }

  /// Проверка: является ли текущий вошедший пользователь администратором
  bool get _isAdmin {
    final sessionRole =
    (RitmSession.currentUser?['role'] as String?)?.trim().toLowerCase();
    if (sessionRole != null && sessionRole.isNotEmpty) {
      return sessionRole == 'admin';
    }
    return widget.controller.userRole.trim().toLowerCase() == 'admin';
  }

  /// Отображаемое имя пользователя из БД
  String get _displayName {
    final sFull = (RitmSession.currentUser?['full_name'] as String?)?.trim();
    if (sFull != null && sFull.isNotEmpty) return sFull;
    final sUser = (RitmSession.currentUser?['username'] as String?)?.trim();
    if (sUser != null && sUser.isNotEmpty) return sUser;
    return widget.controller.userDisplayName;
  }

  /// Первая буква имени для круглого аватара (как на главном экране)
  String get _firstLetter => _initialsFromName(_displayName);

  /// Открытие всплывающего окна управления пользователями команды (только для админа)
  Future<void> _openTeamUsersModal() async {
    await showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Закрыть',
      barrierColor: const Color(0x660E1D16),
      transitionDuration: const Duration(milliseconds: 280),
      pageBuilder: (context, anim1, anim2) {
        return _TeamUsersManagementModal(
          controller: widget.controller,
          adminDisplayName: _displayName,
          adminFirstLetter: _firstLetter,
        );
      },
      transitionBuilder: (context, anim, secondaryAnim, child) {
        final curved = CurvedAnimation(
          parent: anim,
          curve: Curves.easeOutCubic,
        );
        return BackdropFilter(
          filter: ImageFilter.blur(
            sigmaX: 4.0 * curved.value,
            sigmaY: 4.0 * curved.value,
          ),
          child: FadeTransition(
            opacity: curved,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, 0.10),
                end: Offset.zero,
              ).animate(curved),
              child: child,
            ),
          ),
        );
      },
    );
  }

  /// Выход из аккаунта с вызовом POST /api/v1/auth/logout и очисткой памяти
  Future<void> _handleLogout() async {
    if (_isLoggingOut) return;
    setState(() => _isLoggingOut = true);

    try {
      await RitmApiService.postJson('/api/v1/auth/logout');
    } catch (_) {}

    await RitmSession.clearSession();
    if (!mounted) return;

    Navigator.of(context).pushAndRemoveUntil(
      PageRouteBuilder<void>(
        transitionDuration: const Duration(milliseconds: 340),
        pageBuilder: (context, animation, secondaryAnimation) =>
        const RegistrationScreen(),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          final curved = CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
          );
          return FadeTransition(opacity: curved, child: child);
        },
      ),
          (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final p = widget.controller.palette;
        final isAdmin = _isAdmin;

        return AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          color: p.page,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // --- БЛОК 1: ВЕРХНЯЯ ПАНЕЛЬ (.subbar) ---
              _ProfileTopBar(
                palette: p,
                onBackTap: widget.onBackToHome,
              ),

              // --- БЛОК 2: ОСНОВНОЙ КОНТЕНТ ПРОФИЛЯ ---
              Expanded(
                child: RefreshIndicator(
                  color: p.accent,
                  backgroundColor: p.surface,
                  onRefresh: () async {
                    await widget.controller.loadFromServer(
                      showSuccessToast: true,
                      isPullToRefresh: true,
                    );
                    await _syncCurrentUserProfile();
                  },
                  child: SingleChildScrollView(
                    physics: const BouncingScrollPhysics(
                      parent: AlwaysScrollableScrollPhysics(),
                    ),
                    padding: const EdgeInsets.fromLTRB(18, 12, 18, 28),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // Вводный заголовок (.profile-intro)
                        _ProfileIntroSection(palette: p),

                        // Секция «Учётная запись» (без квадрата «Ваша роль», с новым кружком и реальным именем)
                        const SizedBox(height: 2),
                        Text(
                          'Учётная запись',
                          style: TextStyle(
                            color: p.ink,
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 9),
                        _AccountIdentityCard(
                          palette: p,
                          firstLetter: _firstLetter,
                          userName: _displayName,
                          roleSubtitle: isAdmin ? 'Администратор' : 'Пользователь',
                        ),

                        // Секция «Настройки» (переключатель тёмно-оранжевой темы)
                        const SizedBox(height: 18),
                        Text(
                          'Настройки',
                          style: TextStyle(
                            color: p.ink,
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 9),
                        _ThemeSettingsCard(
                          palette: p,
                          onToggleTheme: widget.controller.toggleTheme,
                        ),
                        const SizedBox(height: 8),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 2),
                          child: Text(
                            p.isDark
                                ? 'Включено тёмно-оранжевое оформление.'
                                : 'Выбранная тема сохраняется для следующих посещений.',
                            style: TextStyle(
                              color: p.muted,
                              fontSize: 11.5,
                            ),
                          ),
                        ),

                        // Секция «Администрирование» — ОТОБРАЖАЕТСЯ ТОЛЬКО АДМИНУ
                        if (isAdmin) ...[
                          const SizedBox(height: 18),
                          Text(
                            'Администрирование',
                            style: TextStyle(
                              color: p.ink,
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 9),
                          _CenteredTeamUsersButton(
                            palette: p,
                            onTap: _openTeamUsersModal,
                          ),
                          const SizedBox(height: 8),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 2),
                            child: Text(
                              'Учётная запись администратора задаётся через .env и не меняется в панели.',
                              style: TextStyle(
                                color: p.muted,
                                fontSize: 11.5,
                              ),
                            ),
                          ),
                        ],

                        // Кнопка «Выйти из аккаунта» (.logout)
                        const SizedBox(height: 20),
                        _LogoutButton(
                          palette: p,
                          isLoading: _isLoggingOut,
                          onTap: _handleLogout,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ============================================================================
// РАЗДЕЛ 3: КОМПОНЕНТЫ ЭКРАНА ПРОФИЛЯ
// ============================================================================

class _ProfileTopBar extends StatelessWidget {
  final RitmPalette palette;
  final VoidCallback onBackTap;

  const _ProfileTopBar({
    required this.palette,
    required this.onBackTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = palette.isDark;

    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: Container(
          constraints: const BoxConstraints(minHeight: 66),
          padding: const EdgeInsets.fromLTRB(18, 13, 18, 11),
          decoration: BoxDecoration(
            color: isDark ? null : palette.page.withValues(alpha: 0.96),
            gradient: isDark
                ? const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF101010), Color(0xFF18120E)],
            )
                : null,
            border: Border(
              bottom: BorderSide(
                color: isDark
                    ? palette.accent.withValues(alpha: 0.20)
                    : palette.line,
              ),
            ),
          ),
          child: Row(
            children: [
              _ProfileBackBtn(
                palette: palette,
                onTap: onBackTap,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Профиль',
                      style: TextStyle(
                        color: palette.ink,
                        fontSize: 18,
                        height: 1.12,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.35,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Учётная запись · Ритм',
                      style: TextStyle(
                        color: palette.muted,
                        fontSize: 11.5,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ProfileIntroSection extends StatelessWidget {
  final RitmPalette palette;

  const _ProfileIntroSection({required this.palette});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(1, 2, 1, 15),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'ВАШ АККАУНТ',
            style: TextStyle(
              color: palette.accentInk,
              fontSize: 11,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.0,
            ),
          ),
          const SizedBox(height: 7),
          Text(
            'Профиль',
            style: TextStyle(
              color: palette.ink,
              fontSize: 26,
              height: 1.12,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.8,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Здесь находятся данные вашей учётной записи и настройки внешнего вида приложения.',
            style: TextStyle(
              color: palette.muted,
              fontSize: 13,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}

/// Карточка учётной записи:
/// - Кружок с первой буквой имени как на главном экране
/// - Имя человека из БД
/// - Под именем: «Администратор» или «Пользователь»
/// - Без нижнего квадрата «Ваша роль»
class _AccountIdentityCard extends StatelessWidget {
  final RitmPalette palette;
  final String firstLetter;
  final String userName;
  final String roleSubtitle;

  const _AccountIdentityCard({
    required this.palette,
    required this.firstLetter,
    required this.userName,
    required this.roleSubtitle,
  });

  @override
  Widget build(BuildContext context) {
    final p = palette;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: p.line),
      ),
      child: Row(
        children: [
          // Круглый аватар с первой буквой имени (как на главном экране)
          _SingleLetterAvatar(
            size: 44,
            palette: p,
            letter: firstLetter,
          ),
          const SizedBox(width: 12),

          // Имя пользователя из БД и статус под ним («Администратор» / «Пользователь»)
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  userName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: p.ink,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  roleSubtitle,
                  style: TextStyle(
                    color: p.muted,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),

          // Бейдж «Активен» (.active-tag)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: p.successSoft,
              borderRadius: BorderRadius.circular(99),
            ),
            child: Text(
              'Активен',
              style: TextStyle(
                color: p.success,
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Круглый аватар с одной первой буквой имени (в едином стиле с главным экраном)
class _SingleLetterAvatar extends StatelessWidget {
  final double size;
  final RitmPalette palette;
  final String letter;

  const _SingleLetterAvatar({
    required this.size,
    required this.palette,
    required this.letter,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = palette.isDark;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: const Alignment(-0.85, -0.85),
          end: const Alignment(0.85, 0.85),
          colors: isDark
              ? [
            const Color(0xFFFF8838),
            palette.accent,
          ]
              : [
            palette.accent,
            palette.heroDeep,
          ],
        ),
        border: Border.all(
          color: isDark
              ? palette.accentInk.withValues(alpha: 0.45)
              : palette.accentSoft,
          width: 2,
        ),
        boxShadow: [
          BoxShadow(
            color: isDark
                ? const Color(0x38FF7014)
                : const Color(0x24174532),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      alignment: Alignment.center,
      child: Text(
        letter,
        maxLines: 1,
        style: TextStyle(
          color: palette.onAccent,
          fontSize: letter.length > 1 ? size * 0.34 : size * 0.39,
          fontWeight: FontWeight.w800,
          height: 1.0,
          letterSpacing: letter.length > 1 ? 0.2 : -0.3,
        ),
      ),
    );
  }
}

class _ThemeSettingsCard extends StatelessWidget {
  final RitmPalette palette;
  final VoidCallback onToggleTheme;

  const _ThemeSettingsCard({
    required this.palette,
    required this.onToggleTheme,
  });

  @override
  Widget build(BuildContext context) {
    final p = palette;
    final isDark = p.isDark;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: p.line),
      ),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: p.surfaceSoft,
              borderRadius: BorderRadius.circular(10),
            ),
            alignment: Alignment.center,
            child: Text(
              '◐',
              style: TextStyle(
                color: p.accent,
                fontSize: 17,
                height: 1.0,
              ),
            ),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Тёмная тема',
                  style: TextStyle(
                    color: p.ink,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  'Переключите оформление на тёмно-оранжевое или светлое. Изменение применяется сразу.',
                  style: TextStyle(
                    color: p.muted,
                    fontSize: 11.5,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          GestureDetector(
            onTap: onToggleTheme,
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: 44,
                height: 26,
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  color: isDark ? p.accent : const Color(0xFFD8DED8),
                  borderRadius: BorderRadius.circular(99),
                ),
                child: AnimatedAlign(
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeOutCubic,
                  alignment:
                  isDark ? Alignment.centerRight : Alignment.centerLeft,
                  child: Container(
                    width: 20,
                    height: 20,
                    decoration: BoxDecoration(
                      color: isDark ? const Color(0xFF17100B) : Colors.white,
                      shape: BoxShape.circle,
                      boxShadow: const [
                        BoxShadow(
                          color: Color(0x2E000000),
                          blurRadius: 4,
                          offset: Offset(0, 1),
                        ),
                      ],
                    ),
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

/// Кнопка «Пользователи команды» в разделе Администрирование:
/// Оставлена только надпись «Пользователи команды» и поставлена строго по центру
class _CenteredTeamUsersButton extends StatefulWidget {
  final RitmPalette palette;
  final VoidCallback onTap;

  const _CenteredTeamUsersButton({
    required this.palette,
    required this.onTap,
  });

  @override
  State<_CenteredTeamUsersButton> createState() =>
      _CenteredTeamUsersButtonState();
}

class _CenteredTeamUsersButtonState extends State<_CenteredTeamUsersButton> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _pressed ? 0.985 : 1.0,
          duration: const Duration(milliseconds: 120),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            constraints: const BoxConstraints(minHeight: 52),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              color: _hovered ? p.surfaceSoft : p.surface,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: _hovered
                    ? (p.isDark ? p.accent.withValues(alpha: 0.45) : p.lineStrong)
                    : p.line,
              ),
              boxShadow: [
                BoxShadow(
                  color: p.cardShadow,
                  blurRadius: 16,
                  offset: const Offset(0, 5),
                ),
              ],
            ),
            alignment: Alignment.center,
            child: Text(
              'Пользователи команды',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: p.ink,
                fontSize: 14,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.2,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _LogoutButton extends StatefulWidget {
  final RitmPalette palette;
  final bool isLoading;
  final VoidCallback onTap;

  const _LogoutButton({
    required this.palette,
    required this.isLoading,
    required this.onTap,
  });

  @override
  State<_LogoutButton> createState() => _LogoutButtonState();
}

class _LogoutButtonState extends State<_LogoutButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.isLoading ? null : widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          constraints: const BoxConstraints(minHeight: 42),
          decoration: BoxDecoration(
            color: _hovered ? p.surfaceSoft : Colors.transparent,
            borderRadius: BorderRadius.circular(11),
            border: Border.all(color: p.line),
          ),
          alignment: Alignment.center,
          child: widget.isLoading
              ? SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: p.muted,
            ),
          )
              : Text(
            'Выйти из аккаунта',
            style: TextStyle(
              color: p.muted,
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }
}

// ============================================================================
// РАЗДЕЛ 4: ВСПЛЫВАЮЩЕЕ ОКНО УПРАВЛЕНИЯ ПОЛЬЗОВАТЕЛЯМИ КОМАНДЫ (ДЛЯ АДМИНА)
// ============================================================================

class _TeamUsersManagementModal extends StatefulWidget {
  final RitmController controller;
  final String adminDisplayName;
  final String adminFirstLetter;

  const _TeamUsersManagementModal({
    required this.controller,
    required this.adminDisplayName,
    required this.adminFirstLetter,
  });

  @override
  State<_TeamUsersManagementModal> createState() =>
      _TeamUsersManagementModalState();
}

class _TeamUsersManagementModalState extends State<_TeamUsersManagementModal> {
  List<TeamUserDto> _users = [];
  bool _isLoading = true;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _loadUsers();
  }

  /// Загрузка списка пользователей с сервера: GET /api/v1/users
  Future<void> _loadUsers() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final allUsers = await TeamUsersApiService.fetchUsers();
      if (!mounted) return;
      setState(() {
        // Оставляем в списке обычных участников команды (админ показан в фиксированной карточке выше)
        _users = allUsers
            .where((u) => !u.isEnvAdmin && u.role != 'admin')
            .toList();
        _isLoading = false;
      });
    } on ServerOfflineException catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = e.message;
        _isLoading = false;
      });
    } on ApiRequestException catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = e.detail;
        _isLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Не удалось загрузить список пользователей с сервера.';
        _isLoading = false;
      });
    }
  }

  /// Открытие окна добавления или редактирования пользователя
  Future<void> _openUserFormModal({TeamUserDto? existingUser}) async {
    await showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Закрыть',
      barrierColor: const Color(0x660E1D16),
      transitionDuration: const Duration(milliseconds: 240),
      pageBuilder: (context, anim1, anim2) {
        return _UserFormModalSheet(
          controller: widget.controller,
          existingUser: existingUser,
          onSaved: () async {
            await _loadUsers();
          },
        );
      },
      transitionBuilder: (context, anim, _, child) {
        final curved =
        CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
        return FadeTransition(
          opacity: curved,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, 0.12),
              end: Offset.zero,
            ).animate(curved),
            child: child,
          ),
        );
      },
    );
  }

  /// Подтверждение и удаление пользователя через DELETE /api/v1/users/{id}
  Future<void> _confirmDeleteUser(TeamUserDto user) async {
    final p = widget.controller.palette;

    final confirmed = await showGeneralDialog<bool>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Закрыть',
      barrierColor: const Color(0x660E1D16),
      transitionDuration: const Duration(milliseconds: 220),
      pageBuilder: (context, anim1, anim2) {
        return Center(
          child: Material(
            color: Colors.transparent,
            child: Container(
              width: 350,
              margin: const EdgeInsets.symmetric(horizontal: 20),
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: p.surface,
                borderRadius: BorderRadius.circular(22),
                border: Border.all(color: p.line),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Удалить пользователя?',
                    style: TextStyle(
                      color: p.ink,
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Удалить пользователя «${user.displayName}» (${user.username})?',
                    style: TextStyle(
                      color: p.muted,
                      fontSize: 13.5,
                      height: 1.45,
                    ),
                  ),
                  const SizedBox(height: 18),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      _ProfileModalBtn(
                        palette: p,
                        label: 'Отмена',
                        isPrimary: false,
                        onTap: () => Navigator.of(context).pop(false),
                      ),
                      const SizedBox(width: 8),
                      _ProfileModalBtn(
                        palette: p,
                        label: 'Удалить',
                        isPrimary: true,
                        isDanger: true,
                        onTap: () => Navigator.of(context).pop(true),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );

    if (confirmed != true || !mounted) return;

    try {
      await TeamUsersApiService.deleteUser(user.id);
      await _loadUsers();
      widget.controller.showToast('Пользователь удалён');
    } on ApiRequestException catch (e) {
      widget.controller.showToast(e.detail, isError: true);
    } catch (_) {
      widget.controller.showToast(
        'Ошибка при удалении пользователя',
        isError: true,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.controller.palette;
    final maxModalHeight = MediaQuery.sizeOf(context).height * 0.88;

    return Align(
      alignment: Alignment.bottomCenter,
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: 412,
          constraints: BoxConstraints(maxHeight: maxModalHeight),
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 24),
          decoration: BoxDecoration(
            color: p.page,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(26)),
            border: Border.all(
              color: p.isDark ? p.accent.withValues(alpha: 0.28) : p.line,
            ),
            boxShadow: const [
              BoxShadow(
                color: Color(0x42000000),
                blurRadius: 40,
                offset: Offset(0, -10),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Шапка всплывающего окна «Пользователи»
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'АДМИНИСТРИРОВАНИЕ',
                          style: TextStyle(
                            color: p.accentInk,
                            fontSize: 10.5,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1.0,
                          ),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          'Пользователи',
                          style: TextStyle(
                            color: p.ink,
                            fontSize: 24,
                            height: 1.1,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -0.7,
                          ),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          'Управляйте обычными участниками команды. Права администратора не выдаются через эту панель.',
                          style: TextStyle(
                            color: p.muted,
                            fontSize: 12.5,
                            height: 1.45,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  GestureDetector(
                    onTap: () => Navigator.of(context).pop(),
                    child: MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(
                          color: p.surface,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: p.line),
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          '×',
                          style: TextStyle(
                            color: p.muted,
                            fontSize: 18,
                            height: 1.0,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // Прокручиваемая часть со списком пользователей
              Flexible(
                child: SingleChildScrollView(
                  physics: const BouncingScrollPhysics(),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Фиксированная карточка главного администратора
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: p.surface,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: p.line),
                        ),
                        child: Row(
                          children: [
                            _SingleLetterAvatar(
                              size: 36,
                              palette: p,
                              letter: widget.adminFirstLetter,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    widget.adminDisplayName,
                                    style: TextStyle(
                                      color: p.ink,
                                      fontSize: 13.5,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    'Администратор · задан через .env',
                                    style: TextStyle(
                                      color: p.muted,
                                      fontSize: 11.5,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 9,
                                vertical: 5,
                              ),
                              decoration: BoxDecoration(
                                color: p.successSoft,
                                borderRadius: BorderRadius.circular(99),
                              ),
                              child: Text(
                                'Фиксированный',
                                style: TextStyle(
                                  color: p.success,
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 18),

                      // Заголовок «Участники команды» + кнопка «＋ Добавить»
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            'Участники команды',
                            style: TextStyle(
                              color: p.ink,
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          _AddUserSmallButton(
                            palette: p,
                            onTap: () => _openUserFormModal(),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),

                      // Ошибка сервера (если возникла)
                      if (_errorMessage != null) ...[
                        Container(
                          padding: const EdgeInsets.all(12),
                          margin: const EdgeInsets.only(bottom: 10),
                          decoration: BoxDecoration(
                            color: p.warningSoft,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: p.warningLine),
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  _errorMessage!,
                                  style: TextStyle(
                                    color: p.warning,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              TextButton(
                                onPressed: _loadUsers,
                                child: Text(
                                  'Повторить',
                                  style: TextStyle(
                                    color: p.ink,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],

                      // Список участников команды (.account-card)
                      Container(
                        decoration: BoxDecoration(
                          color: p.surface,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: p.line),
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: _isLoading
                            ? Padding(
                          padding: const EdgeInsets.all(24),
                          child: Center(
                            child: SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.3,
                                color: p.accent,
                              ),
                            ),
                          ),
                        )
                            : (_users.isEmpty
                            ? Padding(
                          padding: const EdgeInsets.all(16),
                          child: Text(
                            'Пользователей пока нет. Нажмите «＋ Добавить», чтобы создать учётную запись участника команды.',
                            style: TextStyle(
                              color: p.muted,
                              fontSize: 12.5,
                              height: 1.4,
                            ),
                          ),
                        )
                            : Column(
                          children: List.generate(
                            _users.length,
                                (index) {
                              final user = _users[index];
                              return _TeamUserRow(
                                palette: p,
                                user: user,
                                showTopBorder: index > 0,
                                onEdit: () => _openUserFormModal(
                                  existingUser: user,
                                ),
                                onDelete: () =>
                                    _confirmDeleteUser(user),
                              );
                            },
                          ),
                        )),
                      ),

                      const SizedBox(height: 13),
                      Container(
                        padding: const EdgeInsets.all(11),
                        decoration: BoxDecoration(
                          color: p.surfaceSoft,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: p.line),
                        ),
                        child: Text(
                          'Ограничения по ролям применяются и в панели, и на сервере API.',
                          style: TextStyle(
                            color: p.muted,
                            fontSize: 11.5,
                            height: 1.4,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TeamUserRow extends StatelessWidget {
  final RitmPalette palette;
  final TeamUserDto user;
  final bool showTopBorder;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _TeamUserRow({
    required this.palette,
    required this.user,
    required this.showTopBorder,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final p = palette;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: showTopBorder ? Border(top: BorderSide(color: p.line)) : null,
      ),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: p.surfaceSoft,
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Text(
              user.firstLetter,
              style: TextStyle(
                color: p.accent,
                fontSize: 12,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  user.displayName,
                  style: TextStyle(
                    color: p.ink,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${user.username} · Пользователь',
                  style: TextStyle(
                    color: p.muted,
                    fontSize: 11.5,
                  ),
                ),
              ],
            ),
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _UserTinyIconButton(
                palette: p,
                onTap: onEdit,
                child: Icon(
                  Icons.edit_outlined,
                  size: 14,
                  color: p.muted,
                ),
              ),
              const SizedBox(width: 5),
              _UserTinyIconButton(
                palette: p,
                onTap: onDelete,
                child: Text(
                  '×',
                  style: TextStyle(
                    color: p.muted,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    height: 1.0,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// РАЗДЕЛ 5: МОДАЛЬНОЕ ОКНО СОЗДАНИЯ / РЕДАКТИРОВАНИЯ ПОЛЬЗОВАТЕЛЯ
// ============================================================================

class _UserFormModalSheet extends StatefulWidget {
  final RitmController controller;
  final TeamUserDto? existingUser;
  final Future<void> Function() onSaved;

  const _UserFormModalSheet({
    required this.controller,
    required this.existingUser,
    required this.onSaved,
  });

  @override
  State<_UserFormModalSheet> createState() => _UserFormModalSheetState();
}

class _UserFormModalSheetState extends State<_UserFormModalSheet> {
  late final TextEditingController _fullNameCtrl;
  late final TextEditingController _usernameCtrl;
  late final TextEditingController _passwordCtrl;

  bool _isSubmitting = false;
  bool _obscurePassword = true;
  String? _errorText;

  bool get _isEdit => widget.existingUser != null;

  @override
  void initState() {
    super.initState();
    _fullNameCtrl = TextEditingController(
      text: widget.existingUser?.fullName ?? '',
    );
    _usernameCtrl = TextEditingController(
      text: widget.existingUser?.username ?? '',
    );
    _passwordCtrl = TextEditingController();
  }

  @override
  void dispose() {
    _fullNameCtrl.dispose();
    _usernameCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  Future<void> _submitUser() async {
    final fullName = _fullNameCtrl.text.trim();
    final username = _usernameCtrl.text.trim();
    final password = _passwordCtrl.text;

    if (fullName.isEmpty) {
      setState(() => _errorText = 'Введите имя и фамилию участника.');
      return;
    }
    if (username.length < 3) {
      setState(
            () => _errorText =
        'Логин должен содержать минимум 3 символа (латиница, цифры, ., _, -).',
      );
      return;
    }
    if (!_isEdit &&
        (password.length < 8 ||
            !RegExp(r'[a-zA-Zа-яА-ЯёЁ]').hasMatch(password))) {
      setState(
            () => _errorText =
        'Пароль должен содержать минимум 8 символов и хотя бы одну букву.',
      );
      return;
    }

    setState(() {
      _isSubmitting = true;
      _errorText = null;
    });

    try {
      if (_isEdit) {
        await TeamUsersApiService.updateUser(
          userId: widget.existingUser!.id,
          fullName: fullName,
          username: username,
          password: password.isNotEmpty ? password : null,
        );
      } else {
        await TeamUsersApiService.createUser(
          fullName: fullName,
          username: username,
          password: password,
        );
      }

      await widget.onSaved();
      if (!mounted) return;
      Navigator.of(context).pop();
      widget.controller.showToast(
        _isEdit ? 'Пользователь обновлён' : 'Пользователь создан',
      );
    } on ServerOfflineException catch (e) {
      if (!mounted) return;
      setState(() {
        _errorText = e.message;
        _isSubmitting = false;
      });
    } on ApiRequestException catch (e) {
      if (!mounted) return;
      setState(() {
        _errorText = e.detail;
        _isSubmitting = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _errorText = 'Ошибка сохранения пользователя на сервере.';
        _isSubmitting = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.controller.palette;
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;

    return Align(
      alignment: Alignment.bottomCenter,
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: 412,
          margin: EdgeInsets.only(bottom: bottomInset),
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 22),
          decoration: BoxDecoration(
            color: p.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
            border: Border.all(
              color: p.isDark ? p.accent.withValues(alpha: 0.28) : p.line,
            ),
            boxShadow: const [
              BoxShadow(
                color: Color(0x45000000),
                blurRadius: 36,
                offset: Offset(0, -10),
              ),
            ],
          ),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _isEdit
                                ? 'Изменить пользователя'
                                : 'Новый пользователь',
                            style: TextStyle(
                              color: p.ink,
                              fontSize: 18,
                              fontWeight: FontWeight.w800,
                              letterSpacing: -0.4,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Добавьте участника команды.',
                            style: TextStyle(
                              color: p.muted,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    GestureDetector(
                      onTap: () => Navigator.of(context).pop(),
                      child: Container(
                        width: 31,
                        height: 31,
                        decoration: BoxDecoration(
                          color: p.page,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: p.line),
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          '×',
                          style: TextStyle(
                            color: p.muted,
                            fontSize: 18,
                            height: 1.0,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),

                // Поле: Имя и фамилия
                Text(
                  'Имя и фамилия',
                  style: TextStyle(
                    color: p.muted,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 6),
                _ProfileFormInput(
                  palette: p,
                  controller: _fullNameCtrl,
                  hintText: 'Имя участника',
                ),
                const SizedBox(height: 12),

                // 2 колонки: Логин + Пароль
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Логин',
                            style: TextStyle(
                              color: p.muted,
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 6),
                          _ProfileFormInput(
                            palette: p,
                            controller: _usernameCtrl,
                            hintText: 'm.orlov',
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 11),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _isEdit ? 'Новый пароль (необяз.)' : 'Пароль',
                            style: TextStyle(
                              color: p.muted,
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 6),
                          _ProfileFormInput(
                            palette: p,
                            controller: _passwordCtrl,
                            hintText: 'Мин. 8 символов',
                            obscureText: _obscurePassword,
                            suffix: GestureDetector(
                              onTap: () => setState(
                                    () => _obscurePassword = !_obscurePassword,
                              ),
                              child: Icon(
                                _obscurePassword
                                    ? Icons.visibility_outlined
                                    : Icons.visibility_off_outlined,
                                size: 16,
                                color: p.muted,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 11),
                Text(
                  'Создаётся обычная учётная запись без прав администратора.',
                  style: TextStyle(
                    color: p.muted,
                    fontSize: 11.5,
                    height: 1.4,
                  ),
                ),
                if (_errorText != null) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: p.warningSoft,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: p.warningLine),
                    ),
                    child: Text(
                      _errorText!,
                      style: TextStyle(
                        color: p.warning,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 17),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    _ProfileModalBtn(
                      palette: p,
                      label: 'Отмена',
                      isPrimary: false,
                      onTap: _isSubmitting
                          ? () {}
                          : () => Navigator.of(context).pop(),
                    ),
                    const SizedBox(width: 8),
                    _ProfileModalBtn(
                      palette: p,
                      label: _isEdit ? 'Сохранить' : 'Создать',
                      isPrimary: true,
                      isLoading: _isSubmitting,
                      onTap: _isSubmitting ? () {} : _submitUser,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ============================================================================
// РАЗДЕЛ 6: ВСПОМОГАТЕЛЬНЫЕ КНОПКИ И ИНПУТЫ ПРОФИЛЯ
// ============================================================================

class _ProfileFormInput extends StatefulWidget {
  final RitmPalette palette;
  final TextEditingController controller;
  final String hintText;
  final bool obscureText;
  final Widget? suffix;

  const _ProfileFormInput({
    required this.palette,
    required this.controller,
    required this.hintText,
    this.obscureText = false,
    this.suffix,
  });

  @override
  State<_ProfileFormInput> createState() => _ProfileFormInputState();
}

class _ProfileFormInputState extends State<_ProfileFormInput> {
  final FocusNode _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final focused = _focusNode.hasFocus;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      height: 42,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: p.page,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: focused ? p.accent : p.line),
        boxShadow: focused
            ? [
          BoxShadow(
            color: p.accentSoft,
            spreadRadius: 3,
          ),
        ]
            : null,
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: widget.controller,
              focusNode: _focusNode,
              obscureText: widget.obscureText,
              style: TextStyle(
                color: p.ink,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
              decoration: InputDecoration(
                hintText: widget.hintText,
                hintStyle: TextStyle(
                  color: p.faint,
                  fontSize: 12,
                ),
                border: InputBorder.none,
                isDense: true,
              ),
            ),
          ),
          if (widget.suffix != null) widget.suffix!,
        ],
      ),
    );
  }
}

class _AddUserSmallButton extends StatefulWidget {
  final RitmPalette palette;
  final VoidCallback onTap;

  const _AddUserSmallButton({
    required this.palette,
    required this.onTap,
  });

  @override
  State<_AddUserSmallButton> createState() => _AddUserSmallButtonState();
}

class _AddUserSmallButtonState extends State<_AddUserSmallButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          constraints: const BoxConstraints(minHeight: 32),
          padding: const EdgeInsets.symmetric(horizontal: 11),
          decoration: BoxDecoration(
            color: _hovered ? p.accentStrong : p.accent,
            borderRadius: BorderRadius.circular(9),
          ),
          alignment: Alignment.center,
          child: Text(
            '＋ Добавить',
            style: TextStyle(
              color: p.onAccent,
              fontSize: 11.5,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }
}

class _UserTinyIconButton extends StatefulWidget {
  final RitmPalette palette;
  final VoidCallback onTap;
  final Widget child;

  const _UserTinyIconButton({
    required this.palette,
    required this.onTap,
    required this.child,
  });

  @override
  State<_UserTinyIconButton> createState() => _UserTinyIconButtonState();
}

class _UserTinyIconButtonState extends State<_UserTinyIconButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: _hovered ? p.surfaceSoft : p.surface,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: p.line),
          ),
          alignment: Alignment.center,
          child: widget.child,
        ),
      ),
    );
  }
}

class _ProfileModalBtn extends StatefulWidget {
  final RitmPalette palette;
  final String label;
  final bool isPrimary;
  final bool isDanger;
  final bool isLoading;
  final VoidCallback onTap;

  const _ProfileModalBtn({
    required this.palette,
    required this.label,
    required this.isPrimary,
    this.isDanger = false,
    this.isLoading = false,
    required this.onTap,
  });

  @override
  State<_ProfileModalBtn> createState() => _ProfileModalBtnState();
}

class _ProfileModalBtnState extends State<_ProfileModalBtn> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final Color bg = widget.isDanger
        ? p.warning
        : (widget.isPrimary
        ? (_hovered ? p.accentStrong : p.accent)
        : (_hovered ? p.surfaceSoft : p.surface));
    final Color fg = widget.isDanger
        ? Colors.white
        : (widget.isPrimary ? p.onAccent : p.ink);
    final Color border = widget.isDanger
        ? p.warning
        : (widget.isPrimary ? p.accent : p.line);

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          constraints: const BoxConstraints(minHeight: 38),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: border),
          ),
          alignment: Alignment.center,
          child: widget.isLoading
              ? SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: fg,
            ),
          )
              : Text(
            widget.label,
            style: TextStyle(
              color: fg,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }
}

class _ProfileBackBtn extends StatefulWidget {
  final RitmPalette palette;
  final VoidCallback onTap;

  const _ProfileBackBtn({
    required this.palette,
    required this.onTap,
  });

  @override
  State<_ProfileBackBtn> createState() => _ProfileBackBtnState();
}

class _ProfileBackBtnState extends State<_ProfileBackBtn> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _pressed ? 0.94 : 1.0,
          duration: const Duration(milliseconds: 110),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: _hovered ? p.surfaceSoft : p.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: p.line),
            ),
            alignment: Alignment.center,
            child: Icon(
              Icons.chevron_left_rounded,
              color: p.ink,
              size: 22,
            ),
          ),
        ),
      ),
    );
  }
}