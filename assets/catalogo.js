/* ============================================================
   Mundo Hogar — Lógica compartida del catálogo
   ============================================================ */
window.MH = (function () {
  const WA_NUMBER = '5493426481326';
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

  let _cache = null;

  // Trae los productos desde Supabase (fuente en vivo, editable desde el panel).
  // Si Supabase falla por algún motivo, usa el catálogo estático como respaldo.
  async function loadFromSupabase() {
    const url = window.SUPABASE_URL;
    const key = window.SUPABASE_PUBLISHABLE_KEY || window.SUPABASE_ANON_KEY;
    if (!url || !key) return null;
    const endpoint = `${url}/rest/v1/productos?select=id,nombre,slug,descripcion,imagen_principal_url,destacado,es_nuevo,orden,categorias(slug)&estado=eq.activo&order=orden.asc`;
    const res = await fetch(endpoint, { headers: { apikey: key, Authorization: `Bearer ${key}` } });
    if (!res.ok) throw new Error('Supabase respondió ' + res.status);
    const rows = await res.json();
    return rows.map(p => ({
      id: p.slug,
      orden: p.orden,
      nombre: p.nombre,
      imagen: p.imagen_principal_url,
      alt: p.nombre,
      descripcion: p.descripcion,
      categoria: p.categorias ? p.categorias.slug : null,
      slug: p.slug,
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

  // Crea la tarjeta de producto (DOM) con fallback de imagen y CTA WhatsApp
  function createCard(p) {
    const file = p.imagen ? p.imagen.split('/').pop() : '';
    const url = p.imagen || PLACEHOLDER;
    const card = document.createElement('article');
    card.className = 'mh-card';
    card.dataset.category = p.categoria;
    const badges = [];
    if (p.destacado) badges.push('<span class="badge badge-dest">Destacado</span>');
    if (p._nuevo) badges.push('<span class="badge badge-new">Nuevo</span>');
    const wa = waLink(`Hola! Me interesa ${p.nombre}. ¿Tienen stock y precio?`);
    card.innerHTML = `
      <div class="mh-card-imgwrap">
        ${badges.length ? `<div class="mh-badges">${badges.join('')}</div>` : ''}
        <img alt="${(p.alt || p.nombre || '').replace(/"/g,'&quot;')}" loading="lazy" decoding="async">
      </div>
      <div class="mh-card-body">
        <div class="mh-card-cat">${catLabel(p.categoria)}</div>
        <h3 class="mh-card-title">${p.nombre || ''}</h3>
        ${p.descripcion ? `<p class="mh-card-desc">${p.descripcion}</p>` : ''}
        <div class="mh-card-cta">
          <a class="btn btn-primary btn-sm" href="${wa}" target="_blank" rel="noopener"
             aria-label="Consultar precio de ${(p.nombre||'').replace(/"/g,'&quot;')} por WhatsApp">
            Consultar precio
          </a>
        </div>
      </div>`;
    const img = card.querySelector('img');
    img.onerror = function () { this.onerror = null; this.src = PLACEHOLDER; };
    img.src = url;
    return card;
  }

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

  return {
    WA_NUMBER, PLACEHOLDER, CATS, CAT_BY_SLUG, catLabel, catVisual, waLink,
    loadProducts, createCard, skeletons, initCarousel, initReveal, stagger,
    initCounters, animateCount, initScrollProgress
  };
})();
