/**
 * Pruebas de ventas en el local, compras y stock controlado
 * (sql/013-local-compras-stock.sql) contra un Postgres REAL en memoria
 * (PGlite), sin tocar Supabase.
 *
 *   npm i --no-save --prefix scripts @electric-sql/pglite   (una sola vez)
 *   node scripts/test-stock-sql.mjs
 *
 * Qué prueba:
 *   1. El 013 corre limpio dos veces (idempotente) sobre 001..012.
 *   2. Conteo de stock: carga inicial, corrección, lote, quitar control, permisos.
 *   3. Alta rápida de producto: SKU automático, slug único, duplicados.
 *   4. Ventas del local: descuenta solo controlados, ítem libre, negativo con
 *      aviso, anulación (propia / ajena / admin), permisos.
 *   5. Compras: sugerencias (SKU, barras, nombre parecido), crear con
 *      vincular/crear/omitir, recepción parcial y total, costo en pesos,
 *      "ya había", recibir al cargar, vincular renglón, estados.
 *   6. Tienda: sin_stock al crear pedido, stock a confirmar, comprometido
 *      por pedidos esperando pago, catálogo del bot.
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
                 '009-crm.sql', '010-bot-whatsapp.sql', '011-crm-conversacion.sql', '012-cobros.sql']) {
  await db.exec(leerSQL(f));
}

const ADMIN = '00000000-0000-0000-0000-00000000000a';
const VEND  = '00000000-0000-0000-0000-00000000000b';
const STOCK = '00000000-0000-0000-0000-00000000000c';
const VEND2 = '00000000-0000-0000-0000-00000000000d';
await db.exec(`
INSERT INTO auth.users (id, email, raw_user_meta_data) VALUES
  ('${ADMIN}', 'ana@mh.test',    '{"nombre":"Ana Admin","rol":"administrador"}'),
  ('${VEND}',  'vero@mh.test',   '{"nombre":"Vero Ventas","rol":"vendedor"}'),
  ('${STOCK}', 'sergio@mh.test', '{"nombre":"Sergio Stock","rol":"encargado_stock"}'),
  ('${VEND2}', 'vale@mh.test',   '{"nombre":"Vale Ventas","rol":"vendedor"}');
INSERT INTO categorias (nombre, slug) VALUES ('Electrodomésticos','electrodomesticos'), ('Herramientas','herramientas');
INSERT INTO productos (nombre, slug, sku, codigo_barras, categoria_id, precio_minorista, seguimiento_inventario, stock_actual) VALUES
  ('Freidora de aire 5L',   'freidora-de-aire-5l', 'ELE-FREID-1001', NULL, 1, 45000, true, 0),     -- 1: con stock cargado a mano (queda controlado)
  ('Lavarropas 8kg',        'lavarropas-8kg',      NULL, NULL, 1, NULL,  false, 0),                -- 2: sin precio, sin seguimiento
  ('Termo 1L',              'termo-1l',            NULL, NULL, 1, 12000.50, false, 0),             -- 3: con precio, sin seguimiento
  ('Licuadora Pro 900W',    'licuadora-pro-900w',  'ELE-LICUA-2002', NULL, 1, 30000, true, 0),    -- 4: con precio, SIN controlar
  ('Taladro INGCO 20V',     'taladro-ingco-20v',   'HER-TALAD-3003', '7791234567890', 2, 80000, true, 0); -- 5
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
const vend2 = (sql, p) => como('authenticated', VEND2, sql, p);
const admin = (sql, p) => como('authenticated', ADMIN, sql, p);
const stock = (sql, p) => como('authenticated', STOCK, sql, p);
const q     = async (sql, p) => (await db.query(sql, p)).rows;

async function falla(nombre, fn, patron) {
  try { await fn(); t(nombre, 'no falló', 'falla con ' + patron); }
  catch (e) { t(nombre, patron.test(e.message) ? 'falló bien' : e.message, 'falló bien'); }
}
const prod = async id => (await q(`SELECT id, nombre, stock_actual, stock_controlado, precio_costo, sku, slug, estado, sku_proveedor FROM productos WHERE id = $1`, [id]))[0];
const movs = async (id) => (await q(`SELECT tipo, cantidad, stock_anterior, stock_posterior, referencia FROM movimientos_inventario WHERE producto_id = $1 ORDER BY id`, [id]));

// Stock del producto 1 cargado a mano ANTES del 013 (debe quedar "controlado" por el backfill)
await admin(`SELECT fn_registrar_movimiento(1, 'carga_inicial', 10, 'Carga inicial')`);

// ── Migración ─────────────────────────────────────────────────────
grupo('Migración');
let errorMigracion = null;
const SQL013 = leerSQL('013-local-compras-stock.sql');
try { await db.exec(SQL013); await db.exec(SQL013); } catch (e) { errorMigracion = e.message; }
t('013 corre limpio, dos veces seguidas', errorMigracion, null);
if (errorMigracion) { console.log(`\n${ok} pasadas, ${fail} fallidas\n`); process.exit(1); }
t('backfill: el producto con carga a mano quedó controlado; los demás no',
  (await q(`SELECT id, stock_controlado FROM productos ORDER BY id`)).map(r => r.stock_controlado), [true, false, false, false, false]);
t('columnas calculadas: comprometido 0, disponible = stock',
  (await anon(`SELECT stock_comprometido(p) AS c, stock_disponible(p) AS d, disponibilidad_web(p) AS w FROM productos p WHERE id = 1`))[0],
  { c: 0, d: 10, w: 'ok' });
t('disponibilidad web por caso: sin precio → consultar; sin seguimiento → ok; con precio sin controlar → consultar',
  (await anon(`SELECT disponibilidad_web(p) AS w FROM productos p WHERE id IN (2,3,4) ORDER BY id`)).map(r => r.w),
  ['consultar', 'ok', 'consultar']);
t('catalogo_bot expone stock_controlado',
  (await anon(`SELECT stock_controlado, disponible FROM catalogo_bot WHERE id = 4`))[0], { stock_controlado: false, disponible: true });

// ── Conteo ────────────────────────────────────────────────────────
grupo('Conteo de stock');
await falla('un vendedor no puede contar', () => vend(`SELECT fn_stock_contar(4, 5)`), /sin_permiso/);
await falla('cantidad negativa', () => stock(`SELECT fn_stock_contar(4, -1)`), /cantidad_invalida/);
let r = (await stock(`SELECT fn_stock_contar(4, 12, 'estante B') AS r`))[0].r;
t('primer conteo: carga_inicial de 12 y queda controlado', [r.stock_anterior, r.stock_actual, r.diferencia, r.ya_estaba_controlado], [0, 12, 12, false]);
t('   producto 4 controlado con stock 12', [(await prod(4)).stock_controlado, (await prod(4)).stock_actual], [true, 12]);
t('   movimiento carga_inicial', (await movs(4)).map(m => [m.tipo, m.cantidad]), [['carga_inicial', 12]]);
r = (await stock(`SELECT fn_stock_contar(4, 9) AS r`))[0].r;
t('recuento a 9: corrección de -3', [r.diferencia, r.stock_actual], [-3, 9]);
t('   movimiento correccion con stock_posterior 9', (await movs(4)).slice(-1).map(m => [m.tipo, m.stock_posterior]), [['correccion', 9]]);
r = (await stock(`SELECT fn_stock_contar(4, 9) AS r`))[0].r;
t('mismo número: sin movimiento', [r.diferencia, r.movimiento_id], [0, null]);
t('   sigue habiendo 2 movimientos', (await movs(4)).length, 2);
r = (await stock(`SELECT fn_stock_contar(5, 0) AS r`))[0].r;
t('contar 0 también controla (no hay, pero se sabe)', [(await prod(5)).stock_controlado, (await prod(5)).stock_actual, r.movimiento_id], [true, 0, null]);
r = (await admin(`SELECT fn_stock_contar_lote($1::jsonb) AS r`, [JSON.stringify([
  { producto_id: 1, cantidad: 8 }, { producto_id: 999, cantidad: 1 }, { producto_id: 5, cantidad: 3 }])]))[0].r;
t('lote: 2 bien, 1 falla (producto inexistente) y no tira los demás', [r.ok, r.contados, r.fallidos], [false, 2, 1]);
t('   stock 1 → 8 (corrección -2), 5 → 3', [(await prod(1)).stock_actual, (await prod(5)).stock_actual], [8, 3]);
t('   el fallido informa el error', r.items[1].ok === false && /producto_no_encontrado/.test(r.items[1].error), true);
await stock(`SELECT fn_stock_quitar_control(5)`);
t('quitar control: vuelve a sin controlar y el stock queda', [(await prod(5)).stock_controlado, (await prod(5)).stock_actual], [false, 3]);
await stock(`SELECT fn_stock_contar(5, 3)`);
t('volver a contar lo mismo: controlado, sin movimiento nuevo', [(await prod(5)).stock_controlado, (await movs(5)).length], [true, 1]);
await falla('UPDATE directo de stock sigue bloqueado (008)', () => admin(`UPDATE productos SET stock_actual = 99 WHERE id = 4`), /stock_solo_por_movimiento/);

// ── Alta rápida ───────────────────────────────────────────────────
grupo('Alta rápida de producto');
await falla('un vendedor no crea productos', () => vend(`SELECT producto_crear_rapido('{"nombre":"x"}'::jsonb)`), /sin_permiso/);
await falla('nombre obligatorio', () => stock(`SELECT producto_crear_rapido('{"nombre":" "}'::jsonb)`), /nombre_invalido/);
r = (await stock(`SELECT producto_crear_rapido($1::jsonb) AS r`, [JSON.stringify({ nombre: 'Pava eléctrica 1.7L', categoria_id: 1, precio_minorista: '15.500,50' })]))[0].r;
t('SKU automático MH-000id y slug', [r.sku, r.slug, r.estado], [`MH-${String(r.id).padStart(5, '0')}`, 'pava-electrica-1-7l', 'inactivo']);
t('   precio tolerante a coma decimal argentina ("15.500,50" no se interpreta: queda null)', (await q(`SELECT precio_minorista FROM productos WHERE id = $1`, [r.id]))[0].precio_minorista, null);
r = (await stock(`SELECT producto_crear_rapido($1::jsonb) AS r`, [JSON.stringify({ nombre: 'Pava eléctrica 1.7L', precio_minorista: '15500.50', estado: 'activo' })]))[0].r;
t('mismo nombre: slug distinto, activo si se pide', [r.slug !== 'pava-electrica-1-7l', r.estado], [true, 'activo']);
t('   precio con punto decimal sí', (await q(`SELECT precio_minorista FROM productos WHERE id = $1`, [r.id]))[0].precio_minorista, '15500.50');
await falla('SKU duplicado', () => stock(`SELECT producto_crear_rapido('{"nombre":"Otra","sku":"ele-freid-1001"}'::jsonb)`), /sku_duplicado/);
t('nace con stock 0 y sin controlar', [(await prod(r.id)).stock_actual, (await prod(r.id)).stock_controlado], [0, false]);

// ── Ventas ────────────────────────────────────────────────────────
grupo('Ventas en el local');
// Estado: 1 controlado 8 | 2 sin seguimiento | 3 sin seguimiento precio | 4 controlado 9 | 5 controlado 3 | 6/7 pavas sin controlar
await falla('anónimo no vende', () => anon(`SELECT venta_registrar('{"items":[{"producto_id":1,"cantidad":1}]}'::jsonb)`), /sin_permiso|permission denied/);
await falla('venta vacía', () => vend(`SELECT venta_registrar('{"items":[]}'::jsonb)`), /venta_vacia/);
await falla('producto sin precio y sin precio en la venta', () => vend(`SELECT venta_registrar('{"items":[{"producto_id":2,"cantidad":1}]}'::jsonb)`), /precio_requerido/);
r = (await vend(`SELECT venta_registrar($1::jsonb) AS r`, [JSON.stringify({
  items: [
    { producto_id: 1, cantidad: 2 },                       // controlado: descuenta (8 → 6)
    { producto_id: 6, cantidad: 1, precio_unitario: 15000 }, // sin controlar: NO toca stock
    { producto_id: 2, cantidad: 1, precio_unitario: 250000 }, // sin seguimiento: no toca stock
    { nombre: 'Cable alargue 5m', cantidad: 3, precio_unitario: 2000 } // ítem libre
  ],
  medio_pago: 'efectivo', descuento: 1000, cliente_nombre: 'Juan', cliente_telefono: '342 555 1234'
})]))[0].r;
t('venta registrada: total = 90000 + 15000 + 250000 + 6000 − 1000', [r.ok, r.subtotal, r.descuento, r.total, r.stock_afectado, r.codigo.startsWith('VL-')], [true, 361000, 1000, 360000, 1, true]);
t('   solo el controlado descontó: 8 → 6', (await prod(1)).stock_actual, 6);
t('   el sin controlar quedó igual (0)', (await prod(6)).stock_actual, 0);
t('   ítems: afecto_stock solo en el primero', r.items.map(i => i.afecto_stock), [true, false, false, false]);
t('   movimiento salida_venta con referencia VL-…', (await movs(1)).slice(-1).map(m => [m.tipo, m.cantidad, m.referencia === r.codigo]), [['salida_venta', 2, true]]);
t('   vendedor guardado', (await q(`SELECT vendedor_nombre, medio_pago, items_count, unidades FROM ventas WHERE id = $1`, [r.id]))[0],
  { vendedor_nombre: 'Vero Ventas', medio_pago: 'efectivo', items_count: 4, unidades: 7 });
const ventaId = r.id;
t('el staff ve las ventas; anon no', [(await vend(`SELECT count(*)::int AS n FROM ventas`))[0].n, (await anon(`SELECT count(*)::int AS n FROM ventas`))[0].n], [1, 0]);
await falla('escribir ventas directo está bloqueado (solo RPC)', () => vend(`INSERT INTO ventas (codigo) VALUES ('X')`), /row-level security/);

r = (await vend2(`SELECT venta_registrar($1::jsonb) AS r`, [JSON.stringify({ items: [{ producto_id: 5, cantidad: 5 }], medio_pago: 'transferencia' })]))[0].r;
t('vender más de lo que dice el sistema: pasa, queda negativo y avisa', [r.ok, (await prod(5)).stock_actual, r.advertencias.length, r.advertencias[0].stock], [true, -2, 1, -2]);
await falla('con permitir_negativo=false frena', () => vend(`SELECT venta_registrar('{"items":[{"producto_id":4,"cantidad":50}],"permitir_negativo":false}'::jsonb)`), /stock_insuficiente/);
t('   y no descontó nada', (await prod(4)).stock_actual, 9);
await falla('precio_unitario negativo', () => vend(`SELECT venta_registrar('{"items":[{"producto_id":4,"cantidad":1,"precio_unitario":-5}]}'::jsonb)`), /precio_invalido/);
await falla('descuento mayor al subtotal', () => vend(`SELECT venta_registrar('{"items":[{"producto_id":4,"cantidad":1}],"descuento":999999}'::jsonb)`), /descuento_invalido/);
await falla('medio de pago inválido', () => vend(`SELECT venta_registrar('{"items":[{"producto_id":4,"cantidad":1}],"medio_pago":"cheque"}'::jsonb)`), /medio_pago_invalido/);
t('resumen por día', (await admin(`SELECT medio_pago, ventas, total FROM v_ventas_resumen ORDER BY medio_pago`)).map(x => [x.medio_pago, x.ventas, Number(x.total)]), [['efectivo', 1, 360000], ['transferencia', 1, 400000]]);

// Anulación
await falla('anular sin motivo', () => vend(`SELECT venta_anular($1, '')`, [ventaId]), /motivo_requerido/);
await falla('otro vendedor no anula una venta ajena', () => vend2(`SELECT venta_anular($1, 'error')`, [ventaId]), /sin_permiso/);
r = (await vend(`SELECT venta_anular($1, 'Se equivocó el cliente') AS r`, [ventaId]))[0].r;
t('el propio vendedor anula: repone 1 movimiento', [r.ok, r.estado, r.movimientos], [true, 'anulada', 1]);
t('   stock 1 volvió a 8', (await prod(1)).stock_actual, 8);
t('   devolucion_cliente con referencia', (await movs(1)).slice(-1).map(m => [m.tipo, m.cantidad]), [['devolucion_cliente', 2]]);
r = (await vend(`SELECT venta_anular($1, 'otra vez') AS r`, [ventaId]))[0].r;
t('anular dos veces: sin cambios', r.sin_cambios, true);
t('   no se repuso dos veces', (await prod(1)).stock_actual, 8);
await q(`UPDATE ventas SET fecha = now() - interval '2 days' WHERE vendedor_id = $1`, [VEND2]);
const ventaVieja = (await q(`SELECT id FROM ventas WHERE vendedor_id = $1`, [VEND2]))[0].id;
await falla('venta de hace 2 días: el vendedor ya no puede', () => vend2(`SELECT venta_anular($1, 'x')`, [ventaVieja]), /sin_permiso/);
r = (await admin(`SELECT venta_anular($1, 'Devolución') AS r`, [ventaVieja]))[0].r;
t('el administrador sí: stock 5 vuelve de -2 a 3', [r.ok, (await prod(5)).stock_actual], [true, 3]);
t('resumen ya no cuenta las anuladas', (await admin(`SELECT count(*)::int AS n FROM v_ventas_resumen`))[0].n, 0);

// ── Compras ───────────────────────────────────────────────────────
grupo('Compras: sugerencias');
await falla('un vendedor no sugiere/carga compras', () => vend(`SELECT compra_sugerir('[]'::jsonb)`), /sin_permiso/);
r = (await stock(`SELECT compra_sugerir($1::jsonb) AS r`, [JSON.stringify([
  { i: 0, descripcion: 'AIR FRYER 5L', sku: 'ele-freid-1001' },         // SKU exacto
  { i: 1, descripcion: 'Taladro ingco 20v', codigo_barras: '779 1234567890' }, // barras + nombre exacto
  { i: 2, descripcion: 'Licuadora Pro 900 W' },                          // nombre parecido
  { i: 3, descripcion: 'Smart TV 50 pulgadas 4K' },                      // nada
  { i: 4, descripcion: 'termo' }                                         // una palabra alcanza si se parece
])]))[0].r;
t('SKU exacto → score 100 y seguro', [r[0].candidatos[0].id, r[0].candidatos[0].score, r[0].seguro], [1, 100, true]);
t('código de barras (con espacios) → score 100 producto 5', [r[1].candidatos[0].id, r[1].candidatos[0].score, r[1].candidatos[0].motivo], [5, 100, 'Código de barras']);
t('nombre parecido → producto 4 con score alto, no "seguro"', [r[2].candidatos[0].id, r[2].candidatos[0].score >= 60, r[2].seguro], [4, true, false]);
t('sin coincidencias → lista vacía', r[3].candidatos, []);
t('una sola palabra encuentra "Termo 1L" por parecido', [r[4].candidatos[0]?.id, r[4].candidatos[0]?.motivo, r[4].seguro], [3, 'Nombre parecido', false]);
t('cada candidato trae stock y control', Object.keys(r[0].candidatos[0]).sort(),
  ['estado', 'id', 'motivo', 'nombre', 'precio_minorista', 'score', 'sku', 'stock_actual', 'stock_controlado']);

grupo('Compras: crear y recibir');
await falla('compra vacía', () => stock(`SELECT compra_crear('{"items":[]}'::jsonb)`), /compra_vacia/);
await falla('vincular a producto inexistente', () => stock(`SELECT compra_crear('{"items":[{"accion":"vincular","producto_id":999,"cantidad":1}]}'::jsonb)`), /producto_no_encontrado/);
await falla('cantidad 0', () => stock(`SELECT compra_crear('{"items":[{"accion":"vincular","producto_id":1,"cantidad":0}]}'::jsonb)`), /cantidad_invalida/);
r = (await stock(`SELECT compra_crear($1::jsonb) AS r`, [JSON.stringify({
  proveedor: 'Yiwu Trading', referencia: 'PI-2026-77', moneda: 'USD', tipo_cambio: 1500, fecha_estimada: '2026-12-15',
  categoria_nuevos: 1, publicar_nuevos: false,
  items: [
    { descripcion: 'AIR FRYER 5L', sku_proveedor: 'YW-AF5', cantidad: 20, costo_unitario: 25.5, accion: 'vincular', producto_id: 1 },
    { descripcion: 'TALADRO 20V', cantidad: 10, costo_unitario: 30, accion: 'vincular', producto_id: 5 },
    { descripcion: 'PARLANTE BT 10W', sku_proveedor: 'YW-SP10', cantidad: 50, costo_unitario: 4.2, accion: 'crear', nuevo: { nombre: 'Parlante Bluetooth 10W', codigo_barras: '7798888888888' } },
    { descripcion: 'Muestra sin cargo', cantidad: 1, accion: 'omitir' },
    { descripcion: 'LICUADORA 900W', cantidad: 6, costo_unitario: 12, accion: 'vincular', producto_id: 6 }   // pava sin controlar (id 6) a propósito
  ]
})]))[0].r;
const compraId = r.id;
t('compra creada: 4 renglones (1 omitido), 86 unidades, 1 producto nuevo, estado pedido', [r.renglones, r.unidades, r.productos_nuevos.length, r.estado, r.codigo.startsWith('OC-')], [4, 86, 1, 'pedido', true]);
const parlante = r.productos_nuevos[0].id;
let pp = await prod(parlante);
t('   el nuevo nace inactivo, con categoría por defecto, costo en pesos (4.2 × 1500) y código del proveedor',
  [pp.estado, pp.precio_costo, pp.sku_proveedor, pp.stock_controlado, (await q(`SELECT categoria_id, codigo_barras FROM productos WHERE id = $1`, [parlante]))[0]],
  ['inactivo', '6300.00', 'YW-SP10', false, { categoria_id: 1, codigo_barras: '7798888888888' }]);
t('   total_costo = 20×25.5 + 10×30 + 50×4.2 + 6×12', (await q(`SELECT total_costo, total_items, total_unidades FROM compras WHERE id = $1`, [compraId]))[0], { total_costo: '1092.00', total_items: 4, total_unidades: 86 });
t('   nada de stock se movió todavía', [(await prod(1)).stock_actual, (await prod(parlante)).stock_actual], [8, 0]);
const items = await q(`SELECT id, producto_id, cantidad_pedida, cantidad_recibida, producto_nuevo FROM compra_items WHERE compra_id = $1 ORDER BY orden`, [compraId]);
t('   renglones en orden, el 3º marcado como producto nuevo', items.map(i => [i.producto_id, i.cantidad_pedida, i.producto_nuevo]), [[1, 20, false], [5, 10, false], [parlante, 50, true], [6, 6, false]]);

r = (await stock(`SELECT compra_cambiar_estado($1, 'en_transito', '2026-12-20') AS r`, [compraId]))[0].r;
t('en tránsito', [r.estado, (await q(`SELECT estado, fecha_estimada::text AS fecha_estimada FROM compras WHERE id = $1`, [compraId]))[0].fecha_estimada], ['en_transito', '2026-12-20']);

// Recepción parcial: llegó todo menos el taladro (que llegó incompleto)
r = (await stock(`SELECT compra_recibir($1, $2::jsonb, 'Contenedor 1 de 2') AS r`, [compraId, JSON.stringify([
  { item_id: items[0].id, cantidad: 20 },
  { item_id: items[1].id, cantidad: 4 },
  { item_id: items[2].id, cantidad: 50 },
  { item_id: items[3].id, cantidad: 6, ya_habia: 2 }     // la pava no estaba controlada: había 2 viejas
])]))[0].r;
t('recepción parcial: 80 unidades, 4 renglones, estado recibido_parcial, 2 productos pasan a controlados', [r.unidades, r.renglones, r.estado, r.nuevos_controlados, r.pendientes], [80, 4, 'recibido_parcial', 2, 1]);
t('   freidora 8 → 28', (await prod(1)).stock_actual, 28);
t('   taladro 3 → 7', (await prod(5)).stock_actual, 7);
t('   parlante 0 → 50 y controlado', [(await prod(parlante)).stock_actual, (await prod(parlante)).stock_controlado], [50, true]);
t('   pava: 2 viejas (carga_inicial) + 6 llegadas = 8, controlada', [(await prod(6)).stock_actual, (await prod(6)).stock_controlado, (await movs(6)).map(m => [m.tipo, m.cantidad])], [8, true, [['carga_inicial', 2], ['entrada_compra', 6]]]);
t('   movimientos con referencia OC-… y motivo', (await q(`SELECT count(*)::int AS n FROM movimientos_inventario WHERE referencia = (SELECT codigo FROM compras WHERE id = $1)`, [compraId]))[0].n, 5);
t('   costo en pesos actualizado en la freidora (25.5 × 1500)', (await prod(1)).precio_costo, '38250.00');
t('   código del proveedor guardado en la freidora', (await prod(1)).sku_proveedor, 'YW-AF5');
t('   cantidades recibidas por renglón', (await q(`SELECT cantidad_recibida FROM compra_items WHERE compra_id = $1 ORDER BY orden`, [compraId])).map(i => i.cantidad_recibida), [20, 4, 50, 6]);
await falla('cambiar de producto un renglón ya recibido', () => stock(`SELECT compra_item_vincular($1, 4)`, [items[1].id]), /item_ya_recibido/);
await falla('cancelar con recepciones', () => stock(`SELECT compra_cambiar_estado($1, 'cancelado')`, [compraId]), /compra_con_recepciones/);
// Llega el resto
r = (await stock(`SELECT compra_recibir($1, $2::jsonb) AS r`, [compraId, JSON.stringify([{ item_id: items[1].id, cantidad: 6 }])]))[0].r;
t('segunda recepción completa la compra', [r.estado, r.pendientes, (await prod(5)).stock_actual], ['recibido', 0, 13]);
await falla('recibir sobre una compra ya recibida', () => stock(`SELECT compra_recibir($1, '[]'::jsonb)`, [compraId]), /compra_ya_recibida/);
t('2 recepciones registradas', (await stock(`SELECT count(*)::int AS n FROM compra_recepciones WHERE compra_id = $1`, [compraId]))[0].n, 2);

// Recibir al cargar (ya llegó todo) + crear producto publicado
r = (await admin(`SELECT compra_crear($1::jsonb) AS r`, [JSON.stringify({
  proveedor: 'Local', moneda: 'ARS', recibir_ahora: true, publicar_nuevos: true,
  items: [
    { descripcion: 'Secador de pelo 2000W', cantidad: 12, costo_unitario: 18000, accion: 'crear' },
    { descripcion: 'Freidora', cantidad: 2, accion: 'vincular', producto_id: 1 }
  ]
})]))[0].r;
t('recibir_ahora: compra queda recibida en la misma operación', [r.estado, r.recepcion.unidades], ['recibido', 14]);
const secador = r.productos_nuevos[0].id;
pp = await prod(secador);
t('   nuevo publicado (activo), controlado, stock 12, costo ARS directo, nombre tomado de la descripción', [pp.estado, pp.stock_controlado, pp.stock_actual, pp.precio_costo, pp.nombre], ['activo', true, 12, '18000.00', 'Secador de pelo 2000W']);
t('   freidora 28 → 30', (await prod(1)).stock_actual, 30);

// Vincular / crear desde un renglón pendiente
r = (await stock(`SELECT compra_crear($1::jsonb) AS r`, [JSON.stringify({ items: [{ descripcion: 'Cosa rara', cantidad: 3, accion: 'crear', nuevo: { nombre: 'Cosa rara' } }] })]))[0].r;
const compra3 = r.id; const item3 = (await q(`SELECT id, producto_id FROM compra_items WHERE compra_id = $1`, [compra3]))[0];
r = (await stock(`SELECT compra_item_vincular($1, 4) AS r`, [item3.id]))[0].r;
t('revincular renglón pendiente a otro producto', [r.ok, (await q(`SELECT producto_id, producto_nuevo FROM compra_items WHERE id = $1`, [item3.id]))[0]], [true, { producto_id: 4, producto_nuevo: false }]);
r = (await stock(`SELECT compra_cambiar_estado($1, 'cancelado') AS r`, [compra3]))[0].r;
t('cancelar compra sin recepciones', r.estado, 'cancelado');
await falla('recibir una compra cancelada', () => stock(`SELECT compra_recibir($1, '[]'::jsonb)`, [compra3]), /compra_cancelada/);
await falla('escribir compras directo está bloqueado', () => admin(`INSERT INTO compras (codigo) VALUES ('X')`), /row-level security/);

// ── Tienda ────────────────────────────────────────────────────────
grupo('Tienda: pedidos web y stock');
// Estado: 1 controlado 30 | 4 controlado 9 | 5 controlado 13 | 6 pava controlada 8 (inactivo) | 7 pava activa sin controlar precio 15500.50
const pedido = (nombre, telefono, items) => anon(`SELECT crear_solicitud($1::jsonb) AS r`, [JSON.stringify({ nombre, telefono, items })]).then(x => x[0].r);
await falla('pedir 10 licuadoras con 9 disponibles → sin_stock con detalle', () => pedido('Juan', '3425550001', [{ id: 4, cantidad: 10 }]), /sin_stock/);
try { await pedido('Juan', '3425550001', [{ id: 4, cantidad: 6 }, { id: 4, cantidad: 4 }]); t('mismo producto dos veces suma (6+4 > 9)', 'no falló', 'falla'); }
catch (e) { t('mismo producto dos veces suma (6+4 > 9)', /sin_stock/.test(e.message), true); }
t('   no se creó ninguna solicitud', (await q(`SELECT count(*)::int AS n FROM solicitudes`))[0].n, 0);
let s = await pedido('Juan', '3425550001', [{ id: 4, cantidad: 9 }]);
t('pedir exactamente el disponible: pasa, total 270000', [s.total, s.tiene_pendientes], [270000, false]);
t('   todavía no compromete (no eligió pagar)', (await anon(`SELECT stock_comprometido(p) AS c, stock_disponible(p) AS d FROM productos p WHERE id = 4`))[0], { c: 0, d: 9 });
// Elige pagar por transferencia → compromete
await q(`UPDATE site_settings SET cobros_activos = true WHERE id = 1`);
await admin(`INSERT INTO cuentas_cobro (nombre, titular, alias) VALUES ('Cuenta A', 'Juan Pérez', 'mh.juan.mp')`);
await anon(`SELECT pedido_pagar_transferencia($1, $2)`, [s.codigo, '3425550001']);
t('con pago pendiente: comprometido 9, disponible 0, web dice sin_stock', (await anon(`SELECT stock_comprometido(p) AS c, stock_disponible(p) AS d, disponibilidad_web(p) AS w FROM productos p WHERE id = 4`))[0], { c: 9, d: 0, w: 'sin_stock' });
await falla('otro cliente ya no puede pedirla', () => pedido('Ana', '3425550002', [{ id: 4, cantidad: 1 }]), /sin_stock/);
t('   el stock físico sigue 9 (no se descontó: se descuenta al confirmar)', (await prod(4)).stock_actual, 9);
// Producto con precio pero sin controlar → stock a confirmar
s = await pedido('Ana', '3425550002', [{ id: 7, cantidad: 2 }, { id: 1, cantidad: 1 }]);
t('pava sin controlar: pedido sale "a confirmar" (sin total, sin pago online)', [s.total, s.tiene_pendientes, s.items.map(i => i.stock_a_confirmar)], [null, true, [true, false]]);
t('   el ítem queda marcado en la base', (await q(`SELECT stock_a_confirmar FROM solicitud_items WHERE producto_id = 7`))[0].stock_a_confirmar, true);
let v = (await anon(`SELECT pedido_consultar($1, $2) AS r`, [s.codigo, '3425550002']))[0].r;
t('   y la página del pedido no ofrece pagar', v.puede_pagar, false);
// Confirmar el primer pedido (pago) descuenta y libera lo comprometido
const sol1 = (await q(`SELECT id FROM solicitudes ORDER BY id LIMIT 1`))[0].id;
await admin(`SELECT confirmar_pago($1, NULL, NULL, 'op1', NULL, 'efectivo en el local', NULL)`, [sol1]);
t('pago confirmado: stock 9 → 0, comprometido 0', [(await prod(4)).stock_actual, (await anon(`SELECT stock_comprometido(p) AS c FROM productos p WHERE id = 4`))[0].c], [0, 0]);
// Vender en el local algo comprometido: pasa (realidad), pero el panel lo puede ver
s = await pedido('Pedro', '3425550003', [{ id: 5, cantidad: 13 }]);
await anon(`SELECT pedido_pagar_transferencia($1, $2)`, [s.codigo, '3425550003']);
r = (await vend(`SELECT venta_registrar('{"items":[{"producto_id":5,"cantidad":1}]}'::jsonb) AS r`))[0].r;
t('la caja vende aunque esté comprometido por la web (stock 13 → 12); el pedido web fallará al confirmar', [r.ok, (await prod(5)).stock_actual], [true, 12]);
const solPedro = (await q(`SELECT id FROM solicitudes WHERE codigo = $1`, [s.codigo]))[0].id;
await falla('   confirmar ese pedido web ahora da stock_insuficiente (y no guarda el pago)', () =>
  admin(`SELECT confirmar_pago($1, NULL, NULL, 'op2', NULL, NULL, NULL)`, [solPedro]), /stock_insuficiente/);
t('   el pedido sigue pendiente de pago', (await q(`SELECT estado_pago FROM solicitudes WHERE codigo = $1`, [s.codigo]))[0].estado_pago, 'pendiente');

console.log(`\n${ok} pasadas, ${fail} fallidas\n`);
process.exit(fail ? 1 : 0);
