import 'dart:ui';
import 'package:flutter/material.dart';
import 'main.dart';

// ============================================================================
// РАЗДЕЛ 1: СЛОЙ API И ДАННЫХ (DTO, Сериализация и Репозиторий Истории)
// ============================================================================

/// DTO-модель одной записи в истории оплат для обмена данными с REST API.
class HistoryRecordDto {
  final String paymentId;
  final int? occurrenceId;
  final String name;
  final double amount;
  final CurrencyCode currency;
  final DateTime paidDate;
  final DateTime dueDate;
  final String authorNote;

  const HistoryRecordDto({
    required this.paymentId,
    this.occurrenceId,
    required this.name,
    required this.amount,
    required this.currency,
    required this.paidDate,
    required this.dueDate,
    this.authorNote = 'Дата указана участником команды',
  });

  /// Парсинг объекта периода оплаты из ответа FastAPI (/api/v1/payment-occurrences)
  factory HistoryRecordDto.fromJson(Map<String, dynamic> json) {
    final currencyStr = (json['currency'] as String? ?? 'RUB').toUpperCase();
    final currencyCode = switch (currencyStr) {
      'USD' => CurrencyCode.usd,
      'EUR' => CurrencyCode.eur,
      _ => CurrencyCode.rub,
    };

    final rawId = json['id'] ?? json['payment_id'];
    final occurrenceId = rawId is int ? rawId : int.tryParse(rawId.toString());

    final rawAmount = json['amount'];
    final parsedAmount = rawAmount is num
        ? rawAmount.toDouble()
        : double.tryParse(rawAmount.toString()) ?? 0.0;

    final dueDateStr = (json['due_date'] as String?) ??
        (json['paid_date'] as String?) ??
        '2026-10-23';
    final paidDateStr = (json['actual_payment_date'] as String?) ??
        (json['paid_date'] as String?) ??
        dueDateStr;

    final paidBy = json['paid_by_username'] as String?;
    final customAuthorNote = json['author_note'] as String?;
    final resolvedNote = customAuthorNote ??
        (paidBy != null && paidBy.isNotEmpty
            ? 'Отметил(а): $paidBy · дата сохранена в истории'
            : 'Дата указана участником команды');

    return HistoryRecordDto(
      paymentId: (json['payment_id'] ?? rawId ?? dueDateStr).toString(),
      occurrenceId: occurrenceId,
      name: json['name'] as String? ?? 'Платёж',
      amount: parsedAmount,
      currency: currencyCode,
      paidDate: DateTime.tryParse(paidDateStr) ?? DateTime(2026, 10, 23),
      dueDate: DateTime.tryParse(dueDateStr) ?? DateTime(2026, 10, 23),
      authorNote: resolvedNote,
    );
  }

  Map<String, dynamic> toJson() => {
    'payment_id': paymentId,
    if (occurrenceId != null) 'id': occurrenceId,
    'name': name,
    'amount': amount,
    'currency': currency.name.toUpperCase(),
    'paid_date': RitmFormatters.isoDate(paidDate),
    'due_date': RitmFormatters.isoDate(dueDate),
    'author_note': authorNote,
  };
}

/// DTO-модель сводки по сохранённым оплатам за месяц
class HistorySummaryDto {
  final int recordsCount;
  final double totalRub;
  final double totalUsd;
  final double totalEur;

  const HistorySummaryDto({
    required this.recordsCount,
    required this.totalRub,
    required this.totalUsd,
    required this.totalEur,
  });

  /// Парсинг ответа FastAPI (/api/v1/payments/summary)
  factory HistorySummaryDto.fromJson(Map<String, dynamic> json) {
    if (json['currencies'] is List) {
      int totalPaidCount = 0;
      double rub = 0.0;
      double usd = 0.0;
      double eur = 0.0;

      for (final item in (json['currencies'] as List)) {
        if (item is Map<String, dynamic>) {
          final curr = (item['currency'] as String? ?? '').toUpperCase();
          final rawPaid = item['paid_amount'];
          final paidAmount = rawPaid is num
              ? rawPaid.toDouble()
              : double.tryParse(rawPaid?.toString() ?? '0') ?? 0.0;
          final paidCount = item['paid_count'] as int? ?? 0;

          totalPaidCount += paidCount;
          if (curr == 'RUB') rub = paidAmount;
          if (curr == 'USD') usd = paidAmount;
          if (curr == 'EUR') eur = paidAmount;
        }
      }

      return HistorySummaryDto(
        recordsCount: totalPaidCount,
        totalRub: rub,
        totalUsd: usd,
        totalEur: eur,
      );
    }

    return HistorySummaryDto(
      recordsCount: json['records_count'] as int? ?? 0,
      totalRub: (json['total_rub'] as num?)?.toDouble() ?? 0.0,
      totalUsd: (json['total_usd'] as num?)?.toDouble() ?? 0.0,
      totalEur: (json['total_eur'] as num?)?.toDouble() ?? 0.0,
    );
  }

  Map<String, dynamic> toJson() => {
    'records_count': recordsCount,
    'total_rub': totalRub,
    'total_usd': totalUsd,
    'total_eur': totalEur,
  };
}

/// Абстрактный интерфейс репозитория истории для работы с API
abstract interface class HistoryRepository {
  Future<List<HistoryRecordDto>> fetchHistoryRecords({
    required int year,
    required int month,
  });

  Future<HistorySummaryDto> fetchHistorySummary({
    required int year,
    required int month,
  });
}

/// Реализация репозитория, выполняющая реальные HTTP-запросы к FastAPI бэкенду
class ApiHistoryRepository implements HistoryRepository {
  const ApiHistoryRepository();

  @override
  Future<List<HistoryRecordDto>> fetchHistoryRecords({
    required int year,
    required int month,
  }) async {
    final firstDay = DateTime(year, month, 1);
    final lastDay = DateTime(year, month + 1, 0);

    await RitmApiService.ensureAuthorized();

    final response = await RitmApiService.getJson(
      '/api/v1/payment-occurrences',
      queryParameters: {
        'status': 'paid',
        'date_from': RitmFormatters.isoDate(firstDay),
        'date_to': RitmFormatters.isoDate(lastDay),
        'sort': '-due_date',
        'limit': '100',
      },
    );

    final rawItems = response['items'];
    if (rawItems is List) {
      final list = rawItems
          .whereType<Map<String, dynamic>>()
          .map(HistoryRecordDto.fromJson)
          .toList();

      list.sort((a, b) => b.paidDate.compareTo(a.paidDate));
      return list;
    }
    return const [];
  }

  @override
  Future<HistorySummaryDto> fetchHistorySummary({
    required int year,
    required int month,
  }) async {
    final firstDay = DateTime(year, month, 1);
    final lastDay = DateTime(year, month + 1, 0);

    await RitmApiService.ensureAuthorized();

    final response = await RitmApiService.getJson(
      '/api/v1/payments/summary',
      queryParameters: {
        'date_from': RitmFormatters.isoDate(firstDay),
        'date_to': RitmFormatters.isoDate(lastDay),
      },
    );

    return HistorySummaryDto.fromJson(response);
  }
}

/// Локальная реализация репозитория (используется как резервный источник от RitmController)
class LocalHistoryRepository implements HistoryRepository {
  final RitmController controller;

  const LocalHistoryRepository(this.controller);

  @override
  Future<List<HistoryRecordDto>> fetchHistoryRecords({
    required int year,
    required int month,
  }) async {
    return controller.historyPaidItemsSorted
        .map(
          (item) => HistoryRecordDto(
        paymentId: item.id,
        occurrenceId: item.occurrenceId,
        name: item.name,
        amount: item.amount,
        currency: item.currency,
        paidDate: item.paidDate ?? item.dueDate,
        dueDate: item.dueDate,
      ),
    )
        .toList();
  }

  @override
  Future<HistorySummaryDto> fetchHistorySummary({
    required int year,
    required int month,
  }) async {
    return HistorySummaryDto(
      recordsCount: controller.paidCount,
      totalRub: controller.paidTotalByCurrency(CurrencyCode.rub),
      totalUsd: controller.paidTotalByCurrency(CurrencyCode.usd),
      totalEur: controller.paidTotalByCurrency(CurrencyCode.eur),
    );
  }
}

/// Расширение контроллера для динамических расчётов на экране «История»
extension RitmHistoryScreenExtension on RitmController {
  List<PaymentItem> get historyPaidItemsSorted {
    final paidItems =
    currentMonthItems.values.where((item) => item.isPaid).toList();

    paidItems.sort((a, b) {
      final dateA = a.paidDate ?? a.dueDate;
      final dateB = b.paidDate ?? b.dueDate;
      final cmp = dateB.compareTo(dateA);
      if (cmp != 0) return cmp;
      return b.day.compareTo(a.day);
    });

    return paidItems;
  }

  double paidTotalByCurrency(CurrencyCode currency) {
    double sum = 0.0;
    for (final item in historyPaidItemsSorted) {
      if (item.currency == currency) {
        sum += item.amount;
      }
    }
    return sum;
  }

  String formattedPaidTotalByCurrency(CurrencyCode currency) {
    final total = paidTotalByCurrency(currency);
    if (total <= 0.001) return '—';
    return RitmFormatters.formatMoney(
      total,
      currency,
      keepTrailingZero:
      currency == CurrencyCode.eur && total != total.roundToDouble(),
    );
  }
}

// ============================================================================
// РАЗДЕЛ 2: ГЛАВНЫЙ ВИДЖЕТ ЭКРАНА «ИСТОРИЯ» С ПОДКЛЮЧЕНИЕМ К СЕРВЕРУ
// ============================================================================

class HistoryScreen extends StatefulWidget {
  final RitmController controller;
  final VoidCallback onBackToHome;
  final ValueChanged<PaymentItem> onOpenPaymentDialog;

  const HistoryScreen({
    super.key,
    required this.controller,
    required this.onBackToHome,
    required this.onOpenPaymentDialog,
  });

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  final ApiHistoryRepository _apiRepository = const ApiHistoryRepository();

  bool _isLoading = false;
  bool _isLocalOffline = false;
  String? _offlineReason;
  String? _apiErrorText;

  List<HistoryRecordDto>? _serverRecords;

  @override
  void initState() {
    super.initState();
    _loadHistoryFromServer();
  }

  /// Загрузка данных истории и сводки с FastAPI сервера
  Future<void> _loadHistoryFromServer({bool isManualRetry = false}) async {
    if (!mounted) return;
    setState(() {
      _isLoading = true;
      _apiErrorText = null;
    });

    try {
      // 1. Проверяем состояние сервера (/api/v1/health)
      await RitmApiService.checkHealth();

      final targetMonth = widget.controller.viewMonth;

      // 2. Запрашиваем с сервера список оплаченных периодов и сводку по валютам
      final results = await Future.wait([
        _apiRepository.fetchHistoryRecords(
          year: targetMonth.year,
          month: targetMonth.month,
        ),
        _apiRepository.fetchHistorySummary(
          year: targetMonth.year,
          month: targetMonth.month,
        ),
      ]);

      if (!mounted) return;

      final records = results[0] as List<HistoryRecordDto>;

      setState(() {
        _serverRecords = records;
        _isLocalOffline = false;
        _offlineReason = null;
        _isLoading = false;
      });

      // Если мы восстановили связь кнопкой «Повторить», обновляем и общий контроллер
      if (isManualRetry || widget.controller.isServerOffline) {
        await widget.controller.loadFromServer(showSuccessToast: isManualRetry);
      }
    } on ServerOfflineException catch (e) {
      if (!mounted) return;
      setState(() {
        _isLocalOffline = true;
        _offlineReason = e.message;
        _isLoading = false;
      });
    } on ApiRequestException catch (e) {
      if (!mounted) return;
      setState(() {
        _isLocalOffline = false;
        _apiErrorText = e.detail;
        _isLoading = false;
      });
      widget.controller.showToast(e.detail, isError: true);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isLocalOffline = true;
        _offlineReason =
        'Не удалось получить историю платежей с сервера. Проверьте подключение и попробуйте снова.';
        _isLoading = false;
      });
    }
  }

  /// Открытие окна редактирования даты оплаты с последующей синхронизацией
  void _handleRecordTap(PaymentItem item) {
    widget.onOpenPaymentDialog(item);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final p = widget.controller.palette;
        final isOffline =
            _isLocalOffline || widget.controller.isServerOffline;
        final offlineMessage = _offlineReason ??
            widget.controller.serverOfflineReason ??
            'Сервер временно недоступен.';

        final errorBannerMessage =
            _apiErrorText ?? widget.controller.apiErrorBanner;

        // Синхронизируем список записей: берём актуальные данные из контроллера,
        // дополняя их примечаниями автора с сервера
        final paidItems = widget.controller.historyPaidItemsSorted;
        final paidCount = paidItems.length;

        final authorNotesByPaymentId = <String, String>{};
        if (_serverRecords != null) {
          for (final rec in _serverRecords!) {
            authorNotesByPaymentId[rec.paymentId] = rec.authorNote;
            if (rec.occurrenceId != null) {
              authorNotesByPaymentId[rec.occurrenceId.toString()] =
                  rec.authorNote;
            }
          }
        }

        return AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          color: p.page,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // --- БЛОК 1: ВЕРХНЯЯ ПАНЕЛЬ ЭКРАНА ИСТОРИИ ---
              _HistoryTopBar(
                palette: p,
                onBackTap: widget.onBackToHome,
              ),

              // Индикатор фоновой синхронизации с сервером
              if (_isLoading && !isOffline)
                LinearProgressIndicator(
                  minHeight: 2.5,
                  color: p.accent,
                  backgroundColor: p.line,
                ),

              // --- ЕСЛИ СЕРВЕР ПОЛНОСТЬЮ ЛЕЖИТ: ЭКРАН ОШИБКИ С КНОПКОЙ «ПОВТОРИТЬ» ---
              if (isOffline)
                Expanded(
                  child: _HistoryServerOfflineView(
                    palette: p,
                    reason: offlineMessage,
                    isRetrying:
                    _isLoading || widget.controller.isInitialLoading,
                    onRetry: () =>
                        _loadHistoryFromServer(isManualRetry: true),
                  ),
                )
              else
              // --- БЛОК 2: ПРОКРУЧИВАЕМАЯ ОБЛАСТЬ КОНТЕНТА (.history-screen-content) ---
                Expanded(
                  child: RefreshIndicator(
                    color: p.accent,
                    backgroundColor: p.surface,
                    onRefresh: () =>
                        _loadHistoryFromServer(isManualRetry: true),
                    child: SingleChildScrollView(
                      physics: const BouncingScrollPhysics(
                        parent: AlwaysScrollableScrollPhysics(),
                      ),
                      padding: const EdgeInsets.fromLTRB(18, 17, 18, 28),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          // Плашка ошибки от сервера (если API вернул ошибку 4xx/5xx)
                          if (errorBannerMessage != null) ...[
                            _HistoryApiErrorBanner(
                              palette: p,
                              message: errorBannerMessage,
                              onRetry: () =>
                                  _loadHistoryFromServer(isManualRetry: true),
                              onDismiss: () {
                                setState(() => _apiErrorText = null);
                                widget.controller.dismissApiErrorBanner();
                              },
                            ),
                            const SizedBox(height: 14),
                          ],

                          // --- Вводный заголовок и описание (.history-screen-intro) ---
                          _HistoryIntroSection(palette: p),
                          const SizedBox(height: 15),

                          // --- Сетка сводки 2x2 по валютам (.history-screen-summary) ---
                          _HistorySummaryGrid(controller: widget.controller),
                          const SizedBox(height: 22),

                          // --- Секция списка записей «Оплаты за октябрь» (.history-detail-section) ---
                          _HistoryRecordsSection(
                            palette: p,
                            paidCount: paidCount,
                            paidItems: paidItems,
                            authorNotesByPaymentId: authorNotesByPaymentId,
                            onItemTap: _handleRecordTap,
                          ),
                          const SizedBox(height: 14),

                          // --- Информационная сноска внизу (.history-screen-note) ---
                          _HistoryBottomNote(palette: p),
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
// РАЗДЕЛ 2.1: ЭКРАН ПАДЕНИЯ СЕРВЕРА И БАННЕР ОШИБКИ API ДЛЯ ИСТОРИИ
// ============================================================================

/// Экран, отображаемый, когда сервер полностью недоступен
class _HistoryServerOfflineView extends StatelessWidget {
  final RitmPalette palette;
  final String reason;
  final bool isRetrying;
  final VoidCallback onRetry;

  const _HistoryServerOfflineView({
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
                width: 66,
                height: 66,
                decoration: BoxDecoration(
                  color: p.warningSoft,
                  shape: BoxShape.circle,
                  border: Border.all(color: p.warningLine),
                ),
                alignment: Alignment.center,
                child: Icon(
                  Icons.cloud_off_rounded,
                  color: p.warning,
                  size: 32,
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
                  'СЕРВЕР НЕДОСТУПЕН',
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
                'Не удалось загрузить историю',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: p.ink,
                  fontSize: 21,
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
              Container(
                width: double.infinity,
                padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: p.surfaceSoft,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: p.line),
                ),
                child: Text(
                  'Адрес: ${RitmApiService.baseUrl}',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: p.inkSoft,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(height: 20),
              _HistoryRetryButton(
                palette: p,
                isRetrying: isRetrying,
                onTap: onRetry,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HistoryRetryButton extends StatefulWidget {
  final RitmPalette palette;
  final bool isRetrying;
  final VoidCallback onTap;

  const _HistoryRetryButton({
    required this.palette,
    required this.isRetrying,
    required this.onTap,
  });

  @override
  State<_HistoryRetryButton> createState() => _HistoryRetryButtonState();
}

class _HistoryRetryButtonState extends State<_HistoryRetryButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: widget.isRetrying
          ? SystemMouseCursors.basic
          : SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.isRetrying ? null : widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          height: 48,
          width: double.infinity,
          decoration: BoxDecoration(
            color: _hovered && !widget.isRetrying ? p.accentStrong : p.accent,
            borderRadius: BorderRadius.circular(13),
          ),
          alignment: Alignment.center,
          child: widget.isRetrying
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
    );
  }
}

/// Баннер ошибки от сервера (когда сервер онлайн, но вернул ошибку в JSON)
class _HistoryApiErrorBanner extends StatelessWidget {
  final RitmPalette palette;
  final String message;
  final VoidCallback onRetry;
  final VoidCallback onDismiss;

  const _HistoryApiErrorBanner({
    required this.palette,
    required this.message,
    required this.onRetry,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
      decoration: BoxDecoration(
        color: palette.warningSoft,
        borderRadius: BorderRadius.circular(14),
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
// РАЗДЕЛ 3: ВНУТРЕННИЕ БЛОКИ И КОМПОНЕНТЫ ЭКРАНА «ИСТОРИЯ»
// ============================================================================

/// Верхняя шапка экрана «История» с чёрно-оранжевым оформлением в тёмной теме
class _HistoryTopBar extends StatefulWidget {
  final RitmPalette palette;
  final VoidCallback onBackTap;

  const _HistoryTopBar({
    required this.palette,
    required this.onBackTap,
  });

  @override
  State<_HistoryTopBar> createState() => _HistoryTopBarState();
}

class _HistoryTopBarState extends State<_HistoryTopBar> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final isDark = p.isDark;

    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: CustomPaint(
          painter: isDark ? const _HistoryDarkOrangeHeaderPainter() : null,
          child: Container(
            padding: const EdgeInsets.fromLTRB(18, 14, 18, 12),
            decoration: BoxDecoration(
              color: isDark
                  ? Colors.transparent
                  : p.page.withValues(alpha: 0.96),
              border: Border(
                bottom: BorderSide(
                  color: isDark ? p.accent.withValues(alpha: 0.22) : p.line,
                ),
              ),
            ),
            child: Row(
              children: [
                // --- БЛОК: Кнопка «Назад» (#history-screen-back) ---
                MouseRegion(
                  onEnter: (_) => setState(() => _hovered = true),
                  onExit: (_) => setState(() => _hovered = false),
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    onTapDown: (_) => setState(() => _pressed = true),
                    onTapUp: (_) => setState(() => _pressed = false),
                    onTapCancel: () => setState(() => _pressed = false),
                    onTap: widget.onBackTap,
                    child: AnimatedScale(
                      scale: _pressed ? 0.94 : 1.0,
                      duration: const Duration(milliseconds: 110),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 150),
                        width: 38,
                        height: 38,
                        decoration: BoxDecoration(
                          color: _hovered
                              ? (isDark ? p.accentSoft : p.surfaceSoft)
                              : (isDark
                              ? const Color(0xFF1A1410)
                              : p.surface),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: isDark
                                ? p.accent.withValues(
                              alpha: _hovered ? 0.45 : 0.26,
                            )
                                : p.line,
                          ),
                        ),
                        alignment: Alignment.center,
                        child: SizedBox(
                          width: 16,
                          height: 16,
                          child: CustomPaint(
                            painter: _HistoryBackArrowPainter(
                              color: isDark && _hovered ? p.accentInk : p.ink,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),

                // --- БЛОК: Заголовок окна (#history-window-title) ---
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'История',
                        style: TextStyle(
                          color: p.ink,
                          fontSize: 18,
                          height: 1.1,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        'Команда · октябрь 2026',
                        style: TextStyle(
                          color: isDark ? p.accentInk : p.muted,
                          fontSize: 12.5,
                          height: 1.1,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Вводный блок описания экрана истории (.history-screen-intro)
class _HistoryIntroSection extends StatelessWidget {
  final RitmPalette palette;

  const _HistoryIntroSection({required this.palette});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 1, vertical: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'ПОДРОБНЫЕ ЗАПИСИ',
            style: TextStyle(
              color: palette.accentInk,
              fontSize: 12,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.3,
            ),
          ),
          const SizedBox(height: 7),
          Text(
            'История оплат',
            style: TextStyle(
              color: palette.ink,
              fontSize: 27,
              height: 1.08,
              letterSpacing: -0.8,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Здесь собраны платежи, которые участники команды отметили как оплаченные. Дата показывает день, указанный при сохранении; сумма остаётся в валюте платежа.',
            style: TextStyle(
              color: palette.muted,
              fontSize: 14,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}

/// Адаптивная сетка 2x2 со сводкой оплаченных сумм по валютам (.history-screen-summary)
class _HistorySummaryGrid extends StatelessWidget {
  final RitmController controller;

  const _HistorySummaryGrid({required this.controller});

  @override
  Widget build(BuildContext context) {
    final p = controller.palette;
    final count = controller.paidCount;
    final countLabel = '$count ${RitmFormatters.pluralPayments(count)}';
    final totalRub = controller.formattedPaidTotalByCurrency(CurrencyCode.rub);
    final totalUsd = controller.formattedPaidTotalByCurrency(CurrencyCode.usd);
    final totalEur = controller.formattedPaidTotalByCurrency(CurrencyCode.eur);

    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= 560;

        if (isWide) {
          return Row(
            children: [
              Expanded(
                child: _HistorySummaryCard(
                  palette: p,
                  label: 'Записей об оплате',
                  value: countLabel,
                ),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: _HistorySummaryCard(
                  palette: p,
                  label: 'В рублях',
                  value: totalRub,
                ),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: _HistorySummaryCard(
                  palette: p,
                  label: 'В долларах',
                  value: totalUsd,
                ),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: _HistorySummaryCard(
                  palette: p,
                  label: 'В евро',
                  value: totalEur,
                ),
              ),
            ],
          );
        }

        return Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: _HistorySummaryCard(
                    palette: p,
                    label: 'Записей об оплате',
                    value: countLabel,
                  ),
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: _HistorySummaryCard(
                    palette: p,
                    label: 'В рублях',
                    value: totalRub,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 9),
            Row(
              children: [
                Expanded(
                  child: _HistorySummaryCard(
                    palette: p,
                    label: 'В долларах',
                    value: totalUsd,
                  ),
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: _HistorySummaryCard(
                    palette: p,
                    label: 'В евро',
                    value: totalEur,
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}

/// Отдельная карточка в сводке истории (.history-summary-card)
class _HistorySummaryCard extends StatelessWidget {
  final RitmPalette palette;
  final String label;
  final String value;

  const _HistorySummaryCard({
    required this.palette,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: palette.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: palette.muted,
              fontSize: 12.5,
              height: 1.35,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 6),
          SizedBox(
            height: 20,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                child: Text(
                  value,
                  key: ValueKey(value),
                  style: TextStyle(
                    color: palette.ink,
                    fontSize: 16.5,
                    height: 1.15,
                    fontWeight: FontWeight.w700,
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

/// Секция со списком карточек оплаченных платежей (.history-detail-section)
class _HistoryRecordsSection extends StatelessWidget {
  final RitmPalette palette;
  final int paidCount;
  final List<PaymentItem> paidItems;
  final Map<String, String> authorNotesByPaymentId;
  final ValueChanged<PaymentItem> onItemTap;

  const _HistoryRecordsSection({
    required this.palette,
    required this.paidCount,
    required this.paidItems,
    required this.authorNotesByPaymentId,
    required this.onItemTap,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // --- БЛОК: Заголовок секции и количество записей ---
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'Оплаты за октябрь',
              style: TextStyle(
                color: palette.ink,
                fontSize: 20,
                height: 1.2,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.35,
              ),
            ),
            Text(
              '$paidCount ${RitmFormatters.pluralPayments(paidCount)}',
              style: TextStyle(
                color: palette.muted,
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),

        // --- БЛОК: Поясняющий подзаголовок (.history-detail-copy) ---
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2),
          child: Text(
            'Список упорядочен от самой свежей записи к более ранней. В каждой карточке указаны платёж, дата и сумма.',
            style: TextStyle(
              color: palette.muted,
              fontSize: 13,
              height: 1.5,
            ),
          ),
        ),
        const SizedBox(height: 10),

        // --- БЛОК: Список карточек истории (.history-detail-list) ---
        AnimatedSize(
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: paidItems.isEmpty
              ? AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: palette.surface,
              borderRadius: BorderRadius.circular(15),
              border: Border.all(color: palette.line),
            ),
            child: Text(
              'За октябрь пока нет сохранённых записей об оплате. Отметьте любой платёж на главной странице или во вкладке «Платежи», и он появится здесь.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: palette.muted,
                fontSize: 13,
                height: 1.45,
              ),
            ),
          )
              : Column(
            children: List.generate(paidItems.length, (index) {
              final item = paidItems[index];
              final authorNote = authorNotesByPaymentId[item.id] ??
                  (item.occurrenceId != null
                      ? authorNotesByPaymentId[
                  item.occurrenceId.toString()]
                      : null) ??
                  'Дата указана участником команды';

              return Padding(
                padding: EdgeInsets.only(top: index == 0 ? 0 : 9),
                child: _HistoryDetailCard(
                  palette: palette,
                  item: item,
                  authorNote: authorNote,
                  onTap: () => onItemTap(item),
                ),
              );
            }),
          ),
        ),
      ],
    );
  }
}

/// Карточка отдельной записи об оплате (.history-detail-row)
class _HistoryDetailCard extends StatefulWidget {
  final RitmPalette palette;
  final PaymentItem item;
  final String authorNote;
  final VoidCallback onTap;

  const _HistoryDetailCard({
    required this.palette,
    required this.item,
    required this.authorNote,
    required this.onTap,
  });

  @override
  State<_HistoryDetailCard> createState() => _HistoryDetailCardState();
}

class _HistoryDetailCardState extends State<_HistoryDetailCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final paidDate = widget.item.paidDate ?? widget.item.dueDate;
    final dateText = 'Оплачено · ${RitmFormatters.shortDate(paidDate)}';

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: _hovered ? p.surfaceSoft : p.surface,
            borderRadius: BorderRadius.circular(15),
            border: Border.all(
              color: _hovered ? p.lineStrong : p.line,
            ),
            boxShadow: [
              BoxShadow(
                color: p.cardShadow,
                blurRadius: 22,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // --- БЛОК: Иконка с галочкой (.history-detail-check) ---
              AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: p.successSoft,
                  borderRadius: BorderRadius.circular(10),
                ),
                alignment: Alignment.center,
                child: SizedBox(
                  width: 14,
                  height: 14,
                  child: CustomPaint(
                    painter: _HistoryCheckPainter(
                      color: p.success,
                      strokeWidth: 1.7,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),

              // --- БЛОК: Название, дата оплаты и подпись автора (.history-detail-copy) ---
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.item.name,
                      style: TextStyle(
                        color: p.ink,
                        fontSize: 15,
                        height: 1.25,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      dateText,
                      style: TextStyle(
                        color: p.inkSoft,
                        fontSize: 13,
                        height: 1.3,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      widget.authorNote,
                      style: TextStyle(
                        color: p.muted,
                        fontSize: 12,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),

              // --- БЛОК: Сумма платежа (.history-detail-amount) ---
              Text(
                widget.item.formattedAmount,
                style: TextStyle(
                  color: p.ink,
                  fontSize: 15,
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

/// Поясняющая карточка в нижней части экрана (.history-screen-note)
class _HistoryBottomNote extends StatelessWidget {
  final RitmPalette palette;

  const _HistoryBottomNote({required this.palette});

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: palette.infoSoft, width: 1.2),
      ),
      child: RichText(
        text: TextSpan(
          style: TextStyle(
            color: palette.inkSoft,
            fontSize: 13,
            height: 1.5,
          ),
          children: [
            TextSpan(
              text: 'Что хранится в истории: ',
              style: TextStyle(
                color: palette.ink,
                fontWeight: FontWeight.w700,
              ),
            ),
            const TextSpan(
              text:
              'запись участника команды и указанная им фактическая дата. Эта отметка сама по себе не подтверждает перевод со стороны банка.',
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================================
// РАЗДЕЛ 4: ВЕКТОРНЫЕ ИКОНКИ И ФОН ШАПКИ ЭКРАНА «ИСТОРИЯ» (CustomPainter)
// ============================================================================

/// Чёрно-оранжевый градиент верхней панели на экране «История»
class _HistoryDarkOrangeHeaderPainter extends CustomPainter {
  const _HistoryDarkOrangeHeaderPainter();

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
        radius: 1.2,
        colors: [
          const Color(0xFFFF7014).withValues(alpha: 0.22),
          Colors.transparent,
        ],
      ).createShader(rect);
    canvas.drawRect(rect, glowPaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _HistoryBackArrowPainter extends CustomPainter {
  final Color color;

  const _HistoryBackArrowPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final sx = size.width / 16.0;
    final sy = size.height / 16.0;

    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6 * sx
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final chevron = Path()
      ..moveTo(10.0 * sx, 3.5 * sy)
      ..lineTo(5.0 * sx, 8.0 * sy)
      ..lineTo(10.0 * sx, 12.5 * sy);

    canvas.drawPath(chevron, paint);
    canvas.drawLine(
      Offset(5.5 * sx, 8.0 * sy),
      Offset(14.0 * sx, 8.0 * sy),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant _HistoryBackArrowPainter oldDelegate) =>
      oldDelegate.color != color;
}

class _HistoryCheckPainter extends CustomPainter {
  final Color color;
  final double strokeWidth;

  const _HistoryCheckPainter({
    required this.color,
    required this.strokeWidth,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final sx = size.width / 14.0;
    final sy = size.height / 14.0;

    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth * sx
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final path = Path()
      ..moveTo(2.8 * sx, 7.2 * sy)
      ..lineTo(5.4 * sx, 9.7 * sy)
      ..lineTo(11.2 * sx, 3.9 * sy);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _HistoryCheckPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.strokeWidth != strokeWidth;
}