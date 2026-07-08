// Utilidades generales del panel admin
const Utils = {

  /* ── Toasts ─────────────────────────────────────── */
  toast(msg, type = 'success', ms = 3600) {
    const icons = { success:'✅', error:'❌', warning:'⚠️', info:'ℹ️' };
    const el = document.createElement('div');
    el.className = `toast toast-${type}`;
    el.innerHTML = `<span class="toast-icon">${icons[type]||'ℹ️'}</span>
                    <span class="toast-msg">${msg}</span>`;
    document.getElementById('toast-container').appendChild(el);
    setTimeout(() => {
      el.style.cssText = 'opacity:0;transform:translateX(18px);transition:.3s';
      setTimeout(() => el.remove(), 310);
    }, ms);
  },

  /* ── Formatters ─────────────────────────────────── */
  currency(n) {
    if (n == null || n === '') return '—';
    return new Intl.NumberFormat('es-AR', {
      style:'currency', currency:'ARS', maximumFractionDigits:0
    }).format(Number(n));
  },

  number(n) {
    if (n == null) return '—';
    return new Intl.NumberFormat('es-AR').format(Number(n));
  },

  date(d) {
    if (!d) return '—';
    return new Date(d).toLocaleDateString('es-AR', { day:'2-digit', month:'2-digit', year:'numeric' });
  },

  datetime(d) {
    if (!d) return '—';
    return new Date(d).toLocaleString('es-AR', {
      day:'2-digit', month:'2-digit', year:'numeric', hour:'2-digit', minute:'2-digit'
    });
  },

  timeAgo(d) {
    if (!d) return '—';
    const diff = Date.now() - new Date(d).getTime();
    const m = Math.floor(diff/60000);
    if (m < 1)   return 'Hace un momento';
    if (m < 60)  return `Hace ${m} min`;
    const h = Math.floor(m/60);
    if (h < 24)  return `Hace ${h}h`;
    const days = Math.floor(h/24);
    if (days < 7) return `Hace ${days}d`;
    return this.date(d);
  },

  /* ── Badges ─────────────────────────────────────── */
  estadoBadge(estado) {
    const map = { activo:{cls:'badge-success',txt:'Activo'}, inactivo:{cls:'badge-muted',txt:'Inactivo'}, archivado:{cls:'badge-danger',txt:'Archivado'} };
    const x = map[estado] || {cls:'badge-muted', txt:estado};
    return `<span class="badge ${x.cls}">${x.txt}</span>`;
  },

  stockClass(qty, min = 0) {
    if (qty <= 0)          return 'stock-zero';
    if (qty <= min||qty<=2) return 'stock-low';
    return 'stock-ok';
  },

  tipoMovBadge(tipo) {
    const m = {
      carga_inicial:      {txt:'Carga Inicial',   cls:'badge-info'},
      entrada_compra:     {txt:'Entrada Compra',  cls:'badge-success'},
      salida_venta:       {txt:'Salida Venta',    cls:'badge-danger'},
      ajuste_positivo:    {txt:'Ajuste +',        cls:'badge-success'},
      ajuste_negativo:    {txt:'Ajuste −',        cls:'badge-warning'},
      devolucion_cliente: {txt:'Dev. Cliente',    cls:'badge-info'},
      devolucion_proveedor:{txt:'Dev. Proveedor', cls:'badge-warning'},
      producto_danado:    {txt:'Dañado',          cls:'badge-danger'},
      perdida:            {txt:'Pérdida',         cls:'badge-danger'},
      transferencia:      {txt:'Transferencia',   cls:'badge-muted'},
      correccion:         {txt:'Corrección',      cls:'badge-muted'},
    };
    const x = m[tipo]||{txt:tipo, cls:'badge-muted'};
    return `<span class="badge ${x.cls}">${x.txt}</span>`;
  },

  rolBadge(rol) {
    const m = {
      administrador:  {txt:'Administrador',      cls:'badge rol-admin'},
      encargado_stock:{txt:'Encargado de Stock', cls:'badge rol-stock'},
      vendedor:       {txt:'Vendedor',           cls:'badge rol-vendedor'}
    };
    const x = m[rol]||{txt:rol, cls:'badge badge-muted'};
    return `<span class="${x.cls}">${x.txt}</span>`;
  },

  /* ── Confirmación ─────────────────────────────── */
  confirm(msg, title = 'Confirmar acción', confirmLabel = 'Confirmar', danger = true) {
    return new Promise(resolve => {
      const bd = document.createElement('div');
      bd.className = 'modal-backdrop';
      bd.innerHTML = `<div class="modal" style="max-width:370px">
        <div class="modal-header"><h3 class="modal-title">${title}</h3></div>
        <div class="modal-body"><p style="color:var(--muted)">${msg}</p></div>
        <div class="modal-footer">
          <button class="btn btn-outline" id="_cno">Cancelar</button>
          <button class="btn ${danger?'btn-danger':'btn-primary'}" id="_cyes">${confirmLabel}</button>
        </div></div>`;
      document.body.appendChild(bd);
      bd.querySelector('#_cyes').onclick = () => { bd.remove(); resolve(true); };
      bd.querySelector('#_cno').onclick  = () => { bd.remove(); resolve(false); };
    });
  },

  /* ── Slug ────────────────────────────────────── */
  slug(str) {
    return (str||'').toLowerCase()
      .normalize('NFD').replace(/[̀-ͯ]/g,'')
      .replace(/[^a-z0-9\s-]/g,'').trim()
      .replace(/\s+/g,'-').replace(/-+/g,'-');
  },

  /* ── CSV Export ─────────────────────────────── */
  exportCSV(rows, filename) {
    if (!rows.length) return;
    const headers = Object.keys(rows[0]);
    const lines = rows.map(r =>
      headers.map(h => `"${(r[h]??'').toString().replace(/"/g,'""')}"`).join(',')
    );
    const csv = '﻿' + [headers.join(','), ...lines].join('\n');
    const a = Object.assign(document.createElement('a'), {
      href: URL.createObjectURL(new Blob([csv],{type:'text/csv;charset=utf-8'})),
      download: filename
    });
    a.click(); URL.revokeObjectURL(a.href);
  },

  /* ── Loading overlay ───────────────────────── */
  showLoading(msg = 'Cargando...') {
    let el = document.getElementById('_loading');
    if (!el) {
      el = document.createElement('div');
      el.id = '_loading';
      el.className = 'loading-overlay';
      el.innerHTML = `<div style="text-align:center">
        <div class="spinner spinner-lg" style="margin:0 auto 12px"></div>
        <p style="color:var(--muted)">${msg}</p></div>`;
      document.body.appendChild(el);
    }
  },
  hideLoading() { document.getElementById('_loading')?.remove(); },

  /* ── Audit log ─────────────────────────────── */
  async log(accion, entidad, id, desc, antes=null, despues=null) {
    try {
      await db.from('historial_actividad').insert({
        accion, entidad, entidad_id: String(id), descripcion: desc,
        valores_anteriores: antes, valores_nuevos: despues
      });
    } catch(_) { /* no crítico */ }
  },

  /* ── Generar SKU ───────────────────────────── */
  generateSKU(categoria, nombre) {
    const cat = (categoria||'XX').slice(0,3).toUpperCase().replace(/[^A-Z]/g,'');
    const nom = this.slug(nombre||'').replace(/-/g,'').slice(0,5).toUpperCase();
    const num = Math.floor(Math.random()*9000)+1000;
    return `${cat}-${nom}-${num}`;
  },

  /* ── Skeleton loaders ───────────────────────── */
  skelRows(n = 5) {
    let h = '';
    for (let i = 0; i < n; i++) h += '<div class="skel skel-row"></div>';
    return `<div style="padding:12px 16px">${h}</div>`;
  },
  skelKpis(n = 4) {
    let h = '';
    for (let i = 0; i < n; i++) h += '<div class="skel skel-kpi"></div>';
    return h;
  },

  /* ── Copiar al portapapeles ─────────────────── */
  async copy(text, okMsg = 'Copiado al portapapeles') {
    try {
      await navigator.clipboard.writeText(text);
      this.toast(okMsg, 'success', 2200);
      return true;
    } catch (e) {
      this.toast('No se pudo copiar. Seleccioná el texto manualmente.', 'warning');
      return false;
    }
  },

  /* ── Paginación ─────────────────────────────── */
  renderPagination(containerEl, page, total, perPage, onPage) {
    const pages = Math.ceil(total / perPage);
    const from  = (page-1)*perPage + 1;
    const to    = Math.min(page*perPage, total);
    let html = `<span class="pagination-info">Mostrando ${from}–${to} de ${total}</span>`;
    html += `<button class="page-btn" ${page<=1?'disabled':''} id="_pprev">‹</button>`;
    for (let i = Math.max(1,page-2); i <= Math.min(pages,page+2); i++) {
      html += `<button class="page-btn${i===page?' active':''}" data-p="${i}">${i}</button>`;
    }
    html += `<button class="page-btn" ${page>=pages?'disabled':''} id="_pnext">›</button>`;
    containerEl.innerHTML = html;
    containerEl.querySelectorAll('[data-p]').forEach(b => b.onclick = ()=>onPage(+b.dataset.p));
    containerEl.querySelector('#_pprev')?.addEventListener('click',()=>onPage(page-1));
    containerEl.querySelector('#_pnext')?.addEventListener('click',()=>onPage(page+1));
  }
};
