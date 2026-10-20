import 'package:flutter/material.dart';
import '../services/settings_store.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('الإعدادات')),
      body: ListView(
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text('المظهر', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.dark_mode_outlined),
            title: const Text('الوضع الليلي'),
            subtitle: const Text('تفعيل المظهر الداكن للتطبيق'),
            value: SettingsStore.isDark,
            onChanged: (value) async {
              await SettingsStore.setDarkMode(value);
              if (mounted) setState(() {});
            },
          ),
          const Divider(),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text('حول التطبيق', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          const ListTile(
            leading: Icon(Icons.bolt),
            title: Text('قوة الآن'),
            subtitle: Text('الإصدار 1.0.0'),
          ),
          const ListTile(
            leading: Icon(Icons.person_outline),
            title: Text('المطوّر'),
            subtitle: Text('شرف علي شرف القارة'),
          ),
        ],
      ),
    );
  }
}
