/**
 * Pruebas del historial de cambios (sql/030-historial.sql) contra un Postgres REAL en memoria (PGlite).
 *
 *   node scripts/test-historial-sql.mjs
 *
 * Lo registra la base (no el navegador), nadie lo edita ni lo borra, lo ve
 * solo quien tiene el permiso, guarda solo lo que cambió y marca lo delicado.
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
await db.exec(leerSQL('024-ubicaciones.sql'));
await db.exec(leerSQL('025-caja-cuentas-bancarias.sql'));
await db.exec(leerSQL('026-cobrar-en-caja.sql'));
await db.exec(leerSQL('027-entregas.sql'));
await db.exec(leerSQL('028-pedidos-web-en-circuito.sql'));
await db.exec(leerSQL('029-rol-cajero.sql'));
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













const T = [{ producto_id: 2, cantidad: 1, precio_unitario: 10000 }];
const ult = async (tabla, extra = '') => (await q(`SELECT usuario_nombre u, operacion op, tipo, sensible s, cambios c, registro r FROM auditoria WHERE tabla = $1 ${extra} ORDER BY id DESC LIMIT 1`, [tabla]))[0];
const n = async () => (await q(`SELECT count(*)::int n FROM auditoria`))[0].n;

grupo('Migración');
let err = null;
const SQL = leerSQL('030-historial.sql');
try { await db.exec(SQL); await db.exec(SQL); } catch (e) { err = e.message; }
t('030 corre limpio, dos veces seguidas', err, null);
if (err) { console.log(`\n${ok} pasadas, ${fail} fallidas\n`); process.exit(1); }

grupo('Precios y productos');
await admin(`UPDATE productos SET precio_minorista = 50000, descripcion_corta = 'nueva' WHERE id = 1`);
let a = await ult('productos');
t('quién, qué producto, solo lo que cambió', [a.u, a.r, Object.keys(a.c).sort(), a.c.precio_minorista], ['Ana Admin', 'Freidora de aire 5L', ['descripcion_corta', 'precio_minorista'], [45000, 50000]]);
t('un cambio de precio es delicado y va a "precios"', [a.s, a.tipo], [true, 'precios']);
await admin(`UPDATE productos SET descripcion_corta = 'otra' WHERE id = 1`);
a = await ult('productos');
t('cambiar la descripción no es delicado', [a.s, a.tipo], [false, 'productos']);
const antes = await n();
await admin(`UPDATE productos SET descripcion_corta = 'otra' WHERE id = 1`);
t('guardar sin cambiar nada no registra', await n(), antes);

grupo('Ventas');
const v = (await vend(`SELECT venta_registrar($1::jsonb) r`, [JSON.stringify({ items: T })]))[0].r;
a = await ult('ventas');
t('la venta nueva queda registrada una sola vez, completa', [a.op, a.r, a.u, a.s, a.c.total[1], (await q(`SELECT count(*)::int n FROM auditoria WHERE tabla = 'ventas'`))[0].n], ['alta', v.codigo, 'Vero Ventas', false, 10000, 1]);
t('vender no registra el descuento de stock ni la caja', (await q(`SELECT count(*)::int n FROM auditoria WHERE tabla IN ('movimientos_inventario','caja_movimientos')`))[0].n, 0);
await vend(`SELECT venta_anular($1, 'el cliente se arrepintió')`, [v.id]);
a = await ult('ventas');
t('anular es delicado, con el motivo', [a.s, a.c.estado, a.c.motivo_anulacion[1]], [true, ['pendiente_cobro', 'anulada'], 'el cliente se arrepintió']);

grupo('Stock y caja a mano');
await stock(`SELECT fn_stock_contar(1, 3, 'conteo')`).catch(() => null);
await admin(`SELECT fn_registrar_movimiento(1, 'ajuste_negativo', 2, 'rotura', NULL, NULL, true)`).catch(e => console.log('   (ajuste:', e.message, ')'));
a = await ult('movimientos_inventario');
t('un ajuste de stock a mano queda, delicado', [a?.op, a?.s, a?.r], ['alta', true, 'Freidora de aire 5L']);
await vend2(`SELECT caja_abrir(1000)`);
const con = (await q(`SELECT id::int FROM caja_conceptos WHERE tipo = 'egreso' AND clave IS NULL AND activo LIMIT 1`))[0].id;
await vend2(`SELECT caja_movimiento_registrar($1::jsonb)`, [JSON.stringify({ tipo: 'egreso', monto: 500, concepto_id: con, descripcion: 'flete' })]);
a = await ult('caja_movimientos');
t('un egreso de caja a mano queda, delicado', [a?.s, a?.u], [true, 'Vale Ventas']);

grupo('Permisos y usuarios');
await admin(`SELECT permisos_rol_guardar('cajero', ARRAY['caja.ver'])`);
const per = await q(`SELECT operacion op, registro r, sensible s FROM auditoria WHERE tabla = 'rol_permisos' ORDER BY id DESC LIMIT 20`);
t('sacar permisos queda uno por uno, delicado', [per.length >= 8, per.every(p => p.op === 'baja' && p.s), per.some(p => /Cobrar ventas en la caja · cajero/.test(p.r))], [true, true, true]);
await admin(`UPDATE profiles SET rol = 'cajero' WHERE id = $1`, [VEND2]);
a = await ult('profiles');
t('cambiar el rol de alguien es delicado', [a.s, a.c.rol, a.r], [true, ['vendedor', 'cajero'], 'Vale Ventas']);

grupo('Nadie lo toca');
await falla('ni el administrador lo borra', () => admin(`DELETE FROM auditoria`), /permission denied/);
await falla('ni lo edita', () => admin(`UPDATE auditoria SET usuario_nombre = 'otro'`), /permission denied/);
await falla('ni lo inventa', () => admin(`INSERT INTO auditoria (tabla, operacion, tipo) VALUES ('x', 'alta', 'x')`), /permission denied/);
await falla('ni siquiera con acceso total a la base', () => q(`DELETE FROM auditoria`), /historial_inmutable/);
await falla('ni vaciándolo', () => q(`TRUNCATE auditoria`), /historial_inmutable/);

grupo('Quién lo ve');
t('el administrador lo ve', (await admin(`SELECT count(*)::int n FROM auditoria`))[0].n > 5, true);
t('el vendedor no', (await vend(`SELECT count(*)::int n FROM auditoria`))[0].n, 0);
await admin(`SELECT permisos_rol_guardar('encargado_stock', ARRAY['auditoria.ver'])`);
t('si se le da el permiso, lo ve', (await stock(`SELECT count(*)::int n FROM auditoria`))[0].n > 5, true);

console.log(`\n${ok} pasadas, ${fail} fallidas\n`);
process.exit(fail ? 1 : 0);
