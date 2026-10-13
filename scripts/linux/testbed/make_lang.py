"""Writes Bengali and Arabic files with known content (ground truth for evals/multilingual.json): notes in
txt/md/rtf/docx, two-page PDFs (one topic per page) and screenshots of app UIs. A port of
scripts/testbed/make_lang.swift: same names, same text. Speech is make_lang.sh's (piper).

    uv run --project scripts/linux/testbed python -I scripts/linux/testbed/make_lang.py <out_dir>   (→ bn/, ar/)

macOS makes the PDFs with WebKit (Safari's Export as PDF), whose text layer PDFKit reads well for Arabic and garbled,
in glyph order, for Bengali. Here fpdf2 lays out the same page (60 pt margins, a 24 pt heading, 15 pt text at 1.6
line height) and shapes the text with HarfBuzz; PDFium (DigUp's PDF reader on Linux) then reads the Arabic exactly and
the Bengali the same way garbled: a cluster drawn with several glyphs (a vowel sign before its consonant, a conjunct)
maps only its first glyph back to the characters. That matches what macOS sees. (Headless Chrome reads Bengali better
but Arabic reversed; LibreOffice reads both exactly. Neither is what the macOS testbed has.)
scripts/linux/testbed/check_eval_paths.py --content shows what PDFium reads.
"""
import datetime
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # -I leaves it out
from fpdf import FPDF

import notes
from draw import DARK_GRAY, SECONDARY_LABEL, SYSTEM, WHITE, face, font_path, rgb, window

out = sys.argv[1]
FIXED = datetime.datetime(2026, 10, 1, 12, 0, 0, tzinfo=datetime.timezone.utc)
FONT_NAME = {"bn": "Kohinoor Bangla", "ar": "Geeza Pro"}  # the macOS fonts, named in the rtf/docx as macOS names them


def folder(name):
    path = os.path.join(out, name)
    os.makedirs(path, exist_ok=True)
    return path


def note(path, content, language):
    notes.write(path, content, font=FONT_NAME[language], size=14, rtl=language == "ar")


def pdf(path, language, pages):
    """One page per (title, body), laid out as the HTML of make_lang.swift renders."""
    doc = FPDF(unit="pt", format=(612, 792))
    doc.set_creation_date(FIXED)
    doc.set_creator("DigUp testbed")
    doc.set_auto_page_break(False)
    doc.set_margins(60, 60, 60)
    doc.add_font("Lang", "", font_path(face(language)))
    doc.add_font("Lang", "B", font_path(face(language, "bold")))
    doc.add_font("Latin", "", font_path(face("sans")))  # words the script's font lacks ("for", "def")
    doc.add_font("Latin", "B", font_path(face("sans", "bold")))
    doc.set_fallback_fonts(["Latin"])
    rtl = language == "ar"
    doc.set_text_shaping(use_shaping_engine=True, direction="rtl" if rtl else "ltr",
                         script="arab" if rtl else "beng", language="ara" if rtl else "ben")
    for title, body in pages:
        doc.add_page()
        doc.set_xy(60, 60)
        doc.set_font("Lang", "B", 24)
        doc.multi_cell(492, 24 * 1.6, title, align="R" if rtl else "L")
        doc.set_xy(60, 60 + 24 * 1.6 + 16)
        doc.set_font("Lang", "", 15)
        doc.multi_cell(492, 15 * 1.6, body, align="R" if rtl else "L")
    doc.output(path)


def screenshot(path, title, language, body):
    """A 1440×900 "screenshot" of an app window."""
    c, (wx, wy, ww, wh) = window(1440, 900)
    rtl = language == "ar"
    c.text_in(title, wx + 200, wy + wh - 38, ww - 400, 30, 15, SECONDARY_LABEL, face(language), rtl=rtl)
    body(c, wx + 60, wy + 40, ww - 120, wh - 130)
    c.save(path)


def text(c, s, rect, language, size, bold=False, color=(0, 0, 0)):
    c.text_in(s, *rect, size, color, face(language, "bold" if bold else "regular"), rtl=language == "ar")


# Bengali

bn = folder("bn")
note(os.path.join(bn, "পরীক্ষার ফলাফল.txt"),
     "এসএসসি পরীক্ষার ফলাফল প্রকাশিত হয়েছে। এ বছর পাসের হার ৮৩ শতাংশ, যা গত বছরের চেয়ে বেশি। ঢাকা বোর্ডে মেয়েরা "
     "ছেলেদের চেয়ে ভালো ফল করেছে। ফলাফল শিক্ষা বোর্ডের ওয়েবসাইটে এবং মোবাইলে এসএমএসের মাধ্যমে জানা যাবে।", "bn")
note(os.path.join(bn, "ইলিশ মাছের রেসিপি.md"),
     "# সরিষা ইলিশ\n\n"
     "সরিষা ইলিশ রান্নার জন্য প্রথমে সরিষা বাটা, কাঁচা মরিচ, হলুদ আর লবণ দিয়ে ইলিশ মাছের টুকরোগুলো মাখিয়ে নিন। "
     "কড়াইয়ে সরিষার তেল গরম করে মাছগুলো দিন, ঢেকে দিয়ে কম আঁচে দশ মিনিট রান্না করুন। গরম ভাতের সঙ্গে পরিবেশন করুন।", "bn")
note(os.path.join(bn, "Sundarbans trip.docx"),
     "সুন্দরবন ভ্রমণ\n\n"
     "খুলনা থেকে লঞ্চে করে আমরা তিন দিনের জন্য সুন্দরবনে গিয়েছিলাম। ম্যানগ্রোভ বনের খালে নৌকায় ঘুরে আমরা রয়েল বেঙ্গল "
     "টাইগারের পায়ের ছাপ দেখেছি। চিত্রা হরিণ, বানর আর একটি বড় কুমিরও চোখে পড়েছে। রাতে লঞ্চের ছাদে বসে তারা দেখা ছিল "
     "সবচেয়ে সুন্দর অভিজ্ঞতা।", "bn")
pdf(os.path.join(bn, "বাড়ি ভাড়ার চুক্তি.pdf"), "bn", [
    ("বাড়ি ভাড়ার চুক্তিপত্র",
     "ধানমন্ডি ৭ নম্বর রোডের তিন বেডরুমের ফ্ল্যাটটি মাসিক ২৫,০০০ টাকা ভাড়ায় দেওয়া হলো। ভাড়াটিয়া দুই মাসের ভাড়া অগ্রিম "
     "জমা দেবেন। প্রতি মাসের পাঁচ তারিখের মধ্যে ভাড়া পরিশোধ করতে হবে। বিদ্যুৎ, পানি ও গ্যাস বিল ভাড়াটিয়া আলাদাভাবে "
     "দেবেন। চুক্তির মেয়াদ এক বছর, এবং বাড়ি ছাড়ার আগে অন্তত দুই মাস আগে বাড়িওয়ালাকে লিখিতভাবে জানাতে হবে। ফ্ল্যাটে "
     "কোনো স্থায়ী পরিবর্তন করতে হলে বাড়িওয়ালার অনুমতি লাগবে।"),
    ("প্রোগ্রামিং ক্লাসের নোট",
     "আজকের ক্লাসে আমরা পাইথনে লুপ আর ফাংশন শিখেছি। for লুপ দিয়ে একটি তালিকার প্রতিটি উপাদানের উপর কাজ করা যায়, আর "
     "while লুপ চলতে থাকে যতক্ষণ শর্তটি সত্য থাকে। ফাংশন তৈরি করতে def শব্দটি ব্যবহার করা হয়, এবং return দিয়ে ফলাফল "
     "ফেরত পাঠানো হয়। বাড়ির কাজ: একটি ফাংশন লিখুন যা একটি সংখ্যার ফ্যাক্টোরিয়াল বের করে, তারপর লুপ দিয়ে এক থেকে "
     "দশ পর্যন্ত সব সংখ্যার ফ্যাক্টোরিয়াল ছাপুন।"),
])


def wallet(c, x, y, w, h):
    top = y + h
    text(c, "টাকা পাঠান", (x, top - 60, 600, 60), "bn", 34, bold=True)
    c.fill(x, top - 200, w, 110, rgb(1, 0.9, 0.9), radius=10)
    text(c, "⚠︎  লেনদেন ব্যর্থ হয়েছে: অপর্যাপ্ত ব্যালেন্স", (x + 30, top - 175, w - 60, 60), "bn", 30, bold=True,
         color=SYSTEM["red"])
    text(c, "পরিমাণ: ৳ ৫,০০০   ·   প্রাপক: ০১৭০০-০০০০০০   ·   সময়: সকাল ১০:১২", (x, top - 290, w, 50), "bn", 24)
    text(c, "আপনার অ্যাকাউন্টে যথেষ্ট টাকা নেই। টাকা যোগ করে আবার চেষ্টা করুন।", (x, top - 350, w, 50), "bn", 22,
         color=DARK_GRAY)
    c.fill(x, top - 450, 300, 60, SYSTEM["pink"], radius=10)
    text(c, "আবার চেষ্টা করুন", (x + 50, top - 440, 260, 44), "bn", 24, bold=True, color=WHITE)


screenshot(os.path.join(bn, "wallet_failed_bn.png"), "মোবাইল ওয়ালেট — টাকা পাঠান", "bn", wallet)

# Arabic

ar = folder("ar")
note(os.path.join(ar, "وصفة الكبسة.txt"),
     "الكبسة السعودية: اغسل الأرز البسمتي وانقعه في الماء لمدة نصف ساعة. في قدر كبير، اقلِ البصل حتى يذبل ثم أضف قطع "
     "الدجاج والطماطم والثوم وبهارات الكبسة. أضف الماء واترك الدجاج ينضج، ثم أضف الأرز واطبخه على نار هادئة. قدّمها مع "
     "اللوز المحمص والزبيب.", "ar")
note(os.path.join(ar, "Meeting minutes.rtf"),
     "محضر اجتماع فريق التطوير\n\n"
     "تقرر تأجيل إطلاق التطبيق إلى شهر ديسمبر بسبب مشاكل في نظام الدفع الإلكتروني. سيقوم فريق الخوادم بإصلاح الأخطاء قبل "
     "نهاية الشهر، وسيتم اختبار النسخة الجديدة مع مجموعة صغيرة من المستخدمين.", "ar")
note(os.path.join(ar, "ملاحظة.md"),
     "# مُلاحَظَة\n\n"
     "قَالَ مُحَمَّدٌ إِنَّ الْمَكْتَبَةَ الْعَامَّةَ تُغْلَقُ فِي السَّاعَةِ الثَّامِنَةِ مَسَاءً يَوْمَ الْخَمِيسِ، فَلَا تَتَأَخَّرْ فِي إِعَادَةِ الْكُتُبِ.", "ar")
pdf(os.path.join(ar, "تقرير.pdf"), "ar", [
    ("التقرير الربعي",
     "ارتفعت المبيعات بنسبة خمسة عشر بالمئة في الربع الثالث مقارنة بالعام الماضي، بفضل نمو قوي في أسواق الخليج وإطلاق "
     "خدمة الاشتراك الجديدة. بقيت التكاليف التشغيلية مستقرة، وانضم ثلاثة مهندسين جدد إلى الفريق. في الربع القادم سنركز "
     "على رضا العملاء وتوسيع شبكة الشركاء."),
    ("رحلة إلى البتراء",
     "زرنا مدينة البتراء الأثرية في جنوب الأردن. مشينا عبر السيق الضيق حتى ظهرت الخزنة المنحوتة في الصخر الوردي. صعدنا "
     "إلى الدير في الصباح الباكر لتجنب الحر، وتناولنا الغداء في قرية وادي موسى. أنصح بارتداء حذاء مريح وحمل الكثير من "
     "الماء."),
])


def checkout(c, x, y, w, h):
    top = y + h
    text(c, "إتمام الطلب", (x, top - 60, w, 60), "ar", 34, bold=True)
    c.fill(x, top - 200, w, 110, rgb(1, 0.9, 0.9), radius=10)
    text(c, "فشلت عملية الدفع: البطاقة مرفوضة من البنك  ⚠︎", (x + 30, top - 175, w - 60, 60), "ar", 30, bold=True,
         color=SYSTEM["red"])
    text(c, "المبلغ: ٣٥٠ ريال   ·   رقم الطلب: ٤٨٢١٧   ·   بطاقة فيزا تنتهي بـ ٤٢٤٢", (x, top - 290, w, 50), "ar", 24)
    text(c, "يرجى استخدام بطاقة أخرى أو المحاولة مرة أخرى لاحقاً.", (x, top - 350, w, 50), "ar", 22, color=DARK_GRAY)
    c.fill(x + w - 300, top - 450, 300, 60, SYSTEM["blue"], radius=10)
    text(c, "إعادة المحاولة", (x + w - 280, top - 440, 260, 44), "ar", 24, bold=True, color=WHITE)


screenshot(os.path.join(ar, "payment_error_ar.png"), "متجر إلكتروني — الدفع", "ar", checkout)
print("ok")
