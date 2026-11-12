/**
 * Carga las fotos sacadas de las placas del Drive en "Fotos para revisar" (sql/031).
 *
 *   SUPABASE_SERVICE_ROLE_KEY=... node scripts/cargar-fotos-placas.mjs <carpeta-paquete> [--probar]
 *
 * El paquete lo arman las herramientas de scripts/placas/ (OCR + recorte + cruce):
 *   <paquete>/filas.json         [{ id, carpeta, titulo, ficha, nivel, candidatos:[{id,nombre,puntos}] }]
 *   <paquete>/fotos/<id>.jpg     la foto del producto, recortada
 *   <paquete>/placas/<id>.jpg    la placa entera achicada (para ver de dónde salió)
 *
 * Sube las imágenes al bucket producto-imagenes (carpeta placas/) y crea una
 * fila por foto. Se puede correr de nuevo: lo ya cargado NO se pisa (una foto
 * ya asignada o descartada queda como está). Con --probar no sube nada: solo
 * cuenta lo que haría.
 */
import fs from 'fs';
import path from 'path';

const [dir, ...flags] = process.argv.slice(2);
const PROBAR = flags.includes('--probar');
const URL = process.env.SUPABASE_URL || 'https://zydotmaolgddwenwywyc.supabase.co';
const KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
const BUCKET = 'producto-imagenes';
if (!dir || !fs.existsSync(path.join(dir, 'filas.json'))) {
  console.log('Uso: SUPABASE_SERVICE_ROLE_KEY=... node scripts/cargar-fotos-placas.mjs <carpeta-paquete> [--probar]');
  process.exit(2);
}
if (!KEY && !PROBAR) { console.log('Falta SUPABASE_SERVICE_ROLE_KEY (Supabase → Project Settings → API keys → service_role).'); process.exit(2); }

const H = { apikey: KEY, Authorization: `Bearer ${KEY}` };
const filas = JSON.parse(fs.readFileSync(path.join(dir, 'filas.json'), 'utf8'));
const publica = p => `${URL}/storage/v1/object/public/${BUCKET}/${p}`;

async function subir(local, destino) {
  const r = await fetch(`${URL}/storage/v1/object/${BUCKET}/${destino}`, {
    method: 'POST',
    headers: { ...H, 'Content-Type': 'image/jpeg', 'Cache-Control': 'max-age=31536000', 'x-upsert': 'true' },
    body: fs.readFileSync(local),
  });
  if (!r.ok) throw new Error(`${destino}: ${r.status} ${await r.text()}`);
}

let subidas = 0, fallas = 0;
const listas = [];
const faltan = filas.filter(f => !fs.existsSync(path.join(dir, 'fotos', f.id + '.jpg')));
if (faltan.length) console.log(`${faltan.length} filas sin foto recortada: se saltean.`);
const conFoto = filas.filter(f => !faltan.includes(f));

if (PROBAR) {
  const n = {}; conFoto.forEach(f => { n[f.nivel] = (n[f.nivel] || 0) + 1; });
  console.log(`Subiría ${conFoto.length} fotos (+ sus placas) y crearía sus filas.`, n);
  process.exit(0);
}

// De a 4 en paralelo
for (let i = 0; i < conFoto.length; i += 4) {
  await Promise.all(conFoto.slice(i, i + 4).map(async f => {
    try {
      await subir(path.join(dir, 'fotos', f.id + '.jpg'), `placas/${f.id}.jpg`);
      const placa = path.join(dir, 'placas', f.id + '.jpg');
      let placaUrl = null;
      if (fs.existsSync(placa)) { await subir(placa, `placas/original/${f.id}.jpg`); placaUrl = publica(`placas/original/${f.id}.jpg`); }
      listas.push({ id: f.id, url: publica(`placas/${f.id}.jpg`), placa_url: placaUrl, carpeta: f.carpeta, titulo: f.titulo,
                    ficha: f.ficha, nivel: f.nivel, candidatos: f.candidatos || [] });
      subidas++;
    } catch (e) { fallas++; console.log('  falló', e.message); }
  }));
  process.stdout.write(`\r  ${subidas + fallas}/${conFoto.length} subidas`);
}
console.log();

// Filas: las que ya existen se ignoran (no se pisa lo revisado)
for (let i = 0; i < listas.length; i += 200) {
  const r = await fetch(`${URL}/rest/v1/fotos_sugeridas?on_conflict=id`, {
    method: 'POST',
    headers: { ...H, 'Content-Type': 'application/json', Prefer: 'resolution=ignore-duplicates,return=minimal' },
    body: JSON.stringify(listas.slice(i, i + 200)),
  });
  if (!r.ok) { console.log('No se pudieron crear las filas:', r.status, await r.text()); process.exit(1); }
}
console.log(`Listo: ${subidas} fotos cargadas${fallas ? `, ${fallas} fallaron (correlo de nuevo)` : ''}. Se revisan en /admin/fotos-revisar.`);
