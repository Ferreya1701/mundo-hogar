// ============================================================
// Edge Function "asistente" — IA del panel de Mundo Hogar
// ------------------------------------------------------------
// Recibe una pregunta del panel admin y responde usando Claude.
// La clave ANTHROPIC_API_KEY vive como secreto en Supabase:
// NUNCA llega al navegador. Solo usuarios logueados pueden usarla.
//
// Deploy: ver GUIA-ASISTENTE-IA.md en la raíz del proyecto.
// ============================================================
import { createClient } from "jsr:@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const SYSTEM_PROMPT = `Sos el Asistente MH, el asistente interno del panel de administración de Mundo Hogar, una tienda mayorista y minorista de artículos para el hogar de Santa Fe, Argentina.

Tu función es ayudar al usuario (que no es técnico) a gestionar su negocio: productos, categorías, stock, movimientos, solicitudes de WhatsApp, usuarios y configuración.

Reglas:
- Respondé en español argentino, claro, breve y accionable (máximo ~120 palabras).
- Usá los datos del contexto cuando estén presentes. NO inventes números ni información.
- Si no tenés datos suficientes, decí qué falta.
- No podés modificar nada: solo orientar. Si el usuario pide un cambio, explicale en qué pantalla hacerlo.
- Secciones del panel: Dashboard, Solicitudes WhatsApp, Productos, Categorías, Registrar Movimiento, Historial, Alertas de Stock, Usuarios, Configuración.
- Datos clave del negocio: la tienda pública muestra "Consultar precio" cuando un producto no tiene precio cargado; los productos "destacados" aparecen en la portada; las solicitudes son pedidos que los clientes envían desde el carrito y se responden por WhatsApp.
- Cuando detectes un problema, sugerí el próximo paso concreto.`;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  const json = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), {
      status,
      headers: { ...CORS, "Content-Type": "application/json" },
    });

  try {
    // Solo usuarios autenticados del panel
    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_ANON_KEY")!,
      { global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } } },
    );
    const { data: { user } } = await supabase.auth.getUser();
    if (!user) return json({ error: "no_autorizado" }, 401);

    const body = await req.json().catch(() => ({}));
    if (body.ping) return json({ ok: true });

    const pregunta = String(body.pregunta ?? "").slice(0, 500).trim();
    if (!pregunta) return json({ error: "pregunta_vacia" }, 400);

    const apiKey = Deno.env.get("ANTHROPIC_API_KEY");
    if (!apiKey) return json({ error: "ia_no_configurada" }, 503);

    const contexto = body.contexto ? JSON.stringify(body.contexto).slice(0, 2000) : "{}";

    const res = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: {
        "x-api-key": apiKey,
        "anthropic-version": "2023-06-01",
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        model: "claude-haiku-4-5-20251001",
        max_tokens: 400,
        system: SYSTEM_PROMPT,
        messages: [{
          role: "user",
          content: `Datos actuales del negocio (JSON): ${contexto}\n\nPregunta del usuario: ${pregunta}`,
        }],
      }),
    });

    if (!res.ok) {
      const err = await res.text();
      console.error("Anthropic error:", err.slice(0, 300));
      return json({ error: "ia_error" }, 502);
    }
    const data = await res.json();
    const respuesta = data?.content?.[0]?.text ?? "No pude generar una respuesta.";
    return json({ respuesta });
  } catch (e) {
    console.error(e);
    return json({ error: "error_interno" }, 500);
  }
});
