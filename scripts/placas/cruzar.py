# Cruce v2: similitud del TÍTULO (ponderada por rareza de cada palabra) + códigos reales + marca
import json, sys, re, unicodedata, difflib, math
from collections import Counter
F = sys.argv[1]
cat = json.load(open(F + '/catalogo.json'))
placas = [json.loads(l) for l in open(F + '/ocr.jsonl') if l.strip()]
STOP = set('DE DEL LA EL LOS LAS CON SIN PARA POR Y X EN UN UNA A O E CM MM LT LTS L KG W V CC PULGADAS'.split())
SIN = {'LAVARROPA':'LAVARROPAS','LAVAROPAS':'LAVARROPAS','BICICLETAS':'BICICLETA','TELEVISOR':'TV','SMART':'TV','SADWICHERA':'SANDWICHERA','FRIGORIAS':'F','MUEBLE':'','ACONDICIONADO':'AIRE'}
def norm(s): return ''.join(c for c in unicodedata.normalize('NFD', (s or '').upper()) if unicodedata.category(c) != 'Mn')
def toks(s):
    s = re.sub(r'(\d)[\.,](\d)', r'\1\2', norm(s))   # 1.20 / 1,20 -> 120
    out = []
    for t in re.findall(r'[A-Z0-9]+', s):
        t = SIN.get(t, t)
        if t and t not in STOP and (len(t) >= 2 or t.isdigit()): out.append(t)
    return out
def es_cod(t): return (any(c.isdigit() for c in t) and any(c.isalpha() for c in t) and len(t) >= 3)
for p in cat:
    p['_t'] = set(toks(p['nombre'] + ' ' + (p.get('marca') or '')))
    if p.get('sku'): p['_t'].add(re.sub(r'[^A-Z0-9]', '', norm(p['sku'])))
df = Counter(t for p in cat for t in p['_t'])
N = len(cat)
def idf(t): return math.log((N + 1) / (df.get(t, 0) + 0.5))
def igual(a, b): return a == b or (len(a) >= 5 and len(b) >= 5 and difflib.SequenceMatcher(None, a, b).ratio() >= 0.85)
VOC = set(df)
def en_voc(t): return t in VOC or (len(t) >= 5 and any(igual(t, u) for u in VOC if abs(len(u) - len(t)) <= 2))
def parcial(t, u): return len(t) >= 3 and t.isdigit() and any(c.isalpha() for c in u) and t in u
_cache = {}
def limpiar(s):
    if s not in _cache: _cache[s] = set(t for t in toks(s) if en_voc(t) or (len(t) >= 3 and any(c.isdigit() for c in t)))
    return _cache[s]
def puntaje(pl, p):
    tt = limpiar(pl.get('titulo')); ft = limpiar(pl.get('ficha'))
    if not tt: return 0, []
    s = 0; por = []; tot = sum(idf(t) for t in tt)
    for t in tt:
        u = next((u for u in p['_t'] if igual(t, u) or parcial(t, u)), None)
        if u: s += idf(t); por.append(t)
    cob = s / tot if tot else 0                         # qué parte del título está en el nombre
    noenc = [u for u in p['_t'] if not any(igual(u, t) or parcial(t, u) for t in tt | ft)]
    exceso = sum(idf(u) for u in noenc) / max(1, sum(idf(u) for u in p['_t']))   # palabras del producto que la placa no dice
    pts = 10 * cob - 3 * exceso
    for t in (tt | ft):
        if (es_cod(t) and t in p['_t']) or (t in tt and any(parcial(t, u) for u in p['_t'])): pts += 4; por.append('cód ' + t)
    mk = set(toks(p.get('marca') or ''))
    if mk and mk & ft and not mk & tt: pts += 1.5; por.append('marca')
    return round(pts, 2), por
salida = []
for pl in placas:
    if not pl.get('titulo'): salida.append(dict(pl, nivel='sin_texto', candidatos=[])); continue
    sc = sorted(((*puntaje(pl, p), p) for p in cat), key=lambda x: -x[0])[:4]
    c = [dict(id=p['id'], nombre=p['nombre'], sku=p.get('sku'), puntos=s, por=por, tiene_foto=p['tiene_foto'], categoria=p.get('categoria')) for s, por, p in sc if s > 0]
    top = c[0]['puntos'] if c else 0; seg = c[1]['puntos'] if len(c) > 1 else 0
    if not c or top < 4: nivel = 'sin_match'
    elif top >= 7 and top - seg >= 2: nivel = 'seguro'
    elif top >= 5.5 and top - seg >= 1: nivel = 'probable'
    else: nivel = 'dudoso'
    salida.append(dict(pl, nivel=nivel, candidatos=c))
json.dump(salida, open(F + '/cruce.json', 'w'), ensure_ascii=False, indent=1)
print(Counter(x['nivel'] for x in salida))
