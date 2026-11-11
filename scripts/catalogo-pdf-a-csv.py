"""
Pasa el listado "Stock de Artículos" del sistema anterior (PDF de Crystal Reports)
a un CSV para Catálogo → Importar artículos (admin/importar.html).

  pdftotext -bbox listado.pdf /tmp/bbox.html          (poppler-utils)
  python3 scripts/catalogo-pdf-a-csv.py /tmp/bbox.html ~/Downloads

Deja catalogo.csv (para importar, separado por ';', abre en Excel) y catalogo.json.
Lee la posición de cada palabra: une códigos y descripciones cortados en dos
renglones y junta las "variantes" (renglones "xxx Stock: N") en observaciones.
NO subir los archivos generados al repo (es público).
"""
import html, json, re, sys, csv
src, out_dir = sys.argv[1], sys.argv[2]
txt = open(src, encoding='utf-8').read()
pages = re.findall(r'<page[^>]*>(.*?)</page>', txt, re.S)
W = re.compile(r'<word xMin="([\d.]+)" yMin="([\d.]+)" xMax="([\d.]+)" yMax="([\d.]+)">(.*?)</word>')
items, cur, rubro, rarezas = [], None, None, []
for pi, pg in enumerate(pages, 1):
    words = [(float(a), float(b), float(c), html.unescape(t)) for a, b, c, d, t in W.findall(pg)]
    # columnas según el encabezado de la página
    hdr = {t: x for x, y, x2, t in words if t in ('Descripción', 'Marca') and 40 < y < 70}
    stock_hdr = [x for x, y, x2, t in words if t == 'Stock' and 40 < y < 70]
    xd, xm, xs = hdr['Descripción'], hdr['Marca'], stock_hdr[0]
    lines = {}
    for x, y, x2, t in words:
        if y < 59.5: continue   # encabezado de página (Código, Descripción…)
        lines.setdefault(round(y / 2.5), []).append((x, x2, t))
    for k in sorted(lines):
        ws = sorted(lines[k])
        texto = ' '.join(w[2] for w in ws)
        if texto.startswith('Página '): continue
        if texto.startswith('Rubro:'):
            rubro = texto.split(':', 1)[1].strip(); continue
        code = ' '.join(t for x, x2, t in ws if x < xd - 3)
        desc = ' '.join(t for x, x2, t in ws if xd - 3 <= x < xm - 3)
        marca = ' '.join(t for x, x2, t in ws if xm - 3 <= x and x2 < xs - 8)
        stock = [t for x, x2, t in ws if x2 >= xs - 8]
        if 'Stock:' in texto:                       # variante del artículo anterior
            m = re.match(r'(.*?)\s*Stock:\s*(-?\d+)?', texto)
            if cur is not None and m:
                cur['variantes'].append({'nombre': m.group(1).strip(), 'stock': int(m.group(2) or 0)} | ({} if m.group(2) else {'sin_numero': True}))
            else: rarezas.append((pi, texto))
            continue
        if code and stock and re.fullmatch(r'-?\d+', stock[-1]):
            cur = {'codigo': code, 'descripcion': desc, 'marca': marca, 'stock': int(stock[-1]),
                   'rubro': rubro, 'pagina': pi, 'variantes': []}
            items.append(cur); continue
        if cur is None: rarezas.append((pi, texto)); continue
        if code and not desc and not stock: cur['codigo'] += code; continue        # código cortado
        if re.fullmatch(r'-?\d+', texto) and cur['variantes'] and cur['variantes'][-1].get('sin_numero'):
            v = cur['variantes'][-1]; v['stock'] = int(texto); v.pop('sin_numero'); continue   # número de la variante, un renglón más abajo
        if desc and not stock:                                                      # descripción cortada
            cur['descripcion'] = (cur['descripcion'] + ' ' + desc).strip()
            if code: cur['codigo'] += code
            if marca: cur['marca'] = (cur['marca'] + ' ' + marca).strip()
            continue
        rarezas.append((pi, texto))
json.dump(items, open(f'{out_dir}/catalogo.json', 'w'), ensure_ascii=False, indent=1)
with open(f'{out_dir}/catalogo.csv', 'w', newline='', encoding='utf-8-sig') as f:
    w = csv.writer(f, delimiter=';')
    w.writerow(['codigo', 'descripcion', 'marca', 'rubro', 'stock', 'precio', 'observaciones'])
    for i in items:
        obs = ', '.join(f"{v['nombre']}: {v['stock']}" for v in i['variantes'] if v['nombre'].lower() not in ('retiro', 'retito'))
        w.writerow([i['codigo'], i['descripcion'], i['marca'], i['rubro'], i['stock'], '', obs])
print('articulos', len(items)); print('rarezas', len(rarezas))
for r in rarezas[:30]: print('  ', r)
