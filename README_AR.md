# قوة الآن 💪 — مشروع Flutter

هذه نسخة مشروع مصدرية مهيأة بهيكل Android v2 embedding الحديث، مع ملف AndroidManifest.xml وإعدادات Gradle الأساسية.

## البناء
1. فك الضغط.
2. افتح مجلد `quwat_alaan_final` كمشروع Flutter في بيئة تدعم Flutter.
3. نفّذ `flutter pub get`.
4. نفّذ `flutter build apk --release`.

اسم الحزمة: `com.quwatalan.app`
اللغة الافتراضية: العربية (RTL)

مهم: لا أستطيع تنفيذ بناء Android فعلي داخل هذه البيئة، لذلك لا أزعم أن APK تم اختباره. إذا كانت بيئة البناء تتطلب Gradle Wrapper JAR، افتح المشروع وشغّل `flutter create . --platforms=android` مرة واحدة لتوليد ملفات المنصة القياسية، مع الإبقاء على `lib/` و`pubspec.yaml` وملف `AndroidManifest.xml` الحديث.
