/* ============================================================
   Impresión desde el panel: ticket de venta (rollo de 80 mm) y
   etiquetas con código de barras (rollo 50×30 mm u hoja A4 de 24).

   Se imprime desde un iframe oculto: no abre pestañas, no lo frena
   el bloqueador de ventanas emergentes y funciona en la app instalada.
   Los códigos se dibujan con JsBarcode (CDN); si no carga, la etiqueta
   sale igual con el código escrito en texto.
   ============================================================ */
const MHImprimir = (() => {
  const JSBARCODE = 'https://cdn.jsdelivr.net/npm/jsbarcode@3.11.6/dist/JsBarcode.all.min.js';
  const esc = v => String(v ?? '').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');
  const money = n => new Intl.NumberFormat('es-AR', { style:'currency', currency:'ARS', minimumFractionDigits:0, maximumFractionDigits:2 }).format(Number(n || 0));
  const MEDIOS = { efectivo:'Efectivo', transferencia:'Transferencia', debito:'Débito', credito:'Crédito', mercadopago:'Mercado Pago', cuenta_corriente:'Cuenta corriente', otro:'Otro' };

  // Fecha y hora de Argentina con segundos: 11/11/2026 13:23:46
  const fechaHora = d => {
    const x = d ? new Date(d) : new Date();
    const o = { timeZone: 'America/Argentina/Buenos_Aires' };
    return x.toLocaleDateString('es-AR', { ...o, day:'2-digit', month:'2-digit', year:'numeric' }) + ' ' +
           x.toLocaleTimeString('es-AR', { ...o, hour:'2-digit', minute:'2-digit', second:'2-digit', hour12:false });
  };
  const fechaCorta = iso => { const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(iso || ''); return m ? `${m[3]}/${m[2]}/${m[1]}` : ''; };
  const cuitFmt = c => { const d = String(c || '').replace(/\D/g, ''); return d.length === 11 ? `${d.slice(0,2)}-${d.slice(2,10)}-${d.slice(10)}` : String(c || ''); };
  const IVA = { responsable_inscripto:'IVA Responsable Inscripto', monotributo:'Responsable Monotributo', exento:'IVA Exento' };
  const LOGO = '/images/marca/logo-mundo-hogar.png';

  let tienda = null;
  async function datosTienda() {
    if (tienda) return tienda;
    const base = 'nombre_tienda,direccion,telefono,whatsapp,horarios';
    try {
      let r = await db.from('site_settings')
        .select(base + ',cuit,domicilio_fiscal,ingresos_brutos,inicio_actividades,condicion_iva,ticket_pie').eq('id', 1).maybeSingle();
      if (r.error) r = await db.from('site_settings').select(base).eq('id', 1).maybeSingle();   // falta sql/017
      tienda = r.data || {};
    } catch (e) { tienda = {}; }
    return tienda;
  }

  /* Manda un documento HTML completo a imprimir. `html` ya trae su <style>. */
  function imprimirHTML(html) {
    document.getElementById('_mh_print')?.remove();
    const f = document.createElement('iframe');
    f.id = '_mh_print'; f.setAttribute('aria-hidden', 'true'); f.title = 'Impresión';
    f.style.cssText = 'position:fixed;right:0;bottom:0;width:0;height:0;border:0;visibility:hidden';
    document.body.appendChild(f);
    const d = f.contentDocument;
    d.open(); d.write(html); d.close();
    // El documento avisa cuando está listo (logo cargado, códigos dibujados) y recién ahí se imprime.
    // Si nunca avisa (CDN caído), igual se imprime a los 2,5 s.
    let hecho = false;
    const go = () => { if (hecho) return; hecho = true; try { f.contentWindow.focus(); f.contentWindow.print(); } catch (e) { console.error('[imprimir]', e); } };
    f.contentWindow.__mhListo = go;
    setTimeout(go, 2500);
    try { f.contentWindow.addEventListener('afterprint', () => setTimeout(() => f.remove(), 500)); } catch (e) {}
    setTimeout(() => f.remove(), 120000);
  }

  /* ── Comprobantes de 80 mm: estilo y encabezado comunes ── */
  const ESTILO_80 = `
  @page { size: 80mm auto; margin: 3mm 4mm; }
  * { box-sizing: border-box; }
  body { margin: 0; color: #000; background: #fff; font: 12px/1.35 "Courier New", Courier, monospace; width: 72mm; }
  .logo { display: block; margin: 0 auto 2px; width: 26mm; height: auto; filter: grayscale(1) contrast(1.15); }
  h1 { font-size: 17px; margin: 0; text-align: center; letter-spacing: .03em; text-transform: uppercase; }
  .tipo { text-align: center; font-weight: bold; font-size: 13px; margin: 2px 0; letter-spacing: .05em; }
  .c { text-align: center; } .m { color: #222; font-size: 11px; }
  .fis { text-align: center; font-size: 11px; line-height: 1.3; }
  .sep { border-top: 1px dashed #000; margin: 6px 0; }
  table { width: 100%; border-collapse: collapse; } td { padding: 1px 0; vertical-align: top; }
  .r { text-align: right; white-space: nowrap; } .d { padding-left: 8px; color: #222; }
  .tot td { font-size: 15px; font-weight: bold; padding-top: 3px; }
  .dato b { font-weight: bold; }
  .marca { border: 2px solid #000; padding: 4px; text-align: center; font-weight: bold; font-size: 15px; margin: 6px 0; }
  .firma { margin-top: 26px; border-top: 1px solid #000; text-align: center; font-size: 11px; padding-top: 2px; }`;

  function encabezado(t, tipo) {
    const fis = [
      t.cuit ? `CUIT: ${esc(cuitFmt(t.cuit))}` : '',
      esc(t.domicilio_fiscal || t.direccion || ''),
      t.ingresos_brutos ? `Ing. Brutos: ${esc(t.ingresos_brutos)}` : '',
      t.inicio_actividades ? `Inicio de actividades: ${esc(fechaCorta(t.inicio_actividades))}` : '',
      esc(IVA[t.condicion_iva] || ''),
    ].filter(Boolean);
    return `<img class="logo" src="${esc(t._origen || '')}${LOGO}" alt="">
  <h1>${esc(t.nombre_tienda || 'Mundo Hogar')}</h1>
  <div class="fis">${fis.join('<br>')}</div>
  <div class="sep"></div>
  <div class="tipo">${esc(tipo)}</div>`;
  }

  // Se imprime cuando cargó el logo (o falló): así no sale el ticket sin logo
  const SCRIPT_LISTO = `<script>
  (function () {
    var img = document.querySelector('img.logo'), ok = function () { window.__mhListo && window.__mhListo(); };
    if (!img || img.complete) return ok();
    img.onload = ok; img.onerror = function () { img.remove(); ok(); };
  })();
</script>`;

  /* ── Ticket de compra (HTML puro, sin imprimir) ──
     Acepta tanto lo que devuelve venta_registrar (items) como una fila
     de `ventas` con venta_items. No es factura: lo dice al pie. */
  function htmlTicket(v, t = {}) {
    // Renglones que quedaron en 0 (se quitaron después de la venta, sql/020) no se imprimen
    const items = (v.items || v.venta_items || []).filter(i => Number(i.cantidad) > 0)
      .sort((a, b) => (a.orden ?? 0) - (b.orden ?? 0));
    const vendedor = v.vendedor_nombre || v.vendedor || '';
    const retira = (v.retira_nombre || '').trim();
    const cc = v.cuenta_corriente || null;   // solo al imprimir recién vendida (trae los saldos)
    const filas = items.map(i => {
      const cant = Number(i.cantidad || 0), pu = Number(i.precio_unitario ?? (cant ? Number(i.subtotal || 0) / cant : 0));
      return `<tr><td colspan="2">${esc(i.nombre)}</td></tr>
        <tr><td class="d">${cant} × ${money(pu)}</td><td class="r">${money(i.subtotal ?? cant * pu)}</td></tr>`;
    }).join('');
    return `<!DOCTYPE html><html lang="es"><head><meta charset="utf-8"><title>Ticket ${esc(v.codigo || '')}</title>
<style>${ESTILO_80}</style></head><body>
  ${encabezado(t, 'TICKET DE COMPRA')}
  <div class="dato">Fecha: ${esc(fechaHora(v.fecha))}</div>
  ${v.codigo ? `<div class="dato">N°: ${esc(v.codigo)}</div>` : ''}
  <div class="dato">Cliente: <b>${esc(v.cliente_nombre || 'Consumidor final')}</b></div>
  ${retira ? `<div class="dato">Retira: <b>${esc(retira)}</b></div>` : ''}
  ${vendedor ? `<div class="m">Atendió: ${esc(vendedor)}</div>` : ''}
  ${v.estado === 'anulada' ? '<div class="marca">VENTA ANULADA</div>' : ''}
  ${v.estado !== 'anulada' && Number(v.ediciones) > 0 ? `<div class="m">Corregida el ${esc(fechaHora(v.editada_en))}: se quitaron productos</div>` : ''}
  <div class="sep"></div>
  <table>${filas}</table>
  <div class="sep"></div>
  <table>
    ${Number(v.descuento) > 0 ? `<tr><td>Subtotal</td><td class="r">${money(v.subtotal)}</td></tr><tr><td>Descuento</td><td class="r">−${money(v.descuento)}</td></tr>` : ''}
    <tr class="tot"><td>TOTAL</td><td class="r">${money(v.total)}</td></tr>
    <tr><td>Pago</td><td class="r">${esc(MEDIOS[v.medio_pago] || v.medio_pago || '')}</td></tr>
    ${v.cuenta_cobro ? `<tr><td class="m" colspan="2">Transferido a: ${esc(v.cuenta_cobro.alias || v.cuenta_cobro.cvu || '')} (${esc(v.cuenta_cobro.titular || '')})</td></tr>` : ''}
    ${v.nro_operacion ? `<tr><td class="m" colspan="2">N° de operación: ${esc(v.nro_operacion)}</td></tr>` : ''}
    ${Number(v.recargo_total) > 0 ? `<tr><td class="m" colspan="2">Incluye recargo cuenta corriente: ${money(v.recargo_total)}</td></tr>` : ''}
  </table>
  ${cc ? `<div class="sep"></div><table>
    <tr><td>Saldo anterior</td><td class="r">${money(cc.saldo_anterior)}</td></tr>
    <tr><td>Esta compra</td><td class="r">+${money(v.total)}</td></tr>
    <tr class="tot"><td>SALDO</td><td class="r">${money(cc.saldo_actual)}</td></tr>
    ${cc.proximo_vencimiento ? `<tr><td colspan="2" class="m">Próximo vencimiento: ${esc(fechaCorta(cc.proximo_vencimiento))}${Number(cc.a_pagar_proximo) > 0 ? ` · a pagar ${money(cc.a_pagar_proximo)}` : ''}</td></tr>` : ''}
  </table>
  <div class="firma">Firma del cliente</div>` : ''}
  <div class="sep"></div>
  <div class="c">¡Gracias por tu compra!</div>
  ${t.ticket_pie ? `<div class="c m">${esc(t.ticket_pie)}</div>` : ''}
  ${t.horarios ? `<div class="c m">${esc(t.horarios)}</div>` : ''}
  <div class="c m" style="margin-top:6px">Comprobante interno · no válido como factura</div>
  ${SCRIPT_LISTO}
</body></html>`;
  }

  /* ── Recibo de pago (HTML puro) ──
     r: { numero, fecha, cliente_nombre, cliente_doc, concepto, monto, medio_pago,
          saldo_anterior, saldo_actual, usuario, anulado }
     El saldo se muestra solo si viene (pagos de cuenta corriente). */
  function htmlRecibo(r, t = {}) {
    const conSaldo = r.saldo_anterior != null && r.saldo_actual != null;
    return `<!DOCTYPE html><html lang="es"><head><meta charset="utf-8"><title>Recibo ${esc(r.numero || '')}</title>
<style>${ESTILO_80}</style></head><body>
  ${encabezado(t, 'RECIBO')}
  <div class="dato">Fecha: ${esc(fechaHora(r.fecha))}</div>
  ${r.numero ? `<div class="dato">N°: ${esc(r.numero)}</div>` : ''}
  <div class="dato">Recibimos de: <b>${esc(r.cliente_nombre || '')}</b></div>
  ${r.cliente_doc ? `<div class="m">DNI/CUIT: ${esc(r.cliente_doc)}</div>` : ''}
  ${r.anulado ? '<div class="marca">RECIBO ANULADO</div>' : ''}
  <div class="sep"></div>
  <div>${esc(r.concepto || 'Pago a cuenta')}</div>
  <table>
    <tr class="tot"><td>IMPORTE</td><td class="r">${money(r.monto)}</td></tr>
    <tr><td>Forma de pago</td><td class="r">${esc(MEDIOS[r.medio_pago] || r.medio_pago || '')}</td></tr>
  </table>
  ${conSaldo ? `<div class="sep"></div><table>
    <tr><td>Saldo anterior</td><td class="r">${money(r.saldo_anterior)}</td></tr>
    <tr><td>Este pago</td><td class="r">−${money(r.monto)}</td></tr>
    <tr class="tot"><td>SALDO ACTUAL</td><td class="r">${money(r.saldo_actual)}</td></tr>
  </table>` : ''}
  ${r.usuario ? `<div class="m" style="margin-top:4px">Recibió: ${esc(r.usuario)}</div>` : ''}
  <div class="firma">Firma y aclaración</div>
  <div class="c m" style="margin-top:6px">Comprobante interno · no válido como factura</div>
  ${SCRIPT_LISTO}
</body></html>`;
  }

  /* ── Cierre de caja (HTML puro) ──
     res: lo que devuelve caja_resumen(id); movs: sus caja_movimientos. */
  function htmlCierreCaja(res, movs = [], t = {}) {
    const s = res.sesion || {}, ef = res.efectivo || {};
    const MED = { ...MEDIOS };
    const dif = Number(s.diferencia || 0);
    const manuales = movs.filter(m => !m.venta_id && m.origen !== 'cierre');
    const otros = (res.por_medio || []).filter(m => m.medio !== 'efectivo');
    const fila = (a, b, cls = '') => `<tr class="${cls}"><td>${a}</td><td class="r">${b}</td></tr>`;
    return `<!DOCTYPE html><html lang="es"><head><meta charset="utf-8"><title>Cierre de caja</title>
<style>${ESTILO_80}</style></head><body>
  ${encabezado(t, 'CIERRE DE CAJA')}
  <div class="dato">Apertura: ${esc(fechaHora(s.abierta_en))}</div>
  <div class="m">Abrió: ${esc(s.abierta_por_nombre || '')}</div>
  <div class="dato">Cierre: ${esc(s.cerrada_en ? fechaHora(s.cerrada_en) : '— (abierta)')}</div>
  ${s.cerrada_por_nombre ? `<div class="m">Cerró: ${esc(s.cerrada_por_nombre)}</div>` : ''}
  <div class="sep"></div>
  <div class="tipo">EFECTIVO</div>
  <table>
    ${fila('Inicial', money(ef.inicial))}
    ${fila('Ingresos', '+' + money(ef.ingresos))}
    ${fila('Egresos', '−' + money(ef.egresos))}
    ${fila('Esperado', money(ef.esperado), 'tot')}
    ${s.efectivo_contado != null ? fila('Contado', money(s.efectivo_contado), 'tot') : ''}
    ${s.efectivo_contado != null ? fila('Diferencia', dif === 0 ? 'coincide' : (dif > 0 ? '+' : '−') + money(Math.abs(dif))) : ''}
    ${s.retiro != null ? fila('Retiro', money(s.retiro)) : ''}
    ${s.fondo_siguiente != null ? fila('Fondo que queda', money(s.fondo_siguiente)) : ''}
  </table>
  ${s.notas_cierre ? `<div class="m">Nota: ${esc(s.notas_cierre)}</div>` : ''}
  ${otros.length ? `<div class="sep"></div><div class="tipo">OTROS MEDIOS</div><table>
    ${otros.map(m => fila(esc(MED[m.medio] || m.medio), money(m.neto))).join('')}</table>` : ''}
  <div class="sep"></div>
  <table>${fila(`Ventas (${Number(res.ventas?.cantidad || 0)})`, money(res.ventas?.total))}</table>
  ${manuales.length ? `<div class="sep"></div><div class="tipo">INGRESOS Y EGRESOS</div><table>
    ${manuales.map(m => `<tr><td colspan="2">${esc(m.concepto_nombre)}${m.descripcion ? ' · ' + esc(m.descripcion) : ''}${m.anulado ? ' (anulado)' : ''}</td></tr>
      <tr><td class="d">${esc(MED[m.medio_pago] || m.medio_pago)}</td><td class="r">${m.tipo === 'ingreso' ? '+' : '−'}${money(m.monto)}</td></tr>`).join('')}
  </table>` : ''}
  <div class="firma">Firma</div>
  ${SCRIPT_LISTO}
</body></html>`;
  }

  async function cierreCaja(res, movs) {
    if (!res) return;
    const t = { ...(await datosTienda()), _origen: location.origin };
    imprimirHTML(htmlCierreCaja(res, movs, t));
  }

  async function ticket(v) {
    if (!v) return;
    const t = { ...(await datosTienda()), _origen: location.origin };
    imprimirHTML(htmlTicket(v, t));
  }

  async function recibo(r) {
    if (!r) return;
    const t = { ...(await datosTienda()), _origen: location.origin };
    imprimirHTML(htmlRecibo(r, t));
  }

  /* ── Etiquetas ──
     items: [{ id, nombre, sku, codigo_barras, precio, cantidad }]
     El código impreso es el de barras si lo tiene; si no, el SKU (la caja
     lo reconoce igual al escanearlo). Siempre CODE128: lo lee cualquier
     lector y acepta tanto números como "MH-00123". */
  const FORMATOS = {
    rollo: { nombre: 'Rollo 50 × 30 mm (impresora de etiquetas)', css: `
      @page { size: 50mm 30mm; margin: 0; }
      .et { width: 50mm; height: 30mm; padding: 1.5mm 2mm; page-break-after: always; }
      .et:last-child { page-break-after: auto; }` },
    hoja: { nombre: 'Hoja A4 · 24 etiquetas de 70 × 37 mm (3 × 8)', css: `
      @page { size: A4 portrait; margin: 0; }
      body { width: 210mm; display: flex; flex-wrap: wrap; align-content: flex-start; }
      .et { width: 70mm; height: 37mm; padding: 2.5mm 3mm; }` }
  };
  function valorCodigo(p) {
    const bar = String(p.codigo_barras || '').trim();
    if (bar) return { valor: bar, esSku: false };
    const sku = String(p.sku || '').trim();
    if (sku) return { valor: sku, esSku: true };
    return null;
  }
  function etiquetas(items, op = {}) {
    const formato = FORMATOS[op.formato] ? op.formato : 'rollo';
    const conPrecio = op.precio !== false;
    const lista = [];
    items.forEach(p => { for (let k = 0; k < Math.max(0, Math.min(500, Number(p.cantidad) || 0)); k++) lista.push(p); });
    if (!lista.length) return false;
    const html = `<!DOCTYPE html><html lang="es"><head><meta charset="utf-8"><title>Etiquetas</title>
<style>
  * { box-sizing: border-box; } body { margin: 0; color: #000; background: #fff; font-family: Arial, Helvetica, sans-serif; }
  .et { display: flex; flex-direction: column; justify-content: space-between; overflow: hidden; }
  .n { font-size: 9pt; line-height: 1.15; font-weight: 600; max-height: 2.3em; overflow: hidden; }
  .p { font-size: 13pt; font-weight: 700; line-height: 1; margin: 1mm 0; }
  .b { text-align: center; } .b svg { max-width: 100%; height: auto; display: block; margin: 0 auto; }
  .t { font-size: 8pt; text-align: center; letter-spacing: .04em; font-family: "Courier New", monospace; }
  .s { font-size: 7pt; color: #333; text-align: center; }
  ${FORMATOS[formato].css}
</style></head><body>
${lista.map(p => { const c = valorCodigo(p); return `<div class="et">
  <div class="n">${esc(p.nombre)}</div>
  ${conPrecio && Number(p.precio) > 0 ? `<div class="p">${money(p.precio)}</div>` : ''}
  <div class="b">${c ? `<svg class="bc" data-v="${esc(c.valor)}"></svg><div class="t">${esc(c.valor)}</div>` : '<div class="s">sin código: cargá SKU o código de barras</div>'}</div>
  ${c && !c.esSku && p.sku ? `<div class="s">${esc(p.sku)}</div>` : ''}
</div>`; }).join('')}
<script>
  function listo() { window.__mhListo && window.__mhListo(); }
  function dibujar() {
    try {
      document.querySelectorAll('svg.bc').forEach(el => {
        try { JsBarcode(el, el.dataset.v, { format: 'CODE128', displayValue: false, height: ${formato === 'rollo' ? 34 : 40}, width: 1.4, margin: 0 }); }
        catch (e) { el.outerHTML = '<div class="s">código no imprimible</div>'; }
      });
    } catch (e) {}
    listo();
  }
  var s = document.createElement('script'); s.src = '${JSBARCODE}'; s.onload = dibujar;
  s.onerror = function () { document.querySelectorAll('svg.bc').forEach(el => el.remove()); listo(); };
  document.head.appendChild(s);
</script>
</body></html>`;
    imprimirHTML(html);
    return true;
  }

  /* Pregunta cuántas de cada una y en qué formato, y después imprime. */
  function pedirEtiquetas(items) {
    items = (items || []).filter(Boolean);
    if (!items.length) { Utils.toast('No hay productos para etiquetar', 'warning'); return; }
    const pref = (() => { try { return JSON.parse(localStorage.getItem('mh_etiquetas') || '{}'); } catch (e) { return {}; } })();
    const bd = document.createElement('div'); bd.className = 'modal-backdrop';
    bd.innerHTML = `<div class="modal modal-lg">
      <div class="modal-header"><h3 class="modal-title">🏷️ Imprimir etiquetas</h3><button class="modal-close" id="_x" aria-label="Cerrar">×</button></div>
      <div class="modal-body">
        <div class="form-grid form-grid-2" style="margin-bottom:12px">
          <div class="form-group"><label>Formato</label><select id="_fmt">${Object.entries(FORMATOS).map(([k, f]) => `<option value="${k}"${(pref.formato || 'rollo') === k ? ' selected' : ''}>${esc(f.nombre)}</option>`).join('')}</select></div>
          <label class="toggle-wrap" style="align-self:end"><div class="toggle"><input type="checkbox" id="_precio"${pref.precio === false ? '' : ' checked'}><div class="toggle-track"></div><div class="toggle-thumb"></div></div><span class="toggle-label">Imprimir el precio</span></label>
        </div>
        <div class="table-wrap"><table>
          <thead><tr><th>Producto</th><th>Código que se imprime</th><th style="width:110px;text-align:right">Cantidad</th></tr></thead>
          <tbody>${items.map((p, i) => { const c = valorCodigo(p); return `<tr>
            <td><div style="font-weight:500">${esc(p.nombre)}</div>${Number(p.precio) > 0 ? `<div style="font-size:11.5px;color:var(--muted)">${money(p.precio)}</div>` : '<div style="font-size:11.5px;color:var(--warning)">sin precio</div>'}</td>
            <td style="font-family:monospace;font-size:12px">${c ? esc(c.valor) + (c.esSku ? ' <span class="badge badge-muted">SKU</span>' : '') : '<span class="badge badge-danger">sin código</span>'}</td>
            <td style="text-align:right"><input type="number" class="_cant" data-i="${i}" inputmode="numeric" min="0" max="500" value="${Math.max(1, Math.min(500, Number(p.cantidad) || 1))}" style="width:90px;text-align:right"></td>
          </tr>`; }).join('')}</tbody>
        </table></div>
        <div class="form-hint" style="margin-top:8px">Al imprimir, elegí la impresora de etiquetas (rollo) o la común (hoja) y desactivá "ajustar a la página". La caja reconoce tanto el código de barras como el SKU al escanear.</div>
      </div>
      <div class="modal-footer"><button class="btn btn-outline" id="_no">Cancelar</button><button class="btn btn-primary" id="_ok">🖨️ Imprimir</button></div></div>`;
    document.body.appendChild(bd);
    const cerrar = () => bd.remove();
    bd.querySelector('#_x').onclick = bd.querySelector('#_no').onclick = cerrar;
    const total = () => [...bd.querySelectorAll('._cant')].reduce((s, i) => s + (Math.max(0, parseInt(i.value, 10) || 0)), 0);
    const pintar = () => { const n = total(); bd.querySelector('#_ok').textContent = `🖨️ Imprimir ${n} etiqueta${n !== 1 ? 's' : ''}`; };
    bd.addEventListener('input', pintar); pintar();
    bd.querySelector('#_ok').addEventListener('click', () => {
      const formato = bd.querySelector('#_fmt').value, precio = bd.querySelector('#_precio').checked;
      try { localStorage.setItem('mh_etiquetas', JSON.stringify({ formato, precio })); } catch (e) {}
      const lista = items.map((p, i) => ({ ...p, cantidad: Math.max(0, parseInt(bd.querySelector(`._cant[data-i="${i}"]`).value, 10) || 0) })).filter(p => p.cantidad > 0);
      if (!etiquetas(lista, { formato, precio })) { Utils.toast('Poné al menos una cantidad', 'warning'); return; }
      cerrar();
    });
  }

  // Después de editar los datos del negocio: la próxima impresión los vuelve a leer
  const refrescar = () => { tienda = null; };

  return { ticket, recibo, cierreCaja, refrescar, etiquetas, pedirEtiquetas, _html: { ticket: htmlTicket, recibo: htmlRecibo, cierreCaja: htmlCierreCaja, cuitFmt, fechaHora } };
})();
window.MHImprimir = MHImprimir;
