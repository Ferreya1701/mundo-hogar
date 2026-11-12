# Recorte v2: borra el texto (cajas de tesseract), el blanco y los colores de la plantilla,
# y se queda con el bloque grande que sobra (el producto). Uso: recortar2.py SALIDA archivo...
import sys, os, io, csv, json, hashlib, subprocess
import numpy as np
from PIL import Image
from scipy import ndimage as nd

S = 4  # trabajar a 1/4 de tamaño

def cajas_texto(f):
    out = subprocess.run(['tesseract', f, '-', '--psm', '11', 'tsv'], capture_output=True, text=True,
                         env=dict(os.environ, OMP_THREAD_LIMIT='1')).stdout
    r = []
    for row in csv.DictReader(io.StringIO(out), delimiter='\t'):
        t = (row.get('text') or '').strip()
        try: conf = float(row['conf'])
        except: continue
        if t and conf >= 30 and any(c.isalnum() for c in t):
            r.append((int(row['left']), int(row['top']), int(row['width']), int(row['height'])))
    return r

def recortar(f, salida):
    im = Image.open(f).convert('RGB')
    W, H = im.size
    a = np.asarray(im.resize((W // S, H // S), Image.BILINEAR)).astype(int)
    R, G, B = a[..., 0], a[..., 1], a[..., 2]
    mx, mn = a.max(-1), a.min(-1)
    blanco = (mn > 228) & (mx - mn < 18)
    naranja = (R > 190) & (G > 90) & (G < 200) & (B < 110) & (R - B > 110)
    azul = (B > 70) & (B - R > 45) & (R < 90)
    fondo = blanco | naranja | azul
    cont = ~fondo
    # texto fuera (con margen)
    for x, y, w, h in cajas_texto(f):
        m = max(3, h // S)
        cont[max(0, y // S - m):(y + h) // S + m, max(0, x // S - m):(x + w) // S + m] = False
    # franja útil: debajo del logo y arriba del precio/ola de abajo
    h4 = H // S
    cont[:int(h4 * 0.13)] = False
    cont[int(h4 * 0.86):] = False
    cont = nd.binary_opening(cont, iterations=1)
    cerr = nd.binary_closing(cont, iterations=6)
    lab, n = nd.label(cerr)
    if n == 0: return None
    areas = nd.sum(cerr, lab, range(1, n + 1))
    big = areas.max()
    if big < 0.02 * cerr.size: return None
    keep = [i + 1 for i, ar in enumerate(areas) if ar >= 0.25 * big]
    ys, xs = np.where(np.isin(lab, keep))
    x0, x1, y0, y1 = xs.min() * S, (xs.max() + 1) * S, ys.min() * S, (ys.max() + 1) * S
    pad = 12
    x0, x1, y0, y1 = int(x0), int(x1), int(y0), int(y1)
    box = (max(0, x0 - pad), max(0, y0 - pad), min(W, x1 + pad), min(H, y1 + pad))
    c = im.crop(box)
    # cuadrado con fondo blanco, como piden las fichas de producto
    lado = max(c.size)
    lienzo = Image.new('RGB', (lado, lado), 'white')
    lienzo.paste(c, ((lado - c.width) // 2, (lado - c.height) // 2))
    if lado > 1000: lienzo = lienzo.resize((1000, 1000), Image.LANCZOS)
    lienzo.save(salida, quality=86)
    return dict(caja=box, partes=len(keep), relleno=round(float(cont[ys.min():ys.max()+1, xs.min():xs.max()+1].mean()), 2))

if __name__ == '__main__':
    out = sys.argv[1]
    for f in sys.argv[2:]:
        key = hashlib.md5(f.encode()).hexdigest()[:12]
        try: r = recortar(f, os.path.join(out, key + '.jpg'))
        except Exception as e: r = {'error': str(e)}
        print(json.dumps(dict(archivo=f, id=key, **(r or {'error': 'sin producto'})), ensure_ascii=False), flush=True)
