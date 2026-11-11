/**
 * Pruebas de cuentas corrientes (sql/019-cuentas-corrientes.sql) contra un
 * Postgres REAL en memoria (PGlite), sin tocar Supabase.
 *
 *   npm i --no-save --prefix scripts @electric-sql/pglite   (una sola vez)
 *   node scripts/test-cc-sql.mjs
 *
 * Corre 001..019 y prueba: recargo por categoría (solo en cuenta corriente,
 * lo pone la base), límite de crédito, cuentas suspendidas, pagos con recibo
 * que entran a la caja, anulaciones, ajustes, vencimientos y permisos.
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



const CEL = 3, TERMO = 2;
const vender = (quien, items, medio = 'efectivo', extra = {}) => quien(`SELECT venta_registrar($1::jsonb) AS r`,
  [JSON.stringify({ items, medio_pago: medio, ...extra })]).then(r => r[0].r);
const cuenta = async id => (await q(`SELECT saldo::float s, habilitada FROM cc_cuentas WHERE id = $1`, [id]))[0];
const movsCC = async id => (await q(`SELECT tipo, monto::float m, saldo_posterior::float s FROM cc_movimientos WHERE cuenta_id = $1 ORDER BY id`, [id]));
const estado = async (id, hoy) => (await q(`SELECT fn_cc_estado($1, $2::date) e`, [id, hoy]))[0].e;

grupo('Migración');
let err = null, res = null;
const SQL019 = leerSQL('019-cuentas-corrientes.sql');
try { await db.exec(SQL019); res = (await db.exec(SQL019)).at(-1).rows[0]; } catch (e) { err = e.message; }
t('019 corre limpio, dos veces seguidas', err, null);
if (err) { console.log(`\n${ok} pasadas, ${fail} fallidas\n`); process.exit(1); }
t('7 permisos, 2 conceptos de caja', res, { permisos_cc: 7, cuentas: 0, conceptos_caja: 2 });
t('vendedor: ver, vender y cobrar', (await vend(`SELECT fn_mis_permisos() p`))[0].p.filter(x => x.startsWith('cc.')), ['cc.ver', 'cc.vender', 'cc.cobrar']);
t('encargado: solo vender', (await stock(`SELECT fn_mis_permisos() p`))[0].p.filter(x => x.startsWith('cc.')), ['cc.vender']);
await falla('las ventas viejas siguen andando (venta común)', () => vender(vend, [{ producto_id: TERMO, cantidad: 1 }]).then(() => { throw new Error('ok'); }), /^ok$/);

grupo('Recargo por categoría');
await falla('el vendedor no cambia recargos', () => vend(`SELECT cc_recargo_guardar(2, 20000)`), /sin_permiso/);
await admin(`SELECT permisos_rol_guardar('encargado_stock', ARRAY['ventas.crear','categorias.editar','cc.vender'])`);
await falla('quien edita categorías no toca el recargo sin el permiso', () => stock(`UPDATE categorias SET recargo_cc = 1 WHERE id = 2`), /sin_permiso/);
await pasa('pero sí el resto de la categoría', () => stock(`UPDATE categorias SET descripcion = 'Smartphones' WHERE id = 2`));
const rg = (await admin(`SELECT cc_recargo_guardar(2, 20000) r`))[0].r;
t('el admin pone +$20.000 a Celulares', [rg.anterior, rg.recargo_cc], [0, 20000]);
t('queda en el historial', (await q(`SELECT count(*)::int n FROM historial_actividad WHERE entidad = 'recargo_cc'`))[0].n, 1);
await falla('recargo negativo', () => admin(`SELECT cc_recargo_guardar(2, -5)`), /monto_invalido/);

grupo('Abrir cuentas');
await falla('el vendedor no abre cuentas', () => vend(`SELECT cc_cuenta_guardar('{"contacto":{"nombre":"Juan"}}'::jsonb)`), /sin_permiso/);
const c1 = (await admin(`SELECT cc_cuenta_guardar($1::jsonb) r`, [JSON.stringify({ contacto: { nombre: 'Juan Pérez', telefono: '342 555-1234', cuit: '20-11111111-2' }, limite: 500000, dia_pago: 10 })]))[0].r;
t('cliente nuevo + cuenta', [c1.ok, c1.nueva], [true, true]);
t('el cliente quedó en el CRM', (await q(`SELECT nombre, canal_origen FROM crm_contactos WHERE id = $1`, [c1.contacto_id]))[0], { nombre: 'Juan Pérez', canal_origen: 'mostrador' });
await falla('el mismo cliente (mismo teléfono) no abre dos cuentas', () => admin(`SELECT cc_cuenta_guardar($1::jsonb)`, [JSON.stringify({ contacto: { nombre: 'Juancito', telefono: '3425551234' } })]), /cuenta_existente/);
await falla('día de pago 31', () => admin(`SELECT cc_cuenta_guardar('{"contacto":{"nombre":"Ana"},"dia_pago":31}'::jsonb)`), /dia_invalido/);
const c2 = (await admin(`SELECT cc_cuenta_guardar('{"contacto":{"nombre":"Ana Gómez"},"dia_pago":5}'::jsonb) r`))[0].r;
const J = c1.cuenta_id, A = c2.cuenta_id;

grupo('Vender en cuenta corriente');
await falla('sin elegir cliente', () => vender(vend, [{ producto_id: CEL, cantidad: 1 }], 'cuenta_corriente'), /cuenta_requerida/);
await falla('supera el límite (2 celulares = 640.000 > 500.000)', () => vender(vend, [{ producto_id: CEL, cantidad: 2 }], 'cuenta_corriente', { cc_cuenta_id: J }), /limite_superado/);
t('y no quedó nada a medias', [(await cuenta(J)).s, (await q(`SELECT count(*)::int n FROM ventas WHERE cc_cuenta_id = $1`, [J]))[0].n], [0, 0]);
const v1 = await vender(vend, [{ producto_id: CEL, cantidad: 1 }, { producto_id: TERMO, cantidad: 1, precio_unitario: 12000 }, { nombre: 'Funda', cantidad: 1, precio_unitario: 5000 }],
  'cuenta_corriente', { cc_cuenta_id: J, retira_nombre: 'María (esposa)', cliente_nombre: 'esto se ignora' });
t('el celular sale 320.000 (300.000 + recargo); termo y funda sin recargo',
  v1.items.map(i => [i.nombre, Number(i.precio_unitario), Number(i.recargo_unitario)]),
  [['Celular X', 320000, 20000], ['Termo 1L', 12000, 0], ['Funda', 5000, 0]]);
t('total 337.000 con 20.000 de recargo', [Number(v1.total), Number(v1.recargo_total)], [337000, 20000]);
t('cliente y teléfono salen de la ficha; queda quién retira', [v1.cliente_nombre, v1.retira_nombre], ['Juan Pérez', 'María (esposa)']);
t('saldo anterior y actual para el ticket', [Number(v1.cuenta_corriente.saldo_anterior), Number(v1.cuenta_corriente.saldo_actual)], [0, 337000]);
t('la deuda quedó asentada', await movsCC(J), [{ tipo: 'cargo', m: 337000, s: 337000 }]);
t('no entra a la caja', (await q(`SELECT count(*)::int n FROM caja_movimientos WHERE venta_id = $1`, [v1.id]))[0].n, 0);
const vComun = await vender(vend, [{ producto_id: CEL, cantidad: 1 }]);
t('en efectivo el celular no lleva recargo', Number(vComun.total), 300000);
await falla('la vendedora no puede "esquivar" el recargo bajando el precio a mano: igual se suma',
  async () => { const v = await vender(vend, [{ producto_id: CEL, cantidad: 1, precio_unitario: 100 }], 'cuenta_corriente', { cc_cuenta_id: A }); throw new Error('precio ' + v.items[0].precio_unitario); }, /precio 20100/);
const vEnc = await vender(stock, [{ producto_id: TERMO, cantidad: 1, precio_unitario: 1000 }], 'cuenta_corriente', { cc_cuenta_id: A });
t('el encargado (con "vender en cuenta corriente") también vende', vEnc.ok, true);
await admin(`SELECT permisos_rol_guardar('vendedor', ARRAY['ventas.crear','cc.ver','cc.cobrar'])`);
await falla('sin ese permiso, no', () => vender(vend, [{ producto_id: TERMO, cantidad: 1 }], 'cuenta_corriente', { cc_cuenta_id: A }), /sin_permiso/);
await pasa('pero sí vende en efectivo', () => vender(vend, [{ producto_id: TERMO, cantidad: 1 }]));
await admin(`SELECT permisos_rol_guardar('vendedor', ARRAY['ventas.crear','ventas.anular_propias','cc.ver','cc.vender','cc.cobrar','caja.ver','caja.abrir_cerrar','caja.movimientos'])`);
const pasado = await vender(admin, [{ producto_id: CEL, cantidad: 1 }], 'cuenta_corriente', { cc_cuenta_id: J });
t('con "vender por encima del límite" (admin) pasa igual', Number((await cuenta(J)).s), 337000 + 320000);

grupo('Suspender');
await admin(`SELECT cc_cuenta_guardar($1::jsonb)`, [JSON.stringify({ cuenta_id: A, habilitada: false })]);
await falla('cuenta suspendida no compra', () => vender(vend, [{ producto_id: TERMO, cantidad: 1 }], 'cuenta_corriente', { cc_cuenta_id: A }), /cuenta_suspendida/);
await admin(`SELECT cc_cuenta_guardar($1::jsonb)`, [JSON.stringify({ cuenta_id: A, habilitada: true })]);

grupo('Pagos');
await vend(`SELECT caja_abrir(0)`);
const espAntes = Number((await admin(`SELECT caja_resumen() r`))[0].r.efectivo.esperado);
const p1 = (await vend(`SELECT cc_pago_registrar($1::jsonb) r`, [JSON.stringify({ cuenta_id: J, monto: 157000, medio_pago: 'efectivo' })]))[0].r;
t('recibo numerado con saldo anterior y actual', [p1.recibo.numero, Number(p1.recibo.saldo_anterior), Number(p1.recibo.saldo_actual), p1.recibo.cliente_nombre],
  ['R-000001', 657000, 500000, 'Juan Pérez']);
t('el cobro entró a la caja en efectivo', (await q(`SELECT tipo, monto::float m, medio_pago, concepto_nombre c FROM caja_movimientos WHERE origen = 'cobro_cc'`)),
  [{ tipo: 'ingreso', m: 157000, medio_pago: 'efectivo', c: 'Cobro cuenta corriente' }]);
t('y suma 157.000 al efectivo esperado', Number((await admin(`SELECT caja_resumen() r`))[0].r.efectivo.esperado) - espAntes, 157000);
await falla('no se paga "en cuenta corriente"', () => vend(`SELECT cc_pago_registrar($1::jsonb)`, [JSON.stringify({ cuenta_id: J, monto: 1, medio_pago: 'cuenta_corriente' })]), /medio_invalido/);
await falla('el encargado no cobra', () => stock(`SELECT cc_pago_registrar($1::jsonb)`, [JSON.stringify({ cuenta_id: J, monto: 1 })]), /sin_permiso/);
const p2 = (await vend(`SELECT cc_pago_registrar($1::jsonb) r`, [JSON.stringify({ cuenta_id: J, monto: 50000, medio_pago: 'transferencia' })]))[0].r;
t('segundo recibo R-000002 por transferencia', p2.recibo.numero, 'R-000002');

grupo('Anular');
await vend(`SELECT venta_anular($1, 'devolvió todo')`, [v1.id]);
t('anular la venta baja la deuda sola', (await movsCC(J)).at(-1), { tipo: 'devolucion', m: 337000, s: 113000 });
await falla('el vendedor no anula pagos', () => vend(`SELECT cc_pago_anular($1, 'x')`, [p2.id]), /sin_permiso/);
await admin(`SELECT cc_pago_anular($1, 'la transferencia rebotó')`, [p2.id]);
t('anular el pago vuelve la deuda', (await movsCC(J)).at(-1), { tipo: 'pago_anulado', m: 50000, s: 163000 });
t('y sale de la caja por el mismo medio', (await q(`SELECT tipo, medio_pago, concepto_nombre c FROM caja_movimientos ORDER BY id DESC LIMIT 1`))[0],
  { tipo: 'egreso', medio_pago: 'transferencia', c: 'Anulación cobro cuenta corriente' });
t('el pago queda marcado', (await q(`SELECT anulado, motivo_anulacion FROM cc_movimientos WHERE id = $1`, [p2.id]))[0], { anulado: true, motivo_anulacion: 'la transferencia rebotó' });
await falla('no se anula una compra desde acá', async () => admin(`SELECT cc_pago_anular($1, 'x')`, [(await q(`SELECT id FROM cc_movimientos WHERE tipo = 'cargo' LIMIT 1`))[0].id]), /no_anulable/);

grupo('Ajustes');
await falla('el vendedor no ajusta', () => vend(`SELECT cc_ajuste('{"cuenta_id":1,"tipo":"ajuste_debito","monto":1,"motivo":"x"}'::jsonb)`), /sin_permiso/);
await falla('sin motivo', () => admin(`SELECT cc_ajuste($1::jsonb)`, [JSON.stringify({ cuenta_id: A, tipo: 'ajuste_debito', monto: 1000 })]), /motivo_requerido/);
const aj = (await admin(`SELECT cc_ajuste($1::jsonb) r`, [JSON.stringify({ cuenta_id: A, tipo: 'ajuste_debito', monto: 45000, motivo: 'Saldo inicial (libreta)' })]))[0].r;
t('saldo inicial cargado', Number(aj.saldo_actual), 20100 + 1000 + 45000);

grupo('Nada se toca a mano');
await falla('UPDATE del saldo desde el panel', () => admin(`UPDATE cc_cuentas SET saldo = 0 WHERE id = $1`, [J]), /permission denied|cc_inmutable/);
await falla('ni el dueño de la base sin pasar por las funciones', () => q(`UPDATE cc_cuentas SET saldo = 0 WHERE id = $1`, [J]), /cc_inmutable/);
await falla('ni borrar movimientos', () => q(`DELETE FROM cc_movimientos`), /cc_inmutable/);
await pasa('cambiar el día de pago sí (no toca el saldo)', () => q(`UPDATE cc_cuentas SET dia_pago = 12 WHERE id = $1`, [A]));
t('cada movimiento cuadra con el anterior', (await q(`SELECT bool_and(saldo_posterior = (SELECT c.saldo FROM cc_cuentas c WHERE c.id = m.cuenta_id)) ok FROM cc_movimientos m
  WHERE id IN (SELECT max(id) FROM cc_movimientos GROUP BY cuenta_id)`))[0].ok, true);

grupo('Vencimientos (día de pago 10, todo comprado en noviembre 2026)');
await admin(`SELECT cc_cuenta_guardar($1::jsonb)`, [JSON.stringify({ cuenta_id: J, dia_pago: 10 })]);
const hoyMes = (await q(`SELECT to_char(now() AT TIME ZONE 'America/Argentina/Buenos_Aires', 'YYYY-MM') m`))[0].m;
const [yy, mm] = hoyMes.split('-').map(Number);
const f = (y, m, d) => { const x = new Date(Date.UTC(y, m - 1 + 0, d)); return x.toISOString().slice(0, 10); };
const mes = k => { const d = new Date(Date.UTC(yy, mm - 1 + k, 1)); return [d.getUTCFullYear(), d.getUTCMonth() + 1]; };
const e0 = await estado(J, f(...mes(0), 11));
t('este mes: nada vencido; vence el 10 del mes que viene, todo el saldo', [Number(e0.vencido), e0.proximo_vencimiento, Number(e0.a_pagar_proximo)], [0, f(...mes(1), 10), 163000]);
const e1 = await estado(J, f(...mes(1), 5));
t('el 5 del mes que viene: todavía no venció', [Number(e1.vencido), e1.proximo_vencimiento], [0, f(...mes(1), 10)]);
const e2 = await estado(J, f(...mes(1), 11));
t('el 11 del mes que viene: vencido todo lo que se debe', [Number(e2.vencido), e2.proximo_vencimiento], [163000, f(...mes(2), 10)]);
await vend(`SELECT cc_pago_registrar($1::jsonb)`, [JSON.stringify({ cuenta_id: J, monto: 63000 })]);
t('un pago baja primero lo vencido', Number((await estado(J, f(...mes(1), 11))).vencido), 100000);
t('disponible = límite − saldo', Number((await estado(J)).disponible), 400000);

grupo('Quién ve qué');
t('el vendedor ve las cuentas con saldo y vencimiento', (await vend(`SELECT nombre, saldo::float s FROM v_cc_cuentas ORDER BY nombre`)),
  [{ nombre: 'Ana Gómez', s: 66100 }, { nombre: 'Juan Pérez', s: 100000 }]);
t('el encargado (sin "ver") no ve cuentas ni movimientos', [await cuantos(stock, 'v_cc_cuentas'), await cuantos(stock, 'cc_movimientos'), await cuantos(stock, 'cc_cuentas')], [0, 0, 0]);
t('pero puede buscar al cliente para venderle', (await stock(`SELECT cc_buscar('juan') r`))[0].r.map(x => [x.nombre, Number(x.saldo)]), [['Juan Pérez', 100000]]);
t('busca por teléfono también', (await stock(`SELECT cc_buscar('5551234') r`))[0].r.length, 1);
await q(`UPDATE profiles SET activo = false WHERE id = $1`, [EX]);
await falla('cuenta desactivada no busca', () => ex(`SELECT cc_buscar('')`), /sin_permiso/);
t('ni ve el estado de una cuenta', (await ex(`SELECT fn_cc_estado(1) e`))[0].e, null);
await falla('anónimo no ve nada', () => anon(`SELECT * FROM v_cc_cuentas`), /permission denied/);

console.log(`\n${ok} pasadas, ${fail} fallidas\n`);
process.exit(fail ? 1 : 0);
