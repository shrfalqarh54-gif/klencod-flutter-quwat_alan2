import 'dart:ui' show DartPluginRegistrant;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;
import '../models/task_item.dart';
import 'task_store.dart';

const String kChannelId = 'quwat_tasks_v2';
const String kActionComplete = 'complete';
const String kActionSnooze = 'snooze';

/// يُستدعى من نظام أندرويد عند الضغط على زر في الإشعار والتطبيق مغلق.
/// يجب أن تكون الدالة على مستوى الملف (top-level) مع هذه الإشارة.
@pragma('vm:entry-point')
Future<void> notificationTapBackground(NotificationResponse response) async {
  DartPluginRegistrant.ensureInitialized();
  await NotificationService.handleResponse(response);
}

class NotificationService {
  static final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
  static const MethodChannel _channel = MethodChannel('com.quwatalan.app/system_settings');

  /// معرّف المهمة التي ضغط المستخدم على "لاحقاً" لها (تستمع له الشاشة الرئيسية).
  static final ValueNotifier<String?> pendingSnoozeTaskId = ValueNotifier<String?>(null);

  static AndroidFlutterLocalNotificationsPlugin? get _android =>
      _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();

  static Future<void> init() async {
    tzdata.initializeTimeZones();
    try {
      final name = await _channel.invokeMethod<String>('getTimeZone');
      if (name != null && name.isNotEmpty) {
        tz.setLocalLocation(tz.getLocation(name));
      }
    } catch (_) {}

    const settings = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    );

    await _plugin.initialize(
      settings,
      onDidReceiveNotificationResponse: (r) {
        handleResponse(r);
      },
      onDidReceiveBackgroundNotificationResponse: notificationTapBackground,
    );

    await _android?.createNotificationChannel(
      const AndroidNotificationChannel(
        kChannelId,
        'تنبيهات المهام',
        description: 'قناة إشعارات بدء المهام',
        importance: Importance.max,
      ),
    );

    // التطبيق فُتح من الإشعار وهو مغلق
    final launch = await _plugin.getNotificationAppLaunchDetails();
    if (launch?.didNotificationLaunchApp == true && launch!.notificationResponse != null) {
      await handleResponse(launch.notificationResponse!);
    }
  }

  static Future<void> requestPermissions() async {
    final android = _android;
    if (android == null) return;
    try {
      await android.requestNotificationsPermission();
    } catch (_) {}
    try {
      final canExact = await android.canScheduleExactNotifications();
      if (canExact != true) {
        await android.requestExactAlarmsPermission();
      }
    } catch (_) {}
  }

  static Future<void> handleResponse(NotificationResponse response) async {
    final taskId = response.payload;
    if (taskId == null || taskId.isEmpty) return;

    if (response.actionId == kActionComplete) {
      await TaskStore.init();
      await TaskStore.markDone(taskId, DateTime.now());
    } else if (response.actionId == kActionSnooze) {
      pendingSnoozeTaskId.value = taskId;
    }
  }

  // ---------- الجدولة ----------

  static int _baseId(String id) {
    final n = int.tryParse(id) ?? id.hashCode;
    return (n.abs() % 100000000) * 10;
  }

  static NotificationDetails _details() {
    return NotificationDetails(
      android: AndroidNotificationDetails(
        kChannelId,
        'تنبيهات المهام',
        channelDescription: 'قناة إشعارات بدء المهام',
        importance: Importance.max,
        priority: Priority.high,
        category: AndroidNotificationCategory.reminder,
        actions: const <AndroidNotificationAction>[
          AndroidNotificationAction(
            kActionComplete,
            'إتمام المهمة',
            showsUserInterface: false,
            cancelNotification: true,
          ),
          AndroidNotificationAction(
            kActionSnooze,
            'لاحقاً',
            showsUserInterface: true,
            cancelNotification: true,
          ),
        ],
      ),
    );
  }

  static tz.TZDateTime _nextAt(DateTime time, {DateTime? notBefore, int? weekday}) {
    final now = tz.TZDateTime.now(tz.local);
    var first = tz.TZDateTime(tz.local, now.year, now.month, now.day, time.hour, time.minute);
    if (notBefore != null) {
      final nb = tz.TZDateTime(tz.local, notBefore.year, notBefore.month, notBefore.day, time.hour, time.minute);
      if (nb.isAfter(first)) first = nb;
    }
    for (var i = 0; i < 16; i++) {
      final cand = tz.TZDateTime(tz.local, first.year, first.month, first.day + i, time.hour, time.minute);
      if (!cand.isAfter(now)) continue;
      if (weekday != null && cand.weekday != weekday) continue;
      return cand;
    }
    return first.add(const Duration(days: 1));
  }

  static Future<void> _zoned(int id, TaskItem task, tz.TZDateTime when, DateTimeComponents? match) async {
    Future<void> go(AndroidScheduleMode mode) {
      return _plugin.zonedSchedule(
        id,
        'حان موعد المهمة 💪',
        task.title,
        when,
        _details(),
        androidScheduleMode: mode,
        uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime,
        matchDateTimeComponents: match,
        payload: task.id,
      );
    }

    try {
      await go(AndroidScheduleMode.exactAllowWhileIdle);
    } catch (_) {
      // لو لم تُمنح صلاحية المنبهات الدقيقة نستخدم الجدولة التقريبية
      try {
        await go(AndroidScheduleMode.inexactAllowWhileIdle);
      } catch (_) {}
    }
  }

  static Future<void> scheduleTask(TaskItem task) async {
    await cancelTask(task.id);
    final base = _baseId(task.id);

    switch (task.recurrence) {
      case Recurrence.none:
        if (task.isCompleted || !task.startTime.isAfter(DateTime.now())) return;
        await _zoned(base, task, tz.TZDateTime.from(task.startTime, tz.local), null);
        break;
      case Recurrence.daily:
        await _zoned(
          base,
          task,
          _nextAt(task.startTime, notBefore: task.startTime),
          DateTimeComponents.time,
        );
        break;
      case Recurrence.weekly:
        for (final d in task.weekdays) {
          await _zoned(
            base + d,
            task,
            _nextAt(task.startTime, notBefore: task.startTime, weekday: d),
            DateTimeComponents.dayOfWeekAndTime,
          );
        }
        break;
    }
  }

  /// إشعار لمرة واحدة (تأجيل مهمة متكررة دون تغيير تكرارها)
  static Future<void> scheduleOneOff(TaskItem task, DateTime when) async {
    await _plugin.cancel(_baseId(task.id) + 8);
    if (!when.isAfter(DateTime.now())) return;
    await _zoned(_baseId(task.id) + 8, task, tz.TZDateTime.from(when, tz.local), null);
  }

  static Future<void> cancelTask(String taskId) async {
    final base = _baseId(taskId);
    for (var i = 0; i < 10; i++) {
      await _plugin.cancel(base + i);
    }
  }
}
