# Informe: Panel premium + Asistente MH (2026-07-08)

## 1. Resumen ejecutivo

El panel de administración pasó de la paleta vieja dorado/negro a la **identidad real de Mundo Hogar** (azul institucional + naranja, violeta reservado para IA), el dashboard se convirtió en un **centro de control** con salud del catálogo accionable, productos ahora comunica **completitud** de cada ficha, solicitudes funciona como un **mini-CRM** con generador de respuestas, y se integró el **Asistente MH**: un copiloto contextual que responde con datos reales del negocio y queda preparado para IA (Claude) con una activación de 10 minutos.

No se rompió ninguna función existente, no se tocaron tablas de la base, no hay claves privadas en el frontend.

## 2. Archivos modificados / creados

| Archivo | Cambio |
|---|---|
| `admin/css/admin.css` | Rebrand completo + skeletons, tooltips `[data-tip]`, chips, botones con microinteracciones, estilos del asistente, `prefers-reduced-motion` |
| `admin/js/utils.js` | Helpers `skelRows`, `skelKpis`, `copy()` (portapapeles con toast) |
| `admin/js/assistant.js` | **NUEVO** — Asistente MH completo (~370 líneas) |
| `admin/dashboard.html` | 6 KPIs clickeables, Salud del catálogo (% + problemas + botones), acciones rápidas, recomendaciones, actividad combinada, alertas con reposición 1-clic |
| `admin/productos.html` | Filtros por URL, "Más filtros" (sin precio/imagen/categoría, destacados, oferta, incompletos), orden por precio/stock/recientes, badges de completitud, ⭐ destacar con 1 clic, precio de oferta tachado |
| `admin/categorias.html` | Badge "Vacía", botón ver productos de la categoría |
| `admin/alertas.html` | "📥 Entrada" lleva a Inventario con el producto ya seleccionado |
| `admin/inventario.html` | Lee `?producto=ID` y preselecciona (foco directo en cantidad) |
| `admin/solicitudes.html` | Chips por estado con conteos, filtro `?estado=`, generador de respuestas de WhatsApp (3 plantillas con datos reales del pedido, editable, copiar / abrir WhatsApp) |
| `supabase/functions/asistente/index.ts` | **NUEVO** — Edge Function con Claude (lista para desplegar) |
| `GUIA-ASISTENTE-IA.md` | **NUEVO** — guía de activación de la IA |
| Todas las páginas del panel | `<script assistant.js>` inyectado (excepto login) |

Commits: `improve: rebrand…`, `feat: dashboard centro de control…`, `feat: solicitudes mini-CRM…`, `feat: Asistente MH…`, `fix: skeletons…`. Todo pusheado y desplegado en Vercel.

## 3. El Asistente MH

**Qué hace hoy (sin costo, ya en producción):**
- Botón flotante violeta ✨ en todas las páginas del panel (nunca en el login; solo con sesión iniciada).
- Responde con **datos reales** (usa la sesión del usuario → respeta RLS, solo lectura): resumen del negocio, productos sin precio/imagen/categoría, incompletos, stock crítico y bajo, solicitudes pendientes, destacados (con candidatos sugeridos), movimientos de 7 días, categorías vacías.
- **Guías de uso** de cada sección (crear producto, ofertas, cambiar WhatsApp, textos de portada, usuarios, etc.), con botones que llevan directo a la pantalla correcta.
- **Sugerencias contextuales** según la página en la que está el usuario.
- **No modifica nada**: es 100% de lectura + navegación.

**Qué agrega la IA cuando se active** (ver `GUIA-ASISTENTE-IA.md`): las preguntas libres pasan a responderse con Claude (modelo Haiku, costo ínfimo), usando un resumen numérico del negocio como contexto. El frontend la detecta solo — cero cambios de código.

**Seguridad de la IA:** API key como secreto en Supabase (nunca en el navegador), verificación de sesión (401 para anónimos), solo recibe cantidades (no datos de clientes), sin acceso de escritura, límites de tamaño por pregunta y respuesta.

## 4. Decisiones tomadas (y por qué)

- **Kanban en Solicitudes: NO.** Con el volumen actual, tabla + chips de estado es más rápida y clara que un tablero drag-and-drop; el pipeline de 7 estados ya existe en el select de cada fila. Queda como mejora futura si el volumen crece.
- **Historial del chat IA: NO persistido.** Más privado, cero tablas nuevas, cero riesgo. El esquema `ai_conversations/ai_messages/ai_actions_log` queda documentado en la guía para cuando se justifique.
- **Buscador global Ctrl+K: pospuesto.** El Asistente cubre el caso de uso ("buscá X", "llevame a Y") con lenguaje natural; un command-palette duplicaría esfuerzo ahora.
- **Generación de descripciones con IA: pospuesta a V2.** Sin LLM sería solo una plantilla genérica (baja calidad); cuando se active la Edge Function se agrega ahí.
- **Modo oscuro: no incluido** — el cliente no lo pidió y duplica el costo de mantenimiento visual.

## 5. Cómo probar (con tu usuario admin)

1. **Login**: `https://mundo-hogar-tan.vercel.app/admin/` — pantalla azul/naranja de marca.
2. **Dashboard**: KPIs nuevos (clic en "Sin precio" → lista filtrada), Salud del catálogo con % y botones, recomendaciones reales.
3. **Productos**: probar "Más filtros" → Sin precio; ordenar por precio; tocar la ⭐ de un producto (queda destacado en la portada de la tienda al instante).
4. **Solicitudes**: chips de estado arriba; entrar a una solicitud → "✨ Respuesta sugerida" → elegir plantilla → Copiar o Abrir WhatsApp.
5. **Alertas**: botón "📥 Entrada" → llega a Inventario con el producto ya elegido.
6. **Asistente**: botón ✨ → "¿Qué necesita atención?" / "¿Qué productos no tienen precio?" / "¿Cómo creo una oferta?".

## 6. Variables/config necesarias

- Hoy: **ninguna nueva**. Todo funciona con `supabase-config.js` (clave publishable, pública por diseño).
- Para activar IA: secreto `ANTHROPIC_API_KEY` en Supabase Edge Functions + deploy de la función `asistente` (guía incluida).

## 7. Limitaciones conocidas

- El Asistente V1 responde por intenciones (palabras clave): preguntas muy libres devuelven la lista de temas disponibles hasta que se active la IA.
- No pude verificar visualmente las pantallas internas logueado (no tengo credenciales — correcto); verifiqué sintaxis de todo el JS, guardas de auth, consola limpia y el login en vivo. **Recomendado: una pasada tuya logueado para confirmar el look nuevo.**
- La IA (V2) requiere API key con crédito de Anthropic: decisión comercial de Tomás/Nicolás.

## 8. Próximas mejoras recomendadas

1. **Activar la IA** (10 min + API key) — el diferencial "wow" para la entrega.
2. Generación de descripciones de producto con IA (extensión de la misma función).
3. Galería multi-imagen por producto (la tabla `producto_imagenes` ya existe).
4. Kanban de solicitudes si el volumen supera ~30/semana.
5. Dominio propio + Analytics (pendientes de la lista general del proyecto).
