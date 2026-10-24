import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'pay.dart';
import 'history.dart';
import 'profile.dart';
import 'reg.dart';
import 'app_config.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Загружаем сохранённую сессию из памяти перед запуском интерфейса
  await RitmSession.restoreFromStorage();
  runApp(const RitmApp());
}

/// Кастомное поведение прокрутки, чтобы потягивание экрана вниз (Pull-to-Refresh)
/// работало и пальцем на телефоне, и мышкой/тачпадом в браузере и на ПК.
class _RitmScrollBehavior extends MaterialScrollBehavior {
  const _RitmScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => {
    PointerDeviceKind.touch,
    PointerDeviceKind.mouse,
    PointerDeviceKind.trackpad,
    PointerDeviceKind.stylus,
  };
}

// ============================================================================
// РАЗДЕЛ 0: СЕТЕВОЙ КЛИЕНТ ДЛЯ РАБОТЫ С FASTAPI БЭКЕНДОМ
// ============================================================================

/// Исключение, выбрасываемое, когда сервер полностью недоступен (таймаут, отказ в соединении, 502/503/504)
class ServerOfflineException implements Exception {
  final String message;
  const ServerOfflineException(this.message);

  @override
  String toString() => message;
}

/// Исключение, выбрасываемое, когда сервер онлайн, но вернул логическую ошибку (400, 401, 403, 404, 422, 500)
class ApiRequestException implements Exception {
  final int statusCode;
  final String detail;

  const ApiRequestException({
    required this.statusCode,
    required this.detail,
  });

  @override
  String toString() => detail;
}

/// Единый сервис HTTP-запросов к вашему серверу FastAPI
abstract final class RitmApiService {
  static String get baseUrl => AppConfig.apiBaseUrl;
  static const Duration _timeout = Duration(seconds: 10);

  /// Токен сессии (синхронизирован с локальным хранилищем RitmSession)
  static String? get accessToken => RitmSession.accessToken;
  static set accessToken(String? value) => RitmSession.accessToken = value;

  static Map<String, String> get _headers => {
    'Content-Type': 'application/json',
    'Accept': 'application/json',
    if (accessToken != null && accessToken!.isNotEmpty)
      'Authorization': 'Bearer $accessToken',
  };

  /// Проверка здоровья сервера и базы данных: GET /api/v1/health
  static Future<Map<String, dynamic>> checkHealth() async {
    try {
      final uri = Uri.parse('$baseUrl/api/v1/health');
      final response = await http.get(uri).timeout(_timeout);
      final bodyText = utf8.decode(response.bodyBytes);

      if (response.statusCode == 503 ||
          response.statusCode == 502 ||
          response.statusCode == 504) {
        throw const ServerOfflineException(
          'Сервер или база данных временно недоступны (код 503).',
        );
      }

      final data = jsonDecode(bodyText) as Map<String, dynamic>;
      if (data['status'] == 'degraded' || data['database'] != 'ok') {
        final dbError = data['database'] ?? 'неизвестная ошибка БД';
        throw ServerOfflineException(
          'База данных на сервере недоступна: $dbError',
        );
      }

      return data;
    } on ServerOfflineException {
      rethrow;
    } on TimeoutException {
      throw const ServerOfflineException(
        'Превышено время ожидания ответа от сервера. Возможно, сервер перегружен или отключён.',
      );
    } catch (_) {
      throw const ServerOfflineException(
        'Не удалось установить соединение с сервером 94.228.173.229:8000. Проверьте работу сервера или интернет-соединение.',
      );
    }
  }

  /// Автоматическое получение или обновление токена по сохранённым учётным данным
  static Future<void> ensureAuthorized() async {
    if (accessToken != null && accessToken!.isNotEmpty) return;

    final loginToUse = RitmSession.savedUsername;
    final passwordToUse = RitmSession.savedPassword;
    if (loginToUse == null || loginToUse.isEmpty ||
        passwordToUse == null || passwordToUse.isEmpty) {
      throw const ApiRequestException(
        statusCode: 401,
        detail: 'Сессия истекла. Выйдите из аккаунта и войдите снова.',
      );
    }

    try {
      final uri = Uri.parse('$baseUrl/api/v1/auth/login');
      final response = await http
          .post(
        uri,
        headers: const {
          'Content-Type': 'application/json',
          'Accept': 'application/json',
        },
        body: jsonEncode({
          'username': loginToUse,
          'password': passwordToUse,
        }),
      )
          .timeout(_timeout);

      if (response.statusCode == 200) {
        final data =
        jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
        final newToken = data['access_token'] as String?;
        final userMap = data['user'] as Map<String, dynamic>?;
        await RitmSession.saveSession(
          token: newToken,
          user: userMap,
          username: loginToUse,
          password: passwordToUse,
        );
      }
    } on TimeoutException {
      throw const ServerOfflineException(
        'Сервер не отвечает при попытке авторизации.',
      );
    } catch (_) {
      throw const ServerOfflineException(
        'Не удалось подключиться к серверу для авторизации.',
      );
    }
  }

  /// Универсальный GET-запрос с обработкой ошибок FastAPI
  static Future<Map<String, dynamic>> getJson(
      String path, {
        Map<String, String>? queryParameters,
      }) async {
    try {
      final uri = Uri.parse('$baseUrl$path').replace(
        queryParameters: queryParameters,
      );
      var response = await http.get(uri, headers: _headers).timeout(_timeout);

      if (response.statusCode == 401) {
        accessToken = null;
        await ensureAuthorized();
        response = await http.get(uri, headers: _headers).timeout(_timeout);
      }

      return _processResponse(response);
    } on ServerOfflineException {
      rethrow;
    } on ApiRequestException {
      rethrow;
    } on TimeoutException {
      throw const ServerOfflineException(
        'Сервер слишком долго не отвечает (таймаут запроса).',
      );
    } catch (_) {
      throw const ServerOfflineException(
        'Потеряно соединение с сервером. Проверьте подключение и попробуйте снова.',
      );
    }
  }

  /// Универсальный PATCH-запрос для отметки/снятия оплаты
  static Future<Map<String, dynamic>> patchJson(
      String path, {
        required Map<String, dynamic> body,
      }) async {
    try {
      final uri = Uri.parse('$baseUrl$path');
      var response = await http
          .patch(
        uri,
        headers: _headers,
        body: jsonEncode(body),
      )
          .timeout(_timeout);

      if (response.statusCode == 401) {
        accessToken = null;
        await ensureAuthorized();
        response = await http
            .patch(
          uri,
          headers: _headers,
          body: jsonEncode(body),
        )
            .timeout(_timeout);
      }

      return _processResponse(response);
    } on ServerOfflineException {
      rethrow;
    } on ApiRequestException {
      rethrow;
    } on TimeoutException {
      throw const ServerOfflineException(
        'Сервер не ответил вовремя при сохранении изменений.',
      );
    } catch (_) {
      throw const ServerOfflineException(
        'Не удалось отправить данные: сервер недоступен.',
      );
    }
  }

  /// Универсальный POST-запрос
  static Future<Map<String, dynamic>> postJson(
      String path, {
        Map<String, dynamic>? body,
      }) async {
    try {
      final uri = Uri.parse('$baseUrl$path');
      var response = await http
          .post(
        uri,
        headers: _headers,
        body: body != null ? jsonEncode(body) : null,
      )
          .timeout(_timeout);

      if (response.statusCode == 401) {
        accessToken = null;
        await ensureAuthorized();
        response = await http
            .post(
          uri,
          headers: _headers,
          body: body != null ? jsonEncode(body) : null,
        )
            .timeout(_timeout);
      }

      return _processResponse(response);
    } on ServerOfflineException {
      rethrow;
    } on ApiRequestException {
      rethrow;
    } on TimeoutException {
      throw const ServerOfflineException(
        'Сервер не ответил вовремя при выполнении запроса.',
      );
    } catch (_) {
      throw const ServerOfflineException(
        'Не удалось выполнить запрос: сервер недоступен.',
      );
    }
  }

  /// Разбор ответа и чтение поля "detail" при ошибках FastAPI
  static Map<String, dynamic> _processResponse(http.Response response) {
    final bodyText = utf8.decode(response.bodyBytes);

    if (response.statusCode == 502 ||
        response.statusCode == 503 ||
        response.statusCode == 504) {
      throw ServerOfflineException(
        'Сервер временно недоступен (код ${response.statusCode}).',
      );
    }

    if (response.statusCode >= 200 && response.statusCode < 300) {
      if (bodyText.isEmpty) return <String, dynamic>{};
      final decoded = jsonDecode(bodyText);
      if (decoded is Map<String, dynamic>) return decoded;
      return <String, dynamic>{'data': decoded};
    }

    String detailMessage = 'Ошибка сервера (код ${response.statusCode})';
    try {
      final decoded = jsonDecode(bodyText);
      if (decoded is Map<String, dynamic> && decoded['detail'] != null) {
        final detail = decoded['detail'];
        if (detail is String) {
          detailMessage = detail;
        } else if (detail is List && detail.isNotEmpty) {
          final first = detail.first;
          if (first is Map && first['msg'] != null) {
            detailMessage = 'Ошибка данных: ${first['msg']}';
          }
        }
      }
    } catch (_) {}

    throw ApiRequestException(
      statusCode: response.statusCode,
      detail: detailMessage,
    );
  }
}

// ============================================================================
// РАЗДЕЛ 1: ТОКЕНЫ ДИЗАЙН-СИСТЕМЫ И ДИНАМИЧЕСКАЯ ПАЛИТРА ТЕМ (Light & Dark)
// ============================================================================

abstract final class RitmColors {
  static const Color page = Color(0xFFF4F6F2);
  static const Color surface = Color(0xFFFFFFFF);
  static const Color surfaceSoft = Color(0xFFEEF3EC);
  static const Color ink = Color(0xFF18271F);
  static const Color inkSoft = Color(0xFF34443A);
  static const Color muted = Color(0xFF7D8981);
  static const Color faint = Color(0xFFA3ADA5);
  static const Color line = Color(0xFFE6EBE4);
  static const Color lineStrong = Color(0xFFDCE5DB);

  static const Color accent = Color(0xFF1D523E);
  static const Color accentStrong = Color(0xFF174532);
  static const Color accentSoft = Color(0xFFEAF3E8);
  static const Color accentInk = Color(0xFF426D49);
  static const Color onAccent = Color(0xFFF8FBF4);

  static const Color lime = Color(0xFFD8F28A);
  static const Color hero = Color(0xFF173F33);
  static const Color heroDeep = Color(0xFF12372E);
  static const Color heroEnd = Color(0xFF183F34);
  static const Color heroInk = Color(0xFFF7F9F1);
  static const Color heroMuted = Color(0xB8F0F7E7);
  static const Color heroGlass = Color(0x14FFFFFF);
  static const Color heroStroke = Color(0x1FFFFFFF);
  static const Color heroTrack = Color(0x2BFFFFFF);

  static const Color warning = Color(0xFFB85B4D);
  static const Color warningSoft = Color(0xFFFFF1ED);
  static const Color warningLine = Color(0xFFF2DDD7);
  static const Color warningDot = Color(0xFFE57461);
  static const Color warningStripe = Color(0xFFE27B66);

  static const Color success = Color(0xFF4D7F4A);
  static const Color successSoft = Color(0xFFEDF6E9);
  static const Color successDot = Color(0xFF71AA5B);
  static const Color successStripe = Color(0xFF75A55F);

  static const Color info = Color(0xFF4385A0);
  static const Color infoSoft = Color(0xFFEAF3F5);
  static const Color toastBg = Color(0xFF22392D);
}

class RitmPalette {
  final bool isDark;
  final Color page;
  final Color surface;
  final Color surfaceSoft;
  final Color ink;
  final Color inkSoft;
  final Color muted;
  final Color faint;
  final Color line;
  final Color lineStrong;

  final Color accent;
  final Color accentStrong;
  final Color accentSoft;
  final Color accentInk;
  final Color onAccent;

  final Color lime;
  final Color hero;
  final Color heroDeep;
  final Color heroEnd;
  final Color heroInk;
  final Color heroMuted;
  final Color heroGlass;
  final Color heroStroke;
  final Color heroTrack;

  final Color warning;
  final Color warningSoft;
  final Color warningLine;
  final Color warningDot;
  final Color warningStripe;

  final Color success;
  final Color successSoft;
  final Color successDot;
  final Color successStripe;

  final Color info;
  final Color infoSoft;
  final Color toastBg;
  final Color cardShadow;

  const RitmPalette({
    required this.isDark,
    required this.page,
    required this.surface,
    required this.surfaceSoft,
    required this.ink,
    required this.inkSoft,
    required this.muted,
    required this.faint,
    required this.line,
    required this.lineStrong,
    required this.accent,
    required this.accentStrong,
    required this.accentSoft,
    required this.accentInk,
    required this.onAccent,
    required this.lime,
    required this.hero,
    required this.heroDeep,
    required this.heroEnd,
    required this.heroInk,
    required this.heroMuted,
    required this.heroGlass,
    required this.heroStroke,
    required this.heroTrack,
    required this.warning,
    required this.warningSoft,
    required this.warningLine,
    required this.warningDot,
    required this.warningStripe,
    required this.success,
    required this.successSoft,
    required this.successDot,
    required this.successStripe,
    required this.info,
    required this.infoSoft,
    required this.toastBg,
    required this.cardShadow,
  });

  static const RitmPalette light = RitmPalette(
    isDark: false,
    page: Color(0xFFF4F6F2),
    surface: Color(0xFFFFFFFF),
    surfaceSoft: Color(0xFFEEF3EC),
    ink: Color(0xFF18271F),
    inkSoft: Color(0xFF34443A),
    muted: Color(0xFF7D8981),
    faint: Color(0xFFA3ADA5),
    line: Color(0xFFE6EBE4),
    lineStrong: Color(0xFFDCE5DB),
    accent: Color(0xFF1D523E),
    accentStrong: Color(0xFF174532),
    accentSoft: Color(0xFFEAF3E8),
    accentInk: Color(0xFF426D49),
    onAccent: Color(0xFFF8FBF4),
    lime: Color(0xFFD8F28A),
    hero: Color(0xFF173F33),
    heroDeep: Color(0xFF12372E),
    heroEnd: Color(0xFF183F34),
    heroInk: Color(0xFFF7F9F1),
    heroMuted: Color(0xB8F0F7E7),
    heroGlass: Color(0x14FFFFFF),
    heroStroke: Color(0x1FFFFFFF),
    heroTrack: Color(0x2BFFFFFF),
    warning: Color(0xFFB85B4D),
    warningSoft: Color(0xFFFFF1ED),
    warningLine: Color(0xFFF2DDD7),
    warningDot: Color(0xFFE57461),
    warningStripe: Color(0xFFE27B66),
    success: Color(0xFF4D7F4A),
    successSoft: Color(0xFFEDF6E9),
    successDot: Color(0xFF71AA5B),
    successStripe: Color(0xFF75A55F),
    info: Color(0xFF4385A0),
    infoSoft: Color(0xFFEAF3F5),
    toastBg: Color(0xFF22392D),
    cardShadow: Color(0x0E183425),
  );

  static const RitmPalette dark = RitmPalette(
    isDark: true,
    page: Color(0xFF080808),
    surface: Color(0xFF141414),
    surfaceSoft: Color(0xFF1D1D1D),
    ink: Color(0xFFF6F6F6),
    inkSoft: Color(0xFFD2D2D2),
    muted: Color(0xFFB0B0B0),
    faint: Color(0xFF8B8B8B),
    line: Color(0xFF303030),
    lineStrong: Color(0xFF414141),
    accent: Color(0xFFFF7014),
    accentStrong: Color(0xFFFF7A1A),
    accentSoft: Color(0xFF2B170B),
    accentInk: Color(0xFFFF9E62),
    onAccent: Color(0xFF17100B),
    lime: Color(0xFFFF7014),
    hero: Color(0xFF171717),
    heroDeep: Color(0xFF0B0B0B),
    heroEnd: Color(0xFF183F34),
    heroInk: Color(0xFFF7F7F7),
    heroMuted: Color(0xADFFFFFF),
    heroGlass: Color(0x13FFFFFF),
    heroStroke: Color(0x1AFFFFFF),
    heroTrack: Color(0x2BFFFFFF),
    warning: Color(0xFFEE9B88),
    warningSoft: Color(0xFF3E2924),
    warningLine: Color(0xFF614038),
    warningDot: Color(0xFFE57461),
    warningStripe: Color(0xFFE27B66),
    success: Color(0xFF98C982),
    successSoft: Color(0xFF273A26),
    successDot: Color(0xFF71AA5B),
    successStripe: Color(0xFF75A55F),
    info: Color(0xFF8BC1D4),
    infoSoft: Color(0xFF253F48),
    toastBg: Color(0xFF22392D),
    cardShadow: Color(0x33000000),
  );
}

// ============================================================================
// РАЗДЕЛ 2: МОДЕЛИ ДАННЫХ И ФОРМАТТЕРЫ (Валюты, Даты, Склонения)
// ============================================================================

enum CurrencyCode { rub, usd, eur }

enum PaymentStatus { paid, upcoming, overdue }

class PaymentItem {
  final String id;
  final int? occurrenceId;
  final int day;
  final int month;
  final int year;
  final String name;
  final double amount;
  final CurrencyCode currency;
  final PaymentStatus status;
  final DateTime dueDate;
  final DateTime? paidDate;
  final String unpaidNote;

  const PaymentItem({
    required this.id,
    this.occurrenceId,
    required this.day,
    this.month = 10,
    this.year = 2026,
    required this.name,
    required this.amount,
    required this.currency,
    required this.status,
    required this.dueDate,
    this.paidDate,
    required this.unpaidNote,
  });

  bool get isPaid => status == PaymentStatus.paid;
  bool get isOverdue => status == PaymentStatus.overdue;

  String get formattedAmount => RitmFormatters.formatMoney(amount, currency);

  String get timingLabel {
    if (paidDate == null) return 'в срок';
    final paidDay = DateTime(paidDate!.year, paidDate!.month, paidDate!.day);
    final dueDay = DateTime(dueDate.year, dueDate.month, dueDate.day);
    if (paidDay.isAfter(dueDay)) return 'с опозданием';
    if (paidDay.isBefore(dueDay)) return 'заранее';
    return 'в срок';
  }

  bool get isPaidLate {
    if (paidDate == null) return false;
    final paidDay = DateTime(paidDate!.year, paidDate!.month, paidDate!.day);
    final dueDay = DateTime(dueDate.year, dueDate.month, dueDate.day);
    return paidDay.isAfter(dueDay);
  }

  int get overdueDaysCount {
    final nowDay = DateTime(
      RitmController.today.year,
      RitmController.today.month,
      RitmController.today.day,
    );
    final dueDay = DateTime(dueDate.year, dueDate.month, dueDate.day);
    final diff = nowDay.difference(dueDay).inDays;
    return math.max(0, diff);
  }

  String get calendarNote {
    if (status == PaymentStatus.paid && paidDate != null) {
      return 'Оплачено · ${RitmFormatters.dayMonthLong(paidDate!)}';
    }
    return unpaidNote;
  }

  /// Создание PaymentItem из JSON-объекта периода оплаты FastAPI (PaymentOccurrence)
  factory PaymentItem.fromOccurrenceJson(
      Map<String, dynamic> json, {
        String? slotAliasId,
      }) {
    final occurrenceId = json['id'] as int?;
    final rawAmount = json['amount'];
    final parsedAmount = rawAmount is num
        ? rawAmount.toDouble()
        : double.tryParse(rawAmount.toString()) ?? 0.0;

    final currencyStr = (json['currency'] as String? ?? 'RUB').toUpperCase();
    final currency = switch (currencyStr) {
      'USD' => CurrencyCode.usd,
      'EUR' => CurrencyCode.eur,
      _ => CurrencyCode.rub,
    };

    final dueDateStr =
        json['due_date'] as String? ?? RitmFormatters.isoDate(DateTime.now());
    final dueDate = DateTime.tryParse(dueDateStr) ?? DateTime.now();

    final actualPaidStr = json['actual_payment_date'] as String?;
    final paidDate =
    actualPaidStr != null ? DateTime.tryParse(actualPaidStr) : null;

    final isPaid = json['is_paid'] as bool? ?? (json['status'] == 'paid');
    final isOverdue = json['is_overdue'] as bool? ?? false;
    final overdueDays = json['overdue_days'] as int? ?? 0;

    final status = isPaid
        ? PaymentStatus.paid
        : (isOverdue ? PaymentStatus.overdue : PaymentStatus.upcoming);

    String note = json['notes'] as String? ?? '';
    if (note.isEmpty) {
      if (isOverdue && overdueDays > 0) {
        note =
        'Срок прошёл $overdueDays ${RitmFormatters.pluralDays(overdueDays)} назад';
      } else if (json['reminded_at'] != null) {
        note = 'Напоминание отправлено в Telegram';
      } else {
        note = 'Срок оплаты — ${RitmFormatters.dayMonthLong(dueDate)}';
      }
    }

    return PaymentItem(
      id: slotAliasId ?? (occurrenceId?.toString() ?? dueDateStr),
      occurrenceId: occurrenceId,
      day: dueDate.day,
      month: dueDate.month,
      year: dueDate.year,
      name: json['name'] as String? ?? 'Платёж',
      amount: parsedAmount,
      currency: currency,
      status: status,
      dueDate: dueDate,
      paidDate: paidDate,
      unpaidNote: note,
    );
  }

  PaymentItem copyWith({
    String? id,
    int? occurrenceId,
    PaymentStatus? status,
    DateTime? paidDate,
    bool clearPaidDate = false,
    String? unpaidNote,
  }) {
    return PaymentItem(
      id: id ?? this.id,
      occurrenceId: occurrenceId ?? this.occurrenceId,
      day: day,
      month: month,
      year: year,
      name: name,
      amount: amount,
      currency: currency,
      status: status ?? this.status,
      dueDate: dueDate,
      paidDate: clearPaidDate ? null : (paidDate ?? this.paidDate),
      unpaidNote: unpaidNote ?? this.unpaidNote,
    );
  }
}

class HistoryEntry {
  final String paymentId;
  final String name;
  final String subtitle;
  final String formattedAmount;

  const HistoryEntry({
    required this.paymentId,
    required this.name,
    required this.subtitle,
    required this.formattedAmount,
  });
}

abstract final class RitmFormatters {
  static const List<String> _monthsNominative = [
    'Январь',
    'Февраль',
    'Март',
    'Апрель',
    'Май',
    'Июнь',
    'Июль',
    'Август',
    'Сентябрь',
    'Октябрь',
    'Ноябрь',
    'Декабрь',
  ];

  static const List<String> _monthsGenitive = [
    'января',
    'февраля',
    'марта',
    'апреля',
    'мая',
    'июня',
    'июля',
    'августа',
    'сентября',
    'октября',
    'ноября',
    'декабря',
  ];

  static const List<String> _monthsAccusative = [
    'январь',
    'февраль',
    'март',
    'апрель',
    'май',
    'июнь',
    'июль',
    'август',
    'сентябрь',
    'октябрь',
    'ноябрь',
    'декабрь',
  ];

  static const List<String> _monthsShort = [
    'янв',
    'фев',
    'мар',
    'апр',
    'мая',
    'июн',
    'июл',
    'авг',
    'сен',
    'окт',
    'ноя',
    'дек',
  ];

  static const List<String> _weekdaysFull = [
    'ПОНЕДЕЛЬНИК',
    'ВТОРНИК',
    'СРЕДА',
    'ЧЕТВЕРГ',
    'ПЯТНИЦА',
    'СУББОТА',
    'ВОСКРЕСЕНЬЕ',
  ];

  static String monthYearTitle(DateTime date) =>
      '${_monthsNominative[date.month - 1]} ${date.year}';

  static String monthYearUpper(DateTime date) =>
      '${_monthsNominative[date.month - 1].toUpperCase()} · ${date.year}';

  static String forMonthAccusative(DateTime date) =>
      'за ${_monthsAccusative[date.month - 1]}';

  static String forMonthCapitalized(DateTime date) =>
      'За ${_monthsAccusative[date.month - 1]}';

  static String weekdayDayMonthUpper(DateTime date) {
    final weekday = _weekdaysFull[(date.weekday - 1).clamp(0, 6)];
    final month = _monthsGenitive[date.month - 1].toUpperCase();
    return '$weekday · ${date.day} $month';
  }

  static String dayMonthLong(DateTime date) =>
      '${date.day} ${_monthsGenitive[date.month - 1]}';

  static String shortDate(DateTime date) =>
      '${date.day} ${_monthsShort[date.month - 1]}';

  static String isoDate(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-'
          '${date.month.toString().padLeft(2, '0')}-'
          '${date.day.toString().padLeft(2, '0')}';

  static String pluralPayments(int n) {
    final a = n % 100;
    final b = n % 10;
    if (a > 10 && a < 20) return 'платежей';
    if (b == 1) return 'платёж';
    if (b >= 2 && b <= 4) return 'платежа';
    return 'платежей';
  }

  static String pluralDays(int n) {
    final a = n % 100;
    final b = n % 10;
    if (a > 10 && a < 20) return 'дней';
    if (b == 1) return 'день';
    if (b >= 2 && b <= 4) return 'дня';
    return 'дней';
  }

  static String formatNumber(double value, CurrencyCode currency) {
    final isRub = currency == CurrencyCode.rub;
    if (isRub || value == value.roundToDouble()) {
      final intVal = value.round();
      final str = intVal.toString();
      final buffer = StringBuffer();
      for (int i = 0; i < str.length; i++) {
        if (i > 0 && (str.length - i) % 3 == 0) {
          buffer.write('\u00A0');
        }
        buffer.write(str[i]);
      }
      return buffer.toString();
    } else {
      String fixed = value.toStringAsFixed(2);
      if (fixed.endsWith('0')) {
        fixed = fixed.substring(0, fixed.length - 1);
      }
      return fixed.replaceAll('.', ',');
    }
  }

  static String formatMoney(
      double value,
      CurrencyCode currency, {
        bool keepTrailingZero = false,
      }) {
    final numStr = keepTrailingZero && value != value.roundToDouble()
        ? value.toStringAsFixed(2).replaceAll('.', ',')
        : formatNumber(value, currency);
    switch (currency) {
      case CurrencyCode.rub:
        return '$numStr ₽';
      case CurrencyCode.usd:
        return '\$$numStr';
      case CurrencyCode.eur:
        return '€$numStr';
    }
  }
}

// ============================================================================
// РАЗДЕЛ 3: КОНТРОЛЛЕР СОСТОЯНИЯ (Интеграция с FastAPI + Данные из БД)
// ============================================================================

class RitmController extends ChangeNotifier {
  /// Актуальная сегодняшняя дата (обновляется с сервера при загрузке или берётся системная)
  static DateTime today = DateTime.now();

  static const List<String> _legacySlotIds = [
    'workplaces',
    'domain',
    'telecom',
    'analytics',
    'rent',
    'server',
    'tools',
  ];

  bool _isDarkTheme = false;
  DateTime _viewMonth = DateTime(DateTime.now().year, DateTime.now().month, 1);
  int _selectedDay = DateTime.now().day;

  // --- Данные текущего пользователя из базы данных ---
  String _userFullName = 'Администратор';
  String _userUsername = 'admin';
  String _userRole = 'admin';

  // --- Состояния сети и ошибок ---
  bool _isInitialLoading = false;
  bool _isServerOffline = false;
  String? _serverOfflineReason;
  String? _apiErrorBanner;
  bool _isToastError = false;

  final Map<int, PaymentItem> _octoberItems = {};
  final List<HistoryEntry> _history = [];

  String? _toastMessage;
  Timer? _toastTimer;

  RitmController() {
    if (RitmSession.savedUsername != null &&
        RitmSession.savedUsername!.isNotEmpty) {
      _userUsername = RitmSession.savedUsername!;
      _userFullName = RitmSession.savedUsername!;
    }
    _applyUserMap(RitmSession.currentUser);
  }

  void _applyUserMap(Map<String, dynamic>? userMap) {
    if (userMap == null) return;
    final fullName = (userMap['full_name'] as String?)?.trim();
    final username = (userMap['username'] as String?)?.trim();
    final role = (userMap['role'] as String?)?.trim();

    if (fullName != null && fullName.isNotEmpty) {
      _userFullName = fullName;
    } else if (username != null && username.isNotEmpty) {
      _userFullName = username;
    }
    if (username != null && username.isNotEmpty) {
      _userUsername = username;
    }
    if (role != null && role.isNotEmpty) {
      _userRole = role;
    }
  }

  // --- Геттеры пользователя из БД ---
  String get userFullName => _userFullName;
  String get userUsername => _userUsername;
  String get userRole => _userRole;

  /// Имя для приветствия на главном экране (берётся из БД)
  String get userDisplayName {
    final trimmed = _userFullName.trim();
    if (trimmed.isEmpty) return _userUsername;
    return trimmed;
  }

  /// Первая буква имени пользователя для кружка аватара в правом верхнем углу
  String get userInitials {
    final words = userDisplayName
        .trim()
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();

    if (words.isEmpty) return 'А';

    String firstChar(String word) =>
        String.fromCharCode(word.runes.first).toUpperCase();

    if (words.length == 1) return firstChar(words[0]);
    return firstChar(words[0]) + firstChar(words[1]);
  }

  /// Оставлен для обратной совместимости, если где-то ещё используется в profile.dart / pay.dart
  String get userFirstLetter => userInitials;

  // --- Геттеры темы и состояния сети ---
  bool get isDarkTheme => _isDarkTheme;
  RitmPalette get palette =>
      _isDarkTheme ? RitmPalette.dark : RitmPalette.light;

  bool get isInitialLoading => _isInitialLoading;
  bool get isServerOffline => _isServerOffline;
  String? get serverOfflineReason => _serverOfflineReason;
  String? get apiErrorBanner => _apiErrorBanner;
  bool get isToastError => _isToastError;

  void dismissApiErrorBanner() {
    _apiErrorBanner = null;
    notifyListeners();
  }

  void toggleTheme() {
    _isDarkTheme = !_isDarkTheme;
    notifyListeners();
  }

  // --- Геттеры данных ---
  DateTime get viewMonth => _viewMonth;
  int get selectedDay => _selectedDay;
  bool get isViewingOctober2026 =>
      _viewMonth.year == today.year && _viewMonth.month == today.month;
  List<HistoryEntry> get history => List.unmodifiable(_history);
  String? get toastMessage => _toastMessage;

  Map<int, PaymentItem> get currentMonthItems => _octoberItems;

  PaymentItem? get selectedDayItem => currentMonthItems[_selectedDay];

  /// Возвращает приоритетный платёж из БД для блока «Нужно проверить»
  PaymentItem? get priorityCheckItem {
    for (final item in _octoberItems.values) {
      if (item.isOverdue) return item;
    }
    for (final item in _octoberItems.values) {
      if (!item.isPaid) return item;
    }
    if (_octoberItems.isNotEmpty) return _octoberItems.values.first;
    return null;
  }

  /// Геттер rentItem сохранён для обратной совместимости с pay.dart / profile.dart
  PaymentItem get rentItem {
    final item = priorityCheckItem;
    if (item != null) return item;
    return PaymentItem(
      id: 'empty',
      day: today.day,
      month: today.month,
      year: today.year,
      name: 'Нет активных платежей',
      amount: 0,
      currency: CurrencyCode.rub,
      dueDate: today,
      status: PaymentStatus.paid,
      paidDate: today,
      unpaidNote: 'Все платежи за месяц проверены',
    );
  }

  int get totalCount => _octoberItems.length;
  int get paidCount => _octoberItems.values.where((e) => e.isPaid).length;
  int get pendingCount => math.max(0, totalCount - paidCount);

  double get progressFraction =>
      totalCount == 0 ? 0.0 : (paidCount / totalCount).clamp(0.0, 1.0);

  int get progressPercent => (progressFraction * 100).round();

  int get overdueCount =>
      _octoberItems.values.where((e) => e.isOverdue).length;

  double remainingForCurrency(CurrencyCode code) {
    double sum = 0;
    for (final item in _octoberItems.values) {
      if (!item.isPaid && item.currency == code) {
        sum += item.amount;
      }
    }
    return math.max(0, sum);
  }

  String formattedRemainingCurrency(CurrencyCode code) {
    final rem = remainingForCurrency(code);
    if (rem <= 0.001) return '—';
    return RitmFormatters.formatMoney(
      rem,
      code,
      keepTrailingZero: code == CurrencyCode.eur,
    );
  }

  PaymentItem? findById(String id) {
    for (final item in _octoberItems.values) {
      if (item.id == id || item.occurrenceId?.toString() == id) {
        return item;
      }
    }
    return null;
  }

  // ==========================================================================
  // МЕТОДЫ СИНХРОНИЗАЦИИ С СЕРВЕРОМ FASTAPI И БАЗОЙ ДАННЫХ
  // ==========================================================================

  /// Загрузка данных с сервера (Health + Профиль из БД + Dashboard + Периоды оплаты)
  Future<void> loadFromServer({
    bool showSuccessToast = false,
    bool isPullToRefresh = false,
  }) async {
    if (!isPullToRefresh) {
      _isInitialLoading = true;
    }
    _apiErrorBanner = null;
    _applyUserMap(RitmSession.currentUser);
    notifyListeners();

    final stopwatch = Stopwatch()..start();

    try {
      // 1. Проверяем здоровье сервера и получаем актуальную дату сервера (/api/v1/health)
      final healthData = await RitmApiService.checkHealth();
      final serverTodayStr = healthData['today'] as String?;
      if (serverTodayStr != null) {
        final parsedToday = DateTime.tryParse(serverTodayStr);
        if (parsedToday != null) {
          final wasDefaultMonth = _octoberItems.isEmpty;
          today = parsedToday;
          if (wasDefaultMonth) {
            _viewMonth = DateTime(today.year, today.month, 1);
            _selectedDay = today.day;
          }
        }
      }

      // 2. Убеждаемся, что есть токен авторизации
      await RitmApiService.ensureAuthorized();
      _applyUserMap(RitmSession.currentUser);

      // 3. Запрашиваем данные текущего пользователя напрямую из БД (/api/v1/auth/me)
      try {
        final meData = await RitmApiService.getJson('/api/v1/auth/me');
        await RitmSession.updateUser(meData);
        _applyUserMap(meData);
      } catch (_) {}

      // 4. Запрашиваем сводку дашборда (/api/v1/dashboard), где также есть user и today
      final dashboardData = await RitmApiService.getJson('/api/v1/dashboard');
      if (dashboardData['user'] is Map<String, dynamic>) {
        final dashUser = dashboardData['user'] as Map<String, dynamic>;
        await RitmSession.updateUser(dashUser);
        _applyUserMap(dashUser);
      }
      final dashTodayStr = dashboardData['today'] as String?;
      if (dashTodayStr != null) {
        final parsedDashToday = DateTime.tryParse(dashTodayStr);
        if (parsedDashToday != null) {
          today = parsedDashToday;
        }
      }

      // 5. Запрашиваем периоды оплаты из БД за просматриваемый месяц (/api/v1/payment-occurrences)
      await _fetchMonthOccurrences(_viewMonth);

      // Если пользователь потянул экран вниз, удерживаем индикатор минимум 550 мс для плавности
      if (isPullToRefresh && stopwatch.elapsedMilliseconds < 550) {
        await Future<void>.delayed(
          Duration(milliseconds: 550 - stopwatch.elapsedMilliseconds),
        );
      }

      _isServerOffline = false;
      _serverOfflineReason = null;
      _isInitialLoading = false;
      notifyListeners();

      if (showSuccessToast) {
        showToast(
          isPullToRefresh
              ? 'Данные с сервера обновлены'
              : 'Связь с сервером восстановлена',
        );
      }
    } on ServerOfflineException catch (e) {
      _isServerOffline = true;
      _serverOfflineReason = e.message;
      _isInitialLoading = false;
      notifyListeners();
    } on ApiRequestException catch (e) {
      _isServerOffline = false;
      _isInitialLoading = false;
      _apiErrorBanner = e.detail;
      notifyListeners();
      showToast(e.detail, isError: true);
    } catch (_) {
      _isServerOffline = true;
      _serverOfflineReason =
      'Не удалось подключиться к серверу. Проверьте его работу и нажмите «Повторить».';
      _isInitialLoading = false;
      notifyListeners();
    }
  }

  /// Загрузка реальных периодов оплаты за конкретный месяц из БД
  Future<void> _fetchMonthOccurrences(DateTime monthDate) async {
    final firstDay = DateTime(monthDate.year, monthDate.month, 1);
    final lastDay = DateTime(monthDate.year, monthDate.month + 1, 0);

    final response = await RitmApiService.getJson(
      '/api/v1/payment-occurrences',
      queryParameters: {
        'date_from': RitmFormatters.isoDate(firstDay),
        'date_to': RitmFormatters.isoDate(lastDay),
        'limit': '100',
        'sort': 'due_date',
      },
    );

    _octoberItems.clear();
    _history.clear();

    final rawItems = response['items'];
    if (rawItems is List && rawItems.isNotEmpty) {
      final paidItemsList = <PaymentItem>[];

      for (int i = 0; i < rawItems.length; i++) {
        final map = rawItems[i] as Map<String, dynamic>;
        final aliasId = i < _legacySlotIds.length ? _legacySlotIds[i] : null;
        final item = PaymentItem.fromOccurrenceJson(
          map,
          slotAliasId: aliasId,
        );

        int dayKey = item.day;
        while (_octoberItems.containsKey(dayKey) && dayKey < 31) {
          dayKey++;
        }
        _octoberItems[dayKey] = item;

        if (item.isPaid) {
          paidItemsList.add(item);
        }
      }

      paidItemsList.sort((a, b) {
        final dateA = a.paidDate ?? a.dueDate;
        final dateB = b.paidDate ?? b.dueDate;
        return dateB.compareTo(dateA);
      });

      for (final item in paidItemsList) {
        final paidDate = item.paidDate ?? item.dueDate;
        _history.add(
          HistoryEntry(
            paymentId: item.id,
            name: item.name,
            subtitle: 'Оплачено · ${RitmFormatters.dayMonthLong(paidDate)}',
            formattedAmount: item.formattedAmount,
          ),
        );
      }

      if (!_octoberItems.containsKey(_selectedDay)) {
        if (monthDate.year == today.year &&
            monthDate.month == today.month &&
            _octoberItems.containsKey(today.day)) {
          _selectedDay = today.day;
        } else {
          _selectedDay = _octoberItems.keys.first;
        }
      }
    } else {
      if (monthDate.year == today.year && monthDate.month == today.month) {
        _selectedDay = today.day;
      } else {
        _selectedDay = 1;
      }
    }
  }

  void selectDay(int day) {
    _selectedDay = day;
    notifyListeners();
  }

  Future<void> prevMonth() async {
    _viewMonth = DateTime(_viewMonth.year, _viewMonth.month - 1, 1);
    _selectedDay = 1;
    notifyListeners();
    await _syncMonthSafely();
  }

  Future<void> nextMonth() async {
    _viewMonth = DateTime(_viewMonth.year, _viewMonth.month + 1, 1);
    _selectedDay = 1;
    notifyListeners();
    await _syncMonthSafely();
  }

  Future<void> _syncMonthSafely() async {
    try {
      await _fetchMonthOccurrences(_viewMonth);
      notifyListeners();
    } on ServerOfflineException catch (e) {
      _isServerOffline = true;
      _serverOfflineReason = e.message;
      notifyListeners();
    } on ApiRequestException catch (e) {
      _apiErrorBanner = e.detail;
      notifyListeners();
      showToast(e.detail, isError: true);
    }
  }

  /// Отметка оплаты и отправка PATCH /api/v1/payment-occurrences/{id} на сервер
  Future<void> savePayment(String id, DateTime paidDate) async {
    final item = findById(id);
    if (item == null) return;

    final wasPaid = item.isPaid;

    if (item.occurrenceId != null) {
      try {
        await RitmApiService.patchJson(
          '/api/v1/payment-occurrences/${item.occurrenceId}',
          body: {
            'is_paid': true,
            'actual_payment_date': RitmFormatters.isoDate(paidDate),
          },
        );
      } on ServerOfflineException catch (e) {
        _isServerOffline = true;
        _serverOfflineReason = e.message;
        notifyListeners();
        return;
      } on ApiRequestException catch (e) {
        _apiErrorBanner = e.detail;
        notifyListeners();
        showToast('Ошибка сервера: ${e.detail}', isError: true);
        return;
      }
    } else {
      try {
        await RitmApiService.checkHealth();
      } on ServerOfflineException catch (e) {
        _isServerOffline = true;
        _serverOfflineReason = e.message;
        notifyListeners();
        return;
      }
    }

    final updated = item.copyWith(
      status: PaymentStatus.paid,
      paidDate: paidDate,
    );

    final entryKey = _octoberItems.entries
        .firstWhere(
          (e) => e.value.id == item.id,
      orElse: () => MapEntry(item.day, item),
    )
        .key;
    _octoberItems[entryKey] = updated;

    final entry = HistoryEntry(
      paymentId: id,
      name: updated.name,
      subtitle: 'Оплачено · ${RitmFormatters.shortDate(paidDate)}',
      formattedAmount: RitmFormatters.formatMoney(
        updated.amount,
        updated.currency,
      ),
    );

    final existingIndex = _history.indexWhere((e) => e.paymentId == id);
    if (existingIndex >= 0) {
      _history[existingIndex] = entry;
    } else {
      _history.insert(0, entry);
    }

    notifyListeners();
    showToast(
      wasPaid ? 'Фактическая дата обновлена' : 'Оплата сохранена в истории',
    );
  }

  /// Снятие отметки об оплате и отправка PATCH /api/v1/payment-occurrences/{id}
  Future<void> undoPayment(String id) async {
    final item = findById(id);
    if (item == null || !item.isPaid) return;

    if (item.occurrenceId != null) {
      try {
        await RitmApiService.patchJson(
          '/api/v1/payment-occurrences/${item.occurrenceId}',
          body: {
            'is_paid': false,
          },
        );
      } on ServerOfflineException catch (e) {
        _isServerOffline = true;
        _serverOfflineReason = e.message;
        notifyListeners();
        return;
      } on ApiRequestException catch (e) {
        _apiErrorBanner = e.detail;
        notifyListeners();
        showToast('Ошибка сервера: ${e.detail}', isError: true);
        return;
      }
    } else {
      try {
        await RitmApiService.checkHealth();
      } on ServerOfflineException catch (e) {
        _isServerOffline = true;
        _serverOfflineReason = e.message;
        notifyListeners();
        return;
      }
    }

    final restoredStatus = item.dueDate.isBefore(today)
        ? PaymentStatus.overdue
        : PaymentStatus.upcoming;

    final entryKey = _octoberItems.entries
        .firstWhere(
          (e) => e.value.id == item.id,
      orElse: () => MapEntry(item.day, item),
    )
        .key;

    _octoberItems[entryKey] = item.copyWith(
      status: restoredStatus,
      clearPaidDate: true,
    );

    _history.removeWhere((e) => e.paymentId == id);
    notifyListeners();
    showToast('Отметка об оплате снята');
  }

  /// Ручной запуск проверки и отправки напоминаний в Telegram: POST /api/v1/reminders/run
  Future<void> triggerTelegramNotification() async {
    try {
      final result = await RitmApiService.postJson('/api/v1/reminders/run');
      final sent = result['sent'] as int? ?? 0;
      final telegramEnabled = result['telegram_enabled'] as bool? ?? false;

      if (!telegramEnabled) {
        showToast(
            'Проверка выполнена (Telegram-бот пока не настроен на сервере)');
      } else {
        showToast('Напоминание в Telegram отправлено (отправлено: $sent)');
      }
    } on ServerOfflineException catch (e) {
      _isServerOffline = true;
      _serverOfflineReason = e.message;
      notifyListeners();
    } on ApiRequestException catch (e) {
      _apiErrorBanner = e.detail;
      notifyListeners();
      showToast(e.detail, isError: true);
    }
  }

  void showToast(String message, {bool isError = false}) {
    _toastMessage = message;
    _isToastError = isError;
    notifyListeners();
    _toastTimer?.cancel();
    _toastTimer = Timer(Duration(milliseconds: isError ? 3600 : 2400), () {
      _toastMessage = null;
      _isToastError = false;
      notifyListeners();
    });
  }

  @override
  void dispose() {
    _toastTimer?.cancel();
    super.dispose();
  }
}

// ============================================================================
// РАЗДЕЛ 4: КОРНЕВОЙ ВИДЖЕТ И АДАПТИВНАЯ ОБОЛОЧКА УСТРОЙСТВА
// ============================================================================

class RitmApp extends StatelessWidget {
  const RitmApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Ритм — платежи команды',
      debugShowCheckedModeBanner: false,
      scrollBehavior: const _RitmScrollBehavior(),
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: RitmColors.page,
        fontFamily: '.SF Pro Display',
        fontFamilyFallback: const [
          'Inter',
          '-apple-system',
          'BlinkMacSystemFont',
          'Segoe UI',
          'Roboto',
          'sans-serif',
        ],
        colorScheme: ColorScheme.fromSeed(
          seedColor: RitmColors.accent,
          surface: RitmColors.surface,
        ),
      ),
      // Если в памяти уже есть сохранённый вход — сразу открываем главный экран
      home: RitmSession.isLoggedIn
          ? const RitmDeviceShell()
          : const RegistrationScreen(),
    );
  }
}

class RitmDeviceShell extends StatefulWidget {
  const RitmDeviceShell({super.key});

  @override
  State<RitmDeviceShell> createState() => _RitmDeviceShellState();
}

class _RitmDeviceShellState extends State<RitmDeviceShell> {
  late final RitmController _controller;

  @override
  void initState() {
    super.initState();
    _controller = RitmController();
    _controller.loadFromServer();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        final p = _controller.palette;

        return LayoutBuilder(
          builder: (context, constraints) {
            final isMobileViewport = constraints.maxWidth <= 500;
            final isCompactHeight =
                constraints.maxHeight <= 700 && !isMobileViewport;

            if (isMobileViewport) {
              return Scaffold(
                backgroundColor: p.page,
                body: SafeArea(
                  child: RitmHomeScreen(controller: _controller),
                ),
              );
            }

            final verticalPadding = isCompactHeight ? 8.0 : 18.0;
            final maxDeviceHeight = math.min(
              884.0,
              constraints.maxHeight - (verticalPadding * 2),
            );

            return Scaffold(
              backgroundColor:
              p.isDark ? const Color(0xFF080808) : const Color(0xFFE9EEE7),
              body: Stack(
                children: [
                  Positioned.fill(
                    child: CustomPaint(
                      painter: _PageAmbientBackgroundPainter(isDark: p.isDark),
                    ),
                  ),
                  Center(
                    child: Padding(
                      padding: EdgeInsets.all(verticalPadding),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 250),
                        width: 412,
                        height: math.max(620.0, maxDeviceHeight),
                        decoration: BoxDecoration(
                          color: p.page,
                          borderRadius: BorderRadius.circular(34),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.88),
                            width: 1,
                          ),
                          boxShadow: p.isDark
                              ? const [
                            BoxShadow(
                              color: Color(0x6B000000),
                              blurRadius: 72,
                              offset: Offset(0, 24),
                            ),
                            BoxShadow(
                              color: Color(0x2E000000),
                              blurRadius: 12,
                              offset: Offset(0, 3),
                            ),
                          ]
                              : const [
                            BoxShadow(
                              color: Color(0x211C3025),
                              blurRadius: 72,
                              offset: Offset(0, 24),
                            ),
                            BoxShadow(
                              color: Color(0x0B1C3025),
                              blurRadius: 12,
                              offset: Offset(0, 3),
                            ),
                          ],
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: RitmHomeScreen(
                          controller: _controller,
                          isCompactHeight: isCompactHeight,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

// ============================================================================
// РАЗДЕЛ 5: ГЛАВНЫЙ ЭКРАН ПРИЛОЖЕНИЯ, ЭКРАН СБОЯ СЕРВЕРА И ВКЛАДКИ
// ============================================================================

class RitmHomeScreen extends StatefulWidget {
  final RitmController controller;
  final bool isCompactHeight;

  const RitmHomeScreen({
    super.key,
    required this.controller,
    this.isCompactHeight = false,
  });

  @override
  State<RitmHomeScreen> createState() => _RitmHomeScreenState();
}

class _RitmHomeScreenState extends State<RitmHomeScreen> {
  late final PageController _pageController;
  int _activeTabIndex = 0;

  @override
  void initState() {
    super.initState();
    _pageController = PageController(initialPage: _activeTabIndex);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _onTabTapped(int index) {
    if (_activeTabIndex == index) return;
    setState(() {
      _activeTabIndex = index;
    });
    if (_pageController.hasClients) {
      _pageController.animateToPage(
        index,
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
      );
    }
  }

  Future<void> _openPaymentDialog(PaymentItem item) async {
    await showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Закрыть',
      barrierColor: const Color(0x6111241C),
      transitionDuration: const Duration(milliseconds: 220),
      pageBuilder: (context, anim1, anim2) {
        return _PaymentDialogModal(
          controller: widget.controller,
          item: item,
          onSave: (selectedDate) {
            widget.controller.savePayment(item.id, selectedDate);
          },
          onUndo: () {
            widget.controller.undoPayment(item.id);
          },
        );
      },
      transitionBuilder: (context, anim, secondaryAnim, child) {
        final curved = CurvedAnimation(
          parent: anim,
          curve: Curves.easeOutCubic,
        );
        return BackdropFilter(
          filter: ImageFilter.blur(
            sigmaX: 3 * curved.value,
            sigmaY: 3 * curved.value,
          ),
          child: FadeTransition(
            opacity: curved,
            child: ScaleTransition(
              scale: Tween<double>(begin: 0.95, end: 1.0).animate(curved),
              child: child,
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final sectionTopGap = widget.isCompactHeight ? 18.0 : 22.0;

    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final p = widget.controller.palette;

        // --- ЕСЛИ СЕРВЕР ПОЛНОСТЬЮ ЛЕЖИТ: ПОКАЗЫВАЕМ ЭКРАН ОШИБКИ С КНОПКОЙ «ПОВТОРИТЬ» ---
        if (widget.controller.isServerOffline) {
          return ColoredBox(
            color: p.page,
            child: Column(
              children: [
                _TopBar(
                  palette: p,
                  firstLetter: widget.controller.userInitials,
                ),
                Expanded(
                  child: _ServerOfflineScreen(
                    palette: p,
                    reason: widget.controller.serverOfflineReason ??
                        'Сервер временно не отвечает на запросы.',
                    isRetrying: widget.controller.isInitialLoading,
                    onRetry: () => widget.controller
                        .loadFromServer(showSuccessToast: true),
                  ),
                ),
              ],
            ),
          );
        }

        return ColoredBox(
          color: p.page,
          child: Stack(
            children: [
              Column(
                children: [
                  // --- БЛОК 1: ОБЛАСТЬ ЭКРАНОВ С ГОРИЗОНТАЛЬНЫМ СДВИГОМ ---
                  Expanded(
                    child: PageView(
                      controller: _pageController,
                      physics: const BouncingScrollPhysics(),
                      onPageChanged: (index) {
                        if (_activeTabIndex != index) {
                          setState(() => _activeTabIndex = index);
                        }
                      },
                      children: [
                        // Индекс 0: Экран «Главная» с поддержкой Pull-to-Refresh
                        ColoredBox(
                          color: p.page,
                          child: Column(
                            children: [
                              _TopBar(
                                palette: p,
                                firstLetter: widget.controller.userFirstLetter,
                              ),

                              if (widget.controller.isInitialLoading)
                                LinearProgressIndicator(
                                  minHeight: 2.5,
                                  color: p.accent,
                                  backgroundColor: p.line,
                                ),

                              if (widget.controller.apiErrorBanner != null)
                                _ApiErrorBanner(
                                  palette: p,
                                  message: widget.controller.apiErrorBanner!,
                                  onDismiss:
                                  widget.controller.dismissApiErrorBanner,
                                  onRetry: () => widget.controller
                                      .loadFromServer(showSuccessToast: true),
                                ),

                              Expanded(
                                child: RefreshIndicator(
                                  color: p.accent,
                                  backgroundColor: p.surface,
                                  displacement: 28,
                                  strokeWidth: 2.6,
                                  onRefresh: () =>
                                      widget.controller.loadFromServer(
                                        showSuccessToast: true,
                                        isPullToRefresh: true,
                                      ),
                                  child: SingleChildScrollView(
                                    physics: const BouncingScrollPhysics(
                                      parent: AlwaysScrollableScrollPhysics(),
                                    ),
                                    padding: const EdgeInsets.fromLTRB(
                                        18, 8, 18, 24),
                                    child: Column(
                                      crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                      children: [
                                        _HelloSection(
                                          palette: p,
                                          userName: widget
                                              .controller.userDisplayName,
                                          todayDate: RitmController.today,
                                        ),
                                        _MonthSummaryCard(
                                          controller: widget.controller,
                                          isCompact: widget.isCompactHeight,
                                        ),
                                        SizedBox(height: sectionTopGap),
                                        _CalendarSection(
                                          controller: widget.controller,
                                          onMarkPayment: _openPaymentDialog,
                                        ),
                                        SizedBox(height: sectionTopGap),
                                        _NeedsCheckSection(
                                          controller: widget.controller,
                                          onMarkPayment: _openPaymentDialog,
                                        ),
                                        SizedBox(height: sectionTopGap),
                                        _HistorySection(
                                          controller: widget.controller,
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),

                        // Индекс 1: Экран «Платежи»
                        PaymentsScreen(
                          controller: widget.controller,
                          onBackToHome: () => _onTabTapped(0),
                          onOpenPaymentDialog: _openPaymentDialog,
                        ),

                        // Индекс 2: Экран «История»
                        HistoryScreen(
                          controller: widget.controller,
                          onBackToHome: () => _onTabTapped(0),
                          onOpenPaymentDialog: _openPaymentDialog,
                        ),

                        // Индекс 3: Экран «Профиль»
                        ProfileScreen(
                          controller: widget.controller,
                          onBackToHome: () => _onTabTapped(0),
                        ),
                      ],
                    ),
                  ),

                  // --- БЛОК 2: НИЖНЯЯ ПАНЕЛЬ НАВИГАЦИИ (.bottom-nav) ---
                  _BottomNavBar(
                    palette: p,
                    activeIndex: _activeTabIndex,
                    onTap: _onTabTapped,
                  ),
                ],
              ),

              // --- БЛОК 3: ВСПЛЫВАЮЩЕЕ УВЕДОМЛЕНИЕ ПОВЕРХ ЭКРАНА (.toast) ---
              Positioned(
                left: 16,
                right: 16,
                bottom: 78,
                child: IgnorePointer(
                  child: Center(
                    child: AnimatedSlide(
                      duration: const Duration(milliseconds: 240),
                      curve: Curves.easeOutCubic,
                      offset: widget.controller.toastMessage != null
                          ? Offset.zero
                          : const Offset(0, 0.35),
                      child: AnimatedOpacity(
                        duration: const Duration(milliseconds: 240),
                        opacity:
                        widget.controller.toastMessage != null ? 1.0 : 0.0,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 12,
                          ),
                          decoration: BoxDecoration(
                            color: widget.controller.isToastError
                                ? const Color(0xFFB84339)
                                : (p.isDark
                                ? const Color(0xFF26170E)
                                : p.toastBg),
                            borderRadius: BorderRadius.circular(13),
                            border: p.isDark && !widget.controller.isToastError
                                ? Border.all(
                              color: p.accent.withValues(alpha: 0.35),
                            )
                                : null,
                            boxShadow: const [
                              BoxShadow(
                                color: Color(0x38000000),
                                blurRadius: 22,
                                offset: Offset(0, 8),
                              ),
                            ],
                          ),
                          child: Text(
                            widget.controller.toastMessage ?? '',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: widget.controller.isToastError
                                  ? Colors.white
                                  : (p.isDark ? p.ink : p.onAccent),
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              height: 1.25,
                            ),
                          ),
                        ),
                      ),
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
// РАЗДЕЛ 5.1: ЭКРАН ПАДЕНИЯ СЕРВЕРА («СЕРВЕР НЕДОСТУПЕН») И БАННЕР ОШИБОК API
// ============================================================================

class _ServerOfflineScreen extends StatelessWidget {
  final RitmPalette palette;
  final String reason;
  final bool isRetrying;
  final VoidCallback onRetry;

  const _ServerOfflineScreen({
    required this.palette,
    required this.reason,
    required this.isRetrying,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final p = palette;

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(22),
        physics: const BouncingScrollPhysics(),
        child: Container(
          padding: const EdgeInsets.fromLTRB(22, 26, 22, 22),
          decoration: BoxDecoration(
            color: p.surface,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: p.warningLine),
            boxShadow: [
              BoxShadow(
                color: p.cardShadow,
                blurRadius: 28,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 68,
                height: 68,
                decoration: BoxDecoration(
                  color: p.warningSoft,
                  shape: BoxShape.circle,
                  border: Border.all(color: p.warningLine),
                ),
                alignment: Alignment.center,
                child: SizedBox(
                  width: 32,
                  height: 32,
                  child: CustomPaint(
                    painter: _ServerOfflineIconPainter(color: p.warning),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Container(
                padding:
                const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: p.warningSoft,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  'НЕТ СВЯЗИ С СЕРВЕРОМ',
                  style: TextStyle(
                    color: p.warning,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.8,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'Сервер временно недоступен',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: p.ink,
                  fontSize: 22,
                  height: 1.15,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.5,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                reason,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: p.muted,
                  fontSize: 14,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: _HoverBackgroundButton(
                  normalColor: p.accent,
                  hoverColor: p.accentStrong,
                  borderRadius: BorderRadius.circular(13),
                  minHeight: 48,
                  onTap: isRetrying ? () {} : onRetry,
                  child: isRetrying
                      ? SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.4,
                      color: p.onAccent,
                    ),
                  )
                      : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.refresh_rounded,
                        color: p.onAccent,
                        size: 19,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'Повторить',
                        style: TextStyle(
                          color: p.onAccent,
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
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

class _ApiErrorBanner extends StatelessWidget {
  final RitmPalette palette;
  final String message;
  final VoidCallback onDismiss;
  final VoidCallback onRetry;

  const _ApiErrorBanner({
    required this.palette,
    required this.message,
    required this.onDismiss,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(18, 10, 18, 4),
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
      decoration: BoxDecoration(
        color: palette.warningSoft,
        borderRadius: BorderRadius.circular(13),
        border: Border.all(color: palette.warningLine),
      ),
      child: Row(
        children: [
          Icon(
            Icons.error_outline_rounded,
            color: palette.warning,
            size: 19,
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                color: palette.warning,
                fontSize: 12.5,
                height: 1.35,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: 6),
          GestureDetector(
            onTap: onRetry,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              child: Text(
                'Повторить',
                style: TextStyle(
                  color: palette.ink,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
          const SizedBox(width: 4),
          GestureDetector(
            onTap: onDismiss,
            child: Icon(
              Icons.close_rounded,
              color: palette.warning,
              size: 17,
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// РАЗДЕЛ 6: КОМПОНЕНТЫ И БЛОКИ ИНТЕРФЕЙСА ГЛАВНОЙ СТРАНИЦЫ
// ============================================================================

/// Верхняя шапка главной страницы (без значка уведомлений, с обновлённым аватаром из 1 буквы)
class _TopBar extends StatelessWidget {
  final RitmPalette palette;
  final String firstLetter;

  const _TopBar({
    required this.palette,
    required this.firstLetter,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = palette.isDark;

    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: CustomPaint(
          painter: isDark ? const _DarkOrangeTopBarPainter() : null,
          child: Container(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 12),
            decoration: BoxDecoration(
              color: isDark
                  ? Colors.transparent
                  : palette.page.withValues(alpha: 0.94),
              border: isDark
                  ? Border(
                bottom: BorderSide(
                  color: palette.accent.withValues(alpha: 0.18),
                ),
              )
                  : null,
            ),
            child: Row(
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 220),
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: palette.accentStrong,
                    borderRadius: BorderRadius.circular(13),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.white.withValues(alpha: 0.18),
                        offset: const Offset(0, 1),
                        blurRadius: 0,
                        blurStyle: BlurStyle.inner,
                      ),
                    ],
                  ),
                  child: Center(
                    child: SizedBox(
                      width: 24,
                      height: 24,
                      child: CustomPaint(
                        painter: _BrandWavePainter(
                          color: isDark ? palette.onAccent : palette.lime,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 11),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'ритм',
                      style: TextStyle(
                        color: palette.ink,
                        fontSize: 21,
                        height: 1.0,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.7,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'платежи команды',
                      style: TextStyle(
                        color: palette.muted,
                        fontSize: 12,
                        height: 1.0,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
                const Spacer(),

                // --- БЛОК: Обновлённый аватар с первой буквой имени из БД ---
                _AvatarBadge(
                  size: 40,
                  palette: palette,
                  letter: firstLetter,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Круглый значок пользователя в фирменном стиле с одной заглавной буквой имени
class _AvatarBadge extends StatelessWidget {
  final double size;
  final RitmPalette palette;
  final String letter;

  const _AvatarBadge({
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
          fontSize: letter.length > 1 ? 14 : 16,
          fontWeight: FontWeight.w800,
          height: 1.0,
          letterSpacing: letter.length > 1 ? 0.2 : -0.3,
        ),
      ),
    );
  }
}

/// Блок приветствия с актуальной сегодняшней датой и именем пользователя из БД
class _HelloSection extends StatelessWidget {
  final RitmPalette palette;
  final String userName;
  final DateTime todayDate;

  const _HelloSection({
    required this.palette,
    required this.userName,
    required this.todayDate,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = palette.isDark;

    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 8, 2, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                  color: isDark ? palette.accent : const Color(0xFF91BB59),
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: isDark
                          ? palette.accent.withValues(alpha: 0.18)
                          : const Color(0xFFE4EED9),
                      spreadRadius: 3.5,
                      blurRadius: 0,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(
                RitmFormatters.weekdayDayMonthUpper(todayDate),
                style: TextStyle(
                  color: palette.muted,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.9,
                ),
              ),
            ],
          ),
          const SizedBox(height: 11),
          Text(
            'Привет, $userName',
            style: TextStyle(
              color: palette.ink,
              fontSize: 30,
              height: 1.06,
              letterSpacing: -1.0,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            'Все платежи команды — в одном месте.',
            style: TextStyle(
              color: palette.muted,
              fontSize: 14.5,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }
}

class _MonthSummaryCard extends StatelessWidget {
  final RitmController controller;
  final bool isCompact;

  const _MonthSummaryCard({
    required this.controller,
    this.isCompact = false,
  });

  @override
  Widget build(BuildContext context) {
    final p = controller.palette;
    final paid = controller.paidCount;
    final total = controller.totalCount;
    final pending = controller.pendingCount;
    final fraction = controller.progressFraction;

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(23),
        gradient: LinearGradient(
          begin: const Alignment(-0.85, -0.85),
          end: const Alignment(0.85, 0.85),
          stops: const [0.0, 0.57, 1.0],
          colors: [
            p.hero,
            p.heroDeep,
            p.heroEnd,
          ],
        ),
        boxShadow: const [
          BoxShadow(
            color: Color(0x2B144030),
            blurRadius: 24,
            offset: Offset(0, 10),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: CustomPaint(
        painter: _HeroDecorationPainter(),
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            16,
            isCompact ? 14 : 17,
            16,
            isCompact ? 13 : 17,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    RitmFormatters.monthYearUpper(controller.viewMonth),
                    style: TextStyle(
                      color: p.heroMuted,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.1,
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: p.heroGlass,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: p.heroStroke),
                    ),
                    child: Text(
                      'Обзор месяца',
                      style: TextStyle(
                        color: p.heroInk,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        height: 1.0,
                      ),
                    ),
                  ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(1, 15, 1, 14),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Уже оплачено',
                          style: TextStyle(
                            color: p.heroMuted,
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(height: 5),
                        AnimatedSwitcher(
                          duration: const Duration(milliseconds: 220),
                          child: Text(
                            '$paid из $total',
                            key: ValueKey('$paid/$total'),
                            style: TextStyle(
                              color: p.heroInk,
                              fontSize: 34,
                              height: 1.0,
                              fontWeight: FontWeight.w700,
                              letterSpacing: -1.3,
                            ),
                          ),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          'платежей за месяц',
                          style: TextStyle(
                            color: p.heroMuted,
                            fontSize: 12.5,
                          ),
                        ),
                      ],
                    ),
                    TweenAnimationBuilder<double>(
                      tween: Tween<double>(begin: 0.0, end: fraction),
                      duration: const Duration(milliseconds: 450),
                      curve: Curves.easeOutCubic,
                      builder: (context, animatedFraction, _) {
                        final dynamicPercent = (animatedFraction * 100).round();
                        return SizedBox(
                          width: 76,
                          height: 76,
                          child: CustomPaint(
                            painter: _ConicRingPainter(
                              progress: animatedFraction,
                              activeColor: p.lime,
                              trackColor: p.heroTrack,
                            ),
                            child: Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    '$dynamicPercent%',
                                    style: TextStyle(
                                      color: p.heroInk,
                                      fontSize: 16.5,
                                      height: 1.05,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    'готово',
                                    style: TextStyle(
                                      color: p.heroMuted,
                                      fontSize: 10.5,
                                      height: 1.0,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ),
              Row(
                children: [
                  Expanded(
                    child: _CurrencyTile(
                      palette: p,
                      label: 'RUB · осталось',
                      value: controller.formattedRemainingCurrency(
                        CurrencyCode.rub,
                      ),
                    ),
                  ),
                  const SizedBox(width: 7),
                  Expanded(
                    child: _CurrencyTile(
                      palette: p,
                      label: 'USD · осталось',
                      value: controller.formattedRemainingCurrency(
                        CurrencyCode.usd,
                      ),
                    ),
                  ),
                  const SizedBox(width: 7),
                  Expanded(
                    child: _CurrencyTile(
                      palette: p,
                      label: 'EUR · осталось',
                      value: controller.formattedRemainingCurrency(
                        CurrencyCode.eur,
                      ),
                    ),
                  ),
                ],
              ),
              TweenAnimationBuilder<double>(
                tween: Tween<double>(begin: 0.0, end: fraction),
                duration: const Duration(milliseconds: 450),
                curve: Curves.easeOutCubic,
                builder: (context, animatedFraction, _) {
                  final dynamicPercent = (animatedFraction * 100).round();
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(1, 13, 1, 8),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            RichText(
                              text: TextSpan(
                                style: TextStyle(
                                  color: p.heroMuted,
                                  fontSize: 12.5,
                                ),
                                children: [
                                  TextSpan(
                                    text: total == 0
                                        ? 'Нет платежей'
                                        : (pending == 0
                                        ? 'Все платежи'
                                        : '$pending ${RitmFormatters.pluralPayments(pending)}'),
                                    style: TextStyle(
                                      color: p.heroInk,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  TextSpan(
                                    text: total == 0
                                        ? ' в этом месяце'
                                        : (pending == 0
                                        ? ' закрыты!'
                                        : ' ещё впереди'),
                                  ),
                                ],
                              ),
                            ),
                            Text(
                              '$dynamicPercent%',
                              style: TextStyle(
                                color: p.heroInk,
                                fontSize: 12.5,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Container(
                        height: 6,
                        decoration: BoxDecoration(
                          color: p.heroTrack,
                          borderRadius: BorderRadius.circular(99),
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: FractionallySizedBox(
                          alignment: Alignment.centerLeft,
                          widthFactor: animatedFraction,
                          child: Container(
                            decoration: BoxDecoration(
                              color: p.lime,
                              borderRadius: BorderRadius.circular(99),
                            ),
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CurrencyTile extends StatelessWidget {
  final RitmPalette palette;
  final String label;
  final String value;

  const _CurrencyTile({
    required this.palette,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 10, 10, 9),
      decoration: BoxDecoration(
        color: palette.heroGlass,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: palette.heroStroke),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: palette.heroMuted,
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.3,
            ),
          ),
          const SizedBox(height: 6),
          SizedBox(
            height: 19,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                value,
                key: ValueKey(value),
                style: TextStyle(
                  color: palette.heroInk,
                  fontSize: 14.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.2,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _OverdueCountPill extends StatelessWidget {
  final RitmPalette palette;
  final int overdueCount;
  final bool useOrangeDarkStyle;

  const _OverdueCountPill({
    required this.palette,
    required this.overdueCount,
    this.useOrangeDarkStyle = false,
  });

  @override
  Widget build(BuildContext context) {
    final isCleared = overdueCount == 0;
    final label = isCleared
        ? 'Просрочка закрыта'
        : '$overdueCount просрочен${overdueCount == 1 ? '' : 'о'}';

    final useSpecialOrange =
        palette.isDark && useOrangeDarkStyle && !isCleared;

    final Color bgColor = isCleared
        ? palette.successSoft
        : useSpecialOrange
        ? const Color(0x1AFF7014)
        : palette.warningSoft;

    final Color fgColor = isCleared
        ? palette.success
        : useSpecialOrange
        ? const Color(0xFFFFB886)
        : palette.warning;

    final Color dotColor = isCleared
        ? palette.successDot
        : useSpecialOrange
        ? palette.accent
        : palette.warningDot;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      constraints: const BoxConstraints(minHeight: 26),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(9),
        border: useSpecialOrange
            ? Border.all(color: const Color(0x33FF7014))
            : null,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: dotColor,
              boxShadow: useSpecialOrange
                  ? const [
                BoxShadow(
                  color: Color(0x24FF7014),
                  spreadRadius: 3,
                ),
              ]
                  : null,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              color: fgColor,
              fontSize: 11.5,
              fontWeight: FontWeight.w700,
              height: 1.0,
            ),
          ),
        ],
      ),
    );
  }
}

class _CalendarSection extends StatelessWidget {
  final RitmController controller;
  final ValueChanged<PaymentItem> onMarkPayment;

  const _CalendarSection({
    required this.controller,
    required this.onMarkPayment,
  });

  @override
  Widget build(BuildContext context) {
    final p = controller.palette;
    final viewMonth = controller.viewMonth;
    final year = viewMonth.year;
    final month = viewMonth.month;
    final firstWeekdayOffset = (DateTime(year, month, 1).weekday + 6) % 7;
    final daysInMonth = DateTime(year, month + 1, 0).day;
    final totalSlots = ((firstWeekdayOffset + daysInMonth) / 7).ceil() * 7;
    final monthItems = controller.currentMonthItems;
    final selectedItem = controller.selectedDayItem;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(1, 0, 1, 10),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'План платежей',
                style: TextStyle(
                  color: p.ink,
                  fontSize: 18,
                  height: 1.2,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.35,
                ),
              ),
              _OverdueCountPill(
                palette: p,
                overdueCount: controller.overdueCount,
              ),
            ],
          ),
        ),
        AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: p.surface,
            borderRadius: BorderRadius.circular(19),
            border: Border.all(color: p.line),
            boxShadow: [
              BoxShadow(
                color: p.cardShadow,
                blurRadius: 22,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    RitmFormatters.monthYearTitle(viewMonth),
                    style: TextStyle(
                      color: p.ink,
                      fontSize: 15.5,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.2,
                    ),
                  ),
                  Row(
                    children: [
                      _MonthArrowButton(
                        palette: p,
                        isLeft: true,
                        onTap: controller.prevMonth,
                      ),
                      const SizedBox(width: 6),
                      _MonthArrowButton(
                        palette: p,
                        isLeft: false,
                        onTap: controller.nextMonth,
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 11),
              Wrap(
                spacing: 14,
                runSpacing: 6,
                children: [
                  _LegendItem(
                    color: p.success,
                    label: 'Оплачено',
                    textColor: p.muted,
                  ),
                  _LegendItem(
                    color: p.accent,
                    label: 'Скоро',
                    textColor: p.muted,
                  ),
                  _LegendItem(
                    color: p.warning,
                    label: 'Просрочено',
                    textColor: p.muted,
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: ['ПН', 'ВТ', 'СР', 'ЧТ', 'ПТ', 'СБ', 'ВС']
                    .map(
                      (day) => SizedBox(
                    width: 40,
                    child: Text(
                      day,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: p.faint,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.4,
                      ),
                    ),
                  ),
                )
                    .toList(),
              ),
              const SizedBox(height: 5),
              Column(
                children: List.generate(totalSlots ~/ 7, (rowIndex) {
                  return Padding(
                    padding: EdgeInsets.only(top: rowIndex == 0 ? 0 : 3),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: List.generate(7, (colIndex) {
                        final slot = rowIndex * 7 + colIndex;
                        final day = slot - firstWeekdayOffset + 1;
                        if (day < 1 || day > daysInMonth) {
                          return const SizedBox(width: 40, height: 40);
                        }
                        final item = monthItems[day];
                        final isToday = year == RitmController.today.year &&
                            month == RitmController.today.month &&
                            day == RitmController.today.day;
                        final isSelected = day == controller.selectedDay;
                        return _CalendarDayCell(
                          palette: p,
                          day: day,
                          item: item,
                          isToday: isToday,
                          isSelected: isSelected,
                          onTap: () => controller.selectDay(day),
                        );
                      }),
                    ),
                  );
                }),
              ),
              const SizedBox(height: 12),
              _CalendarDetailBox(
                palette: p,
                selectedDate: DateTime(
                  year,
                  month,
                  controller.selectedDay.clamp(1, daysInMonth),
                ),
                item: selectedItem,
                onActionTap: selectedItem != null
                    ? () => onMarkPayment(selectedItem)
                    : null,
              ),
              const SizedBox(height: 9),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Text(
                  'Нажмите на дату, чтобы посмотреть платёж и его статус.',
                  style: TextStyle(
                    color: p.muted,
                    fontSize: 11.5,
                    height: 1.35,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _MonthArrowButton extends StatefulWidget {
  final RitmPalette palette;
  final bool isLeft;
  final VoidCallback onTap;

  const _MonthArrowButton({
    required this.palette,
    required this.isLeft,
    required this.onTap,
  });

  @override
  State<_MonthArrowButton> createState() => _MonthArrowButtonState();
}

class _MonthArrowButtonState extends State<_MonthArrowButton> {
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
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: _hovered ? p.surfaceSoft : p.surface,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: p.line),
          ),
          alignment: Alignment.center,
          child: SizedBox(
            width: 13,
            height: 13,
            child: CustomPaint(
              painter: _ChevronPainter(
                isLeft: widget.isLeft,
                color: p.inkSoft,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _LegendItem extends StatelessWidget {
  final Color color;
  final String label;
  final Color textColor;

  const _LegendItem({
    required this.color,
    required this.label,
    required this.textColor,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: TextStyle(
            color: textColor,
            fontSize: 12,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}

class _CalendarDayCell extends StatefulWidget {
  final RitmPalette palette;
  final int day;
  final PaymentItem? item;
  final bool isToday;
  final bool isSelected;
  final VoidCallback onTap;

  const _CalendarDayCell({
    required this.palette,
    required this.day,
    required this.item,
    required this.isToday,
    required this.isSelected,
    required this.onTap,
  });

  @override
  State<_CalendarDayCell> createState() => _CalendarDayCellState();
}

class _CalendarDayCellState extends State<_CalendarDayCell> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final status = widget.item?.status;
    final isOverdue = status == PaymentStatus.overdue;
    final isPaid = status == PaymentStatus.paid;

    Color textColor = p.inkSoft;
    if (isOverdue) {
      textColor = p.warning;
    } else if (isPaid) {
      textColor = p.success;
    } else if (widget.isSelected) {
      textColor = p.accent;
    }

    Color bgColor = Colors.transparent;
    if (widget.isSelected) {
      bgColor = isOverdue ? p.warningSoft : p.accentSoft;
    } else if (_hovered) {
      bgColor = p.surfaceSoft;
    }

    Color borderColor = Colors.transparent;
    if (widget.isSelected) {
      borderColor =
      isOverdue ? p.warningLine : p.accent.withValues(alpha: 0.35);
    } else if (widget.isToday) {
      borderColor = p.lineStrong;
    }

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(11),
            border: Border.all(color: borderColor, width: 1.2),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                '${widget.day}',
                style: TextStyle(
                  color: textColor,
                  fontSize: 13,
                  height: 1.0,
                  fontWeight:
                  widget.isSelected ? FontWeight.w700 : FontWeight.w600,
                ),
              ),
              if (widget.item != null) ...[
                const SizedBox(height: 3),
                Container(
                  width: 4.5,
                  height: 4.5,
                  decoration: BoxDecoration(
                    color: textColor,
                    shape: BoxShape.circle,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _CalendarDetailBox extends StatelessWidget {
  final RitmPalette palette;
  final DateTime selectedDate;
  final PaymentItem? item;
  final VoidCallback? onActionTap;

  const _CalendarDetailBox({
    required this.palette,
    required this.selectedDate,
    required this.item,
    required this.onActionTap,
  });

  @override
  Widget build(BuildContext context) {
    final p = palette;
    final hasItem = item != null;
    final statusText = !hasItem
        ? 'Свободный день'
        : switch (item!.status) {
      PaymentStatus.paid => 'Оплачено',
      PaymentStatus.overdue => 'Просрочено',
      PaymentStatus.upcoming => 'Скоро',
    };

    final (Color badgeBg, Color badgeFg) = !hasItem
        ? (p.accentSoft, p.accentInk)
        : switch (item!.status) {
      PaymentStatus.paid => (p.successSoft, p.success),
      PaymentStatus.overdue => (p.warningSoft, p.warning),
      PaymentStatus.upcoming => (p.accentSoft, p.accentInk),
    };

    return AnimatedSize(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.all(13),
        decoration: BoxDecoration(
          color: p.page,
          borderRadius: BorderRadius.circular(15),
          border: Border.all(color: p.line),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  RitmFormatters.dayMonthLong(selectedDate),
                  style: TextStyle(
                    color: p.muted,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 9,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: badgeBg,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    statusText,
                    style: TextStyle(
                      color: badgeFg,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                      height: 1.0,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: p.surface,
                    borderRadius: BorderRadius.circular(11),
                  ),
                  alignment: Alignment.center,
                  child: SizedBox(
                    width: 19,
                    height: 19,
                    child: CustomPaint(
                      painter: _ServerIconPainter(color: p.accent),
                    ),
                  ),
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        hasItem ? item!.name : 'На этот день платежей нет',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: p.ink,
                          fontSize: 14.5,
                          fontWeight: FontWeight.w700,
                          height: 1.2,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        hasItem
                            ? item!.calendarNote
                            : 'Выберите дату с точкой, чтобы открыть платёж.',
                        style: TextStyle(
                          color: p.muted,
                          fontSize: 12.5,
                          height: 1.3,
                        ),
                      ),
                    ],
                  ),
                ),
                if (hasItem) ...[
                  const SizedBox(width: 10),
                  Text(
                    item!.formattedAmount,
                    style: TextStyle(
                      color: p.ink,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ],
            ),
            if (onActionTap != null) ...[
              const SizedBox(height: 11),
              _HoverBackgroundButton(
                normalColor: p.accent,
                hoverColor: p.accentStrong,
                borderRadius: BorderRadius.circular(10),
                minHeight: 36,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                onTap: onActionTap!,
                child: Text(
                  item!.isPaid ? 'Изменить дату' : 'Отметить оплату',
                  style: TextStyle(
                    color: p.onAccent,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Секция «Нужно проверить» — полностью работает на реальных данных из БД без заглушек
class _NeedsCheckSection extends StatelessWidget {
  final RitmController controller;
  final ValueChanged<PaymentItem> onMarkPayment;

  const _NeedsCheckSection({
    required this.controller,
    required this.onMarkPayment,
  });

  @override
  Widget build(BuildContext context) {
    final p = controller.palette;
    final isDark = p.isDark;
    final targetItem = controller.priorityCheckItem;

    if (targetItem == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(1, 0, 1, 10),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Нужно проверить',
                  style: TextStyle(
                    color: p.ink,
                    fontSize: 18,
                    height: 1.2,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.35,
                  ),
                ),
                _OverdueCountPill(
                  palette: p,
                  overdueCount: 0,
                  useOrangeDarkStyle: true,
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: p.surface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: p.line),
            ),
            child: Text(
              'В этом месяце нет платежей, требующих проверки.',
              style: TextStyle(
                color: p.muted,
                fontSize: 13,
              ),
            ),
          ),
        ],
      );
    }

    final isPaid = targetItem.isPaid;
    final isOverdue = targetItem.isOverdue;
    final timing = targetItem.timingLabel;
    final isLate = targetItem.isPaidLate;
    final overdueDays = targetItem.overdueDaysCount;

    final statusLabel = isPaid
        ? 'Оплачено $timing'
        : (isOverdue
        ? 'Просрочен · ${RitmFormatters.shortDate(targetItem.dueDate)}'
        : 'К оплате · ${RitmFormatters.shortDate(targetItem.dueDate)}');

    final metaLabel = isPaid && targetItem.paidDate != null
        ? 'Фактическая дата · ${RitmFormatters.shortDate(targetItem.paidDate!)}${isLate ? ' · позже срока' : ' · $timing'}'
        : targetItem.unpaidNote;

    final footerWarningText = isOverdue && overdueDays > 0
        ? 'Просрочка · $overdueDays ${RitmFormatters.pluralDays(overdueDays)}'
        : 'Ожидает оплаты · до ${RitmFormatters.shortDate(targetItem.dueDate)}';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(1, 0, 1, 10),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Нужно проверить',
                style: TextStyle(
                  color: p.ink,
                  fontSize: 18,
                  height: 1.2,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.35,
                ),
              ),
              _OverdueCountPill(
                palette: p,
                overdueCount: controller.overdueCount,
                useOrangeDarkStyle: true,
              ),
            ],
          ),
        ),
        AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          decoration: BoxDecoration(
            color: isDark ? null : p.surface,
            gradient: isDark
                ? const LinearGradient(
              begin: Alignment(-0.85, -0.85),
              end: Alignment(0.85, 0.85),
              stops: [0.0, 0.56, 1.0],
              colors: [
                Color(0xFF1B1714),
                Color(0xFF151515),
                Color(0xFF121212),
              ],
            )
                : null,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: isPaid
                  ? p.lineStrong
                  : (isDark ? const Color(0x47FF7014) : p.warningLine),
            ),
            boxShadow: [
              BoxShadow(
                color: isDark ? const Color(0x5C000000) : p.cardShadow,
                blurRadius: isDark ? 28 : 22,
                offset: Offset(0, isDark ? 12 : 8),
              ),
            ],
          ),
          clipBehavior: Clip.antiAlias,
          child: CustomPaint(
            painter: isDark ? const _DarkRentCardGlowPainter() : null,
            child: Stack(
              children: [
                if (!isDark)
                  Positioned(
                    left: 0,
                    top: 0,
                    bottom: 0,
                    width: 3.5,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 220),
                      color: isPaid ? p.successStripe : p.warningStripe,
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(15, 14, 14, 13),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          AnimatedContainer(
                            duration: const Duration(milliseconds: 200),
                            constraints: const BoxConstraints(minHeight: 25),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 9,
                              vertical: 5,
                            ),
                            decoration: BoxDecoration(
                              color: isPaid
                                  ? p.successSoft
                                  : (isDark
                                  ? const Color(0x1FFF7014)
                                  : p.warningSoft),
                              borderRadius: BorderRadius.circular(8),
                              border: !isPaid && isDark
                                  ? Border.all(color: const Color(0x33FF7014))
                                  : null,
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Container(
                                  width: 5.5,
                                  height: 5.5,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: isPaid ? p.successDot : p.warningDot,
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  statusLabel.toUpperCase(),
                                  style: TextStyle(
                                    color: isPaid
                                        ? p.success
                                        : (isDark
                                        ? const Color(0xFFFFC18F)
                                        : p.warning),
                                    fontSize: 11,
                                    fontWeight: FontWeight.w700,
                                    letterSpacing: 0.3,
                                    height: 1.0,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Text(
                            RitmFormatters.forMonthCapitalized(
                              targetItem.dueDate,
                            ),
                            style: TextStyle(
                              color: isDark ? const Color(0xFF999999) : p.muted,
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 11),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  targetItem.name,
                                  style: TextStyle(
                                    color: p.ink,
                                    fontSize: 17,
                                    height: 1.2,
                                    fontWeight: FontWeight.w700,
                                    letterSpacing: -0.25,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  metaLabel,
                                  style: TextStyle(
                                    color: isDark
                                        ? const Color(0xFFB0AAA5)
                                        : p.muted,
                                    fontSize: 13,
                                    height: 1.35,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 10),
                          Padding(
                            padding: const EdgeInsets.only(top: 1),
                            child: Text(
                              targetItem.formattedAmount,
                              style: TextStyle(
                                color:
                                isDark ? const Color(0xFFFFE1C6) : p.ink,
                                fontSize: 17,
                                fontWeight: FontWeight.w700,
                                letterSpacing: -0.4,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.only(top: 11),
                        decoration: BoxDecoration(
                          border: Border(
                            top: BorderSide(
                              color: isDark
                                  ? Colors.white.withValues(alpha: 0.08)
                                  : p.line,
                            ),
                          ),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Flexible(
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Container(
                                    width: 20,
                                    height: 20,
                                    decoration: BoxDecoration(
                                      color: isPaid
                                          ? p.successSoft
                                          : (isDark
                                          ? const Color(0x21FF7014)
                                          : p.warningSoft),
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    alignment: Alignment.center,
                                    child: SizedBox(
                                      width: 12,
                                      height: 12,
                                      child: CustomPaint(
                                        painter: _ClockIconPainter(
                                          color: isPaid
                                              ? p.success
                                              : (isDark
                                              ? const Color(0xFFFFAD72)
                                              : p.warning),
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 7),
                                  if (!isPaid)
                                    Flexible(
                                      child: Text(
                                        footerWarningText,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          color: isDark
                                              ? const Color(0xFFFFAD72)
                                              : p.warning,
                                          fontSize: 12.5,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    )
                                  else
                                    Flexible(
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          SizedBox(
                                            width: 13,
                                            height: 13,
                                            child: CustomPaint(
                                              painter: _CheckIconPainter(
                                                color: p.success,
                                                strokeWidth: 1.6,
                                              ),
                                            ),
                                          ),
                                          const SizedBox(width: 5),
                                          Flexible(
                                            child: Text(
                                              'Оплата записана',
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                color: p.success,
                                                fontSize: 12.5,
                                                fontWeight: FontWeight.w700,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),
                            _PayCardActionButton(
                              palette: p,
                              isPaid: isPaid,
                              onTap: () => onMarkPayment(targetItem),
                            ),
                          ],
                        ),
                      ),
                    ],
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

class _PayCardActionButton extends StatefulWidget {
  final RitmPalette palette;
  final bool isPaid;
  final VoidCallback onTap;

  const _PayCardActionButton({
    required this.palette,
    required this.isPaid,
    required this.onTap,
  });

  @override
  State<_PayCardActionButton> createState() => _PayCardActionButtonState();
}

class _PayCardActionButtonState extends State<_PayCardActionButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final fgColor = widget.isPaid ? p.accentInk : p.onAccent;
    final bgColor = widget.isPaid
        ? p.accentSoft
        : (_hovered ? p.accentStrong : p.accent);

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          transform: Matrix4.translationValues(0, _hovered ? -1.0 : 0.0, 0),
          constraints: const BoxConstraints(minHeight: 38),
          padding: const EdgeInsets.symmetric(horizontal: 13),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(11),
            boxShadow: widget.isPaid
                ? null
                : [
              BoxShadow(
                color: p.isDark
                    ? const Color(0x2EFF7014)
                    : const Color(0x24174B3A),
                blurRadius: p.isDark ? 14 : 8,
                offset: Offset(0, p.isDark ? 4 : 3),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 14,
                height: 14,
                child: CustomPaint(
                  painter: _CheckIconPainter(
                    color: fgColor,
                    strokeWidth: 1.7,
                  ),
                ),
              ),
              const SizedBox(width: 7),
              Text(
                widget.isPaid ? 'Изменить дату' : 'Отметить оплату',
                style: TextStyle(
                  color: fgColor,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HistorySection extends StatelessWidget {
  final RitmController controller;

  const _HistorySection({required this.controller});

  @override
  Widget build(BuildContext context) {
    final p = controller.palette;
    final entries = controller.history;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(1, 0, 1, 10),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Последние оплаты',
                style: TextStyle(
                  color: p.ink,
                  fontSize: 18,
                  height: 1.2,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.35,
                ),
              ),
              Text(
                '${controller.paidCount} ${RitmFormatters.forMonthAccusative(controller.viewMonth)}',
                style: TextStyle(
                  color: p.muted,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOutCubic,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            decoration: BoxDecoration(
              color: p.surface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: p.line),
            ),
            clipBehavior: Clip.antiAlias,
            child: entries.isEmpty
                ? Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'В этом месяце пока нет отмеченных оплат.',
                style: TextStyle(
                  color: p.muted,
                  fontSize: 13,
                ),
              ),
            )
                : Column(
              children: List.generate(entries.length, (index) {
                final entry = entries[index];
                return Container(
                  constraints: const BoxConstraints(minHeight: 60),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 13,
                    vertical: 11,
                  ),
                  decoration: BoxDecoration(
                    border: index == 0
                        ? null
                        : Border(
                      top: BorderSide(color: p.line),
                    ),
                  ),
                  child: Row(
                    children: [
                      _UniversalPaymentBadge(palette: p),
                      const SizedBox(width: 11),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              entry.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: p.ink,
                                fontSize: 14,
                                height: 1.2,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              entry.subtitle,
                              style: TextStyle(
                                color: p.muted,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        entry.formattedAmount,
                        style: TextStyle(
                          color: p.inkSoft,
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                );
              }),
            ),
          ),
        ),
      ],
    );
  }
}

class _UniversalPaymentBadge extends StatelessWidget {
  final RitmPalette palette;

  const _UniversalPaymentBadge({required this.palette});

  @override
  Widget build(BuildContext context) {
    final isDark = palette.isDark;

    final Color bgColor =
    isDark ? const Color(0x1AFF7014) : palette.accentSoft;
    final Color borderColor =
    isDark ? const Color(0x2EFF7014) : const Color(0xFFD4E5D0);
    final Color iconColor = isDark ? palette.accentInk : palette.accent;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      width: 30,
      height: 30,
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: borderColor),
      ),
      alignment: Alignment.center,
      child: SizedBox(
        width: 15,
        height: 15,
        child: CustomPaint(
          painter: _UniversalPaymentReceiptPainter(color: iconColor),
        ),
      ),
    );
  }
}

class _BottomNavBar extends StatelessWidget {
  final RitmPalette palette;
  final int activeIndex;
  final ValueChanged<int> onTap;

  const _BottomNavBar({
    required this.palette,
    required this.activeIndex,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    const items = [
      (label: 'Главная', type: _NavIconType.home),
      (label: 'Платежи', type: _NavIconType.payments),
      (label: 'История', type: _NavIconType.history),
      (label: 'Профиль', type: _NavIconType.profile),
    ];

    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
          decoration: BoxDecoration(
            color: palette.isDark
                ? const Color(0xF7141414)
                : palette.surface.withValues(alpha: 0.96),
            border: Border(top: BorderSide(color: palette.line)),
          ),
          child: Row(
            children: List.generate(items.length, (index) {
              final item = items[index];
              final isActive = index == activeIndex;
              return Expanded(
                child: Padding(
                  padding: EdgeInsets.only(left: index == 0 ? 0 : 4),
                  child: _NavTabButton(
                    palette: palette,
                    label: item.label,
                    iconType: item.type,
                    isActive: isActive,
                    onTap: () => onTap(index),
                  ),
                ),
              );
            }),
          ),
        ),
      ),
    );
  }
}

class _NavTabButton extends StatefulWidget {
  final RitmPalette palette;
  final String label;
  final _NavIconType iconType;
  final bool isActive;
  final VoidCallback onTap;

  const _NavTabButton({
    required this.palette,
    required this.label,
    required this.iconType,
    required this.isActive,
    required this.onTap,
  });

  @override
  State<_NavTabButton> createState() => _NavTabButtonState();
}

class _NavTabButtonState extends State<_NavTabButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final color = widget.isActive ? p.accent : p.faint;

    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      onTap: widget.onTap,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          constraints: const BoxConstraints(minHeight: 50),
          decoration: BoxDecoration(
            color: _pressed ? p.surfaceSoft : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SizedBox(
                width: 20,
                height: 20,
                child: CustomPaint(
                  painter: _NavIconPainter(
                    type: widget.iconType,
                    color: color,
                    strokeWidth: widget.isActive ? 2.2 : 1.7,
                  ),
                ),
              ),
              const SizedBox(height: 5),
              Text(
                widget.label,
                style: TextStyle(
                  color: color,
                  fontSize: 11.5,
                  fontWeight:
                  widget.isActive ? FontWeight.w700 : FontWeight.w600,
                  height: 1.0,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================================================
// РАЗДЕЛ 7: МОДАЛЬНОЕ ОКНО ОТМЕТКИ И РЕДАКТИРОВАНИЯ ОПЛАТЫ (#payment-dialog)
// ============================================================================

class _PaymentDialogModal extends StatefulWidget {
  final RitmController controller;
  final PaymentItem item;
  final ValueChanged<DateTime> onSave;
  final VoidCallback onUndo;

  const _PaymentDialogModal({
    required this.controller,
    required this.item,
    required this.onSave,
    required this.onUndo,
  });

  @override
  State<_PaymentDialogModal> createState() => _PaymentDialogModalState();
}

class _PaymentDialogModalState extends State<_PaymentDialogModal> {
  late DateTime _selectedDate;
  bool _fieldFocused = false;

  @override
  void initState() {
    super.initState();
    _selectedDate = widget.item.paidDate ?? RitmController.today;
  }

  Future<void> _pickDate() async {
    final p = widget.controller.palette;
    setState(() => _fieldFocused = true);
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2025, 1, 1),
      lastDate: DateTime(2028, 12, 31),
      helpText: 'Выберите фактическую дату оплаты',
      cancelText: 'Отмена',
      confirmText: 'Выбрать',
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: p.isDark
                ? ColorScheme.dark(
              primary: p.accent,
              onPrimary: p.onAccent,
              surface: p.surface,
              onSurface: p.ink,
            )
                : ColorScheme.light(
              primary: p.accent,
              onPrimary: p.onAccent,
              surface: p.surface,
              onSurface: p.ink,
            ),
          ),
          child: child!,
        );
      },
    );
    if (!mounted) return;
    setState(() {
      _fieldFocused = false;
      if (picked != null) _selectedDate = picked;
    });
  }

  void _shiftDay(int delta) {
    setState(() {
      _selectedDate = _selectedDate.add(Duration(days: delta));
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.controller.palette;
    final isPaid = widget.item.isPaid;

    return Center(
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: math.min(364.0, MediaQuery.sizeOf(context).width - 32),
          padding: const EdgeInsets.all(22),
          decoration: BoxDecoration(
            color: p.surface,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: p.line),
            boxShadow: const [
              BoxShadow(
                color: Color(0x400E261A),
                blurRadius: 100,
                offset: Offset(0, 30),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
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
                          isPaid ? 'Изменить дату оплаты' : 'Отметить оплату',
                          style: TextStyle(
                            color: p.ink,
                            fontSize: 21,
                            height: 1.15,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.5,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          isPaid
                              ? 'Уточните фактическую дату. Просрочка пересчитается автоматически.'
                              : 'Запишите фактическую дату. Её можно будет изменить позже.',
                          style: TextStyle(
                            color: p.muted,
                            fontSize: 13,
                            height: 1.4,
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
                          color: p.surfaceSoft,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        alignment: Alignment.center,
                        child: SizedBox(
                          width: 14,
                          height: 14,
                          child: CustomPaint(
                            painter: _CloseIconPainter(color: p.muted),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 13,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: p.surfaceSoft,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '${widget.item.name} · ${widget.item.formattedAmount}',
                  style: TextStyle(
                    color: p.ink,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Text(
                'Фактическая дата оплаты',
                style: TextStyle(
                  color: p.muted,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 7),
              GestureDetector(
                onTap: _pickDate,
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    height: 45,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    decoration: BoxDecoration(
                      color: p.page,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: _fieldFocused ? p.accent : p.line,
                      ),
                      boxShadow: _fieldFocused
                          ? [
                        BoxShadow(
                          color: p.accent.withValues(alpha: 0.15),
                          spreadRadius: 3,
                        ),
                      ]
                          : null,
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            '${RitmFormatters.isoDate(_selectedDate)} (${RitmFormatters.dayMonthLong(_selectedDate)})',
                            style: TextStyle(
                              color: p.ink,
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        _QuickDayAdjustButton(
                          palette: p,
                          label: '−1д',
                          onTap: () => _shiftDay(-1),
                        ),
                        const SizedBox(width: 5),
                        _QuickDayAdjustButton(
                          palette: p,
                          label: '+1д',
                          onTap: () => _shiftDay(1),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              _HoverBackgroundButton(
                normalColor: p.accent,
                hoverColor: p.accentStrong,
                borderRadius: BorderRadius.circular(12),
                minHeight: 46,
                onTap: () {
                  widget.onSave(_selectedDate);
                  Navigator.of(context).pop();
                },
                child: Text(
                  isPaid ? 'Сохранить дату' : 'Сохранить оплату',
                  style: TextStyle(
                    color: p.onAccent,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (isPaid) ...[
                const SizedBox(height: 10),
                GestureDetector(
                  onTap: () {
                    widget.onUndo();
                    Navigator.of(context).pop();
                  },
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      alignment: Alignment.center,
                      child: Text(
                        'Снять отметку об оплате',
                        style: TextStyle(
                          color: p.warning,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _QuickDayAdjustButton extends StatelessWidget {
  final RitmPalette palette;
  final String label;
  final VoidCallback onTap;

  const _QuickDayAdjustButton({
    required this.palette,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 5),
        decoration: BoxDecoration(
          color: palette.surface,
          borderRadius: BorderRadius.circular(7),
          border: Border.all(color: palette.line),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: palette.inkSoft,
            fontSize: 11,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

// ============================================================================
// РАЗДЕЛ 8: БАЗОВЫЕ ИНТЕРАКТИВНЫЕ КНОПКИ
// ============================================================================

class _HoverBackgroundButton extends StatefulWidget {
  final Color normalColor;
  final Color hoverColor;
  final BorderRadius borderRadius;
  final double minHeight;
  final EdgeInsetsGeometry? padding;
  final VoidCallback onTap;
  final Widget child;

  const _HoverBackgroundButton({
    required this.normalColor,
    required this.hoverColor,
    required this.borderRadius,
    required this.minHeight,
    this.padding,
    required this.onTap,
    required this.child,
  });

  @override
  State<_HoverBackgroundButton> createState() => _HoverBackgroundButtonState();
}

class _HoverBackgroundButtonState extends State<_HoverBackgroundButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          constraints: BoxConstraints(minHeight: widget.minHeight),
          padding: widget.padding,
          decoration: BoxDecoration(
            color: _hovered ? widget.hoverColor : widget.normalColor,
            borderRadius: widget.borderRadius,
          ),
          alignment: Alignment.center,
          child: widget.child,
        ),
      ),
    );
  }
}

// ============================================================================
// РАЗДЕЛ 9: КАСТОМНАЯ ОТРИСОВКА ИКОНОК И ГРАДИЕНТОВ (CustomPainter)
// ============================================================================

class _ServerOfflineIconPainter extends CustomPainter {
  final Color color;

  const _ServerOfflineIconPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final sx = size.width / 24.0;
    final sy = size.height / 24.0;

    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.9 * sx
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(3 * sx, 4 * sy, 18 * sx, 6 * sy),
        Radius.circular(2 * sx),
      ),
      paint,
    );

    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(3 * sx, 14 * sy, 18 * sx, 6 * sy),
        Radius.circular(2 * sx),
      ),
      paint,
    );

    canvas.drawLine(
      Offset(7 * sx, 7 * sy),
      Offset(7.1 * sx, 7 * sy),
      paint,
    );
    canvas.drawLine(
      Offset(7 * sx, 17 * sy),
      Offset(7.1 * sx, 17 * sy),
      paint,
    );

    canvas.drawLine(
      Offset(3 * sx, 21 * sy),
      Offset(21 * sx, 3 * sy),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant _ServerOfflineIconPainter oldDelegate) =>
      oldDelegate.color != color;
}

class _DarkOrangeTopBarPainter extends CustomPainter {
  const _DarkOrangeTopBarPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;

    final basePaint = Paint()
      ..shader = const LinearGradient(
        begin: Alignment(-0.9, -0.4),
        end: Alignment(0.9, 0.4),
        stops: [0.0, 0.58, 1.0],
        colors: [
          Color(0xFF171310),
          Color(0xFF141414),
          Color(0xFF101010),
        ],
      ).createShader(rect);
    canvas.drawRect(rect, basePaint);

    final glowPaint = Paint()
      ..shader = RadialGradient(
        center: Alignment.topLeft,
        radius: 1.15,
        colors: [
          const Color(0xFFFF7014).withValues(alpha: 0.20),
          Colors.transparent,
        ],
      ).createShader(rect);
    canvas.drawRect(rect, glowPaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _DarkRentCardGlowPainter extends CustomPainter {
  const _DarkRentCardGlowPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final glowPaint = Paint()
      ..shader = RadialGradient(
        center: Alignment.topRight,
        radius: 0.75,
        colors: [
          const Color(0xFFFF7014).withValues(alpha: 0.12),
          Colors.transparent,
        ],
      ).createShader(rect);
    canvas.drawRect(rect, glowPaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _PageAmbientBackgroundPainter extends CustomPainter {
  final bool isDark;

  const _PageAmbientBackgroundPainter({required this.isDark});

  @override
  void paint(Canvas canvas, Size size) {
    final p1 = Paint()
      ..shader = RadialGradient(
        center: const Alignment(-0.72, -0.76),
        radius: 0.55,
        colors: [
          isDark
              ? const Color(0xFFFF7014).withValues(alpha: 0.09)
              : const Color(0xFFD5E6CB).withValues(alpha: 0.7),
          Colors.transparent,
        ],
      ).createShader(Offset.zero & size);
    canvas.drawRect(Offset.zero & size, p1);

    final p2 = Paint()
      ..shader = RadialGradient(
        center: const Alignment(0.76, 0.74),
        radius: 0.55,
        colors: [
          isDark
              ? const Color(0xFFFF7014).withValues(alpha: 0.025)
              : const Color(0xFFD8E8D3).withValues(alpha: 0.55),
          Colors.transparent,
        ],
      ).createShader(Offset.zero & size);
    canvas.drawRect(Offset.zero & size, p2);
  }

  @override
  bool shouldRepaint(covariant _PageAmbientBackgroundPainter oldDelegate) =>
      oldDelegate.isDark != isDark;
}

class _HeroDecorationPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final glowPaint = Paint()
      ..shader = RadialGradient(
        center: const Alignment(1.0, -1.1),
        radius: 0.65,
        colors: [
          const Color(0xFF77AB71).withValues(alpha: 0.35),
          Colors.transparent,
        ],
      ).createShader(Offset.zero & size);
    canvas.drawRect(Offset.zero & size, glowPaint);

    final topHighlight = Paint()
      ..color = Colors.white.withValues(alpha: 0.12)
      ..strokeWidth = 1;
    canvas.drawLine(Offset.zero, Offset(size.width, 0), topHighlight);

    final center = Offset(size.width + 11, -11);
    final ring1 = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = const Color(0xFFDCF6AF).withValues(alpha: 0.09);
    canvas.drawCircle(center, 85, ring1);

    final ring2 = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 18
      ..color = const Color(0xFFDCF6AF).withValues(alpha: 0.025);
    canvas.drawCircle(center, 85 + 9, ring2);

    final ring3 = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 18
      ..color = const Color(0xFFDCF6AF).withValues(alpha: 0.02);
    canvas.drawCircle(center, 85 + 27, ring3);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _ConicRingPainter extends CustomPainter {
  final double progress;
  final Color activeColor;
  final Color trackColor;

  const _ConicRingPainter({
    required this.progress,
    required this.activeColor,
    required this.trackColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    const strokeWidth = 6.5;
    final radius = (size.width - strokeWidth) / 2;

    final trackPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..color = trackColor;
    canvas.drawCircle(center, radius, trackPaint);

    if (progress > 0) {
      const startAngle = (-90 - 35) * (math.pi / 180.0);
      final sweepAngle = 2 * math.pi * progress.clamp(0.0, 1.0);

      final progressPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.butt
        ..color = activeColor;

      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        startAngle,
        sweepAngle,
        false,
        progressPaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _ConicRingPainter oldDelegate) =>
      oldDelegate.progress != progress ||
          oldDelegate.activeColor != activeColor ||
          oldDelegate.trackColor != trackColor;
}

class _BrandWavePainter extends CustomPainter {
  final Color color;

  const _BrandWavePainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final sx = size.width / 24.0;
    final sy = size.height / 24.0;

    final strokePaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.3 * sx
      ..strokeCap = StrokeCap.round;

    final path = Path()
      ..moveTo(4 * sx, 13.2 * sy)
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
      ..color = color
      ..style = PaintingStyle.fill;

    canvas.drawCircle(Offset(4 * sx, 13.2 * sy), 1.5 * sx, fillPaint);
    canvas.drawCircle(Offset(20 * sx, 11.6 * sy), 1.5 * sx, fillPaint);
  }

  @override
  bool shouldRepaint(covariant _BrandWavePainter oldDelegate) =>
      oldDelegate.color != color;
}

class _UniversalPaymentReceiptPainter extends CustomPainter {
  final Color color;

  const _UniversalPaymentReceiptPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final sx = size.width / 20.0;
    final sy = size.height / 20.0;

    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.7 * sx
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(2.5 * sx, 3.0 * sy, 15.0 * sx, 14.0 * sy),
        Radius.circular(3.5 * sx),
      ),
      paint,
    );

    canvas.drawLine(
      Offset(6.2 * sx, 7.2 * sy),
      Offset(11.5 * sx, 7.2 * sy),
      paint,
    );

    final check = Path()
      ..moveTo(6.8 * sx, 11.8 * sy)
      ..lineTo(9.1 * sx, 13.9 * sy)
      ..lineTo(13.6 * sx, 9.6 * sy);
    canvas.drawPath(check, paint);
  }

  @override
  bool shouldRepaint(covariant _UniversalPaymentReceiptPainter oldDelegate) =>
      oldDelegate.color != color;
}

class _ChevronPainter extends CustomPainter {
  final bool isLeft;
  final Color color;

  const _ChevronPainter({required this.isLeft, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final sx = size.width / 12.0;
    final sy = size.height / 12.0;

    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6 * sx
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final path = Path();
    if (isLeft) {
      path
        ..moveTo(7.5 * sx, 2.5 * sy)
        ..lineTo(3.5 * sx, 6.0 * sy)
        ..lineTo(7.5 * sx, 9.5 * sy);
    } else {
      path
        ..moveTo(4.5 * sx, 2.5 * sy)
        ..lineTo(8.5 * sx, 6.0 * sy)
        ..lineTo(4.5 * sx, 9.5 * sy);
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _ChevronPainter oldDelegate) =>
      oldDelegate.isLeft != isLeft || oldDelegate.color != color;
}

class _ServerIconPainter extends CustomPainter {
  final Color color;

  const _ServerIconPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final sx = size.width / 20.0;
    final sy = size.height / 20.0;

    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5 * sx
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(3 * sx, 4 * sy, 14 * sx, 5 * sy),
        Radius.circular(1.5 * sx),
      ),
      paint,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(3 * sx, 11 * sy, 14 * sx, 5 * sy),
        Radius.circular(1.5 * sx),
      ),
      paint,
    );

    canvas.drawLine(
      Offset(6 * sx, 6.5 * sy),
      Offset(6.1 * sx, 6.5 * sy),
      paint,
    );
    canvas.drawLine(
      Offset(6 * sx, 13.5 * sy),
      Offset(6.1 * sx, 13.5 * sy),
      paint,
    );
    canvas.drawLine(
      Offset(9 * sx, 6.5 * sy),
      Offset(14 * sx, 6.5 * sy),
      paint,
    );
    canvas.drawLine(
      Offset(9 * sx, 13.5 * sy),
      Offset(14 * sx, 13.5 * sy),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant _ServerIconPainter oldDelegate) =>
      oldDelegate.color != color;
}

class _ClockIconPainter extends CustomPainter {
  final Color color;

  const _ClockIconPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final sx = size.width / 12.0;
    final sy = size.height / 12.0;

    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4 * sx
      ..strokeCap = StrokeCap.round;

    canvas.drawCircle(Offset(6 * sx, 6 * sy), 4.25 * sx, paint);
    final path = Path()
      ..moveTo(6 * sx, 3.4 * sy)
      ..lineTo(6 * sx, 6.2 * sy)
      ..lineTo(7.8 * sx, 7.2 * sy);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _ClockIconPainter oldDelegate) =>
      oldDelegate.color != color;
}

class _CheckIconPainter extends CustomPainter {
  final Color color;
  final double strokeWidth;

  const _CheckIconPainter({required this.color, required this.strokeWidth});

  @override
  void paint(Canvas canvas, Size size) {
    final sx = size.width / 12.0;
    final sy = size.height / 12.0;

    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth * sx
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final path = Path()
      ..moveTo(2.0 * sx, 6.0 * sy)
      ..lineTo(4.5 * sx, 8.5 * sy)
      ..lineTo(10.0 * sx, 3.0 * sy);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _CheckIconPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.strokeWidth != strokeWidth;
}

class _CloseIconPainter extends CustomPainter {
  final Color color;

  const _CloseIconPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final sx = size.width / 14.0;
    final sy = size.height / 14.0;

    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6 * sx
      ..strokeCap = StrokeCap.round;

    canvas.drawLine(Offset(3 * sx, 3 * sy), Offset(11 * sx, 11 * sy), paint);
    canvas.drawLine(Offset(11 * sx, 3 * sy), Offset(3 * sx, 11 * sy), paint);
  }

  @override
  bool shouldRepaint(covariant _CloseIconPainter oldDelegate) =>
      oldDelegate.color != color;
}

enum _NavIconType { home, payments, history, profile }

class _NavIconPainter extends CustomPainter {
  final _NavIconType type;
  final Color color;
  final double strokeWidth;

  const _NavIconPainter({
    required this.type,
    required this.color,
    required this.strokeWidth,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final sx = size.width / 24.0;
    final sy = size.height / 24.0;

    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth * sx
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    switch (type) {
      case _NavIconType.home:
        final house = Path()
          ..moveTo(3.5 * sx, 10 * sy)
          ..lineTo(12 * sx, 3.5 * sy)
          ..lineTo(20.5 * sx, 10 * sy)
          ..lineTo(20.5 * sx, 19 * sy)
          ..arcToPoint(
            Offset(19 * sx, 20.5 * sy),
            radius: Radius.circular(1.5 * sx),
          )
          ..lineTo(5 * sx, 20.5 * sy)
          ..arcToPoint(
            Offset(3.5 * sx, 19 * sy),
            radius: Radius.circular(1.5 * sx),
          )
          ..close();
        canvas.drawPath(house, paint);

        final door = Path()
          ..moveTo(9 * sx, 20.5 * sy)
          ..lineTo(9 * sx, 13.5 * sy)
          ..lineTo(15 * sx, 13.5 * sy)
          ..lineTo(15 * sx, 20.5 * sy);
        canvas.drawPath(door, paint);

      case _NavIconType.payments:
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(3.5 * sx, 4.5 * sy, 17 * sx, 15 * sy),
            Radius.circular(2.5 * sx),
          ),
          paint,
        );
        canvas.drawLine(
          Offset(7.5 * sx, 9 * sy),
          Offset(16.5 * sx, 9 * sy),
          paint,
        );
        canvas.drawLine(
          Offset(7.5 * sx, 13 * sy),
          Offset(11.5 * sx, 13 * sy),
          paint,
        );
        canvas.drawLine(
          Offset(7.5 * sx, 16 * sy),
          Offset(13.5 * sx, 16 * sy),
          paint,
        );

      case _NavIconType.history:
        canvas.drawCircle(Offset(12 * sx, 12 * sy), 8.5 * sx, paint);
        final hands = Path()
          ..moveTo(12 * sx, 7.5 * sy)
          ..lineTo(12 * sx, 12.5 * sy)
          ..lineTo(15.2 * sx, 14.5 * sy);
        canvas.drawPath(hands, paint);

      case _NavIconType.profile:
        canvas.drawCircle(Offset(12 * sx, 8 * sy), 3.3 * sx, paint);
        final shoulders = Path()
          ..moveTo(5 * sx, 20 * sy)
          ..lineTo(5 * sx, 18.9 * sy)
          ..arcToPoint(
            Offset(9.6 * sx, 14.3 * sy),
            radius: Radius.circular(4.6 * sx),
          )
          ..lineTo(14.4 * sx, 14.3 * sy)
          ..arcToPoint(
            Offset(19 * sx, 18.9 * sy),
            radius: Radius.circular(4.6 * sx),
          )
          ..lineTo(19 * sx, 20 * sy);
        canvas.drawPath(shoulders, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _NavIconPainter oldDelegate) =>
      oldDelegate.type != type ||
          oldDelegate.color != color ||
          oldDelegate.strokeWidth != strokeWidth;
}
