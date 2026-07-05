/* ============================================================
   Mundo Hogar — Lógica compartida del catálogo
   ============================================================ */
window.MH = (function () {
  // Feature flag: el checkout online (Mercado Pago u otro) queda DESACTIVADO en esta fase.
  // Cuando se integre un pago online, activar desde acá; ninguna UI de pago debe
  // renderizarse mientras sea false.
  const ONLINE_PAYMENTS_ENABLED = false;

  // Número de respaldo; el vigente se lee de site_settings (editable desde el panel)
  let WA_NUMBER = '5493426481326';
  const DATA_URL = '/src/data/productos.json';
  const PLACEHOLDER = "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 400 400'%3E%3Crect width='400' height='400' fill='%23F4F7FC'/%3E%3Ctext x='200' y='190' font-family='Plus Jakarta Sans,Arial,sans-serif' font-size='52' font-weight='800' fill='%231763C6' text-anchor='middle'%3EMH%3C/text%3E%3Ctext x='200' y='230' font-family='Arial,sans-serif' font-size='15' fill='%235A6B85' text-anchor='middle'%3EImagen no disponible%3C/text%3E%3C/svg%3E";

  // Categorías reales (orden de visualización)
  const CATS = [
    { slug:'electrodomesticos',     label:'Electrodomésticos',     desc:'Heladeras, cocinas, lavarropas, freidoras de aire y más.' },
    { slug:'herramientas',          label:'Herramientas',          desc:'Taladros, amoladoras, soldadoras y herramientas INGCO.' },
    { slug:'tecnologia-celulares',  label:'Tecnología y Celulares',desc:'Celulares, Smart TV, parlantes, auriculares y cámaras.' },
    { slug:'muebles-hogar',         label:'Muebles y Hogar',       desc:'Colchones, sillas, sofás, termos y bazar.' },
    { slug:'cuidado-personal',      label:'Cuidado Personal',      desc:'Secadores, planchitas, recortadoras y más.' },
    { slug:'salud',                 label:'Salud',                 desc:'Tensiómetros, nebulizadores y balanzas.' },
    { slug:'seguridad',             label:'Seguridad',             desc:'Cerraduras inteligentes para tu hogar.' }
  ];
  const CAT_BY_SLUG = Object.fromEntries(CATS.map(c => [c.slug, c]));
  const catLabel = s => (CAT_BY_SLUG[s] && CAT_BY_SLUG[s].label) || s;

  // Gradientes de marca por categoría (variados a propósito para que cada
  // categoría se distinga de un vistazo, siempre dentro de azul/naranja/blanco)
  const CAT_GRAD = {
    electrodomesticos:     'linear-gradient(135deg,#0A2E63 0%,#2472DB 100%)',
    herramientas:          'linear-gradient(135deg,#12213F 0%,#0E4AA0 100%)',
    'tecnologia-celulares':'linear-gradient(135deg,#0A2E63 0%,#3B8CE0 100%)',
    'muebles-hogar':       'linear-gradient(135deg,#123B7D 0%,#0A2E63 100%)',
    'cuidado-personal':    'linear-gradient(135deg,#1763C6 0%,#0A2E63 100%)',
    salud:                 'linear-gradient(135deg,#0A2E63 0%,#1D7A9C 100%)',
    seguridad:             'linear-gradient(135deg,#081226 0%,#12213F 100%)'
  };
  // Color de acento (resplandor + insignia) por categoría, para reforzar la distinción
  const CAT_ACCENT = {
    electrodomesticos:'#F47A1F', herramientas:'#F47A1F', 'tecnologia-celulares':'#3FD0E8',
    'muebles-hogar':'#F47A1F', 'cuidado-personal':'#FF9F5A', salud:'#3FE0B0', seguridad:'#F47A1F'
  };

  // Íconos grandes y protagonistas — representan el rubro, no un producto puntual
  const BIG_ICONS = {
    electrodomesticos:'<svg viewBox="0 0 64 64" fill="none" stroke="currentColor" stroke-width="3.2" stroke-linecap="round" stroke-linejoin="round"><rect x="14" y="4" width="36" height="56" rx="5"/><line x1="14" y1="25" x2="50" y2="25"/><line x1="21" y1="12" x2="21" y2="16"/><line x1="21" y1="34" x2="21" y2="41"/></svg>',
    herramientas:'<svg viewBox="0 0 64 64" fill="none" stroke="currentColor" stroke-width="3.2" stroke-linecap="round" stroke-linejoin="round"><path d="M41 11a10.5 10.5 0 0 0-14.4 13.3L7 44v9h9l19.7-19.7A10.5 10.5 0 0 0 49 23.4l-7 7-6-1.4-1.4-6z"/></svg>',
    'tecnologia-celulares':'<svg viewBox="0 0 64 64" fill="none" stroke="currentColor" stroke-width="3.2" stroke-linecap="round" stroke-linejoin="round"><rect x="19" y="5" width="26" height="54" rx="5.5"/><line x1="28" y1="50" x2="36" y2="50"/></svg>',
    'muebles-hogar':'<svg viewBox="0 0 64 64" fill="none" stroke="currentColor" stroke-width="3.2" stroke-linecap="round" stroke-linejoin="round"><path d="M10 30v-8a6 6 0 0 1 6-6h32a6 6 0 0 1 6 6v8"/><path d="M6 32a4 4 0 0 1 4 4v11h44V36a4 4 0 0 1 4-4"/><line x1="10" y1="47" x2="10" y2="55"/><line x1="54" y1="47" x2="54" y2="55"/></svg>',
    'cuidado-personal':'<svg viewBox="0 0 64 64" fill="none" stroke="currentColor" stroke-width="3.2" stroke-linecap="round" stroke-linejoin="round"><path d="M9 15c8-7 21-9 31-2 10 7 13 19 8 27-4 6-11 7-16 3" stroke-width="3.2"/><ellipse cx="45" cy="34" rx="10" ry="7.5" transform="rotate(30 45 34)"/></svg>',
    salud:'<svg viewBox="0 0 64 64" fill="none" stroke="currentColor" stroke-width="3.2" stroke-linecap="round" stroke-linejoin="round"><path d="M32 53S11 41 11 26a11 11 0 0 1 21-4.6A11 11 0 0 1 53 26c0 15-21 27-21 27z"/><path d="M17 30h6l4-8 6 16 4-11 3 3h8" stroke-width="2.6"/></svg>',
    seguridad:'<svg viewBox="0 0 64 64" fill="none" stroke="currentColor" stroke-width="3.2" stroke-linecap="round" stroke-linejoin="round"><path d="M32 6l19 7v15c0 14-8.5 22.5-19 27C21.5 50.5 13 42 13 28V13z"/><rect x="23" y="30" width="18" height="14" rx="3"/><path d="M26 30v-4a6 6 0 0 1 12 0v4"/></svg>'
  };

  // Visual profesional de categoría: gradiente de marca + insignia con ícono grande (sin fotos de productos)
  function catVisual(slug) {
    const grad = CAT_GRAD[slug] || CAT_GRAD.electrodomesticos;
    const accent = CAT_ACCENT[slug] || '#F47A1F';
    const icon = BIG_ICONS[slug] || '';
    return `<div class="cat-visual" style="background:${grad}">
      <span class="cat-visual-blob" style="background:radial-gradient(circle,${accent}66,transparent 65%)" aria-hidden="true"></span>
      <span class="cat-visual-pattern" aria-hidden="true"></span>
      <span class="cat-visual-badge" style="background:${accent}26;border-color:${accent}66" aria-hidden="true">
        <span class="cat-visual-icon">${icon}</span>
      </span>
    </div>`;
  }

  // Anima un número desde 0 hasta su valor final cuando entra en pantalla
  function animateCount(el) {
    const target = parseFloat(el.dataset.count);
    if (!isFinite(target)) return;
    const suffix = el.dataset.suffix || '';
    const prefix = el.dataset.prefix || '';
    const dur = 1100;
    const reduced = window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches;
    if (reduced) { el.textContent = prefix + target + suffix; return; }
    const t0 = performance.now();
    function step(now) {
      const p = Math.min((now - t0) / dur, 1);
      const eased = 1 - Math.pow(1 - p, 3);
      el.textContent = prefix + Math.round(target * eased) + suffix;
      if (p < 1) requestAnimationFrame(step);
    }
    requestAnimationFrame(step);
  }

  function initCounters(root) {
    const els = (root || document).querySelectorAll('[data-count]');
    if (!els.length) return;
    if (!('IntersectionObserver' in window)) { els.forEach(animateCount); return; }
    const io = new IntersectionObserver((entries) => {
      entries.forEach(en => { if (en.isIntersecting) { animateCount(en.target); io.unobserve(en.target); } });
    }, { threshold: .4 });
    els.forEach(e => io.observe(e));
  }

  const waLink = (text) => `https://wa.me/${WA_NUMBER}?text=${encodeURIComponent(text)}`;

  // ── Configuración del sitio (site_settings, editable desde el panel) ──
  // Trae el número de WhatsApp y textos; si falla, quedan los valores de respaldo.
  let _settings = null;
  async function loadSettings() {
    if (_settings) return _settings;
    try {
      const url = window.SUPABASE_URL;
      const key = window.SUPABASE_PUBLISHABLE_KEY || window.SUPABASE_ANON_KEY;
      if (!url || !key) return null;
      const res = await fetch(`${url}/rest/v1/site_settings?id=eq.1&select=whatsapp,envio_info,mensaje_promo,nombre_tienda`,
        { headers: { apikey: key, Authorization: `Bearer ${key}` } });
      if (!res.ok) return null;
      const rows = await res.json();
      _settings = rows[0] || null;
      if (_settings && _settings.whatsapp) {
        const num = String(_settings.whatsapp).replace(/\D/g, '');
        if (num.length >= 10) { WA_NUMBER = num; syncWaLinks(); }
      }
    } catch (e) { /* respaldo local */ }
    return _settings;
  }

  // ── Textos del sitio (site_content, editables desde el panel) ──
  // Devuelve un mapa clave→valor. Si falla, {} y la página usa sus textos fijos.
  let _content = null;
  async function loadContent() {
    if (_content) return _content;
    try {
      const url = window.SUPABASE_URL;
      const key = window.SUPABASE_PUBLISHABLE_KEY || window.SUPABASE_ANON_KEY;
      if (!url || !key) return {};
      const res = await fetch(`${url}/rest/v1/site_content?select=clave,valor`,
        { headers: { apikey: key, Authorization: `Bearer ${key}` } });
      if (!res.ok) return {};
      const rows = await res.json();
      _content = {};
      rows.forEach(r => { if (r.valor) _content[r.clave] = r.valor; });
    } catch (e) { _content = {}; }
    return _content;
  }

  // Aplica un texto de site_content a un elemento si existe valor cargado.
  // Para títulos (conEnfasis), "|" separa la parte final resaltada en naranja;
  // si el valor no trae "|" se conserva el texto original de la página
  // (evita perder el resaltado si el dato de la base quedó desactualizado).
  function applyContent(map, clave, el, conEnfasis) {
    const v = map[clave];
    if (!v || !el) return;
    if (conEnfasis) {
      if (!v.includes('|')) return;
      const [a, b] = v.split('|');
      el.innerHTML = '';
      el.append(a.trim());
      el.appendChild(document.createElement('br'));
      const em = document.createElement('em');
      em.textContent = b.trim();
      el.appendChild(em);
    } else {
      el.textContent = v;
    }
  }

  // Reescribe todos los links wa.me del documento con el número configurado,
  // conservando el texto precargado de cada uno (el número vive en un solo lugar).
  function syncWaLinks() {
    document.querySelectorAll('a[href*="wa.me/"]').forEach(a => {
      try {
        const u = new URL(a.href);
        const text = u.searchParams.get('text');
        a.href = `https://wa.me/${WA_NUMBER}` + (text ? `?text=${encodeURIComponent(text)}` : '');
      } catch (e) { /* href inválido: se deja como está */ }
    });
  }

  // ── Precios ──
  // Un precio es válido solo si es un número mayor a 0. Nunca mostrar $0/NaN.
  const isValidPrice = (n) => typeof n === 'number' && isFinite(n) && n > 0;
  function effectivePrice(p) {
    if (p.enOferta && isValidPrice(p.precioOferta)) return p.precioOferta;
    if (isValidPrice(p.precio)) return p.precio;
    return null;
  }
  const hasPrice = (p) => effectivePrice(p) !== null;
  const _fmt = new Intl.NumberFormat('es-AR', { style: 'currency', currency: 'ARS', minimumFractionDigits: 0, maximumFractionDigits: 2 });
  const fmtPrice = (n) => isValidPrice(n) ? _fmt.format(n) : null;

  // Disponibilidad: el bloqueo por stock solo aplica a productos con precio
  // cargado (ficha gestionada). Sin precio, el flujo es consulta/cotización y
  // no se afirma disponibilidad (el stock aún no se cargó en esta fase).
  function isAvailable(p) {
    if (!hasPrice(p)) return true;
    if (p.seguimiento === false || p.permiteSinStock === true) return true;
    if (typeof p.stock === 'number' && p.stock <= 0) return false;
    return true;
  }

  // ── Analítica (no-op si GA4/Meta no están instalados) ──
  // Nunca enviar datos personales (nombre, teléfono, dirección) en estos eventos.
  function track(evento, params) {
    try {
      if (window.gtag) window.gtag('event', evento, params || {});
      if (window.fbq) window.fbq('trackCustom', evento, params || {});
    } catch (e) { /* la analítica nunca debe romper la tienda */ }
  }

  let _cache = null;

  // Trae los productos desde Supabase (fuente en vivo, editable desde el panel).
  // Si Supabase falla por algún motivo, usa el catálogo estático como respaldo.
  async function loadFromSupabase() {
    const url = window.SUPABASE_URL;
    const key = window.SUPABASE_PUBLISHABLE_KEY || window.SUPABASE_ANON_KEY;
    if (!url || !key) return null;
    const endpoint = `${url}/rest/v1/productos?select=id,nombre,slug,descripcion,descripcion_corta,imagen_principal_url,destacado,es_nuevo,orden,sku,marca,precio_minorista,precio_oferta,en_oferta,stock_actual,permite_venta_sin_stock,seguimiento_inventario,categorias(slug)&estado=eq.activo&order=orden.asc`;
    const res = await fetch(endpoint, { headers: { apikey: key, Authorization: `Bearer ${key}` } });
    if (!res.ok) throw new Error('Supabase respondió ' + res.status);
    const rows = await res.json();
    return rows.map(p => ({
      id: p.slug,
      pid: p.id,
      orden: p.orden,
      nombre: p.nombre,
      imagen: p.imagen_principal_url,
      alt: p.nombre,
      descripcion: p.descripcion,
      descripcionCorta: p.descripcion_corta,
      categoria: p.categorias ? p.categorias.slug : null,
      slug: p.slug,
      sku: p.sku,
      marca: p.marca,
      precio: p.precio_minorista != null ? Number(p.precio_minorista) : null,
      precioOferta: p.precio_oferta != null ? Number(p.precio_oferta) : null,
      enOferta: !!p.en_oferta,
      stock: typeof p.stock_actual === 'number' ? p.stock_actual : null,
      permiteSinStock: !!p.permite_venta_sin_stock,
      seguimiento: p.seguimiento_inventario !== false,
      activo: true,
      destacado: !!p.destacado,
      _nuevo: !!p.es_nuevo
    }));
  }

  async function loadFromJSON() {
    const res = await fetch(DATA_URL, { cache: 'no-cache' });
    const data = await res.json();
    const activos = data.productos.filter(p => p.activo !== false);
    const ordenMax = Math.max(...activos.map(p => p.orden || 0));
    activos.forEach(p => { p._nuevo = (p.orden || 0) > ordenMax - 18; });
    return activos;
  }

  async function loadProducts() {
    if (_cache) return _cache;
    try {
      const desdeSupabase = await loadFromSupabase();
      if (desdeSupabase && desdeSupabase.length) {
        _cache = desdeSupabase;
        return _cache;
      }
    } catch (err) {
      console.warn('No se pudo cargar el catálogo desde Supabase, se usa respaldo local.', err);
    }
    _cache = await loadFromJSON();
    return _cache;
  }

  // Crea la tarjeta de producto (DOM). Dos estados: con precio (agregar al carrito)
  // y sin precio ("Consultar precio" + cotización). Nunca muestra $0/NaN.
  function createCard(p) {
    const url = p.imagen || PLACEHOLDER;
    const card = document.createElement('article');
    card.className = 'mh-card';
    card.dataset.category = p.categoria;
    const ficha = p.slug ? `/producto/${p.slug}` : null;
    const badges = [];
    const precio = effectivePrice(p);
    const conOferta = precio !== null && p.enOferta && isValidPrice(p.precioOferta) && isValidPrice(p.precio) && p.precioOferta < p.precio;
    if (conOferta) badges.push('<span class="badge badge-oferta">Oferta</span>');
    if (p.destacado) badges.push('<span class="badge badge-dest">Destacado</span>');
    if (p._nuevo) badges.push('<span class="badge badge-new">Nuevo</span>');
    const disponible = isAvailable(p);
    if (!disponible) badges.push('<span class="badge badge-nostock">Sin stock</span>');
    const nombreAttr = (p.nombre || '').replace(/"/g, '&quot;');
    const wa = waLink(`Hola! Me interesa ${p.nombre}. ¿Tienen stock y precio?`);

    const precioHTML = precio !== null
      ? `<div class="mh-price">${conOferta ? `<s class="mh-price-old">${fmtPrice(p.precio)}</s>` : ''}<b>${fmtPrice(precio)}</b></div>`
      : `<div class="mh-price mh-price-ask">Consultar precio</div>`;

    let ctaHTML;
    if (!disponible) {
      ctaHTML = `<a class="btn btn-wa btn-sm" href="${wa}" target="_blank" rel="noopener" aria-label="Consultar disponibilidad de ${nombreAttr}">Consultar</a>`;
    } else if (precio !== null) {
      ctaHTML = `<button class="btn btn-primary btn-sm mh-add" type="button" aria-label="Agregar ${nombreAttr} al carrito">Agregar</button>
        <a class="btn btn-wa btn-sm btn-icon" href="${wa}" target="_blank" rel="noopener" aria-label="Consultar ${nombreAttr} por WhatsApp">WA</a>`;
    } else {
      ctaHTML = `<button class="btn btn-outline btn-sm mh-add" type="button" aria-label="Agregar ${nombreAttr} a la cotización">Cotizar</button>
        <a class="btn btn-wa btn-sm btn-icon" href="${wa}" target="_blank" rel="noopener" aria-label="Consultar ${nombreAttr} por WhatsApp">WA</a>`;
    }

    card.innerHTML = `
      <div class="mh-card-imgwrap">
        ${badges.length ? `<div class="mh-badges">${badges.join('')}</div>` : ''}
        ${ficha ? `<a href="${ficha}" class="mh-card-imglink" aria-hidden="true" tabindex="-1">` : ''}
        <img alt="${(p.alt || p.nombre || '').replace(/"/g,'&quot;')}" loading="lazy" decoding="async">
        ${ficha ? `</a>` : ''}
      </div>
      <div class="mh-card-body">
        <div class="mh-card-cat">${catLabel(p.categoria)}</div>
        <h3 class="mh-card-title">${ficha ? `<a href="${ficha}">${p.nombre || ''}</a>` : (p.nombre || '')}</h3>
        ${p.descripcion ? `<p class="mh-card-desc">${p.descripcion}</p>` : ''}
        ${precioHTML}
        <div class="mh-card-cta">${ctaHTML}</div>
      </div>`;
    const img = card.querySelector('img');
    img.onerror = function () { this.onerror = null; this.src = PLACEHOLDER; };
    img.src = url;
    const addBtn = card.querySelector('.mh-add');
    if (addBtn) addBtn.addEventListener('click', () => { Cart.add(p, 1); Cart.flash(addBtn); });
    return card;
  }

  // ── Carrito (persistente en localStorage; los precios finales los valida el servidor) ──
  const Cart = (function () {
    const KEY = 'mh_cart_v1';
    let items = [];
    try { items = JSON.parse(localStorage.getItem(KEY) || '[]'); } catch (e) { items = []; }
    if (!Array.isArray(items)) items = [];

    const save = () => { try { localStorage.setItem(KEY, JSON.stringify(items)); } catch (e) {} renderFab(); };
    const count = () => items.reduce((n, it) => n + (it.cant || 0), 0);

    function add(p, cant) {
      if (!p || (p.pid == null && !p.slug)) return;
      const key = p.pid != null ? String(p.pid) : p.slug;
      const found = items.find(it => String(it.pid) === key || it.slug === key);
      if (found) found.cant = Math.min((found.cant || 1) + (cant || 1), 99);
      else items.push({
        pid: p.pid != null ? p.pid : null, slug: p.slug || null,
        nombre: p.nombre || '', sku: p.sku || null, imagen: p.imagen || null,
        precio: effectivePrice(p),      // referencia visual; el server lo recalcula
        cant: Math.min(Math.max(cant || 1, 1), 99)
      });
      save();
      track('add_to_cart', { item_name: p.nombre });
    }
    function setQty(key, cant) {
      const it = items.find(i => String(i.pid) === String(key) || i.slug === key);
      if (!it) return;
      cant = Math.max(1, Math.min(99, parseInt(cant, 10) || 1));
      it.cant = cant; save();
    }
    function remove(key) {
      items = items.filter(i => !(String(i.pid) === String(key) || i.slug === key));
      save();
      track('remove_from_cart', {});
    }
    function clear() { items = []; save(); }

    // Botón flotante con contador (aparece en todas las páginas, arriba del de WhatsApp)
    let _fab = null;
    function renderFab() {
      if (!_fab) return;
      const n = count();
      _fab.querySelector('.mh-cart-count').textContent = n;
      _fab.classList.toggle('has-items', n > 0);
    }
    function initFab() {
      if (_fab || document.getElementById('mh-cart-fab')) return;
      _fab = document.createElement('a');
      _fab.id = 'mh-cart-fab';
      _fab.href = '/carrito';
      _fab.setAttribute('aria-label', 'Ver carrito');
      _fab.innerHTML = `<svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="9" cy="21" r="1"/><circle cx="20" cy="21" r="1"/><path d="M1 1h4l2.68 13.39a2 2 0 0 0 2 1.61h9.72a2 2 0 0 0 2-1.61L23 6H6"/></svg><span class="mh-cart-count">0</span>`;
      document.body.appendChild(_fab);
      renderFab();
    }
    // Mini-feedback al agregar
    function flash(btn) {
      if (!btn) return;
      const prev = btn.textContent;
      btn.textContent = '✓ Agregado';
      btn.disabled = true;
      setTimeout(() => { btn.textContent = prev; btn.disabled = false; }, 1200);
      if (_fab) { _fab.classList.add('bump'); setTimeout(() => _fab.classList.remove('bump'), 400); }
    }
    return { get items() { return items; }, add, setQty, remove, clear, count, initFab, flash };
  })();

  function skeletons(n) {
    let h = '';
    for (let i = 0; i < n; i++) h += '<div class="skel skel-card"></div>';
    return h;
  }

  // Carrusel: crea flechas, soporta teclado/táctil, habilita/deshabilita extremos
  function initCarousel(carousel) {
    const track = carousel.querySelector('.mh-carousel-track');
    if (!track) return;
    const prev = document.createElement('button');
    const next = document.createElement('button');
    prev.className = 'mh-arrow mh-arrow-prev'; prev.setAttribute('aria-label', 'Anterior');
    next.className = 'mh-arrow mh-arrow-next'; next.setAttribute('aria-label', 'Siguiente');
    prev.innerHTML = '<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><polyline points="15 18 9 12 15 6"/></svg>';
    next.innerHTML = '<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><polyline points="9 18 15 12 9 6"/></svg>';
    carousel.appendChild(prev); carousel.appendChild(next);
    const step = () => Math.max(track.clientWidth * 0.8, 240);
    prev.addEventListener('click', () => track.scrollBy({ left: -step(), behavior: 'smooth' }));
    next.addEventListener('click', () => track.scrollBy({ left: step(), behavior: 'smooth' }));
    track.setAttribute('tabindex', '0');
    track.setAttribute('role', 'region');
    track.addEventListener('keydown', e => {
      if (e.key === 'ArrowRight') { e.preventDefault(); track.scrollBy({ left: step(), behavior: 'smooth' }); }
      if (e.key === 'ArrowLeft') { e.preventDefault(); track.scrollBy({ left: -step(), behavior: 'smooth' }); }
    });
    const update = () => {
      prev.disabled = track.scrollLeft < 8;
      next.disabled = track.scrollLeft + track.clientWidth >= track.scrollWidth - 8;
    };
    track.addEventListener('scroll', update, { passive: true });
    window.addEventListener('resize', update);
    setTimeout(update, 60);
  }

  // Aparición suave al hacer scroll
  function initReveal(root) {
    const els = (root || document).querySelectorAll('.reveal');
    if (!('IntersectionObserver' in window) || !els.length) { els.forEach(e => e.classList.add('in')); return; }
    const io = new IntersectionObserver((entries) => {
      entries.forEach(en => { if (en.isIntersecting) { en.target.classList.add('in'); io.unobserve(en.target); } });
    }, { threshold: 0.12 });
    els.forEach(e => io.observe(e));
  }

  // Marca los hijos directos de un contenedor como .reveal con una demora escalonada
  // (da sensación de "entrada en cascada" en grillas y carruseles)
  function stagger(container, stepMs) {
    if (!container) return;
    Array.from(container.children).forEach((el, i) => {
      el.classList.add('reveal');
      el.style.transitionDelay = Math.min(i * (stepMs || 60), 480) + 'ms';
    });
  }

  // Barra de progreso de scroll (arriba de la página)
  function initScrollProgress() {
    const bar = document.createElement('div');
    bar.id = 'mh-scroll-progress';
    document.body.appendChild(bar);
    const update = () => {
      const h = document.documentElement;
      const scrolled = h.scrollTop;
      const max = h.scrollHeight - h.clientHeight;
      bar.style.width = (max > 0 ? (scrolled / max) * 100 : 0) + '%';
    };
    window.addEventListener('scroll', update, { passive: true });
    update();
  }

  // Inicialización común a todas las páginas: settings (número de WhatsApp
  // configurable) + botón flotante del carrito.
  function boot() {
    Cart.initFab();
    loadSettings();
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', boot);
  else boot();

  return {
    ONLINE_PAYMENTS_ENABLED,
    get WA_NUMBER() { return WA_NUMBER; },
    PLACEHOLDER, CATS, CAT_BY_SLUG, catLabel, catVisual, waLink,
    loadProducts, createCard, skeletons, initCarousel, initReveal, stagger,
    initCounters, animateCount, initScrollProgress,
    loadSettings, loadContent, applyContent, syncWaLinks, isValidPrice, effectivePrice, hasPrice, fmtPrice,
    isAvailable, track, Cart
  };
})();
