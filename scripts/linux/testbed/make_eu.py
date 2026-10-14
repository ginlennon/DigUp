"""Writes the European-language testbed (ground truth for evals/european.json): for German, English, French, Spanish,
Italian and Portuguese a note or two (md, txt, docx, odt), a two-page PDF (one topic per page), a screenshot named as
the desktop names one in that language, and two recordings with planted names, numbers, amounts, dates and a code;
German also has a 162 s recording of a club's board meeting. probes/ has 20 s of silence and 20 s of music without
speech, which must match nothing. transcripts.json holds what each recording says (the reference text, the planted
terms and, per paragraph, when it's said), for scoring transcripts later.

    uv run --project scripts/linux/testbed python -I scripts/linux/testbed/make_eu.py <out_dir>   (→ de/ en/ fr/ es/ it/ pt/ probes/)

The recordings are the ASR spike's (docs/linux-port/ASR_SPIKE.md): the same reference texts, the same spoken forms
(German ordinal dates written out, no apostrophe in 1'250) and the same Piper voices (speak.py). Piper adds random
noise inside its model, so every run gives slightly different timings: transcripts.json has this run's. Each topic is
in one language only, so a query in another language has one right answer; the planted terms are only said, never
written, so keyword search can find them only through a transcript.
"""
import datetime
import io
import json
import os
import re
import subprocess
import sys
import tempfile
import wave

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # -I leaves it out
import numpy as np
from fpdf import FPDF

import notes
import speak
from draw import BLACK, DARK_GRAY, SECONDARY_LABEL, SYSTEM, WHITE, face, font_path, rgb, window

out = os.path.abspath(sys.argv[1])
FIXED = datetime.datetime(2026, 10, 1, 12, 0, 0, tzinfo=datetime.timezone.utc)
SANS, SEMI, BOLD = face("sans"), face("sans", "semibold"), face("sans", "bold")


# Notes: (file name, text). Formats spread over the languages; Swiss German writes "ss" and 1'250, the doctor's note
# is in German German ("Seestraße"), for the ß/ss and number probes of evals/european.json.
NOTES = {
    "de": [
        ("Zopf Rezept.md",
         "# Sonntagszopf nach Grossmutters Rezept\n\n"
         "500 g Zopfmehl, 1 TL Salz, 1 TL Zucker und 20 g Hefe in einer Schüssel mischen. 60 g weiche Butter und 3 dl "
         "lauwarme Milch dazugeben und zu einem glatten Teig kneten. Den Teig zugedeckt eine Stunde aufgehen lassen, "
         "dann in zwei Stränge teilen und flechten. Mit verquirltem Ei bestreichen und bei 200 °C etwa 35 Minuten "
         "backen. Am Sonntag mit Butter und Konfitüre servieren."),
        ("Arzttermin.odt",
         "Termin bei Dr. med. Ruth Baumann\n\n"
         "Praxis am See, Seestraße 4, 8610 Uster. Dienstag, 20. Oktober, um 8.15 Uhr. Bitte nüchtern erscheinen: "
         "Blutentnahme für die Laborwerte (Cholesterin, Eisen, Vitamin D). Versichertenkarte und die Liste der "
         "Medikamente mitbringen. Wer den Termin nicht wahrnehmen kann, sagt bis 24 Stunden vorher ab, sonst wird er "
         "verrechnet."),
    ],
    "en": [
        ("Boiler service.txt",
         "Boiler service booked with Hartley Heating for Thursday 22 October, between 8 am and 12 noon. The engineer, "
         "Gareth, will check the gas pressure, clean the burner and test the carbon monoxide alarm. The annual service "
         "costs £95; booking reference HH-30418. Leave the side gate unlocked."),
        ("School trip consent.docx",
         "Year 5 trip to the Natural History Museum\n\n"
         "The coach leaves school at 8:15 on Friday 6 November and returns by 4 pm. Children need a packed lunch, a "
         "waterproof coat and comfortable shoes. Please return the signed consent slip and the £12 contribution to "
         "Mrs Patel by Monday."),
    ],
    "fr": [
        ("Recette tarte Tatin.docx",
         "Tarte Tatin\n\n"
         "Faire fondre 100 g de beurre et 150 g de sucre dans un moule jusqu'à obtenir un caramel blond. Disposer six "
         "pommes coupées en quartiers, bien serrées, et cuire dix minutes à feu doux. Recouvrir d'une pâte brisée en "
         "rentrant les bords, puis enfourner 30 minutes à 190 °C. Retourner la tarte encore tiède sur un plat et "
         "servir avec de la crème fraîche."),
    ],
    "es": [
        ("Cita veterinario.odt",
         "Cita en el veterinario\n\n"
         "Luna, nuestra perra de seis años, tiene cita en la Clínica Veterinaria Los Olivos el jueves 15 de octubre a "
         "las 17:30. Le pondrán la vacuna de la rabia y le harán una revisión de los dientes. Hay que llevar la "
         "cartilla de vacunación y no darle de comer tres horas antes. Dirección: calle Mayor 23, Zaragoza."),
    ],
    "it": [
        ("Ricetta risotto.txt",
         "Ricetta del risotto ai funghi porcini: ammollare 30 g di porcini secchi in acqua tiepida. Soffriggere mezza "
         "cipolla nel burro, tostare 320 g di riso Carnaroli e sfumare con un bicchiere di vino bianco. Aggiungere i "
         "funghi e il brodo caldo un mestolo alla volta per circa 18 minuti. Mantecare con burro e parmigiano e "
         "lasciare riposare due minuti prima di servire."),
    ],
    "pt": [
        ("Mudança de casa.md",
         "# Mudança para o apartamento novo\n\n"
         "A mudança para Belo Horizonte é no sábado, 31 de outubro. Antes disso: contratar a transportadora, "
         "encaixotar os livros e a louça, pedir o desligamento da internet antiga e a instalação da nova, e atualizar "
         "o endereço no banco. As chaves serão entregues pela imobiliária na sexta-feira às 16 horas."),
    ],
}

# Two-page PDFs: (file name, [(title, body), (title, body)]).
PDFS = {
    "de": ("Unterlagen Wohnung.pdf", [
        ("Rechnung Nr. 2026-117",
         "Schreinerei Gubler AG, Tösstalstrasse 41, 8400 Winterthur. Rechnung an: Familie Lüthi, Bahnhofstrasse 12, "
         "8610 Uster. Einbauschrank aus Eiche im Schlafzimmer, nach Mass gefertigt und montiert: CHF 2'150.00. "
         "Lieferung und Montage: CHF 230.50. Total CHF 2'380.50 inkl. MWST. Zahlbar innert 30 Tagen. Besten Dank für "
         "Ihren Auftrag."),
        ("Mietvertrag – Zusatzvereinbarung",
         "Wohnung: 3½ Zimmer, 2. Stock, Bahnhofstrasse 12, 8610 Uster. Der Mietzins beträgt CHF 1'950.– pro Monat, "
         "zuzüglich CHF 180.– Nebenkosten akonto. Die Mietkaution von drei Monatsmieten wird auf ein "
         "Mietkautionskonto einbezahlt. Die Kündigungsfrist beträgt drei Monate, kündbar auf Ende März, Juni oder "
         "September. Haustiere sind nach Absprache mit der Verwaltung erlaubt. Die Waschküche steht gemäss Plan am "
         "Dienstag und am Freitag zur Verfügung."),
    ]),
    "en": ("Home insurance claim.pdf", [
        ("Insurance claim: water damage",
         "On 28 September a pipe under the kitchen sink burst while we were away for the weekend. Water soaked the oak "
         "flooring and the bottom of the kitchen cabinets. Claim number CLM-77120 was opened with Harbour Home "
         "Insurance. The loss adjuster visited on 2 October; a flooring company quoted £1,840 to replace the floor. "
         "Photos of the damage and the plumber's receipt are attached."),
        ("Allotment notes: autumn planting",
         "Plot 14 at the Meadow Lane allotments. Planted garlic cloves and broad beans in the raised bed, and onion "
         "sets along the fence. Spread two barrows of compost on the empty beds and covered them with cardboard for "
         "the winter. Next spring: rhubarb, potatoes and a new water butt."),
    ]),
    "fr": ("Courrier octobre.pdf", [
        ("Facture n° 2026-0815",
         "Garage Rousseau, 12 avenue Alsace-Lorraine, 38000 Grenoble. Véhicule : break gris. Vidange du moteur et "
         "remplacement du filtre à huile : 129,90 €. Remplacement des plaquettes de frein avant : 256,50 €. Total TTC : "
         "386,40 €. Facture payable à réception, par chèque ou par carte bancaire."),
        ("Conservatoire : inscription au cours de piano",
         "Léa est inscrite au cours de piano du conservatoire municipal pour l'année 2026-2027. Les cours ont lieu le "
         "mercredi de 14 h à 14 h 45 avec Madame Duval. Le tarif est de 210 € par trimestre. L'audition de fin d'année "
         "aura lieu le samedi 12 juin dans l'auditorium."),
    ]),
    "es": ("Casa y barrio.pdf", [
        ("Factura de la luz – septiembre",
         "Energía Norte. Titular: Pilar Gómez. Número de factura FE-2026-33910. Periodo de consumo: del 1 al 30 de "
         "septiembre. Consumo: 312 kWh. Término de potencia: 18,20 €. Energía consumida: 52,75 €. Impuesto eléctrico e "
         "IVA: 7,50 €. Total a pagar: 78,45 €, que se cargará en su cuenta el 10 de octubre."),
        ("Torneo de pádel del barrio",
         "El sábado 24 de octubre se celebra el torneo de pádel de las fiestas del barrio en el polideportivo "
         "municipal. Parejas mixtas y de adultos, con una inscripción de 15 euros por pareja hasta el miércoles. Habrá "
         "trofeos para los finalistas y una paella para todos los participantes al terminar."),
    ]),
    "it": ("Condominio via Garibaldi.pdf", [
        ("Verbale dell'assemblea condominiale",
         "Condominio di via Garibaldi 18, Torino, assemblea del 29 settembre. Presenti dodici condomini su sedici. Si "
         "approva il rifacimento del tetto e delle grondaie secondo il preventivo della ditta Edilnova, per un importo "
         "di 48.600 euro, da ripartire in base ai millesimi. I lavori inizieranno a marzo. L'amministratore, il "
         "ragionier Paolo Gatti, raccoglierà le quote in tre rate."),
        ("Corso di yoga – orari d'autunno",
         "Il corso di yoga per principianti si tiene nella palestra comunale il martedì e il giovedì dalle 18:30 alle "
         "19:45. L'insegnante è Chiara Villa. Portare un tappetino e un asciugamano. Il costo è di 90 euro per dieci "
         "lezioni; la prima lezione di prova è gratuita."),
    ]),
    "pt": ("Escola e festa.pdf", [
        ("Matrícula escolar 2027",
         "Colégio Ipê Amarelo. Para a matrícula do Pedro no 3º ano do ensino fundamental, entregar na secretaria até 20 "
         "de novembro: certidão de nascimento, comprovante de residência, carteira de vacinação e duas fotos 3x4. A "
         "mensalidade será de 1.150 reais. O uniforme pode ser comprado na própria escola."),
        ("Festa de aniversário da Beatriz",
         "A Beatriz vai fazer sete anos! A festa será no domingo, 15 de novembro, das 14 às 18 horas, no salão de "
         "festas do prédio. Haverá bolo de chocolate, brigadeiros e uma oficina de pintura para as crianças. Por "
         "favor, confirmem a presença até o dia 8."),
    ]),
}

# Screenshots, named as GNOME names them in each language (DigUp's Linux build knows them by that name):
# (file name, window title, heading, banner, banner kind, detail line, hint, button).
SHOTS = {
    "de": ("Bildschirmfoto vom 2026-10-03 14-22-10.png", "Bahn-Billette — Kauf", "Ihr Billett",
           "Zahlung fehlgeschlagen: Karte abgelehnt", "error",
           "Zürich HB → Frauenfeld   ·   2. Klasse   ·   CHF 12.40   ·   Fehlercode ZK-4471",
           "Ihre Bank hat die Zahlung abgelehnt. Bitte wählen Sie eine andere Zahlungsart.", "Erneut versuchen"),
    "en": ("Screenshot from 2026-10-07 14-05-51.png", "Parcel tracking", "Delivery update",
           "We couldn't deliver your parcel", "error",
           "Tracking number TRK-58301-GB   ·   From: Northgate Books   ·   Attempted Wed 7 Oct, 13:52",
           "Nobody was home to sign for it. Choose a new day or a safe place.", "Rebook delivery"),
    "fr": ("Capture d'écran du 2026-10-05 18-03-11.png", "Billetterie — Paiement", "Votre commande",
           "Paiement refusé : carte expirée", "error",
           "Concert de l'Orchestre de chambre   ·   2 places   ·   64,90 €   ·   Réf. commande CMD-90417",
           "Veuillez vérifier la date d'expiration de votre carte ou utiliser un autre moyen de paiement.",
           "Réessayer"),
    "es": ("Captura de pantalla de 2026-10-06 12-40-02.png", "Banca en línea — Transferencias", "Nueva transferencia",
           "Transferencia rechazada: IBAN no válido", "error",
           "Importe: 450,00 €   ·   Beneficiario: Academia de Idiomas Delta   ·   Código de error TRF-4127",
           "Revise el número de cuenta del beneficiario e inténtelo de nuevo.", "Volver a intentar"),
    "it": ("Schermata del 2026-10-02 09-15-44.png", "Pagamenti — Ricevuta", "Ricevuta di pagamento",
           "Pagamento riuscito: tassa sui rifiuti 2026", "ok",
           "Comune di Parma   ·   Importo 238,00 €   ·   Pagato il 2 ottobre   ·   Codice avviso TR-55190",
           "Conservi questa ricevuta: vale come quietanza di pagamento.", "Scarica PDF"),
    "pt": ("Captura de tela de 2026-10-08 20-31-05.png", "Loja online — Pagamento", "Finalizar compra",
           "Pagamento recusado: saldo insuficiente", "error",
           "Valor: R$ 189,90   ·   Pedido PED-30752   ·   Cartão de débito final 8821",
           "Escolha outra forma de pagamento ou tente novamente mais tarde.", "Tentar novamente"),
}

# The ASR spike's clips (its gen_audio.py): ref = what a careful transcriber writes; sub = spoken forms where espeak
# misreads the written one; terms = what was planted. The long clip is said paragraph by paragraph (its "parts").
SPEECH = {
    "de_invoice": dict(
        lang="de",
        parts=["Guten Tag Frau Brunner, hier spricht Thomas Keller von der Schreinerei Keller in Winterthur. Ich rufe "
               "wegen der Rechnung RE-2041 über 1'250 Franken an, die am 14. November fällig ist. Leider fehlt uns "
               "noch die Zahlung. Bitte überweisen Sie den Betrag auf das Konto bei der Zürcher Kantonalbank oder "
               "rufen Sie mich zurück unter 044 381 27 90. Die Lieferung der zwölf Stühle nach Uster ist für "
               "Donnerstag, den 3. Dezember, geplant. Vielen Dank und freundliche Grüsse."],
        sub={"14. November": "vierzehnten November", "3. Dezember": "dritten Dezember"},
        terms=["Brunner", "Thomas Keller", "Winterthur", "RE-2041", "1250", "14. November", "Zürcher Kantonalbank",
               "044 381 27 90", "Uster", "3. Dezember"]),
    "de_trip": dict(
        lang="de",
        parts=["Kurze Info zur Dienstreise nach Hamburg: Der Flug LX 1074 startet am Montag, dem 9. März, um 7 Uhr 45 "
               "in Zürich. Andrea Meier hat das Hotel Atlantic für drei Nächte gebucht, die Kosten liegen bei 480 Euro "
               "pro Nacht. Das Treffen mit Doktor Stefan Hofmann von der Firma Nordlicht GmbH findet am Dienstag um 14 "
               "Uhr statt. Bitte bringt die Projektunterlagen mit der Nummer P-7731 und den Vertragsentwurf mit. Die "
               "Rückreise ist am Donnerstag mit dem ICE 578 über Basel."],
        sub={"9. März": "neunten März"},
        terms=["Hamburg", "LX 1074", "9. März", "Andrea Meier", "Hotel Atlantic", "480 Euro", "Stefan Hofmann",
               "Nordlicht", "P-7731", "ICE 578", "Basel"]),
    "de_long3min": dict(
        lang="de",
        parts=["Protokoll der Vorstandssitzung des Vereins Seeblick vom 22. September in Rapperswil. Anwesend waren die "
               "Präsidentin Monika Steiner, der Kassier Peter Huber, die Aktuarin Sandra Graf sowie fünf weitere "
               "Mitglieder. Die Sitzung begann um 19 Uhr 30 im Restaurant Rössli.",
               "Erstens: Finanzen. Peter Huber berichtete, dass der Verein per Ende August ein Vermögen von 18'400 "
               "Franken ausweist. Die Mitgliederbeiträge für dieses Jahr sind zu 92 Prozent eingegangen. Offen sind "
               "noch elf Beiträge mit einem Gesamtbetrag von 660 Franken. Huber schlägt vor, die säumigen Mitglieder "
               "bis zum 15. Oktober schriftlich zu mahnen. Die Versicherungsprämie bei der Mobiliar steigt im nächsten "
               "Jahr um 4 Prozent auf 1'120 Franken.",
               "Zweitens: Sommerfest. Das Sommerfest am Obersee war mit rund 240 Gästen ein grosser Erfolg. Der "
               "Reingewinn beträgt 3'150 Franken. Sandra Graf dankte besonders der Familie Brändli, die den Grill und "
               "die Getränke organisiert hatte. Für das nächste Jahr wird der 27. Juni als Datum vorgeschlagen. Die "
               "Bewilligung bei der Stadt Rapperswil-Jona muss bis Ende Februar eingereicht werden, Aktenzeichen "
               "BEW-5512.",
               "Drittens: Bootssteg. Der alte Bootssteg muss saniert werden. Es liegen zwei Offerten vor: Die Firma "
               "Holzbau Zollinger aus Wädenswil offeriert die Arbeiten für 27'800 Franken, die Firma Seetech AG aus "
               "Pfäffikon für 31'250 Franken. Der Vorstand empfiehlt die Offerte von Zollinger, Offertnummer "
               "OF-2026-118. Die Arbeiten sollen im April beginnen und rund sechs Wochen dauern. Monika Steiner wird "
               "bei der Gemeinde einen Beitrag aus dem Fonds für Freizeitanlagen beantragen, der bis zu 20 Prozent der "
               "Kosten decken kann.",
               "Viertens: Mitgliederversammlung. Die nächste Mitgliederversammlung findet am Freitag, dem 13. März, um "
               "19 Uhr im Kirchgemeindehaus statt. Die Einladungen werden bis zum 10. Februar per Post und per E-Mail "
               "verschickt. Traktanden sind unter anderem die Wahl eines neuen Kassiers, da Peter Huber nach zwölf "
               "Jahren zurücktritt, sowie die Abstimmung über den Bootssteg.",
               "Fünftens: Verschiedenes. Herr Daniel Wyss regt an, eine Website für den Verein zu erstellen. Seine "
               "Tochter Laura Wyss hat sich bereit erklärt, die Seite unentgeltlich zu gestalten. Der Vorstand "
               "begrüsst die Idee. Ausserdem wird die Schlüsselübergabe für das Bootshaus neu geregelt: Schlüssel "
               "erhalten nur noch Mitglieder mit gültigem Bootsplatz. Die Telefonnummer für Notfälle lautet neu 055 "
               "210 44 87.",
               "Die Sitzung endete um 21 Uhr 15. Das nächste Vorstandstreffen ist am 3. November angesetzt. Für das "
               "Protokoll: Sandra Graf."],
        sub={"22. September": "zweiundzwanzigsten September", "15. Oktober": "fünfzehnten Oktober",
             "27. Juni": "siebenundzwanzigsten Juni", "13. März": "dreizehnten März", "10. Februar": "zehnten Februar",
             "3. November": "dritten November", "Erstens:": "Erstens.", "Zweitens:": "Zweitens.",
             "Drittens:": "Drittens.", "Viertens:": "Viertens.", "Fünftens:": "Fünftens."},
        terms=["Seeblick", "22. September", "Rapperswil", "Monika Steiner", "Peter Huber", "Sandra Graf", "Rössli",
               "18400", "660 Franken", "15. Oktober", "Mobiliar", "1120", "Obersee", "3150", "Brändli", "27. Juni",
               "BEW-5512", "Zollinger", "Wädenswil", "27800", "Seetech", "Pfäffikon", "31250", "OF-2026-118",
               "13. März", "10. Februar", "Daniel Wyss", "Laura Wyss", "055 210 44 87", "3. November"]),
    "en_invoice": dict(
        lang="en",
        parts=["Hi Sarah, this is Michael Thompson from Brookfield Logistics in Leeds. I'm calling about invoice "
               "INV-3381 for 2,975 dollars, which was due on October 21st. Our records show the payment hasn't arrived "
               "yet. Could you check with your accounts team and call me back at 0113 496 0582? Also, the shipment of "
               "forty pallets to Manchester is now scheduled for Friday, November 6th. If anything changes, please "
               "email Jennifer Walsh in our Sheffield office. Thanks a lot and have a good day."],
        sub={},
        terms=["Sarah", "Michael Thompson", "Brookfield Logistics", "Leeds", "INV-3381", "2975", "October 21",
               "0113 496 0582", "Manchester", "November 6", "Jennifer Walsh", "Sheffield"]),
    "en_trip": dict(
        lang="en",
        parts=["Quick update on the conference trip to Denver. Flight UA 1492 leaves Chicago O'Hare on Tuesday, March "
               "17th at 8:40 in the morning. Daniel Okafor booked rooms at the Crawford Hotel for three nights at 289 "
               "dollars per night. The keynote by Professor Linda Garcia starts at 10 a.m. on Wednesday in hall B. "
               "Please bring the project file with reference PRJ-5520 and the signed contract. The return flight is on "
               "Friday, and the total travel budget is 4,600 dollars."],
        sub={},
        terms=["Denver", "UA 1492", "O'Hare", "March 17", "8:40", "Daniel Okafor", "Crawford Hotel", "289",
               "Linda Garcia", "PRJ-5520", "4600"]),
    "fr_invoice": dict(
        lang="fr",
        parts=["Bonjour Madame Lefèvre, ici Julien Moreau de l'agence Moreau Immobilier à Lyon. Je vous appelle au "
               "sujet de la facture FA-1187 d'un montant de 3450 euros, payable le 12 octobre. Nous n'avons pas encore "
               "reçu votre virement. Pouvez-vous me rappeler au 04 72 18 33 60 ? Par ailleurs, la visite de "
               "l'appartement à Villeurbanne est prévue le jeudi 5 novembre à 15 heures. Mon collègue Antoine Girard "
               "vous accompagnera. Merci beaucoup et bonne journée."],
        sub={},
        terms=["Lefèvre", "Julien Moreau", "Lyon", "FA-1187", "3450", "12 octobre", "04 72 18 33 60", "Villeurbanne",
               "5 novembre", "Antoine Girard"]),
    "fr_trip": dict(
        lang="fr",
        parts=["Petit rappel pour le déplacement à Bordeaux. Le vol AF 7621 part de Paris Orly le lundi 2 février à 9 "
               "heures 15. Claire Dubois a réservé l'hôtel Mercure pour deux nuits, au prix de 145 euros par nuit. La "
               "réunion avec le docteur Philippe Martin de la société Atlantique Énergie aura lieu mardi à 11 heures. "
               "N'oubliez pas le dossier numéro DOS-4409 et le contrat signé. Le retour en train TGV 8534 est prévu "
               "mercredi soir."],
        sub={},
        terms=["Bordeaux", "AF 7621", "Orly", "2 février", "Claire Dubois", "Mercure", "145 euros", "Philippe Martin",
               "Atlantique Énergie", "DOS-4409", "8534"]),
    "es_invoice": dict(
        lang="es",
        parts=["Buenos días, señora Fernández, le habla Carlos Ruiz de la empresa Ruiz Construcciones en Valencia. Le "
               "llamo por la factura FAC-2290 por un importe de 1875 euros, con vencimiento el 18 de noviembre. "
               "Todavía no hemos recibido el pago. ¿Podría llamarme al 963 427 158? Además, la entrega de los "
               "materiales en Alicante está prevista para el viernes 4 de diciembre. Mi compañera Lucía Navarro se "
               "encargará del transporte. Muchas gracias y que tenga un buen día."],
        sub={},
        terms=["Fernández", "Carlos Ruiz", "Ruiz Construcciones", "Valencia", "FAC-2290", "1875", "18 de noviembre",
               "963 427 158", "Alicante", "4 de diciembre", "Lucía Navarro"]),
    "es_trip": dict(
        lang="es",
        parts=["Información sobre el viaje a Sevilla. El vuelo IB 3145 sale de Madrid Barajas el martes 10 de marzo a "
               "las 8 y media. Javier Morales ha reservado el hotel Giralda Palace para dos noches, a 320 euros por "
               "noche. La reunión con la doctora Elena Castillo, de la empresa Solaria Ibérica, será el miércoles a "
               "las 12. Por favor, traigan el expediente EXP-6083 y el contrato firmado. El regreso será en el AVE "
               "2471 el jueves por la tarde."],
        sub={},
        terms=["Sevilla", "IB 3145", "Barajas", "10 de marzo", "Javier Morales", "Giralda Palace", "320 euros",
               "Elena Castillo", "Solaria Ibérica", "EXP-6083", "AVE 2471"]),
    "it_invoice": dict(
        lang="it",
        parts=["Buongiorno signora Ricci, sono Marco Bianchi della ditta Bianchi Arredamenti di Bologna. La chiamo per "
               "la fattura FT-3326 di 2140 euro, con scadenza il 16 ottobre. Non abbiamo ancora ricevuto il pagamento. "
               "Può richiamarmi al numero 051 648 2293? Inoltre la consegna dei mobili a Modena è prevista per venerdì "
               "6 novembre. Il mio collega Luca Ferrari seguirà il trasporto. Grazie mille e buona giornata."],
        sub={},
        terms=["Ricci", "Marco Bianchi", "Bianchi Arredamenti", "Bologna", "FT-3326", "2140", "16 ottobre",
               "051 648 2293", "Modena", "6 novembre", "Luca Ferrari"]),
    "it_trip": dict(
        lang="it",
        parts=["Aggiornamento sul viaggio a Napoli. Il volo AZ 1263 parte da Milano Linate lunedì 23 febbraio alle 7 e "
               "30. Giulia Romano ha prenotato l'hotel Vesuvio per tre notti, a 210 euro a notte. L'incontro con il "
               "professor Alessandro Conti della società Mediterranea Servizi si terrà martedì alle 15. Portate la "
               "pratica numero PR-8814 e il contratto firmato. Il ritorno è previsto giovedì con il Frecciarossa "
               "9541."],
        sub={},
        terms=["Napoli", "AZ 1263", "Linate", "23 febbraio", "Giulia Romano", "Vesuvio", "210 euro",
               "Alessandro Conti", "Mediterranea Servizi", "PR-8814", "Frecciarossa 9541"]),
    "pt_invoice": dict(
        lang="pt",
        parts=["Bom dia, senhora Oliveira, aqui é o Rafael Souza da empresa Souza Engenharia em Curitiba. Estou "
               "ligando sobre a fatura NF-4472 no valor de 3680 reais, com vencimento em 20 de outubro. Ainda não "
               "recebemos o pagamento. A senhora pode me ligar no número 41 3352 7190? Além disso, a entrega dos "
               "equipamentos em Londrina está marcada para quinta-feira, 12 de novembro. Minha colega Fernanda Lima "
               "vai acompanhar o transporte. Muito obrigado e tenha um bom dia."],
        sub={},
        terms=["Oliveira", "Rafael Souza", "Souza Engenharia", "Curitiba", "NF-4472", "3680", "20 de outubro",
               "41 3352 7190", "Londrina", "12 de novembro", "Fernanda Lima"]),
    "pt_trip": dict(
        lang="pt",
        parts=["Informações sobre a viagem a Salvador. O voo LA 3519 sai de São Paulo Guarulhos na segunda-feira, 8 "
               "de março, às 6 e 50. O Bruno Almeida reservou o hotel Fasano por duas noites, a 540 reais por noite. A "
               "reunião com a doutora Patrícia Costa, da empresa Atlântica Energia, será na terça-feira às 14 horas. "
               "Por favor, tragam o processo número PROC-2208 e o contrato assinado. A volta está prevista para "
               "quarta-feira à noite."],
        sub={},
        terms=["Salvador", "LA 3519", "Guarulhos", "8 de março", "Bruno Almeida", "Fasano", "540 reais",
               "Patrícia Costa", "Atlântica Energia", "PROC-2208"]),
}

# Where each clip goes, under a voice memo's neutral name (the name gives nothing away), in the formats phones and
# recorders write.
RECORDINGS = [
    ("de/Memo 2026-10-09 0814.m4a", "de_invoice"),
    ("de/Memo 2026-10-11 1702.ogg", "de_trip"),
    ("de/Memo 2026-09-22 1930.wav", "de_long3min"),
    ("en/Memo 2026-10-08 0915.m4a", "en_invoice"),
    ("en/Memo 2026-10-10 1640.mp3", "en_trip"),
    ("fr/Memo 2026-10-06 1012.ogg", "fr_invoice"),
    ("fr/Memo 2026-10-12 0830.m4a", "fr_trip"),
    ("es/Memo 2026-10-05 1125.mp3", "es_invoice"),
    ("es/Memo 2026-10-13 1950.wav", "es_trip"),
    ("it/Memo 2026-10-07 1610.m4a", "it_invoice"),
    ("it/Memo 2026-10-14 0745.ogg", "it_trip"),
    ("pt/Memo 2026-10-04 1430.wav", "pt_invoice"),
    ("pt/Memo 2026-10-12 2105.mp3", "pt_trip"),
]
CODECS = {".wav": ["-c:a", "pcm_s16le"], ".m4a": ["-c:a", "aac", "-b:a", "48k"],
          ".mp3": ["-c:a", "libmp3lame", "-b:a", "48k"], ".ogg": ["-c:a", "libopus", "-b:a", "32k"]}
PAUSE = 0.6  # seconds between the paragraphs of a clip


def path(rel):
    full = os.path.join(out, rel)
    os.makedirs(os.path.dirname(full), exist_ok=True)
    return full


def pdf(file, pages):
    """Like make_docs.py's pages: a 22 pt title, 13 pt text, 60 pt margins, one topic per page."""
    doc = FPDF(unit="pt", format=(612, 792))
    doc.set_creation_date(FIXED)
    doc.set_creator("DigUp testbed")
    doc.set_auto_page_break(False)
    doc.set_margins(0, 0, 0)
    doc.add_font("Sans", "", font_path(SANS))
    doc.add_font("Sans", "B", font_path(BOLD))
    for title, body in pages:
        doc.add_page()
        doc.set_font("Sans", "B", 22)
        doc.set_xy(60, 52)
        doc.multi_cell(492, 26, title)
        doc.set_font("Sans", "", 13)
        doc.set_xy(60, 112)
        doc.multi_cell(492, 13 * 1.2 + 4, body)
    doc.output(file)


def screenshot(file, title, heading, banner, kind, detail, hint, button):
    """A 1440×900 app window, as make_screenshots.py draws its payment error."""
    c, (wx, wy, ww, wh) = window(1440, 900)
    c.text_at(title, wx + ww / 2 - 180, wy + wh - 32, 15, SECONDARY_LABEL, SEMI)
    x, w, top = wx + 40, ww - 80, wy + wh - 80
    c.text_at(heading, x, top - 40, 30, BLACK, BOLD)
    error = kind == "error"
    c.fill(x, top - 140, w, 80, rgb(1, 0.9, 0.9) if error else rgb(0.9, 0.97, 0.9), radius=8)
    c.text_at(("⚠︎  " if error else "✓  ") + banner, x + 24, top - 95, 22, SYSTEM["red"] if error else
              rgb(0.1, 0.5, 0.2), SEMI)
    c.text_at(detail, x, top - 200, 18)
    c.text_at(hint, x, top - 240, 16, DARK_GRAY)
    c.fill(x, top - 320, 260, 44, SYSTEM["blue"], radius=8)
    c.text_at(button, x + 30, top - 308, 17, WHITE, SEMI)
    c.save(file)


def spoken(text, sub):
    """The spike's spoken form: the substitutions, and no apostrophe between digit groups (1'250 → 1250)."""
    for written, said in sub.items():
        text = text.replace(written, said)
    return re.sub(r"(?<=\d)'(?=\d{3})", "", text)


def duration(file):
    return float(subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", file],
                                capture_output=True, text=True, check=True).stdout)


def record(rel, clip_id, voices):
    """Says the clip's parts with a short pause between them; returns its transcripts.json entry."""
    clip = SPEECH[clip_id]
    language = clip["lang"]
    if language not in voices:
        voices[language] = speak.voice(language)
    pcm, rate, parts, at = b"", None, [], 0.0
    for i, text in enumerate(clip["parts"]):
        buffer = io.BytesIO()
        with wave.open(buffer, "wb") as f:
            voices[language].synthesize_wav(spoken(text, clip["sub"]), f)
        buffer.seek(0)
        with wave.open(buffer, "rb") as f:
            rate, frames = f.getframerate(), f.readframes(f.getnframes())
        if i:
            pcm += b"\0\0" * int(PAUSE * rate)
            at += PAUSE
        length = len(frames) / 2 / rate
        parts.append({"start": round(at, 2), "end": round(at + length, 2), "text": text})
        pcm += frames
        at += length
    file = path(rel)
    with tempfile.TemporaryDirectory() as tmp:
        raw = os.path.join(tmp, "raw.wav")
        with wave.open(raw, "wb") as f:
            f.setnchannels(1)
            f.setsampwidth(2)
            f.setframerate(rate)
            f.writeframes(pcm)
        subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", raw, "-ac", "1", "-ar", "16000",
                        *CODECS[os.path.splitext(rel)[1]], "-map_metadata", "-1", file], check=True)
    ref = " ".join(clip["parts"])
    return {"path": rel, "lang": language, "voice": os.path.basename(speak.VOICES[language][0]),
            "spike_id": "syn_" + clip_id, "duration": round(duration(file), 2),
            "ref": ref, "tts_text": spoken(ref, clip["sub"]), "terms": clip["terms"],
            "parts": parts if len(parts) > 1 else []}


def probes():
    """20 s of silence and 20 s of plucked chords (the spike's music probe): no speech, so no transcript."""
    silence = path("probes/probe_silence_20s.wav")
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "anullsrc=r=16000:cl=mono", "-t", "20",
                    "-c:a", "pcm_s16le", silence], check=True)
    sr = 16000
    t = np.arange(sr * 20) / sr
    sig = np.zeros_like(t)
    chords = [[261.6, 329.6, 392.0], [220.0, 261.6, 329.6], [174.6, 220.0, 261.6], [196.0, 246.9, 293.7]]
    for i in range(20):  # 1 s per chord, with a plucked envelope and an arpeggio voice on top
        seg = (t >= i) & (t < i + 1)
        tt = t[seg] - i
        env = np.exp(-3 * tt)
        chord = chords[i % 4]
        for f in chord:
            sig[seg] += env * (np.sin(2 * np.pi * f * tt) + 0.3 * np.sin(4 * np.pi * f * tt))
        for k in range(4):
            s2 = seg & (t >= i + k / 4) & (t < i + (k + 1) / 4)
            t2 = t[s2] - i - k / 4
            sig[s2] += 0.6 * np.exp(-8 * t2) * np.sin(2 * np.pi * 2 * chord[k % 3] * t2)
    sig += 0.15 * np.sin(2 * np.pi * 55 * t) * (0.5 + 0.5 * np.sin(2 * np.pi * 2 * t))
    sig = (sig / np.abs(sig).max() * 0.6 * 32767).astype(np.int16)
    music = path("probes/probe_music_20s.wav")
    with wave.open(music, "wb") as f:
        f.setnchannels(1)
        f.setsampwidth(2)
        f.setframerate(sr)
        f.writeframes(sig.tobytes())
    return [{"path": os.path.relpath(p, out), "lang": None, "kind": "probe", "duration": 20.0, "ref": "", "terms": [],
             "parts": []} for p in (silence, music)]


for language, items in NOTES.items():
    for name, content in items:
        notes.write(path(f"{language}/{name}"), content)
for language, (name, pages) in PDFS.items():
    pdf(path(f"{language}/{name}"), pages)
for language, (name, *shot) in SHOTS.items():
    screenshot(path(f"{language}/{name}"), *shot)
voices, entries = {}, []
for rel, clip_id in RECORDINGS:
    entries.append(record(rel, clip_id, voices))
    print(f"  {rel}  {entries[-1]['duration']:.1f} s", file=sys.stderr)
entries += probes()
with open(path("transcripts.json"), "w", encoding="utf-8") as f:
    json.dump({"about": "What each recording here says (ref: as a careful transcriber writes it; tts_text: what Piper "
                        "was given; terms: planted names, numbers, amounts, dates and codes; parts: each paragraph's "
                        "start and end in seconds). Probes have no speech: a transcript must stay empty.",
               "recordings": entries}, f, ensure_ascii=False, indent=1)
print("ok")
