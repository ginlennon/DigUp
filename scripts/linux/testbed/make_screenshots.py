"""Renders fake but realistic-looking UI "screenshots" (no real user data): a port of
scripts/testbed/make_screenshots.swift with the same names, layout and visible text.

    uv run --project scripts/linux/testbed python -I scripts/linux/testbed/make_screenshots.py <outdir>
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # -I leaves it out
from draw import BLACK, DARK_GRAY, SECONDARY_LABEL, SYSTEM, WHITE, face, gray, rgb, window

out = sys.argv[1]
os.makedirs(out, exist_ok=True)
W, H = 1440, 900
SANS, SEMI, BOLD, MONO = face("sans"), face("sans", "semibold"), face("sans", "bold"), face("mono")
light = gray(0.93)


def render(name, bg, chrome, title, body):
    c, (wx, wy, ww, wh) = window(W, H, bg, chrome)
    c.text_at(title, wx + ww / 2 - 180, wy + wh - 32, 15, SECONDARY_LABEL, SEMI)
    r = (wx + 40, wy + 30, ww - 80, wh - 110)  # x, y, width, height of the content
    body(c, *r)
    c.save(os.path.join(out, f"{name}.png"))


def payment(c, x, y, w, h):
    top = y + h
    c.text_at("Invoices", x, top - 40, 30, BLACK, BOLD)
    c.fill(x, top - 140, w, 80, rgb(1, 0.9, 0.9), radius=8)
    c.text_at("⚠︎  Payment failed: Your card was declined (card_declined)", x + 24, top - 95, 22, SYSTEM["red"], SEMI)
    c.text_at("Invoice INV-2041   ·   Acme Design Studio   ·   $249.00 USD   ·   Visa •••• 4242", x, top - 200, 18)
    c.text_at("Attempted Oct 3, 2026 9:41 AM — The customer's bank declined the charge. Ask for another payment method.",
              x, top - 240, 16, DARK_GRAY)
    c.fill(x, top - 320, 200, 44, SYSTEM["blue"], radius=8)
    c.text_at("Retry payment", x + 40, top - 308, 17, WHITE, SEMI)


def traceback(c, x, y, w, h):
    lines = ["$ python train.py --epochs 10",
             "Traceback (most recent call last):",
             "  File \"/Users/me/project/train.py\", line 3, in <module>",
             "    import torch",
             "ModuleNotFoundError: No module named 'torch'",
             "$ pip install torch",
             "error: externally-managed-environment"]
    for i, line in enumerate(lines):
        color = SYSTEM["red"] if "Error" in line or "error" in line else gray(0.9)
        c.text_at(line, x, y + h - 30 - i * 34, 22, color, MONO)


def flight(c, x, y, w, h):
    top = y + h
    c.text_at("Booking confirmed ✈︎", x, top - 40, 30, BLACK, BOLD)
    c.fill(x, top - 300, w * 0.7, 220, rgb(0.93, 0.96, 1), radius=14)
    c.text_at("San Francisco (SFO)  →  Tokyo Haneda (HND)", x + 30, top - 120, 26, BLACK, SEMI)
    c.text_at("Flight NH 7   ·   Departs Fri, Nov 14 at 14:30   ·   Arrives Sat 18:55", x + 30, top - 170, 19)
    c.text_at("Passenger: Alex Doe   ·   Seat 32A   ·   Gate 112   ·   Confirmation code: K7Q2LM", x + 30, top - 210, 19)
    c.text_at("Check-in opens 24 hours before departure.", x + 30, top - 260, 16, DARK_GRAY)


def chat(c, x, y, w, h):
    msgs = [("Sam", "Can we move the design review to Thursday? I'm out sick tomorrow."),
            ("Priya", "Sure, Thursday 3pm works for me. I'll update the calendar invite."),
            ("Sam", "Thanks! I'll also share the new onboarding mockups before the meeting.")]
    for i, (who, text) in enumerate(msgs):
        my = y + h - 60 - i * 110
        c.fill(x, my - 6, 44, 44, SYSTEM[["orange", "purple", "orange"][i]], radius=22)
        c.text_at(who, x + 60, my + 18, 18, BLACK, BOLD)
        c.text_at(text, x + 60, my - 12, 19)


def weather(c, x, y, w, h):
    top = y + h
    c.text_at("London", x, top - 50, 40, BLACK, BOLD)
    c.text_at("18° · Heavy rain ☂︎ · 90% chance of rain", x, top - 110, 28)
    for i, day in enumerate(["Mon 🌧 15°", "Tue 🌧 14°", "Wed ⛈ 13°", "Thu 🌦 16°", "Fri ☁︎ 17°"]):
        c.fill(x + i * 220, top - 300, 200, 140, (250, 251, 253), radius=16)  # white at 70% over the window
        c.text_at(day, x + 30 + i * 220, top - 240, 24)


def swift_code(c, x, y, w, h):
    code = ["import Accelerate", "",
            "struct SearchIndex {",
            "    var vectors: [Float]",
            "    let dimension = 768",
            "",
            "    func search(query: [Float], topK: Int) -> [Int] {",
            "        // cosine similarity via matrix-vector product",
            "        var scores = [Float](repeating: 0, count: vectors.count / dimension)",
            "        cblas_sgemv(CblasRowMajor, CblasNoTrans, ...)",
            "        return scores.indices.sorted { scores[$0] > scores[$1] }.prefix(topK).map { $0 }",
            "    }", "}"]
    for i, line in enumerate(code):
        if "//" in line:
            color = SYSTEM["green"]
        elif "struct" in line or "func" in line or "import" in line:
            color = SYSTEM["pink"]
        else:
            color = gray(0.9)
        c.text_at(line, x, y + h - 30 - i * 30, 19, color, MONO)


render("shot_payment_error", WHITE, light, "dashboard.payments.example.com — Invoices", payment)
render("shot_python_traceback", gray(0.1), gray(0.22), "zsh — 120×40", traceback)
render("shot_flight_booking", WHITE, light, "Mail — Your booking is confirmed", flight)
render("shot_chat_meeting", WHITE, light, "#design-team", chat)
render("shot_weather", rgb(0.85, 0.9, 0.96), light, "Weather", weather)
render("shot_swift_code", gray(0.12), gray(0.2), "SearchIndex.swift — Editor", swift_code)
print("ok")
