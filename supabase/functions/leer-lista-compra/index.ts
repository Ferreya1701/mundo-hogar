// ============================================================
// Edge Function "leer-lista-compra" — lectura de listas de compra
// ------------------------------------------------------------
// El panel (Compras → Nueva compra → "Leer con IA") manda la lista del
// proveedor tal como llegó: foto, PDF, o el texto de una planilla. La
// función se la da a Claude y pide SOLO los renglones normalizados:
// descripción original, nombre en español, código del proveedor,
// código de barras, cantidad y costo unitario. No crea nada: el panel
// muestra el resultado para revisarlo antes de cargar la compra.
//
// Quién puede llamarla: staff del panel con rol administrador o
// encargado_stock (se valida la sesión con la clave de servicio).
//
// Secretos en Supabase → Edge Functions → Secrets:
//   ANTHROPIC_API_KEY            (obligatoria; sin ella responde ia:false)
//   SUPABASE_SERVICE_ROLE_KEY    (la pone Supabase sola)
// Deploy: npx supabase functions deploy leer-lista-compra --project-ref <ref> --no-verify-jwt --use-api
// ============================================================
import { createClient } from "jsr:@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

// Opus 5: las listas de China vienen en inglés/chino, con columnas
// desordenadas y nombres que hay que traducir bien. Si el costo importa
// más que la calidad, se puede bajar a "claude-haiku-4-5" (hasta 10×
// más barato; conviene revisar más a mano).
const MODEL = "claude-opus-5";
const MAX_TOKENS = 24000;

const PROMPT = `Sos el asistente de un comercio de artículos para el hogar en Argentina que importa mercadería (sobre todo de China). Te paso la lista de un pedido de compra o de lo que llegó, tal como la mandó el proveedor (puede ser una planilla, una foto, un PDF, una factura proforma o un packing list; en inglés, chino o español).

Extraé TODOS los renglones de producto que haya en la lista. Para cada renglón:
- descripcion_original: el texto tal cual figura (modelo, nombre, especificación), sin inventar.
- nombre_es: un nombre corto y claro en español rioplatense, como lo pondría una tienda en su catálogo (ej: "Freidora de aire 5 L", "Taladro percutor 20V inalámbrico"). Incluí lo distintivo (medida, potencia, color) si figura. Sin marcas inventadas.
- sku_proveedor: el código, modelo o referencia que usa el proveedor para ese ítem (item no., model, SKU, 货号, 型号). null si no hay.
- codigo_barras: EAN/UPC si figura (solo dígitos). null si no hay.
- cantidad: unidades totales pedidas. Si la lista está en cajas y dice cuántas unidades trae cada caja, multiplicá y aclaralo en notas. Si no se puede saber, usá la cantidad que figura.
- costo_unitario: precio por unidad en la moneda de la lista, número con punto decimal. null si no figura.
- notas: aclaraciones breves (ej: "12 cajas × 6 u.", "precio por caja, dividido", "fila ilegible") o null.

Además, a nivel lista: moneda (código ISO de 3 letras si se deduce: USD, CNY, ARS, EUR; si no, null), proveedor (nombre si figura, si no null) y notas generales (qué no pudiste leer, totales que no cierran, etc.).

Reglas: no inventes renglones ni datos; lo que no está va en null. No incluyas filas de totales, flete, seguro, comisiones ni encabezados como renglones. Si la imagen no es una lista de productos, devolvé lineas vacías y explicalo en notas.`;

const SCHEMA = {
  type: "object",
  properties: {
    lineas: {
      type: "array",
      items: {
        type: "object",
        properties: {
          descripcion_original: { type: "string" },
          nombre_es: { type: "string" },
          sku_proveedor: { anyOf: [{ type: "string" }, { type: "null" }] },
          codigo_barras: { anyOf: [{ type: "string" }, { type: "null" }] },
          cantidad: { anyOf: [{ type: "integer" }, { type: "null" }] },
          costo_unitario: { anyOf: [{ type: "number" }, { type: "null" }] },
          notas: { anyOf: [{ type: "string" }, { type: "null" }] },
        },
        required: ["descripcion_original", "nombre_es", "sku_proveedor", "codigo_barras", "cantidad", "costo_unitario", "notas"],
        additionalProperties: false,
      },
    },
    moneda: { anyOf: [{ type: "string" }, { type: "null" }] },
    proveedor: { anyOf: [{ type: "string" }, { type: "null" }] },
    notas: { anyOf: [{ type: "string" }, { type: "null" }] },
  },
  required: ["lineas", "moneda", "proveedor", "notas"],
  additionalProperties: false,
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  const json = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });

  try {
    const url = Deno.env.get("SUPABASE_URL")!;
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const apiKey = Deno.env.get("ANTHROPIC_API_KEY");

    const body = await req.json().catch(() => ({}));
    if (body.ping) return json({ ok: true, ia: !!apiKey });

    // ── 1) Solo staff de stock logueado ──
    const admin = createClient(url, serviceKey, { auth: { persistSession: false } });
    const conSesion = createClient(url, anonKey, {
      auth: { persistSession: false },
      global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
    });
    const { data: { user } } = await conSesion.auth.getUser();
    if (!user) return json({ error: "no_autorizado" }, 401);
    const { data: perfil } = await admin.from("profiles").select("rol, activo").eq("id", user.id).maybeSingle();
    if (!perfil || !perfil.activo || !["administrador", "encargado_stock"].includes(perfil.rol)) {
      return json({ error: "no_autorizado" }, 401);
    }
    if (!apiKey) return json({ error: "ia_no_configurada", detalle: "Falta ANTHROPIC_API_KEY en los secretos de Supabase" }, 503);

    // ── 2) Qué nos mandaron: archivo (imagen/PDF en base64) o texto ──
    const texto = typeof body.texto === "string" ? body.texto.trim() : "";
    const archivo = typeof body.archivo === "string" ? body.archivo : "";
    const mime = String(body.mime ?? "").toLowerCase();
    const esImagen = ["image/jpeg", "image/png", "image/webp", "image/gif"].includes(mime);
    const esPDF = mime === "application/pdf";
    if (!texto && !archivo) return json({ error: "sin_contenido" }, 400);
    if (archivo && !esImagen && !esPDF) return json({ error: "formato_no_soportado", detalle: `Formato ${mime || "desconocido"}: mandá una foto, un PDF o el texto de la planilla` }, 400);
    if (archivo.length > 14_000_000) return json({ error: "archivo_grande", detalle: "El archivo supera los 10 MB" }, 400);
    if (texto.length > 200_000) return json({ error: "texto_largo", detalle: "La lista es muy larga: dividila en partes" }, 400);

    const contenido: unknown[] = [];
    if (archivo) {
      contenido.push(esPDF
        ? { type: "document", source: { type: "base64", media_type: "application/pdf", data: archivo } }
        : { type: "image", source: { type: "base64", media_type: mime, data: archivo } });
    }
    contenido.push({ type: "text", text: PROMPT + (texto ? `\n\nLista (texto de la planilla, columnas separadas por tabulador):\n\n${texto}` : "") });

    // ── 3) Claude lee la lista ──
    const res = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: {
        "x-api-key": apiKey,
        "anthropic-version": "2023-06-01",
        "anthropic-beta": "server-side-fallback-2026-07-01",
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        model: MODEL,
        fallbacks: "default",
        max_tokens: MAX_TOKENS,
        output_config: { effort: "medium", format: { type: "json_schema", schema: SCHEMA } },
        messages: [{ role: "user", content: contenido }],
      }),
    });
    if (!res.ok) {
      const err = await res.text();
      console.error("Anthropic error:", res.status, err.slice(0, 400));
      return json({ error: "ia_fallo", detalle: `La lectura falló (${res.status})` }, 502);
    }
    const msg = await res.json();
    if (msg.stop_reason === "refusal") return json({ error: "ia_rechazo", detalle: "La IA no procesó este archivo; cargá la lista a mano" }, 422);
    if (msg.stop_reason === "max_tokens") return json({ error: "lista_larga", detalle: "La lista es demasiado larga para leerla de una vez: dividila en partes" }, 422);
    const txt = (msg.content ?? []).filter((b: { type: string }) => b.type === "text").map((b: { text: string }) => b.text).join("");
    let out: { lineas?: unknown[]; moneda?: string | null; proveedor?: string | null; notas?: string | null };
    try { out = JSON.parse(txt); } catch { return json({ error: "ia_ilegible", detalle: "La respuesta de la IA no se pudo interpretar" }, 502); }

    return json({
      ok: true,
      modelo: msg.model,
      lineas: Array.isArray(out.lineas) ? out.lineas : [],
      moneda: out.moneda ?? null,
      proveedor: out.proveedor ?? null,
      notas: out.notas ?? null,
      uso: msg.usage ? { entrada: msg.usage.input_tokens, salida: msg.usage.output_tokens } : null,
    });
  } catch (e) {
    console.error(e);
    return json({ error: "error_interno" }, 500);
  }
});
