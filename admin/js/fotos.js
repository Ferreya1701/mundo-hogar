/* ============================================================
   Fotos de productos: achicar, subir y ordenar (sql/023).

   - Se achican EN EL NAVEGADOR antes de subir: lado mayor 1600 px,
     WebP (o JPG si el navegador no sabe). Una foto de celular de 6 MB
     queda en ~200 KB: sube rápido y la tienda carga liviana.
   - Varias fotos por producto. La primera es la PRINCIPAL (la que se ve
     en la tienda y en el panel). Se reordenan con las flechas.
   - Se agregan con el botón, arrastrando, pegando (Ctrl+V) o con la
     cámara del celular.
   - Cada cambio se guarda solo (producto_fotos_guardar).

   Uso:
     MHFotos.galeria(contenedor, { productoId, urls, onCambio(urls) })
     MHFotos.subir(file, productoId) → url pública
   ============================================================ */
const MHFotos = (() => {
  const BUCKET = 'producto-imagenes';
  const LADO = 1600, CALIDAD = 0.82, MAX_FOTOS = 12;
  const esc = v => String(v ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
  const esTactil = () => matchMedia('(pointer: coarse)').matches;

  async function decodificar(file) {
    if ('createImageBitmap' in window) {
      try { return await createImageBitmap(file, { imageOrientation: 'from-image' }); } catch (e) { /* sigue */ }
    }
    return new Promise((ok, mal) => {
      const img = new Image(), u = URL.createObjectURL(file);
      img.onload = () => { URL.revokeObjectURL(u); ok(img); };
      img.onerror = () => { URL.revokeObjectURL(u); mal(new Error('formato')); };
      img.src = u;
    });
  }

  // File → Blob achicado (WebP o JPG)
  async function comprimir(file) {
    if (!/^image\//.test(file.type) && !/\.(jpe?g|png|webp|heic|heif|gif|bmp)$/i.test(file.name || '')) {
      throw new Error('no_es_imagen');
    }
    let img;
    try { img = await decodificar(file); }
    catch (e) { throw new Error('formato'); }
    const w = img.width || img.naturalWidth, h = img.height || img.naturalHeight;
    const k = Math.min(1, LADO / Math.max(w, h));
    const c = document.createElement('canvas');
    c.width = Math.round(w * k); c.height = Math.round(h * k);
    const ctx = c.getContext('2d');
    ctx.fillStyle = '#fff'; ctx.fillRect(0, 0, c.width, c.height);   // PNG transparente → fondo blanco
    ctx.drawImage(img, 0, 0, c.width, c.height);
    if (img.close) img.close();
    const blob = await new Promise(ok => c.toBlob(ok, 'image/webp', CALIDAD));
    if (blob && blob.type === 'image/webp') return blob;
    return new Promise(ok => c.toBlob(ok, 'image/jpeg', CALIDAD));
  }

  function mensaje(e) {
    const m = String(e?.message || e?.error || '').toLowerCase();
    if (m.includes('no_es_imagen')) return 'no es una imagen';
    if (m.includes('formato')) return 'formato que este navegador no abre (probá sacarla en JPG)';
    if (m.includes('row-level') || m.includes('unauthorized') || m.includes('403') || m.includes('sin_permiso')) return 'tu usuario no puede subir fotos';
    if (!navigator.onLine || m.includes('fetch')) return 'sin conexión';
    return 'no se pudo subir';
  }

  async function subir(file, productoId) {
    const blob = await comprimir(file);
    const ext = blob.type === 'image/webp' ? 'webp' : 'jpg';
    const path = `productos/${productoId || 'sueltas'}/${Date.now()}-${Math.random().toString(36).slice(2, 7)}.${ext}`;
    const { error } = await db.storage.from(BUCKET).upload(path, blob, { contentType: blob.type, cacheControl: '31536000' });
    if (error) throw error;
    return db.storage.from(BUCKET).getPublicUrl(path).data.publicUrl;
  }

  async function guardar(productoId, urls) {
    const { error } = await db.rpc('producto_fotos_guardar', { p_producto_id: productoId, p_urls: urls });
    if (error) {
      // Sin sql/023: al menos la principal, como antes
      if (/could not find the function|schema cache/i.test(error.message || '')) {
        const r = await db.from('productos').update({ imagen_principal_url: urls[0] || null }).eq('id', productoId);
        if (r.error) throw r.error;
        return;
      }
      throw error;
    }
  }

  // Galería editable. Devuelve { agregar(files), urls() }
  function galeria(el, op) {
    let urls = (op.urls || []).filter(Boolean);
    let subiendo = 0;
    const compacta = !!op.compacta;
    // Si ya había una galería en este elemento, sus eventos se sueltan
    el._mhfAbort?.abort();
    const ac = new AbortController(); el._mhfAbort = ac;
    const on = (ev, fn) => el.addEventListener(ev, fn, { signal: ac.signal });

    function pintar() {
      el.classList.add('mhf');
      el.classList.toggle('mhf-compacta', compacta);
      el.innerHTML = `
        <div class="mhf-grilla">
          ${urls.map((u, i) => `<div class="mhf-foto${i === 0 ? ' principal' : ''}">
            <img src="${esc(u)}" alt="" loading="lazy">
            ${i === 0 ? '<span class="mhf-tag">Principal</span>' : ''}
            <div class="mhf-acc">
              ${i > 0 ? `<button type="button" data-a="izq" data-i="${i}" title="Mover a la izquierda (la primera es la principal)" aria-label="Mover antes">◀</button>` : ''}
              ${i < urls.length - 1 ? `<button type="button" data-a="der" data-i="${i}" title="Mover a la derecha" aria-label="Mover después">▶</button>` : ''}
              <button type="button" data-a="quitar" data-i="${i}" title="Quitar foto" aria-label="Quitar foto">✕</button>
            </div></div>`).join('')}
          ${Array.from({ length: subiendo }).map(() => '<div class="mhf-foto mhf-cargando"><div class="spinner"></div></div>').join('')}
          ${urls.length + subiendo < MAX_FOTOS ? `<label class="mhf-agregar" title="Elegir fotos (también podés arrastrarlas o pegarlas con Ctrl+V)">
              <input type="file" accept="image/*" multiple hidden data-in="archivos">
              <span class="mhf-mas">＋</span><span>${urls.length ? 'Agregar' : 'Agregar fotos'}</span>
            </label>
            ${esTactil() ? `<label class="mhf-agregar mhf-camara"><input type="file" accept="image/*" capture="environment" hidden data-in="camara"><span class="mhf-mas">📷</span><span>Sacar foto</span></label>` : ''}` : ''}
        </div>
        ${!compacta ? `<div class="mhf-ayuda">${urls.length ? 'La primera es la principal. ' : ''}Arrastrá fotos acá o pegalas con Ctrl+V. Se achican solas.</div>` : ''}`;
    }

    async function cambiar(nuevas) {
      const antes = urls;
      urls = nuevas; pintar();
      try { if (op.productoId) await guardar(op.productoId, urls); op.onCambio?.(urls); }   // sin producto todavía: se asocian al crearlo
      catch (e) { urls = antes; pintar(); Utils.toast('No se guardó el cambio de fotos: ' + mensaje(e), 'error'); }
    }

    async function agregar(files) {
      files = [...files].filter(f => f && (f.type.startsWith('image/') || /\.(heic|heif)$/i.test(f.name || '')));
      if (!files.length) return;
      const lugar = MAX_FOTOS - urls.length - subiendo;
      if (files.length > lugar) { Utils.toast(`Hasta ${MAX_FOTOS} fotos por producto`, 'warning'); files = files.slice(0, Math.max(0, lugar)); }
      subiendo += files.length; pintar();
      const nuevas = [], fallas = [];
      for (const f of files) {
        try { nuevas.push(await subir(f, op.productoId)); }
        catch (e) { fallas.push(`${f.name || 'foto'}: ${mensaje(e)}`); }
        subiendo--; pintar();
      }
      if (fallas.length) Utils.toast('No se pudieron subir: ' + fallas.map(esc).join(' · '), 'error', 8000);
      if (nuevas.length) await cambiar([...urls, ...nuevas]);
    }

    on('click', e => {
      const b = e.target.closest('[data-a]'); if (!b) return;
      const i = Number(b.dataset.i), n = [...urls];
      if (b.dataset.a === 'quitar') { n.splice(i, 1); cambiar(n); }
      if (b.dataset.a === 'izq') { [n[i - 1], n[i]] = [n[i], n[i - 1]]; cambiar(n); }
      if (b.dataset.a === 'der') { [n[i + 1], n[i]] = [n[i], n[i + 1]]; cambiar(n); }
    });
    on('change', e => { if (e.target.dataset.in) { agregar(e.target.files); e.target.value = ''; } });
    on('dragover', e => { e.preventDefault(); el.classList.add('mhf-sobre'); });
    on('dragleave', () => el.classList.remove('mhf-sobre'));
    on('drop', e => { e.preventDefault(); el.classList.remove('mhf-sobre'); agregar(e.dataTransfer.files); });
    el.tabIndex = el.tabIndex >= 0 ? el.tabIndex : 0;
    on('paste', e => {
      const fs = [...(e.clipboardData?.files || [])];
      if (fs.length) { e.preventDefault(); agregar(fs); }
    });

    pintar();
    return { agregar, urls: () => [...urls] };
  }

  // Estilos una sola vez
  if (!document.getElementById('mhf-css')) {
    const st = document.createElement('style'); st.id = 'mhf-css';
    st.textContent = `
      .mhf { outline:none; border-radius:var(--r-lg, 12px); }
      .mhf.mhf-sobre { box-shadow:0 0 0 3px rgba(244,122,31,.45); background:rgba(244,122,31,.05); }
      .mhf-grilla { display:grid; grid-template-columns:repeat(auto-fill, minmax(104px, 1fr)); gap:10px; }
      .mhf-compacta .mhf-grilla { grid-template-columns:repeat(auto-fill, 64px); gap:6px; }
      .mhf-foto, .mhf-agregar { position:relative; aspect-ratio:1; border-radius:10px; overflow:hidden; border:1px solid var(--border, #e5e7eb); background:#fff; }
      .mhf-foto img { width:100%; height:100%; object-fit:contain; display:block; }
      .mhf-foto.principal { border:2px solid var(--gold, #F47A1F); }
      .mhf-tag { position:absolute; left:4px; top:4px; background:var(--gold, #F47A1F); color:#fff; font-size:10px; font-weight:700; padding:1px 6px; border-radius:20px; }
      .mhf-compacta .mhf-tag { display:none; }
      .mhf-acc { position:absolute; inset:auto 0 0 0; display:flex; justify-content:center; gap:4px; padding:4px; background:linear-gradient(transparent, rgba(0,0,0,.45)); opacity:0; transition:opacity .15s; }
      .mhf-foto:hover .mhf-acc, .mhf-foto:focus-within .mhf-acc { opacity:1; }
      @media (pointer: coarse) { .mhf-acc { opacity:1; } }
      .mhf-acc button { width:26px; height:26px; border-radius:50%; border:0; background:#fff; cursor:pointer; font-size:11px; line-height:1; }
      .mhf-acc button[data-a="quitar"] { color:#B91C1C; }
      .mhf-agregar { display:flex; flex-direction:column; align-items:center; justify-content:center; gap:2px; border:2px dashed var(--border, #d1d5db); cursor:pointer; color:var(--muted, #6b7280); font-size:12px; text-align:center; background:var(--bg, #f8fafc); }
      .mhf-agregar:hover { border-color:var(--gold, #F47A1F); color:var(--gold, #F47A1F); }
      .mhf-mas { font-size:22px; line-height:1; }
      .mhf-compacta .mhf-agregar span:last-child { display:none; }
      .mhf-cargando { display:flex; align-items:center; justify-content:center; background:var(--bg, #f8fafc); }
      .mhf-ayuda { font-size:12px; color:var(--muted, #6b7280); margin-top:8px; }`;
    document.head.appendChild(st);
  }

  return { comprimir, subir, guardar, galeria, mensaje };
})();
window.MHFotos = MHFotos;
