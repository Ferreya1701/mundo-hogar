/**
 * Pruebas de las cuentas bancarias en la caja (sql/025-caja-cuentas-bancarias.sql)
 * contra un Postgres REAL en memoria (PGlite).
 *
 *   node scripts/test-caja-cuentas-sql.mjs
 *
 * Prueba que la caja reparte igual que la web (límites diario y mensual, peso,
 * respaldo), que las reservas evitan que dos cajas llenen la misma cuenta, que
 * la venta consume cupo y anular / quitar productos lo devuelve, que nunca
 * frena una venta, y que sin cuentas activas todo sigue como antes.
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








const vender = (quien, total, medio = 'transferencia', extra = {}) => quien(`SELECT venta_registrar($1::jsonb) AS r`,
  [JSON.stringify({ items: [{ producto_id: 2, cantidad: 2, precio_unitario: total / 2 }], medio_pago: medio, ...extra })]).then(r => r[0].r);
const pedir = (quien, monto, excluir = null) => quien(`SELECT caja_cuenta_pedir($1, $2::bigint[]) r`, [monto, excluir]).then(r => r[0].r);
const tomado = async id => Number((await q(`SELECT fn_cuenta_acumulado($1, date_trunc('month', fn_mh_local(now()))) x`, [id]))[0].x);
const movs = async ventaId => (await q(`SELECT tipo, monto::float m, cuenta_cobro_id::int c FROM movimientos_cobro WHERE venta_id = $1 ORDER BY id`, [ventaId]));

grupo('Sin cuentas activas: todo como antes');
let err = null;
try { await db.exec(leerSQL('025-caja-cuentas-bancarias.sql')); await db.exec(leerSQL('025-caja-cuentas-bancarias.sql')); } catch (e) { err = e.message; }
t('025 corre limpio, dos veces seguidas', err, null);
if (err) { console.log(`\n${ok} pasadas, ${fail} fallidas\n`); process.exit(1); }
t('pedir cuenta: no hay', (await pedir(vend, 10000)).motivo, 'sin_cuentas');
const v0 = await vender(vend, 10000);
t('la venta por transferencia se registra igual, sin cuenta', [v0.ok, v0.cuenta_cobro, v0.aviso_cuenta], [true, null, null]);

// Tres cuentas: A (límite diario 100.000, peso 5), B (límite mensual 300.000, peso 5), R (respaldo, sin límites)
await admin(`INSERT INTO cuentas_cobro (nombre, titular, alias, cvu, peso, orden, limite_diario, limite_mensual, es_respaldo) VALUES
  ('Cuenta A', 'Ana A', 'ana.mp', NULL, 5, 1, 100000, NULL, false),
  ('Cuenta B', 'Beto B', NULL, '0000003100012345678901', 5, 2, NULL, 300000, false)`);
const [A, B] = (await q(`SELECT id::int FROM cuentas_cobro ORDER BY orden`)).map(r => r.id);

grupo('La caja reparte igual que la web');
const p1 = await pedir(vend, 60000);
t('asigna la cuenta que elegiría la web', p1.cuenta.id, A);
t('muestra alias, titular y banco, sin CUIT ni límites', Object.keys(p1.cuenta).sort(), ['alias', 'banco', 'cvu', 'es_respaldo', 'id', 'nombre', 'titular']);
t('la reserva ya cuenta como tomada', await tomado(A), 60000);
t('otra caja, a la vez, pide 60.000: A no tiene cupo diario → B', (await pedir(vend2, 60000)).cuenta.id, B);
t('volver a pedir reemplaza la reserva propia (no se acumula)', [(await pedir(vend, 60000)).cuenta.id, await tomado(A)], [A, 60000]);
const v1 = await vender(vend, 60000, 'transferencia', { cuenta_cobro_id: A, nro_operacion: ' 123456 ' });
t('la venta queda en esa cuenta y devuelve sus datos', [v1.cuenta_cobro.id, v1.cuenta_cobro.alias, v1.aviso_cuenta], [A, 'ana.mp', null]);
t('queda asentada como cobro de la cuenta, con el N° de operación', (await q(`SELECT tipo, monto::float m, nro_operacion n, detalle LIKE 'Venta en el local VL-%' d FROM movimientos_cobro WHERE venta_id = $1`, [v1.id])),
  [{ tipo: 'cobro', m: 60000, n: '123456', d: true }]);
t('la reserva se soltó: tomado = el cobro, no el doble', await tomado(A), 60000);
t('la web ahora elige B para 60.000 (mismo cálculo)', (await q(`SELECT fn_cobros_elegir_cuenta(60000)::int x`))[0].x, B);
t('y para 30.000 sigue eligiendo A (le queda cupo y está más descansada… no: tiene 60.000 vs B con la reserva de Vale)',
  [(await q(`SELECT fn_cobros_elegir_cuenta(30000)::int x`))[0].x, await tomado(B)], [A, 60000]);
await vend2(`SELECT caja_cuenta_soltar()`);
t('soltar la reserva libera el cupo', await tomado(B), 0);

grupo('Sin elegir cuenta: la asigna el sistema');
const v2 = await vender(vend, 50000, 'mercadopago');
t('Mercado Pago sin cuenta → B (A no tiene cupo diario para 50.000)', [v2.cuenta_cobro.id, (await movs(v2.id))[0]], [B, { tipo: 'cobro', m: 50000, c: B }]);
const vEf = await vender(vend, 5000, 'efectivo', { cuenta_cobro_id: A });
t('en efectivo no hay cuenta aunque la manden', [vEf.cuenta_cobro, (await movs(vEf.id)).length], [null, 0]);

grupo('Límites');
t('pedir 250.000: B (ya tiene 50.000) + 250.000 = justo el límite mensual → entra', (await pedir(vend, 250000)).cuenta.id, B);
t('pedir 250.001: ninguna tiene cupo y no hay respaldo', [(await pedir(vend, 250001)).cuenta, (await pedir(vend, 250001)).motivo], [null, 'sin_cupo']);
await admin(`INSERT INTO cuentas_cobro (nombre, titular, alias, peso, orden, es_respaldo) VALUES ('Respaldo', 'Rita R', 'rita.resp', 1, 9, true)`);
const R = (await q(`SELECT id::int FROM cuentas_cobro WHERE es_respaldo`))[0].id;
await q(`UPDATE cuentas_cobro SET limite_mensual = 1000 WHERE id = $1`, [R]);
const pr = await pedir(vend, 400000);
t('con respaldo: la usa y avisa', [pr.cuenta.id, /respaldo/.test(pr.aviso)], [R, true]);
await q(`UPDATE cuentas_cobro SET limite_mensual = NULL WHERE id = $1`, [R]);
t('"dame otra" excluye la que no sirve', (await pedir(vend, 20000, [A])).cuenta.id !== A, true);
const sola = await pedir(vend, 20000, [A, B, R]);
t('si no hay otra, devuelve la mejor (la menos cargada según su peso) y lo dice', [sola.cuenta.id, sola.aviso], [R, 'No hay otra cuenta con cupo para este monto.']);

grupo('La caja nunca frena: la plata ya se transfirió');
const v3 = await vender(vend, 90000, 'transferencia', { cuenta_cobro_id: A });   // A: 60.000 + 90.000 > 100.000 diarios
t('se registra igual en esa cuenta', [v3.ok, v3.cuenta_cobro.id], [true, A]);
t('y avisa que pasó el límite de hoy', /pasó su límite de hoy/.test(v3.aviso_cuenta), true);
t('una cuenta que no existe se ignora y se asigna otra', (await vender(vend, 1000, 'transferencia', { cuenta_cobro_id: 99999 })).cuenta_cobro.id !== 99999, true);

grupo('Anular y quitar productos devuelven el cupo');
const antesB = await tomado(B);
await vend(`SELECT venta_anular($1, 'se arrepintió')`, [v2.id]);
t('anular: movimiento de anulación en la misma cuenta', await movs(v2.id), [{ tipo: 'cobro', m: 50000, c: B }, { tipo: 'anulacion', m: 50000, c: B }]);
t('el cupo vuelve', antesB - await tomado(B), 50000);
await vend(`SELECT venta_anular($1, 'otra vez')`, [v2.id]);
t('anular dos veces no duplica', (await movs(v2.id)).length, 2);
const it = (await q(`SELECT id FROM venta_items WHERE venta_id = $1`, [v1.id]))[0].id;
await vend(`SELECT venta_quitar_items($1, $2::jsonb, 'llevó una sola')`, [v1.id, JSON.stringify([{ item_id: it, quitar: 1 }])]);
t('quitar una unidad devuelve la mitad del cupo', await movs(v1.id), [{ tipo: 'cobro', m: 60000, c: A }, { tipo: 'anulacion', m: 30000, c: A }]);

grupo('Caja del día y liquidación');
await vend(`SELECT caja_abrir(0)`);
const pc = (await vend(`SELECT caja_por_cuenta() r`))[0].r;
t('la caja muestra cuánto entró a cada cuenta', pc.map(x => [x.cuenta, Number(x.total)]).sort(), [['Cuenta A', 120000], ['Respaldo', 1000], ['Sin cuenta asignada', 10000]].sort());   // A: 30.000 (60.000 − 30.000 quitados) + 90.000; B: anulada → no aparece
t('las ventas del local entran al resumen de Cuentas bancarias', Number((await admin(`SELECT cobrado_mes FROM v_cuentas_cobro_resumen WHERE id = $1`, [A]))[0].cobrado_mes), 120000);

grupo('Seguridad');
await q(`UPDATE profiles SET activo = false WHERE id = $1`, [EX]);
await falla('cuenta desactivada no pide cuenta', () => pedir(ex, 1000), /sin_permiso/);
await falla('anónimo tampoco', () => anon(`SELECT caja_cuenta_pedir(1000)`), /permission denied/);
await falla('las reservas no se leen ni se tocan a mano', () => vend(`SELECT * FROM cobro_reservas`), /permission denied/);
t('el vendedor sigue sin ver CUIT ni límites de las cuentas', await cuantos(vend, 'cuentas_cobro'), 0);

console.log(`\n${ok} pasadas, ${fail} fallidas\n`);
process.exit(fail ? 1 : 0);
