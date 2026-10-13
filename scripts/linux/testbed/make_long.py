"""Writes long files with known content deep inside, past the first step that the first pass reads. A port of
scripts/testbed/make_long.swift; the same seeded generator, so the same text:
  Sailing log 2025.pdf   120 pages of a logbook; a few days stand out (pages 41, 66, 88, 100)
  Team notes 2026.md     ~150,000 characters of weekly notes; one week stands out (past the 40th chunk)
  sensor readings.txt    a dump of numbers (keyword search only), with one number near its end

    uv run --project scripts/linux/testbed python -I scripts/linux/testbed/make_long.py <out_dir>
"""
import datetime
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # -I leaves it out
from fpdf import FPDF

from draw import face, font_path

out = sys.argv[1]
os.makedirs(out, exist_ok=True)

# The same "random" choices every run: Swift's `seed &* 6364136223846793005 &+ 1442695040888963407` on a UInt64.
seed = 20251009


def pick(items):
    global seed
    seed = (seed * 6364136223846793005 + 1442695040888963407) % 2**64
    return items[(seed >> 33) % len(items)]


# The logbook

ports = ["Falmouth", "Fowey", "Plymouth", "Salcombe", "Dartmouth", "Weymouth", "Poole", "Yarmouth", "Cherbourg",
         "St Peter Port", "Alderney", "Brixham", "Penzance", "Newlyn", "St Mary's"]
winds = ["northwest 3", "west 4", "southwest 4 to 5", "south 3", "variable 2", "northeast 4", "west 5, gusting 6",
         "southwest 3"]
seas = ["slight", "moderate", "smooth", "slight to moderate", "a long swell from the west"]
weather = ["Sunny spells and good visibility.", "Overcast, with drizzle in the afternoon.",
           "Clear skies, cold in the evening.", "Showers passing through, rainbow at noon.",
           "Grey and still all morning, brighter later.", "High cloud and a halo around the sun."]
days = ["Two reefs in the main until the wind eased, then full sail and a long beat to windward.",
        "Practised man-overboard drills with the fender twice; both recoveries under two minutes.",
        "Checked the rigging at the mast foot and tightened a loose shackle on the kicker.",
        "Long reach along the coast, logged a steady six knots most of the way.",
        "Motor-sailed the last hour to make the tide at the harbour entrance.",
        "Cleaned the bilge, topped up the water tanks and bought bread and fruit ashore.",
        "Took bearings on the lighthouse and the church spire to fix our position on the chart.",
        "Changed the genoa sheets and whipped the frayed ends with waxed twine.",
        "Quiet day at anchor: read, swam off the stern and cooked a curry for dinner."]


def log_page(number):
    # Swift evaluates the interpolations left to right; so does this.
    origin = pick(ports)
    to = pick([p for p in ports if p != origin])
    text = f"Day {number}. Left {origin} at {pick(['06:10', '07:45', '08:30', '09:15', '10:40'])}, bound for {to}. "
    text += f"Wind {pick(winds)}, sea {pick(seas)}. {pick(weather)} {pick(days)} {pick(days[::-1])} "
    text += (f"Moored in {to} after {pick(['18', '23', '27', '31', '36', '42'])} miles. "
             f"Barometer {pick(['1012', '1016', '1019', '1021', '1008'])} ")
    text += "and steady. Crew well; the night watch went to the skipper and the mate in two-hour turns."
    return text


standouts = {
    41: "Day 41. The engine overheated off Start Point and stopped. The raw-water impeller had lost all its vanes, so "
        "we sailed the last eight miles into Brixham under genoa alone and fitted the spare impeller on the pontoon. "
        "Ordered two more from the chandlery; never leave harbour without a spare again.",
    66: "Day 66. At sunset a pod of a dozen common dolphins came racing in from the south and rode our bow wave for "
        "twenty minutes, leaping clear of the water and rolling to look up at us. Nobody wanted to go below for "
        "dinner. The skipper said it was the best evening of the whole season.",
    88: "Day 88. Picked up visitors' mooring ball M-417 in the Helford river, paid the harbour master eighteen pounds "
        "and rowed ashore for supplies. Quiet creek, oak woods down to the water, an egret fishing on the mud.",
    100: "Day 100. Fog came down so thick off the Lizard that we could not see the bow from the cockpit. We slowed to "
         "three knots, sounded the horn every two minutes and steered by radar and the plotter while a tanker's "
         "foghorn boomed somewhere to starboard. It lifted only as we reached the harbour wall.",
}

pdf = FPDF(unit="pt", format=(612, 792))
pdf.set_creation_date(datetime.datetime(2026, 10, 1, 12, 0, 0, tzinfo=datetime.timezone.utc))
pdf.set_creator("DigUp testbed")
pdf.set_auto_page_break(False)
pdf.set_margins(0, 0, 0)
pdf.add_font("Sans", "", font_path(face("sans")))
pdf.add_font("Sans", "B", font_path(face("sans", "bold")))
for number in range(1, 121):
    pdf.add_page()
    pdf.set_font("Sans", "B", 14)
    pdf.set_xy(60, 792 - 750)  # the box (60, 720, 492, 30) from the bottom
    pdf.cell(492, 17, f"Sailing log 2025 · page {number}")
    pdf.set_font("Sans", "", 13)
    pdf.set_xy(60, 792 - 700)  # the box (60, 60, 492, 640)
    # `standouts[number] ?? logPage(number)`: no picks for a standout page.
    pdf.multi_cell(492, 13 * 1.2 + 4, standouts[number] if number in standouts else log_page(number))
pdf.output(os.path.join(out, "Sailing log 2025.pdf"))

# The notes

topics = ["the release checklist", "on-call handover", "the design review backlog", "hiring for the data team",
          "the customer survey results", "budget for the next quarter", "the support queue", "flaky tests in CI",
          "the onboarding guide", "the API deprecation plan", "laptop refresh", "the team offsite"]
actions = ["Priya will draft a proposal by Friday.", "Sam takes the follow-up with finance.",
           "We agreed to revisit this in two weeks.", "Ana will write it up in the wiki.",
           "No decision yet; collect more data first.", "Ben volunteered to own it this sprint.",
           "Moved to the next planning meeting.", "Done, closing the ticket."]

notes = "# Team notes 2026\n\n"
week, told = 1, False
while len(notes) < 150_000:
    notes += f"## Week {week}\n\n"
    if not told and len(notes) > 120_000:  # well past the 40 chunks (~64,000 characters) of the first step
        told = True
        notes += ("The big news: we agreed to move the whole team to a new office in Lisbon next March. The rent is "
                  "lower, half of the team already lives in Portugal, and the building has room to grow. Marta will "
                  "look at schools for the families who relocate, and the company covers the moving costs.\n\n")
    for _ in range(6):
        line = f"- On {pick(topics)}: {pick(['discussed', 'reviewed', 'went through', 'looked again at'])} where it stands. "
        line += f"{pick(actions)} {pick(actions)}\n"
        notes += line
    notes += "\n"
    week += 1
with open(os.path.join(out, "Team notes 2026.md"), "w", encoding="utf-8") as f:
    f.write(notes)

# The numbers

rows = ["timestamp,sensor,value\n"]
for row in range(12_000):
    rows.append(f"{1_760_000_000 + row * 60} {row % 17} {row * 7919 % 100_003}\n")
    if row == 11_500:
        rows.append("4815162342 0 0\n")
with open(os.path.join(out, "sensor readings.txt"), "w", encoding="utf-8") as f:
    f.write("".join(rows))
print("ok")
