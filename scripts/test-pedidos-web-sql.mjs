/**
 * Pruebas: pedidos web en el mismo circuito (sql/028-pedidos-web-en-circuito.sql)
 * contra un Postgres REAL en memoria (PGlite).
 *
 *   node scripts/test-pedidos-web-sql.mjs
 *
 * Un pedido web pasa al mostrador → venta. Pagado online: queda pagada sin
 * tocar la caja. Sin pagar: se cobra en la caja al retirar. El stock no se
 * descuenta dos veces. Entregar / anular la venta mueve el pedido.
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











const hoyStock = async id => (await q(`SELECT stock_actual::int s FROM productos WHERE id = $1`, [id]))[0].s;
const sol = async id => (await q(`SELECT estado, estado_pago, venta_id::int v, stock_descontado sd FROM solicitudes WHERE id = $1`, [id]))[0];
const venta = async id => (await q(`SELECT estado, medio_pago, origen, entrega_tipo, entrega_estado, envio_localidad, total::int total, cobrada_por_nombre FROM ventas WHERE id = $1`, [id]))[0];
const cajaVenta = async id => (await q(`SELECT count(*)::int n FROM caja_movimientos WHERE venta_id = $1`, [id]))[0].n;
const cobrosVenta = async id => (await q(`SELECT count(*)::int n FROM movimientos_cobro WHERE venta_id = $1`, [id]))[0].n;
let nPed = 0;
async function pedido({ entrega = 'retiro', items = [[FREIDORA, 2, 45000]], pago = 'sin_pago', pagado = 0, direccion = null, localidad = null } = {}) {
  nPed++;
  const [s] = await q(`INSERT INTO solicitudes (codigo, cliente_nombre, telefono, tipo_entrega, direccion, localidad, estado_pago, monto_pagado, total_estimado)
     VALUES ($1, 'Laura Web', '3424000000', $2, $3, $4, $5, $6, 0) RETURNING id::int`, [`MH-W${nPed}`, entrega, direccion, localidad, pago, pagado]);
  for (const [pid, cant, precio] of items)
    await q(`INSERT INTO solicitud_items (solicitud_id, producto_id, nombre, cantidad, precio_unitario, subtotal) VALUES ($1, $2::int, coalesce((SELECT nombre FROM productos WHERE id = $2::int), 'Algo'), $3::int, $4::numeric, $3::int * $4::numeric)`, [s.id, pid, cant, precio]);
  return s.id;
}
const pasar = (quien, id, o = {}) => quien(`SELECT pedido_a_venta($1, $2::jsonb) r`, [id, JSON.stringify(o)]).then(r => r[0].r);
const FREIDORA = 1, TERMO = 2;
await db.exec(`SET mh.stock = '1'; UPDATE productos SET stock_actual = 10, stock_controlado = true WHERE id = 1; RESET mh.stock;`);

grupo('Migración');
let err = null;
const SQL = leerSQL('028-pedidos-web-en-circuito.sql');
try { await db.exec(SQL); await db.exec(SQL); } catch (e) { err = e.message; }
t('028 corre limpio, dos veces seguidas', err, null);
if (err) { console.log(`\n${ok} pasadas, ${fail} fallidas\n`); process.exit(1); }

grupo('Pedido sin pagar → se cobra en la caja al retirar');
const p1 = await pedido();
await falla('el encargado de stock sin permiso de pedidos no lo pasa', () => pasar(stock, p1), /sin_permiso/);
const r1 = await pasar(vend, p1);
t('queda una venta web esperando cobro, para retirar', await venta(r1.id), { estado: 'pendiente_cobro', medio_pago: 'pendiente', origen: 'web', entrega_tipo: 'retiro', entrega_estado: 'pendiente', envio_localidad: null, total: 90000, cobrada_por_nombre: null });
t('el pedido queda confirmado y apuntando a la venta', [(await sol(p1)).estado, (await sol(p1)).v], ['confirmado', r1.id]);
t('el stock lo descontó la venta (una vez)', await hoyStock(FREIDORA), 8);
await falla('no se pasa dos veces', () => pasar(vend, p1), /pedido_ya_en_venta/);
await falla('ni se cancela desde Pedidos', () => vend(`SELECT cambiar_estado_solicitud($1, 'cancelado')`, [p1]), /pedido_en_venta/);
await falla('ni se entrega desde Pedidos', () => vend(`SELECT cambiar_estado_solicitud($1, 'entregado')`, [p1]), /pedido_en_venta/);
await falla('no sale sin pagar', () => stock(`SELECT venta_entregar(ARRAY[$1]::bigint[])`, [r1.id]), /sin_pagar/);
await vend2(`SELECT caja_abrir(0)`);
await vend2(`SELECT venta_cobrar($1, '[{"medio":"efectivo","monto":90000}]'::jsonb)`, [r1.id]);
t('la caja la cobra en efectivo', [(await venta(r1.id)).estado, await cajaVenta(r1.id)], ['cerrada', 1]);
await stock(`SELECT venta_entregar(ARRAY[$1]::bigint[], '{"recibio_nombre":"Laura"}'::jsonb)`, [r1.id]);
t('entregada → el pedido queda entregado', (await sol(p1)).estado, 'entregado');
await stock(`SELECT venta_entrega_deshacer($1, 'error')`, [r1.id]);
t('deshecha la entrega → el pedido vuelve a confirmado', (await sol(p1)).estado, 'confirmado');

grupo('Pedido ya pagado online → venta pagada, sin tocar la caja');
const p2 = await pedido({ entrega: 'envio', direccion: 'Bv. Gálvez 100', localidad: 'Santo Tomé', pago: 'pagado', pagado: 90000.37 });
const r2 = await pasar(vend, p2);
t('pagada con medio "web", lista para enviar', [r2.estado, r2.pagada_online, (await venta(r2.id)).medio_pago, (await venta(r2.id)).entrega_tipo, (await venta(r2.id)).envio_localidad], ['cerrada', true, 'web', 'envio', 'Santo Tomé']);
t('no entra a la caja ni a la cuenta bancaria (ya se registró en Pedidos)', [await cajaVenta(r2.id), await cobrosVenta(r2.id)], [0, 0]);
t('se puede despachar', (await stock(`SELECT venta_entregar(ARRAY[$1]::bigint[]) r`, [r2.id]))[0].r.entregadas, 1);
const p3 = await pedido({ pago: 'pagado', pagado: 50000 });
await falla('si pagó menos de lo que suma: no se pasa', () => pasar(vend, p3), /pago_web_incompleto/);
t('y no quedó nada a medias', [(await sol(p3)).v, (await sol(p3)).estado, await hoyStock(FREIDORA)], [null, 'nueva', 6]);

grupo('Stock ya descontado por el pedido');
const p4 = await pedido({ items: [[FREIDORA, 1, 45000]] });
await vend(`SELECT cambiar_estado_solicitud($1, 'confirmado')`, [p4]);
t('al confirmar el pedido descontó', [await hoyStock(FREIDORA), (await sol(p4)).sd], [5, true]);
const r4 = await pasar(vend, p4);
t('al pasar a venta no descuenta otra vez', [await hoyStock(FREIDORA), (await sol(p4)).sd], [5, false]);

grupo('Pago online después de pasar al mostrador');
const CTA = (await q(`INSERT INTO cuentas_cobro (nombre, titular, alias) VALUES ('Cuenta 1', 'Titular', 'mh.prueba.uno') RETURNING id::int`))[0].id;
await q(`UPDATE solicitudes SET estado_pago = 'pagado', monto_pagado = 45000, pagado_en = now(), cuenta_cobro_id = $2 WHERE id = $1`, [p4, CTA]);
t('la venta se marca pagada sola', [(await venta(r4.id)).estado, (await venta(r4.id)).medio_pago, (await venta(r4.id)).cobrada_por_nombre], ['cerrada', 'web', 'Pago online']);
t('y sale de la cola de la caja', (await vend2(`SELECT count(*)::int n FROM ventas WHERE estado = 'pendiente_cobro' AND id = $1`, [r4.id]))[0].n, 0);
await admin(`SELECT anular_pago($1, 'transferencia rebotada')`, [p4]);
t('se anula el pago → vuelve a esperar cobro', [(await venta(r4.id)).estado, (await venta(r4.id)).medio_pago], ['pendiente_cobro', 'pendiente']);
await q(`UPDATE solicitudes SET estado_pago = 'pagado', monto_pagado = 45000 WHERE id = $1`, [p4]);
await stock(`SELECT venta_entregar(ARRAY[$1]::bigint[])`, [r4.id]);
await falla('si ya salió, no se anula el pago online', () => admin(`SELECT anular_pago($1, 'x')`, [p4]), /venta_entregada/);

grupo('Anular la venta');
const p5 = await pedido({ items: [[TERMO, 1, 12000], [null, 1, 5000]] });
const r5 = await pasar(vend, p5, { items: [], entrega: { tipo: 'retiro', fecha: '2030-01-01' } });
t('ítem sin producto del catálogo: entra igual', (await q(`SELECT count(*)::int n FROM venta_items WHERE venta_id = $1`, [r5.id]))[0].n, 2);
await vend(`SELECT venta_anular($1, 'el cliente no vino')`, [r5.id]);
t('anulada → el pedido queda sin venta', [(await sol(p5)).v, (await sol(p5)).estado], [null, 'confirmado']);
const r5b = await pasar(vend, p5);
t('se puede volver a pasar', (await venta(r5b.id)).estado, 'pendiente_cobro');
await vend(`SELECT venta_anular($1, 'otra vez')`, [r5b.id]);
t('y cancelar el pedido desde Pedidos', (await vend(`SELECT cambiar_estado_solicitud($1, 'cancelado') r`, [p5]))[0].r.estado, 'cancelado');
await falla('un pedido cancelado no pasa', () => pasar(vend, p5), /pedido_cerrado/);

grupo('Precios');
const p6 = await pedido({ items: [[TERMO, 2, null]] });
await falla('sin precio no pasa', () => pasar(vend, p6), /precio_requerido/);
const it6 = (await q(`SELECT id::int FROM solicitud_items WHERE solicitud_id = $1`, [p6]))[0].id;
t('con el precio corregido en el panel, sí', (await venta((await pasar(vend, p6, { items: [{ id: it6, precio: 11000 }] })).id)).total, 22000);

grupo('Comprometido para la web');
const p7 = await pedido({ items: [[FREIDORA, 2, 45000]], pago: 'pendiente' });
const comp = async () => (await q(`SELECT stock_comprometido(p) n FROM productos p WHERE id = 1`))[0].n;
t('pedido esperando transferencia: compromete', await comp(), 2);
await pasar(vend, p7);
t('pasado a venta: ya no (lo descontó la venta)', await comp(), 0);

console.log(`\n${ok} pasadas, ${fail} fallidas\n`);
process.exit(fail ? 1 : 0);
