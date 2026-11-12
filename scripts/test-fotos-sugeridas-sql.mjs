/**
 * Pruebas de las fotos para revisar (sql/031-fotos-sugeridas.sql) contra un Postgres REAL en memoria (PGlite).
 * contra un Postgres REAL en memoria (PGlite).
 *
 *   npm i --no-save --prefix scripts @electric-sql/pglite   (una sola vez)
 *   node scripts/test-fotos-sugeridas-sql.mjs
 */
import fs from 'fs';
import path from 'path';
import { fileURLToPath, pathToFileURL } from 'url';

const RAIZ = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const leerSQL = f => fs.readFileSync(path.join(RAIZ, 'sql', f), 'utf8');

async function cargarPGlite() {
  try {
    const m = await import('@electric-sql/pglite');
    const t = await import('@electric-sql/pglite/contrib/pg_trgm');
    return { PGlite: m.PGlite, pg_trgm: t.pg_trgm };
  } catch (_) { /* sigue */ }
  if (process.env.PGLITE_DIR) {
    const base = path.join(process.env.PGLITE_DIR, 'node_modules', '@electric-sql', 'pglite', 'dist');
    const m = await import(pathToFileURL(path.join(base, 'index.js')).href);
    const t = await import(pathToFileURL(path.join(base, 'contrib', 'pg_trgm.js')).href);
    return { PGlite: m.PGlite, pg_trgm: t.pg_trgm };
  }
  console.log('Falta PGlite. Instalalo una vez con:\n  npm i --no-save --prefix scripts @electric-sql/pglite');
  process.exit(2);
}

let ok = 0, fail = 0;
const grupo = n => console.log(`\n— ${n} —`);
const t = (nombre, real, esperado) => {
  const a = JSON.stringify(real), b = JSON.stringify(esperado);
  if (a === b) { ok++; console.log('  OK   ' + nombre); }
  else { fail++; console.log(`  FALLA ${nombre}\n        esperado: ${b}\n        obtenido: ${a}`); }
};

const { PGlite, pg_trgm } = await cargarPGlite();
const db = new PGlite({ extensions: { pg_trgm } });

await db.exec(`
CREATE SCHEMA auth;
CREATE SCHEMA extensions;
CREATE TABLE auth.users (id UUID PRIMARY KEY, email TEXT, raw_user_meta_data JSONB DEFAULT '{}'::jsonb);
CREATE FUNCTION auth.uid() RETURNS UUID LANGUAGE sql STABLE AS
  $f$ SELECT nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $f$;
CREATE ROLE anon NOLOGIN;
CREATE ROLE authenticated NOLOGIN;
GRANT USAGE ON SCHEMA public, auth, extensions TO anon, authenticated;
GRANT EXECUTE ON FUNCTION auth.uid() TO anon, authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO anon, authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO anon, authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT EXECUTE ON FUNCTIONS TO anon, authenticated;
`);
await db.exec(leerSQL('001-schema.sql').replace(/CREATE EXTENSION[^;]*;/i, ''));
for (const f of ['002-rls-policies.sql', '005-solicitudes.sql', '007-nucleo-stock.sql', '008-blindaje-stock.sql',
                 '009-crm.sql', '010-bot-whatsapp.sql', '011-crm-conversacion.sql', '012-cobros.sql',
                 '013-local-compras-stock.sql']) {
  await db.exec(leerSQL(f));
}

const ADMIN = '00000000-0000-0000-0000-00000000000a';
const VEND  = '00000000-0000-0000-0000-00000000000b';
const STOCK = '00000000-0000-0000-0000-00000000000c';
const VEND2 = '00000000-0000-0000-0000-00000000000d';
const EX    = '00000000-0000-0000-0000-00000000000e';
await db.exec(`
INSERT INTO auth.users (id, email, raw_user_meta_data) VALUES
  ('${ADMIN}', 'ana@mh.test',    '{"nombre":"Ana Admin","rol":"administrador"}'),
  ('${VEND}',  'vero@mh.test',   '{"nombre":"Vero Ventas","rol":"vendedor"}'),
  ('${STOCK}', 'sergio@mh.test', '{"nombre":"Sergio Stock","rol":"encargado_stock"}'),
  ('${VEND2}', 'vale@mh.test',   '{"nombre":"Vale Ventas","rol":"vendedor"}'),
  ('${EX}',    'ex@mh.test',     '{"nombre":"Ex Vendedor","rol":"vendedor"}');
INSERT INTO categorias (nombre, slug) VALUES ('Electrodomésticos','electrodomesticos');
INSERT INTO productos (nombre, slug, categoria_id, precio_minorista, seguimiento_inventario, estado) VALUES
  ('Freidora de aire 5L', 'freidora', 1, 45000, true,  'activo'),
  ('Termo 1L',            'termo',    1, 12000, false, 'activo');
`);
await db.exec(leerSQL('014-accesos.sql'));
await db.exec(leerSQL('015-permisos-por-rol.sql'));
await db.exec(leerSQL('016-permisos-tildables.sql'));
await db.exec(leerSQL('017-datos-fiscales.sql'));
await db.exec(leerSQL('018-caja.sql'));
await db.exec(leerSQL('019-cuentas-corrientes.sql'));
await db.exec(leerSQL('020-editar-venta.sql'));
await db.exec(leerSQL('021-importar-articulos.sql'));
await db.exec(leerSQL('022-reparar-movimientos-stock.sql'));
await db.exec(`INSERT INTO categorias (nombre, slug) VALUES ('Celulares','celulares');
               INSERT INTO productos (nombre, slug, categoria_id, precio_minorista, seguimiento_inventario, estado)
               VALUES ('Celular X', 'celular-x', 2, 300000, false, 'activo');`);

async function como(rol, uid, sql, params = []) {
  return db.transaction(async tx => {
    await tx.exec(`SET LOCAL ROLE ${rol}`);
    await tx.query(`SELECT set_config('request.jwt.claim.sub', $1, true)`, [uid ?? '']);
    const r = await tx.query(sql, params);
    return Object.assign(r.rows, { afectadas: r.affectedRows });
  });
}
const usuario = uid => (sql, p) => como('authenticated', uid, sql, p);
const anon  = (sql, p) => como('anon', '', sql, p);
const admin = usuario(ADMIN), vend = usuario(VEND), vend2 = usuario(VEND2), stock = usuario(STOCK), ex = usuario(EX);
const q = async (sql, p) => (await db.query(sql, p)).rows;
const cuantos = async (quien, tabla) => (await quien(`SELECT count(*)::int AS n FROM ${tabla}`))[0].n;

async function falla(nombre, fn, patron) {
  try { await fn(); t(nombre, 'no falló', 'falla con ' + patron); }
  catch (e) { t(nombre, patron.test(e.message) ? 'falló bien' : e.message, 'falló bien'); }
}
// "Pasa el control de acceso": anda, o falla por otra cosa que no es permiso
async function pasa(nombre, fn) {
  try { await fn(); t(nombre, 'pasa', 'pasa'); }
  catch (e) { t(nombre, /sin_permiso|permission denied|row-level security/.test(e.message) ? 'bloqueado: ' + e.message : 'pasa', 'pasa'); }
}


await db.exec(leerSQL('023-fotos-precios-publicar.sql'));
let err = null;
try { await db.exec(leerSQL('031-fotos-sugeridas.sql')); await db.exec(leerSQL('031-fotos-sugeridas.sql')); } catch (e) { err = e.message; }
grupo('Se instala');
t('031 corre dos veces sin error', err, null);

const U = n => `https://x.supabase.co/storage/v1/object/public/producto-imagenes/placas/${n}.jpg`;
const VIEJA = 'https://x.supabase.co/storage/v1/object/public/producto-imagenes/productos/1/vieja.webp';
await q(`INSERT INTO fotos_sugeridas (id, url, titulo, nivel, candidatos) VALUES
  ('a', '${U('a')}', 'FREIDORA DE AIRE', 'seguro', '[{"id":1,"nombre":"Freidora de aire 5L","puntos":9}]'),
  ('b', '${U('b')}', 'TERMO', 'probable', '[]'),
  ('c', '${U('c')}', 'OTRA FREIDORA', 'dudoso', '[]'),
  ('d', '${U('d')}', 'CUALQUIERA', 'sin_match', '[]')`);
const fotos = async id => (await q(`SELECT url FROM producto_imagenes WHERE producto_id = $1 ORDER BY orden`, [id])).map(r => r.url.split('/').pop());
const principal = async id => ((await q(`SELECT imagen_principal_url u FROM productos WHERE id = $1`, [id]))[0].u || '').split('/').pop();
const fila = async id => (await q(`SELECT estado, producto_id, revisada_por IS NOT NULL rev FROM fotos_sugeridas WHERE id = $1`, [id]))[0];

grupo('Quién la ve y quién la toca');
const vendEdita = (await vend(`SELECT fn_tiene_permiso('productos.editar') x`))[0].x;
t('el administrador ve las fotos para revisar', await cuantos(admin, 'fotos_sugeridas'), 4);
t('quien no edita productos no las ve', await cuantos(anon, 'fotos_sugeridas'), 0);
if (!vendEdita) {
  t('el vendedor (sin permiso de editar productos) no las ve', await cuantos(vend, 'fotos_sugeridas'), 0);
  await falla('el vendedor no puede asignar', () => vend(`SELECT foto_sugerida_asignar('a', 1)`), /sin_permiso/);
}
await falla('nadie las inventa desde el panel', () => admin(`INSERT INTO fotos_sugeridas (id, url) VALUES ('z', 'https://x/z.jpg')`), /permission denied/);
await falla('ni las cambia a mano', () => admin(`UPDATE fotos_sugeridas SET estado = 'asignada'`), /permission denied/);
await falla('ni las borra', () => admin(`DELETE FROM fotos_sugeridas`), /permission denied/);
await falla('anónimo no puede asignar', () => anon(`SELECT foto_sugerida_asignar('a', 1)`), /permission denied|sin_permiso/);

grupo('Asignar');
await admin(`SELECT foto_sugerida_asignar('a', 1)`);
t('producto sin fotos: la asignada queda de principal', [await fotos(1), await principal(1)], [['a.jpg'], 'a.jpg']);
t('la foto queda asignada, con quién la revisó', await fila('a'), { estado: 'asignada', producto_id: 1, rev: true });
await falla('no se asigna dos veces', () => admin(`SELECT foto_sugerida_asignar('a', 2)`), /ya_revisada/);
await admin(`SELECT producto_fotos_guardar(2, ARRAY['${VIEJA}'])`);
await admin(`SELECT foto_sugerida_asignar('b', 2)`);
t('producto con fotos: se suma al final, la principal no cambia', [await fotos(2), await principal(2)], [['vieja.webp', 'b.jpg'], 'vieja.webp']);
await admin(`SELECT foto_sugerida_asignar('c', 1, true)`);
t('"como principal": va primera', [await fotos(1), await principal(1)], [['c.jpg', 'a.jpg'], 'c.jpg']);
await falla('a un producto que no existe, no', () => admin(`SELECT foto_sugerida_asignar('d', 999)`), /producto_no_encontrado/);
t('y la foto sigue pendiente', (await fila('d')).estado, 'pendiente');

grupo('Descartar y deshacer');
await admin(`SELECT foto_sugerida_descartar('d')`);
t('descartada', (await fila('d')).estado, 'descartada');
await falla('no se descarta una ya revisada', () => admin(`SELECT foto_sugerida_descartar('a')`), /ya_revisada/);
await admin(`SELECT foto_sugerida_deshacer('d')`);
t('deshacer un descarte la vuelve a pendiente', (await fila('d')).estado, 'pendiente');
await admin(`SELECT foto_sugerida_deshacer('c')`);
t('deshacer una asignación la saca del producto, las otras quedan', [await fotos(1), await principal(1)], [['a.jpg'], 'a.jpg']);
t('y queda pendiente', await fila('c'), { estado: 'pendiente', producto_id: null, rev: false });
await admin(`SELECT foto_sugerida_deshacer('a')`);
t('si era la única, el producto queda sin foto', [await fotos(1), await principal(1)], [[], '']);

grupo('Límite de 12 fotos');
await admin(`SELECT producto_fotos_guardar(3, ARRAY(SELECT '${VIEJA}?' || g FROM generate_series(1, 12) g))`);
await falla('a un producto con 12 fotos no se le suma otra', () => admin(`SELECT foto_sugerida_asignar('a', 3)`), /demasiadas_fotos/);

console.log(`\n${ok} pasadas, ${fail} fallidas\n`);
process.exit(fail ? 1 : 0);
