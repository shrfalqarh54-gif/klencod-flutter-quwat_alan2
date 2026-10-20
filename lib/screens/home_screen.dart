import 'package:flutter/material.dart';
import '../models/task_item.dart';
import '../services/notification_service.dart';
import '../services/task_store.dart';
import 'assistant_screen.dart';
import 'settings_screen.dart';
import 'task_editor.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  List<TaskItem> _tasks = [];
  bool _isLoading = true;
  bool _snoozeOpen = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    TaskStore.changes.addListener(_loadTasks);
    NotificationService.pendingSnoozeTaskId.addListener(_checkSnooze);
    _loadTasks();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      _checkSnooze();
      await NotificationService.requestPermissions();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    TaskStore.changes.removeListener(_loadTasks);
    NotificationService.pendingSnoozeTaskId.removeListener(_checkSnooze);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _onResumed();
    }
  }

  Future<void> _onResumed() async {
    // قد تكون مهمة أُنجزت من زر الإشعار في الخلفية
    await TaskStore.reload();
    _checkSnooze();
  }

  void _loadTasks() {
    if (!mounted) return;
    setState(() {
      _tasks = List<TaskItem>.from(TaskStore.getAllTasks());
      _isLoading = false;
    });
  }

  // ---------- التأجيل (زر "لاحقاً") ----------

  Future<void> _checkSnooze() async {
    final id = NotificationService.pendingSnoozeTaskId.value;
    if (id == null || _snoozeOpen || !mounted) return;
    NotificationService.pendingSnoozeTaskId.value = null;
    final task = TaskStore.getById(id);
    if (task == null) return;
    _snoozeOpen = true;
    await _showSnoozeSheet(task);
    _snoozeOpen = false;
  }

  Future<void> _showSnoozeSheet(TaskItem task) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'هل تريد تأجيل المهمة "${task.title}" إلى:',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.timer_outlined),
              title: const Text('بعد ساعة'),
              onTap: () => Navigator.pop(ctx, 'hour'),
            ),
            ListTile(
              leading: const Icon(Icons.wb_sunny_outlined),
              title: const Text('الغد'),
              onTap: () => Navigator.pop(ctx, 'tomorrow'),
            ),
            ListTile(
              leading: const Icon(Icons.date_range_outlined),
              title: const Text('بعد أسبوع'),
              onTap: () => Navigator.pop(ctx, 'week'),
            ),
            ListTile(
              leading: const Icon(Icons.edit_calendar_outlined),
              title: const Text('تخصيص (اختيار وقت وتاريخ)'),
              onTap: () => Navigator.pop(ctx, 'custom'),
            ),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;

    final now = DateTime.now();
    DateTime? newStart;
    switch (choice) {
      case 'hour':
        newStart = now.add(const Duration(hours: 1));
        break;
      case 'tomorrow':
        newStart = DateTime(now.year, now.month, now.day + 1, task.startTime.hour, task.startTime.minute);
        break;
      case 'week':
        newStart = now.add(const Duration(days: 7));
        break;
      case 'custom':
        final date = await showDatePicker(
          context: context,
          initialDate: now,
          firstDate: DateTime(now.year, now.month, now.day),
          lastDate: DateTime(now.year + 2),
        );
        if (date == null || !mounted) return;
        final time = await showTimePicker(
          context: context,
          initialTime: TimeOfDay.fromDateTime(now.add(const Duration(hours: 1))),
        );
        if (time == null) return;
        newStart = DateTime(date.year, date.month, date.day, time.hour, time.minute);
        break;
    }
    if (newStart == null) return;
    await _applySnooze(task, newStart);
  }

  Future<void> _applySnooze(TaskItem task, DateTime newStart) async {
    if (task.isRecurring) {
      await NotificationService.scheduleOneOff(task, newStart);
    } else {
      final dur = task.duration;
      task.startTime = newStart;
      task.endTime = newStart.add(dur);
      task.isCompleted = false;
      await TaskStore.saveTask(task);
      await NotificationService.scheduleTask(task);
    }
    _loadTasks();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تم التأجيل إلى ${formatYmd(newStart)} ${formatHm(newStart)}')),
      );
    }
  }

  // ---------- بيانات العرض ----------

  List<TaskItem> get _todayTasks {
    final now = DateTime.now();
    final list = _tasks.where((t) => t.occursOn(now)).toList();
    list.sort((a, b) => a.startOn(now).compareTo(b.startOn(now)));
    return list;
  }

  List<TaskItem> get _laterTasks {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final list = _tasks.where((t) {
      final d = DateTime(t.startTime.year, t.startTime.month, t.startTime.day);
      return !t.isRecurring && !t.isCompleted && d.isAfter(today);
    }).toList();
    list.sort((a, b) => a.startTime.compareTo(b.startTime));
    return list;
  }

  TaskItem? get _currentActiveTask {
    final now = DateTime.now();
    for (final t in _tasks) {
      if (t.isActiveAt(now)) return t;
    }
    return null;
  }

  MapEntry<TaskItem, DateTime>? get _upcoming {
    final now = DateTime.now();
    MapEntry<TaskItem, DateTime>? best;
    for (final t in _tasks) {
      final next = t.nextOccurrenceAfter(now);
      if (next == null) continue;
      if (best == null || next.isBefore(best.value)) {
        best = MapEntry(t, next);
      }
    }
    return best;
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final today = _todayTasks;
    final later = _laterTasks;

    return Scaffold(
      appBar: AppBar(
        title: const Text('قوة الآن 💪'),
        actions: [
          IconButton(
            icon: const Icon(Icons.smart_toy_outlined),
            tooltip: 'المساعد',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const AssistantScreen()),
              ).then((_) => _loadTasks());
            },
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'الإعدادات',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const SettingsScreen()),
              );
            },
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: () async {
                await TaskStore.reload();
              },
              child: ListView(
                padding: const EdgeInsets.all(16.0),
                children: [
                  _buildNowSection(),
                  const SizedBox(height: 16),
                  _buildUpcomingSection(),
                  const SizedBox(height: 20),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'مهام اليوم (${today.length})',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
                      ),
                      Text(
                        'المكتملة: ${today.where((t) => t.isDoneOn(now)).length}',
                        style: const TextStyle(color: Colors.grey, fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                  const Divider(),
                  if (today.isEmpty)
                    const Center(
                      child: Padding(
                        padding: EdgeInsets.symmetric(vertical: 40.0),
                        child: Text(
                          'لا توجد مهام لليوم. ابدأ بإضافة مهمتك الأولى!',
                          style: TextStyle(color: Colors.grey, fontSize: 16),
                        ),
                      ),
                    )
                  else
                    ...today.map((task) => _buildTaskCard(task, now)),
                  if (later.isNotEmpty) ...[
                    const SizedBox(height: 20),
                    Text(
                      'مهام قادمة (${later.length})',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
                    ),
                    const Divider(),
                    ...later.map((task) => _buildTaskCard(task, task.startTime)),
                  ],
                  const SizedBox(height: 80),
                ],
              ),
            ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          final result = await Navigator.push(
            context,
            MaterialPageRoute(builder: (context) => const TaskEditorScreen()),
          );
          if (result == true) _loadTasks();
        },
        label: const Text('إضافة مهمة'),
        icon: const Icon(Icons.add),
        backgroundColor: const Color(0xFF2E7D32),
        foregroundColor: Colors.white,
      ),
    );
  }

  Widget _buildNowSection() {
    final active = _currentActiveTask;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cs = Theme.of(context).colorScheme;
    final activeBg = isDark ? const Color(0xFF1B3A1E) : const Color(0xFFE8F5E9);
    final activeTitle = isDark ? const Color(0xFFA5D6A7) : const Color(0xFF1B5E20);

    return Card(
      color: active != null ? activeBg : cs.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: active != null ? Colors.green : Colors.grey.shade400),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.bolt, color: active != null ? Colors.amber.shade800 : Colors.grey),
                const SizedBox(width: 8),
                Text(
                  'ماذا أفعل الآن؟',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const SizedBox(height: 10),
            if (active != null) ...[
              Text(
                active.title,
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: activeTitle),
              ),
              const SizedBox(height: 4),
              Text('الانتهاء: ${formatHm(active.endOn(DateTime.now()))}'),
            ] else ...[
              const Text(
                'أنت متفرغ الآن! استغل هذا الوقت في التخطيط أو الراحة.',
                style: TextStyle(color: Colors.grey),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildUpcomingSection() {
    final upcoming = _upcoming;
    if (upcoming == null) return const SizedBox.shrink();
    return Card(
      child: ListTile(
        leading: const Icon(Icons.access_time, color: Colors.blue),
        title: Text('المهمة القادمة: ${upcoming.key.title}'),
        subtitle: Text('البدء: ${formatHm(upcoming.value)}'),
      ),
    );
  }

  Widget _buildTaskCard(TaskItem task, DateTime day) {
    final done = task.isDoneOn(day);
    final isToday = TaskItem.dateKey(day) == TaskItem.dateKey(DateTime.now());
    final timeText = '${formatHm(task.startOn(day))} - ${formatHm(task.endOn(day))}';
    final lines = <String>[
      isToday ? timeText : '${formatYmd(day)}  $timeText',
      if (task.isRecurring) task.recurrenceLabel,
      if (task.subTasks.isNotEmpty)
        'المهام الفرعية: ${task.subTasks.where((s) => s.isDone).length}/${task.subTasks.length}',
    ];

    return Card(
      child: Column(
        children: [
          ListTile(
            isThreeLine: lines.length > 2,
            leading: Checkbox(
              value: done,
              activeColor: const Color(0xFF2E7D32),
              onChanged: (val) async {
                task.setDoneOn(day, val ?? false);
                await TaskStore.saveTask(task);
                if (!task.isRecurring) {
                  if (task.isCompleted) {
                    await NotificationService.cancelTask(task.id);
                  } else {
                    await NotificationService.scheduleTask(task);
                  }
                }
                _loadTasks();
              },
            ),
            title: Text(
              task.title,
              style: TextStyle(
                decoration: done ? TextDecoration.lineThrough : null,
                fontWeight: FontWeight.w600,
              ),
            ),
            subtitle: Text(lines.join('\n')),
            trailing: IconButton(
              icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
              onPressed: () async {
                await NotificationService.cancelTask(task.id);
                await TaskStore.deleteTask(task.id);
                _loadTasks();
              },
            ),
            onTap: () async {
              final res = await Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => TaskEditorScreen(task: task)),
              );
              if (res == true) _loadTasks();
            },
          ),
          ...task.subTasks.map(
            (st) => CheckboxListTile(
              dense: true,
              controlAffinity: ListTileControlAffinity.leading,
              contentPadding: const EdgeInsetsDirectional.only(start: 56, end: 16),
              value: st.isDone,
              title: Text(
                st.title,
                style: TextStyle(decoration: st.isDone ? TextDecoration.lineThrough : null),
              ),
              onChanged: (v) async {
                st.isDone = v ?? false;
                await TaskStore.saveTask(task);
                _loadTasks();
              },
            ),
          ),
        ],
      ),
    );
  }
}
