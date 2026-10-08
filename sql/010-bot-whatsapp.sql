-- ============================================================
-- 010 — Conexión con el bot de WhatsApp (PanelBot) (2026-10-08)
-- Ejecutar en Supabase → SQL Editor, DESPUÉS del 009.
-- Idempotente. No modifica ni borra datos existentes.
--
-- Qué agrega:
--   1) Vista catalogo_bot: lo que el bot puede ofrecer, con la MISMA
--      regla de precio y disponibilidad que la tienda web
--      (assets/catalogo.js: effectivePrice / isAvailable). Es pública
--      igual que el catálogo de la tienda: no expone nada nuevo.
--   2) crm_integraciones: la clave de cada sistema externo (PanelBot).
--      Se guarda solo el hash: la clave se ve una sola vez, al crearla.
--   3) crm_bot_evento(clave, evento): la puerta por la que el bot carga
--      consultas y pedidos en el CRM. Cada evento trae un "ref" del bot:
--      si llega dos veces (reintentos), no se duplica.
--
-- Después de correrlo, crear la clave UNA vez (desde este SQL Editor):
--     SELECT crm_crear_integracion('panelbot');
-- y pasársela a PanelBot por un canal privado (nunca al repo, que es público).
-- Volver a correrlo rota la clave: la vieja deja de andar.
-- Para cortar el acceso:
--     UPDATE crm_integraciones SET activo = false WHERE nombre = 'panelbot';
-- ============================================================


-- ──────────────────────────────────────────────
-- 1) CATÁLOGO PARA EL BOT
-- ──────────────────────────────────────────────
-- security_invoker: la vista respeta el RLS de productos (el público solo
-- ve los activos), igual que cuando la tienda pide el catálogo.
CREATE OR REPLACE VIEW catalogo_bot WITH (security_invoker = true) AS
SELECT
  p.id,
  p.sku,
  p.nombre,
  coalesce(nullif(btrim(p.descripcion_corta), ''), left(p.descripcion, 400)) AS descripcion,
  c.nombre AS categoria,
  p.marca,
  -- Precio que ve el cliente: oferta si está en oferta, si no el minorista.
  -- NULL = "consultar precio" (la tienda tampoco muestra $0).
  CASE WHEN p.en_oferta AND coalesce(p.precio_oferta, 0) > 0 THEN p.precio_oferta
       WHEN coalesce(p.precio_minorista, 0) > 0 THEN p.precio_minorista
  END AS precio,
  (p.en_oferta AND coalesce(p.precio_oferta, 0) > 0) AS en_oferta,
  CASE WHEN p.en_oferta AND coalesce(p.precio_oferta, 0) > 0
             AND coalesce(p.precio_minorista, 0) > p.precio_oferta
       THEN p.precio_minorista
  END AS precio_anterior,
  -- Disponibilidad: el stock solo bloquea productos CON precio (igual que la
  -- tienda). Sin precio el flujo es consulta/cotización y no se afirma nada.
  CASE
    WHEN NOT (coalesce(p.precio_minorista, 0) > 0
              OR (p.en_oferta AND coalesce(p.precio_oferta, 0) > 0)) THEN true
    WHEN NOT p.seguimiento_inventario OR p.permite_venta_sin_stock THEN true
    ELSE p.stock_actual > 0
  END AS disponible,
  'https://mundohogarstf.com/producto/' || p.slug AS url,
  p.imagen_principal_url AS imagen,
  p.updated_at AS actualizado        -- para sincronizar solo lo que cambió
FROM productos p
LEFT JOIN categorias c ON c.id = p.categoria_id
WHERE p.estado = 'activo';

GRANT SELECT ON catalogo_bot TO anon, authenticated;


-- ──────────────────────────────────────────────
-- 2) REFERENCIA EXTERNA EN LAS OPORTUNIDADES
-- ──────────────────────────────────────────────
ALTER TABLE crm_oportunidades ADD COLUMN IF NOT EXISTS ref_externa TEXT
  CHECK (ref_externa IS NULL OR char_length(ref_externa) <= 160);
CREATE UNIQUE INDEX IF NOT EXISTS uq_crm_opp_ref_externa
  ON crm_oportunidades(ref_externa) WHERE ref_externa IS NOT NULL;


-- ──────────────────────────────────────────────
-- 3) INTEGRACIONES (claves de sistemas externos)
--    Sin políticas: ni el público ni el staff la leen por la API.
-- ──────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm_integraciones (
  id                BIGSERIAL PRIMARY KEY,
  nombre            TEXT NOT NULL UNIQUE
                      CHECK (nombre ~ '^[a-z0-9_-]{2,40}$'),
  token_hash        TEXT NOT NULL,
  activo            BOOLEAN NOT NULL DEFAULT true,
  eventos_ventana   INT NOT NULL DEFAULT 0,          -- límite por minuto
  ventana_desde     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  ultimo_evento_at  TIMESTAMPTZ,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE crm_integraciones ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON crm_integraciones FROM anon, authenticated;
REVOKE ALL ON SEQUENCE crm_integraciones_id_seq FROM anon, authenticated;

-- Crea (o rota) la clave de una integración y la devuelve UNA sola vez.
-- Solo se puede correr desde el SQL Editor (nadie más tiene permiso).
CREATE OR REPLACE FUNCTION crm_crear_integracion(p_nombre TEXT)
RETURNS TEXT LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $func$
DECLARE
  v_token TEXT := 'mhcrm_' || replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
BEGIN
  INSERT INTO crm_integraciones (nombre, token_hash, activo)
  VALUES (lower(btrim(p_nombre)), encode(sha256(convert_to(v_token, 'UTF8')), 'hex'), true)
  ON CONFLICT (nombre) DO UPDATE SET token_hash = EXCLUDED.token_hash, activo = true;
  RETURN v_token;
END;
$func$;

REVOKE ALL ON FUNCTION crm_crear_integracion(TEXT) FROM PUBLIC, anon, authenticated;


-- ──────────────────────────────────────────────
-- 4) PUERTA DEL BOT: crm_bot_evento(clave, evento)
--
--   Consulta (el bot pasa la charla a una persona):
--     { "tipo": "consulta", "ref": "<id de la conversación en PanelBot>",
--       "telefono": "+5493424445555", "nombre": "María Gómez",
--       "titulo": "Juego de sillas", "resumen": "Pregunta si hay en gris…" }
--
--   Pedido (el bot tomó un pedido y el cliente confirmó el resumen):
--     { "tipo": "pedido", "ref": "<id del pedido en PanelBot>",
--       "telefono": "...", "nombre": "...", "resumen": "Retira el sábado",
--       "items": [ { "nombre": "Freidora de aire 5L", "cantidad": 2, "precio": 89999 },
--                  { "nombre": "Lavarropas 8kg", "cantidad": 1, "precio": null } ] }
--     precio null = a cotizar. Si el mismo "ref" llega otra vez (el cliente
--     corrigió el pedido), se actualiza la misma oportunidad.
--
--   Devuelve { ok, contacto_id, oportunidad_id, oportunidad_nueva,
--              contacto_nuevo, url } — url abre la ficha en el CRM.
-- ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION crm_bot_evento(p_token TEXT, p JSONB)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $func$
DECLARE
  v_int        crm_integraciones%ROWTYPE;
  v_tipo       TEXT := coalesce(p->>'tipo', '');
  v_ref        TEXT := nullif(left(btrim(coalesce(p->>'ref', '')), 100), '');
  v_tel        TEXT := nullif(left(regexp_replace(coalesce(p->>'telefono', ''), '[^0-9+ ()\-]', '', 'g'), 40), '');
  v_clave      TEXT;
  v_nombre     TEXT := left(btrim(regexp_replace(coalesce(p->>'nombre', ''), '\s+', ' ', 'g')), 120);
  v_resumen    TEXT := nullif(left(btrim(coalesce(p->>'resumen', '')), 1500), '');
  v_hoy        DATE := (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date;
  v_contacto   BIGINT;
  v_cnuevo     BOOLEAN := false;
  v_opp        crm_oportunidades%ROWTYPE;
  v_opp_id     BIGINT;
  v_nueva      BOOLEAN := false;
  v_titulo     TEXT;
  v_monto      NUMERIC(12,2);
  v_items      JSONB;
  v_item       JSONB;
  v_nom_item   TEXT;
  v_cant       INT;
  v_precio     NUMERIC(12,2);
  v_total      NUMERIC(14,2) := 0;
  v_falta      BOOLEAN := false;
  v_lineas     TEXT := '';
  v_n          INT := 0;
  v_detalle    TEXT;
BEGIN
  -- Clave: se compara el hash, la clave nunca se guarda
  SELECT * INTO v_int FROM crm_integraciones
   WHERE token_hash = encode(sha256(convert_to(coalesce(p_token, ''), 'UTF8')), 'hex') AND activo
   FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'no_autorizado' USING HINT = 'La clave de la integración no es válida o está desactivada.';
  END IF;

  -- Límite: 120 eventos por minuto por integración
  IF v_int.ventana_desde < now() - interval '1 minute' THEN
    UPDATE crm_integraciones SET ventana_desde = now(), eventos_ventana = 1, ultimo_evento_at = now()
     WHERE id = v_int.id;
  ELSIF v_int.eventos_ventana >= 120 THEN
    RAISE EXCEPTION 'limite_eventos' USING HINT = 'Demasiados eventos por minuto. Reintentá en un rato.';
  ELSE
    UPDATE crm_integraciones SET eventos_ventana = eventos_ventana + 1, ultimo_evento_at = now()
     WHERE id = v_int.id;
  END IF;

  -- Validación
  IF v_tipo NOT IN ('consulta', 'pedido') THEN
    RAISE EXCEPTION 'tipo_invalido' USING HINT = '"tipo" tiene que ser "consulta" o "pedido".';
  END IF;
  IF v_ref IS NULL THEN
    RAISE EXCEPTION 'ref_requerida'
      USING HINT = 'Mandá "ref": el id de la conversación o del pedido en el bot (evita duplicados).';
  END IF;
  v_clave := fn_crm_tel_clave(v_tel);
  IF v_clave IS NULL THEN
    RAISE EXCEPTION 'telefono_invalido' USING HINT = 'Mandá "telefono": el número de WhatsApp del cliente.';
  END IF;
  IF char_length(v_nombre) < 2 THEN
    v_nombre := 'Cliente de WhatsApp ' || right(v_clave, 4);
  END IF;
  v_ref := v_int.nombre || ':' || v_tipo || ':' || v_ref;

  -- Pedido: items, total y título
  IF v_tipo = 'pedido' THEN
    v_items := coalesce(p->'items', '[]'::jsonb);
    IF jsonb_typeof(v_items) <> 'array' OR jsonb_array_length(v_items) = 0 OR jsonb_array_length(v_items) > 50 THEN
      RAISE EXCEPTION 'items_invalidos'
        USING HINT = 'Mandá "items": [{"nombre", "cantidad", "precio"}] (precio vacío = a cotizar), entre 1 y 50.';
    END IF;
    FOR v_item IN SELECT * FROM jsonb_array_elements(v_items) LOOP
      BEGIN
        v_nom_item := left(btrim(coalesce(v_item->>'nombre', '')), 120);
        v_cant     := least(greatest(coalesce((v_item->>'cantidad')::int, 1), 1), 999);
        v_precio   := nullif(btrim(coalesce(v_item->>'precio', '')), '')::numeric;
      EXCEPTION WHEN OTHERS THEN
        RAISE EXCEPTION 'items_invalidos' USING HINT = 'Cantidad y precio tienen que ser números.';
      END;
      IF v_nom_item = '' THEN
        RAISE EXCEPTION 'items_invalidos' USING HINT = 'Cada item necesita "nombre".';
      END IF;
      v_n := v_n + 1;
      IF v_precio IS NULL OR v_precio <= 0 THEN
        v_falta := true;
        v_lineas := v_lineas || format(E'\n• %s× %s — a cotizar', v_cant, v_nom_item);
      ELSE
        v_total := v_total + v_precio * v_cant;
        v_lineas := v_lineas || format(E'\n• %s× %s — $%s', v_cant, v_nom_item,
                                       replace(to_char(v_precio * v_cant, 'FM999,999,999,990'), ',', '.'));
      END IF;
    END LOOP;
    v_monto := CASE WHEN v_falta THEN NULL ELSE round(v_total, 2) END;
    v_titulo := left('Pedido por WhatsApp · ' || (v_items->0->>'nombre')
                     || CASE WHEN v_n > 1 THEN format(' y %s más', v_n - 1) ELSE '' END, 160);
  ELSE
    v_titulo := coalesce(nullif(left(btrim(regexp_replace(coalesce(p->>'titulo', ''), '\s+', ' ', 'g')), 160), ''),
                         'Consulta por WhatsApp');
  END IF;

  -- Contacto: el que ya tiene ese teléfono (activo primero) o uno nuevo
  SELECT id INTO v_contacto FROM crm_contactos
   WHERE telefono_clave = v_clave ORDER BY archivado, id LIMIT 1;
  IF v_contacto IS NULL THEN
    INSERT INTO crm_contactos (nombre, telefono, canal_origen, created_by)
    VALUES (v_nombre, v_tel, 'whatsapp', NULL)
    RETURNING id INTO v_contacto;
    v_cnuevo := true;
  ELSE
    UPDATE crm_contactos SET archivado = false WHERE id = v_contacto AND archivado;
    -- Si lo habíamos cargado sin nombre y ahora llega el real, se completa
    IF v_nombre NOT LIKE 'Cliente de WhatsApp %' THEN
      UPDATE crm_contactos SET nombre = v_nombre
       WHERE id = v_contacto AND nombre LIKE 'Cliente de WhatsApp %';
    END IF;
  END IF;

  -- Oportunidad: una por ref (los reintentos no duplican)
  SELECT * INTO v_opp FROM crm_oportunidades WHERE ref_externa = v_ref;
  IF NOT FOUND THEN
    INSERT INTO crm_oportunidades (contacto_id, titulo, etapa, canal, monto, ref_externa,
                                   proxima_accion, proxima_accion_fecha, created_by)
    VALUES (v_contacto, v_titulo, 'nueva', 'whatsapp', v_monto, v_ref,
            CASE WHEN v_tipo = 'consulta' THEN 'Responder por WhatsApp (lo pasó el bot)'
                 WHEN v_falta THEN 'Cotizar lo que falta y confirmar el pedido'
                 ELSE 'Confirmar el pedido con el cliente' END,
            v_hoy, NULL)
    RETURNING id INTO v_opp_id;
    v_nueva := true;
  ELSE
    v_opp_id := v_opp.id;
    -- Si el equipo ya la cerró, no se le toca nada: solo queda asentado
    IF v_opp.etapa IN ('nueva', 'contactado', 'cotizado') THEN
      UPDATE crm_oportunidades
         SET titulo = v_titulo,
             monto  = CASE WHEN v_tipo = 'pedido' THEN v_monto ELSE monto END
       WHERE id = v_opp_id;
    END IF;
  END IF;

  -- Historial: qué dijo o pidió el cliente
  v_detalle := CASE
    WHEN v_tipo = 'pedido' THEN
      (CASE WHEN v_nueva THEN '🤖 El bot tomó un pedido por WhatsApp:' ELSE '🤖 El cliente cambió el pedido:' END)
      || v_lineas
      || CASE WHEN v_monto IS NOT NULL
              THEN E'\nTotal: $' || replace(to_char(v_monto, 'FM999,999,999,990'), ',', '.')
              ELSE E'\nTotal: a confirmar (hay productos a cotizar)' END
      || CASE WHEN v_resumen IS NOT NULL THEN E'\n' || v_resumen ELSE '' END
    ELSE
      '🤖 El bot pasó la charla a una persona' || CASE WHEN v_resumen IS NOT NULL THEN ': ' || v_resumen ELSE '.' END
  END;
  INSERT INTO crm_actividades (contacto_id, oportunidad_id, tipo, detalle, usuario_id)
  VALUES (v_contacto, v_opp_id, 'sistema', left(v_detalle, 2000), NULL);

  RETURN jsonb_build_object(
    'ok', true,
    'contacto_id', v_contacto,
    'oportunidad_id', v_opp_id,
    'oportunidad_nueva', v_nueva,
    'contacto_nuevo', v_cnuevo,
    'url', 'https://mundohogarstf.com/admin/crm.html?op=' || v_opp_id
  );
END;
$func$;

REVOKE ALL ON FUNCTION crm_bot_evento(TEXT, JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION crm_bot_evento(TEXT, JSONB) TO anon, authenticated;

NOTIFY pgrst, 'reload schema';

-- ============================================================
-- VERIFICACIÓN RÁPIDA (opcional):
--   1. SELECT crm_crear_integracion('panelbot');   → anotá la clave
--   2. Desde una terminal (reemplazá CLAVE y la clave pública del sitio):
--      curl -X POST "https://<proyecto>.supabase.co/rest/v1/rpc/crm_bot_evento" \
--        -H "apikey: <clave pública>" -H "Content-Type: application/json" \
--        -d '{"p_token":"CLAVE","p":{"tipo":"consulta","ref":"prueba-1","telefono":"3420000000","nombre":"Prueba Bot","titulo":"Prueba"}}'
--   3. Panel → CRM: aparece "Prueba Bot" en "Para hoy". Archivalo.
-- ============================================================
