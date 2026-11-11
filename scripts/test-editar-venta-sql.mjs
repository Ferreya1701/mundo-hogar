/**
 * Pruebas de "quitar productos de una venta" (sql/020-editar-venta.sql)
 * contra un Postgres REAL en memoria (PGlite), sin tocar Supabase.
 *
 *   npm i --no-save --prefix scripts @electric-sql/pglite   (una sola vez)
 *   node scripts/test-editar-venta-sql.mjs
 *
 * Corre 001..020 y prueba: stock que vuelve, total recalculado, devolución
 * en caja por el mismo medio, baja de deuda en cuenta corriente (con
 * recargo), permisos (propias 24 h / todas), registro de la edición y
 * que después se pueda anular sin reponer de más.
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




const FREIDORA = 1, TERMO = 2, CEL = 3;
// La freidora descuenta stock: la contamos en 10
await db.exec(`SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', false)`);
await q(`SELECT fn_stock_contar(1, 10)`);
await db.exec(`SELECT set_config('request.jwt.claim.sub', '', false)`);
await admin(`SELECT cc_recargo_guardar(2, 20000)`);
const cta = (await admin(`SELECT cc_cuenta_guardar('{"contacto":{"nombre":"Juan Pérez","telefono":"3425551234"}}'::jsonb) r`))[0].r.cuenta_id;

const vender = (quien, items, medio = 'efectivo', extra = {}) => quien(`SELECT venta_registrar($1::jsonb) AS r`,
  [JSON.stringify({ items, medio_pago: medio, ...extra })]).then(r => r[0].r);
const items = async id => (await q(`SELECT id, nombre, cantidad, cantidad_original, subtotal::float s FROM venta_items WHERE venta_id = $1 ORDER BY orden`, [id]));
const quitar = (quien, id, lista, motivo = 'no lo quiso') => quien(`SELECT venta_quitar_items($1, $2::jsonb, $3) r`, [id, JSON.stringify(lista), motivo]).then(r => r[0].r);
const stockDe = async pid => (await q(`SELECT stock_actual FROM productos WHERE id = $1`, [pid]))[0].stock_actual;
const venta = async id => (await q(`SELECT total::float t, subtotal::float s, descuento::float d, recargo_total::float r, unidades, items_count, ediciones, estado FROM ventas WHERE id = $1`, [id]))[0];

grupo('Migración');
let err = null, res = null;
const SQL020 = leerSQL('020-editar-venta.sql');
try { await db.exec(SQL020); res = (await db.exec(SQL020)).at(-1).rows[0]; } catch (e) { err = e.message; }
t('020 corre limpio, dos veces seguidas', err, null);
if (err) { console.log(`\n${ok} pasadas, ${fail} fallidas\n`); process.exit(1); }
t('2 permisos nuevos', res.permisos_editar, 2);
t('vendedor y encargado: quitar de sus ventas', [(await vend(`SELECT 'ventas.editar_propias' = ANY(fn_mis_permisos()) x`))[0].x, (await stock(`SELECT 'ventas.editar_propias' = ANY(fn_mis_permisos()) x`))[0].x], [true, true]);

grupo('Venta en efectivo: el cliente no se lleva una freidora');
await vend(`SELECT caja_abrir(0)`);
const v1 = await vender(vend, [{ producto_id: FREIDORA, cantidad: 2, precio_unitario: 45000 }, { producto_id: TERMO, cantidad: 1, precio_unitario: 12000 }]);
t('vendió 2 freidoras: stock 8', await stockDe(FREIDORA), 8);
const [itF, itT] = await items(v1.id);
await falla('sin motivo no se puede', () => quitar(vend, v1.id, [{ item_id: itF.id, quitar: 1 }], '  '), /motivo_requerido/);
await falla('no se quitan más de las vendidas', () => quitar(vend, v1.id, [{ item_id: itF.id, quitar: 3 }]), /cantidad_invalida/);
await falla('no se deja la venta vacía (para eso, anular)', () => quitar(vend, v1.id, [{ item_id: itF.id, quitar: 2 }, { item_id: itT.id, quitar: 1 }]), /venta_vacia/);
t('y nada quedó a medias', [await stockDe(FREIDORA), (await venta(v1.id)).t], [8, 102000]);
const r1 = await quitar(vend, v1.id, [{ item_id: itF.id, quitar: 1 }], 'se llevó una sola');
t('total 102.000 → 57.000, devuelve 45.000', [Number(r1.total_anterior), Number(r1.total), Number(r1.diferencia)], [102000, 57000, 45000]);
t('la freidora vuelve al stock: 9', await stockDe(FREIDORA), 9);
t('el renglón queda en 1 (original 2)', (await items(v1.id))[0], { id: itF.id, nombre: 'Freidora de aire 5L', cantidad: 1, cantidad_original: 2, s: 45000 });
t('venta: unidades, ediciones', [(await venta(v1.id)).unidades, (await venta(v1.id)).ediciones, (await venta(v1.id)).estado], [2, 1, 'cerrada']);
t('sale la devolución de la caja en efectivo', (await q(`SELECT tipo, monto::float m, medio_pago FROM caja_movimientos WHERE venta_id = $1 ORDER BY id`, [v1.id])),
  [{ tipo: 'ingreso', m: 102000, medio_pago: 'efectivo' }, { tipo: 'egreso', m: 45000, medio_pago: 'efectivo' }]);
t('queda registrado qué se quitó, quién y por qué', (await q(`SELECT usuario_nombre, motivo, total_anterior::float a, total_nuevo::float n, detalle->0->>'quitadas' AS q FROM venta_ediciones WHERE venta_id = $1`, [v1.id]))[0],
  { usuario_nombre: 'Vero Ventas', motivo: 'se llevó una sola', a: 102000, n: 57000, q: '1' });
await quitar(vend, v1.id, [{ item_id: itT.id, quitar: 1 }], 'tampoco el termo');
t('quitar todo un renglón: queda en 0 a la vista', (await items(v1.id)).map(i => [i.cantidad, i.cantidad_original]), [[1, 2], [0, 1]]);
t('termo sin control de stock: no se mueve stock', (await q(`SELECT count(*)::int n FROM movimientos_inventario WHERE producto_id = $1`, [TERMO]))[0].n, 0);
await vend(`SELECT venta_anular($1, 'al final nada')`, [v1.id]);
t('anular después de editar repone solo lo que quedaba (stock 10)', await stockDe(FREIDORA), 10);
t('y la caja queda en cero para esa venta', (await q(`SELECT sum(CASE tipo WHEN 'ingreso' THEN monto ELSE -monto END)::float s FROM caja_movimientos WHERE venta_id = $1`, [v1.id]))[0].s, 0);
await falla('una venta anulada no se edita', () => quitar(vend, v1.id, [{ item_id: itF.id, quitar: 1 }]), /venta_anulada/);

grupo('Descuento');
const v2 = await vender(vend, [{ producto_id: TERMO, cantidad: 3, precio_unitario: 10000 }], 'transferencia', { descuento: 5000 });
const [it2] = await items(v2.id);
await quitar(vend, v2.id, [{ item_id: it2.id, quitar: 2 }]);
t('el descuento se mantiene (30.000 − 5.000 → 10.000 − 5.000)', [(await venta(v2.id)).t, (await venta(v2.id)).d], [5000, 5000]);
t('devolución por transferencia (el mismo medio)', (await q(`SELECT medio_pago, monto::float m FROM caja_movimientos WHERE venta_id = $1 AND tipo = 'egreso'`, [v2.id]))[0], { medio_pago: 'transferencia', m: 20000 });

grupo('Cuenta corriente: pidió por teléfono, no se llevó un celular');
const v3 = await vender(vend, [{ producto_id: CEL, cantidad: 2 }, { producto_id: TERMO, cantidad: 1, precio_unitario: 12000 }], 'cuenta_corriente', { cc_cuenta_id: cta });
t('debía 652.000 (2 × 320.000 + 12.000)', Number((await q(`SELECT saldo FROM cc_cuentas WHERE id = $1`, [cta]))[0].saldo), 652000);
const [itC] = await items(v3.id);
const r3 = await quitar(vend, v3.id, [{ item_id: itC.id, quitar: 1 }], 'se llevó un solo celular');
t('baja la deuda 320.000 (con su recargo)', Number(r3.saldo_cuenta), 332000);
t('y el recargo de la venta baja a 20.000', (await venta(v3.id)).r, 20000);
t('movimiento de devolución en la cuenta', (await q(`SELECT tipo, monto::float m, saldo_posterior::float s FROM cc_movimientos WHERE venta_id = $1 ORDER BY id`, [v3.id])).at(-1), { tipo: 'devolucion', m: 320000, s: 332000 });
t('cuenta corriente no toca la caja', (await q(`SELECT count(*)::int n FROM caja_movimientos WHERE venta_id = $1`, [v3.id]))[0].n, 0);

grupo('Permisos');
const vVale = await vender(vend2, [{ producto_id: TERMO, cantidad: 2, precio_unitario: 1000 }]);
const [itV] = await items(vVale.id);
await falla('un vendedor no edita la venta de otra', () => quitar(vend, vVale.id, [{ item_id: itV.id, quitar: 1 }]), /sin_permiso/);
await q(`UPDATE ventas SET fecha = now() - interval '2 days' WHERE id = $1`, [v2.id]);
await falla('ni una suya de hace más de 24 h', () => quitar(vend, v2.id, [{ item_id: it2.id, quitar: 1 }]), /sin_permiso/);
await pasa('el admin (editar todas) sí', () => quitar(admin, vVale.id, [{ item_id: itV.id, quitar: 1 }]));
await admin(`SELECT permisos_rol_guardar('vendedor', ARRAY['ventas.crear','caja.ver'])`);
await falla('sin el permiso, ni las propias', () => quitar(vend, v3.id, [{ item_id: itC.id, quitar: 1 }]), /sin_permiso/);
await falla('un renglón de otra venta', () => quitar(admin, v3.id, [{ item_id: itV.id, quitar: 1 }]), /item_no_encontrado/);
await falla('escribir el registro de ediciones a mano', () => vend(`INSERT INTO venta_ediciones (venta_id, motivo, detalle, total_anterior, total_nuevo, diferencia) VALUES (1,'x','[]',0,0,0)`), /permission denied|row-level/);
t('el vendedor ve las ediciones de sus ventas, no las de otros', (await vend(`SELECT array_agg(DISTINCT venta_id ORDER BY venta_id) v FROM venta_ediciones`))[0].v, [v1.id, v2.id, v3.id]);

console.log(`\n${ok} pasadas, ${fail} fallidas\n`);
process.exit(fail ? 1 : 0);
