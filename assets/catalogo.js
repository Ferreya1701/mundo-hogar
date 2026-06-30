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
    { slug:'electrodomesticos',     label:'Electrodomésticos',     desc:'Heladeras, cocinas, lavarropas, freidoras de aire y más.', img:'/images/productos/electrodomesticos/IMG_1440.jpg' },
    { slug:'herramientas',          label:'Herramientas',          desc:'Taladros, amoladoras, soldadoras y herramientas INGCO.',   img:'/images/productos/herramientas/atornilladora-21-01.jpg' },
    { slug:'tecnologia-celulares',  label:'Tecnología y Celulares',desc:'Celulares, Smart TV, parlantes, auriculares y cámaras.',   img:'/images/productos/tecnologia-celulares/motorola-moto-g05.jpg' },
    { slug:'muebles-hogar',         label:'Muebles y Hogar',       desc:'Colchones, sillas, sofás, termos y bazar.',                img:'/images/productos/muebles-hogar/IMG_0053.jpg' },
    { slug:'cuidado-personal',      label:'Cuidado Personal',      desc:'Secadores, planchitas, recortadoras y más.',               img:'/images/productos/cuidado-personal/IMG_0314.jpg' },
    { slug:'salud',                 label:'Salud',                 desc:'Tensiómetros, nebulizadores y balanzas.',                  img:'/images/productos/salud/IMG_0572.jpg' },
    { slug:'seguridad',             label:'Seguridad',             desc:'Cerraduras inteligentes para tu hogar.',                   img:'/images/productos/seguridad/cerradura-02.jpg' }
  ];
  const CAT_BY_SLUG = Object.fromEntries(CATS.map(c => [c.slug, c]));
  const catLabel = s => (CAT_BY_SLUG[s] && CAT_BY_SLUG[s].label) || s;
  const catIcon = s => ICONS[s] || '';

  const waLink = (text) => `https://wa.me/${WA_NUMBER}?text=${encodeURIComponent(text)}`;

  let _cache = null;
  async function loadProducts() {
    if (_cache) return _cache;
    const res = await fetch(DATA_URL, { cache: 'no-cache' });
    const data = await res.json();
    const activos = data.productos.filter(p => p.activo !== false);
    // marcar novedades: las de mayor "orden" (últimas cargadas)
    const ordenMax = Math.max(...activos.map(p => p.orden || 0));
    activos.forEach(p => { p._nuevo = (p.orden || 0) > ordenMax - 18; });
    _cache = activos;
    return activos;
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
  function initReveal() {
    const els = document.querySelectorAll('.reveal');
    if (!('IntersectionObserver' in window) || !els.length) { els.forEach(e => e.classList.add('in')); return; }
    const io = new IntersectionObserver((entries) => {
      entries.forEach(en => { if (en.isIntersecting) { en.target.classList.add('in'); io.unobserve(en.target); } });
    }, { threshold: 0.12 });
    els.forEach(e => io.observe(e));
  }

  return { WA_NUMBER, PLACEHOLDER, CATS, CAT_BY_SLUG, catLabel, catIcon, waLink, loadProducts, createCard, skeletons, initCarousel, initReveal };
})();
