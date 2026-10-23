// ============================================================
// Edge Function "leer-comprobante" — lectura de comprobantes de pago
// ------------------------------------------------------------
// La página pública /pedido/<código> la llama después de subir el
// archivo al bucket privado 'comprobantes'. La función:
//   1. Verifica que quien llama conozca código + teléfono del pedido
//      (o sea staff logueado del panel, para releer a mano).
//   2. Baja el archivo con la clave de servicio (nunca sale al navegador).
//   3. Se lo manda a Claude y le pide SOLO los datos del comprobante:
//      monto, fecha, destino (alias / CVU / titular), origen, nº de operación.
//   4. Guarda la lectura con comprobante_registrar_lectura (sql/012), que
//      es la que decide si coincide con el pedido. La IA no decide nada.
//
// Secretos en Supabase → Edge Functions → Secrets:
//   ANTHROPIC_API_KEY            (obligatoria)
//   SUPABASE_SERVICE_ROLE_KEY    (la pone Supabase sola)
// Deploy: igual que "asistente" (ver GUIA-ASISTENTE-IA.md), nombre
// exacto: leer-comprobante.
// ============================================================
import { createClient } from "jsr:@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const MODEL = "claude-opus-5";

const PROMPT = `Sos un lector de comprobantes de transferencia bancaria y de billeteras virtuales de Argentina (Mercado Pago, Ualá, bancos, etc.).

Mirá el comprobante adjunto y devolvé SOLO un objeto JSON con esta forma exacta, sin texto antes ni después, sin comentarios y sin bloque de código:

{
  "legible": true,
  "monto": 12345.67,
  "moneda": "ARS",
  "fecha": "2026-10-23",
  "hora": "14:35",
  "destino_alias": "alias.del.destino",
  "destino_cvu": "0000003100012345678901",
  "destino_titular": "Nombre del titular que recibe",
  "destino_banco": "Mercado Pago",
  "origen_titular": "Nombre de quien paga",
  "origen_banco": "Banco Galicia",
  "nro_operacion": "123456789",
  "confianza": 90,
  "notas": "cualquier aclaración breve"
}

Reglas:
- "legible": false si la imagen no es un comprobante de pago o no se puede leer. En ese caso dejá los demás campos en null y explicá en "notas".
- "monto": número con punto decimal, sin símbolo ni separadores de miles. Si el comprobante muestra $ 12.345,67 el monto es 12345.67. Si no está, null.
- "fecha": en formato AAAA-MM-DD. Si solo dice "hoy" o no figura, null.
- El DESTINO es la cuenta que RECIBE la plata (suele decir "Para", "Destinatario", "A", "Cuenta destino"). El ORIGEN es quien paga ("De", "Desde", "Cuenta origen"). No los confundas.
- "destino_cvu": solo dígitos (CBU o CVU de 22 dígitos). Si figura parcialmente oculto, null.
- "nro_operacion": el número de operación, comprobante, transacción o referencia tal como figura. Si no hay, null.
- "confianza": de 0 a 100, qué tan seguro estás de monto, fecha y destino en conjunto.
- No inventes datos. Lo que no esté en el comprobante va en null.`;

type Lectura = Record<string, unknown>;

function extraerJSON(texto: string): Lectura | null {
  const limpio = texto.replace(/```(?:json)?/gi, "").trim();
  const ini = limpio.indexOf("{"), fin = limpio.lastIndexOf("}");
  if (ini < 0 || fin < ini) return null;
  try { return JSON.parse(limpio.slice(ini, fin + 1)); } catch { return null; }
}

function b64(bytes: Uint8Array): string {
  let s = "";
  const CH = 0x8000;
  for (let i = 0; i < bytes.length; i += CH) {
    s += String.fromCharCode.apply(null, Array.from(bytes.subarray(i, i + CH)));
  }
  return btoa(s);
}

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

    const comprobanteId = Number(body.comprobante_id);
    if (!Number.isInteger(comprobanteId) || comprobanteId <= 0) return json({ error: "comprobante_invalido" }, 400);

    const admin = createClient(url, serviceKey, { auth: { persistSession: false } });

    // ── 1) ¿Quién llama? Cliente (código + teléfono) o staff del panel ──
    let autorizado = false;
    const codigo = String(body.codigo ?? "").trim().toUpperCase();
    const telefono = String(body.telefono ?? "").trim();
    if (codigo && telefono) {
      const anon = createClient(url, anonKey, { auth: { persistSession: false } });
      const { data, error } = await anon.rpc("pedido_consultar", { p_codigo: codigo, p_telefono: telefono });
      if (!error && data && Array.isArray(data.comprobantes) &&
          data.comprobantes.some((c: { id: number }) => Number(c.id) === comprobanteId)) {
        autorizado = true;
      }
    }
    if (!autorizado) {
      const conSesion = createClient(url, anonKey, {
        auth: { persistSession: false },
        global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
      });
      const { data: { user } } = await conSesion.auth.getUser();
      if (user) {
        const { data: perfil } = await admin.from("profiles").select("rol, activo").eq("id", user.id).maybeSingle();
        autorizado = !!perfil && perfil.activo && ["administrador", "vendedor"].includes(perfil.rol);
      }
    }
    if (!autorizado) return json({ error: "no_autorizado" }, 401);

    // ── 2) El comprobante y su archivo ──
    const { data: comp, error: eComp } = await admin
      .from("comprobantes").select("id, archivo, mime, estado").eq("id", comprobanteId).maybeSingle();
    if (eComp || !comp) return json({ error: "comprobante_no_encontrado" }, 404);
    if (["aceptado", "rechazado"].includes(comp.estado)) return json({ ok: true, estado: comp.estado, sin_cambios: true });

    let lectura: Lectura;
    const mime = String(comp.mime ?? "").toLowerCase();
    const esImagen = ["image/jpeg", "image/png", "image/webp", "image/gif"].includes(mime);
    const esPDF = mime === "application/pdf";

    if (!apiKey) {
      lectura = { legible: false, confianza: 0, notas: "Lectura automática no configurada (falta ANTHROPIC_API_KEY)" };
    } else if (!esImagen && !esPDF) {
      lectura = { legible: false, confianza: 0, notas: `Formato ${mime || "desconocido"} no soportado para lectura automática; revisar a mano` };
    } else {
      const { data: archivo, error: eArch } = await admin.storage.from("comprobantes").download(comp.archivo);
      if (eArch || !archivo) return json({ error: "archivo_no_disponible" }, 404);
      const bytes = new Uint8Array(await archivo.arrayBuffer());
      const data = b64(bytes);

      const adjunto = esPDF
        ? { type: "document", source: { type: "base64", media_type: "application/pdf", data } }
        : { type: "image", source: { type: "base64", media_type: mime, data } };

      // ── 3) Claude lee el comprobante ──
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
          max_tokens: 2048,
          fallbacks: "default",
          output_config: { effort: "medium" },
          messages: [{ role: "user", content: [adjunto, { type: "text", text: PROMPT }] }],
        }),
      });
      if (!res.ok) {
        const err = await res.text();
        console.error("Anthropic error:", res.status, err.slice(0, 300));
        lectura = { legible: false, confianza: 0, notas: `La lectura automática falló (${res.status}); revisar a mano` };
      } else {
        const msg = await res.json();
        if (msg.stop_reason === "refusal") {
          lectura = { legible: false, confianza: 0, notas: "La IA no procesó este archivo; revisar a mano" };
        } else {
          const texto = (msg.content ?? []).filter((b: { type: string }) => b.type === "text")
            .map((b: { text: string }) => b.text).join("\n");
          lectura = extraerJSON(texto) ?? { legible: false, confianza: 0, notas: "Respuesta de la IA no interpretable; revisar a mano" };
          lectura.modelo = msg.model;
        }
      }
    }

    // ── 4) La base decide si coincide con el pedido ──
    const { data: resultado, error: eReg } = await admin.rpc("comprobante_registrar_lectura", {
      p_comprobante_id: comprobanteId, p_lectura: lectura,
    });
    if (eReg) {
      console.error("registrar_lectura:", eReg.message);
      return json({ error: "no_se_pudo_registrar", detalle: eReg.message }, 500);
    }
    return json({ ok: true, ...resultado });
  } catch (e) {
    console.error(e);
    return json({ error: "error_interno" }, 500);
  }
});
