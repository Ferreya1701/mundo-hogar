-- ============================================================
-- 011 — ABRIR LA CHARLA EN PANELBOT (2026-10-13)
-- Ejecutar en Supabase → SQL Editor, DESPUÉS del 010.
-- Idempotente. No modifica ni borra datos existentes.
--
-- EL PROBLEMA QUE RESUELVE
--   El botón 💬 del CRM abre wa.me, que responde desde el WhatsApp que
--   esté abierto en el navegador. Si alguien del equipo tiene logueado el
--   número viejo, le contesta al cliente desde ahí. El cliente ve dos
--   números distintos y la conversación queda partida.
--
-- CÓMO LO RESUELVE
--   Cuando la charla ya existe en PanelBot, el CRM deja de ofrecer wa.me y
--   ofrece "Abrir la charla": lleva a la conversación real, en el número
--   que de verdad usa el negocio.
--
-- DECISIONES DE DISEÑO
--   1) Se guarda el ID de la conversación, NO una URL. Si guardáramos la
--      URL que manda un sistema externo, una clave filtrada permitiría
--      poner cualquier link en un botón del panel (phishing interno). El
--      id se sanitiza y la dirección base la ponemos nosotros acá.
--   2) La conversación vive en el CONTACTO, no en la oportunidad: en
--      WhatsApp hay una sola charla por teléfono, y dura más que
--      cualquier consulta puntual.
--   3) Para las consultas NO hace falta que PanelBot cambie nada: el
--      contrato (entregable 12) ya define `ref` como el id de la
--      conversación, así que se usa como respaldo. Para los pedidos, `ref`
--      es el id del pedido: ahí sí hay que mandar "conversacion".
--
-- DESPUÉS DE CORRERLO, configurar la dirección base UNA vez:
--     SELECT crm_set_base_conversacion('https://panel.tiaf.shop/app/conversaciones/');
--   El segundo parámetro es el nombre de la integración ('panelbot' por
--   defecto); si el bot es otro, pasale el nombre con el que lo creaste.
--   LA DIRECCIÓN DE ARRIBA ES UN EJEMPLO DEDUCIDO, NO VERIFICADA: pedila a
--   quien maneje el bot. Sin esto el botón no aparece y el CRM sigue
--   funcionando como hasta ahora.
--   Para desactivar el botón en todo el panel:
--     SELECT crm_set_base_conversacion(NULL);
-- ============================================================

-- ──────────────────────────────────────────────
-- 1) DÓNDE SE GUARDA
-- ──────────────────────────────────────────────
ALTER TABLE crm_contactos
  ADD COLUMN IF NOT EXISTS conversacion_externa TEXT
    CHECK (conversacion_externa IS NULL OR char_length(conversacion_externa) <= 120);

COMMENT ON COLUMN crm_contactos.conversacion_externa IS
  'Id de la conversación en el sistema externo (PanelBot). Solo el id: la dirección base vive en crm_integraciones.base_conversacion.';

ALTER TABLE crm_integraciones
  ADD COLUMN IF NOT EXISTS base_conversacion TEXT;

COMMENT ON COLUMN crm_integraciones.base_conversacion IS
  'Prefijo de la URL de conversaciones del sistema externo. Lo pone Mundo Hogar, nunca el sistema externo.';

-- ──────────────────────────────────────────────
-- 2) SANEADO DEL ID
--    Solo lo que puede ser un id: letras, números, guiones, guión bajo y
--    dos puntos. Nada de "/", "?", "#", ":" de esquema ni espacios, así
--    el id no puede cambiar la dirección a la que lleva el botón.
-- ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_crm_conv_id(p_id TEXT)
RETURNS TEXT LANGUAGE sql IMMUTABLE AS $$
  SELECT nullif(left(regexp_replace(coalesce(p_id, ''), '[^A-Za-z0-9_:-]', '', 'g'), 120), '');
$$;

GRANT EXECUTE ON FUNCTION fn_crm_conv_id(TEXT) TO authenticated;

-- ──────────────────────────────────────────────
-- 3) CONFIGURAR LA DIRECCIÓN BASE (solo desde el SQL Editor)
--    Exige https: un http:// mandaría al equipo a un sitio sin cifrar.
--
--    El nombre de la integración es un parámetro, no 'panelbot' fijo: la
--    puerta del 010 ya identifica al sistema externo por el hash de su
--    clave, así que cualquier bot (PanelBot, uno propio de TIAF OS, otro)
--    funciona igual. Atarlo a un nombre habría obligado a llamar 'panelbot'
--    a algo que no lo es.
-- ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION crm_set_base_conversacion(p_base TEXT, p_nombre TEXT DEFAULT 'panelbot')
RETURNS TEXT LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE
  v_base   TEXT := nullif(btrim(coalesce(p_base, '')), '');
  v_nombre TEXT := nullif(btrim(coalesce(p_nombre, '')), '');
BEGIN
  IF v_nombre IS NULL THEN
    RAISE EXCEPTION 'nombre_requerido' USING HINT = 'Pasá el nombre de la integración.';
  END IF;

  IF v_base IS NOT NULL THEN
    IF v_base !~* '^https://[a-z0-9.-]+[a-z0-9](/[A-Za-z0-9_./-]*)?$' THEN
      RAISE EXCEPTION 'base_invalida'
        USING HINT = 'Tiene que ser una dirección https, por ejemplo https://panel.tiaf.shop/app/conversaciones/';
    END IF;
    IF right(v_base, 1) <> '/' THEN v_base := v_base || '/'; END IF;
  END IF;

  UPDATE crm_integraciones SET base_conversacion = v_base WHERE nombre = v_nombre;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'integracion_inexistente'
      USING HINT = 'Primero creá la integración: SELECT crm_crear_integracion(''<nombre>'');';
  END IF;

  RETURN coalesce(v_base, '(botón desactivado)');
END;
$$;

REVOKE ALL ON FUNCTION crm_set_base_conversacion(TEXT, TEXT) FROM PUBLIC, anon, authenticated;

-- ──────────────────────────────────────────────
-- 4) LO QUE LEE EL PANEL
--    crm_integraciones no se puede leer por la API (ahí vive el hash de la
--    clave). Esta función devuelve SOLO la dirección base, y solo a quien
--    usa el CRM. El público no recibe nada.
--
--    No pregunta por nombre: el panel solo necesita saber DÓNDE viven las
--    charlas. Toma la de la integración activa que tenga una configurada.
--    Si algún día convivieran dos bots escribiendo charlas, habría que
--    registrar en el contacto de cuál vino cada una; hoy ese caso no existe
--    y no se construye por adelantado.
-- ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION crm_base_conversacion()
RETURNS TEXT LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public AS $$
BEGIN
  IF coalesce(fn_get_user_role(), '') NOT IN ('administrador','vendedor') THEN
    RETURN NULL;
  END IF;
  RETURN (SELECT base_conversacion FROM crm_integraciones
           WHERE activo AND base_conversacion IS NOT NULL
           ORDER BY id LIMIT 1);
END;
$$;

REVOKE ALL ON FUNCTION crm_base_conversacion() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION crm_base_conversacion() TO authenticated;
-- ──────────────────────────────────────────────
-- 5) crm_bot_evento: recibir y guardar la charla
--    Es LA MISMA función del 010 (copiada del archivo, no reescrita) con
--    cinco agregados marcados "011". PL/pgSQL no permite parchear un
--    pedazo: hay que reemplazarla entera.
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
  v_conv       TEXT;                 -- 011: charla en PanelBot
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
  -- 011: el id de la charla. Si no viene explícito y es una consulta, el
  -- contrato (entregable 12) define `ref` como el id de la conversación, así
  -- que sirve de respaldo. En los pedidos `ref` es el id del pedido: ahí hace
  -- falta "conversacion". Se calcula ANTES de prefijar v_ref.
  v_conv := fn_crm_conv_id(p->>'conversacion');
  IF v_conv IS NULL AND v_tipo = 'consulta' THEN
    v_conv := fn_crm_conv_id(v_ref);
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
    INSERT INTO crm_contactos (nombre, telefono, canal_origen, created_by, conversacion_externa)
    VALUES (v_nombre, v_tel, 'whatsapp', NULL, v_conv)
    RETURNING id INTO v_contacto;
    v_cnuevo := true;
  ELSE
    UPDATE crm_contactos SET archivado = false WHERE id = v_contacto AND archivado;
    -- Si lo habíamos cargado sin nombre y ahora llega el real, se completa
    IF v_nombre NOT LIKE 'Cliente de WhatsApp %' THEN
      UPDATE crm_contactos SET nombre = v_nombre
       WHERE id = v_contacto AND nombre LIKE 'Cliente de WhatsApp %';
    END IF;
    -- 011: se guarda la charla más reciente. Si el evento no la trae, se deja
    -- la que había: perder el botón por un evento incompleto sería peor.
    IF v_conv IS NOT NULL THEN
      UPDATE crm_contactos SET conversacion_externa = v_conv
       WHERE id = v_contacto AND coalesce(conversacion_externa, '') <> v_conv;
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
    'conversacion_guardada', v_conv IS NOT NULL,   -- 011
    'url', 'https://mundohogarstf.com/admin/crm.html?op=' || v_opp_id
  );
END;
$func$;

REVOKE ALL ON FUNCTION crm_bot_evento(TEXT, JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION crm_bot_evento(TEXT, JSONB) TO anon, authenticated;

NOTIFY pgrst, 'reload schema';

-- ============================================================
-- VERIFICACIÓN (correr aparte, después de este script)
--   1. SELECT crm_set_base_conversacion('https://panel.tiaf.shop/app/conversaciones/');
--      → devuelve la dirección con la barra final.
--   2. SELECT crm_set_base_conversacion('http://no-cifrado.com');
--      → debe fallar con 'base_invalida'.
--   3. SELECT fn_crm_conv_id('../../admin?x=1');  → 'adminx1'
--      (queda inofensivo: no puede cambiar el destino del botón)
--   4. Mandar una consulta de prueba por crm_bot_evento con la clave real:
--      la respuesta trae "conversacion_guardada": true y en el CRM aparece
--      "Abrir la charla" en la ficha de ese contacto.
--   5. Como anónimo: SELECT crm_base_conversacion(); → NULL (sin permiso).
-- ============================================================
