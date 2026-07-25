#!/usr/bin/env python3
"""Compose remaining video frames locally (zero credits) from brand assets + product screenshots."""
from PIL import Image, ImageDraw, ImageFont
import cairosvg, io, shutil, os

W, H = 1920, 1080
CREAM, TEAL, DEEP, AMBER, PAPR, CHAR = '#FAF6EF', '#0F5E63', '#0A4247', '#E8A33D', '#C4502F', '#23282B'
os.chdir('/opt/data/projects/company-builder-experiment/run-1/videos')

def font(sz, bold=True, serif=True):
    p = ('/usr/share/fonts/truetype/dejavu/DejaVuSerif-Bold.ttf' if (bold and serif) else
         '/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf' if bold else
         '/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf')
    return ImageFont.truetype(p, sz)

logo_png = cairosvg.svg2png(url='../brand/logo-mark-v2.svg', output_width=140, output_height=140)
LOGO = Image.open(io.BytesIO(logo_png)).convert('RGBA')

def icon_png(name, sz=300):
    png = cairosvg.svg2png(url=f'../brand/{name}', output_width=sz, output_height=sz)
    return Image.open(io.BytesIO(png)).convert('RGBA')

def wrap(draw, text, fnt, maxw):
    words, lines, cur = text.split(), [], ''
    for w in words:
        t = (cur + ' ' + w).strip()
        if draw.textlength(t, font=fnt) <= maxw: cur = t
        else: lines.append(cur); cur = w
    if cur: lines.append(cur)
    return lines

def card(out, eyebrow, headline, sub=None, stat=None, stat_color=AMBER, icon=None, dark=False):
    bg = Image.new('RGB', (W, H), DEEP if dark else CREAM)
    d = ImageDraw.Draw(bg)
    fg = CREAM if dark else CHAR
    acc = AMBER
    bg.paste(LOGO, (80, 70), LOGO)
    d.text((240, 105), 'CostSauce', font=font(52), fill=(CREAM if dark else TEAL))
    y = 320
    if eyebrow:
        d.text((140, y), eyebrow.upper(), font=font(34, bold=True, serif=False), fill=acc); y += 90
    f1 = font(88)
    for line in wrap(d, headline, f1, W - 280):
        d.text((140, y), line, font=f1, fill=(CREAM if dark else TEAL)); y += 108
    if stat:
        d.text((140, y + 30), stat, font=font(130), fill=stat_color); y += 190
    if sub:
        y += 24
        for line in wrap(d, sub, font(40, bold=False, serif=False), W - 280):
            d.text((140, y), line, font=font(40, bold=False, serif=False), fill=fg); y += 56
    if icon:
        ic = icon_png(icon, 340)
        bg.paste(ic, (W - 480, H - 480), ic)
    bg.save(out); print('made', out)

# ---- LAUNCH ----
shutil.copy('../site/assets/img/product-dashboard.png', 'frames-launch/L2-menu.png')
shutil.copy('../site/assets/img/product-ingredients.png', 'frames-launch/L4-live.png')
shutil.copy('../site/assets/img/product-recipes.png', 'frames-launch/L5-alert.png')
card('frames-launch/L3-stat.png', 'Meanwhile, at your restaurant',
     'Most owners find out when the month is already over.',
     stat='82%', sub='of operators said food costs rose in 2025 (NRN / Technomic)')
card('frames-launch/L6-versus.png', 'The other guys',
     'Automation for chains: $199–$480/mo. CostSauce: $49.',
     sub='Built for one-location restaurants.', icon=None)
card('frames-launch/L7-phone.png', 'Setup',
     'Photograph an invoice and you are live.',
     sub='No POS integration. No annual contract.', icon='icon-invoice.svg')

# ---- FOUNDER ----
card('frames-founder/F2-quote.png', 'A real owner, r/restaurateur',
     '"The formulas got fragile, my team broke them constantly, and I was the only one who could fix them."',
     sub='On the spreadsheet he built for food costing.')
card('frames-founder/F3-480.png', 'The fix exists — for chains',
     'Enterprise food-cost software is priced for groups.',
     stat='$480/mo', stat_color=PAPR, sub='Quoted to a one-location owner (MarginEdge demo, his words).')
card('frames-founder/F4-indies.png', 'Who gets left out',
     'The taqueria, the bistro, the burger joint your town would miss.',
     stat='412,498', sub='independent restaurant locations in the US (end of 2025, NRN/Technomic).')
card('frames-founder/F5-radar.png', 'One job',
     'Invoices in. Drift alerts out.',
     sub='CostSauce watches every price, ties it to your recipes, and warns you before the month eats the difference.',
     icon='icon-alert.svg')
card('frames-founder/F6-49.png', 'Pricing', 'Fair for one location.',
     stat='$49/mo', sub='No POS project. No annual contract. Photo, prices, alerts.')
print('ALL FRAMES DONE')
