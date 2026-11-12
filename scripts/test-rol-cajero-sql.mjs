/**
 * Pruebas del rol "cajero" (sql/029-rol-cajero.sql) contra un Postgres REAL en memoria (PGlite).
 *
 *   node scripts/test-rol-cajero-sql.mjs
 *
 * El cajero cobra, abre y cierra la caja, entrega y registra pagos de cuenta
 * corriente; no vende. Sus permisos se cambian en Permisos como los de los demás.
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












const CAJ = '00000000-0000-0000-0000-0000000000ca';
const caj = usuario(CAJ);
const T = [{ producto_id: 2, cantidad: 1, precio_unitario: 10000 }];

grupo('Migración');
let err = null;
const SQL = leerSQL('029-rol-cajero.sql');
try { await db.exec(SQL); await db.exec(SQL); } catch (e) { err = e.message; }
t('029 corre limpio, dos veces seguidas', err, null);
if (err) { console.log(`\n${ok} pasadas, ${fail} fallidas\n`); process.exit(1); }

await q(`INSERT INTO auth.users (id, email, raw_user_meta_data) VALUES ($1, 'caro@mh.test', '{"nombre":"Caro Caja"}')`, [CAJ]);
t('solo el administrador asigna el rol', (await vend(`UPDATE profiles SET rol = 'cajero' WHERE id = $1`, [CAJ])).afectadas, 0);
await admin(`UPDATE profiles SET rol = 'cajero', activo = true WHERE id = $1`, [CAJ]);
t('la persona queda como cajero', (await q(`SELECT rol FROM profiles WHERE id = $1`, [CAJ]))[0].rol, 'cajero');
await falla('un rol inventado sigue sin existir', () => admin(`UPDATE profiles SET rol = 'gerente' WHERE id = $1`, [CAJ]), /check constraint/);

grupo('Lo que puede de entrada');
t('caja, cuenta corriente, pedidos web y entregas', (await caj(`SELECT fn_mis_permisos() p`))[0].p.sort(),
  ['caja.abrir_cerrar', 'caja.cobrar', 'caja.movimientos', 'caja.ver', 'cc.cobrar', 'cc.ver', 'entregas.gestionar', 'entregas.ver', 'pedidos.cobrar']);
t('al vendedor no se le sacó nada', (await vend(`SELECT 'caja.cobrar' = ANY(fn_mis_permisos()) x`))[0].x, true);
await falla('no vende', () => caj(`SELECT venta_registrar($1::jsonb)`, [JSON.stringify({ items: T })]), /sin_permiso/);

grupo('El circuito con cajero');
const v = (await vend(`SELECT venta_registrar($1::jsonb) r`, [JSON.stringify({ items: T, entrega: { tipo: 'retiro' } })]))[0].r;
t('ve la venta que espera cobro', (await caj(`SELECT count(*)::int n FROM ventas WHERE id = $1`, [v.id]))[0].n, 1);
await caj(`SELECT caja_abrir(5000)`);
const c = (await caj(`SELECT venta_cobrar($1, '[{"medio":"efectivo","monto":6000},{"medio":"debito","monto":4000}]'::jsonb) r`, [v.id]))[0].r;
t('abre la caja y cobra con pago mixto', [c.estado, c.medio_pago, c.cobrada_por_nombre ?? (await q(`SELECT cobrada_por_nombre n FROM ventas WHERE id = $1`, [v.id]))[0].n], ['cerrada', 'mixto', 'Caro Caja']);
t('entrega el retiro', (await caj(`SELECT venta_entregar(ARRAY[$1]::bigint[], '{"recibio_nombre":"Juan"}'::jsonb) r`, [v.id]))[0].r.entregadas, 1);
t('después sigue viendo la venta que cobró', (await caj(`SELECT count(*)::int n FROM ventas WHERE id = $1`, [v.id]))[0].n, 1);
const v2 = (await vend2(`SELECT venta_registrar($1::jsonb) r`, [JSON.stringify({ items: T })]))[0].r;
await vend2(`SELECT venta_cobrar($1, '[{"medio":"efectivo","monto":10000}]'::jsonb)`, [v2.id]);
t('no ve las ventas que cobró otra persona', (await caj(`SELECT count(*)::int n FROM ventas WHERE id = $1`, [v2.id]))[0].n, 0);

grupo('Permisos editables');
await admin(`SELECT permisos_rol_guardar('cajero', ARRAY['caja.ver','caja.cobrar','caja.abrir_cerrar'])`);
t('el administrador le cambia los permisos', (await caj(`SELECT fn_mis_permisos() p`))[0].p.sort(), ['caja.abrir_cerrar', 'caja.cobrar', 'caja.ver']);
await db.exec(SQL);
t('correr el 029 otra vez no los pisa', (await caj(`SELECT fn_mis_permisos() p`))[0].p.length, 3);
await falla('sin entregas.gestionar ya no entrega', async () => {
  const v3 = (await vend(`SELECT venta_registrar($1::jsonb) r`, [JSON.stringify({ items: T, entrega: { tipo: 'retiro' } })]))[0].r;
  await caj(`SELECT venta_cobrar($1, '[{"medio":"efectivo","monto":10000}]'::jsonb)`, [v3.id]);
  await caj(`SELECT venta_entregar(ARRAY[$1]::bigint[])`, [v3.id]);
}, /sin_permiso/);
await admin(`SELECT permisos_rol_guardar('vendedor', ARRAY['ventas.crear'])`);
await falla('y el vendedor sin "cobrar en la caja" ya no cobra', async () => {
  const v4 = (await vend(`SELECT venta_registrar($1::jsonb) r`, [JSON.stringify({ items: T })]))[0].r;
  await vend(`SELECT venta_cobrar($1, '[{"medio":"efectivo","monto":10000}]'::jsonb)`, [v4.id]);
}, /sin_permiso/);
await falla('el vendedor no se asigna permisos de cajero', () => vend(`SELECT permisos_rol_guardar('cajero', ARRAY['caja.ver'])`), /sin_permiso|solo/);
await falla('un rol inventado no se guarda', () => admin(`SELECT permisos_rol_guardar('gerente', ARRAY['caja.ver'])`), /rol_invalido/);

console.log(`\n${ok} pasadas, ${fail} fallidas\n`);
process.exit(fail ? 1 : 0);
