/**
 * Pruebas: verificación de pagos con el aviso del banco (sql/032-avisos-banco.sql)
 * contra un Postgres REAL en memoria (PGlite).
 *
 *   node scripts/test-avisos-banco-sql.mjs
 *
 * Comprobante + aviso del banco del mismo importe → pago confirmado solo.
 * Llega primero cualquiera de los dos. Tolerancia de $50. Sin aviso en 7 min →
 * alerta (panel + mail) y si el aviso llega después igual confirma. Mismo
 * archivo en otro pedido, hora anterior, avisos repetidos, Gmail, permisos.
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

for (const f of ['028-pedidos-web-en-circuito.sql', '029-rol-cajero.sql', '030-historial.sql', '031-fotos-sugeridas.sql']) {
  await db.exec(leerSQL(f));
}

grupo('Migración');
let err = null;
const SQL = leerSQL('032-avisos-banco.sql');
try { await db.exec(SQL); await db.exec(SQL); } catch (e) { err = e.message; }
t('032 corre limpio, dos veces seguidas', err, null);
if (err) { console.log(`\n${ok} pasadas, ${fail} fallidas\n`); process.exit(1); }

const TERMO = 2;
const CTA = (await q(`INSERT INTO cuentas_cobro (nombre, titular, alias, banco) VALUES ('MP Juan', 'Juan Pérez', 'mh.juan.mp', 'Mercado Pago') RETURNING id::int`))[0].id;
const CTA2 = (await q(`INSERT INTO cuentas_cobro (nombre, titular, alias, banco, activa) VALUES ('Galicia Ana', 'Ana Gómez', 'mh.ana.gal', 'Galicia', false) RETURNING id::int`))[0].id;
const token = async c => (await q(`SELECT token FROM cuentas_cobro_avisos WHERE cuenta_cobro_id = $1`, [c]))[0]?.token;
const TOK = await token(CTA), TOK2 = await token(CTA2);
await q(`UPDATE site_settings SET cobros_activos = true, cobros_auto_confirmar = false WHERE id = 1`);

grupo('Direcciones de avisos');
t('cada cuenta nueva recibe su dirección secreta', [typeof TOK, TOK?.length, typeof TOK2, TOK !== TOK2], ['string', 12, 'string', true]);
t('el vendedor no ve las direcciones', await cuantos(vend, 'cuentas_cobro_avisos'), 0);
t('el administrador sí', await cuantos(admin, 'cuentas_cobro_avisos'), 2);

let nPed = 0;
async function pedido(total = 24000) {
  nPed++;
  const [s] = await q(`INSERT INTO solicitudes (codigo, cliente_nombre, telefono, tipo_entrega, total_estimado)
     VALUES ($1, 'Laura Web', '3424000000', 'retiro', $2) RETURNING id::int`, [`MH-A${nPed}`, total]);
  await q(`INSERT INTO solicitud_items (solicitud_id, producto_id, nombre, cantidad, precio_unitario, subtotal) VALUES ($1, $2, 'Termo 1L', $3, 12000, $4)`,
          [s.id, TERMO, Math.round(total / 12000), total]);
  const h = (await q(`SELECT fn_cobros_habilitar($1, NULL, 'prueba') r`, [s.id]))[0].r;
  return { id: s.id, monto: Number(h.monto) };
}
let nComp = 0;
async function comprobante(solId, lectura) {
  nComp++;
  const [c] = await q(`INSERT INTO comprobantes (solicitud_id, archivo, mime) VALUES ($1, $2, 'image/jpeg') RETURNING id::int`, [solId, `x/${nComp}.jpg`]);
  const r = (await q(`SELECT comprobante_registrar_lectura($1, $2::jsonb) r`, [c.id, JSON.stringify(lectura)]))[0].r;
  return { id: c.id, r };
}
const ahora = () => new Date(Date.now() - 3 * 3600e3);   // hora de Argentina, a mano
const hoy = () => ahora().toISOString().slice(0, 10);
const hora = (min = 0) => new Date(ahora().getTime() + min * 60e3).toISOString().slice(11, 16);
const lec = (monto, extra = {}) => ({ legible: true, monto, fecha: hoy(), hora: hora(1), destino_alias: 'mh.juan.mp', confianza: 90, ...extra });
let nAv = 0;
const aviso = async (tok, d) => (await q(`SELECT aviso_registrar($1, $2::jsonb) r`, [tok, JSON.stringify({ message_id: `<m${++nAv}@banco>`, tipo: 'ingreso', ...d })]))[0].r;
const sol = async id => (await q(`SELECT estado, estado_pago, monto_pagado::float m FROM solicitudes WHERE id = $1`, [id]))[0];
const revisar = async () => (await q(`SELECT cobros_revisar() r`))[0].r;
const alertas = async id => (await q(`SELECT tipo, resuelta_en IS NOT NULL resuelta, mail_estado FROM cobros_alertas WHERE solicitud_id = $1 ORDER BY id`, [id]));
const atrasar = (compId, min) => q(`UPDATE comprobantes SET leido_en = now() - make_interval(mins => $2) WHERE id = $1`, [compId, min]);

grupo('Comprobante primero, aviso después');
const p1 = await pedido();
t('el pedido tiene centavos únicos en la cuenta activa', [p1.monto > 24000, p1.monto < 24001], [true, true]);
const c1 = await comprobante(p1.id, lec(p1.monto, { nro_operacion: '111' }));
t('el comprobante coincide pero espera el aviso', [c1.r.estado, c1.r.conciliacion.esperando_aviso, (await sol(p1.id)).estado_pago], ['coincide', true, 'en_revision']);
const a1 = await aviso(TOK, { monto: p1.monto, ordenante: 'LAURA WEB', nro_operacion: '111' });
t('llega el aviso del banco → pagado y confirmado solo', [a1.asignado, (await sol(p1.id)).estado_pago, (await sol(p1.id)).estado], [true, 'pagado', 'confirmado']);
t('el aviso queda usado y atado al comprobante', (await q(`SELECT estado, comprobante_id::int c FROM avisos_ingreso WHERE id = $1`, [a1.aviso_id]))[0], { estado: 'usado', c: c1.id });
t('hay un movimiento de cobro en la cuenta', (await q(`SELECT count(*)::int n FROM movimientos_cobro WHERE solicitud_id = $1 AND tipo = 'cobro' AND cuenta_cobro_id = $2`, [p1.id, CTA]))[0].n, 1);
t('la cuenta queda marcada con verificación activa', (await q(`SELECT primer_aviso_en IS NOT NULL x FROM cuentas_cobro_avisos WHERE cuenta_cobro_id = $1`, [CTA]))[0].x, true);

grupo('Aviso primero, comprobante después');
const p2 = await pedido(36000);
const a2 = await aviso(TOK, { monto: p2.monto });
t('el aviso encuentra su pedido por los centavos exactos', [a2.asignado, a2.solicitud_id, (await sol(p2.id)).estado_pago], [true, p2.id, 'pendiente']);
await comprobante(p2.id, lec(p2.monto));
t('al leerse el comprobante, se confirma solo', (await sol(p2.id)).estado_pago, 'pagado');

grupo('Tolerancia de $50');
const p3 = await pedido(48000);
const c3 = await comprobante(p3.id, lec(p3.monto - 2));
t('2 pesos menos: coincide, con la diferencia anotada', [c3.r.estado, /2,00 menos|2.00 menos/.test(c3.r.nota_interna || '')], ['coincide', true]);
await aviso(TOK, { monto: p3.monto - 2 });
t('con el aviso, se confirma por lo que entró de verdad', [(await sol(p3.id)).estado_pago, (await sol(p3.id)).m], ['pagado', Math.round((p3.monto - 2) * 100) / 100]);
const v3 = (await vend(`SELECT pedido_a_venta($1, '{}'::jsonb) r`, [p3.id]))[0].r;
t('y pasa al mostrador como venta pagada (antes fallaba por $1)', [v3.pagada_online, v3.estado], [true, 'cerrada']);
const p4 = await pedido(60000);
const c4 = await comprobante(p4.id, lec(p4.monto - 100));
t('100 pesos menos: no coincide', [c4.r.estado, /Monto leído/.test(c4.r.motivo)], ['no_coincide', true]);
await revisar();
t('y genera alerta para revisar ya', (await alertas(p4.id)).map(a => a.tipo), ['comprobante_no_valido']);

grupo('7 minutos sin aviso → alerta, y sigue esperando');
await q(`UPDATE cobros_avisos_config SET mail_alertas = 'dueno@mh.test' WHERE id = 1`);
const p5 = await pedido(72000);
const c5 = await comprobante(p5.id, lec(p5.monto));
let rv = await revisar();
t('a los 0 minutos no hay alerta', (await alertas(p5.id)).length, 0);
await atrasar(c5.id, 6);
await revisar();
t('a los 6 minutos tampoco', (await alertas(p5.id)).length, 0);
await atrasar(c5.id, 8);
rv = await revisar();
t('a los 8 minutos: alerta "no llegó el aviso"', (await alertas(p5.id)).map(a => a.tipo), ['sin_aviso']);
const m5 = rv.mails.find(m => m.titulo.includes('MH-A' + nPed));
t('y sale el mail al dueño con el enlace al pedido', [rv.para, !!m5, m5?.link.endsWith('ver=' + p5.id), /no llegó el aviso/.test(m5?.titulo)], ['dueno@mh.test', true, true, true]);
rv = await revisar();
t('no se manda dos veces mientras el Worker confirma', rv.mails.some(m => m.id === m5.id), false);
await q(`SELECT cobros_alertas_mail_resultado($1::bigint[], true)`, [[m5.id]]);
t('el Worker avisa que salió', (await alertas(p5.id))[0].mail_estado, 'enviado');
await vend(`SELECT cobros_alerta_vista($1)`, [m5.id]);
t('el panel la marca vista', (await q(`SELECT vista_en IS NOT NULL v FROM cobros_alertas WHERE id = $1`, [m5.id]))[0].v, true);
await aviso(TOK, { monto: p5.monto });
t('el aviso llega tarde → se confirma solo igual', (await sol(p5.id)).estado_pago, 'pagado');
t('y la alerta se cierra', (await alertas(p5.id)).map(a => a.resuelta), [true]);

grupo('El aviso no coincide con el comprobante');
const p6 = await pedido(84000);
await aviso(TOK, { monto: p6.monto - 30 });
const c6 = await comprobante(p6.id, lec(p6.monto));
t('no se confirma', (await sol(p6.id)).estado_pago, 'en_revision');
await atrasar(c6.id, 8); await revisar();
t('la alerta lo dice', (await q(`SELECT titulo FROM cobros_alertas WHERE solicitud_id = $1`, [p6.id]))[0].titulo.includes('no coincide con el comprobante'), true);

grupo('Trampas en el comprobante');
const p7 = await pedido(96000);
const c7a = await comprobante(p7.id, lec(p7.monto, { _sha256: 'abc123' }));
const p8 = await pedido(96000);
const c8 = await comprobante(p8.id, lec(p8.monto, { _sha256: 'ABC123' }));
t('el mismo archivo en otro pedido → no coincide', [c7a.r.estado, c8.r.estado, /mismo archivo/.test(c8.r.motivo)], ['coincide', 'no_coincide', true]);
const p9 = await pedido(108000);
const c9 = await comprobante(p9.id, lec(p9.monto, { hora: hora(-120) }));
t('hora 2 h anterior a habilitar el pago → no coincide', [c9.r.estado, /anteriores al pedido/.test(c9.r.motivo)], ['no_coincide', true]);
const p10 = await pedido(120000);
const c10 = await comprobante(p10.id, lec(p10.monto, { posible_edicion: true }));
t('señales de edición: queda anotado, espera el aviso', [c10.r.estado, /edición/.test(c10.r.nota_interna), (await sol(p10.id)).estado_pago], ['coincide', true, 'en_revision']);
const cli = (await q(`SELECT pedido_consultar($1, '3424000000') r`, ['MH-A' + nPed]))[0].r;
t('el cliente no ve la nota interna', JSON.stringify(cli.comprobantes).includes('edición'), false);
await q(`UPDATE site_settings SET cobros_auto_confirmar = true WHERE id = 1`);
const p11 = await pedido(132000);
await comprobante(p11.id, lec(p11.monto, { posible_edicion: true }));
t('ni con "confirmar solo con comprobante" prendido pasa uno con señales de edición', (await sol(p11.id)).estado_pago, 'en_revision');
await q(`UPDATE site_settings SET cobros_auto_confirmar = false WHERE id = 1`);

grupo('Avisos raros');
t('dirección desconocida → no entra', (await aviso('000000000000', { monto: 10 })).error, 'direccion_desconocida');
const dup = await q(`SELECT aviso_registrar($1, '{"message_id":"<m1@banco>","tipo":"ingreso","monto":5}'::jsonb) r`, [TOK]);
t('el mismo mail dos veces → se ignora', dup[0].r.repetido, true);
const r1 = await aviso(TOK, { monto: 5000.5, nro_operacion: 'ZZ9' });
const r2 = await aviso(TOK, { monto: 5000.5, nro_operacion: 'ZZ9' });
t('el mismo ingreso reenviado con otro mail → descartado', [r1.repetido, r2.repetido], [undefined, true]);
const g = await q(`SELECT aviso_registrar($1, '{"message_id":"<g1>","tipo":"confirmacion_gmail","gmail_codigo":"123456789","gmail_link":"https://mail.google.com/x"}'::jsonb) r`, [TOK2]);
t('confirmación de reenvío de Gmail → código guardado para el panel', (await q(`SELECT gmail_codigo FROM cuentas_cobro_avisos WHERE cuenta_cobro_id = $1`, [CTA2]))[0].gmail_codigo, '123456789');
t('un mail que no es un ingreso no cuenta como verificación', (await q(`SELECT primer_aviso_en IS NULL x FROM cuentas_cobro_avisos WHERE cuenta_cobro_id = $1`, [CTA2]))[0].x, true);
const pt = await pedido(160000);
const trucho = await aviso(TOK, { monto: pt.monto, remitente_banco: false, remitente: 'avisos@mercadopag0.com' });
t('mail de un remitente que no es un banco → no se usa solo', [trucho.asignado, (await sol(pt.id)).estado_pago], [false, 'pendiente']);
await comprobante(pt.id, lec(pt.monto));
t('ni aunque llegue un comprobante del mismo importe', (await sol(pt.id)).estado_pago, 'en_revision');
await revisar();
t('y la revisión tampoco lo empareja', (await q(`SELECT estado FROM avisos_ingreso WHERE id = $1`, [trucho.aviso_id]))[0].estado, 'sin_asignar');
const pa = await pedido(150000), pb = await pedido(150000);
const amb = await aviso(TOK, { monto: Math.min(pa.monto, pb.monto) - 10 });
t('dos pedidos posibles y ningún comprobante → queda suelto', [amb.asignado, amb.ambiguo], [false, true]);
await q(`UPDATE avisos_ingreso SET recibido_en = now() - interval '31 minutes' WHERE id = $1`, [amb.aviso_id]);
await revisar();
t('a los 30 min: alerta de plata sin pedido', (await q(`SELECT count(*)::int n FROM cobros_alertas WHERE aviso_id = $1 AND tipo = 'aviso_sin_pedido'`, [amb.aviso_id]))[0].n, 1);
await vend(`SELECT aviso_asignar($1, $2)`, [amb.aviso_id, pa.id]);
await comprobante(pa.id, lec(Math.min(pa.monto, pb.monto) - 10));
t('asignado a mano + comprobante del mismo importe → pagado', (await sol(pa.id)).estado_pago, 'pagado');
await revisar();
t('y la alerta de plata sin pedido se cierra', (await q(`SELECT resuelta_en IS NOT NULL x FROM cobros_alertas WHERE aviso_id = $1`, [amb.aviso_id]))[0].x, true);
const suelto = await aviso(TOK, { monto: 777 });
await falla('descartar pide motivo', () => vend(`SELECT aviso_descartar($1, '')`, [suelto.aviso_id]), /motivo_requerido/);
await vend(`SELECT aviso_descartar($1, 'Transferencia personal')`, [suelto.aviso_id]);
t('descartado con motivo', (await q(`SELECT estado FROM avisos_ingreso WHERE id = $1`, [suelto.aviso_id]))[0].estado, 'descartado');

grupo('Confirmación automática apagada');
await q(`UPDATE cobros_avisos_config SET auto_con_aviso = false WHERE id = 1`);
const p12 = await pedido(180000);
await aviso(TOK, { monto: p12.monto });
const c12 = await comprobante(p12.id, lec(p12.monto));
t('con todo coincidiendo, no confirma: lo hace una persona', [c12.r.conciliacion.manual, (await sol(p12.id)).estado_pago], [true, 'en_revision']);
await q(`UPDATE cobros_avisos_config SET auto_con_aviso = true WHERE id = 1`);

grupo('Permisos');
await falla('el público no puede inventar avisos', () => anon(`SELECT aviso_registrar($1, '{"monto":1}'::jsonb)`, [TOK]), /permission denied/);
await falla('el vendedor tampoco', () => vend(`SELECT aviso_registrar($1, '{"monto":1}'::jsonb)`, [TOK]), /permission denied/);
await falla('ni correr la revisión', () => vend(`SELECT cobros_revisar()`), /permission denied/);
await falla('ni marcar mails como enviados', () => vend(`SELECT cobros_alertas_mail_resultado(ARRAY[1]::bigint[], true)`), /permission denied/);
t('el vendedor ve avisos y alertas', [await cuantos(vend, 'avisos_ingreso') > 0, await cuantos(vend, 'cobros_alertas') > 0], [true, true]);
t('el encargado de stock no', [await cuantos(stock, 'avisos_ingreso'), await cuantos(stock, 'cobros_alertas')], [0, 0]);
for (const tb of ['avisos_ingreso', 'cobros_alertas', 'cobros_avisos_config', 'cuentas_cobro_avisos'])
  await falla(`el público ni consulta ${tb}`, () => cuantos(anon, tb), /permission denied/);
await falla('el vendedor no inserta avisos a mano', () => vend(`INSERT INTO avisos_ingreso (tipo) VALUES ('ingreso')`), /permission denied/);
await falla('el vendedor no cambia la tolerancia', async () => { const r = await vend(`UPDATE cobros_avisos_config SET tolerancia = 5000 WHERE id = 1`); if (!r.afectadas) throw new Error('permission denied (0 filas)'); }, /permission denied/);
await admin(`UPDATE cobros_avisos_config SET tolerancia = 30 WHERE id = 1`);
t('el administrador sí', (await q(`SELECT tolerancia::int t FROM cobros_avisos_config`))[0].t, 30);
await falla('el vendedor no regenera direcciones', () => vend(`SELECT cuenta_avisos_regenerar($1)`, [CTA]), /sin_permiso/);
const nuevo = (await admin(`SELECT cuenta_avisos_regenerar($1) t`, [CTA]))[0].t;
t('el administrador sí, y la vieja deja de andar', [nuevo !== TOK, (await aviso(TOK, { monto: 1 })).error], [true, 'direccion_desconocida']);

console.log(`\n${ok} pasadas, ${fail} fallidas\n`);
process.exit(fail ? 1 : 0);
