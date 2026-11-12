/**
 * Pruebas de entregas: retiros en el local y envíos (sql/027-entregas.sql)
 * contra un Postgres REAL en memoria (PGlite).
 *
 *   node scripts/test-entregas-sql.mjs
 *
 * Prueba: la venta guarda cómo se entrega, lo sin pagar no sale (salvo cuenta
 * corriente), listo / entregar / despachar varios / deshacer, quién retiró,
 * empresas de transporte, quién ve qué, y que nada se rompa con la caja.
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










const vender = (quien, items, extra = {}) => quien(`SELECT venta_registrar($1::jsonb) AS r`, [JSON.stringify({ items, ...extra })]).then(r => r[0].r);
const cobrar = (quien, id, total) => quien(`SELECT venta_cobrar($1, $2::jsonb) r`, [id, JSON.stringify([{ medio: 'efectivo', monto: total }])]).then(r => r[0].r);
const ent = async id => (await q(`SELECT entrega_tipo t, entrega_estado e, entrega_fecha::text f, transporte_id::int tr, envio_direccion d, envio_localidad l,
  recibio_nombre rn, recibio_dni rd, entregada_por_nombre ep, envio_seguimiento s, lista_por_nombre lp FROM ventas WHERE id = $1`, [id]))[0];
const hoy = (await q(`SELECT (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date::text d`))[0].d;
const T = [{ producto_id: 2, cantidad: 1, precio_unitario: 10000 }];

grupo('Migración');
let err = null, res = null;
const SQL = leerSQL('027-entregas.sql');
try { await db.exec(SQL); res = (await db.exec(SQL)).at(-1).rows[0]; } catch (e) { err = e.message; }
t('027 corre limpio, dos veces seguidas', err, null);
if (err) { console.log(`\n${ok} pasadas, ${fail} fallidas\n`); process.exit(1); }
t('vendedor y encargado: ver y entregar; transportes solo admin', [
  (await vend(`SELECT fn_mis_permisos() p`))[0].p.filter(x => x.startsWith('entregas.')),
  (await stock(`SELECT fn_mis_permisos() p`))[0].p.filter(x => x.startsWith('entregas.'))], [['entregas.ver', 'entregas.gestionar'], ['entregas.ver', 'entregas.gestionar']]);

grupo('Empresas de transporte');
await falla('el vendedor no las edita', () => vend(`INSERT INTO transportes (nombre) VALUES ('Andreani')`), /row-level/);
await admin(`INSERT INTO transportes (nombre, notas) VALUES ('Andreani', 'Pasa a las 16 h'), ('Vía Cargo', NULL)`);
const [AND, VIA] = (await q(`SELECT id::int FROM transportes ORDER BY id`)).map(r => r.id);
await falla('no se repiten', () => admin(`INSERT INTO transportes (nombre) VALUES (' andreani ')`), /duplicate|unique/);
await falla('no se borran', () => admin(`DELETE FROM transportes`), /permission denied/);
t('todo el personal las ve', await cuantos(vend, 'transportes'), 2);

grupo('Al vender se elige la entrega');
const v0 = await vender(vend, T);
t('sin decir nada: se lo lleva en el momento', await ent(v0.id), { t: 'en_el_momento', e: null, f: null, tr: null, d: null, l: null, rn: null, rd: null, ep: null, s: null, lp: null });
await falla('envío sin dirección: no se registra la venta', () => vender(vend, T, { entrega: { tipo: 'envio', localidad: 'Rafaela' } }), /envio_incompleto/);
const vR = await vender(vend, T, { entrega: { tipo: 'retiro', fecha: '2030-01-15', notas: 'pasa el sábado' }, retira_nombre: 'María' });
t('retiro: pendiente, con fecha y nota', [(await ent(vR.id)).t, (await ent(vR.id)).e, (await ent(vR.id)).f], ['retiro', 'pendiente', '2030-01-15']);
const vE = await vender(vend, T, { entrega: { tipo: 'envio', transporte_id: AND, direccion: 'San Martín 123', localidad: 'Rafaela', destinatario: 'Juan', telefono: '3492', bultos: 2 } });
t('envío sin fecha: hoy, con su transporte', [(await ent(vE.id)).t, (await ent(vE.id)).f, (await ent(vE.id)).tr, (await ent(vE.id)).l], ['envio', hoy, AND, 'Rafaela']);

grupo('Lo que no está pagado no sale');
await falla('no se entrega una venta que espera cobro', () => stock(`SELECT venta_entregar(ARRAY[$1]::bigint[])`, [vR.id]), /sin_pagar/);
t('pero sí se puede preparar (marcar lista)', [(await stock(`SELECT venta_entrega_lista(ARRAY[$1]::bigint[]) r`, [vR.id]))[0].r.cambiadas, (await ent(vR.id)).e, (await ent(vR.id)).lp], [1, 'listo', 'Sergio Stock']);
await vend2(`SELECT caja_abrir(0)`);
await cobrar(vend2, vR.id, 10000); await cobrar(vend2, vE.id, 10000);
const cta = (await admin(`SELECT cc_cuenta_guardar('{"contacto":{"nombre":"Carla CC"}}'::jsonb) r`))[0].r.cuenta_id;
const vCC = await vender(vend, T, { medio_pago: 'cuenta_corriente', cc_cuenta_id: cta, entrega: { tipo: 'retiro' } });
t('cuenta corriente: sale sin pasar por caja', (await stock(`SELECT venta_entregar(ARRAY[$1]::bigint[]) r`, [vCC.id]))[0].r.entregadas, 1);

grupo('Entregar un retiro');
await falla('el vendedor sin permiso no entrega', async () => { await admin(`SELECT permisos_rol_guardar('vendedor', ARRAY['ventas.crear','caja.cobrar','entregas.ver'])`); await vend(`SELECT venta_entregar(ARRAY[$1]::bigint[])`, [vR.id]); }, /sin_permiso/);
await admin(`SELECT permisos_rol_guardar('vendedor', ARRAY['ventas.crear','caja.ver','caja.abrir_cerrar','caja.movimientos','caja.cobrar','entregas.ver','entregas.gestionar','ventas.anular_propias'])`);
const e1 = (await stock(`SELECT venta_entregar(ARRAY[$1]::bigint[], $2::jsonb) r`, [vR.id, JSON.stringify({ recibio_nombre: ' María López ', recibio_dni: '30.123.456' })]))[0].r;
t('queda entregada: quién retiró, su DNI y quién entregó', [e1.entregadas, (await ent(vR.id)).e, (await ent(vR.id)).rn, (await ent(vR.id)).rd, (await ent(vR.id)).ep], [1, 'entregado', 'María López', '30.123.456', 'Sergio Stock']);
t('entregar de nuevo no pisa nada', [(await stock(`SELECT venta_entregar(ARRAY[$1]::bigint[], '{"recibio_nombre":"Otro"}'::jsonb) r`, [vR.id]))[0].r.entregadas, (await ent(vR.id)).rn], [0, 'María López']);
await falla('ya salió: no se cambia la entrega', () => vend(`SELECT venta_entrega_guardar($1, '{"tipo":"envio","direccion":"x","localidad":"y"}'::jsonb)`, [vR.id]), /ya_entregada/);
await falla('deshacer exige motivo', () => stock(`SELECT venta_entrega_deshacer($1, '')`, [vR.id]), /motivo_requerido/);
await stock(`SELECT venta_entrega_deshacer($1, 'se marcó la equivocada')`, [vR.id]);
t('deshecha: vuelve a pendiente, sin quién retiró', [(await ent(vR.id)).e, (await ent(vR.id)).rn], ['pendiente', null]);
t('sin nombre: queda el de "retira" de la venta', [(await stock(`SELECT venta_entregar(ARRAY[$1]::bigint[]) r`, [vR.id]))[0].r.entregadas, (await ent(vR.id)).rn], [1, 'María']);

grupo('Despachar envíos');
const vE2 = await vender(vend, T, { entrega: { tipo: 'envio', transporte_id: '', bultos: '3 b', fecha: '', direccion: 'Belgrano 9', localidad: 'Esperanza' } });
t('campos vacíos del formulario no rompen', [(await q('SELECT transporte_id, envio_bultos::int b FROM ventas WHERE id = $1', [vE2.id]))[0].b], [3]);
await admin(`UPDATE ventas SET transporte_id = $2 WHERE id = $1`, [vE2.id, AND]);
await falla('todo o nada: si una no está pagada no sale ninguna', () => stock(`SELECT venta_entregar(ARRAY[$1, $2]::bigint[])`, [vE.id, vE2.id]), /sin_pagar/);
t('y la pagada sigue sin salir', (await ent(vE.id)).e, 'pendiente');
await cobrar(vend2, vE2.id, 10000);
const d = (await stock(`SELECT venta_entregar(ARRAY[$1, $2]::bigint[], $3::jsonb) r`, [vE.id, vE2.id, JSON.stringify({ seguimientos: { [vE.id]: 'AND-001' } })]))[0].r;
t('despacha las dos, con número de guía', [d.entregadas, (await ent(vE.id)).s, (await ent(vE2.id)).s, (await ent(vE.id)).rn], [2, 'AND-001', null, 'Juan']);

grupo('Corregir la entrega antes de que salga');
const vX = await vender(vend, T);
await vend(`SELECT venta_entrega_guardar($1, $2::jsonb)`, [vX.id, JSON.stringify({ tipo: 'envio', transporte_id: VIA, direccion: 'Rivadavia 1', localidad: 'Paraná' })]);
t('la vendedora la pasa a envío', [(await ent(vX.id)).t, (await ent(vX.id)).tr], ['envio', VIA]);
await falla('otra vendedora sin permiso de entregas no', async () => { await admin(`SELECT permisos_rol_guardar('vendedor', ARRAY['ventas.crear'])`); await vend2(`SELECT venta_entrega_guardar($1, '{"tipo":"retiro"}'::jsonb)`, [vX.id]); }, /sin_permiso/);
await vend(`SELECT venta_entrega_guardar($1, '{"tipo":"en_el_momento"}'::jsonb)`, [vX.id]);
t('volver a "se lo lleva" limpia los datos de envío', [(await ent(vX.id)).t, (await ent(vX.id)).e, (await ent(vX.id)).d], ['en_el_momento', null, null]);

grupo('Quién ve qué');
await admin(`SELECT permisos_rol_guardar('vendedor', ARRAY['ventas.crear','entregas.ver'])`);
t('con "ver retiros y envíos" se ven las de todas las vendedoras', (await vend2(`SELECT count(*)::int n FROM ventas WHERE entrega_tipo <> 'en_el_momento'`))[0].n, 4);   // retiro, envío, cuenta corriente y el segundo envío
t('pero no las ventas comunes de otras', (await vend2(`SELECT count(*)::int n FROM ventas WHERE entrega_tipo = 'en_el_momento' AND vendedor_id <> auth.uid()`))[0].n, 0);
await admin(`SELECT permisos_rol_guardar('encargado_stock', ARRAY['ventas.crear'])`);
t('sin el permiso no se ven', (await stock(`SELECT count(*)::int n FROM ventas WHERE entrega_tipo <> 'en_el_momento' AND vendedor_id <> auth.uid()`))[0].n, 0);
await falla('anónimo no ve transportes', () => anon(`SELECT * FROM transportes`), /permission denied/);

grupo('Anular');
const vA = await vender(admin, T, { entrega: { tipo: 'retiro' } });
await admin(`SELECT venta_anular($1, 'se arrepintió')`, [vA.id]);
await falla('una anulada no se entrega', () => admin(`SELECT venta_entregar(ARRAY[$1]::bigint[])`, [vA.id]), /venta_anulada/);

console.log(`\n${ok} pasadas, ${fail} fallidas\n`);
process.exit(fail ? 1 : 0);
