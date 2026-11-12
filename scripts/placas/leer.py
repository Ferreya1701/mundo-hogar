# Una placa: texto (título / ficha / precio) + recorte de la foto del producto
import sys, subprocess, csv, io, os, json, re, hashlib
f, outdir = sys.argv[1], sys.argv[2]
out = subprocess.run(['tesseract', f, '-', '--psm', '11', 'tsv'], capture_output=True, text=True).stdout
ws = []
for row in csv.DictReader(io.StringIO(out), delimiter='\t'):
    t = (row.get('text') or '').strip()
    try: conf = float(row['conf'])
    except: continue
    if t and conf >= 25 and any(c.isalnum() for c in t):
        ws.append(dict(t=t, c=conf, x=int(row['left']), y=int(row['top']), w=int(row['width']), h=int(row['height'])))
key = hashlib.md5(f.encode()).hexdigest()[:12]
res = dict(archivo=f, id=key, carpeta=os.path.basename(os.path.dirname(f)).strip())
tit = [w for w in ws if 230 < w['y'] < 950 and w['h'] >= 34]
if tit:
    tb = max(w['y'] + w['h'] for w in tit)
    abajo = sorted([w for w in ws if w['y'] > tb + 250 and w['c'] >= 45], key=lambda w: w['y'])
    st = abajo[0]['y'] if abajo else 1500
    res['titulo'] = ' '.join(w['t'] for w in sorted(tit, key=lambda w: (w['y'] // 45, w['x'])))
    res['ficha'] = ' '.join(w['t'] for w in sorted(abajo, key=lambda w: (w['y'] // 30, w['x'])))
    m = re.findall(r'\$\s?([\d\.]{4,})', res['ficha'].replace(',', '.'))
    res['precio'] = int(m[-1].replace('.', '')) if m else None
    y0, y1 = tb + 15, st - 15
    if y1 - y0 >= 300:
        tmp = os.path.join(outdir, key + '_c.png'); fin = os.path.join(outdir, key + '.jpg')
        subprocess.run(['magick', f, '-crop', f'1080x{y1-y0}+0+{y0}', '+repage', tmp], check=True)
        # geometría del producto: sin el naranja del diseño ni el blanco de alrededor
        g = subprocess.run(['magick', tmp, '-fuzz', '22%', '-fill', 'white', '-opaque', '#F7941D', '-opaque', '#1F4E9C', '-fuzz', '8%', '-trim', '-format', '%@', 'info:'], capture_output=True, text=True).stdout.strip()
        subprocess.run(['magick', tmp] + (['-crop', g, '+repage'] if g else []) + ['-background', 'white', '-flatten', '-quality', '86', fin], check=True)
        os.remove(tmp)
        res['recorte'] = fin
        res['tam'] = subprocess.run(['identify', '-format', '%wx%h', fin], capture_output=True, text=True).stdout
print(json.dumps(res, ensure_ascii=False))
