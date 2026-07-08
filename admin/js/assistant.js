/* ============================================================
   Asistente MH — copiloto del panel de Mundo Hogar
   ------------------------------------------------------------
   V1 (esta versión): responde con DATOS REALES del negocio
   usando la sesión del usuario (respeta RLS) + guías de uso.
   Solo LEE datos; nunca modifica nada.

   V2 (opcional): si la Edge Function "asistente" está desplegada
   en Supabase (ver GUIA-ASISTENTE-IA.md), las preguntas libres
   se responden con IA (Claude). Este archivo la detecta solo.
   ============================================================ */
window.MHAssistant = (function () {
  let panel = null;
  let cache = { data: null, ts: 0 };
  let iaDisponible = null; // null = sin probar, true/false tras el ping
  let ocupado = false;

  /* ── Sección actual (para ayuda contextual) ── */
  function seccion() {
    const p = location.pathname;
    if (p.includes('dashboard'))     return 'dashboard';
    if (p.includes('solicitudes'))   return 'solicitudes';
    if (p.includes('producto-form')) return 'producto-form';
    if (p.includes('productos'))     return 'productos';
    if (p.includes('categorias'))    return 'categorias';
    if (p.includes('inventario'))    return 'inventario';
    if (p.includes('movimientos'))   return 'movimientos';
    if (p.includes('alertas'))       return 'alertas';
    if (p.includes('usuarios'))      return 'usuarios';
    if (p.includes('configuracion')) return 'configuracion';
    return 'panel';
  }

  /* ── Datos del negocio (solo lectura, cache 60s) ── */
  async function datos() {
    if (cache.data && Date.now() - cache.ts < 60000) return cache.data;
    const [prodRes, solRes, movRes] = await Promise.all([
      db.from('productos').select('id,nombre,estado,stock_actual,stock_minimo,precio_minorista,imagen_principal_url,categoria_id,destacado,en_oferta'),
      db.from('solicitudes').select('id,estado,cliente_nombre,codigo,created_at').order('created_at', { ascending: false }).limit(100),
      db.from('movimientos_inventario').select('id,tipo,cantidad,created_at,productos(nombre)').gte('created_at', new Date(Date.now() - 7 * 864e5).toISOString()).order('created_at', { ascending: false }).limit(50)
    ]);
    const productos = prodRes.data || [];
    const activos = productos.filter(p => p.estado === 'activo');
    const d = {
      productos, activos,
      total: productos.length,
      nActivos: activos.length,
      sinPrecio: activos.filter(p => !(p.precio_minorista > 0)),
      sinImagen: activos.filter(p => !p.imagen_principal_url),
      sinCategoria: activos.filter(p => !p.categoria_id),
      sinStock: activos.filter(p => p.stock_actual <= 0),
      stockBajo: activos.filter(p => p.stock_actual > 0 && p.stock_minimo > 0 && p.stock_actual <= p.stock_minimo),
      destacados: activos.filter(p => p.destacado),
      solicitudes: solRes.error ? [] : (solRes.data || []),
      movimientos: movRes.error ? [] : (movRes.data || [])
    };
    d.nuevas = d.solicitudes.filter(s => s.estado === 'nueva');
    d.incompletos = d.activos.filter(p => !(p.precio_minorista > 0) || !p.imagen_principal_url || !p.categoria_id);
    cache = { data: d, ts: Date.now() };
    return d;
  }

  const esc = s => String(s == null ? '' : s).replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
  const listado = (arr, max = 6) => '<ul>' + arr.slice(0, max).map(p => `<li>${esc(p.nombre)}</li>`).join('') + (arr.length > max ? `<li>… y ${arr.length - max} más</li>` : '') + '</ul>';
  const link = (href, txt) => `<a class="btn btn-outline btn-sm asst-mini" href="${href}">${txt}</a>`;

  /* ── Respuestas con datos reales ── */
  const R = {
    async resumen() {
      const d = await datos();
      let h = `<b>Resumen del negocio:</b><ul>`;
      h += `<li><b>${d.nActivos}</b> productos activos (${d.total} en total)</li>`;
      h += `<li><b>${d.nActivos - d.sinPrecio.length}</b> con precio cargado · <b>${d.sinPrecio.length}</b> sin precio</li>`;
      h += `<li><b>${d.destacados.length}</b> destacados en portada</li>`;
      h += `<li><b>${d.nuevas.length}</b> solicitudes sin atender (${d.solicitudes.length} totales)</li>`;
      h += `<li><b>${d.movimientos.length}</b> movimientos de stock en 7 días</li></ul>`;
      const prioridad = d.nuevas.length ? 'respondé las solicitudes nuevas' : d.sinPrecio.length ? 'cargá los precios que faltan' : 'revisá el stock';
      h += `Lo primero que conviene atender: <b>${prioridad}</b>.`;
      h += '<br>' + (d.nuevas.length ? link('/admin/solicitudes.html?estado=nueva', '💬 Ver solicitudes') : link('/admin/productos.html?precio=sin', '💲 Cargar precios'));
      return h;
    },
    async sinPrecio() {
      const d = await datos();
      if (!d.sinPrecio.length) return '¡Excelente! Todos los productos activos tienen precio cargado. ✅';
      return `Hay <b>${d.sinPrecio.length} productos sin precio</b> (se muestran como "Consultar precio" en la tienda):${listado(d.sinPrecio)}${link('/admin/productos.html?precio=sin', '💲 Verlos y cargar precios')}`;
    },
    async sinImagen() {
      const d = await datos();
      if (!d.sinImagen.length) return 'Todos los productos activos tienen imagen. ✅';
      return `Hay <b>${d.sinImagen.length} productos sin imagen</b>:${listado(d.sinImagen)}${link('/admin/productos.html?imagen=sin', '🖼️ Verlos')}`;
    },
    async incompletos() {
      const d = await datos();
      if (!d.incompletos.length) return 'No hay productos incompletos: todos tienen precio, imagen y categoría. ✅';
      return `Hay <b>${d.incompletos.length} productos incompletos</b> (les falta precio, imagen o categoría):${listado(d.incompletos)}${link('/admin/productos.html?incompletos=1', '⚠️ Ver incompletos')}`;
    },
    async stock() {
      const d = await datos();
      if (!d.sinStock.length && !d.stockBajo.length) return 'No hay alertas de stock. Todos los productos con seguimiento están en niveles correctos. ✅';
      let h = '';
      if (d.sinStock.length) h += `<b>${d.sinStock.length} sin stock</b> (crítico):${listado(d.sinStock, 5)}`;
      if (d.stockBajo.length) h += `<b>${d.stockBajo.length} con stock bajo</b>:${listado(d.stockBajo, 5)}`;
      h += `Para reponer: registrá una <b>entrada por compra</b> desde Inventario.${link('/admin/alertas.html', '🔔 Ver alertas')}${link('/admin/inventario.html', '📥 Registrar entrada')}`;
      return h;
    },
    async solicitudes() {
      const d = await datos();
      if (!d.solicitudes.length) return 'Todavía no hay solicitudes. Cuando un cliente envíe un pedido desde la tienda, aparecen en la sección Solicitudes. 💬';
      let h = `Hay <b>${d.nuevas.length} solicitudes sin atender</b> de ${d.solicitudes.length} totales.`;
      if (d.nuevas.length) {
        h += '<ul>' + d.nuevas.slice(0, 5).map(s => `<li>${esc(s.cliente_nombre)} (${esc(s.codigo)})</li>`).join('') + '</ul>';
        h += 'Consejo: responder dentro de la primera hora aumenta mucho las chances de cerrar la venta.';
      }
      return h + link('/admin/solicitudes.html?estado=nueva', '💬 Responder ahora');
    },
    async movimientos() {
      const d = await datos();
      if (!d.movimientos.length) return 'No se registraron movimientos de stock en los últimos 7 días. Se registran desde <b>Registrar Movimiento</b>.' + link('/admin/inventario.html', '📦 Registrar');
      const entradas = d.movimientos.filter(m => ['carga_inicial', 'entrada_compra', 'ajuste_positivo', 'devolucion_cliente'].includes(m.tipo)).length;
      return `En los últimos 7 días hubo <b>${d.movimientos.length} movimientos</b> (${entradas} entradas, ${d.movimientos.length - entradas} salidas/ajustes). Los últimos:<ul>${d.movimientos.slice(0, 5).map(m => `<li>${esc(m.productos?.nombre || '—')} · ${esc(m.tipo.replace(/_/g, ' '))}</li>`).join('')}</ul>${link('/admin/movimientos.html', '📋 Ver historial')}`;
    },
    async destacados() {
      const d = await datos();
      let h = `Tenés <b>${d.destacados.length} productos destacados</b> (aparecen en la portada de la tienda).`;
      const candidatos = d.activos.filter(p => p.precio_minorista > 0 && p.imagen_principal_url && !p.destacado);
      if (d.destacados.length < 12 && candidatos.length) {
        h += ` Te conviene tener 8–12. Hay <b>${candidatos.length} candidatos ideales</b> (con precio e imagen):${listado(candidatos, 5)}`;
        h += 'Para destacar: en Productos, tocá la <b>estrella ⭐</b> del producto.';
      }
      return h + link('/admin/productos.html', '🛍️ Ir a Productos');
    },
    async categoriasVacias() {
      const { data: cats } = await db.from('categorias').select('id,nombre');
      const d = await datos();
      const vacias = (cats || []).filter(c => !d.productos.some(p => p.categoria_id === c.id));
      if (!vacias.length) return 'Todas las categorías tienen productos. ✅';
      return `Hay <b>${vacias.length} categorías vacías</b>: ${vacias.map(c => esc(c.nombre)).join(', ')}. Asignales productos o desactivalas.${link('/admin/categorias.html', '🏷️ Ver categorías')}`;
    }
  };

  /* ── Guías de uso (base de conocimiento) ── */
  const GUIAS = [
    { k: /(cargo|creo|agrego|añado|nuevo).*(producto)|producto nuevo/i, t: 'Para <b>crear un producto</b>: Productos → "+ Nuevo Producto". Completá nombre, categoría, precio minorista y stock inicial, subí la foto (clic o arrastrar) y Guardar. Con "Destacado" activado aparece en la portada.' + link('/admin/producto-form.html', '+ Crear producto') },
    { k: /(edito|cambio|modifico).*(precio|producto)|precio.*(cambiar|editar|cargar|poner)/i, t: 'Para <b>cambiar un precio</b>: Productos → lápiz ✏️ del producto → campo "Precio minorista" (número sin puntos, ej: 234000) → Guardar. El cambio se ve al instante en la tienda.' + link('/admin/productos.html', '🛍️ Ir a Productos') },
    { k: /(creo|agrego|nueva).*(categor)/i, t: 'Para <b>crear una categoría</b>: Categorías → completá el nombre (el slug se genera solo) → Guardar. Después asignásela a los productos desde su formulario.' + link('/admin/categorias.html', '🏷️ Ir a Categorías') },
    { k: /(registro|cargo|hago).*(movimiento|stock|entrada|salida)|reponer stock|sumar stock/i, t: 'Para <b>registrar stock</b>: Registrar Movimiento → elegí el tipo (entrada por compra, salida por venta, ajuste…) → buscá el producto → cantidad. Vas a ver el "antes → después" antes de confirmar. Todo queda en el Historial.' + link('/admin/inventario.html', '📦 Registrar movimiento') },
    { k: /(subo|cambio|agrego).*(imagen|foto)/i, t: 'Para <b>subir una imagen</b>: Productos → ✏️ del producto → sección "Imagen principal" → hacé clic o arrastrá el archivo (JPG/PNG/WebP, máx. 5 MB) → Guardar.' },
    { k: /no aparece|no se ve|no se muestra/i, t: 'Si un producto <b>no aparece en la tienda</b>, revisá: 1) Estado = "Activo" (inactivo/archivado no se muestran), 2) que tenga categoría asignada, 3) recargá la página de la tienda. Si sigue sin verse, decime el nombre y lo reviso.' },
    { k: /(oculto|pauso|desactivo|publico).*(producto)/i, t: 'Para <b>ocultar/publicar</b> un producto rápido: en Productos usá el botón ⏸️/▶️ de la fila. Ocultar no borra nada: lo podés volver a publicar cuando quieras.' },
    { k: /oferta|descuento|promoci/i, t: 'Para <b>crear una oferta</b>: editá el producto → activá "En oferta" → cargá el "Precio oferta" (menor al minorista). En la tienda aparece el precio anterior tachado y la etiqueta Oferta.' },
    { k: /whatsapp.*(cambio|numero|número)|numero.*whatsapp/i, t: 'Para <b>cambiar el número de WhatsApp</b> de toda la tienda: Configuración → "WhatsApp" → guardá. Todos los botones de la web pasan a usar el número nuevo al instante.' + link('/admin/configuracion.html', '⚙️ Ir a Configuración') },
    { k: /texto|portada|titulo|título|hero/i, t: 'Los <b>textos de la portada</b> (título, subtítulo, sección mayorista, envíos, pagos) se editan desde Configuración → "Textos de la página". En el título, usá "|" antes de la parte que va en naranja.' + link('/admin/configuracion.html', '⚙️ Editar textos') },
    { k: /usuario|vendedor|empleado|acceso/i, t: 'Para <b>dar acceso a otra persona</b>: Usuarios → invitala con su email y elegí el rol (Administrador: todo · Encargado de stock: productos y stock · Vendedor: solo consulta y solicitudes).' + link('/admin/usuarios.html', '👥 Ir a Usuarios') },
    { k: /alerta.*(significa|explic)|significa.*alerta|que es.*alerta/i, t: 'Las <b>alertas de stock</b> avisan cuando un producto llega a 0 (crítico, rojo) o queda por debajo de su "stock mínimo" (bajo, amarillo). El stock mínimo lo definís en cada producto; cuando se cruza, aparece acá y en el Dashboard.' },
    { k: /instalar|app|escritorio|acceso directo/i, t: 'El panel se puede <b>instalar como app</b>: en Chrome, menú ⋮ → "Instalar Mundo Hogar — Administrador". Queda con el logo en el escritorio y abre directo al panel.' }
  ];

  /* ── Sugerencias por sección ── */
  const SUGERENCIAS = {
    dashboard:     ['¿Qué necesita atención?', '¿Qué productos no tienen precio?', '¿Hay solicitudes pendientes?'],
    productos:     ['¿Qué productos están incompletos?', '¿Cómo cargo un precio?', '¿Qué debería destacar?'],
    'producto-form': ['¿Cómo subo la imagen?', '¿Cómo creo una oferta?', '¿Qué es el stock mínimo?'],
    categorias:    ['¿Hay categorías vacías?', '¿Cómo creo una categoría?'],
    inventario:    ['¿Cómo registro una entrada?', '¿Qué productos hay que reponer?'],
    movimientos:   ['¿Qué movimientos hubo esta semana?', '¿Cómo corrijo un stock mal cargado?'],
    alertas:       ['¿Qué significa cada alerta?', '¿Qué debería reponer primero?'],
    solicitudes:   ['¿Cuántas solicitudes hay sin atender?', '¿Cómo respondo una solicitud?'],
    usuarios:      ['¿Cómo agrego un vendedor?', '¿Qué puede hacer cada rol?'],
    configuracion: ['¿Cómo cambio el WhatsApp?', '¿Cómo edito los textos de la portada?'],
    panel:         ['Resumime el estado del negocio', '¿Qué necesita atención?']
  };

  /* ── Motor de intenciones ── */
  async function responder(q) {
    const t = q.toLowerCase();
    if (/resumen|estado (del|de mi) negocio|como (va|anda|está|esta) (todo|el negocio)|atenci[oó]n|revisar primero|qu[eé] (debo|deber[ií]a|tengo que) (hacer|revisar)/.test(t)) return R.resumen();
    if (/sin precio|falta[n]? .*precio|precio.*falta/.test(t)) return R.sinPrecio();
    if (/sin (imagen|foto)|falta[n]? .*(imagen|foto)/.test(t)) return R.sinImagen();
    if (/incomplet/.test(t)) return R.incompletos();
    if (/stock (cr[ií]tico|bajo)|sin stock|reponer|reposici[oó]n|agotado/.test(t)) return R.stock();
    if (/solicitud|pedido.*pendiente|clientes (esperando|sin)/.test(t)) return R.solicitudes();
    if (/movimiento|actividad.*(semana|d[ií]as)|(semana|hoy).*movimiento/.test(t)) return R.movimientos();
    if (/destaca/.test(t)) return R.destacados();
    if (/categor[ií]a.*vac[ií]a|vac[ií]a.*categor/.test(t)) return R.categoriasVacias();
    for (const g of GUIAS) if (g.k.test(q)) return g.t;

    // Sin coincidencia local → probar IA (si está activada)
    const ia = await preguntarIA(q);
    if (ia) return ia;
    return 'No tengo una respuesta preparada para eso todavía 🤔. Probá con una de las sugerencias, o preguntame por: <b>precios faltantes, stock, solicitudes, destacados, cómo crear productos/categorías/ofertas, textos de la portada o usuarios</b>.<br><span style="font-size:11.5px;color:var(--muted)">💡 Las preguntas libres se responden con IA cuando se activa la Función "asistente" (ver GUIA-ASISTENTE-IA.md).</span>';
  }

  /* ── IA opcional (Edge Function "asistente") ── */
  async function preguntarIA(pregunta) {
    try {
      if (iaDisponible === false) return null;
      const { data: { session } } = await db.auth.getSession();
      if (!session) return null;
      const d = await datos();
      const contexto = {
        seccion: seccion(),
        resumen: {
          productos_activos: d.nActivos, sin_precio: d.sinPrecio.length, sin_imagen: d.sinImagen.length,
          sin_stock: d.sinStock.length, stock_bajo: d.stockBajo.length, destacados: d.destacados.length,
          solicitudes_nuevas: d.nuevas.length, solicitudes_total: d.solicitudes.length,
          movimientos_7d: d.movimientos.length
        }
      };
      const res = await fetch(`${SUPABASE_URL}/functions/v1/asistente`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', apikey: SUPABASE_ANON_KEY, Authorization: `Bearer ${session.access_token}` },
        body: JSON.stringify({ pregunta, contexto })
      });
      if (!res.ok) { iaDisponible = false; return null; }
      iaDisponible = true;
      const json = await res.json();
      return json.respuesta ? esc(json.respuesta).replace(/\n/g, '<br>') : null;
    } catch (e) { iaDisponible = false; return null; }
  }

  /* ── UI ── */
  function agregarMsg(html, who) {
    const body = panel.querySelector('.mh-asst-body');
    const el = document.createElement('div');
    el.className = 'asst-msg ' + who;
    el.innerHTML = html;
    body.appendChild(el);
    body.scrollTop = body.scrollHeight;
    return el;
  }

  async function enviar(texto) {
    if (!texto.trim() || ocupado) return;
    ocupado = true;
    agregarMsg(esc(texto), 'user');
    const typing = agregarMsg('<span class="asst-typing"><span></span><span></span><span></span></span>', 'bot');
    try {
      const resp = await responder(texto);
      typing.innerHTML = resp;
    } catch (e) {
      typing.innerHTML = 'Uy, no pude consultar los datos (¿problema de conexión?). Probá de nuevo en un momento.';
    }
    panel.querySelector('.mh-asst-body').scrollTop = panel.querySelector('.mh-asst-body').scrollHeight;
    ocupado = false;
  }

  function abrirPanel() {
    if (panel) { panel.remove(); panel = null; return; }
    panel = document.createElement('div');
    panel.className = 'mh-asst-panel';
    const sugs = SUGERENCIAS[seccion()] || SUGERENCIAS.panel;
    panel.innerHTML = `
      <div class="mh-asst-head">
        <span class="asst-avatar">✨</span>
        <div><b>Asistente MH</b><span class="asst-status">Conectado a tu negocio</span></div>
        <button class="asst-close" aria-label="Cerrar">✕</button>
      </div>
      <div class="mh-asst-body"></div>
      <div class="mh-asst-sug">${sugs.map(s => `<button class="asst-chip">${s}</button>`).join('')}</div>
      <div class="mh-asst-input">
        <input type="text" placeholder="Preguntame algo del negocio…" aria-label="Pregunta al asistente">
        <button aria-label="Enviar">➤</button>
      </div>`;
    document.body.appendChild(panel);
    agregarMsg('¡Hola! Soy el <b>Asistente MH</b> 👋. Puedo mostrarte el estado real del negocio (stock, precios, solicitudes) y explicarte cómo usar cada parte del panel. ¿En qué te ayudo?', 'bot');

    const input = panel.querySelector('input');
    panel.querySelector('.asst-close').onclick = () => { panel.remove(); panel = null; };
    panel.querySelector('.mh-asst-input button').onclick = () => { const v = input.value; input.value = ''; enviar(v); };
    input.addEventListener('keydown', e => { if (e.key === 'Enter') { const v = input.value; input.value = ''; enviar(v); } });
    panel.querySelectorAll('.asst-chip').forEach(c => c.addEventListener('click', () => enviar(c.textContent)));
    input.focus();
  }

  async function init() {
    // Solo en páginas del panel con sesión iniciada (nunca en el login)
    if (!window.db || location.pathname.replace(/\/$/, '').endsWith('/admin') || location.pathname.endsWith('/admin/index.html')) return;
    const { data: { session } } = await db.auth.getSession();
    if (!session) return;
    const fab = document.createElement('button');
    fab.id = 'mh-asst-fab';
    fab.setAttribute('aria-label', 'Abrir Asistente MH');
    fab.setAttribute('data-tip', 'Asistente MH');
    fab.textContent = '✨';
    fab.onclick = abrirPanel;
    document.body.appendChild(fab);
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init);
  else init();

  return { open: () => { if (!panel) abrirPanel(); }, seccion };
})();
