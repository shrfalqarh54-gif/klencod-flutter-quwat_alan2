import 'package:flutter/material.dart';
import 'package:speech_to_text/speech_to_text.dart';
import '../models/task_item.dart';
import '../services/notification_service.dart';
import '../services/task_store.dart';
import '../utils/arabic_parser.dart';

enum _Step { none, title, start, end, repeat }

class AssistantScreen extends StatefulWidget {
  const AssistantScreen({super.key});

  @override
  State<AssistantScreen> createState() => _AssistantScreenState();
}

class _AssistantScreenState extends State<AssistantScreen> {
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scroll = ScrollController();
  final SpeechToText _speech = SpeechToText();
  bool _speechReady = false;
  bool _listening = false;
  String? _localeId;

  // حالة محادثة "أضف مهمة"
  _Step _step = _Step.none;
  String _draftTitle = '';
  DateTime? _draftStart;
  DateTime? _draftEnd;

  final List<Map<String, String>> _messages = [
    {
      'role': 'assistant',
      'text': 'أهلاً بك في "قوة الآن" 💪. أنا مساعدك المحلي. اسألني عن جدولك اليوم، أو قل "أضف مهمة" وسأساعدك في إنشائها. يمكنك أيضاً الضغط على المايكروفون والتحدث.'
    }
  ];

  @override
  void dispose() {
    _speech.stop();
    _controller.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  // ---------- الإدخال الصوتي ----------

  Future<void> _toggleMic() async {
    if (_listening) {
      await _speech.stop();
      if (mounted) setState(() => _listening = false);
      return;
    }

    if (!_speechReady) {
      _speechReady = await _speech.initialize(
        onStatus: (status) {
          if ((status == 'done' || status == 'notListening') && mounted) {
            setState(() => _listening = false);
          }
        },
        onError: (error) {
          if (!mounted) return;
          setState(() => _listening = false);
          _snack('تعذّر التعرف على الصوت. تأكد من الاتصال بالإنترنت وحاول مجدداً.');
        },
      );
      if (!_speechReady) {
        _snack('التعرف الصوتي غير متاح، أو لم تُمنح صلاحية المايكروفون.');
        return;
      }
      try {
        final locales = await _speech.locales();
        for (final l in locales) {
          if (l.localeId.toLowerCase().startsWith('ar')) {
            _localeId = l.localeId;
            break;
          }
        }
      } catch (_) {}
    }

    setState(() => _listening = true);
    await _speech.listen(
      localeId: _localeId,
      listenFor: const Duration(seconds: 30),
      pauseFor: const Duration(seconds: 4),
      onResult: (result) {
        if (!mounted) return;
        setState(() => _controller.text = result.recognizedWords);
        if (result.finalResult) {
          setState(() => _listening = false);
          if (_controller.text.trim().isNotEmpty) _handleSend();
        }
      },
    );
  }

  // ---------- الإرسال والرد ----------

  Future<void> _handleSend() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;

    setState(() {
      _messages.add({'role': 'user', 'text': text});
      _controller.clear();
    });
    _scrollToEnd();

    final response = await _reply(text);
    if (!mounted) return;
    setState(() {
      _messages.add({'role': 'assistant', 'text': response});
    });
    _scrollToEnd();
  }

  void _resetFlow() {
    _step = _Step.none;
    _draftTitle = '';
    _draftStart = null;
    _draftEnd = null;
  }

  Future<String> _reply(String query) async {
    final n = ArabicParser.normalize(query);

    // أثناء جمع بيانات مهمة جديدة
    if (_step != _Step.none) {
      if (RegExp(r'^(الغاء|الغي|الغ|توقف|cancel)').hasMatch(n)) {
        _resetFlow();
        return 'تم إلغاء إضافة المهمة.';
      }
      return _continueFlow(query);
    }

    // بدء إضافة مهمة
    final addMatch = RegExp(
      r'(?:أضف|اضف|أضيف|اضيف|أنشئ|انشئ|إضافة|اضافة)\s*(?:لي\s*)?مهم[ةه]\s*(.*)',
    ).firstMatch(query.trim());
    if (addMatch != null || n.contains('مهمه جديده')) {
      final rest = (addMatch?.group(1) ?? '').trim();
      final restN = ArabicParser.normalize(rest);
      if (rest.isNotEmpty && restN != 'جديده') {
        _draftTitle = rest;
        _step = _Step.start;
        return 'تمام، المهمة: "$rest".\nمتى ستبدأ؟ (مثال: 5 مساءً، أو بعد ساعة)';
      }
      _step = _Step.title;
      return 'بكل سرور! ما عنوان المهمة؟ (للإلغاء اكتب: إلغاء)';
    }

    final tasks = TaskStore.getAllTasks();
    final now = DateTime.now();
    final lower = query.toLowerCase();

    if (lower.contains('مرحبا') || lower.contains('السلام') || lower.contains('أهلا') || lower.contains('اهلا')) {
      return 'أهلاً وسهلاً بك! كيف يمكنني مساعدتك في إدارة وقتك اليوم؟';
    }

    if (lower.contains('الآن') || lower.contains('افعل') || lower.contains('سوي')) {
      for (final t in tasks) {
        if (t.isActiveAt(now)) {
          return 'مهمتك الحالية هي: "${t.title}". تنتهي في تمام الساعة ${formatHm(t.endOn(now))}. ركز وأنجزها!';
        }
      }
      return 'ليس لديك مهمة جارية في هذه اللحظة. يمكنك أخذ استراحة أو مراجعة جدولك القادم.';
    }

    if (lower.contains('القادمة') || lower.contains('بعد') || lower.contains('الجاي')) {
      TaskItem? best;
      DateTime? bestTime;
      for (final t in tasks) {
        final next = t.nextOccurrenceAfter(now);
        if (next != null && (bestTime == null || next.isBefore(bestTime))) {
          best = t;
          bestTime = next;
        }
      }
      if (best != null && bestTime != null) {
        return 'مهمتك القادمة هي "${best.title}" وتبدأ في الساعة ${formatHm(bestTime)}.';
      }
      return 'لا توجد مهام قادمة مجدولة.';
    }

    if (lower.contains('كم') || lower.contains('عدد') || lower.contains('مهام') || lower.contains('اليوم')) {
      final today = tasks.where((t) => t.occursOn(now)).toList();
      final completed = today.where((t) => t.isDoneOn(now)).length;
      return 'مهام اليوم: ${today.length}.\nتم إنجاز: $completed منها.';
    }

    return 'يمكنني إخبارك بما يجب فعله الآن، أو مهمتك القادمة، أو عدد المهام، أو إضافة مهمة جديدة. جرب أن تقول: "أضف مهمة".';
  }

  Future<String> _continueFlow(String text) async {
    final now = DateTime.now();

    switch (_step) {
      case _Step.title:
        {
          _draftTitle = text.trim();
          _step = _Step.start;
          return 'تمام، المهمة: "$_draftTitle".\nمتى ستبدأ؟ (مثال: 5 مساءً، أو بعد ساعة)';
        }
      case _Step.start:
        {
          var t = ArabicParser.parseTime(text, now);
          if (t == null) {
            return 'لم أفهم الوقت. اكتب مثلاً: "5 مساءً" أو "17:30" أو "بعد ساعة".';
          }
          var note = '';
          if (t.isBefore(now.subtract(const Duration(minutes: 1)))) {
            t = t.add(const Duration(days: 1));
            note = '\n(هذا الوقت مضى اليوم، فجدولتها للغد)';
          }
          _draftStart = t;
          _step = _Step.end;
          return 'تبدأ الساعة ${formatHm(t)}.$note\nمتى ستنتهي؟ أو كم مدتها؟ (مثال: 6 مساءً، أو ساعة ونصف)';
        }
      case _Step.end:
        {
          final start = _draftStart!;
          DateTime? end;
          if (ArabicParser.looksLikeDuration(text)) {
            final d = ArabicParser.parseDuration(text);
            if (d != null) end = start.add(d);
          } else {
            end = ArabicParser.parseTime(text, start);
          }
          if (end == null) {
            return 'لم أفهم. اكتب وقت الانتهاء (مثل: 6 مساءً) أو المدة (مثل: 45 دقيقة).';
          }
          if (!end.isAfter(start)) {
            return 'وقت الانتهاء يجب أن يكون بعد وقت البدء (${formatHm(start)}). حاول مجدداً.';
          }
          _draftEnd = end;
          _step = _Step.repeat;
          return 'تنتهي الساعة ${formatHm(end)}.\nهل تتكرر المهمة؟ اكتب: "لا"، أو "يومياً"، أو أيام محددة مثل "الأحد والثلاثاء".';
        }
      case _Step.repeat:
        {
          final rc = ArabicParser.parseRecurrence(text);
          if (rc == null) {
            return 'لم أفهم. اكتب: "لا" أو "يومياً" أو أيام مثل "الأحد والثلاثاء".';
          }
          final task = TaskItem(
            id: DateTime.now().millisecondsSinceEpoch.toString(),
            title: _draftTitle,
            startTime: _draftStart!,
            endTime: _draftEnd!,
            recurrence: rc.recurrence,
            weekdays: rc.weekdays,
          );
          await TaskStore.saveTask(task);
          await NotificationService.scheduleTask(task);
          _resetFlow();
          final rep = task.isRecurring ? '\n${task.recurrenceLabel}' : '';
          return 'تمت إضافة "${task.title}" ✅\n${formatHm(task.startTime)} - ${formatHm(task.endTime)}$rep\nسأذكّرك عند موعدها.';
        }
      case _Step.none:
        return '';
    }
  }

  // ---------- الواجهة ----------

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('المساعد الذكي (محلي)'),
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              controller: _scroll,
              padding: const EdgeInsets.all(12),
              itemCount: _messages.length,
              itemBuilder: (context, index) {
                final msg = _messages[index];
                final isUser = msg['role'] == 'user';
                return Align(
                  alignment: isUser ? Alignment.centerLeft : Alignment.centerRight,
                  child: Container(
                    constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.8),
                    margin: const EdgeInsets.symmetric(vertical: 4),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: isUser ? const Color(0xFF2E7D32) : cs.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      msg['text']!,
                      style: TextStyle(
                        color: isUser ? Colors.white : cs.onSurface,
                        fontSize: 15,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          Container(
            padding: const EdgeInsets.all(8),
            color: cs.surface,
            child: SafeArea(
              top: false,
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      decoration: InputDecoration(
                        hintText: _listening ? 'أستمع إليك...' : 'اكتب سؤالك هنا...',
                        border: const OutlineInputBorder(),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      ),
                      onSubmitted: (_) => _handleSend(),
                    ),
                  ),
                  const SizedBox(width: 4),
                  IconButton(
                    tooltip: 'تحدث',
                    icon: Icon(
                      _listening ? Icons.mic : Icons.mic_none,
                      color: _listening ? Colors.red : const Color(0xFF2E7D32),
                    ),
                    onPressed: _toggleMic,
                  ),
                  IconButton(
                    icon: const Icon(Icons.send, color: Color(0xFF2E7D32)),
                    onPressed: _handleSend,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
