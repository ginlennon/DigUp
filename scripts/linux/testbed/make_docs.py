"""Writes synthetic documents with known content (ground truth for evals): a 3-page text PDF (one topic per page), an
image-only "scanned" PDF, and txt/md/rtf/docx notes. A port of scripts/testbed/make_docs.swift: same names, same text.

    uv run --project scripts/linux/testbed python -I scripts/linux/testbed/make_docs.py <out_dir>
"""
import datetime
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # -I leaves it out
from fpdf import FPDF
from PIL import Image, ImageDraw

import notes
from draw import face, font_path, gray, pil_font

out = sys.argv[1]
os.makedirs(out, exist_ok=True)
FIXED = datetime.datetime(2026, 10, 1, 12, 0, 0, tzinfo=datetime.timezone.utc)


def new_pdf():
    pdf = FPDF(unit="pt", format=(612, 792))
    pdf.set_creation_date(FIXED)
    pdf.set_creator("DigUp testbed")
    pdf.set_auto_page_break(False)
    pdf.set_margins(0, 0, 0)
    pdf.add_font("Sans", "", font_path(face("sans")))
    pdf.add_font("Sans", "B", font_path(face("sans", "bold")))
    return pdf


def page(pdf, title, body):
    """AppKit's text(_:in:) boxes: the title in (60, 700, 492, 40), the body in (60, 60, 492, 620) from the bottom."""
    pdf.add_page()
    pdf.set_font("Sans", "B", 22)
    pdf.set_xy(60, 792 - 740)
    pdf.multi_cell(492, 26, title)
    pdf.set_font("Sans", "", 13)
    pdf.set_xy(60, 792 - 680)
    pdf.multi_cell(492, 13 * 1.2 + 4, body)  # lineSpacing 4


pdf = new_pdf()
page(pdf, "Quarterly business review",
     "Revenue grew 20% compared to last year, driven by strong sales in Europe and a new enterprise plan. Operating "
     "costs stayed flat, and the team hired four engineers. Next quarter we will focus on retention and on expanding "
     "the partner program in Japan.")
page(pdf, "Hiking trip to Mount Fuji",
     "We started the climb from the Yoshida trail at the fifth station before sunrise. The path was rocky and cold "
     "near the summit, but the view of the clouds below the crater was unforgettable. Pack warm gloves, a headlamp and "
     "enough water; the mountain huts sell instant noodles.")
page(pdf, "Sourdough bread recipe",
     "Feed the starter the night before. Mix 500 g flour, 350 g water and 100 g active starter, rest for an hour, then "
     "add 10 g salt. Stretch and fold four times, shape a boule, proof overnight in the fridge and bake in a Dutch oven "
     "at 250 °C.")
pdf.output(os.path.join(out, "Annual notes 2026.pdf"))

# "Scanned" receipt: text rendered into an image, so the PDF has no text layer. 900 × 1200 points, drawn at 2× as a
# Retina Mac draws it.
S = 2
receipt = Image.new("RGB", (900 * S, 1200 * S), gray(0.97))
d = ImageDraw.Draw(receipt)
lines = ["BLUE BOTTLE COFFEE", "Hayes Valley, San Francisco", "", "Oat latte            5.50", "Almond croissant     4.75",
         "Cold brew            4.25", "", "TOTAL               14.50", "VISA **** 4242", "Thank you for visiting!"]
for i, line in enumerate(lines):
    font = pil_font(face("mono", "bold" if i == 0 else "regular"), 34 * S)
    d.text((120 * S, (1200 - (1050 - i * 60) - 34 * 1.19) * S), line, font=font, fill=(0, 0, 0))
pdf = new_pdf()
pdf.add_page()
pdf.image(receipt, x=40, y=40, w=612 - 80, h=792 - 80)
pdf.output(os.path.join(out, "Scan 2026-09-14.pdf"))

for name, content in [
    ("Groceries.txt", "Grocery list for the weekend: milk, eggs, bread, apples, coffee beans and dish soap."),
    ("Tokyo itinerary.md", "# Tokyo trip\n\nFlight to Tokyo Haneda on November 14. Hotel in Shinjuku for five nights. "
                           "Day trip to Kamakura on Sunday to see the Great Buddha."),
    ("Meeting notes.rtf", "Design review moved to Thursday at 3pm because Sam was sick. Priya will update the calendar "
                          "invite and Sam will share the onboarding mockups."),
    ("Vector search notes.docx", "Notes on implementing cosine similarity search over embedding vectors with Accelerate "
                                 "in Swift: normalize vectors, use cblas_sgemv, keep the top-k with a heap."),
]:
    notes.write(os.path.join(out, name), content)
print("ok")
