/* ============================================================
   Mundo Hogar — Lógica compartida del catálogo
   ============================================================ */
window.MH = (function () {
  const WA_NUMBER = '5493426481326';
  const DATA_URL = '/src/data/productos.json';
  const PLACEHOLDER = "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 400 400'%3E%3Crect width='400' height='400' fill='%23F4F7FC'/%3E%3Ctext x='200' y='190' font-family='Plus Jakarta Sans,Arial,sans-serif' font-size='52' font-weight='800' fill='%231763C6' text-anchor='middle'%3EMH%3C/text%3E%3Ctext x='200' y='230' font-family='Arial,sans-serif' font-size='15' fill='%235A6B85' text-anchor='middle'%3EImagen no disponible%3C/text%3E%3C/svg%3E";

  // Iconos de categoría (line icons)
  const ICONS = {
    electrodomesticos:'<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><rect x="5" y="2" width="14" height="20" rx="2"/><line x1="5" y1="9" x2="19" y2="9"/><line x1="8" y1="5.5" x2="8" y2="6"/><line x1="8" y1="13" x2="8" y2="16"/></svg>',
    herramientas:'<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M14.7 6.3a4 4 0 0 0-5.4 5.3L3 18v3h3l6.4-6.4a4 4 0 0 0 5.3-5.4l-2.6 2.6-2.3-.6-.6-2.3 2.5-2.6z"/></svg>',
    'tecnologia-celulares':'<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><rect x="6" y="2" width="12" height="20" rx="2.5"/><line x1="11" y1="18" x2="13" y2="18"/></svg>',
    'muebles-hogar':'<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M4 11V8a2 2 0 0 1 2-2h12a2 2 0 0 1 2 2v3"/><path d="M3 12a2 2 0 0 1 2 2v3h14v-3a2 2 0 0 1 2-2"/><line x1="5" y1="20" x2="5" y2="17"/><line x1="19" y1="20" x2="19" y2="17"/></svg>',
    'cuidado-personal':'<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><circle cx="6" cy="6" r="3"/><circle cx="6" cy="18" r="3"/><line x1="20" y1="4" x2="8.12" y2="15.88"/><line x1="14.47" y1="14.48" x2="20" y2="20"/><line x1="8.12" y1="8.12" x2="12" y2="12"/></svg>',
    salud:'<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M22 12h-4l-3 9L9 3l-3 9H2"/></svg>',
    seguridad:'<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="11" width="18" height="11" rx="2"/><path d="M7 11V7a5 5 0 0 1 10 0v4"/></svg>'
  };

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
  const catIcon = s => ICONS[s] || '';

  // Gradientes de marca por categoría (todos dentro de la paleta azul/naranja)
  const CAT_GRAD = {
    electrodomesticos:    'linear-gradient(135deg,#0A2E63 0%,#1763C6 100%)',
    herramientas:         'linear-gradient(135deg,#0E4AA0 0%,#0A2E63 100%)',
    'tecnologia-celulares':'linear-gradient(135deg,#0A2E63 0%,#2472DB 100%)',
    'muebles-hogar':      'linear-gradient(135deg,#0E4AA0 0%,#123B7D 100%)',
    'cuidado-personal':   'linear-gradient(135deg,#123B7D 0%,#1763C6 100%)',
    salud:                'linear-gradient(135deg,#0A2E63 0%,#0E4AA0 100%)',
    seguridad:            'linear-gradient(135deg,#081F45 0%,#123B7D 100%)'
  };

  // Íconos grandes tipo "marca de agua" — representan el rubro, no un producto puntual
  const BIG_ICONS = {
    electrodomesticos:'<svg viewBox="0 0 64 64" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><rect x="14" y="4" width="36" height="56" rx="4"/><line x1="14" y1="24" x2="50" y2="24"/><line x1="21" y1="12" x2="21" y2="15"/><line x1="21" y1="34" x2="21" y2="40"/><circle cx="43" cy="37" r="6"/><line x1="43" y1="33" x2="43" y2="37" transform="rotate(40 43 37)"/></svg>',
    herramientas:'<svg viewBox="0 0 64 64" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M40 12a10 10 0 0 0-13.8 12.7L7 44v9h9l19.3-19.3A10 10 0 0 0 48 24l-6.5 6.5-5.8-1.4-1.4-5.8L40 17z"/><circle cx="15" cy="49" r="2.4"/></svg>',
    'tecnologia-celulares':'<svg viewBox="0 0 64 64" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><rect x="20" y="5" width="24" height="54" rx="5"/><line x1="29" y1="50" x2="35" y2="50"/><path d="M12 22a24 24 0 0 1 6-9M52 22a24 24 0 0 0-6-9" stroke-dasharray="1 6.5"/></svg>',
    'muebles-hogar':'<svg viewBox="0 0 64 64" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M10 30v-8a6 6 0 0 1 6-6h32a6 6 0 0 1 6 6v8"/><path d="M6 32a4 4 0 0 1 4 4v10h44V36a4 4 0 0 1 4-4"/><line x1="10" y1="46" x2="10" y2="54"/><line x1="54" y1="46" x2="54" y2="54"/><line x1="20" y1="16" x2="20" y2="30"/><line x1="44" y1="16" x2="44" y2="30"/></svg>',
    'cuidado-personal':'<svg viewBox="0 0 64 64" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M8 14c8-6 20-8 30-2 10 6 14 18 10 26-3 6-10 8-15 4"/><ellipse cx="46" cy="34" rx="9" ry="7" transform="rotate(28 46 34)"/><line x1="14" y1="12" x2="8" y2="6"/><line x1="10" y1="20" x2="4" y2="18"/></svg>',
    salud:'<svg viewBox="0 0 64 64" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M8 34h9l5-12 8 22 6-16 4 6h12"/><path d="M32 54S12 43 12 27a11 11 0 0 1 20-6 11 11 0 0 1 20 6c0 16-20 27-20 27z" stroke-dasharray="0"/></svg>',
    seguridad:'<svg viewBox="0 0 64 64" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M32 6l20 8v14c0 15-9 24-20 30C21 52 12 43 12 28V14z"/><path d="M24 32a8 8 0 0 1 16 0v4"/><rect x="21" y="32" width="22" height="16" rx="3"/></svg>'
  };

  // Visual profesional de categoría: gradiente de marca + ícono grande (sin fotos de productos)
  function catVisual(slug) {
    const grad = CAT_GRAD[slug] || CAT_GRAD.electrodomesticos;
    const icon = BIG_ICONS[slug] || '';
    return `<div class="cat-visual" style="background:${grad}">
      <span class="cat-visual-blob" aria-hidden="true"></span>
      <span class="cat-visual-pattern" aria-hidden="true"></span>
      <span class="cat-visual-icon" aria-hidden="true">${icon}</span>
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
    WA_NUMBER, PLACEHOLDER, CATS, CAT_BY_SLUG, catLabel, catIcon, catVisual, waLink,
    loadProducts, createCard, skeletons, initCarousel, initReveal, stagger,
    initCounters, animateCount, initScrollProgress
  };
})();
