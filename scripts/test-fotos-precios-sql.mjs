/**
 * Pruebas de fotos, precios en masa y publicar (sql/023-fotos-precios-publicar.sql)
 * contra un Postgres REAL en memoria (PGlite).
 *
 *   npm i --no-save --prefix scripts @electric-sql/pglite   (una sola vez)
 *   node scripts/test-fotos-precios-sql.mjs
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






const URL1 = 'https://x.supabase.co/storage/v1/object/public/producto-imagenes/productos/1/a.webp';
const URL2 = 'https://x.supabase.co/storage/v1/object/public/producto-imagenes/productos/1/b.webp';
const prod = async id => (await q(`SELECT estado, precio_minorista::float precio, en_oferta, imagen_principal_url foto, categoria_id cat FROM productos WHERE id = $1`, [id]))[0];
await q(`INSERT INTO productos (nombre, slug, precio_minorista, estado) VALUES ('Sin nada', 'sin-nada', NULL, 'inactivo'), ('Con oferta', 'con-oferta', 10000, 'inactivo')`); // ids 4, 5
await q(`UPDATE productos SET precio_oferta = 9000, en_oferta = true, categoria_id = 1 WHERE id = 5`);

grupo('Migración');
let err = null;
try { await db.exec(leerSQL('023-fotos-precios-publicar.sql')); await db.exec(leerSQL('023-fotos-precios-publicar.sql')); } catch (e) { err = e.message; }
t('023 corre limpio, dos veces seguidas', err, null);
if (err) { console.log(`\n${ok} pasadas, ${fail} fallidas\n`); process.exit(1); }

grupo('Fotos');
await falla('el vendedor no cambia fotos', () => vend(`SELECT producto_fotos_guardar(1, ARRAY[$1])`, [URL1]), /sin_permiso/);
const f1 = (await stock(`SELECT producto_fotos_guardar(1, ARRAY[$1, $2]) r`, [URL1, URL2]))[0].r;
t('el encargado carga 2 fotos; la primera es la principal', [f1.fotos, (await prod(1)).foto], [2, URL1]);
t('quedan en orden en la galería', await q(`SELECT url, es_principal, orden FROM producto_imagenes WHERE producto_id = 1 ORDER BY orden`),
  [{ url: URL1, es_principal: true, orden: 0 }, { url: URL2, es_principal: false, orden: 1 }]);
await stock(`SELECT producto_fotos_guardar(1, ARRAY[$1, $2])`, [URL2, URL1]);
t('cambiar el orden cambia la principal', (await prod(1)).foto, URL2);
await stock(`SELECT producto_fotos_guardar(1, ARRAY[]::text[])`);
t('sin fotos: queda sin principal', [(await prod(1)).foto, (await q(`SELECT count(*)::int n FROM producto_imagenes WHERE producto_id = 1`))[0].n], [null, 0]);
await falla('una dirección rara no se acepta', () => admin(`SELECT producto_fotos_guardar(1, ARRAY['javascript:alert(1)'])`), /url_invalida/);
await falla('ni más de 12', () => admin(`SELECT producto_fotos_guardar(1, $1::text[])`, [Array(13).fill(URL1)]), /demasiadas_fotos/);
t('el encargado puede borrar una foto de la galería directo', (await stock(`DELETE FROM producto_imagenes WHERE producto_id = 1`)).afectadas, 0);

grupo('Precios en masa');
const pm = (quien, p) => quien(`SELECT productos_precio_masivo($1::jsonb) r`, [JSON.stringify(p)]).then(r => r[0].r);
await falla('el vendedor no cambia precios', () => pm(vend, { ids: [1], modo: 'fijar', valor: 100 }), /sin_permiso/);
const r1 = await pm(admin, { ids: [4], modo: 'fijar', valor: '12.500' });
t('fijar pone el primer precio a uno que no tenía', [r1.cambiados, (await prod(4)).precio], [1, 12500]);
const r2 = await pm(admin, { ids: [1, 4], modo: 'porcentaje', valor: 10, redondeo: 100 });
t('+10% redondeado a 100', [r2.cambiados, (await prod(1)).precio, (await prod(4)).precio], [2, 49500, 13800]);
await q(`UPDATE productos SET precio_minorista = NULL WHERE id = 4`);
const r3 = await pm(admin, { ids: [1, 4], modo: 'sumar', valor: 500 });
t('sumar saltea los que no tienen precio', [r3.cambiados, r3.salteados, (await prod(1)).precio, (await prod(4)).precio], [1, 1, 50000, null]);
const r4 = await pm(admin, { ids: [5], modo: 'porcentaje', valor: -20 });
t('bajar 20% deja la oferta más cara que el precio: se apaga', [r4.ofertas_apagadas, (await prod(5)).precio, (await prod(5)).en_oferta], [1, 8000, false]);
await falla('fijar en 0 no', () => pm(admin, { ids: [1], modo: 'fijar', valor: 0 }), /valor_invalido/);
await falla('bajar 100% no', () => pm(admin, { ids: [1], modo: 'porcentaje', valor: -100 }), /valor_invalido/);
t('queda en el historial con antes y después', (await q(`SELECT count(*)::int n FROM historial_actividad WHERE descripcion LIKE 'Precios en masa%'`))[0].n, 4);

grupo('Publicar solo lo completo');
await stock(`SELECT producto_fotos_guardar(5, ARRAY[$1])`, [URL1]);
const pub = (quien, ids, si = true) => quien(`SELECT productos_publicar($1::int[], $2) r`, [ids, si]).then(r => r[0].r);
await falla('el vendedor no publica', () => pub(vend, [5]), /sin_permiso/);
const p1 = await pub(admin, [4, 5]);
t('publica el completo y dice qué le falta al otro', [p1.publicados, p1.faltan.map(f => [f.nombre, f.falta])], [1, [['Sin nada', ['precio', 'foto', 'categoría']]]]);
t('el completo quedó activo; el otro sigue inactivo', [(await prod(5)).estado, (await prod(4)).estado], ['activo', 'inactivo']);
const p2 = await pub(admin, [5], false);
t('ocultar no pide nada', [p2.ocultados, (await prod(5)).estado], [1, 'inactivo']);

console.log(`\n${ok} pasadas, ${fail} fallidas\n`);
process.exit(fail ? 1 : 0);
