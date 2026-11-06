// ============================================================
// Edge Function "usuarios" — accesos al panel sin entrar a Supabase
// ------------------------------------------------------------
// El panel (Usuarios) la llama para:
//   { accion: "crear", email, nombre, rol }  → crea la cuenta con una
//       contraseña temporal y la devuelve UNA vez para pasársela a la persona.
//   { accion: "restablecer", id }            → contraseña temporal nueva
//       para alguien que se olvidó la suya.
//   { ping: true }                           → ¿está desplegada?
// En los dos casos el perfil queda con debe_cambiar_clave = true y el panel
// le pide a la persona elegir una propia al entrar (admin/clave.html).
//
// Quién puede llamarla: un administrador ACTIVO del panel (se valida la
// sesión y el perfil con la clave de servicio). Nunca devuelve otra cosa
// que la contraseña temporal recién creada.
//
// Requiere sql/014-accesos.sql (columna debe_cambiar_clave; las cuentas
// nuevas nacen inactivas y esta función las activa con el rol pedido).
//
// Secretos: solo SUPABASE_SERVICE_ROLE_KEY (la pone Supabase sola).
// Deploy: npx supabase functions deploy usuarios --project-ref zydotmaolgddwenwywyc --no-verify-jwt --use-api
// ============================================================
import { createClient } from "jsr:@supabase/supabase-js@2";
import { claveTemporal, esEmailExistente, validarAlta } from "./logica.ts";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  const json = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });

  try {
    const url = Deno.env.get("SUPABASE_URL")!;
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const admin = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });

    const body = await req.json().catch(() => ({}));
    if (body.ping) return json({ ok: true });

    // ── ¿Quién llama? Solo un administrador activo ──
    const conSesion = createClient(url, anonKey, {
      auth: { persistSession: false },
      global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
    });
    const { data: { user } } = await conSesion.auth.getUser();
    if (!user) return json({ error: "no_autorizado" }, 401);
    const { data: yo } = await admin.from("profiles").select("rol, activo").eq("id", user.id).maybeSingle();
    if (!yo || !yo.activo || yo.rol !== "administrador") return json({ error: "no_autorizado" }, 403);

    // ── Crear un acceso ──
    if (body.accion === "crear") {
      const alta = validarAlta(body);
      if ("error" in alta) return json(alta, 400);
      const clave = claveTemporal();

      const { data: creado, error } = await admin.auth.admin.createUser({
        email: alta.email,
        password: clave,
        email_confirm: true,            // no hay mail de confirmación: lo da de alta un admin
        user_metadata: { nombre: alta.nombre },
      });
      if (error || !creado?.user) {
        if (esEmailExistente(error)) return json({ error: "email_existente" }, 409);
        console.error("createUser", error);
        return json({ error: "no_se_pudo_crear", detalle: error?.message }, 500);
      }

      // El trigger del 014 crea el perfil inactivo; acá se activa con el rol pedido.
      const { error: ePerfil } = await admin.from("profiles").update({
        nombre: alta.nombre, rol: alta.rol, activo: true, debe_cambiar_clave: true,
      }).eq("id", creado.user.id);
      if (ePerfil) {
        console.error("perfil", ePerfil);
        return json({ error: "perfil_sin_activar", detalle: ePerfil.message, id: creado.user.id }, 500);
      }
      return json({ ok: true, id: creado.user.id, email: alta.email, clave });
    }

    // ── Contraseña temporal nueva ──
    if (body.accion === "restablecer") {
      const id = String(body.id ?? "");
      if (!/^[0-9a-f-]{36}$/i.test(id)) return json({ error: "id_invalido" }, 400);
      if (id === user.id) return json({ error: "es_tu_cuenta" }, 400);   // la propia se cambia en admin/clave
      const { data: perfil } = await admin.from("profiles").select("email").eq("id", id).maybeSingle();
      if (!perfil) return json({ error: "usuario_no_encontrado" }, 404);

      const clave = claveTemporal();
      const { error } = await admin.auth.admin.updateUserById(id, { password: clave });
      if (error) {
        console.error("updateUserById", error);
        return json({ error: "no_se_pudo_restablecer", detalle: error.message }, 500);
      }
      await admin.from("profiles").update({ debe_cambiar_clave: true }).eq("id", id);
      return json({ ok: true, id, email: perfil.email, clave });
    }

    return json({ error: "accion_invalida" }, 400);
  } catch (e) {
    console.error(e);
    return json({ error: "error_interno" }, 500);
  }
});
