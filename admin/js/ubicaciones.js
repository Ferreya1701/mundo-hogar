/* ============================================================
   Ubicación del stock (sql/024): dónde está guardado cada producto.
   Una lista de lugares (local, depósito…) con sector opcional.

     await MHUbic.cargar()            → [{ id, lugar, sector, activo, texto }]
     MHUbic.disponible                → false si la base todavía no tiene el 024
     MHUbic.texto(id)                 → "Depósito 1 · Fila B" ('' si no tiene)
     MHUbic.opciones(elegida, extra)  → <option>… para un <select>
     MHUbic.ubicar(ids, ubicacionId)  → guarda (null = sin ubicación)
     MHUbic.administrar(alCerrar)     → ventana para agregar / renombrar / desactivar
     MHUbic.elegir(titulo)            → ventana que devuelve una ubicación (o null)
   ============================================================ */
const MHUbic = (() => {
  const esc = v => String(v ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
  let lista = null;
  const api = { disponible: true };

  const armar = u => ({ ...u, texto: u.lugar.trim() + (u.sector && u.sector.trim() ? ' · ' + u.sector.trim() : '') });

  api.cargar = async (forzar = false) => {
    if (lista && !forzar) return lista;
    const { data, error } = await db.from('ubicaciones').select('id, lugar, sector, activo, orden').order('lugar').order('orden').order('sector');
    if (error) { api.disponible = false; lista = []; return lista; }
    lista = (data || []).map(armar);
    return lista;
  };
  api.lista = () => lista || [];
  api.texto = id => (lista || []).find(u => u.id === Number(id))?.texto || '';

  api.opciones = (elegida, { vacio = 'Sin ubicación', soloActivas = true } = {}) => {
    const us = (lista || []).filter(u => !soloActivas || u.activo || u.id === Number(elegida));
    const porLugar = {};
    us.forEach(u => (porLugar[u.lugar.trim()] = porLugar[u.lugar.trim()] || []).push(u));
    return (vacio === null ? '' : `<option value="">${esc(vacio)}</option>`) +
      Object.entries(porLugar).map(([lugar, arr]) => arr.length === 1 && !arr[0].sector
        ? `<option value="${arr[0].id}"${arr[0].id === Number(elegida) ? ' selected' : ''}>${esc(lugar)}</option>`
        : `<optgroup label="${esc(lugar)}">${arr.map(u => `<option value="${u.id}"${u.id === Number(elegida) ? ' selected' : ''}>${esc(u.sector ? u.texto : lugar + ' (general)')}</option>`).join('')}</optgroup>`).join('');
  };

  api.ubicar = async (ids, ubicacionId) => {
    const { data, error } = await db.rpc('productos_ubicar', { p_ids: ids, p_ubicacion_id: ubicacionId || null });
    if (error) throw error;
    return data;
  };

  function modal(html, ancho = 520) {
    const bd = document.createElement('div'); bd.className = 'modal-backdrop';
    bd.innerHTML = `<div class="modal" style="max-width:${ancho}px">${html}</div>`;
    document.body.appendChild(bd);
    return bd;
  }

  api.administrar = alCerrar => {
    const bd = modal(`<div class="modal-header"><h3 class="modal-title">📍 Ubicaciones</h3><button class="modal-close" data-x aria-label="Cerrar">×</button></div>
      <div class="modal-body">
        <p style="font-size:13px;color:var(--muted);margin-bottom:10px">Los lugares donde hay mercadería. El sector es opcional (estante, fila, góndola).</p>
        <form id="_uf" style="display:flex;gap:8px;flex-wrap:wrap;margin-bottom:12px" novalidate>
          <input type="text" id="_ul" list="_ulugares" maxlength="60" placeholder="Lugar (ej: Depósito 1)" style="flex:1;min-width:150px">
          <datalist id="_ulugares"></datalist>
          <input type="text" id="_us" maxlength="60" placeholder="Sector (opcional)" style="flex:1;min-width:130px">
          <button class="btn btn-primary" type="submit">Agregar</button>
        </form>
        <div class="table-wrap" style="max-height:46vh;overflow:auto"><table><thead><tr><th>Lugar</th><th>Sector</th><th style="width:70px">Activa</th></tr></thead><tbody id="_ut"></tbody></table></div>
        <div class="form-hint" style="margin-top:8px">No se borran: se desactivan y dejan de aparecer para elegir. Tocá un nombre para corregirlo.</div>
      </div>`, 560);
    const pintar = () => {
      bd.querySelector('#_ulugares').innerHTML = [...new Set(lista.map(u => u.lugar.trim()))].map(l => `<option value="${esc(l)}">`).join('');
      bd.querySelector('#_ut').innerHTML = lista.length ? lista.map(u => `<tr>
        <td><input type="text" data-campo="lugar" data-id="${u.id}" value="${esc(u.lugar)}" maxlength="60" style="width:100%;border-color:transparent;background:transparent"></td>
        <td><input type="text" data-campo="sector" data-id="${u.id}" value="${esc(u.sector || '')}" maxlength="60" placeholder="—" style="width:100%;border-color:transparent;background:transparent"></td>
        <td><label class="toggle-wrap"><div class="toggle"><input type="checkbox" data-activo="${u.id}" ${u.activo ? 'checked' : ''}><div class="toggle-track"></div><div class="toggle-thumb"></div></div></label></td></tr>`).join('')
        : '<tr><td colspan="3" style="padding:18px;text-align:center;color:var(--muted)">Todavía no hay ubicaciones. Agregá la primera arriba.</td></tr>';
    };
    const cerrar = () => { bd.remove(); alCerrar?.(); };
    bd.querySelector('[data-x]').onclick = cerrar;
    bd.querySelector('#_uf').onsubmit = async e => {
      e.preventDefault();
      const lugar = bd.querySelector('#_ul').value.trim(), sector = bd.querySelector('#_us').value.trim() || null;
      if (lugar.length < 2) { Utils.toast('Escribí el lugar', 'warning'); return; }
      const { data, error } = await db.from('ubicaciones').insert({ lugar, sector }).select().single();
      if (error) { Utils.toast(/duplicate|unique/i.test(error.message) ? 'Esa ubicación ya existe' : (error.hint || error.message), 'error'); return; }
      lista.push(armar(data)); lista.sort((a, b) => a.texto.localeCompare(b.texto, 'es'));
      bd.querySelector('#_us').value = ''; bd.querySelector('#_us').focus(); pintar();
    };
    bd.addEventListener('change', async e => {
      const t = e.target, id = Number(t.dataset.id || t.dataset.activo); if (!id) return;
      const u = lista.find(x => x.id === id);
      const cambio = t.dataset.activo ? { activo: t.checked } : { [t.dataset.campo]: t.value.trim() || null };
      if (cambio.lugar === null) { t.value = u.lugar; return; }
      const { error } = await db.from('ubicaciones').update(cambio).eq('id', id);
      if (error) { Utils.toast(/duplicate|unique/i.test(error.message) ? 'Ya hay otra ubicación con ese nombre' : (error.hint || error.message), 'error'); pintar(); return; }
      Object.assign(u, cambio, {}); Object.assign(u, armar(u));
    });
    pintar();
    bd.querySelector('#_ul').focus();
  };

  // Elegir una ubicación (para ubicar varios productos). Devuelve id, 0 (= quitar) o null (cancelado)
  api.elegir = (titulo = 'Ubicación') => new Promise(resolve => {
    const bd = modal(`<div class="modal-header"><h3 class="modal-title">📍 ${esc(titulo)}</h3><button class="modal-close" data-x aria-label="Cerrar">×</button></div>
      <form class="modal-body form-grid" style="gap:14px" novalidate>
        <div class="form-group"><label>¿Dónde están?</label><select id="_ue">${api.opciones(null)}</select>
          <button type="button" class="btn btn-ghost btn-sm" id="_uadm" style="margin-top:6px;align-self:flex-start">Agregar o editar ubicaciones…</button></div>
        <div class="modal-footer" style="padding:0;border:0"><button type="button" class="btn btn-outline" data-x>Cancelar</button><button type="submit" class="btn btn-primary">Guardar</button></div>
      </form>`, 440);
    bd.querySelectorAll('[data-x]').forEach(b => b.onclick = () => { bd.remove(); resolve(null); });
    bd.querySelector('#_uadm').onclick = () => api.administrar(() => { bd.querySelector('#_ue').innerHTML = api.opciones(bd.querySelector('#_ue').value); });
    bd.querySelector('form').onsubmit = e => { e.preventDefault(); const v = Number(bd.querySelector('#_ue').value) || 0; bd.remove(); resolve(v); };
  });

  return api;
})();
window.MHUbic = MHUbic;
