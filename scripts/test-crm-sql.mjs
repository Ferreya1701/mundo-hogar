/**
 * Pruebas de la base del CRM (sql/009-crm.sql) contra un Postgres REAL.
 *
 *   npm i --no-save --prefix scripts @electric-sql/pglite   (una sola vez)
 *   node scripts/test-crm-sql.mjs
 *
 * PGlite es Postgres compilado a WebAssembly: corre en memoria, sin Docker
 * y sin tocar Supabase. node_modules/ está en el .gitignore, así que la
 * instalación no cambia el proyecto (sigue sin dependencias).
 *
 * Qué hace:
 *   1. Arma una base con los scripts reales 001, 002, 005, 007 y 008 y un
 *      "auth" mínimo que imita a Supabase (auth.uid(), roles anon y
 *      authenticated, permisos por defecto).
 *   2. Carga pedidos ANTES del CRM, como pasa en producción.
 *   3. Corre el 009 dos veces (tiene que ser idempotente).
 *   4. Prueba la sincronización con pedidos, las reglas de etapa, los
 *      permisos por rol y que una falla del CRM nunca frene un pedido.
 *   5. Compara la clave de teléfono de la base con la del panel
 *      (admin/crm.html) sobre cientos de números: tienen que coincidir.
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

// ── Base de prueba ────────────────────────────────────────────────
const PGlite = await cargarPGlite();
const db = new PGlite();

const SUPABASE_MINIMO = `
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
`;

await db.exec(SUPABASE_MINIMO);
// uuid-ossp no viene en PGlite y el esquema no lo usa
await db.exec(leerSQL('001-schema.sql').replace(/CREATE EXTENSION[^;]*;/i, ''));
for (const f of ['002-rls-policies.sql', '005-solicitudes.sql', '007-nucleo-stock.sql', '008-blindaje-stock.sql']) {
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
INSERT INTO productos (nombre, precio_minorista, seguimiento_inventario) VALUES
  ('Freidora de aire 5L', 89999, false),
  ('Lavarropas 8kg', NULL, false);
`);

/** Corre una consulta como un rol de Supabase, igual que la API REST. */
async function como(rol, uid, sql, params = []) {
  return db.transaction(async tx => {
    await tx.exec(`SET LOCAL ROLE ${rol}`);
    await tx.query(`SELECT set_config('request.jwt.claim.sub', $1, true)`, [uid ?? '']);
    const r = await tx.query(sql, params);
    return Object.assign(r.rows, { afectadas: r.affectedRows });
  });
}
const anon = (sql, p) => como('anon', '', sql, p);
const vend = (sql, p) => como('authenticated', VEND, sql, p);
const q    = async (sql, p) => (await db.query(sql, p)).rows;   // como dueño (SQL Editor)

/** Espera que falle con un mensaje que matchee el patrón. */
async function falla(nombre, fn, patron) {
  try { await fn(); t(nombre, 'no falló', 'falla con ' + patron); }
  catch (e) { t(nombre, patron.test(e.message) ? 'falló bien' : e.message, 'falló bien'); }
}

const pedido = (nombre, telefono, items, extra = {}) =>
  anon(`SELECT crear_solicitud($1::jsonb) AS r`, [JSON.stringify({ nombre, telefono, items, ...extra })])
    .then(r => r[0].r);
const idSol = async codigo => (await q(`SELECT id FROM solicitudes WHERE codigo = $1`, [codigo]))[0].id;
const estadoPedido = (id, estado) =>
  vend(`SELECT cambiar_estado_solicitud($1, $2) AS r`, [id, estado]);

// ── Pedidos que ya existían antes del CRM ─────────────────────────
const pA = await pedido('Juan Pérez', '+54 9 342 648-1326', [{ id: 1, cantidad: 1 }]);
const pB = await pedido('Juan Perez', '0342 15 648-1326', [{ id: 2, cantidad: 1 }]);
const pC = await pedido('Ferretería El Clavo', '341 555-1234', [],
  { canal: 'mayorista', es_mayorista: true, comercio: 'El Clavo SRL', cuit: '30-12345678-9' });
const solA = await idSol(pA.codigo), solB = await idSol(pB.codigo), solC = await idSol(pC.codigo);
await estadoPedido(solA, 'contactado');
await estadoPedido(solA, 'confirmado');
await estadoPedido(solC, 'cancelado');

// ── Migración: dos veces ──────────────────────────────────────────
const SQL009 = leerSQL('009-crm.sql');
const SQL010 = leerSQL('010-bot-whatsapp.sql');
let errorMigracion = null;
try {
  await db.exec(SQL009); await db.exec(SQL009);
  await db.exec(SQL010); await db.exec(SQL010);
} catch (e) { errorMigracion = e.message; }

grupo('Migración');
t('009 y 010 corren limpias, dos veces seguidas', errorMigracion, null);
if (errorMigracion) { console.log(`\n${ok} pasadas, ${fail} fallidas\n`); process.exit(1); }

// ── Clave de teléfono ─────────────────────────────────────────────
grupo('Clave de teléfono (un contacto por número, escrito como sea)');
const clave = async tel => (await q(`SELECT fn_crm_tel_clave($1) AS c`, [tel]))[0].c;
const VECTORES = [
  ['+54 9 342 648-1326', '3426481326'], ['5493426481326', '3426481326'],
  ['0342 15 648-1326', '3426481326'],   ['342 15 6481326', '3426481326'],
  ['3426481326', '3426481326'],         ['+54 9 342 15 648 1326', '3426481326'],
  ['+54 342 648-1326', '3426481326'],   ['011 15 1234-5678', '1112345678'],
  ['+54 11 1234-5678', '1112345678'],   ['11 15 1234 5678', '1112345678'],
  ['(0341) 15-555-1234', '3415551234'], ['6481326', '6481326'],
  ['12345', null], ['', null], [null, null]
];
for (const [tel, esperado] of VECTORES) t(`${tel}`, await clave(tel), esperado);

// ── Carga inicial ─────────────────────────────────────────────────
grupo('Carga inicial: los pedidos que ya existían entran al CRM');
const opps = async () => q(`SELECT o.*, c.nombre AS contacto FROM crm_oportunidades o
                            JOIN crm_contactos c ON c.id = o.contacto_id ORDER BY o.id`);
let O = await opps();
t('una oportunidad por pedido (sin duplicar al correr dos veces)', O.length, 3);
t('mismo teléfono escrito distinto → mismo contacto',
  O.find(o => o.solicitud_id == solA).contacto_id === O.find(o => o.solicitud_id == solB).contacto_id, true);
t('contactos creados', (await q(`SELECT count(*)::int AS n FROM crm_contactos`))[0].n, 2);
t('pedido confirmado → venta ganada', O.find(o => o.solicitud_id == solA).etapa, 'ganada');
t('pedido nuevo → nueva consulta', O.find(o => o.solicitud_id == solB).etapa, 'nueva');
t('pedido cancelado → perdida', O.find(o => o.solicitud_id == solC).etapa, 'perdida');
t('monto = total del pedido', Number(O.find(o => o.solicitud_id == solA).monto), 89999);
t('pedido sin precio → monto vacío', O.find(o => o.solicitud_id == solB).monto, null);
t('la ganada queda cerrada', O.find(o => o.solicitud_id == solA).cerrada_at !== null, true);
t('consulta mayorista → contacto mayorista con comercio y CUIT',
  (await q(`SELECT tipo, comercio, cuit FROM crm_contactos WHERE telefono_clave = '3415551234'`))[0],
  { tipo: 'mayorista', comercio: 'El Clavo SRL', cuit: '30-12345678-9' });
t('"Oportunidad creada" asentada una sola vez por pedido',
  (await q(`SELECT count(*)::int AS n FROM crm_actividades WHERE detalle LIKE 'Oportunidad creada%'`))[0].n, 3);

// ── Pedido nuevo con el CRM ya instalado ──────────────────────────
grupo('Pedido nuevo desde la tienda');
const pD = await pedido('Juan', '342-6481326', [{ id: 1, cantidad: 2 }]);
const solD = await idSol(pD.codigo);
let oD = (await q(`SELECT * FROM crm_oportunidades WHERE solicitud_id = $1`, [solD]))[0];
t('crea su oportunidad sola', !!oD, true);
t('reutiliza el contacto de Juan', (await q(`SELECT count(*)::int AS n FROM crm_contactos`))[0].n, 2);
t('monto con el total calculado por la tienda', Number(oD.monto), 179998);
t('título con el código del pedido', oD.titulo, 'Pedido ' + pD.codigo);
t('canal web', oD.canal, 'web');

grupo('La etapa sigue al estado del pedido');
await estadoPedido(solD, 'cotizacion_enviada');
oD = (await q(`SELECT * FROM crm_oportunidades WHERE id = $1`, [oD.id]))[0];
t('cotización enviada → cotizado', oD.etapa, 'cotizado');
t('asienta el cambio en el historial',
  (await q(`SELECT detalle FROM crm_actividades WHERE oportunidad_id = $1 AND tipo = 'cambio_etapa' ORDER BY id DESC LIMIT 1`, [oD.id]))[0].detalle,
  'Nueva consulta → Cotizado');
await estadoPedido(solD, 'confirmado');
oD = (await q(`SELECT * FROM crm_oportunidades WHERE id = $1`, [oD.id]))[0];
t('confirmado → venta ganada', oD.etapa, 'ganada');
t('y queda cerrada', oD.cerrada_at !== null, true);

grupo('Las oportunidades de pedidos no se mueven a mano');
await falla('cambiar la etapa a mano → la base lo rechaza',
  () => vend(`UPDATE crm_oportunidades SET etapa = 'perdida' WHERE id = $1`, [oD.id]), /etapa_por_pedido/);
await falla('crear una oportunidad "de pedido" a mano → rechazado',
  () => vend(`INSERT INTO crm_oportunidades (contacto_id, titulo, solicitud_id) VALUES ($1, 'x', $2)`,
             [oD.contacto_id, solB]), /solicitud_solo_por_sync/);
await falla('desvincular el pedido → rechazado',
  () => vend(`UPDATE crm_oportunidades SET solicitud_id = NULL WHERE id = $1`, [oD.id]), /solicitud_solo_por_sync/);
t('sí se pueden editar los demás datos (próximo paso)',
  (await vend(`UPDATE crm_oportunidades SET proxima_accion = 'Coordinar envío' WHERE id = $1 RETURNING proxima_accion`,
              [O.find(o => o.solicitud_id == solB).id]))[0].proxima_accion, 'Coordinar envío');

// ── Consulta cargada a mano ───────────────────────────────────────
grupo('Nueva consulta (Instagram, WhatsApp, local…)');
const consulta = p => vend(`SELECT crm_nueva_consulta($1::jsonb) AS r`, [JSON.stringify(p)]).then(r => r[0].r);
const hoy = (await q(`SELECT current_date::text AS d`))[0].d;
const r1 = await consulta({ nombre: '  María   Gómez ', telefono: '342 15 444-5555', canal: 'instagram',
  instagram: '@maria.deco', titulo: 'Juego de sillas', monto: '250000',
  proxima_accion: 'Pasar precio', proxima_accion_fecha: hoy, nota: 'Vio la publicación del sábado' });
t('crea contacto nuevo', r1.contacto_nuevo, true);
const maria = (await q(`SELECT * FROM crm_contactos WHERE id = $1`, [r1.contacto_id]))[0];
t('limpia el nombre', maria.nombre, 'María Gómez');
t('instagram sin @', maria.instagram, 'maria.deco');
t('canal de origen', maria.canal_origen, 'instagram');
const o1 = (await q(`SELECT * FROM crm_oportunidades WHERE id = $1`, [r1.oportunidad_id]))[0];
t('etapa inicial: nueva consulta', o1.etapa, 'nueva');
t('responsable: quien la cargó', o1.responsable_id, VEND);
t('próximo paso con fecha', [o1.proxima_accion, o1.proxima_accion_fecha && o1.proxima_accion_fecha.toISOString().slice(0, 10)], ['Pasar precio', hoy]);
t('guarda la nota en el historial',
  (await q(`SELECT tipo, detalle, usuario_id FROM crm_actividades WHERE oportunidad_id = $1 AND tipo = 'nota'`, [o1.id]))[0],
  { tipo: 'nota', detalle: 'Vio la publicación del sábado', usuario_id: VEND });

const r2 = await consulta({ nombre: 'Maria', telefono: '+54 9 342 444-5555', canal: 'whatsapp', titulo: 'Mesa ratona' });
t('mismo teléfono en otro formato → mismo contacto', [r2.contacto_nuevo, r2.contacto_id], [false, r1.contacto_id]);
t('no le pisa el nombre', (await q(`SELECT nombre FROM crm_contactos WHERE id = $1`, [r1.contacto_id]))[0].nombre, 'María Gómez');

await falla('sin "qué busca" → pide completarlo', () => consulta({ nombre: 'X Y', titulo: ' ' }), /titulo_invalido/);
await falla('monto no numérico', () => consulta({ nombre: 'X Y', titulo: 'Algo', monto: 'abc' }), /monto_invalido/);
await falla('monto negativo', () => consulta({ nombre: 'X Y', titulo: 'Algo', monto: '-5' }), /monto_invalido/);
await falla('fecha inválida', () => consulta({ nombre: 'X Y', titulo: 'Algo', proxima_accion_fecha: 'mañana' }), /fecha_invalida/);
await falla('contacto nuevo sin nombre', () => consulta({ nombre: '', telefono: '351 600 0000', titulo: 'Algo' }), /nombre_invalido/);
const r3 = await consulta({ nombre: 'Sin Teléfono', titulo: 'Consulta en el local', canal: 'mostrador' });
t('se puede cargar sin teléfono (vino al local)', r3.contacto_nuevo, true);
const r4 = await consulta({ contacto_id: String(r1.contacto_id), titulo: 'Almohadones' });
t('o para un contacto ya elegido', r4.contacto_id, r1.contacto_id);
t('canal desconocido → "otro"',
  (await q(`SELECT canal FROM crm_oportunidades WHERE id = $1`, [(await consulta({ nombre: 'Pepe Z', titulo: 'Algo', canal: 'tiktok' })).oportunidad_id]))[0].canal, 'otro');

// ── Embudo a mano ─────────────────────────────────────────────────
grupo('Embudo de una consulta cargada a mano');
await vend(`INSERT INTO crm_actividades (oportunidad_id, contacto_id, tipo, detalle) VALUES ($1, $2, 'whatsapp', 'Le pasé fotos')`,
           [o1.id, r1.contacto_id]);
let m = (await q(`SELECT * FROM crm_oportunidades WHERE id = $1`, [o1.id]))[0];
t('registrar un WhatsApp la pasa a "contactado"', m.etapa, 'contactado');
t('y actualiza el último contacto',
  (await q(`SELECT ultimo_contacto_at IS NOT NULL AS x FROM crm_contactos WHERE id = $1`, [r1.contacto_id]))[0].x, true);
t('el cambio queda a nombre de quien lo hizo',
  (await q(`SELECT usuario_id FROM crm_actividades WHERE oportunidad_id = $1 AND detalle = 'Nueva consulta → Contactado'`, [o1.id]))[0].usuario_id, VEND);
await vend(`INSERT INTO crm_actividades (oportunidad_id, contacto_id, tipo) VALUES ($1, $2, 'llamada')`, [o1.id, r1.contacto_id]);
t('una segunda llamada no la vuelve a mover',
  (await q(`SELECT count(*)::int AS n FROM crm_actividades WHERE oportunidad_id = $1 AND tipo = 'cambio_etapa'`, [o1.id]))[0].n, 2);
await vend(`UPDATE crm_oportunidades SET etapa = 'cotizado' WHERE id = $1`, [o1.id]);
await vend(`UPDATE crm_oportunidades SET etapa = 'ganada' WHERE id = $1`, [o1.id]);
m = (await q(`SELECT * FROM crm_oportunidades WHERE id = $1`, [o1.id]))[0];
t('ganada → cerrada', m.cerrada_at !== null, true);
t('ganada → sin próximo paso (sale de "Para hoy")', [m.proxima_accion, m.proxima_accion_fecha], [null, null]);
await vend(`UPDATE crm_oportunidades SET etapa = 'cotizado' WHERE id = $1`, [o1.id]);
t('reabrir → deja de estar cerrada',
  (await q(`SELECT cerrada_at FROM crm_oportunidades WHERE id = $1`, [o1.id]))[0].cerrada_at, null);
await vend(`UPDATE crm_oportunidades SET etapa = 'perdida', motivo_perdida = 'Precio' WHERE id = $1`, [o1.id]);
t('perdida con motivo → el motivo queda en el historial',
  (await q(`SELECT detalle FROM crm_actividades WHERE oportunidad_id = $1 ORDER BY id DESC LIMIT 1`, [o1.id]))[0].detalle,
  'Cotizado → Perdida (Precio)');
await vend(`UPDATE crm_oportunidades SET etapa = 'contactado' WHERE id = $1`, [o1.id]);
t('si se reabre, el motivo de pérdida se borra',
  (await q(`SELECT motivo_perdida FROM crm_oportunidades WHERE id = $1`, [o1.id]))[0].motivo_perdida, null);
t('el historial no queda cruzado entre contactos',
  (await vend(`INSERT INTO crm_actividades (oportunidad_id, contacto_id, tipo, detalle) VALUES ($1, $2, 'nota', 'x') RETURNING contacto_id`,
              [o1.id, oD.contacto_id]))[0].contacto_id == r1.contacto_id, true);

// ── Contactos ─────────────────────────────────────────────────────
grupo('Contactos');
await falla('dos contactos activos con el mismo teléfono → rechazado',
  () => vend(`INSERT INTO crm_contactos (nombre, telefono) VALUES ('Otro Juan', '0342-15-648-1326')`), /uq_crm_contactos_tel|duplicate/);
const juan = oD.contacto_id;
await vend(`UPDATE crm_contactos SET archivado = true WHERE id = $1`, [juan]);
const pE = await pedido('Juan Pérez', '3426481326', [{ id: 1, cantidad: 1 }]);
const oE = (await q(`SELECT o.contacto_id, c.archivado FROM crm_oportunidades o JOIN crm_contactos c ON c.id = o.contacto_id
                     WHERE o.solicitud_id = $1`, [await idSol(pE.codigo)]))[0];
t('un archivado que vuelve a comprar se reactiva (no se duplica)', [oE.contacto_id, oE.archivado], [juan, false]);
t('email en minúscula',
  (await vend(`INSERT INTO crm_contactos (nombre, email) VALUES ('Lu', '  Lu@Mail.COM ') RETURNING email`))[0].email, 'lu@mail.com');

// ── Permisos ──────────────────────────────────────────────────────
grupo('Permisos: el encargado de stock y el público no entran');
t('stock: no ve contactos', (await como('authenticated', STOCK, `SELECT count(*)::int AS n FROM crm_contactos`))[0].n, 0);
t('stock: no ve oportunidades', (await como('authenticated', STOCK, `SELECT count(*)::int AS n FROM crm_oportunidades`))[0].n, 0);
await falla('stock: no puede crear contactos',
  () => como('authenticated', STOCK, `INSERT INTO crm_contactos (nombre) VALUES ('x')`), /row-level security/);
await falla('stock: no puede usar "nueva consulta"',
  () => como('authenticated', STOCK, `SELECT crm_nueva_consulta('{"nombre":"x y","titulo":"algo"}'::jsonb)`), /sin_permiso/);
await falla('público: no lee contactos', () => anon(`SELECT * FROM crm_contactos`), /permission denied/);
await falla('público: no lee el historial', () => anon(`SELECT * FROM crm_actividades`), /permission denied/);
await falla('público: no puede usar "nueva consulta"',
  () => anon(`SELECT crm_nueva_consulta('{}'::jsonb)`), /permission denied/);
await falla('público: no puede llamar la función interna',
  () => anon(`SELECT fn_crm_vincular_solicitud(1)`), /permission denied/);
await falla('vendedor: no puede llamar la carga inicial',
  () => vend(`SELECT fn_crm_incorporar_solicitudes()`), /permission denied/);
t('vendedor: ve el CRM', (await vend(`SELECT count(*)::int AS n FROM crm_contactos`))[0].n > 0, true);

grupo('El historial no se edita ni se borra');
const act = (await q(`SELECT id, detalle FROM crm_actividades ORDER BY id LIMIT 1`))[0];
t('editar: no afecta ninguna fila',
  (await vend(`UPDATE crm_actividades SET detalle = 'trucho' WHERE id = $1`, [act.id])).afectadas, 0);
t('borrar: no afecta ninguna fila',
  (await vend(`DELETE FROM crm_actividades WHERE id = $1`, [act.id])).afectadas, 0);
t('sigue intacto', (await q(`SELECT detalle FROM crm_actividades WHERE id = $1`, [act.id]))[0].detalle, act.detalle);
await falla('no se puede inventar un "cambio de etapa"',
  () => vend(`INSERT INTO crm_actividades (contacto_id, tipo, detalle) VALUES ($1, 'cambio_etapa', 'x')`, [juan]), /row-level security/);
await falla('no se puede cargar a nombre de otro',
  () => vend(`INSERT INTO crm_actividades (contacto_id, tipo, usuario_id) VALUES ($1, 'nota', $2)`, [juan, ADMIN]), /row-level security/);
t('vendedor: no borra contactos',
  (await vend(`DELETE FROM crm_contactos WHERE id = $1`, [juan])).afectadas, 0);
t('vendedor: no borra oportunidades',
  (await vend(`DELETE FROM crm_oportunidades WHERE id = $1`, [o1.id])).afectadas, 0);

// ── El CRM nunca frena una venta ──────────────────────────────────
grupo('Si el CRM falla, el pedido sale igual');
await q(`ALTER TABLE crm_contactos ADD CONSTRAINT prueba_falla CHECK (false) NOT VALID`);
let pF = null, errF = null;
try { pF = await pedido('Cliente Nuevo', '351 777 8888', [{ id: 1, cantidad: 1 }]); } catch (e) { errF = e.message; }
t('el pedido se crea igual', [errF, !!(pF && pF.codigo)], [null, true]);
const solF = pF ? await idSol(pF.codigo) : null;
t('(y queda sin oportunidad por ahora)',
  (await q(`SELECT count(*)::int AS n FROM crm_oportunidades WHERE solicitud_id = $1`, [solF]))[0].n, 0);
await q(`ALTER TABLE crm_contactos DROP CONSTRAINT prueba_falla`);
t('la carga inicial lo recupera después',
  (await q(`SELECT fn_crm_incorporar_solicitudes() AS n`))[0].n, 1);

await q(`ALTER TABLE crm_oportunidades ADD CONSTRAINT prueba_falla CHECK (etapa <> 'contactado') NOT VALID`);
let errG = null;
try { await estadoPedido(solF, 'contactado'); } catch (e) { errG = e.message; }
t('un cambio de estado del pedido no se frena si falla la sincronización', errG, null);
t('el pedido cambió de estado', (await q(`SELECT estado FROM solicitudes WHERE id = $1`, [solF]))[0].estado, 'contactado');
await q(`ALTER TABLE crm_oportunidades DROP CONSTRAINT prueba_falla`);
await estadoPedido(solF, 'cotizacion_enviada');
t('y el CRM se pone al día en el cambio siguiente',
  (await q(`SELECT etapa FROM crm_oportunidades WHERE solicitud_id = $1`, [solF]))[0].etapa, 'cotizado');

// ── Bot de WhatsApp (sql/010) ─────────────────────────────────────
grupo('Bot · catálogo público con la misma regla que la tienda');
await q(`INSERT INTO categorias (nombre, slug) VALUES ('Electro', 'electro')`);
const cat = (await q(`SELECT id FROM categorias WHERE slug = 'electro'`))[0].id;
await q(`INSERT INTO productos (nombre, slug, categoria_id, precio_minorista, seguimiento_inventario) VALUES
  ('Pava eléctrica', 'pava', $1, 25000, true),
  ('Tostadora', 'tostadora', $1, 30000, true),
  ('Heladera', 'heladera', $1, NULL, true),
  ('Microondas', 'microondas', $1, 150000, true)`, [cat]);
await q(`UPDATE productos SET en_oferta = true, precio_oferta = 120000, permite_venta_sin_stock = true WHERE slug = 'microondas'`);
await q(`INSERT INTO productos (nombre, slug, precio_minorista, estado) VALUES ('Discontinuado', 'disc', 1000, 'inactivo')`);
await como('authenticated', ADMIN, `SELECT fn_registrar_movimiento((SELECT id FROM productos WHERE slug = 'tostadora'), 'carga_inicial', 5)`);
const cb = Object.fromEntries((await anon(`SELECT * FROM catalogo_bot`)).map(r => [r.nombre, r]));
t('el público lo lee', Object.keys(cb).length >= 5, true);
t('solo activos', 'Discontinuado' in cb, false);
t('con precio y stock 0 → sin stock (como la web)', cb['Pava eléctrica'].disponible, false);
t('con stock → disponible', cb['Tostadora'].disponible, true);
t('sin precio → "consultar" y no se afirma stock', [cb['Heladera'].precio, cb['Heladera'].disponible], [null, true]);
t('oferta → precio de oferta y precio anterior',
  [Number(cb['Microondas'].precio), Number(cb['Microondas'].precio_anterior), cb['Microondas'].en_oferta], [120000, 150000, true]);
t('se vende sin stock → disponible', cb['Microondas'].disponible, true);
t('link a la ficha de la tienda', cb['Tostadora'].url, 'https://mundohogarstf.com/producto/tostadora');
t('categoría por nombre', cb['Tostadora'].categoria, 'Electro');

grupo('Bot · clave de la integración');
const claveBot = (await q(`SELECT crm_crear_integracion('panelbot') AS k`))[0].k;
t('formato de la clave', /^mhcrm_[0-9a-f]{64}$/.test(claveBot), true);
t('en la base no se guarda la clave, solo su hash',
  (await q(`SELECT count(*)::int AS n FROM crm_integraciones WHERE token_hash = $1`, [claveBot]))[0].n, 0);
await falla('el público no puede crear claves', () => anon(`SELECT crm_crear_integracion('x')`), /permission denied/);
await falla('el staff tampoco', () => vend(`SELECT crm_crear_integracion('x')`), /permission denied/);
await falla('nadie lee la tabla de claves por la API', () => vend(`SELECT * FROM crm_integraciones`), /permission denied/);
const bot = (p, k = claveBot) => anon(`SELECT crm_bot_evento($1, $2::jsonb) AS r`, [k, JSON.stringify(p)]).then(r => r[0].r);
await falla('clave equivocada → no autorizado',
  () => bot({ tipo:'consulta', ref:'x', telefono:'3420000001' }, 'mhcrm_trucha'), /no_autorizado/);

grupo('Bot · consultas que pasa a una persona');
const hoyAR = (await q(`SELECT (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date::text AS d`))[0].d;
const c1 = await bot({ tipo:'consulta', ref:'conv-1', telefono:'+54 9 351 600 1111', nombre:'Rocío Paz',
                       titulo:'Juego de sillas', resumen:'Pregunta si hay en gris' });
t('crea contacto y oportunidad', [c1.ok, c1.contacto_nuevo, c1.oportunidad_nueva], [true, true, true]);
const oc1 = (await q(`SELECT * FROM crm_oportunidades WHERE id = $1`, [c1.oportunidad_id]))[0];
t('entra en "Para hoy": nueva, por WhatsApp, con fecha de hoy en Argentina',
  [oc1.etapa, oc1.canal, oc1.proxima_accion_fecha.toISOString().slice(0, 10)], ['nueva', 'whatsapp', hoyAR]);
t('el resumen queda en el historial',
  (await q(`SELECT detalle FROM crm_actividades WHERE oportunidad_id = $1 AND tipo = 'sistema'`, [c1.oportunidad_id]))[0].detalle,
  '🤖 El bot pasó la charla a una persona: Pregunta si hay en gris');
t('el link abre la ficha en el CRM', c1.url, 'https://mundohogarstf.com/admin/crm.html?op=' + c1.oportunidad_id);
const c1b = await bot({ tipo:'consulta', ref:'conv-1', telefono:'3516001111', nombre:'Rocío Paz', titulo:'Juego de sillas' });
t('el mismo ref (reintento) no duplica', [c1b.oportunidad_id, c1b.oportunidad_nueva], [c1.oportunidad_id, false]);
const c2 = await bot({ tipo:'consulta', ref:'conv-2', telefono:'3426481326' });
t('cliente que ya compró en la web → mismo contacto', c2.contacto_id == juan, true);
t('y no le pisa el nombre', (await q(`SELECT nombre FROM crm_contactos WHERE id = $1`, [juan]))[0].nombre, 'Juan Pérez');
const c3 = await bot({ tipo:'consulta', ref:'conv-3', telefono:'3517770000' });
t('sin nombre → "Cliente de WhatsApp" y los últimos 4',
  (await q(`SELECT nombre FROM crm_contactos WHERE id = $1`, [c3.contacto_id]))[0].nombre, 'Cliente de WhatsApp 0000');
await bot({ tipo:'consulta', ref:'conv-4', telefono:'3517770000', nombre:'Marcos Díaz' });
t('cuando llega el nombre real, se completa',
  (await q(`SELECT nombre FROM crm_contactos WHERE id = $1`, [c3.contacto_id]))[0].nombre, 'Marcos Díaz');

grupo('Bot · pedidos');
const p1 = await bot({ tipo:'pedido', ref:'ped-1', telefono:'3516001111', nombre:'Rocío Paz',
  items:[{ nombre:'Freidora de aire 5L', cantidad:2, precio:89999 }, { nombre:'Tostadora', cantidad:1, precio:30000 }] });
const opp = async id => (await q(`SELECT * FROM crm_oportunidades WHERE id = $1`, [id]))[0];
const ultimaNota = async id => (await q(`SELECT detalle FROM crm_actividades WHERE oportunidad_id = $1 AND tipo = 'sistema' ORDER BY id DESC LIMIT 1`, [id]))[0].detalle;
let op1 = await opp(p1.oportunidad_id);
t('total calculado', Number(op1.monto), 209998);
t('título con el primer producto', op1.titulo, 'Pedido por WhatsApp · Freidora de aire 5L y 1 más');
t('próximo paso: confirmar', op1.proxima_accion, 'Confirmar el pedido con el cliente');
t('el detalle lista los productos con precios en pesos', await ultimaNota(p1.oportunidad_id),
  '🤖 El bot tomó un pedido por WhatsApp:\n• 2× Freidora de aire 5L — $179.998\n• 1× Tostadora — $30.000\nTotal: $209.998');
const p2 = await bot({ tipo:'pedido', ref:'ped-2', telefono:'3516001111', items:[{ nombre:'Heladera', cantidad:1, precio:null }] });
const op2 = await opp(p2.oportunidad_id);
t('con productos a cotizar → total vacío', op2.monto, null);
t('y el próximo paso lo dice', op2.proxima_accion, 'Cotizar lo que falta y confirmar el pedido');
await bot({ tipo:'pedido', ref:'ped-1', telefono:'3516001111', items:[{ nombre:'Freidora de aire 5L', cantidad:1, precio:89999 }] });
op1 = await opp(p1.oportunidad_id);
t('si el cliente corrige el pedido, se actualiza la misma oportunidad',
  [Number(op1.monto), op1.titulo], [89999, 'Pedido por WhatsApp · Freidora de aire 5L']);
await vend(`UPDATE crm_oportunidades SET etapa = 'ganada' WHERE id = $1`, [p1.oportunidad_id]);
await bot({ tipo:'pedido', ref:'ped-1', telefono:'3516001111', items:[{ nombre:'Freidora de aire 5L', cantidad:5, precio:89999 }] });
op1 = await opp(p1.oportunidad_id);
t('si el equipo ya la cerró, el bot no la toca', [op1.etapa, Number(op1.monto)], ['ganada', 89999]);
t('pero el cambio queda asentado', (await ultimaNota(p1.oportunidad_id)).startsWith('🤖 El cliente cambió el pedido:'), true);
t('el vendedor ve todo en el CRM',
  (await vend(`SELECT count(*)::int AS n FROM crm_oportunidades WHERE ref_externa LIKE 'panelbot:%'`))[0].n, 6);

grupo('Bot · datos inválidos');
await falla('tipo desconocido', () => bot({ tipo:'spam', ref:'z', telefono:'3420000002' }), /tipo_invalido/);
await falla('sin ref', () => bot({ tipo:'consulta', telefono:'3420000002' }), /ref_requerida/);
await falla('sin teléfono', () => bot({ tipo:'consulta', ref:'z' }), /telefono_invalido/);
await falla('pedido sin productos', () => bot({ tipo:'pedido', ref:'z', telefono:'3420000002', items:[] }), /items_invalidos/);
await falla('precio que no es número', () => bot({ tipo:'pedido', ref:'z', telefono:'3420000002', items:[{ nombre:'x', precio:'mucho' }] }), /items_invalidos/);

grupo('Bot · límite, rotación y corte de la clave');
await q(`UPDATE crm_integraciones SET eventos_ventana = 120, ventana_desde = now() WHERE nombre = 'panelbot'`);
await falla('más de 120 eventos por minuto → frena', () => bot({ tipo:'consulta', ref:'z2', telefono:'3420000003' }), /limite_eventos/);
await q(`UPDATE crm_integraciones SET eventos_ventana = 0 WHERE nombre = 'panelbot'`);
const claveNueva = (await q(`SELECT crm_crear_integracion('panelbot') AS k`))[0].k;
await falla('rotar la clave: la vieja deja de andar', () => bot({ tipo:'consulta', ref:'z3', telefono:'3420000004' }), /no_autorizado/);
t('la nueva anda', (await bot({ tipo:'consulta', ref:'z3', telefono:'3420000004' }, claveNueva)).ok, true);
await q(`UPDATE crm_integraciones SET activo = false WHERE nombre = 'panelbot'`);
await falla('desactivada → no autorizado', () => bot({ tipo:'consulta', ref:'z4', telefono:'3420000005' }, claveNueva), /no_autorizado/);

// ── La regla del panel = la regla de la base ──────────────────────
grupo('Clave de teléfono: panel y base dan lo mismo');
const CRM = path.join(RAIZ, 'admin', 'crm.html');
if (fs.existsSync(CRM)) {
  const lineas = fs.readFileSync(CRM, 'utf8').split(/\r?\n/);
  const i = lineas.findIndex(l => /^function telClave/.test(l));
  const j = lineas.findIndex((l, k) => k > i && /^}/.test(l));
  const telClave = new Function(lineas.slice(i, j + 1).join('\n') + '\nreturn telClave;')();
  const formatos = [];
  const areas = ['342', '341', '11', '351', '3482', '2972'];
  let semilla = 7;
  const azar = n => { semilla = (semilla * 48271) % 2147483647; return semilla % n; };
  for (let k = 0; k < 400; k++) {
    const area = areas[azar(areas.length)];
    const largo = 10 - area.length;
    let num = ''; for (let d = 0; d < largo; d++) num += azar(10);
    const plantillas = [
      `+54 9 ${area} ${num}`, `0${area} 15 ${num}`, `${area} ${num}`, `54${area}${num}`,
      `(0${area}) 15-${num.slice(0, 3)}-${num.slice(3)}`, `${area}15${num}`, `+54 ${area} ${num}`, num
    ];
    formatos.push(plantillas[azar(plantillas.length)]);
  }
  formatos.push(...VECTORES.map(v => v[0]));
  let distintos = 0, ejemplo = null;
  for (const f of formatos) {
    const a = telClave(f), b = await clave(f);
    if (a !== b) { distintos++; ejemplo ??= { f, panel: a, base: b }; }
  }
  t(`${formatos.length} teléfonos en formatos mezclados: sin diferencias`, ejemplo, null);
} else {
  console.log('  (admin/crm.html todavía no existe: se salta)');
}

console.log(`\n${ok} pasadas, ${fail} fallidas\n`);
process.exit(fail ? 1 : 0);
