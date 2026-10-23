/**
 * Pruebas de los cobros por transferencia (sql/012-cobros.sql) contra un
 * Postgres REAL en memoria (PGlite), sin tocar Supabase.
 *
 *   npm i --no-save --prefix scripts @electric-sql/pglite   (una sola vez)
 *   node scripts/test-cobros-sql.mjs
 *
 * Qué prueba:
 *   1. El 012 corre limpio dos veces (idempotente) sobre 001..011.
 *   2. Reparto entre cuentas: la que menos acumuló, pesos, límites, respaldo.
 *   3. Flujo público: consultar, habilitar pago (centavos únicos), subir
 *      comprobante, lectura de la IA (coincide / no coincide / ilegible).
 *   4. Confirmar pago: movimiento, pedido confirmado, stock descontado.
 *   5. Rechazar, anular, vencer, confirmación automática, permisos por rol.
 *   6. Liquidación mensual.
 */
import fs from 'fs';
import path from 'path';
import { fileURLToPath, pathToFileURL } from 'url';

const RAIZ = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const leerSQL = f => fs.readFileSync(path.join(RAIZ, 'sql', f), 'utf8');

async function cargarPGlite() {
  try { return (await import('@electric-sql/pglite')).PGlite; } catch (_) { /* sigue */ }
  if (process.env.PGLITE_DIR) {
    const p = path.join(process.env.PGLITE_DIR, 'node_modules', '@electric-sql', 'pglite', 'dist', 'index.js');
    return (await import(pathToFileURL(p).href)).PGlite;
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

const PGlite = await cargarPGlite();
const db = new PGlite();

await db.exec(`
CREATE SCHEMA auth;
CREATE TABLE auth.users (id UUID PRIMARY KEY, email TEXT, raw_user_meta_data JSONB DEFAULT '{}'::jsonb);
CREATE FUNCTION auth.uid() RETURNS UUID LANGUAGE sql STABLE AS
  $f$ SELECT nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $f$;
CREATE ROLE anon NOLOGIN;
CREATE ROLE authenticated NOLOGIN;
GRANT USAGE ON SCHEMA public, auth TO anon, authenticated;
GRANT EXECUTE ON FUNCTION auth.uid() TO anon, authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO anon, authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO anon, authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT EXECUTE ON FUNCTIONS TO anon, authenticated;
`);
await db.exec(leerSQL('001-schema.sql').replace(/CREATE EXTENSION[^;]*;/i, ''));
for (const f of ['002-rls-policies.sql', '005-solicitudes.sql', '007-nucleo-stock.sql', '008-blindaje-stock.sql',
                 '009-crm.sql', '010-bot-whatsapp.sql', '011-crm-conversacion.sql']) {
  await db.exec(leerSQL(f));
}

const ADMIN = '00000000-0000-0000-0000-00000000000a';
const VEND  = '00000000-0000-0000-0000-00000000000b';
const STOCK = '00000000-0000-0000-0000-00000000000c';
await db.exec(`
INSERT INTO auth.users (id, email, raw_user_meta_data) VALUES
  ('${ADMIN}', 'ana@mh.test',    '{"nombre":"Ana Admin","rol":"administrador"}'),
  ('${VEND}',  'vero@mh.test',   '{"nombre":"Vero Ventas","rol":"vendedor"}'),
  ('${STOCK}', 'sergio@mh.test', '{"nombre":"Sergio Stock","rol":"encargado_stock"}');
INSERT INTO productos (nombre, precio_minorista, seguimiento_inventario, stock_actual) VALUES
  ('Freidora de aire 5L', 45000, true, 0),
  ('Lavarropas 8kg', NULL, false, 0),
  ('Termo 1L', 12000.50, false, 0);
`);

async function como(rol, uid, sql, params = []) {
  return db.transaction(async tx => {
    await tx.exec(`SET LOCAL ROLE ${rol}`);
    await tx.query(`SELECT set_config('request.jwt.claim.sub', $1, true)`, [uid ?? '']);
    const r = await tx.query(sql, params);
    return Object.assign(r.rows, { afectadas: r.affectedRows });
  });
}
const anon  = (sql, p) => como('anon', '', sql, p);
const vend  = (sql, p) => como('authenticated', VEND, sql, p);
const admin = (sql, p) => como('authenticated', ADMIN, sql, p);
const stock = (sql, p) => como('authenticated', STOCK, sql, p);
const q     = async (sql, p) => (await db.query(sql, p)).rows;   // dueño (SQL Editor / service role)

async function falla(nombre, fn, patron) {
  try { await fn(); t(nombre, 'no falló', 'falla con ' + patron); }
  catch (e) { t(nombre, patron.test(e.message) ? 'falló bien' : e.message, 'falló bien'); }
}

const pedido = (nombre, telefono, items, extra = {}) =>
  anon(`SELECT crear_solicitud($1::jsonb) AS r`, [JSON.stringify({ nombre, telefono, items, ...extra })])
    .then(r => r[0].r);
const sol = async codigo => (await q(`SELECT * FROM solicitudes WHERE codigo = $1`, [codigo]))[0];

// Stock inicial por la vía legal (el 008 bloquea el UPDATE directo)
await admin(`SELECT fn_registrar_movimiento(1, 'carga_inicial', 10, 'Carga inicial')`);

// ── Migración ─────────────────────────────────────────────────────
grupo('Migración');
let errorMigracion = null;
const SQL012 = leerSQL('012-cobros.sql');
try { await db.exec(SQL012); await db.exec(SQL012); } catch (e) { errorMigracion = e.message; }
t('012 corre limpio, dos veces seguidas', errorMigracion, null);
if (errorMigracion) { console.log(`\n${ok} pasadas, ${fail} fallidas\n`); process.exit(1); }
t('site_settings tiene la fila 1 con cobros apagados',
  (await q(`SELECT cobros_activos, cobros_plazo_horas, comision_pct FROM site_settings WHERE id = 1`))[0],
  { cobros_activos: false, cobros_plazo_horas: 72, comision_pct: '0.00' });

// ── Cuentas ───────────────────────────────────────────────────────
grupo('Cuentas de cobro');
await falla('un vendedor no puede crear cuentas', () =>
  vend(`INSERT INTO cuentas_cobro (nombre, titular, alias) VALUES ('x','x','x.y.z')`), /row-level security/);
await admin(`INSERT INTO cuentas_cobro (nombre, titular, alias, cvu, peso, orden, limite_mensual) VALUES
  ('Cuenta A', 'Juan Pérez',  'mh.juan.mp',  '0000003100012345678901', 5, 1, NULL),
  ('Cuenta B', 'María López', 'mh.maria.mp', '0000003100098765432109', 5, 2, NULL),
  ('Cuenta C', 'Pedro Gómez', 'mh.pedro.mp', NULL, 5, 3, 50000)`);
t('el staff ve las cuentas', (await vend(`SELECT count(*)::int AS n FROM cuentas_cobro`))[0].n, 3);
t('un vendedor NO ve movimientos', (await vend(`SELECT count(*)::int AS n FROM movimientos_cobro`))[0].n, 0);
await falla('alias o CVU obligatorio', () =>
  admin(`INSERT INTO cuentas_cobro (nombre, titular) VALUES ('sin destino','x')`), /cuentas_cobro_destino/);

// ── Flujo público ─────────────────────────────────────────────────
grupo('Flujo público: consultar y habilitar');
const p1 = await pedido('Juan Cliente', '+54 9 342 555-1111', [{ id: 1, cantidad: 2 }]);   // 90000
await falla('cobros apagados: no se puede pagar', () =>
  anon(`SELECT pedido_pagar_transferencia($1, $2)`, [p1.codigo, '3425551111']), /cobros_inactivos/);
await q(`UPDATE site_settings SET cobros_activos = true WHERE id = 1`);
await falla('teléfono equivocado', () =>
  anon(`SELECT pedido_consultar($1, $2)`, [p1.codigo, '3420000000']), /pedido_no_encontrado/);
let v = (await anon(`SELECT pedido_consultar($1, $2) AS r`, [p1.codigo, '0342 15 555 1111']))[0].r;
t('consultar: total, puede_pagar, sin cuenta todavía',
  [v.total, v.puede_pagar, v.estado_pago, v.cuenta], [90000, true, 'sin_pago', null]);
let pago = (await anon(`SELECT pedido_pagar_transferencia($1, $2) AS r`, [p1.codigo, '3425551111']))[0].r;
t('habilitar: cuenta A (orden 1, todas en cero) y centavos distintivos',
  [pago.cuenta.alias, Math.floor(pago.monto), pago.monto > 90000 && pago.monto < 90001], ['mh.juan.mp', 90000, true]);
let pago2 = (await anon(`SELECT pedido_pagar_transferencia($1, $2) AS r`, [p1.codigo, '3425551111']))[0].r;
t('habilitar de nuevo: mismo monto y cuenta (idempotente)', [pago2.sin_cambios, pago2.monto], [true, pago.monto]);
v = (await anon(`SELECT pedido_consultar($1, $2) AS r`, [p1.codigo, '3425551111']))[0].r;
t('consultar: ahora muestra alias, CVU, titular y vencimiento',
  [v.estado_pago, v.cuenta.titular, v.cuenta.cvu, !!v.vence_en], ['pendiente', 'Juan Pérez', '0000003100012345678901', true]);

const p2 = await pedido('Ana Cliente', '3425552222', [{ id: 1, cantidad: 1 }]);   // 45000
const pagoB = (await anon(`SELECT pedido_pagar_transferencia($1, $2) AS r`, [p2.codigo, '3425552222']))[0].r;
t('segundo pedido: va a la cuenta B (A ya tiene 90000 comprometidos)', pagoB.cuenta.alias, 'mh.maria.mp');
const p3 = await pedido('Luis Cliente', '3425553333', [{ id: 1, cantidad: 1 }]);   // 45000
const pagoC = (await anon(`SELECT pedido_pagar_transferencia($1, $2) AS r`, [p3.codigo, '3425553333']))[0].r;
t('tercer pedido: cuenta C (45000 entra en su límite de 50000)', pagoC.cuenta.alias, 'mh.pedro.mp');
const p4 = await pedido('Eva Cliente', '3425554444', [{ id: 1, cantidad: 1 }]);
const pagoD = (await anon(`SELECT pedido_pagar_transferencia($1, $2) AS r`, [p4.codigo, '3425554444']))[0].r;
t('cuarto: C ya no entra (45000+45000 > 50000); B tiene 45000 < A 90000 → B', pagoD.cuenta.alias, 'mh.maria.mp');

const pSinPrecio = await pedido('Sin Precio', '3425559999', [{ id: 2, cantidad: 1 }]);
await falla('pedido a cotizar no se puede pagar online', () =>
  anon(`SELECT pedido_pagar_transferencia($1, $2)`, [pSinPrecio.codigo, '3425559999']), /pedido_a_cotizar|pedido_sin_total/);

// Pesos: una cuenta con peso 10 recibe el doble que una con peso 5
grupo('Pesos y respaldo');
await admin(`UPDATE cuentas_cobro SET peso = 10 WHERE nombre = 'Cuenta A'`);
const p5 = await pedido('Peso Test', '3425555555', [{ id: 1, cantidad: 1 }]);
const pagoE = (await anon(`SELECT pedido_pagar_transferencia($1, $2) AS r`, [p5.codigo, '3425555555']))[0].r;
t('con peso 10, A (90000/10=9000) gana a B (90000/5=18000)', pagoE.cuenta.alias, 'mh.juan.mp');
await admin(`UPDATE cuentas_cobro SET activa = false WHERE nombre IN ('Cuenta A','Cuenta B')`);
await admin(`UPDATE cuentas_cobro SET limite_mensual = 1 WHERE nombre = 'Cuenta C'`);
const p6 = await pedido('Sin Cuenta', '3425556666', [{ id: 1, cantidad: 1 }]);
await falla('ninguna cuenta puede y no hay respaldo', () =>
  anon(`SELECT pedido_pagar_transferencia($1, $2)`, [p6.codigo, '3425556666']), /sin_cuenta_cobro/);
await admin(`UPDATE cuentas_cobro SET es_respaldo = true WHERE nombre = 'Cuenta C'`);
const pagoF = (await anon(`SELECT pedido_pagar_transferencia($1, $2) AS r`, [p6.codigo, '3425556666']))[0].r;
t('con respaldo marcado, C toma el pedido aunque pase su límite', pagoF.cuenta.alias, 'mh.pedro.mp');
await admin(`UPDATE cuentas_cobro SET activa = true, es_respaldo = false, limite_mensual = NULL`);

// ── Comprobantes y lectura ────────────────────────────────────────
grupo('Comprobante y lectura de la IA');
await falla('archivo fuera de la carpeta del pedido', () =>
  anon(`SELECT pedido_subir_comprobante($1, $2, $3, $4, $5)`, [p1.codigo, '3425551111', 'OTRO/x.jpg', 'image/jpeg', 100]), /archivo_invalido/);
await falla('sin pago habilitado no se sube comprobante', () =>
  anon(`SELECT pedido_subir_comprobante($1, $2, $3, $4, $5)`, [pSinPrecio.codigo, '3425559999', pSinPrecio.codigo + '/a.jpg', 'image/jpeg', 100]), /pedido_sin_pago_pendiente/);
let sub = (await anon(`SELECT pedido_subir_comprobante($1, $2, $3, $4, $5) AS r`,
  [p1.codigo, '3425551111', p1.codigo + '/comp1.jpg', 'image/jpeg', 120000]))[0].r;
t('subir comprobante: queda recibido', [sub.ok, sub.estado_pago, (await sol(p1.codigo)).estado_pago],
  [true, 'comprobante_recibido', 'comprobante_recibido']);
await falla('el panel no puede registrar lecturas (solo la función con clave de servicio)', () =>
  admin(`SELECT comprobante_registrar_lectura($1, '{}'::jsonb)`, [sub.comprobante_id]), /permission denied/);

const montoA = (await sol(p1.codigo)).monto_a_pagar;
let lec = (await q(`SELECT comprobante_registrar_lectura($1, $2::jsonb) AS r`, [sub.comprobante_id, JSON.stringify({
  legible: true, monto: Number(montoA) + 10, fecha: '2026-10-23', destino_alias: 'mh.juan.mp', nro_operacion: 'OP-1', confianza: 90 })]))[0].r;
t('monto distinto → no_coincide con motivo', [lec.estado, /Monto leído/.test(lec.motivo)], ['no_coincide', true]);
t('el pedido pasa a en_revision', (await sol(p1.codigo)).estado_pago, 'en_revision');

let sub2 = (await anon(`SELECT pedido_subir_comprobante($1, $2, $3, $4, $5) AS r`,
  [p1.codigo, '3425551111', p1.codigo + '/comp2.jpg', 'image/jpeg', 120000]))[0].r;
lec = (await q(`SELECT comprobante_registrar_lectura($1, $2::jsonb) AS r`, [sub2.comprobante_id, JSON.stringify({
  legible: true, monto: montoA, fecha: '2026-10-23', destino_alias: 'MH.JUAN.MP', nro_operacion: 'OP-2', confianza: 92 })]))[0].r;
t('monto y alias correctos (alias sin distinguir mayúsculas) → coincide', [lec.estado, lec.motivo, lec.auto], ['coincide', null, null]);

let sub3 = (await anon(`SELECT pedido_subir_comprobante($1, $2, $3, $4, $5) AS r`,
  [p1.codigo, '3425551111', p1.codigo + '/comp3.jpg', 'image/jpeg', 120000]))[0].r;
lec = (await q(`SELECT comprobante_registrar_lectura($1, $2::jsonb) AS r`, [sub3.comprobante_id, JSON.stringify({
  legible: true, monto: montoA, fecha: '2026-10-23', destino_cvu: '0000003100098765432109', confianza: 92 })]))[0].r;
t('CVU de otra cuenta → no_coincide', [lec.estado, /Cuenta destino/.test(lec.motivo)], ['no_coincide', true]);

let sub4 = (await anon(`SELECT pedido_subir_comprobante($1, $2, $3, $4, $5) AS r`,
  [p1.codigo, '3425551111', p1.codigo + '/comp4.jpg', 'image/jpeg', 120000]))[0].r;
lec = (await q(`SELECT comprobante_registrar_lectura($1, $2::jsonb) AS r`, [sub4.comprobante_id, JSON.stringify({ legible: false, confianza: 10 })]))[0].r;
t('ilegible', lec.estado, 'ilegible');
await falla('máximo 5 comprobantes por pedido', async () => {
  await anon(`SELECT pedido_subir_comprobante($1, $2, $3, $4, $5)`, [p1.codigo, '3425551111', p1.codigo + '/comp5.jpg', 'image/jpeg', 1]);
  await anon(`SELECT pedido_subir_comprobante($1, $2, $3, $4, $5)`, [p1.codigo, '3425551111', p1.codigo + '/comp6.jpg', 'image/jpeg', 1]);
}, /limite_comprobantes/);

// Mismo número de operación en otro pedido
let subB = (await anon(`SELECT pedido_subir_comprobante($1, $2, $3, $4, $5) AS r`,
  [p2.codigo, '3425552222', p2.codigo + '/c.jpg', 'image/jpeg', 100]))[0].r;
lec = (await q(`SELECT comprobante_registrar_lectura($1, $2::jsonb) AS r`, [subB.comprobante_id, JSON.stringify({
  legible: true, monto: (await sol(p2.codigo)).monto_a_pagar, destino_alias: 'mh.maria.mp', nro_operacion: 'OP-2', confianza: 95 })]))[0].r;
t('número de operación repetido en otro pedido → no_coincide', [lec.estado, /ya se usó/.test(lec.motivo)], ['no_coincide', true]);

// ── Confirmar ─────────────────────────────────────────────────────
grupo('Confirmar pago');
await falla('encargado de stock no confirma pagos', async () =>
  stock(`SELECT confirmar_pago($1, $2)`, [(await sol(p1.codigo)).id, sub2.comprobante_id]), /sin_permiso/);
const idP1 = (await sol(p1.codigo)).id;
let conf = (await vend(`SELECT confirmar_pago($1, $2) AS r`, [idP1, sub2.comprobante_id]))[0].r;
t('vendedor confirma: pagado, pedido confirmado, 1 movimiento de stock',
  [conf.ok, conf.estado_pago, conf.estado, conf.movimientos_stock, conf.monto], [true, 'pagado', 'confirmado', 1, Number(montoA)]);
t('stock descontado (10 - 2 = 8)', (await q(`SELECT stock_actual FROM productos WHERE id = 1`))[0].stock_actual, 8);
let s1 = await sol(p1.codigo);
t('solicitud: pagado_en, monto_pagado', [s1.estado_pago, s1.estado, !!s1.pagado_en, s1.monto_pagado], ['pagado', 'confirmado', true, montoA]);
t('comprobante aceptado', (await q(`SELECT estado FROM comprobantes WHERE id = $1`, [sub2.comprobante_id]))[0].estado, 'aceptado');
t('movimiento en la cuenta A', (await admin(`SELECT count(*)::int AS n, sum(monto) AS s FROM movimientos_cobro WHERE solicitud_id = $1 AND tipo = 'cobro'`, [idP1]))[0], { n: 1, s: montoA });
conf = (await vend(`SELECT confirmar_pago($1, $2) AS r`, [idP1, sub2.comprobante_id]))[0].r;
t('confirmar dos veces no duplica', [conf.sin_cambios, (await admin(`SELECT count(*)::int AS n FROM movimientos_cobro WHERE solicitud_id = $1`, [idP1]))[0].n], [true, 1]);
await falla('con el pago confirmado, rechazar el comprobante aceptado no se puede', () =>
  vend(`SELECT rechazar_comprobante($1, 'x')`, [sub2.comprobante_id]), /comprobante_aceptado/);
t('la vista de resumen suma el cobro', (await admin(`SELECT cobrado_mes, cobros_mes::int AS n FROM v_cuentas_cobro_resumen WHERE nombre = 'Cuenta A'`))[0], { cobrado_mes: montoA, n: 1 });

// Confirmar sin stock suficiente: todo se deshace
grupo('Confirmar sin stock: se deshace todo');
const pGrande = await pedido('Grande', '3425557777', [{ id: 1, cantidad: 50 }]);
await vend(`SELECT habilitar_pago($1)`, [(await sol(pGrande.codigo)).id]);
await falla('stock insuficiente al confirmar', async () =>
  vend(`SELECT confirmar_pago($1)`, [(await sol(pGrande.codigo)).id]), /stock_insuficiente/);
t('no quedó movimiento ni pago', [(await sol(pGrande.codigo)).estado_pago,
  (await admin(`SELECT count(*)::int AS n FROM movimientos_cobro WHERE solicitud_id = $1`, [(await sol(pGrande.codigo)).id]))[0].n], ['pendiente', 0]);

// ── Rechazar / anular / vencer ────────────────────────────────────
grupo('Rechazar, anular y vencer');
await falla('rechazar sin motivo', () => vend(`SELECT rechazar_comprobante($1, '')`, [subB.comprobante_id]), /motivo_requerido/);
await vend(`SELECT rechazar_comprobante($1, 'El número de operación es de otro pedido')`, [subB.comprobante_id]);
t('rechazado y el pedido vuelve a pendiente', [(await q(`SELECT estado FROM comprobantes WHERE id = $1`, [subB.comprobante_id]))[0].estado,
  (await sol(p2.codigo)).estado_pago], ['rechazado', 'pendiente']);
v = (await anon(`SELECT pedido_consultar($1, $2) AS r`, [p2.codigo, '3425552222']))[0].r;
t('el cliente ve el motivo del rechazo', v.comprobantes[0].motivo, 'El número de operación es de otro pedido');

await falla('vendedor no anula pagos', () => vend(`SELECT anular_pago($1, 'x')`, [idP1]), /sin_permiso/);
let an = (await admin(`SELECT anular_pago($1, 'Transferencia rebotada') AS r`, [idP1]))[0].r;
t('anular: pendiente, movimiento de anulación, saldo de la cuenta en 0',
  [an.estado_pago, (await admin(`SELECT cobrado_mes FROM v_cuentas_cobro_resumen WHERE nombre = 'Cuenta A'`))[0].cobrado_mes,
   (await admin(`SELECT count(*)::int AS n FROM movimientos_cobro WHERE solicitud_id = $1 AND tipo = 'anulacion'`, [idP1]))[0].n],
  ['pendiente', '0.00', 1]);
t('el pedido sigue confirmado (el stock no se toca al anular el pago)', (await sol(p1.codigo)).estado, 'confirmado');

await q(`UPDATE solicitudes SET pago_vence_en = now() - interval '1 hour' WHERE codigo IN ($1, $2)`, [p3.codigo, p1.codigo]);
v = (await anon(`SELECT pedido_consultar($1, $2) AS r`, [p3.codigo, '3425553333']))[0].r;
t('pendiente sin comprobante y vencido → vencido, y puede volver a pagar', [v.estado_pago, v.puede_pagar], ['vencido', true]);
v = (await anon(`SELECT pedido_consultar($1, $2) AS r`, [p1.codigo, '3425551111']))[0].r;
t('pendiente CON comprobantes no vence', v.estado_pago, 'pendiente');
const re = (await anon(`SELECT pedido_pagar_transferencia($1, $2) AS r`, [p3.codigo, '3425553333']))[0].r;
t('volver a habilitar un vencido: nuevo monto y cuenta', [re.ok, re.sin_cambios], [true, undefined]);

// ── Confirmación automática ───────────────────────────────────────
grupo('Confirmación automática');
await q(`UPDATE site_settings SET cobros_auto_confirmar = true WHERE id = 1`);
const pAuto = await pedido('Auto', '3425558888', [{ id: 3, cantidad: 2 }]);   // 24001 (12000.50 x 2)
const hab = (await anon(`SELECT pedido_pagar_transferencia($1, $2) AS r`, [pAuto.codigo, '3425558888']))[0].r;
t('total con centavos se redondea hacia arriba antes de los centavos distintivos', Math.floor(hab.monto), 24001);
let subA = (await anon(`SELECT pedido_subir_comprobante($1, $2, $3, $4, $5) AS r`,
  [pAuto.codigo, '3425558888', pAuto.codigo + '/c.pdf', 'application/pdf', 100]))[0].r;
lec = (await q(`SELECT comprobante_registrar_lectura($1, $2::jsonb) AS r`, [subA.comprobante_id, JSON.stringify({
  legible: true, monto: hab.monto, fecha: '2026-10-23', destino_alias: hab.cuenta.alias, nro_operacion: 'OP-AUTO', confianza: 97 })]))[0].r;
t('coincide + auto → pagado y confirmado sin usuario', [lec.estado, lec.auto.ok, (await sol(pAuto.codigo)).estado_pago, (await sol(pAuto.codigo)).estado],
  ['coincide', true, 'pagado', 'confirmado']);
await q(`UPDATE site_settings SET cobros_auto_confirmar = false WHERE id = 1`);

// Habilitar desde el panel con monto manual (cotización)
grupo('Habilitar desde el panel');
await falla('vendedor con monto cero', async () =>
  vend(`SELECT habilitar_pago($1, 0)`, [(await sol(pSinPrecio.codigo)).id]), /monto_invalido/);
const habP = (await vend(`SELECT habilitar_pago($1, 150000) AS r`, [(await sol(pSinPrecio.codigo)).id]))[0].r;
t('cotización con monto manual: habilitada', [habP.ok, Math.floor(habP.monto)], [true, 150000]);
v = (await anon(`SELECT pedido_consultar($1, $2) AS r`, [pSinPrecio.codigo, '3425559999']))[0].r;
t('el cliente ve la cuenta y el monto cotizado', [v.estado_pago, !!v.cuenta, Math.floor(v.monto_a_pagar)], ['pendiente', true, 150000]);
await falla('con comprobante en revisión no se cambia el monto', async () => {
  await anon(`SELECT pedido_subir_comprobante($1, $2, $3, $4, $5)`, [pSinPrecio.codigo, '3425559999', pSinPrecio.codigo + '/c.jpg', 'image/jpeg', 1]);
  await vend(`SELECT habilitar_pago($1, 99999)`, [(await sol(pSinPrecio.codigo)).id]);
}, /pedido_con_comprobante/);

// Confirmar un pago sin cuenta asignada (pagó por otro medio) indicando la cuenta
const pManual = await pedido('Manual', '3425550000', [{ id: 3, cantidad: 1 }]);
await falla('confirmar sin cuenta asignada ni indicada', async () =>
  vend(`SELECT confirmar_pago($1)`, [(await sol(pManual.codigo)).id]), /sin_cuenta/);
const ctaB = (await q(`SELECT id FROM cuentas_cobro WHERE nombre = 'Cuenta B'`))[0].id;
conf = (await vend(`SELECT confirmar_pago($1, NULL, 12000.50, 'EFECTIVO', NULL, 'Pagó en el local', $2) AS r`, [(await sol(pManual.codigo)).id, ctaB]))[0].r;
t('confirmación manual con cuenta y monto', [conf.ok, conf.monto, conf.estado], [true, 12000.5, 'confirmado']);

// ── Liquidación ───────────────────────────────────────────────────
grupo('Liquidación');
await q(`UPDATE site_settings SET comision_pct = 5 WHERE id = 1`);
await falla('vendedor no cierra liquidaciones', () => vend(`SELECT cerrar_liquidacion('2026-09')`), /sin_permiso/);
await falla('mes en curso no se cierra', () => admin(`SELECT cerrar_liquidacion(to_char(now(), 'YYYY-MM'))`), /periodo_abierto/);
// Movemos los cobros a septiembre para cerrarlo
await q(`UPDATE movimientos_cobro SET fecha = '2026-09-15 12:00:00-03'`);
let liq = (await admin(`SELECT cerrar_liquidacion('2026-09') AS r`))[0].r;
const esperado = (await q(`SELECT sum(CASE WHEN tipo='cobro' THEN monto ELSE -monto END) AS s FROM movimientos_cobro`))[0].s;
t('liquidación: total = cobros - anulaciones, comisión 5%', [liq.total_cobrado, liq.comision, liq.porcentaje],
  [Number(esperado), Math.round(Number(esperado) * 5) / 100, 5]);
await falla('no se cierra dos veces', () => admin(`SELECT cerrar_liquidacion('2026-09')`), /liquidacion_ya_cerrada/);
t('detalle por cuenta guardado', (await admin(`SELECT jsonb_array_length(detalle->'cuentas')::int AS n FROM liquidaciones`))[0].n > 0, true);
t('vendedor no ve liquidaciones', (await vend(`SELECT count(*)::int AS n FROM liquidaciones`))[0].n, 0);

// ── Guardas de datos ──────────────────────────────────────────────
grupo('Guardas');
await falla('anon no lee cuentas', async () => {
  const r = await anon(`SELECT count(*)::int AS n FROM cuentas_cobro`);
  if (r[0].n === 0) throw new Error('rls_ok');
}, /rls_ok/);
await falla('anon no lee comprobantes', async () => {
  const r = await anon(`SELECT count(*)::int AS n FROM comprobantes`);
  if (r[0].n === 0) throw new Error('rls_ok');
}, /rls_ok/);
await falla('el panel no puede escribir movimientos a mano', () =>
  vend(`INSERT INTO movimientos_cobro (cuenta_cobro_id, tipo, monto) VALUES (${ctaB}, 'cobro', 1)`), /row-level security/);
await falla('el guard del 007 sigue: no se cambia estado a mano', () =>
  vend(`UPDATE solicitudes SET estado = 'entregado' WHERE id = ${idP1}`), /estado_solo_por_rpc/);

console.log(`\n${ok} pasadas, ${fail} fallidas\n`);
process.exit(fail ? 1 : 0);
