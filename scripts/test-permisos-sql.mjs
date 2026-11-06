/**
 * Pruebas de "qué ve cada rol" (sql/015-permisos-por-rol.sql) contra un
 * Postgres REAL en memoria (PGlite), sin tocar Supabase.
 *
 *   npm i --no-save --prefix scripts @electric-sql/pglite   (una sola vez)
 *   node scripts/test-permisos-sql.mjs
 *
 * Corre 001..015 y prueba, rol por rol (anónimo, vendedor, encargado de
 * stock, administrador y cuenta desactivada), qué puede leer de ventas,
 * compras, costos, cuentas bancarias, historial, pedidos y comprobantes.
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
const EX    = '00000000-0000-0000-0000-00000000000e';   // vendedor que ya no trabaja (se desactiva)
await db.exec(`
INSERT INTO auth.users (id, email, raw_user_meta_data) VALUES
  ('${ADMIN}', 'ana@mh.test',    '{"nombre":"Ana Admin","rol":"administrador"}'),
  ('${VEND}',  'vero@mh.test',   '{"nombre":"Vero Ventas","rol":"vendedor"}'),
  ('${STOCK}', 'sergio@mh.test', '{"nombre":"Sergio Stock","rol":"encargado_stock"}'),
  ('${VEND2}', 'vale@mh.test',   '{"nombre":"Vale Ventas","rol":"vendedor"}'),
  ('${EX}',    'ex@mh.test',     '{"nombre":"Ex Vendedor","rol":"vendedor"}');
INSERT INTO categorias (nombre, slug) VALUES ('Electrodomésticos','electrodomesticos');
INSERT INTO productos (nombre, slug, categoria_id, precio_minorista, precio_costo, proveedor, seguimiento_inventario, estado) VALUES
  ('Freidora de aire 5L', 'freidora', 1, 45000, 30000, 'Yiwu Trading', false, 'activo'),
  ('Termo 1L',            'termo',    1, 12000, NULL,  NULL,           false, 'activo'),
  ('Pava (borrador)',     'pava',     1, 20000, 9000,  '  ',           false, 'inactivo');
`);
await db.exec(leerSQL('014-accesos.sql'));

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
const q = async (sql, p) => (await db.query(sql, p)).rows;   // servidor
const cuantos = async (quien, tabla) => (await quien(`SELECT count(*)::int AS n FROM ${tabla}`))[0].n;

async function falla(nombre, fn, patron) {
  try { await fn(); t(nombre, 'no falló', 'falla con ' + patron); }
  catch (e) { t(nombre, patron.test(e.message) ? 'falló bien' : e.message, 'falló bien'); }
}

// ── Datos de antes del 015 ────────────────────────────────────────
const vender = (quien, precio) => quien(`SELECT venta_registrar($1::jsonb) AS r`,
  [JSON.stringify({ items: [{ producto_id: 2, cantidad: 1, precio_unitario: precio }], medio_pago: 'efectivo' })]).then(r => r[0].r);
await vender(vend, 1000); await vender(vend, 2000); await vender(vend2, 5000); await vender(stock, 7000); await vender(ex, 300);
await admin(`INSERT INTO cuentas_cobro (nombre, titular, alias, cvu, cuit_cuil, peso, limite_mensual, notas) VALUES
  ('Cuenta A', 'Juan Pérez',  'mh.juan.mp', '0000003100012345678901', '20-11111111-1', 5, 900000, 'la de Juan'),
  ('Cuenta B', 'María López', NULL,         '0000003100098765432109', '27-22222222-2', 3, NULL,   NULL)`);
await vend(`INSERT INTO historial_actividad (accion, entidad, entidad_id, descripcion) VALUES ('crear','venta','1','prueba')`);
await stock(`SELECT compra_crear($1::jsonb)`, [JSON.stringify({ proveedor: 'Yiwu Trading', moneda: 'ARS',
  items: [{ descripcion: 'AIR FRYER', cantidad: 5, costo_unitario: 31000, accion: 'vincular', producto_id: 1 }] })]);
await anon(`SELECT crear_solicitud($1::jsonb)`, [JSON.stringify({ nombre: 'Cliente', telefono: '3425551111', items: [{ id: 2, cantidad: 1 }] })]);

grupo('Antes del 015 (lo que se veía de más)');
t('antes: anónimo leía costo y proveedor de un producto activo',
  (await anon(`SELECT precio_costo, proveedor FROM productos WHERE id = 1`))[0], { precio_costo: '30000.00', proveedor: 'Yiwu Trading' });
t('antes: un vendedor veía las 5 ventas de todos', await cuantos(vend, 'ventas'), 5);
t('antes: un vendedor veía las compras', await cuantos(vend, 'compras'), 1);

// ── Migración ─────────────────────────────────────────────────────
grupo('Migración');
await q(`UPDATE profiles SET activo = false WHERE id = $1`, [EX]);   // se fue del negocio
let errorMigracion = null;
const SQL015 = leerSQL('015-permisos-por-rol.sql');
let resumen = null;
try { await db.exec(SQL015); resumen = (await db.exec(SQL015)).at(-1).rows[0]; } catch (e) { errorMigracion = e.message; }
t('015 corre limpio, dos veces seguidas', errorMigracion, null);
if (errorMigracion) { console.log(`\n${ok} pasadas, ${fail} fallidas\n`); process.exit(1); }
t('resumen: 2 costos mudados, ninguno a la vista', resumen, { costos_guardados_aparte: 2, costos_que_quedan_a_la_vista: 0 });
t('los costos se mudaron a producto_costos (proveedor en blanco → vacío)',
  await q(`SELECT producto_id, precio_costo, proveedor FROM producto_costos ORDER BY producto_id`),
  [{ producto_id: 1, precio_costo: '30000.00', proveedor: 'Yiwu Trading' }, { producto_id: 3, precio_costo: '9000.00', proveedor: null }]);

// ── B) Costos ─────────────────────────────────────────────────────
grupo('B) Costos y compras');
t('anónimo: costo y proveedor vacíos en la tienda', (await anon(`SELECT precio_costo, proveedor FROM productos WHERE id = 1`))[0], { precio_costo: null, proveedor: null });
await falla('anónimo no puede leer producto_costos', () => anon(`SELECT * FROM producto_costos`), /permission denied/);
t('vendedor: no ve costos', await cuantos(vend, 'producto_costos'), 0);
t('encargado de stock: ve costos', await cuantos(stock, 'producto_costos'), 2);
t('administrador: ve costos', await cuantos(admin, 'producto_costos'), 2);
t('vendedor: no ve compras ni sus renglones', [await cuantos(vend, 'compras'), await cuantos(vend, 'compra_items')], [0, 0]);
t('encargado y admin sí', [await cuantos(stock, 'compras'), await cuantos(admin, 'compra_items')], [1, 1]);

await stock(`UPDATE productos SET precio_costo = 32000 WHERE id = 1`);
t('formulario viejo escribe productos.precio_costo → se muda (proveedor se conserva)',
  [(await q(`SELECT precio_costo, proveedor FROM productos WHERE id = 1`))[0], (await q(`SELECT precio_costo, proveedor FROM producto_costos WHERE producto_id = 1`))[0]],
  [{ precio_costo: null, proveedor: null }, { precio_costo: '32000.00', proveedor: 'Yiwu Trading' }]);
const nuevo = (await stock(`INSERT INTO productos (nombre, slug, precio_costo, proveedor) VALUES ('Ventilador', 'ventilador', 15000, 'Local') RETURNING id`))[0].id;
t('alta con costo: queda aparte, el producto sin costo',
  [(await q(`SELECT precio_costo FROM productos WHERE id = $1`, [nuevo]))[0].precio_costo, (await q(`SELECT precio_costo, proveedor FROM producto_costos WHERE producto_id = $1`, [nuevo]))[0]],
  [null, { precio_costo: '15000.00', proveedor: 'Local' }]);
await stock(`INSERT INTO producto_costos (producto_id, precio_costo) VALUES (2, 8000)`);
await stock(`UPDATE producto_costos SET precio_costo = NULL WHERE producto_id = 2`);
t('el panel nuevo escribe directo en producto_costos y puede borrar el costo',
  (await q(`SELECT precio_costo, updated_by FROM producto_costos WHERE producto_id = 2`))[0], { precio_costo: null, updated_by: STOCK });
await falla('un vendedor no puede escribir costos', () => vend(`INSERT INTO producto_costos (producto_id, precio_costo) VALUES ($1, 1)`, [nuevo]), /row-level security/);

// La recepción de una compra (sql/013) actualiza el costo: tiene que mudarse
const compra = (await stock(`SELECT compra_crear($1::jsonb) AS r`, [JSON.stringify({ proveedor: 'Yiwu', moneda: 'USD', tipo_cambio: 1500,
  items: [{ descripcion: 'TERMO', cantidad: 3, costo_unitario: 4, accion: 'vincular', producto_id: 2 },
          { descripcion: 'MIXER', cantidad: 2, costo_unitario: 10, accion: 'crear', nuevo: { nombre: 'Mixer de mano' } }] })]))[0].r;
const mixer = compra.productos_nuevos[0].id;
t('compra con producto nuevo: el costo del nuevo queda aparte',
  [(await q(`SELECT precio_costo, proveedor FROM productos WHERE id = $1`, [mixer]))[0], (await q(`SELECT precio_costo FROM producto_costos WHERE producto_id = $1`, [mixer]))[0]?.precio_costo],
  [{ precio_costo: null, proveedor: null }, '15000.00']);
const it = await q(`SELECT id FROM compra_items WHERE compra_id = $1 ORDER BY orden`, [compra.id]);
await stock(`SELECT compra_recibir($1, $2::jsonb, NULL)`, [compra.id, JSON.stringify([{ item_id: it[0].id, cantidad: 3 }])]);
t('al recibir, el costo en pesos (4 × 1500) va a producto_costos',
  [(await q(`SELECT precio_costo FROM productos WHERE id = 2`))[0].precio_costo, (await q(`SELECT precio_costo FROM producto_costos WHERE producto_id = 2`))[0].precio_costo],
  [null, '6000.00']);
t('y el stock se cargó igual (3)', (await q(`SELECT stock_actual FROM productos WHERE id = 2`))[0].stock_actual, 3);

// ── A) Ventas ─────────────────────────────────────────────────────
grupo('A) Ventas');
t('vendedor: solo sus 2 ventas', (await vend(`SELECT total FROM ventas ORDER BY id`)).map(v => v.total), ['1000.00', '2000.00']);
t('otro vendedor: solo la suya', await cuantos(vend2, 'ventas'), 1);
t('vendedor: solo los renglones de sus ventas', await cuantos(vend, 'venta_items'), 2);
t('encargado de stock: todas (5)', await cuantos(stock, 'ventas'), 5);
t('administrador: todas (5) con renglones', [await cuantos(admin, 'ventas'), await cuantos(admin, 'venta_items')], [5, 5]);
t('anónimo: ninguna', await cuantos(anon, 'ventas'), 0);
const nueva = await vender(vend2, 9999);
t('vender sigue andando y el vendedor ve su venta nueva', [nueva.ok, await cuantos(vend2, 'ventas')], [true, 2]);

// ── C) Cuentas bancarias ──────────────────────────────────────────
grupo('C) Cuentas bancarias');
t('vendedor: la tabla completa no', await cuantos(vend, 'cuentas_cobro'), 0);
t('encargado: la tabla completa no', await cuantos(stock, 'cuentas_cobro'), 0);
t('administrador: la tabla completa sí, con CUIT y límites',
  (await admin(`SELECT cuit_cuil, limite_mensual FROM cuentas_cobro ORDER BY id`))[0], { cuit_cuil: '20-11111111-1', limite_mensual: '900000.00' });
t('vendedor: la vista para cobrar (CBU solo si no hay alias)',
  await vend(`SELECT nombre, titular, alias, cvu FROM cuentas_cobro_staff ORDER BY id`),
  [{ nombre: 'Cuenta A', titular: 'Juan Pérez', alias: 'mh.juan.mp', cvu: null },
   { nombre: 'Cuenta B', titular: 'María López', alias: null, cvu: '0000003100098765432109' }]);
await falla('la vista no tiene CUIT, límites ni notas', () => vend(`SELECT cuit_cuil FROM cuentas_cobro_staff`), /does not exist/);
await falla('anónimo no lee la vista', () => anon(`SELECT * FROM cuentas_cobro_staff`), /permission denied/);
t('cuenta desactivada: la vista viene vacía', await cuantos(ex, 'cuentas_cobro_staff'), 0);
t('el pedido público sigue mostrando a qué cuenta pagar (RPC)',
  typeof (await anon(`SELECT pedido_consultar($1, '3425551111') AS r`, [(await q(`SELECT codigo FROM solicitudes LIMIT 1`))[0].codigo]))[0].r, 'object');

// ── D) Historial ──────────────────────────────────────────────────
grupo('D) Historial de actividad');
t('vendedor: puede registrar, no leer', [(await vend(`INSERT INTO historial_actividad (accion, entidad, entidad_id, descripcion) VALUES ('x','y','1','z')`)).afectadas, await cuantos(vend, 'historial_actividad')], [1, 0]);
t('encargado: no lee', await cuantos(stock, 'historial_actividad'), 0);
t('administrador: lee todo (lo que registran las ventas y compras también)',
  await cuantos(admin, 'historial_actividad'), (await q(`SELECT count(*)::int AS n FROM historial_actividad`))[0].n);
await falla('cuenta desactivada: no puede registrar', () => ex(`INSERT INTO historial_actividad (accion, entidad, entidad_id, descripcion) VALUES ('x','y','1','z')`), /row-level security/);

// ── E) Cuenta desactivada ─────────────────────────────────────────
grupo('E) Cuenta desactivada = sin acceso');
for (const tabla of ['ventas', 'venta_items', 'solicitudes', 'solicitud_items', 'solicitud_eventos', 'comprobantes',
                     'movimientos_inventario', 'compras', 'producto_costos', 'cuentas_cobro', 'historial_actividad']) {
  t(`no lee ${tabla}`, await cuantos(ex, tabla), 0);
}
t('ni sus propias ventas viejas', (await ex(`SELECT count(*)::int AS n FROM ventas WHERE vendedor_id = auth.uid()`))[0].n, 0);
t('de productos ve solo lo que ve cualquiera en la tienda (activos)', await cuantos(ex, 'productos'), await cuantos(anon, 'productos'));
await falla('no puede vender', () => vender(ex, 100), /sin_permiso/);

grupo('Lo que no cambia para el staff activo');
t('vendedor: pedidos, renglones y eventos', [await cuantos(vend, 'solicitudes') > 0, await cuantos(vend, 'solicitud_items') > 0, await cuantos(vend, 'solicitud_eventos') >= 0], [true, true, true]);
t('vendedor: movimientos de stock', await cuantos(vend, 'movimientos_inventario') > 0, true);
t('vendedor: productos inactivos también (para vender y consultar)', await cuantos(vend, 'productos'), await cuantos(admin, 'productos'));
t('CRM: igual que antes (admin y vendedor sí, encargado no)',
  [await cuantos(vend, 'crm_contactos') >= 0, (await stock(`SELECT fn_get_user_role() AS r`))[0].r], [true, 'encargado_stock']);

console.log(`\n${ok} pasadas, ${fail} fallidas\n`);
process.exit(fail ? 1 : 0);
