/**
 * Pruebas de "la venta se cobra en la caja, con pago mixto" (sql/026-cobrar-en-caja.sql)
 * contra un Postgres REAL en memoria (PGlite).
 *
 *   node scripts/test-cobrar-en-caja-sql.mjs
 *
 * Prueba que la venta nace esperando cobro (sin plata asentada, con el stock ya
 * reservado), que la cajera cobra con uno o varios medios y cada parte cae donde
 * corresponde (caja por medio, cuenta bancaria con sus límites), que devolver /
 * cancelar / quitar productos / anular dejan todo cuadrado, y los permisos.
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









const FREIDORA = 1, TERMO = 2;
await db.exec(`SELECT set_config('request.jwt.claim.sub', '${ADMIN}', false)`);
await q(`SELECT fn_stock_contar(1, 10)`);           // la freidora lleva stock: 10
await db.exec(`SELECT set_config('request.jwt.claim.sub', '', false)`);
await admin(`INSERT INTO cuentas_cobro (nombre, titular, alias, peso, orden, limite_diario) VALUES ('Cuenta A', 'Ana A', 'ana.mp', 5, 1, 100000)`);
const CTA = (await q(`SELECT id::int FROM cuentas_cobro`))[0].id;
// Una venta de antes del 026 (cobrada en efectivo, sin pagos cargados)
await db.exec(`SELECT set_config('request.jwt.claim.sub', '${VEND}', false)`);
const vieja = (await q(`SELECT venta_registrar('{"items":[{"producto_id":2,"cantidad":1,"precio_unitario":1000}],"medio_pago":"efectivo"}'::jsonb) r`))[0].r;
await db.exec(`SELECT set_config('request.jwt.claim.sub', '', false)`);

const vender = (quien, items, extra = {}) => quien(`SELECT venta_registrar($1::jsonb) AS r`, [JSON.stringify({ items, ...extra })]).then(r => r[0].r);
const cobrar = (quien, id, pagos) => quien(`SELECT venta_cobrar($1, $2::jsonb) r`, [id, JSON.stringify(pagos)]).then(r => r[0].r);
const venta = async id => (await q(`SELECT estado, medio_pago, total::float t, cobrada_por_nombre cp, cuenta_cobro_id::int c, devuelta_motivo dm FROM ventas WHERE id = $1`, [id]))[0];
const caja = async id => (await q(`SELECT tipo, medio_pago m, monto::float x, usuario_nombre u FROM caja_movimientos WHERE venta_id = $1 ORDER BY id`, [id]));
const neto = async id => Object.fromEntries((await q(`SELECT medio_pago m, sum(CASE tipo WHEN 'ingreso' THEN monto ELSE -monto END)::float x FROM caja_movimientos WHERE venta_id = $1 GROUP BY 1 ORDER BY 1`, [id])).map(r => [r.m, r.x]));
const banco = async id => (await q(`SELECT tipo, monto::float x, cuenta_cobro_id::int c, nro_operacion n FROM movimientos_cobro WHERE venta_id = $1 ORDER BY id`, [id]));
const stockF = async () => (await q(`SELECT stock_actual FROM productos WHERE id = 1`))[0].stock_actual;

grupo('Migración');
let err = null, res = null;
const SQL026 = leerSQL('026-cobrar-en-caja.sql');
try { await db.exec(SQL026); res = (await db.exec(SQL026)).at(-1).rows[0]; } catch (e) { err = e.message; }
t('026 corre limpio, dos veces seguidas', err, null);
if (err) { console.log(`\n${ok} pasadas, ${fail} fallidas\n`); process.exit(1); }
t('las ventas van a caja', res.ventas_van_a_caja, true);
t('la venta vieja sigue cobrada y con su ingreso en efectivo', [(await venta(vieja.id)).estado, await neto(vieja.id)], ['cerrada', { efectivo: 1000 }]);
t('vendedor: tiene "cobrar en caja"; encargado: no', [(await vend(`SELECT fn_tiene_permiso('caja.cobrar') x`))[0].x, (await stock(`SELECT fn_tiene_permiso('caja.cobrar') x`))[0].x], [true, false]);

grupo('La vendedora envía a caja');
const v1 = await vender(vend, [{ producto_id: FREIDORA, cantidad: 2, precio_unitario: 45000 }, { producto_id: TERMO, cantidad: 1, precio_unitario: 10000 }], { medio_pago: 'efectivo', cliente_nombre: 'Juan' });
t('la venta nace esperando cobro, aunque el panel mande un medio', [v1.estado, (await venta(v1.id)).estado, (await venta(v1.id)).medio_pago], ['pendiente_cobro', 'pendiente_cobro', 'pendiente']);
t('la mercadería ya quedó reservada (stock 10 → 8)', await stockF(), 8);
t('todavía no entró plata a la caja ni a ninguna cuenta', [await caja(v1.id), await banco(v1.id)], [[], []]);
const cta = (await admin(`SELECT cc_cuenta_guardar('{"contacto":{"nombre":"Carla CC"}}'::jsonb) r`))[0].r.cuenta_id;
const vcc = await vender(vend, [{ producto_id: TERMO, cantidad: 1, precio_unitario: 5000 }], { medio_pago: 'cuenta_corriente', cc_cuenta_id: cta });
t('cuenta corriente NO pasa por caja: queda cerrada y cargada a la cuenta', [vcc.estado, Number((await q(`SELECT saldo FROM cc_cuentas WHERE id = $1`, [cta]))[0].saldo), await caja(vcc.id)], ['cerrada', 5000, []]);

grupo('Quién ve la fila de la caja');
t('otra vendedora con "cobrar en caja" ve la venta que espera', (await vend2(`SELECT count(*)::int n FROM ventas WHERE estado = 'pendiente_cobro'`))[0].n, 1);
t('con sus renglones', (await vend2(`SELECT count(*)::int n FROM venta_items WHERE venta_id = $1`, [v1.id]))[0].n, 2);
await admin(`SELECT permisos_rol_guardar('encargado_stock', ARRAY['ventas.crear','caja.ver'])`);
t('el encargado (sin ese permiso) no la ve', (await stock(`SELECT count(*)::int n FROM ventas WHERE estado = 'pendiente_cobro'`))[0].n, 0);

grupo('Cobrar');
await falla('con la caja cerrada no se cobra', () => cobrar(vend2, v1.id, [{ medio: 'efectivo', monto: 100000 }]), /caja_cerrada/);
await vend2(`SELECT caja_abrir(0)`);
await falla('el encargado no cobra', () => cobrar(stock, v1.id, [{ medio: 'efectivo', monto: 100000 }]), /sin_permiso/);
await falla('los pagos tienen que sumar el total', () => cobrar(vend2, v1.id, [{ medio: 'efectivo', monto: 99999 }]), /pagos_no_suman/);
await falla('no se cobra "en cuenta corriente" desde la caja', () => cobrar(vend2, v1.id, [{ medio: 'cuenta_corriente', monto: 100000 }]), /medio_invalido/);
t('un cobro rechazado no deja nada a medias', [(await venta(v1.id)).estado, (await q(`SELECT count(*)::int n FROM venta_pagos WHERE venta_id = $1`, [v1.id]))[0].n], ['pendiente_cobro', 0]);
const c1 = await cobrar(vend2, v1.id, [{ medio: 'efectivo', monto: 40000 }, { medio: 'transferencia', monto: 50000, nro_operacion: '7788' }, { medio: 'debito', monto: 10000 }]);
t('pago mixto: queda cerrada, "mixto", cobrada por la cajera', [(await venta(v1.id)).estado, (await venta(v1.id)).medio_pago, (await venta(v1.id)).cp], ['cerrada', 'mixto', 'Vale Ventas']);
t('cada parte entra a la caja por su medio, a nombre de la cajera', await caja(v1.id),
  [{ tipo: 'ingreso', m: 'debito', x: 10000, u: 'Vale Ventas' }, { tipo: 'ingreso', m: 'efectivo', x: 40000, u: 'Vale Ventas' }, { tipo: 'ingreso', m: 'transferencia', x: 50000, u: 'Vale Ventas' }]);
t('la parte por transferencia se asignó a la cuenta y cuenta para su límite', [await banco(v1.id), c1.pagos.find(p => p.medio === 'transferencia').cuenta.alias],
  [[{ tipo: 'cobro', x: 50000, c: CTA, n: '7788' }], 'ana.mp']);
t('el resultado trae todo para el ticket', [c1.codigo.startsWith('VL-'), c1.items.length, c1.pagos.length, c1.cliente_nombre], [true, 2, 3, 'Juan']);
t('solo el efectivo suma al cajón (40.000 + los 1.000 de la venta vieja, que estaba pendiente de caja)', Number((await vend2(`SELECT caja_resumen() r`))[0].r.efectivo.esperado), 41000);
await falla('no se cobra dos veces', () => cobrar(vend2, v1.id, [{ medio: 'efectivo', monto: 100000 }]), /venta_ya_cobrada/);
t('la cajera sigue viendo lo que cobró (para reimprimir)', (await vend2(`SELECT count(*)::int n FROM ventas WHERE id = $1`, [v1.id]))[0].n, 1);

grupo('Quitar productos y anular una venta con pago mixto');
const itF = (await q(`SELECT id FROM venta_items WHERE venta_id = $1 AND producto_id = 1`, [v1.id]))[0].id;
await vend(`SELECT venta_quitar_items($1, $2::jsonb, 'llevó una sola')`, [v1.id, JSON.stringify([{ item_id: itF, quitar: 1 }])]);
t('devuelve 45.000: primero todo el efectivo (40.000) y el resto del medio más grande', await neto(v1.id), { debito: 10000, efectivo: 0, transferencia: 45000 });
t('y la cuenta bancaria recupera esos 5.000 de cupo', (await banco(v1.id)).at(-1), { tipo: 'anulacion', x: 5000, c: CTA, n: null });
await admin(`SELECT venta_anular($1, 'devolvió todo')`, [v1.id]);
t('anular deja la caja en cero por cada medio', await neto(v1.id), { debito: 0, efectivo: 0, transferencia: 0 });
t('y la cuenta bancaria en cero', (await q(`SELECT sum(CASE tipo WHEN 'cobro' THEN monto ELSE -monto END)::float x FROM movimientos_cobro WHERE venta_id = $1`, [v1.id]))[0].x, 0);
t('el stock volvió entero', await stockF(), 10);
await admin(`SELECT venta_anular($1, 'error')`, [vieja.id]);
t('anular una venta vieja (sin pagos cargados) devuelve por su medio', await neto(vieja.id), { efectivo: 0 });

grupo('Devolver a la vendedora, corregir y volver a mandar');
const v2 = await vender(vend, [{ producto_id: FREIDORA, cantidad: 3, precio_unitario: 45000 }]);
await falla('devolver exige decir por qué', () => vend2(`SELECT venta_devolver($1, ' ')`, [v2.id]), /motivo_requerido/);
await vend2(`SELECT venta_devolver($1, 'el cliente quiere dos, no tres')`, [v2.id]);
t('queda marcada con el motivo', (await venta(v2.id)).dm, 'el cliente quiere dos, no tres');
const it2 = (await q(`SELECT id FROM venta_items WHERE venta_id = $1`, [v2.id]))[0].id;
await vend(`SELECT venta_quitar_items($1, $2::jsonb, 'quiere dos')`, [v2.id, JSON.stringify([{ item_id: it2, quitar: 1 }])]);
t('la vendedora quita uno antes de cobrar: baja el total, vuelve el stock, sigue sin plata', [(await venta(v2.id)).t, await stockF(), await caja(v2.id)], [90000, 8, []]);
await falla('otra persona sin permiso de caja no la reenvía', () => stock(`SELECT venta_reenviar_a_caja($1)`, [v2.id]), /sin_permiso/);
await vend(`SELECT venta_reenviar_a_caja($1)`, [v2.id]);
t('reenviada: se limpia el motivo', (await venta(v2.id)).dm, null);
const c2 = await cobrar(vend2, v2.id, [{ medio: 'efectivo', monto: 90000 }]);
t('un solo medio: la venta queda con ese medio', [(await venta(v2.id)).medio_pago, await neto(v2.id)], ['efectivo', { efectivo: 90000 }]);

grupo('Cancelar desde la caja y límites de la cuenta');
const v3 = await vender(vend, [{ producto_id: FREIDORA, cantidad: 1, precio_unitario: 45000 }]);
await vend2(`SELECT venta_anular($1, 'el cliente se fue')`, [v3.id]);
t('la cajera cancela una venta ajena que esperaba cobro: vuelve el stock, sin plata', [(await venta(v3.id)).estado, await stockF(), await caja(v3.id)], ['anulada', 8, []]);
await falla('una cancelada no se cobra', () => cobrar(vend2, v3.id, [{ medio: 'efectivo', monto: 45000 }]), /venta_no_cobrable/);
const v4 = await vender(vend, [{ producto_id: TERMO, cantidad: 1, precio_unitario: 120000 }]);
const c4 = await cobrar(vend2, v4.id, [{ medio: 'transferencia', monto: 120000, cuenta_cobro_id: CTA }]);
t('transferencia que pasa el límite diario: se cobra igual y avisa', [(await venta(v4.id)).estado, (await venta(v4.id)).c, /pasó su límite de hoy/.test(c4.avisos[0] || '')], ['cerrada', CTA, true]);

grupo('Seguridad');
await falla('anónimo no cobra', () => anon(`SELECT venta_cobrar(1, '[]'::jsonb)`), /permission denied/);
await falla('los pagos no se escriben a mano', () => vend2(`INSERT INTO venta_pagos (venta_id, medio_pago, monto, monto_original) VALUES (1,'efectivo',1,1)`), /permission denied/);
t('el encargado no ve pagos de ventas ajenas', (await stock(`SELECT count(*)::int n FROM venta_pagos`))[0].n, 0);

console.log(`\n${ok} pasadas, ${fail} fallidas\n`);
process.exit(fail ? 1 : 0);
