/**
 * Pruebas de la ubicación del stock (sql/024-ubicaciones.sql) en PGlite.
 *   node scripts/test-ubicaciones-sql.mjs
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
await db.exec(leerSQL('023-fotos-precios-publicar.sql'));
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







grupo('Migración');
let err = null;
try { await db.exec(leerSQL('024-ubicaciones.sql')); await db.exec(leerSQL('024-ubicaciones.sql')); } catch (e) { err = e.message; }
t('024 corre limpio, dos veces seguidas', err, null);
if (err) { console.log(`\n${ok} pasadas, ${fail} fallidas\n`); process.exit(1); }

grupo('Armar la lista');
await falla('el vendedor no crea ubicaciones', () => vend(`INSERT INTO ubicaciones (lugar) VALUES ('Local')`), /row-level/);
await pasa('el encargado (cuenta stock) sí', () => stock(`INSERT INTO ubicaciones (lugar, sector) VALUES ('Depósito 1', 'Fila B'), ('Local Blas Parera', NULL)`));
await falla('no se repite (aunque cambien mayúsculas o espacios)', () => admin(`INSERT INTO ubicaciones (lugar, sector) VALUES (' depósito 1', 'fila b ')`), /duplicate|unique/);
t('texto para mostrar', (await q(`SELECT fn_ubicacion_texto(u) x FROM ubicaciones u ORDER BY id`)).map(r => r.x), ['Depósito 1 · Fila B', 'Local Blas Parera']);
t('el vendedor las ve (para saber dónde buscar)', await cuantos(vend, 'ubicaciones'), 2);
await falla('anónimo no', () => anon(`SELECT * FROM ubicaciones`), /permission denied/);
await falla('no se borran', () => admin(`DELETE FROM ubicaciones`), /permission denied/);

grupo('Ubicar productos');
const U = Object.fromEntries((await q(`SELECT id, lugar FROM ubicaciones`)).map(r => [r.lugar, r.id]));
const DEP = U['Depósito 1'], LOC = U['Local Blas Parera'];
const ubicar = (quien, ids, u) => quien(`SELECT productos_ubicar($1::int[], $2) r`, [ids, u]).then(r => r[0].r);
await falla('el vendedor no ubica', () => ubicar(vend, [1], DEP), /sin_permiso/);
t('el encargado ubica dos productos', (await ubicar(stock, [1, 2], DEP)).ubicados, 2);
t('quedaron ubicados', (await q(`SELECT id, ubicacion_id FROM productos WHERE id IN (1,2) ORDER BY id`)), [{ id: 1, ubicacion_id: DEP }, { id: 2, ubicacion_id: DEP }]);
t('repetir no cuenta de nuevo', (await ubicar(stock, [1, 2], DEP)).ubicados, 0);
t('quitar la ubicación', [(await ubicar(admin, [2], null)).ubicados, (await q(`SELECT ubicacion_id FROM productos WHERE id = 2`))[0].ubicacion_id], [1, null]);
await falla('una ubicación que no existe', () => ubicar(admin, [1], 9999), /ubicacion_invalida/);
await admin(`UPDATE ubicaciones SET activo = false WHERE id = ${LOC}`);
await falla('ni una desactivada', () => ubicar(admin, [1], LOC), /ubicacion_invalida/);
t('desactivar no le saca la ubicación a nadie', (await q(`SELECT ubicacion_id FROM productos WHERE id = 1`))[0].ubicacion_id, DEP);
await admin(`UPDATE ubicaciones SET activo = false WHERE id = ${DEP}`);
t('desactivar la que está en uso tampoco', (await q(`SELECT ubicacion_id FROM productos WHERE id = 1`))[0].ubicacion_id, DEP);
await pasa('vender sigue andando con la columna nueva', () => vend(`SELECT venta_registrar('{"items":[{"producto_id":2,"cantidad":1,"precio_unitario":100}]}'::jsonb)`));

console.log(`\n${ok} pasadas, ${fail} fallidas\n`);
process.exit(fail ? 1 : 0);
