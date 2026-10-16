import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../app/theme.dart';
import '../core/api.dart';
import '../core/formatters.dart';
import '../core/models.dart';
import 'async_view.dart';

/// The bell in the top bar: unread count, and a panel of recent
/// notifications (endpoints 51–53).
///
/// The count is polled every minute while the bell is on screen. The bell
/// only exists inside the signed-in shell, so polling stops on sign-out.
class NotificationBell extends StatefulWidget {
  const NotificationBell({super.key});

  static const pollEvery = Duration(seconds: 60);

  @override
  State<NotificationBell> createState() => _NotificationBellState();
}

class _NotificationBellState extends State<NotificationBell> {
  final _api = PrufloApi();
  Timer? _poll;
  int _unread = 0;

  @override
  void initState() {
    super.initState();
    _refreshCount();
    _poll = Timer.periodic(NotificationBell.pollEvery, (_) => _refreshCount());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _refreshCount() async {
    try {
      final page = await _api.notifications(limit: 1);
      if (mounted) setState(() => _unread = page.unreadCount);
    } catch (_) {
      // The badge is a hint; a failed poll keeps the last count.
    }
  }

  Future<void> _open() async {
    final narrow = MediaQuery.sizeOf(context).width < 600;
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black12,
      builder: (dialogContext) => Align(
        alignment: narrow ? Alignment.topCenter : Alignment.topRight,
        child: Padding(
          padding: EdgeInsets.only(
            top: 60,
            right: narrow ? 8 : 24,
            left: narrow ? 8 : 24,
          ),
          child: Material(
            elevation: 8,
            borderRadius: BorderRadius.circular(12),
            clipBehavior: Clip.antiAlias,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: narrow ? double.infinity : 400,
                maxHeight: MediaQuery.sizeOf(dialogContext).height * 0.7,
              ),
              child: NotificationPanel(
                onUnreadChanged: (n) {
                  if (mounted) setState(() => _unread = n);
                },
                onOpen: (link) {
                  Navigator.of(dialogContext).pop();
                  if (link != null && link.startsWith('/')) context.go(link);
                },
              ),
            ),
          ),
        ),
      ),
    );
    _refreshCount();
  }

  @override
  Widget build(BuildContext context) {
    final label = _unread == 0
        ? 'Notifications'
        : 'Notifications, $_unread unread';
    return IconButton(
      tooltip: label,
      onPressed: _open,
      icon: Badge(
        isLabelVisible: _unread > 0,
        label: Text(_unread > 99 ? '99+' : '$_unread'),
        backgroundColor: AppColors.danger,
        child: Icon(
          _unread > 0 ? Icons.notifications : Icons.notifications_none_outlined,
          semanticLabel: label,
        ),
      ),
    );
  }
}

/// The list inside the bell's panel.
class NotificationPanel extends StatefulWidget {
  const NotificationPanel({
    super.key,
    required this.onUnreadChanged,
    required this.onOpen,
  });

  final ValueChanged<int> onUnreadChanged;
  final ValueChanged<String?> onOpen;

  @override
  State<NotificationPanel> createState() => _NotificationPanelState();
}

class _NotificationPanelState extends State<NotificationPanel> {
  final _api = PrufloApi();
  final _items = <AppNotification>[];
  String? _cursor;
  int _unread = 0;
  bool _loading = true;
  bool _loadingMore = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await _api.notifications();
      if (!mounted) return;
      setState(() {
        _items
          ..clear()
          ..addAll(page.items);
        _cursor = page.nextCursor;
        _unread = page.unreadCount;
        _loading = false;
      });
      widget.onUnreadChanged(_unread);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e;
          _loading = false;
        });
      }
    }
  }

  Future<void> _more() async {
    final cursor = _cursor;
    if (cursor == null) return;
    setState(() => _loadingMore = true);
    try {
      final page = await _api.notifications(cursor: cursor);
      if (!mounted) return;
      setState(() {
        _items.addAll(page.items);
        _cursor = page.nextCursor;
        _unread = page.unreadCount;
      });
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  Future<void> _markAll() async {
    try {
      await _api.markAllNotificationsRead();
      if (!mounted) return;
      setState(() {
        for (var i = 0; i < _items.length; i++) {
          _items[i] = _items[i].markedRead();
        }
        _unread = 0;
      });
      widget.onUnreadChanged(0);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _tap(AppNotification n) async {
    if (!n.read) {
      try {
        await _api.markNotificationRead(n.id);
        _unread = (_unread - 1).clamp(0, 1 << 30);
        widget.onUnreadChanged(_unread);
      } catch (_) {
        // Still open it; it stays unread and can be marked later.
      }
    }
    widget.onOpen(n.link);
  }

  @override
  Widget build(BuildContext context) {
    final header = Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
      child: Row(
        children: [
          const Expanded(
            child: Text(
              'Notifications',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
          ),
          if (_unread > 0)
            TextButton(
              onPressed: _markAll,
              child: const Text('Mark all as read'),
            ),
        ],
      ),
    );

    Widget body;
    if (_loading) {
      body = const Padding(
        padding: EdgeInsets.all(32),
        child: Center(
          child: SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2.5),
          ),
        ),
      );
    } else if (_error != null) {
      body = ErrorPanel(message: '$_error', onRetry: _load, compact: true);
    } else if (_items.isEmpty) {
      body = const EmptyPanel(
        icon: Icons.notifications_none_outlined,
        title: 'No notifications yet',
        message: 'Uploads, assignments, reviews and reports show here.',
      );
    } else {
      body = Flexible(
        child: ListView.separated(
          shrinkWrap: true,
          itemCount: _items.length + (_cursor != null ? 1 : 0),
          separatorBuilder: (_, _) => const Divider(height: 1),
          itemBuilder: (context, i) {
            if (i == _items.length) {
              return Padding(
                padding: const EdgeInsets.all(8),
                child: Center(
                  child: TextButton(
                    onPressed: _loadingMore ? null : _more,
                    child: Text(_loadingMore ? 'Loading…' : 'Load more'),
                  ),
                ),
              );
            }
            return _NotificationTile(_items[i], onTap: () => _tap(_items[i]));
          },
        ),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [header, const Divider(height: 1), body],
    );
  }
}

class _NotificationTile extends StatelessWidget {
  const _NotificationTile(this.n, {required this.onTap});
  final AppNotification n;
  final VoidCallback onTap;

  IconData get _icon => switch (n.kind) {
    NotificationKind.evidenceProcessed => Icons.upload_file_outlined,
    NotificationKind.caseAssigned => Icons.assignment_ind_outlined,
    NotificationKind.caseInReview => Icons.fact_check_outlined,
    NotificationKind.reportReady => Icons.description_outlined,
    NotificationKind.weeklySummary => Icons.summarize_outlined,
    null => Icons.notifications_none_outlined,
  };

  @override
  Widget build(BuildContext context) {
    return Material(
      color: n.read
          ? Colors.white
          : AppColors.primarySoft.withValues(alpha: 0.5),
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(_icon, size: 20, color: AppColors.primary),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      n.title,
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: n.read ? FontWeight.w400 : FontWeight.w600,
                      ),
                    ),
                    if (n.body.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        n.body,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12.5,
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ],
                    const SizedBox(height: 4),
                    Text(
                      timeAgo(n.createdAt),
                      style: const TextStyle(
                        fontSize: 11.5,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              if (!n.read)
                Container(
                  margin: const EdgeInsets.only(left: 8, top: 4),
                  width: 8,
                  height: 8,
                  decoration: const BoxDecoration(
                    color: AppColors.primary,
                    shape: BoxShape.circle,
                  ),
                  child: Semantics(label: 'Unread'),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
