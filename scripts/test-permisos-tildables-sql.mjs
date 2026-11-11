/**
 * Pruebas de los permisos tildables por rol (sql/016-permisos-tildables.sql)
 * contra un Postgres REAL en memoria (PGlite), sin tocar Supabase.
 *
 *   npm i --no-save --prefix scripts @electric-sql/pglite   (una sola vez)
 *   node scripts/test-permisos-tildables-sql.mjs
 *
 * Corre 001..016 y prueba:
 *   • que el día que se instala cada rol puede EXACTAMENTE lo mismo que antes;
 *   • que destildar un permiso lo corta en la base (funciones y políticas);
 *   • que tildar uno nuevo lo habilita;
 *   • que el administrador siempre puede todo y una cuenta desactivada nada;
 *   • que solo el administrador cambia permisos y queda registrado;
 *   • que volver a correr el 016 no vuelve a tildar lo que se destildó.
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

const vender = (quien, precio = 1000) => quien(`SELECT venta_registrar($1::jsonb) AS r`,
  [JSON.stringify({ items: [{ producto_id: 2, cantidad: 1, precio_unitario: precio }], medio_pago: 'efectivo' })]).then(r => r[0].r);
const anular = (quien, id) => quien(`SELECT venta_anular($1, 'prueba') AS r`, [id]);
const contar = quien => quien(`SELECT fn_stock_contar(1, 10, 'prueba')`);
const ajustar = quien => quien(`SELECT fn_registrar_movimiento(1, 'ajuste_positivo', 1, 'prueba')`);
const editarProducto = quien => quien(`UPDATE productos SET nombre = nombre WHERE id = 2`).then(r => { if (!r.afectadas) throw new Error('row-level security: 0 filas'); });
const editarCategoria = quien => quien(`UPDATE categorias SET nombre = nombre WHERE id = 1`).then(r => { if (!r.afectadas) throw new Error('row-level security: 0 filas'); });

// Pedido web para probar los permisos de pedidos
await anon(`SELECT crear_solicitud($1::jsonb)`, [JSON.stringify({ nombre: 'Cliente', telefono: '3425551111', items: [{ id: 2, cantidad: 1 }] })]);
const ventaVero = (await vender(vend)).id;
const ventaVale = (await vender(vend2)).id;

// ── Migración ─────────────────────────────────────────────────────
grupo('Migración');
let errorMigracion = null, resumen = null;
const SQL016 = leerSQL('016-permisos-tildables.sql');
try { await db.exec(SQL016); resumen = (await db.exec(SQL016)).at(-1).rows; } catch (e) { errorMigracion = e.message; }
t('016 corre limpio, dos veces seguidas', errorMigracion, null);
if (errorMigracion) { console.log(`\n${ok} pasadas, ${fail} fallidas\n`); process.exit(1); }
t('resumen: lo que quedó tildado para cada rol', resumen, [
  { rol: 'encargado_stock', permisos: ['ventas.crear', 'ventas.ver_todas', 'ventas.anular_propias', 'productos.editar', 'stock.contar', 'stock.ajustar', 'compras.gestionar'] },
  { rol: 'vendedor',        permisos: ['ventas.crear', 'ventas.anular_propias', 'pedidos.gestionar', 'pedidos.cobrar', 'clientes.gestionar'] },
]);
const funcionesConRolEscrito = await q(`
  SELECT p.proname FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = ANY($1)
    AND (pg_get_functiondef(p.oid) LIKE '%NOT IN (''administrador''%' OR pg_get_functiondef(p.oid) LIKE '%v_rol <> ''administrador''%')`,
  [['fn_registrar_movimiento', 'fn_stock_contar', 'fn_stock_contar_lote', 'fn_stock_quitar_control', 'producto_crear_rapido',
    'cambiar_estado_solicitud', 'anular_pago', 'crm_nueva_consulta', 'crm_base_conversacion', 'venta_registrar', 'venta_anular']]);
t('ninguna función sigue con el rol escrito a mano', funcionesConRolEscrito, []);
t('las funciones cambiadas siguen siendo SECURITY DEFINER',
  (await q(`SELECT bool_and(prosecdef) AS ok FROM pg_proc WHERE proname IN ('venta_registrar','venta_anular','fn_stock_contar','cambiar_estado_solicitud')`))[0].ok, true);

// ── Día 1: todo igual que antes ───────────────────────────────────
grupo('Día 1: cada rol puede lo mismo que antes');
t('mis permisos: vendedor', (await vend(`SELECT fn_mis_permisos() AS p`))[0].p,
  ['ventas.crear', 'ventas.anular_propias', 'pedidos.gestionar', 'pedidos.cobrar', 'clientes.gestionar']);
t('mis permisos: administrador tiene los 13', (await admin(`SELECT cardinality(fn_mis_permisos()) AS n`))[0].n, 13);
t('mis permisos: cuenta desactivada → ninguno', await q(`UPDATE profiles SET activo = false WHERE id = $1 RETURNING id`, [EX]).then(() => ex(`SELECT fn_mis_permisos() AS p`)).then(r => r[0].p), []);
await pasa('vendedor vende', () => vender(vend));
await pasa('encargado vende', () => vender(stock));
await falla('cuenta desactivada no vende', () => vender(ex), /sin_permiso/);
t('vendedor ve solo sus ventas', (await vend(`SELECT array_agg(DISTINCT vendedor_id::text) AS v FROM ventas`))[0].v, [VEND]);
t('encargado ve las de todos', (await stock(`SELECT count(DISTINCT vendedor_id)::int AS n FROM ventas`))[0].n, 3);
await falla('vendedor no anula una venta de otro', () => anular(vend, ventaVale), /sin_permiso/);
await pasa('vendedor anula la suya', () => anular(vend, ventaVero));
await pasa('admin anula la de otro', () => anular(admin, ventaVale));
await pasa('encargado cuenta stock', () => contar(stock));
await falla('vendedor no cuenta stock', () => contar(vend), /sin_permiso/);
await pasa('encargado hace ajuste manual', () => ajustar(stock));
await falla('vendedor no hace ajuste manual', () => ajustar(vend), /sin_permiso/);
await pasa('encargado edita productos', () => editarProducto(stock));
await falla('vendedor no edita productos', () => editarProducto(vend), /row-level security/);
await falla('encargado no edita categorías', () => editarCategoria(stock), /row-level security/);
await pasa('admin edita categorías', () => editarCategoria(admin));
await pasa('vendedor cambia estado de un pedido web', () => vend(`SELECT cambiar_estado_solicitud(1, 'contactado')`));
await falla('encargado no cambia estado de un pedido web', () => stock(`SELECT cambiar_estado_solicitud(1, 'contactado')`), /sin_permiso/);
await pasa('vendedor habilita el pago de un pedido', () => vend(`SELECT habilitar_pago(1)`));
await falla('encargado no habilita pagos', () => stock(`SELECT habilitar_pago(1)`), /sin_permiso/);
await falla('vendedor no anula pagos confirmados', () => vend(`SELECT anular_pago(1, 'x')`), /sin_permiso/);
t('CRM: vendedor sí, encargado no (devuelve 0 filas)', [await cuantos(vend, 'crm_contactos') >= 0, await cuantos(stock, 'crm_contactos')], [true, 0]);
await falla('encargado no carga consultas al CRM', () => stock(`SELECT crm_nueva_consulta('{}'::jsonb)`), /sin_permiso/);
t('compras: encargado sí, vendedor no', [await cuantos(stock, 'compras'), await cuantos(vend, 'compras')], [0, 0]);
await falla('vendedor no crea compras', () => vend(`SELECT compra_crear('{}'::jsonb)`), /sin_permiso/);

// ── Cambiar permisos ──────────────────────────────────────────────
grupo('Solo el administrador cambia permisos');
await falla('vendedor no puede darse permisos', () => vend(`SELECT permisos_rol_guardar('vendedor', ARRAY['stock.ajustar'])`), /sin_permiso/);
await falla('encargado tampoco', () => stock(`SELECT permisos_rol_guardar('encargado_stock', ARRAY['ventas.anular_todas'])`), /sin_permiso/);
await falla('ni escribiendo la tabla directo', () => vend(`INSERT INTO rol_permisos (rol, permiso) VALUES ('vendedor','stock.ajustar')`), /row-level security|permission denied/);
await falla('el rol administrador no se edita', () => admin(`SELECT permisos_rol_guardar('administrador', ARRAY[]::text[])`), /rol_invalido/);
await falla('un permiso inventado se rechaza', () => admin(`SELECT permisos_rol_guardar('vendedor', ARRAY['ventas.crear','todo.todo'])`), /permiso_desconocido/);
t('vendedor y encargado no leen la tabla de asignaciones', [await cuantos(vend, 'rol_permisos'), await cuantos(stock, 'rol_permisos')], [0, 0]);
t('todos leen el catálogo de permisos', await cuantos(vend, 'permisos'), 13);
await falla('anónimo no lee nada de permisos', () => anon(`SELECT * FROM permisos`), /permission denied/);

grupo('Destildar corta en la base');
const r1 = (await admin(`SELECT permisos_rol_guardar('vendedor', ARRAY['ventas.crear','pedidos.gestionar','pedidos.cobrar','ventas.ver_todas']) AS r`))[0].r;
t('devuelve qué se agregó y qué se quitó', [r1.agregados, r1.quitados], [['ventas.ver_todas'], ['clientes.gestionar', 'ventas.anular_propias']]);
t('queda en el historial', (await q(`SELECT accion, entidad, entidad_id, usuario_id::text AS quien, valores_nuevos->'agregados' AS ag, valores_nuevos->'quitados' AS qu
                                       FROM historial_actividad WHERE entidad = 'permisos'`)),
  [{ accion: 'actualizar', entidad: 'permisos', entidad_id: 'vendedor', quien: ADMIN, ag: ['ventas.ver_todas'], qu: ['clientes.gestionar', 'ventas.anular_propias'] }]);
const otraVero = (await vender(vend)).id;
await falla('sin "anular propias", el vendedor ya no anula ni la suya', () => anular(vend, otraVero), /sin_permiso/);
t('sin "clientes", el vendedor no ve el CRM', await cuantos(vend, 'crm_contactos'), 0);
await falla('ni carga consultas', () => vend(`SELECT crm_nueva_consulta('{}'::jsonb)`), /sin_permiso/);
t('con "ver todas", el vendedor ve las ventas de todos', (await vend(`SELECT count(DISTINCT vendedor_id)::int AS n FROM ventas`))[0].n, 3);
t('a Vale (otro vendedor) le pasa lo mismo: el permiso es del rol', (await vend2(`SELECT count(DISTINCT vendedor_id)::int AS n FROM ventas`))[0].n, 3);

await admin(`SELECT permisos_rol_guardar('encargado_stock', ARRAY['ventas.crear','stock.contar'])`);
await falla('sin "ajuste manual", el encargado ya no ajusta', () => ajustar(stock), /sin_permiso/);
await falla('sin "productos", no edita productos', () => editarProducto(stock), /row-level security/);
t('sin "compras", no ve compras ni costos', [await cuantos(stock, 'compras'), await cuantos(stock, 'producto_costos')], [0, 0]);
t('sin "ver todas", ve solo sus ventas', (await stock(`SELECT array_agg(DISTINCT vendedor_id::text) AS v FROM ventas`))[0].v, [STOCK]);
await pasa('pero sigue contando stock (el conteo no exige "ajuste manual")', () => contar(stock));
t('y el conteo quedó asentado como movimiento', (await q(`SELECT count(*)::int AS n FROM movimientos_inventario WHERE motivo IN ('Conteo de stock','Conteo inicial')`))[0].n > 0, true);
await admin(`SELECT permisos_rol_guardar('vendedor', ARRAY['compras.gestionar'])`);
const compra = (await vend(`SELECT compra_crear($1::jsonb) AS r`, [JSON.stringify({ proveedor: 'Yiwu', moneda: 'ARS',
  items: [{ descripcion: 'AIR FRYER', cantidad: 2, costo_unitario: 30000, accion: 'vincular', producto_id: 1 }] })]))[0].r;
const item = (await q(`SELECT id FROM compra_items WHERE compra_id = $1`, [compra.id]))[0].id;
await pasa('quien tiene solo "compras" recibe la mercadería (sin "ajuste manual")',
  () => vend(`SELECT compra_recibir($1, $2::jsonb)`, [compra.id, JSON.stringify([{ item_id: item, cantidad: 2 }])]));
t('y la entrada de compra quedó asentada', (await q(`SELECT count(*)::int AS n FROM movimientos_inventario WHERE tipo = 'entrada_compra'`))[0].n, 1);
await falla('pero no puede hacer un ajuste manual suelto', () => ajustar(vend), /sin_permiso/);
await admin(`SELECT permisos_rol_guardar('vendedor', ARRAY['ventas.crear','pedidos.gestionar','pedidos.cobrar','ventas.ver_todas'])`);
await pasa('el ajuste interno de una venta sigue andando (no depende del permiso)', () => vender(stock));

grupo('Tildar habilita');
await admin(`SELECT permisos_rol_guardar('encargado_stock', ARRAY['ventas.crear','stock.contar','categorias.editar','ventas.anular_todas'])`);
await pasa('con "categorías", el encargado edita categorías', () => editarCategoria(stock));
await pasa('con "anular cualquier venta", anula la de otro vendedor', () => anular(stock, otraVero));

grupo('El administrador no depende de lo tildado');
for (const rol of ['vendedor', 'encargado_stock']) await admin(`SELECT permisos_rol_guardar($1, ARRAY[]::text[])`, [rol]);
await pasa('admin vende', () => vender(admin));
await pasa('admin ajusta stock', () => ajustar(admin));
await pasa('admin edita productos', () => editarProducto(admin));
t('admin ve el CRM y las compras', [await cuantos(admin, 'crm_contactos') >= 0, await cuantos(admin, 'compras') >= 0], [true, true]);
await falla('vendedor sin nada no vende', () => vender(vend), /sin_permiso/);

grupo('Volver a correr el 016 respeta lo que eligió el administrador');
await admin(`SELECT permisos_rol_guardar('vendedor', ARRAY['ventas.crear'])`);
await db.exec(SQL016);
t('el vendedor sigue solo con "crear ventas"', (await vend(`SELECT fn_mis_permisos() AS p`))[0].p, ['ventas.crear']);
t('el encargado sigue sin nada', (await stock(`SELECT fn_mis_permisos() AS p`))[0].p, []);

console.log(`\n${ok} pasadas, ${fail} fallidas\n`);
process.exit(fail ? 1 : 0);
