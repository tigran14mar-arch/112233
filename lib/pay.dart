import 'dart:async';
import 'dart:convert';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'main.dart';
import 'reg.dart';

// ============================================================================
// РАЗДЕЛ 1: МОДЕЛИ ОТВЕТОВ API ДЛЯ РЕГУЛЯРНЫХ ПЛАТЕЖЕЙ И СЕРВИС ЗАПРОСОВ
// ============================================================================

/// Модель шаблона регулярного платежа из GET / POST / PATCH /api/v1/recurring-payments
class RecurringPaymentTemplateDto {
  final int id;
  final String name;
  final double amount;
  final CurrencyCode currency;
  final String periodicity;
  final DateTime startDate;
  final int anchorDay;
  final int remindDaysBefore;
  final bool isDeleted;
  final DateTime? nextDueDate;

  // Поля результата PATCH-запроса
  final List<String> changedFields;
  final int updatedPeriods;
  final int removedPeriods;
  final int createdPeriods;

  const RecurringPaymentTemplateDto({
    required this.id,
    required this.name,
    required this.amount,
    required this.currency,
    required this.periodicity,
    required this.startDate,
    required this.anchorDay,
    required this.remindDaysBefore,
    required this.isDeleted,
    this.nextDueDate,
    this.changedFields = const [],
    this.updatedPeriods = 0,
    this.removedPeriods = 0,
    this.createdPeriods = 0,
  });

  static int _parseInt(dynamic value, int fallback) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value.trim()) ?? fallback;
    return fallback;
  }

  static double _parseDouble(dynamic value, double fallback) {
    if (value is num) return value.toDouble();
    if (value is String) {
      return double.tryParse(value.trim().replaceAll(',', '.')) ?? fallback;
    }
    return fallback;
  }

  static bool _parseBool(dynamic value, bool fallback) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    if (value is String) {
      final lower = value.trim().toLowerCase();
      if (lower == 'true' || lower == '1') return true;
      if (lower == 'false' || lower == '0') return false;
    }
    return fallback;
  }

  factory RecurringPaymentTemplateDto.fromJson(Map<String, dynamic> rawJson) {
    final Map<String, dynamic> json = (rawJson['item'] is Map<String, dynamic>)
        ? rawJson['item'] as Map<String, dynamic>
        : (rawJson['data'] is Map<String, dynamic>)
        ? rawJson['data'] as Map<String, dynamic>
        : rawJson;

    final parsedAmount = _parseDouble(json['amount'], 0.0);

    final currencyStr = (json['currency']?.toString() ?? 'RUB').toUpperCase();
    final currency = switch (currencyStr) {
      'USD' => CurrencyCode.usd,
      'EUR' => CurrencyCode.eur,
      _ => CurrencyCode.rub,
    };

    final startStr = (json['start_date'] ??
        json['next_due_date'] ??
        json['due_date'])
        ?.toString();
    final startDate =
        (startStr != null ? DateTime.tryParse(startStr) : null) ??
            RitmController.today;

    final nextDueStr =
    (json['next_due_date'] ?? json['due_date'])?.toString();
    final nextDueDate =
    nextDueStr != null ? DateTime.tryParse(nextDueStr) : null;

    final rawChanged = json['changed_fields'];
    final changedFields = rawChanged is List
        ? rawChanged.map((e) => e.toString()).toList()
        : const <String>[];

    final anchor = _parseInt(json['anchor_day'], startDate.day).clamp(1, 31);
    final remind = _parseInt(json['remind_days_before'], 3).clamp(1, 60);

    return RecurringPaymentTemplateDto(
      id: _parseInt(json['id'] ?? json['recurring_payment_id'], 0),
      name: (json['name'] ?? json['title'] ?? '').toString(),
      amount: parsedAmount,
      currency: currency,
      periodicity: (json['periodicity'] ?? 'monthly').toString(),
      startDate: startDate,
      anchorDay: anchor,
      remindDaysBefore: remind,
      isDeleted: _parseBool(
        json['is_deleted'] ?? json['is_recurring_deleted'],
        false,
      ),
      nextDueDate: nextDueDate,
      changedFields: changedFields,
      updatedPeriods: _parseInt(json['updated_periods'], 0),
      removedPeriods: _parseInt(json['removed_periods'], 0),
      createdPeriods: _parseInt(json['created_periods'], 0),
    );
  }
}

/// Результат вызова DELETE /api/v1/recurring-payments/{payment_id}
class DeleteRecurringResultDto {
  final int id;
  final String name;
  final bool isDeleted;
  final bool permanent;
  final int removedPeriods;

  const DeleteRecurringResultDto({
    required this.id,
    required this.name,
    required this.isDeleted,
    required this.permanent,
    required this.removedPeriods,
  });

  factory DeleteRecurringResultDto.fromJson(
      Map<String, dynamic> rawJson, {
        required int fallbackId,
        required bool requestedPermanent,
      }) {
    final Map<String, dynamic> json = (rawJson['data'] is Map<String, dynamic>)
        ? rawJson['data'] as Map<String, dynamic>
        : rawJson;

    return DeleteRecurringResultDto(
      id: RecurringPaymentTemplateDto._parseInt(json['id'], fallbackId),
      name: (json['name'] ?? '').toString(),
      isDeleted: RecurringPaymentTemplateDto._parseBool(
        json['is_deleted'],
        true,
      ),
      permanent: RecurringPaymentTemplateDto._parseBool(
        json['permanent'],
        requestedPermanent,
      ),
      removedPeriods: RecurringPaymentTemplateDto._parseInt(
        json['removed_periods'] ?? json['deleted_occurrences'],
        0,
      ),
    );
  }
}

/// Надёжный HTTP-сервис для работы с /api/v1/recurring-payments и /api/v1/payment-occurrences
/// Надёжный HTTP-сервис для работы с /api/v1/recurring-payments и /api/v1/payment-occurrences
abstract final class RecurringPaymentsApi {
  static const Duration _timeout = Duration(seconds: 12);

  static String get _baseUrl {
    final raw = RitmApiService.baseUrl.trim();
    return raw.endsWith('/') ? raw.substring(0, raw.length - 1) : raw;
  }

  static Future<String> _ensureValidToken({bool forceRefresh = false}) async {
    if (forceRefresh) {
      RitmSession.accessToken = null;
      RitmApiService.accessToken = null;
    }

    if ((RitmApiService.accessToken == null ||
        RitmApiService.accessToken!.trim().isEmpty) &&
        (RitmSession.accessToken == null ||
            RitmSession.accessToken!.trim().isEmpty)) {
      await RitmApiService.ensureAuthorized();
    }

    final resolved = (RitmSession.accessToken?.trim().isNotEmpty == true)
        ? RitmSession.accessToken!.trim()
        : (RitmApiService.accessToken?.trim() ?? '');

    if (resolved.isNotEmpty) {
      RitmSession.accessToken = resolved;
      RitmApiService.accessToken = resolved;
    }
    return resolved;
  }

  static Map<String, String> _buildHeaders(
      String token, {
        bool hasBody = false,
      }) {
    return <String, String>{
      'Accept': 'application/json',
      if (hasBody) 'Content-Type': 'application/json',
      if (token.isNotEmpty) 'Authorization': 'Bearer $token',
    };
  }

  static Uri _buildUri(String path, [Map<String, String>? queryParameters]) {
    final cleanPath = path.startsWith('/') ? path : '/$path';
    final uri = Uri.parse('$_baseUrl$cleanPath');
    if (queryParameters == null || queryParameters.isEmpty) {
      return uri;
    }
    return uri.replace(queryParameters: queryParameters);
  }

  static Future<Map<String, dynamic>> _requestJson({
    required String method,
    required String path,
    Map<String, String>? queryParameters,
    Map<String, dynamic>? body,
  }) async {
    var token = await _ensureValidToken();
    final uri = _buildUri(path, queryParameters);
    final hasBody = body != null;
    final encodedBody = hasBody ? jsonEncode(body) : null;

    Future<http.Response> sendOnce(String currentToken) {
      final headers = _buildHeaders(currentToken, hasBody: hasBody);
      switch (method.toUpperCase()) {
        case 'GET':
          return http.get(uri, headers: headers).timeout(_timeout);
        case 'POST':
          return http
              .post(uri, headers: headers, body: encodedBody)
              .timeout(_timeout);
        case 'PATCH':
          return http
              .patch(uri, headers: headers, body: encodedBody)
              .timeout(_timeout);
        case 'DELETE':
          return http.delete(uri, headers: headers).timeout(_timeout);
        default:
          throw UnsupportedError('Unsupported HTTP method: $method');
      }
    }

    try {
      var response = await sendOnce(token);

      if (response.statusCode == 401) {
        token = await _ensureValidToken(forceRefresh: true);
        response = await sendOnce(token);
      }

      return _handleHttpResponse(response);
    } on TimeoutException {
      throw const ServerOfflineException(
        'Сервер не ответил вовремя. Проверьте соединение.',
      );
    } on ApiRequestException {
      rethrow;
    } on ServerOfflineException {
      rethrow;
    } catch (e) {
      throw ServerOfflineException('Не удалось подключиться к серверу: $e');
    }
  }

  static List<Map<String, dynamic>> extractItemsList(
      Map<String, dynamic> response,
      ) {
    final candidates = [
      response['items'],
      response['data'],
      response['results'],
      response['recurring_payments'],
      response['occurrences'],
      response['payment_occurrences'],
    ];
    for (final candidate in candidates) {
      if (candidate is List) {
        return candidate
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
      }
    }
    return const <Map<String, dynamic>>[];
  }

  // ИСПРАВЛЕНИЕ 1: Ищем по общему списку, чтобы избежать ошибки 404/405
  static Future<RecurringPaymentTemplateDto> getById(int paymentId) async {
    try {
      final list = await listTemplates(includeDeleted: true);
      for (final item in list) {
        if (item.id == paymentId) return item;
      }
      final response = await _requestJson(
        method: 'GET',
        path: '/api/v1/recurring-payments/$paymentId',
      );
      return RecurringPaymentTemplateDto.fromJson(response);
    } catch (e) {
      rethrow;
    }
  }

  static Future<List<RecurringPaymentTemplateDto>> listTemplates({
    bool includeDeleted = true,
  }) async {
    Map<String, dynamic> response;
    try {
      response = await _requestJson(
        method: 'GET',
        path: '/api/v1/recurring-payments',
        queryParameters: includeDeleted
            ? {'include_deleted': 'true', 'limit': '200'}
            : {'limit': '200'},
      );
    } on ApiRequestException catch (e) {
      if (e.statusCode == 422 || e.statusCode == 400) {
        response = await _requestJson(
          method: 'GET',
          path: '/api/v1/recurring-payments',
        );
      } else {
        rethrow;
      }
    }
    return extractItemsList(response)
        .map(RecurringPaymentTemplateDto.fromJson)
        .toList();
  }

  static Future<Map<String, dynamic>?> getOccurrenceById(
      int occurrenceId,
      ) async {
    try {
      final resp = await _requestJson(
        method: 'GET',
        path: '/api/v1/payment-occurrences/$occurrenceId',
      );
      if (resp['item'] is Map) {
        return Map<String, dynamic>.from(resp['item'] as Map);
      }
      if (resp['data'] is Map) {
        return Map<String, dynamic>.from(resp['data'] as Map);
      }
      return resp;
    } catch (_) {
      return null;
    }
  }

  static Future<List<Map<String, dynamic>>> listOccurrences({
    DateTime? dateFrom,
    DateTime? dateTo,
  }) async {
    try {
      final query = <String, String>{
        if (dateFrom != null) 'date_from': RitmFormatters.isoDate(dateFrom),
        if (dateTo != null) 'date_to': RitmFormatters.isoDate(dateTo),
        'limit': '200',
      };
      final resp = await _requestJson(
        method: 'GET',
        path: '/api/v1/payment-occurrences',
        queryParameters: query,
      );
      return extractItemsList(resp);
    } on ApiRequestException catch (e) {
      if (e.statusCode == 422 || e.statusCode == 400) {
        final resp = await _requestJson(
          method: 'GET',
          path: '/api/v1/payment-occurrences',
        );
        return extractItemsList(resp);
      }
      rethrow;
    }
  }

  static Future<RecurringPaymentTemplateDto> create({
    required String name,
    required double amount,
    required CurrencyCode currency,
    required DateTime startDate,
    int? anchorDay,
    int remindDaysBefore = 3,
  }) async {
    final currencyStr = switch (currency) {
      CurrencyCode.usd => 'USD',
      CurrencyCode.eur => 'EUR',
      _ => 'RUB',
    };
    final fullBody = <String, dynamic>{
      'name': name.trim(),
      'amount': double.parse(amount.toStringAsFixed(2)),
      'currency': currencyStr,
      'start_date': RitmFormatters.isoDate(startDate),
      'periodicity': 'monthly',
      'anchor_day': (anchorDay ?? startDate.day).clamp(1, 31),
      'remind_days_before': remindDaysBefore.clamp(3, 60),
    };
    try {
      final response = await _requestJson(
        method: 'POST',
        path: '/api/v1/recurring-payments',
        body: fullBody,
      );
      return RecurringPaymentTemplateDto.fromJson(response);
    } on ApiRequestException catch (e) {
      if (e.statusCode == 422) {
        final fallbackBody = <String, dynamic>{
          'name': name.trim(),
          'amount': double.parse(amount.toStringAsFixed(2)),
          'currency': currencyStr,
          'start_date': RitmFormatters.isoDate(startDate),
          'periodicity': 'monthly',
        };
        final response = await _requestJson(
          method: 'POST',
          path: '/api/v1/recurring-payments',
          body: fallbackBody,
        );
        return RecurringPaymentTemplateDto.fromJson(response);
      }
      rethrow;
    }
  }

  // ИСПРАВЛЕНИЕ 2: Резервное создание платежа, если PATCH выдает сбой подключения
  static Future<RecurringPaymentTemplateDto> patch({
    required int paymentId,
    required Map<String, dynamic> changedBody,
    String? fullName,
    double? fullAmount,
    CurrencyCode? fullCurrency,
    DateTime? fullStartDate,
    int? fullAnchorDay,
    int fullRemindDays = 3,
  }) async {
    try {
      final response = await _requestJson(
        method: 'PATCH',
        path: '/api/v1/recurring-payments/$paymentId',
        body: changedBody,
      );
      return RecurringPaymentTemplateDto.fromJson(response);
    } catch (_) {
      // 1. Проверяем, не успел ли сервер сохранить изменения в БД до разрыва соединения
      try {
        final templates = await listTemplates(includeDeleted: true);
        for (final tpl in templates) {
          if (tpl.id == paymentId) {
            bool matchesAllChanges = true;
            if (changedBody.containsKey('name')) {
              if (tpl.name.trim() != changedBody['name'].toString().trim()) {
                matchesAllChanges = false;
              }
            }
            if (changedBody.containsKey('amount')) {
              final reqAmount = (changedBody['amount'] as num).toDouble();
              if ((tpl.amount - reqAmount).abs() > 0.01) {
                matchesAllChanges = false;
              }
            }
            if (changedBody.containsKey('currency')) {
              final reqCurr = changedBody['currency'].toString().toUpperCase();
              final tplCurr = switch (tpl.currency) {
                CurrencyCode.usd => 'USD',
                CurrencyCode.eur => 'EUR',
                _ => 'RUB',
              };
              if (tplCurr != reqCurr) {
                matchesAllChanges = false;
              }
            }
            if (matchesAllChanges) {
              // Платёж уже обновлён в БД — возвращаем его без создания нового
              return tpl;
            }
            break;
          }
        }
      } catch (_) {}

      // 2. Если БД не обновилась через PATCH — полностью удаляем старый шаблон (permanent: true)
      // и записываем обновлённый, чтобы не оставалось старой карточки
      if (fullName != null &&
          fullAmount != null &&
          fullCurrency != null &&
          fullStartDate != null) {
        try {
          await delete(paymentId: paymentId, permanent: true);
        } catch (_) {}

        final created = await create(
          name: fullName,
          amount: fullAmount,
          currency: fullCurrency,
          startDate: fullStartDate,
          anchorDay: fullAnchorDay ?? fullStartDate.day,
          remindDaysBefore: fullRemindDays,
        );
        return created;
      }
      rethrow;
    }
  }

  static Future<DeleteRecurringResultDto> delete({
    required int paymentId,
    required bool permanent,
  }) async {
    final response = await _requestJson(
      method: 'DELETE',
      path: '/api/v1/recurring-payments/$paymentId',
      queryParameters: permanent ? const {'permanent': 'true'} : null,
    );
    return DeleteRecurringResultDto.fromJson(
      response,
      fallbackId: paymentId,
      requestedPermanent: permanent,
    );
  }

  static Map<String, dynamic> _handleHttpResponse(http.Response response) {
    final bodyText = utf8.decode(response.bodyBytes).trim();
    if (response.statusCode == 502 ||
        response.statusCode == 503 ||
        response.statusCode == 504) {
      throw ServerOfflineException(
        'Сервер временно недоступен (код ${response.statusCode}).',
      );
    }

    if (response.statusCode >= 200 && response.statusCode < 300) {
      if (bodyText.isEmpty) return <String, dynamic>{};
      try {
        final decoded = jsonDecode(bodyText);
        if (decoded is Map<String, dynamic>) return decoded;
        if (decoded is Map) return Map<String, dynamic>.from(decoded);
        return <String, dynamic>{'data': decoded};
      } catch (_) {
        return <String, dynamic>{};
      }
    }

    String detailMessage = switch (response.statusCode) {
      401 => 'Сессия истекла. Войдите в аккаунт заново.',
      403 => 'Недостаточно прав: действие доступно только администратору.',
      404 => 'Платёж не найден на сервере.',
      409 => 'Платёж уже был изменён или прекращён.',
      _ => 'Ошибка запроса (код ${response.statusCode})',
    };

    try {
      if (bodyText.isNotEmpty) {
        final decoded = jsonDecode(bodyText);
        if (decoded is Map && decoded['detail'] != null) {
          final detail = decoded['detail'];
          if (detail is String && detail.trim().isNotEmpty) {
            detailMessage = detail.trim();
          } else if (detail is List && detail.isNotEmpty) {
            final messages = <String>[];
            for (final err in detail) {
              if (err is Map) {
                final loc =
                (err['loc'] is List && (err['loc'] as List).isNotEmpty)
                    ? (err['loc'] as List).last.toString()
                    : '';
                final msg = err['msg']?.toString() ?? 'Некорректное значение';
                messages.add(loc.isNotEmpty ? '$loc: $msg' : msg);
              }
            }
            if (messages.isNotEmpty) {
              detailMessage = 'Проверьте поля формы (${messages.join('; ')})';
            }
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
// РАЗДЕЛ 2: РАСШИРЕНИЯ РОЛЕЙ И СТАТИСТИКИ ПЛАТЕЖЕЙ
// ============================================================================

extension RitmPaymentsRoleExtension on RitmController {
  /// Проверка: вошёл ли в приложение администратор
  bool get isAdminAccount {
    final sessionRole =
    (RitmSession.currentUser?['role'] as String?)?.trim().toLowerCase();
    if (sessionRole != null && sessionRole.isNotEmpty) {
      return sessionRole == 'admin';
    }
    return userRole.trim().toLowerCase() == 'admin';
  }

  /// Список неоплаченных платежей (сначала просроченные, затем по дате)
  List<PaymentItem> get unpaidItemsSorted {
    final list = currentMonthItems.values.where((e) => !e.isPaid).toList();
    list.sort((a, b) {
      final aOver = a.isOverdue ? 0 : 1;
      final bOver = b.isOverdue ? 0 : 1;
      if (aOver != bOver) return aOver.compareTo(bOver);
      return a.dueDate.compareTo(b.dueDate);
    });
    return list;
  }

  /// Список уже оплаченных платежей за выбранный месяц
  List<PaymentItem> get paidItemsSorted {
    final list = currentMonthItems.values.where((e) => e.isPaid).toList();
    list.sort((a, b) {
      final dateA = a.paidDate ?? a.dueDate;
      final dateB = b.paidDate ?? b.dueDate;
      return dateB.compareTo(dateA);
    });
    return list;
  }

  /// Количество платежей со статусом «Скоро срок»
  int get upcomingSoonCount => currentMonthItems.values
      .where((e) => !e.isPaid && !e.isOverdue)
      .length;
}

// ============================================================================
// РАЗДЕЛ 3: ГЛАВНЫЙ ВИДЖЕТ ЭКРАНА «ПЛАТЕЖИ» (PaymentsScreen)
// ============================================================================

class PaymentsScreen extends StatefulWidget {
  final RitmController controller;
  final VoidCallback onBackToHome;
  final ValueChanged<PaymentItem> onOpenPaymentDialog;

  const PaymentsScreen({
    super.key,
    required this.controller,
    required this.onBackToHome,
    required this.onOpenPaymentDialog,
  });

  @override
  State<PaymentsScreen> createState() => _PaymentsScreenState();
}

class _PaymentsScreenState extends State<PaymentsScreen> {
  /// Полный список периодов платежей за выбранный месяц напрямую с сервера
  List<PaymentItem> _serverMonthItems = <PaymentItem>[];
  bool _hasLoadedServerItems = false;

  /// Привязка: occurrenceId -> recurringPaymentId
  final Map<int, int> _occurrenceToRecurringId = {};

  /// Привязка по нормализованному имени шаблона -> recurringPaymentId
  final Map<String, int> _nameToRecurringId = {};

  /// Признак того, что шаблон регулярного платежа уже прекращён (is_recurring_deleted: true)
  final Map<int, bool> _occurrenceRecurringDeleted = {};

  /// Множество ID шаблонов, которые прекращены (is_deleted: true)
  final Set<int> _deletedRecurringIds = <int>{};

  /// Множество ID шаблонов, удалённых навсегда (permanent: true)
  final Set<int> _permanentlyDeletedRecurringIds = <int>{};

  /// Локально скрытые неоплаченные occurrenceId после прекращения/удаления
  final Set<int> _hiddenUnpaidOccurrenceIds = <int>{};

  final Map<String, String> _customCategoriesByName = {};
  bool _isSyncingMeta = false;
  bool _isInternalControllerReload = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerNotified);
    _syncOccurrencesMetadata();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerNotified);
    super.dispose();
  }

  /// Если пользователь отметил оплату в диалоге main.dart или сменил месяц —
  /// автоматически подтягиваем свежие данные с сервера
  void _onControllerNotified() {
    if (_isInternalControllerReload || _isSyncingMeta) return;
    _syncOccurrencesMetadata();
  }

  static int? _asInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v.trim());
    return null;
  }

  static bool _asBool(dynamic v) {
    if (v is bool) return v;
    if (v is num) return v != 0;
    if (v is String) {
      final s = v.trim().toLowerCase();
      return s == 'true' || s == '1';
    }
    return false;
  }

  static String _normName(String name) => name.trim().toLowerCase();

  int? _extractRecurringIdFromOccurrence(Map<String, dynamic> raw) {
    final direct = _asInt(
      raw['recurring_payment_id'] ?? raw['template_id'] ?? raw['recurring_id'],
    );
    if (direct != null && direct > 0) return direct;

    final nested = raw['recurring_payment'] ?? raw['template'];
    if (nested is Map) {
      final nestedId = _asInt(nested['id']);
      if (nestedId != null && nestedId > 0) return nestedId;
    }
    return null;
  }

  bool _extractIsRecurringDeletedFromOccurrence(Map<String, dynamic> raw) {
    if (raw.containsKey('is_recurring_deleted')) {
      return _asBool(raw['is_recurring_deleted']);
    }
    if (raw.containsKey('is_deleted')) {
      return _asBool(raw['is_deleted']);
    }
    final nested = raw['recurring_payment'] ?? raw['template'];
    if (nested is Map && nested.containsKey('is_deleted')) {
      return _asBool(nested['is_deleted']);
    }
    final recId = _extractRecurringIdFromOccurrence(raw);
    if (recId != null && _deletedRecurringIds.contains(recId)) {
      return true;
    }
    return false;
  }

  /// Актуальный список неоплаченных платежей для рендера на экране
  List<PaymentItem> get _effectiveUnpaidItems {
    final source = _hasLoadedServerItems
        ? _serverMonthItems
        : widget.controller.currentMonthItems.values.toList();

    final list = source.where((item) {
      if (item.isPaid) return false;
      final occId = item.occurrenceId;
      if (occId != null) {
        if (_hiddenUnpaidOccurrenceIds.contains(occId)) return false;
        final recId = _occurrenceToRecurringId[occId];
        if (recId != null && _permanentlyDeletedRecurringIds.contains(recId)) {
          return false;
        }
      }
      return true;
    }).toList();

    list.sort((a, b) {
      final aOver = a.isOverdue ? 0 : 1;
      final bOver = b.isOverdue ? 0 : 1;
      if (aOver != bOver) return aOver.compareTo(bOver);
      final dateCmp = a.dueDate.compareTo(b.dueDate);
      if (dateCmp != 0) return dateCmp;
      // Новые платежи в пределах одного дня показываем выше
      return (b.occurrenceId ?? 0).compareTo(a.occurrenceId ?? 0);
    });

    return list;
  }

  /// Актуальный список оплаченных платежей для рендера на экране
  List<PaymentItem> get _effectivePaidItems {
    final source = _hasLoadedServerItems
        ? _serverMonthItems
        : widget.controller.currentMonthItems.values.toList();

    final list = source.where((item) {
      if (!item.isPaid) return false;
      final occId = item.occurrenceId;
      if (occId != null) {
        final recId = _occurrenceToRecurringId[occId];
        if (recId != null && _permanentlyDeletedRecurringIds.contains(recId)) {
          return false;
        }
      }
      return true;
    }).toList();

    list.sort((a, b) {
      final dateA = a.paidDate ?? a.dueDate;
      final dateB = b.paidDate ?? b.dueDate;
      final dateCmp = dateB.compareTo(dateA);
      if (dateCmp != 0) return dateCmp;
      return (b.occurrenceId ?? 0).compareTo(a.occurrenceId ?? 0);
    });

    return list;
  }

  /// Полная перезагрузка данных с сервера
  Future<void> _reloadAllFromServer({
    bool showSuccessToast = false,
    bool isPullToRefresh = false,
  }) async {
    _isInternalControllerReload = true;
    try {
      await widget.controller.loadFromServer(
        showSuccessToast: showSuccessToast,
        isPullToRefresh: isPullToRefresh,
      );
    } catch (_) {
    } finally {
      _isInternalControllerReload = false;
    }

    await _syncOccurrencesMetadata();
  }

  /// Прямая загрузка всех периодов и шаблонов с сервера в _serverMonthItems
  Future<void> _syncOccurrencesMetadata() async {
    if (_isSyncingMeta) return;
    _isSyncingMeta = true;
    try {
      final monthDate = widget.controller.viewMonth;
      final firstDay = DateTime(monthDate.year, monthDate.month, 1);
      final lastDay = DateTime(monthDate.year, monthDate.month + 1, 0);

      // 1. Загружаем шаблоны регулярных платежей
      try {
        final templates = await RecurringPaymentsApi.listTemplates(
          includeDeleted: true,
        );
        for (final tpl in templates) {
          if (tpl.id > 0) {
            final key = _normName(tpl.name);
            if (!tpl.isDeleted || !_nameToRecurringId.containsKey(key)) {
              _nameToRecurringId[key] = tpl.id;
            }
            if (tpl.isDeleted) {
              _deletedRecurringIds.add(tpl.id);
            } else {
              _deletedRecurringIds.remove(tpl.id);
            }
          }
        }
      } catch (_) {}

      // 2. Загружаем все периоды оплат за выбранный месяц
      final occItems = await RecurringPaymentsApi.listOccurrences(
        dateFrom: firstDay,
        dateTo: lastDay,
      );

      final parsedItems = <PaymentItem>[];
      final seenOccurrenceIds = <int>{};

      for (final raw in occItems) {
        final occId = _asInt(raw['id'] ?? raw['occurrence_id']);
        final recId = _extractRecurringIdFromOccurrence(raw);
        final isRecDeleted = _extractIsRecurringDeletedFromOccurrence(raw);
        final rawName = (raw['name'] ?? raw['title'] ?? '').toString();

        if (occId != null) {
          if (seenOccurrenceIds.contains(occId)) continue;
          seenOccurrenceIds.add(occId);

          if (recId != null) {
            _occurrenceToRecurringId[occId] = recId;
            if (rawName.trim().isNotEmpty) {
              _nameToRecurringId[_normName(rawName)] = recId;
            }
          } else if (rawName.trim().isNotEmpty &&
              _nameToRecurringId.containsKey(_normName(rawName))) {
            _occurrenceToRecurringId[occId] =
            _nameToRecurringId[_normName(rawName)]!;
          }
          _occurrenceRecurringDeleted[occId] = isRecDeleted;
        }

        try {
          final item = PaymentItem.fromOccurrenceJson(raw);
          parsedItems.add(item);
        } catch (_) {}
      }

      if (mounted) {
        setState(() {
          _serverMonthItems = parsedItems;
          _hasLoadedServerItems = true;
        });
      }
    } catch (_) {
    } finally {
      _isSyncingMeta = false;
    }
  }

  /// Находит ID шаблона регулярного платежа (recurring_payment_id) для выбранной карточки
  Future<int?> _resolveRecurringPaymentId(PaymentItem item) async {
    final occId = item.occurrenceId;

    // Шаг 1: Локальный кэш по occurrenceId
    if (occId != null && _occurrenceToRecurringId.containsKey(occId)) {
      return _occurrenceToRecurringId[occId];
    }

    // Шаг 2: Запрос конкретного периода GET /api/v1/payment-occurrences/{id}
    if (occId != null) {
      final singleOcc = await RecurringPaymentsApi.getOccurrenceById(occId);
      if (singleOcc != null) {
        final recId = _extractRecurringIdFromOccurrence(singleOcc);
        final isRecDel = _extractIsRecurringDeletedFromOccurrence(singleOcc);
        _occurrenceRecurringDeleted[occId] = isRecDel;
        if (recId != null) {
          _occurrenceToRecurringId[occId] = recId;
          return recId;
        }
      }
    }

    // Шаг 3: Запрос списка периодов за месяц платежа
    try {
      final firstDay = DateTime(item.dueDate.year, item.dueDate.month, 1);
      final lastDay = DateTime(item.dueDate.year, item.dueDate.month + 1, 0);
      final occList = await RecurringPaymentsApi.listOccurrences(
        dateFrom: firstDay,
        dateTo: lastDay,
      );

      for (final raw in occList) {
        final rawOccId = _asInt(raw['id'] ?? raw['occurrence_id']);
        final recId = _extractRecurringIdFromOccurrence(raw);
        final isRecDel = _extractIsRecurringDeletedFromOccurrence(raw);
        if (rawOccId != null) {
          if (recId != null) _occurrenceToRecurringId[rawOccId] = recId;
          _occurrenceRecurringDeleted[rawOccId] = isRecDel;
          if (occId != null && rawOccId == occId && recId != null) {
            return recId;
          }
        }
      }
    } catch (_) {}

    // Шаг 4: Поиск в шаблонах /api/v1/recurring-payments по имени, валюте и сумме
    try {
      final templates = await RecurringPaymentsApi.listTemplates(
        includeDeleted: true,
      );
      final targetName = _normName(item.name);

      for (final tpl in templates) {
        if (!tpl.isDeleted &&
            _normName(tpl.name) == targetName &&
            tpl.currency == item.currency &&
            (tpl.amount - item.amount).abs() < 0.01 &&
            tpl.id > 0) {
          if (occId != null) _occurrenceToRecurringId[occId] = tpl.id;
          return tpl.id;
        }
      }

      for (final tpl in templates) {
        if (_normName(tpl.name) == targetName && tpl.id > 0) {
          if (occId != null) _occurrenceToRecurringId[occId] = tpl.id;
          return tpl.id;
        }
      }
    } catch (_) {}

    // Шаг 5: Кэш по имени
    final cachedByName = _nameToRecurringId[_normName(item.name)];
    if (cachedByName != null && cachedByName > 0) {
      return cachedByName;
    }

    return null;
  }

  /// Открытие окна «Новый регулярный платёж» или «Изменить платёж»
  Future<void> _openRecurringPaymentModal({PaymentItem? existingItem}) async {
    int? recurringId;
    if (existingItem != null) {
      recurringId = await _resolveRecurringPaymentId(existingItem);
      if (!mounted) return;
      if (recurringId == null) {
        widget.controller.showToast(
          'Не удалось определить ID регулярного платежа на сервере',
          isError: true,
        );
        return;
      }
    }

    final initialCategory = existingItem != null
        ? (_customCategoriesByName[existingItem.name] ?? 'Регулярный платёж')
        : 'Регулярный платёж';

    await showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Закрыть',
      barrierColor: const Color(0x660E1D16),
      transitionDuration: const Duration(milliseconds: 260),
      pageBuilder: (context, anim1, anim2) {
        return _RecurringPaymentModalSheet(
          controller: widget.controller,
          existingItem: existingItem,
          recurringPaymentId: recurringId,
          initialCategory: initialCategory,
          onCompleted: (
              savedTemplate,
              savedName,
              selectedCategory,
              toastText,
              ) async {
            setState(() {
              if (existingItem != null && existingItem.name != savedName) {
                _customCategoriesByName.remove(existingItem.name);
              }
              _customCategoriesByName[savedName] = selectedCategory;

              if (savedTemplate != null && savedTemplate.id > 0) {
                // Если при сохранении шаблон был пересоздан с новым ID — скрываем старый
                if (recurringId != null && savedTemplate.id != recurringId) {
                  _permanentlyDeletedRecurringIds.add(recurringId);
                  if (existingItem?.occurrenceId != null) {
                    _hiddenUnpaidOccurrenceIds.add(existingItem!.occurrenceId!);
                  }
                }
                _nameToRecurringId[_normName(savedName)] = savedTemplate.id;
                _deletedRecurringIds.remove(savedTemplate.id);
                _permanentlyDeletedRecurringIds.remove(savedTemplate.id);
              }
            });
            await _reloadAllFromServer();
            if (toastText != null && toastText.isNotEmpty) {
              widget.controller.showToast(toastText);
            }
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
            sigmaX: 3.5 * curved.value,
            sigmaY: 3.5 * curved.value,
          ),
          child: FadeTransition(
            opacity: curved,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, 0.12),
                end: Offset.zero,
              ).animate(curved),
              child: child,
            ),
          ),
        );
      },
    );
  }

  /// Открытие диалога удаления/прекращения платежа
  Future<void> _openDeletePaymentDialog(PaymentItem item) async {
    final recurringId = await _resolveRecurringPaymentId(item);
    if (!mounted) return;

    if (recurringId == null) {
      widget.controller.showToast(
        'Не удалось найти регулярный платёж на сервере',
        isError: true,
      );
      return;
    }

    final isAlreadyStopped = (item.occurrenceId != null &&
        (_occurrenceRecurringDeleted[item.occurrenceId!] ?? false)) ||
        _deletedRecurringIds.contains(recurringId);

    await showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Закрыть',
      barrierColor: const Color(0x660E1D16),
      transitionDuration: const Duration(milliseconds: 230),
      pageBuilder: (context, anim1, anim2) {
        return _DeleteRecurringDialog(
          controller: widget.controller,
          item: item,
          recurringPaymentId: recurringId,
          isAlreadyStopped: isAlreadyStopped,
          onDeleted: (result, toastMessage) async {
            setState(() {
              _deletedRecurringIds.add(recurringId);
              if (item.occurrenceId != null) {
                _occurrenceRecurringDeleted[item.occurrenceId!] = true;
                if (!item.isPaid || result.permanent) {
                  _hiddenUnpaidOccurrenceIds.add(item.occurrenceId!);
                }
              }
              if (result.permanent) {
                _permanentlyDeletedRecurringIds.add(recurringId);
                _nameToRecurringId.remove(_normName(item.name));
              }
            });
            await _reloadAllFromServer();
            widget.controller.showToast(toastMessage);
          },
        );
      },
      transitionBuilder: (context, anim, _, child) {
        final curved =
        CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
        return BackdropFilter(
          filter: ImageFilter.blur(
            sigmaX: 3.0 * curved.value,
            sigmaY: 3.0 * curved.value,
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
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final p = widget.controller.palette;
        final isAdmin = widget.controller.isAdminAccount;
        final unpaidItems = _effectiveUnpaidItems;
        final paidItems = _effectivePaidItems;
        final monthLower =
        RitmFormatters.monthYearTitle(widget.controller.viewMonth)
            .toLowerCase();

        return AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          color: p.page,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // --- БЛОК 1: ВЕРХНЯЯ ПАНЕЛЬ (.subbar) С КНОПКОЙ «+» ДЛЯ АДМИНА ---
              _PaymentsTopBar(
                palette: p,
                subtitle: 'Команда · $monthLower',
                showAddButton: isAdmin,
                onBackTap: widget.onBackToHome,
                onAddTap: () => _openRecurringPaymentModal(),
              ),

              // --- БЛОК 2: ПРОКРУЧИВАЕМЫЙ КОНТЕНТ С ПОДДЕРЖКОЙ ОБНОВЛЕНИЯ ---
              Expanded(
                child: RefreshIndicator(
                  color: p.accent,
                  backgroundColor: p.surface,
                  onRefresh: () async {
                    await _reloadAllFromServer(
                      showSuccessToast: true,
                      isPullToRefresh: true,
                    );
                  },
                  child: SingleChildScrollView(
                    physics: const BouncingScrollPhysics(
                      parent: AlwaysScrollableScrollPhysics(),
                    ),
                    padding: const EdgeInsets.fromLTRB(18, 12, 18, 26),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _PaymentsIntroSection(
                          palette: p,
                          monthTitleLower: monthLower,
                        ),
                        _PaymentsSummaryGrid(
                          palette: p,
                          paidCount: paidItems.length,
                          unpaidItems: unpaidItems,
                        ),
                        const SizedBox(height: 13),
                        _PaymentsProgressBar(
                          palette: p,
                          fraction: (paidItems.length + unpaidItems.length) == 0
                              ? 0.0
                              : paidItems.length /
                              (paidItems.length + unpaidItems.length),
                        ),
                        const SizedBox(height: 22),
                        _NeedsPaymentSection(
                          palette: p,
                          isAdmin: isAdmin,
                          items: unpaidItems,
                          customCategories: _customCategoriesByName,
                          stoppedMap: _occurrenceRecurringDeleted,
                          onMarkPayment: widget.onOpenPaymentDialog,
                          onEditPayment: (item) =>
                              _openRecurringPaymentModal(existingItem: item),
                          onDeletePayment: _openDeletePaymentDialog,
                        ),
                        const SizedBox(height: 22),
                        _StatusMeaningSection(palette: p),
                        const SizedBox(height: 22),
                        _AlreadyPaidSection(
                          palette: p,
                          paidItems: paidItems,
                          viewMonth: widget.controller.viewMonth,
                          onItemTap: widget.onOpenPaymentDialog,
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
// РАЗДЕЛ 4: ШАПКА, СВОДКА И КАРТОЧКИ ПЛАТЕЖЕЙ
// ============================================================================

class _PaymentsTopBar extends StatelessWidget {
  final RitmPalette palette;
  final String subtitle;
  final bool showAddButton;
  final VoidCallback onBackTap;
  final VoidCallback onAddTap;

  const _PaymentsTopBar({
    required this.palette,
    required this.subtitle,
    required this.showAddButton,
    required this.onBackTap,
    required this.onAddTap,
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
              _IconSquareButton(
                palette: palette,
                size: 38,
                borderRadius: 12,
                onTap: onBackTap,
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CustomPaint(
                    painter: _BackChevronPainter(color: palette.ink),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Платежи',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
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
                      subtitle,
                      style: TextStyle(
                        color: palette.muted,
                        fontSize: 11.5,
                      ),
                    ),
                  ],
                ),
              ),
              if (showAddButton)
                _IconSquareButton(
                  palette: palette,
                  size: 36,
                  borderRadius: 11,
                  onTap: onAddTap,
                  tooltip: 'Добавить платёж',
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CustomPaint(
                      painter: _PlusIconPainter(color: palette.accent),
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

class _PaymentsIntroSection extends StatelessWidget {
  final RitmPalette palette;
  final String monthTitleLower;

  const _PaymentsIntroSection({
    required this.palette,
    required this.monthTitleLower,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(1, 2, 1, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'ПОДРОБНЫЙ ПЛАН',
            style: TextStyle(
              color: palette.accentInk,
              fontSize: 11,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.0,
            ),
          ),
          const SizedBox(height: 7),
          Text(
            'Платежи команды',
            style: TextStyle(
              color: palette.ink,
              fontSize: 26,
              height: 1.13,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.8,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Все суммы и сроки за $monthTitleLower собраны здесь. Проверьте, что уже оплачено, что нужно оплатить и какие платежи просрочены.',
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

class _PaymentsSummaryGrid extends StatelessWidget {
  final RitmPalette palette;
  final int paidCount;
  final List<PaymentItem> unpaidItems;

  const _PaymentsSummaryGrid({
    required this.palette,
    required this.paidCount,
    required this.unpaidItems,
  });

  @override
  Widget build(BuildContext context) {
    final p = palette;
    final pending = unpaidItems.length;
    final total = paidCount + pending;
    final overdue = unpaidItems.where((e) => e.isOverdue).length;
    final soon = unpaidItems.where((e) => !e.isOverdue).length;

    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: _SummaryTile(
                palette: p,
                label: 'Оплачено',
                value: '$paidCount из $total',
                valueColor: p.success,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _SummaryTile(
                palette: p,
                label: 'Осталось оплатить',
                value: '$pending ${RitmFormatters.pluralPayments(pending)}',
                valueColor: p.ink,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: _SummaryTile(
                palette: p,
                label: 'Просрочено',
                value: '$overdue ${RitmFormatters.pluralPayments(overdue)}',
                valueColor: p.warning,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _SummaryTile(
                palette: p,
                label: 'Скоро срок',
                value: '$soon ${RitmFormatters.pluralPayments(soon)}',
                valueColor: p.ink,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _SummaryTile extends StatelessWidget {
  final RitmPalette palette;
  final String label;
  final String value;
  final Color valueColor;

  const _SummaryTile({
    required this.palette,
    required this.label,
    required this.value,
    required this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 76),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: palette.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            label,
            style: TextStyle(
              color: palette.muted,
              fontSize: 11.5,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 7),
          Text(
            value,
            style: TextStyle(
              color: valueColor,
              fontSize: 16,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.3,
            ),
          ),
        ],
      ),
    );
  }
}

class _PaymentsProgressBar extends StatelessWidget {
  final RitmPalette palette;
  final double fraction;

  const _PaymentsProgressBar({
    required this.palette,
    required this.fraction,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 6,
      decoration: BoxDecoration(
        color: palette.surfaceSoft,
        borderRadius: BorderRadius.circular(99),
      ),
      clipBehavior: Clip.antiAlias,
      child: TweenAnimationBuilder<double>(
        tween: Tween<double>(begin: 0, end: fraction.clamp(0.0, 1.0)),
        duration: const Duration(milliseconds: 380),
        curve: Curves.easeOutCubic,
        builder: (context, val, _) {
          return FractionallySizedBox(
            alignment: Alignment.centerLeft,
            widthFactor: val,
            child: Container(
              decoration: BoxDecoration(
                color: palette.isDark ? palette.accent : palette.successDot,
                borderRadius: BorderRadius.circular(99),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _NeedsPaymentSection extends StatelessWidget {
  final RitmPalette palette;
  final bool isAdmin;
  final List<PaymentItem> items;
  final Map<String, String> customCategories;
  final Map<int, bool> stoppedMap;
  final ValueChanged<PaymentItem> onMarkPayment;
  final ValueChanged<PaymentItem> onEditPayment;
  final ValueChanged<PaymentItem> onDeletePayment;

  const _NeedsPaymentSection({
    required this.palette,
    required this.isAdmin,
    required this.items,
    required this.customCategories,
    required this.stoppedMap,
    required this.onMarkPayment,
    required this.onEditPayment,
    required this.onDeletePayment,
  });

  @override
  Widget build(BuildContext context) {
    final badgeText = items.isNotEmpty
        ? '${items.length} ${RitmFormatters.pluralPayments(items.length)}'
        : 'Все оплачены';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'Нужно оплатить',
              style: TextStyle(
                color: palette.ink,
                fontSize: 18,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.35,
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color:
                items.isEmpty ? palette.successSoft : palette.warningSoft,
                borderRadius: BorderRadius.circular(99),
                border: Border.all(
                  color: items.isEmpty ? palette.line : palette.warningLine,
                ),
              ),
              child: Text(
                badgeText,
                style: TextStyle(
                  color: items.isEmpty ? palette.success : palette.warning,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          'Сначала показан платёж с прошедшим сроком, затем ближайшие даты.',
          style: TextStyle(
            color: palette.muted,
            fontSize: 12,
            height: 1.45,
          ),
        ),
        const SizedBox(height: 10),
        if (items.isEmpty)
          Container(
            padding: const EdgeInsets.all(13),
            decoration: BoxDecoration(
              color: palette.surfaceSoft,
              borderRadius: BorderRadius.circular(13),
              border: Border.all(color: palette.line),
            ),
            child: Text(
              'Все платежи отмечены в этом месяце.',
              style: TextStyle(
                color: palette.muted,
                fontSize: 12.5,
              ),
            ),
          )
        else
          Column(
            children: List.generate(items.length, (index) {
              final item = items[index];
              final isStopped = item.occurrenceId != null &&
                  (stoppedMap[item.occurrenceId!] ?? false);
              final category = isStopped
                  ? 'Прекращён'
                  : (customCategories[item.name] ??
                  (item.isOverdue
                      ? RitmFormatters.forMonthCapitalized(item.dueDate)
                      : 'Регулярный платёж'));

              return Padding(
                padding: EdgeInsets.only(top: index == 0 ? 0 : 9),
                child: _PaymentDetailCard(
                  palette: palette,
                  item: item,
                  category: category,
                  isAdmin: isAdmin,
                  isStopped: isStopped,
                  onMarkTap: () => onMarkPayment(item),
                  onEditTap: () => onEditPayment(item),
                  onDeleteTap: () => onDeletePayment(item),
                ),
              );
            }),
          ),
      ],
    );
  }
}

class _PaymentDetailCard extends StatelessWidget {
  final RitmPalette palette;
  final PaymentItem item;
  final String category;
  final bool isAdmin;
  final bool isStopped;
  final VoidCallback onMarkTap;
  final VoidCallback onEditTap;
  final VoidCallback onDeleteTap;

  const _PaymentDetailCard({
    required this.palette,
    required this.item,
    required this.category,
    required this.isAdmin,
    this.isStopped = false,
    required this.onMarkTap,
    required this.onEditTap,
    required this.onDeleteTap,
  });

  @override
  Widget build(BuildContext context) {
    final p = palette;
    final isLate = !item.isPaid && item.isOverdue;

    final String statusLabel = item.isPaid
        ? 'Оплачено · ${RitmFormatters.shortDate(item.paidDate ?? item.dueDate)}'
        : (isLate
        ? 'Просрочен · ${RitmFormatters.shortDate(item.dueDate)}'
        : 'Скоро · ${RitmFormatters.shortDate(item.dueDate)}');

    final Color pillBg = item.isPaid
        ? p.successSoft
        : (isLate
        ? p.warningSoft
        : (p.isDark ? const Color(0xFF2B2114) : const Color(0xFFF8F2E7)));

    final Color pillFg = item.isPaid
        ? p.success
        : (isLate
        ? p.warning
        : (p.isDark ? const Color(0xFFF0B865) : const Color(0xFF9B7433)));

    final String desc = item.isPaid && item.paidDate != null
        ? 'Фактическая дата оплаты · ${RitmFormatters.shortDate(item.paidDate!)}'
        : item.unpaidNote;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: BorderRadius.circular(15),
        border: Border.all(
          color: isLate ? p.warningLine : p.line,
        ),
        boxShadow: [
          BoxShadow(
            color: p.cardShadow,
            blurRadius: 16,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Container(
                  padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: pillBg,
                    borderRadius: BorderRadius.circular(99),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 5,
                        height: 5,
                        decoration: BoxDecoration(
                          color: pillFg,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 5),
                      Text(
                        statusLabel,
                        style: TextStyle(
                          color: pillFg,
                          fontSize: 10.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
                Text(
                  category,
                  style: TextStyle(
                    color: isStopped ? p.warning : p.muted,
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
            child: Row(
              children: [
                Container(
                  width: 39,
                  height: 39,
                  decoration: BoxDecoration(
                    color: p.warningSoft,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: p.warningLine),
                  ),
                  alignment: Alignment.center,
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CustomPaint(
                      painter: _ReceiptWaveIconPainter(color: p.warning),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.name,
                        style: TextStyle(
                          color: p.ink,
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        desc,
                        style: TextStyle(
                          color: p.muted,
                          fontSize: 11.5,
                          height: 1.35,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  item.formattedAmount,
                  style: TextStyle(
                    color: p.ink,
                    fontSize: 14.5,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: p.line)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Flexible(
                  child: Text(
                    isLate
                        ? 'Срок оплаты прошёл'
                        : 'Оплата ${RitmFormatters.forMonthAccusative(item.dueDate)}',
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: p.muted,
                      fontSize: 11,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Кнопки карандаша и крестика — ТОЛЬКО ДЛЯ АДМИНА
                    if (isAdmin) ...[
                      _TinyAdminActionButton(
                        palette: p,
                        tooltip: 'Изменить',
                        onTap: onEditTap,
                        child: SizedBox(
                          width: 14,
                          height: 14,
                          child: CustomPaint(
                            painter: _EditPencilIconPainter(color: p.muted),
                          ),
                        ),
                      ),
                      const SizedBox(width: 5),
                      _TinyAdminActionButton(
                        palette: p,
                        tooltip: 'Прекратить или удалить',
                        onTap: onDeleteTap,
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
                      const SizedBox(width: 6),
                    ],
                    _PrimaryActionSmallButton(
                      palette: p,
                      label: item.isPaid ? 'Изменить дату' : 'Отметить оплату',
                      onTap: onMarkTap,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusMeaningSection extends StatelessWidget {
  final RitmPalette palette;

  const _StatusMeaningSection({required this.palette});

  @override
  Widget build(BuildContext context) {
    final p = palette;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Что означают статусы',
          style: TextStyle(
            color: p.ink,
            fontSize: 18,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.35,
          ),
        ),
        const SizedBox(height: 10),
        _MeaningRow(
          palette: p,
          dotColor: p.successDot,
          title: 'Оплачено',
          copy: 'Участник команды записал фактическую дату оплаты.',
        ),
        const SizedBox(height: 8),
        _MeaningRow(
          palette: p,
          dotColor: const Color(0xFFD5A953),
          title: 'Скоро срок',
          copy:
          'Дата платежа ещё не наступила. Сумма и срок указаны в карточке.',
        ),
        const SizedBox(height: 8),
        _MeaningRow(
          palette: p,
          dotColor: p.warningDot,
          title: 'Просрочено',
          copy: 'Дата оплаты прошла, но платёж ещё не отмечен.',
        ),
      ],
    );
  }
}

class _MeaningRow extends StatelessWidget {
  final RitmPalette palette;
  final Color dotColor;
  final String title;
  final String copy;

  const _MeaningRow({
    required this.palette,
    required this.dotColor,
    required this.title,
    required this.copy,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: palette.line),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 8,
            height: 8,
            margin: const EdgeInsets.only(top: 4),
            decoration: BoxDecoration(
              color: dotColor,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: palette.ink,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  copy,
                  style: TextStyle(
                    color: palette.muted,
                    fontSize: 11.5,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _AlreadyPaidSection extends StatelessWidget {
  final RitmPalette palette;
  final List<PaymentItem> paidItems;
  final DateTime viewMonth;
  final ValueChanged<PaymentItem> onItemTap;

  const _AlreadyPaidSection({
    required this.palette,
    required this.paidItems,
    required this.viewMonth,
    required this.onItemTap,
  });

  @override
  Widget build(BuildContext context) {
    final p = palette;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Уже оплачено',
          style: TextStyle(
            color: p.ink,
            fontSize: 18,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.35,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          'Ниже — платежи, которые уже отмечены ${RitmFormatters.forMonthAccusative(viewMonth)}, с датами и суммами.',
          style: TextStyle(
            color: p.muted,
            fontSize: 12,
            height: 1.45,
          ),
        ),
        const SizedBox(height: 10),
        Container(
          decoration: BoxDecoration(
            color: p.surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: p.line),
          ),
          clipBehavior: Clip.antiAlias,
          child: paidItems.isEmpty
              ? Padding(
            padding: const EdgeInsets.all(14),
            child: Text(
              'В этом месяце пока нет оплаченных счетов.',
              style: TextStyle(
                color: p.muted,
                fontSize: 12.5,
              ),
            ),
          )
              : Column(
            children: List.generate(paidItems.length, (index) {
              final item = paidItems[index];
              final paidDate = item.paidDate ?? item.dueDate;
              return _ScreenHistoryRow(
                palette: p,
                name: item.name,
                dateSubtitle:
                'Оплачено · ${RitmFormatters.shortDate(paidDate)}',
                amount: item.formattedAmount,
                showTopBorder: index > 0,
                onTap: () => onItemTap(item),
              );
            }),
          ),
        ),
      ],
    );
  }
}

class _ScreenHistoryRow extends StatefulWidget {
  final RitmPalette palette;
  final String name;
  final String dateSubtitle;
  final String amount;
  final bool showTopBorder;
  final VoidCallback onTap;

  const _ScreenHistoryRow({
    required this.palette,
    required this.name,
    required this.dateSubtitle,
    required this.amount,
    required this.showTopBorder,
    required this.onTap,
  });

  @override
  State<_ScreenHistoryRow> createState() => _ScreenHistoryRowState();
}

class _ScreenHistoryRowState extends State<_ScreenHistoryRow> {
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
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: _hovered ? p.surfaceSoft : Colors.transparent,
            border: widget.showTopBorder
                ? Border(top: BorderSide(color: p.line))
                : null,
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
                      widget.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: p.ink,
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      widget.dateSubtitle,
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
                widget.amount,
                style: TextStyle(
                  color: p.ink,
                  fontSize: 14,
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

class _ImportantNoteBox extends StatelessWidget {
  final RitmPalette palette;

  const _ImportantNoteBox({required this.palette});

  @override
  Widget build(BuildContext context) {
    return Container(

    );
  }
}

// ============================================================================
// РАЗДЕЛ 5: МОДАЛЬНОЕ ОКНО «НОВЫЙ РЕГУЛЯРНЫЙ ПЛАТЁЖ» / «ИЗМЕНИТЬ ПЛАТЁЖ»
// (Без полей «День месяца» и «Напоминать за дней» в UI)
// ============================================================================

class _RecurringPaymentModalSheet extends StatefulWidget {
  final RitmController controller;
  final PaymentItem? existingItem;
  final int? recurringPaymentId;
  final String initialCategory;
  final Future<void> Function(
      RecurringPaymentTemplateDto? savedTemplate,
      String savedName,
      String selectedCategory,
      String? toastText,
      ) onCompleted;

  const _RecurringPaymentModalSheet({
    required this.controller,
    required this.existingItem,
    required this.recurringPaymentId,
    required this.initialCategory,
    required this.onCompleted,
  });

  @override
  State<_RecurringPaymentModalSheet> createState() =>
      _RecurringPaymentModalSheetState();
}

class _RecurringPaymentModalSheetState
    extends State<_RecurringPaymentModalSheet> {
  static const List<String> _categories = [
    'Регулярный платёж',
    'Инфраструктура',
    'Помещение',
    'Связь',
    'Подписка',
    'Сервисы',
  ];

  late final TextEditingController _nameCtrl;
  late final TextEditingController _amountCtrl;

  late CurrencyCode _selectedCurrency;
  late DateTime _selectedDueDate;
  late String _selectedCategory;

  // Исходные значения шаблона из GET /api/v1/recurring-payments/{id}
  String? _origName;
  double? _origAmount;
  CurrencyCode? _origCurrency;
  DateTime? _origStartDate;
  int? _origAnchorDay;
  int _origRemindDays = 3;
  bool _userChangedDueDatePicker = false;

  bool _isLoadingTemplate = false;
  bool _isSubmitting = false;
  String? _errorText;

  bool get _isEditMode =>
      widget.existingItem != null && widget.recurringPaymentId != null;

  @override
  void initState() {
    super.initState();
    final item = widget.existingItem;
    final defaultDate = item?.dueDate ?? RitmController.today;

    _nameCtrl = TextEditingController(text: item?.name ?? '');
    _amountCtrl = TextEditingController(
      text: item != null ? _formatAmountForInput(item.amount) : '',
    );

    _selectedCurrency = item?.currency ?? CurrencyCode.rub;
    _selectedDueDate = defaultDate;
    _selectedCategory = _categories.contains(widget.initialCategory)
        ? widget.initialCategory
        : _categories.first;

    if (_isEditMode) {
      _origName = item!.name;
      _origAmount = item.amount;
      _origCurrency = item.currency;
      _origStartDate = item.dueDate;
      _origAnchorDay = item.dueDate.day;
      _origRemindDays = 3;
      _loadTemplateFromServer();
    }
  }

  String _formatAmountForInput(double val) {
    if (val == val.roundToDouble()) {
      return val.round().toString();
    }
    return val.toStringAsFixed(2);
  }

  /// Загружаем актуальные значения шаблона с сервера перед редактированием
  Future<void> _loadTemplateFromServer() async {
    setState(() {
      _isLoadingTemplate = true;
      _errorText = null;
    });

    try {
      final tpl = await RecurringPaymentsApi.getById(
        widget.recurringPaymentId!,
      );
      if (!mounted) return;

      final displayDate =
          tpl.nextDueDate ?? widget.existingItem?.dueDate ?? tpl.startDate;
      setState(() {
        _nameCtrl.text = tpl.name;
        _amountCtrl.text = _formatAmountForInput(tpl.amount);
        _selectedCurrency = tpl.currency;
        _selectedDueDate = displayDate;

        _origName = tpl.name;
        _origAmount = tpl.amount;
        _origCurrency = tpl.currency;
        _origStartDate = displayDate;
        _origAnchorDay = tpl.anchorDay;
        _origRemindDays = tpl.remindDaysBefore;
        _userChangedDueDatePicker = false;
        _isLoadingTemplate = false;
      });
    } on ApiRequestException catch (e) {
      if (!mounted) return;
      setState(() {
        _errorText = e.detail;
        _isLoadingTemplate = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _isLoadingTemplate = false);
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _amountCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickDueDate() async {
    final p = widget.controller.palette;
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDueDate,
      firstDate: DateTime(2000, 1, 1),
      lastDate: DateTime(2100, 12, 31),
      helpText: 'Дата ближайшей оплаты',
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
    if (picked != null && mounted) {
      setState(() {
        _selectedDueDate = picked;
        _userChangedDueDatePicker = true;
      });
    }
  }

  Future<void> _submitForm() async {
    final name = _nameCtrl.text.trim();
    final rawAmount =
    _amountCtrl.text.trim().replaceAll(' ', '').replaceAll(',', '.');
    final amount = double.tryParse(rawAmount);
    final anchorDay = _selectedDueDate.day.clamp(1, 31);
    final remindDays = _origRemindDays.clamp(3, 60);

    if (name.isEmpty || name.length > 255) {
      setState(
            () => _errorText = 'Укажите название платежа (от 1 до 255 символов).',
      );
      return;
    }
    if (amount == null || amount <= 0) {
      setState(() => _errorText = 'Сумма должна быть больше 0.');
      return;
    }

    setState(() {
      _isSubmitting = true;
      _errorText = null;
    });

    try {
      if (_isEditMode) {
        final changedBody = <String, dynamic>{};

        if (_origName == null || name != _origName) {
          changedBody['name'] = name;
        }
        if (_origAmount == null || (amount - _origAmount!).abs() >= 0.005) {
          changedBody['amount'] = double.parse(amount.toStringAsFixed(2));
        }
        if (_origCurrency == null || _selectedCurrency != _origCurrency) {
          changedBody['currency'] = switch (_selectedCurrency) {
            CurrencyCode.rub => 'RUB',
            CurrencyCode.usd => 'USD',
            CurrencyCode.eur => 'EUR',
          };
        }

        final dueDateChanged = _userChangedDueDatePicker &&
            (_origStartDate == null ||
                RitmFormatters.isoDate(_selectedDueDate) !=
                    RitmFormatters.isoDate(_origStartDate!));

        if (dueDateChanged) {
          changedBody['start_date'] = RitmFormatters.isoDate(_selectedDueDate);
          if (_origAnchorDay == null || anchorDay != _origAnchorDay) {
            changedBody['anchor_day'] = anchorDay;
          }
        }

        final categoryChanged = _selectedCategory != widget.initialCategory;

        if (changedBody.isEmpty) {
          if (categoryChanged) {
            await widget.onCompleted(
              null,
              name,
              _selectedCategory,
              'Категория обновлена',
            );
          } else {
            widget.controller.showToast('Изменений нет');
          }
          if (!mounted) return;
          Navigator.of(context).pop();
          return;
        }

        final patchResult = await RecurringPaymentsApi.patch(
          paymentId: widget.recurringPaymentId!,
          changedBody: changedBody,
          fullName: name,
          fullAmount: amount,
          fullCurrency: _selectedCurrency,
          fullStartDate: _selectedDueDate,
          fullAnchorDay: anchorDay,
          fullRemindDays: remindDays,
        );

        await widget.onCompleted(
          patchResult,
          name,
          _selectedCategory,
          'Изменения сохранены',
        );
        if (!mounted) return;
        Navigator.of(context).pop();
      } else {
        final createdTemplate = await RecurringPaymentsApi.create(
          name: name,
          amount: amount,
          currency: _selectedCurrency,
          startDate: _selectedDueDate,
          anchorDay: anchorDay,
          remindDaysBefore: remindDays,
        );

        final todayDate = DateTime(
          RitmController.today.year,
          RitmController.today.month,
          RitmController.today.day,
        );
        final dueOnly = DateTime(
          _selectedDueDate.year,
          _selectedDueDate.month,
          _selectedDueDate.day,
        );
        final diffDays = dueOnly.difference(todayDate).inDays;
        final toastMsg = (diffDays <= remindDays && diffDays >= 0)
            ? 'Платёж добавлен · напоминание отправлено сразу'
            : 'Регулярный платёж добавлен';

        await widget.onCompleted(
          createdTemplate,
          name,
          _selectedCategory,
          toastMsg,
        );
        if (!mounted) return;
        Navigator.of(context).pop();
      }
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
        _errorText = 'Не удалось сохранить платёж на сервере.';
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
                color: Color(0x3D000000),
                blurRadius: 36,
                offset: Offset(0, -10),
              ),
            ],
          ),
          child: SingleChildScrollView(
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
                            _isEditMode
                                ? 'Изменить платёж'
                                : 'Новый регулярный платёж',
                            style: TextStyle(
                              color: p.ink,
                              fontSize: 18,
                              fontWeight: FontWeight.w800,
                              letterSpacing: -0.4,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            _isEditMode
                                ? 'История прошлых и просроченных счетов не перезаписывается. Изменения применятся к будущим периодам.'
                                : 'Укажите название, сумму, валюту и ближайший срок оплаты.',
                            style: TextStyle(
                              color: p.muted,
                              fontSize: 12,
                              height: 1.45,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                    _ModalCloseButton(
                      palette: p,
                      onTap: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),

                if (_isLoadingTemplate) ...[
                  const SizedBox(height: 12),
                  LinearProgressIndicator(
                    minHeight: 2.2,
                    color: p.accent,
                    backgroundColor: p.line,
                  ),
                ],

                const SizedBox(height: 16),
                _FormFieldLabel(
                  palette: p,
                  label: 'Название регулярного платежа',
                ),
                const SizedBox(height: 6),
                _ModalTextInput(
                  palette: p,
                  controller: _nameCtrl,
                  hintText: 'Например, аренда офиса',
                ),
                const SizedBox(height: 12),

                // Сумма + Валюта
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _FormFieldLabel(palette: p, label: 'Сумма'),
                          const SizedBox(height: 6),
                          _ModalTextInput(
                            palette: p,
                            controller: _amountCtrl,
                            hintText: '0.00',
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 11),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _FormFieldLabel(palette: p, label: 'Валюта'),
                          const SizedBox(height: 6),
                          _ModalDropdownField<CurrencyCode>(
                            palette: p,
                            value: _selectedCurrency,
                            items: const [
                              DropdownMenuItem(
                                value: CurrencyCode.rub,
                                child: Text('RUB · рубль'),
                              ),
                              DropdownMenuItem(
                                value: CurrencyCode.usd,
                                child: Text('USD · доллар'),
                              ),
                              DropdownMenuItem(
                                value: CurrencyCode.eur,
                                child: Text('EUR · евро'),
                              ),
                            ],
                            onChanged: (val) {
                              if (val != null) {
                                setState(() => _selectedCurrency = val);
                              }
                            },
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),

                // Дата ближайшей оплаты + Категория
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _FormFieldLabel(
                            palette: p,
                            label: 'Дата ближайшей оплаты',
                          ),
                          const SizedBox(height: 6),
                          GestureDetector(
                            onTap: _pickDueDate,
                            child: MouseRegion(
                              cursor: SystemMouseCursors.click,
                              child: Container(
                                height: 42,
                                padding:
                                const EdgeInsets.symmetric(horizontal: 10),
                                decoration: BoxDecoration(
                                  color: p.page,
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(
                                    color: _userChangedDueDatePicker
                                        ? p.accent
                                        : p.line,
                                  ),
                                ),
                                alignment: Alignment.centerLeft,
                                child: Row(
                                  mainAxisAlignment:
                                  MainAxisAlignment.spaceBetween,
                                  children: [
                                    Text(
                                      RitmFormatters.isoDate(_selectedDueDate),
                                      style: TextStyle(
                                        color: p.ink,
                                        fontSize: 12.5,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    Icon(
                                      Icons.calendar_today_outlined,
                                      size: 15,
                                      color: p.muted,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 11),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _FormFieldLabel(palette: p, label: 'Категория'),
                          const SizedBox(height: 6),
                          _ModalDropdownField<String>(
                            palette: p,
                            value: _selectedCategory,
                            items: _categories
                                .map(
                                  (cat) => DropdownMenuItem(
                                value: cat,
                                child: Text(
                                  cat,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            )
                                .toList(),
                            onChanged: (val) {
                              if (val != null) {
                                setState(() => _selectedCategory = val);
                              }
                            },
                          ),
                        ],
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 11),
                Text(
                  'Платёж повторяется ежемесячно. Напоминание в Telegram отправляется за 3 дня до срока.',
                  style: TextStyle(
                    color: p.muted,
                    fontSize: 11.5,
                    height: 1.4,
                  ),
                ),

                if (_errorText != null) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(11),
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
                        height: 1.35,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],

                const SizedBox(height: 17),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    _ModalButton(
                      palette: p,
                      label: 'Отмена',
                      isPrimary: false,
                      onTap: _isSubmitting
                          ? () {}
                          : () => Navigator.of(context).pop(),
                    ),
                    const SizedBox(width: 8),
                    _ModalButton(
                      palette: p,
                      label: _isEditMode ? 'Сохранить' : 'Добавить платёж',
                      isPrimary: true,
                      isLoading: _isSubmitting,
                      onTap: (_isSubmitting || _isLoadingTemplate)
                          ? () {}
                          : _submitForm,
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
// РАЗДЕЛ 6: ДИАЛОГ ПРЕКРАЩЕНИЯ И ПОЛНОГО УДАЛЕНИЯ ПЛАТЕЖА
// ============================================================================

class _DeleteRecurringDialog extends StatefulWidget {
  final RitmController controller;
  final PaymentItem item;
  final int recurringPaymentId;
  final bool isAlreadyStopped;
  final Future<void> Function(
      DeleteRecurringResultDto result,
      String toastMessage,
      ) onDeleted;

  const _DeleteRecurringDialog({
    required this.controller,
    required this.item,
    required this.recurringPaymentId,
    required this.isAlreadyStopped,
    required this.onDeleted,
  });

  @override
  State<_DeleteRecurringDialog> createState() => _DeleteRecurringDialogState();
}

class _DeleteRecurringDialogState extends State<_DeleteRecurringDialog> {
  bool _confirmingPermanent = false;
  bool _isSubmitting = false;
  String? _errorText;

  /// Выполнение DELETE /api/v1/recurring-payments/{id} (permanent = false или true)
  Future<void> _executeDelete({required bool permanent}) async {
    setState(() {
      _isSubmitting = true;
      _errorText = null;
    });

    try {
      final result = await RecurringPaymentsApi.delete(
        paymentId: widget.recurringPaymentId,
        permanent: permanent,
      );

      final toastMessage = result.permanent
          ? 'Платёж удалён навсегда'
          : 'Платёж прекращён · история оплат сохранена';

      await widget.onDeleted(result, toastMessage);
      if (!mounted) return;
      Navigator.of(context).pop();
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
        if (e.statusCode == 409) {
          _confirmingPermanent = true;
        }
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _errorText = 'Ошибка при удалении платежа на сервере.';
        _isSubmitting = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.controller.palette;

    return Center(
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: 376,
          margin: const EdgeInsets.symmetric(horizontal: 20),
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: p.surface,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(
              color: p.isDark ? p.accent.withValues(alpha: 0.28) : p.line,
            ),
            boxShadow: const [
              BoxShadow(
                color: Color(0x45000000),
                blurRadius: 38,
                offset: Offset(0, 14),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Text(
                      _confirmingPermanent
                          ? 'Удалить навсегда?'
                          : 'Управление платежом',
                      style: TextStyle(
                        color: p.ink,
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.4,
                      ),
                    ),
                  ),
                  _ModalCloseButton(
                    palette: p,
                    onTap: _isSubmitting
                        ? () {}
                        : () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 10),

              // Название и сумма выбранного платежа
              Container(
                padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: p.surfaceSoft,
                  borderRadius: BorderRadius.circular(11),
                  border: Border.all(color: p.line),
                ),
                child: Text(
                  '${widget.item.name} · ${widget.item.formattedAmount}',
                  style: TextStyle(
                    color: p.ink,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(height: 12),

              if (!_confirmingPermanent) ...[
                Text(
                  widget.isAlreadyStopped
                      ? 'Этот регулярный платёж уже прекращён. Вы можете полностью удалить его вместе с историей.'
                      : 'Выберите действие:\n«Прекратить» — новые счета и напоминания больше не создаются, но вся история оплат сохраняется.\n«Удалить навсегда» — убирает платёж, созданный по ошибке, вместе со всеми его периодами.',
                  style: TextStyle(
                    color: p.muted,
                    fontSize: 12.5,
                    height: 1.45,
                  ),
                ),
              ] else ...[
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: p.warningSoft,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: p.warningLine),
                  ),
                  child: Text(
                    'Платёж и вся история его оплат будут удалены без возможности восстановления.',
                    style: TextStyle(
                      color: p.warning,
                      fontSize: 13,
                      height: 1.4,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],

              if (_errorText != null) ...[
                const SizedBox(height: 10),
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

              const SizedBox(height: 18),
              if (!_confirmingPermanent) ...[
                if (!widget.isAlreadyStopped) ...[
                  _ModalButton(
                    palette: p,
                    label: 'Прекратить (сохранить историю)',
                    isPrimary: true,
                    isLoading: _isSubmitting,
                    onTap: _isSubmitting
                        ? () {}
                        : () => _executeDelete(permanent: false),
                  ),
                  const SizedBox(height: 8),
                ],
                _ModalButton(
                  palette: p,
                  label: 'Удалить навсегда',
                  isPrimary: false,
                  isDanger: true,
                  onTap: _isSubmitting
                      ? () {}
                      : () => setState(() => _confirmingPermanent = true),
                ),
                const SizedBox(height: 8),
                _ModalButton(
                  palette: p,
                  label: 'Отмена',
                  isPrimary: false,
                  onTap: _isSubmitting
                      ? () {}
                      : () => Navigator.of(context).pop(),
                ),
              ] else ...[
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    _ModalButton(
                      palette: p,
                      label: 'Назад',
                      isPrimary: false,
                      onTap: _isSubmitting
                          ? () {}
                          : () => setState(() => _confirmingPermanent = false),
                    ),
                    const SizedBox(width: 8),
                    _ModalButton(
                      palette: p,
                      label: 'Удалить навсегда',
                      isPrimary: true,
                      isDanger: true,
                      isLoading: _isSubmitting,
                      onTap: _isSubmitting
                          ? () {}
                          : () => _executeDelete(permanent: true),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================================================
// РАЗДЕЛ 7: КНОПКИ, ПОЛЯ ФОРМ И ВЕКТОРНЫЕ ИКОНКИ
// ============================================================================

class _FormFieldLabel extends StatelessWidget {
  final RitmPalette palette;
  final String label;

  const _FormFieldLabel({required this.palette, required this.label});

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: TextStyle(
        color: palette.muted,
        fontSize: 11,
        fontWeight: FontWeight.w700,
      ),
    );
  }
}

class _ModalTextInput extends StatefulWidget {
  final RitmPalette palette;
  final TextEditingController controller;
  final String hintText;
  final TextInputType keyboardType;

  const _ModalTextInput({
    required this.palette,
    required this.controller,
    required this.hintText,
    this.keyboardType = TextInputType.text,
  });

  @override
  State<_ModalTextInput> createState() => _ModalTextInputState();
}

class _ModalTextInputState extends State<_ModalTextInput> {
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
      decoration: BoxDecoration(
        color: p.page,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: focused ? p.accent : p.line,
        ),
        boxShadow: focused
            ? [
          BoxShadow(
            color: p.accentSoft,
            spreadRadius: 3,
          ),
        ]
            : null,
      ),
      child: TextField(
        controller: widget.controller,
        focusNode: _focusNode,
        keyboardType: widget.keyboardType,
        style: TextStyle(
          color: p.ink,
          fontSize: 13,
          fontWeight: FontWeight.w500,
        ),
        decoration: InputDecoration(
          hintText: widget.hintText,
          hintStyle: TextStyle(
            color: p.faint,
            fontSize: 12.5,
          ),
          border: InputBorder.none,
          contentPadding:
          const EdgeInsets.symmetric(horizontal: 11, vertical: 11),
        ),
      ),
    );
  }
}

class _ModalDropdownField<T> extends StatelessWidget {
  final RitmPalette palette;
  final T value;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?> onChanged;

  const _ModalDropdownField({
    required this.palette,
    required this.value,
    required this.items,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final p = palette;
    return Container(
      height: 42,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: p.page,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: p.line),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          isExpanded: true,
          dropdownColor: p.surface,
          icon: Icon(
            Icons.keyboard_arrow_down_rounded,
            color: p.muted,
            size: 18,
          ),
          style: TextStyle(
            color: p.ink,
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
          ),
          items: items,
          onChanged: onChanged,
        ),
      ),
    );
  }
}

class _ModalCloseButton extends StatelessWidget {
  final RitmPalette palette;
  final VoidCallback onTap;

  const _ModalCloseButton({
    required this.palette,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Container(
          width: 31,
          height: 31,
          decoration: BoxDecoration(
            color: palette.page,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: palette.line),
          ),
          alignment: Alignment.center,
          child: Text(
            '×',
            style: TextStyle(
              color: palette.muted,
              fontSize: 18,
              height: 1.0,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}

class _ModalButton extends StatefulWidget {
  final RitmPalette palette;
  final String label;
  final bool isPrimary;
  final bool isDanger;
  final bool isLoading;
  final VoidCallback onTap;

  const _ModalButton({
    required this.palette,
    required this.label,
    required this.isPrimary,
    this.isDanger = false,
    this.isLoading = false,
    required this.onTap,
  });

  @override
  State<_ModalButton> createState() => _ModalButtonState();
}

class _ModalButtonState extends State<_ModalButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final Color bg = widget.isDanger
        ? (widget.isPrimary ? p.warning : p.warningSoft)
        : (widget.isPrimary
        ? (_hovered ? p.accentStrong : p.accent)
        : (_hovered ? p.surfaceSoft : p.surface));
    final Color fg = widget.isDanger
        ? (widget.isPrimary ? Colors.white : p.warning)
        : (widget.isPrimary ? p.onAccent : p.ink);
    final Color border = widget.isDanger
        ? (widget.isPrimary ? p.warning : p.warningLine)
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

class _IconSquareButton extends StatefulWidget {
  final RitmPalette palette;
  final double size;
  final double borderRadius;
  final VoidCallback onTap;
  final String? tooltip;
  final Widget child;

  const _IconSquareButton({
    required this.palette,
    required this.size,
    required this.borderRadius,
    required this.onTap,
    this.tooltip,
    required this.child,
  });

  @override
  State<_IconSquareButton> createState() => _IconSquareButtonState();
}

class _IconSquareButtonState extends State<_IconSquareButton> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final btn = MouseRegion(
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
            width: widget.size,
            height: widget.size,
            decoration: BoxDecoration(
              color: _hovered ? p.surfaceSoft : p.surface,
              borderRadius: BorderRadius.circular(widget.borderRadius),
              border: Border.all(color: p.line),
            ),
            alignment: Alignment.center,
            child: widget.child,
          ),
        ),
      ),
    );

    if (widget.tooltip != null) {
      return Tooltip(message: widget.tooltip!, child: btn);
    }
    return btn;
  }
}

class _TinyAdminActionButton extends StatefulWidget {
  final RitmPalette palette;
  final String tooltip;
  final VoidCallback onTap;
  final Widget child;

  const _TinyAdminActionButton({
    required this.palette,
    required this.tooltip,
    required this.onTap,
    required this.child,
  });

  @override
  State<_TinyAdminActionButton> createState() => _TinyAdminActionButtonState();
}

class _TinyAdminActionButtonState extends State<_TinyAdminActionButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
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
              border: Border.all(
                color: _hovered ? p.lineStrong : p.line,
              ),
            ),
            alignment: Alignment.center,
            child: widget.child,
          ),
        ),
      ),
    );
  }
}

class _PrimaryActionSmallButton extends StatefulWidget {
  final RitmPalette palette;
  final String label;
  final VoidCallback onTap;

  const _PrimaryActionSmallButton({
    required this.palette,
    required this.label,
    required this.onTap,
  });

  @override
  State<_PrimaryActionSmallButton> createState() =>
      _PrimaryActionSmallButtonState();
}

class _PrimaryActionSmallButtonState extends State<_PrimaryActionSmallButton> {
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
            border: Border.all(color: p.accent),
          ),
          alignment: Alignment.center,
          child: Text(
            widget.label,
            style: TextStyle(
              color: p.onAccent,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
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

class _BackChevronPainter extends CustomPainter {
  final Color color;

  const _BackChevronPainter({required this.color});

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

    final path = Path()
      ..moveTo(14.5 * sx, 5.0 * sy)
      ..lineTo(7.5 * sx, 12.0 * sy)
      ..lineTo(14.5 * sx, 19.0 * sy);

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _BackChevronPainter oldDelegate) =>
      oldDelegate.color != color;
}

class _PlusIconPainter extends CustomPainter {
  final Color color;

  const _PlusIconPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final sx = size.width / 24.0;
    final sy = size.height / 24.0;

    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0 * sx
      ..strokeCap = StrokeCap.round;

    canvas.drawLine(
      Offset(12 * sx, 5 * sy),
      Offset(12 * sx, 19 * sy),
      paint,
    );
    canvas.drawLine(
      Offset(5 * sx, 12 * sy),
      Offset(19 * sx, 12 * sy),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant _PlusIconPainter oldDelegate) =>
      oldDelegate.color != color;
}

class _EditPencilIconPainter extends CustomPainter {
  final Color color;

  const _EditPencilIconPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final sx = size.width / 24.0;
    final sy = size.height / 24.0;

    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8 * sx
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final path = Path()
      ..moveTo(4.0 * sx, 16.8 * sy)
      ..lineTo(3.2 * sx, 20.8 * sy)
      ..lineTo(7.2 * sx, 20.0 * sy)
      ..lineTo(19.0 * sx, 8.2 * sy)
      ..lineTo(15.8 * sx, 5.0 * sy)
      ..close();
    canvas.drawPath(path, paint);

    canvas.drawLine(
      Offset(13.8 * sx, 7.0 * sy),
      Offset(17.0 * sx, 10.2 * sy),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant _EditPencilIconPainter oldDelegate) =>
      oldDelegate.color != color;
}

class _ReceiptWaveIconPainter extends CustomPainter {
  final Color color;

  const _ReceiptWaveIconPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final sx = size.width / 24.0;
    final sy = size.height / 24.0;

    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.7 * sx
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final receipt = Path()
      ..moveTo(6 * sx, 3.5 * sy)
      ..lineTo(18 * sx, 3.5 * sy)
      ..lineTo(18 * sx, 20.5 * sy)
      ..lineTo(15 * sx, 18.5 * sy)
      ..lineTo(12 * sx, 20.5 * sy)
      ..lineTo(9 * sx, 18.5 * sy)
      ..lineTo(6 * sx, 20.5 * sy)
      ..close();
    canvas.drawPath(receipt, paint);

    canvas.drawLine(Offset(9 * sx, 8 * sy), Offset(15 * sx, 8 * sy), paint);
    canvas.drawLine(Offset(9 * sx, 12 * sy), Offset(15 * sx, 12 * sy), paint);
    canvas.drawLine(Offset(9 * sx, 16 * sy), Offset(12 * sx, 16 * sy), paint);
  }

  @override
  bool shouldRepaint(covariant _ReceiptWaveIconPainter oldDelegate) =>
      oldDelegate.color != color;
}