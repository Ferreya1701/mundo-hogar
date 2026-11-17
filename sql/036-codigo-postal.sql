-- ============================================================
-- 036 — Código postal en los pedidos web (2026-11-17)
-- ------------------------------------------------------------
-- El carrito pide el código postal cuando el cliente elige envío. Se guarda
-- en solicitudes.codigo_postal (4 números, o el CPA de 8 como S3000ABC; lo
-- demás se descarta, nunca frena el pedido) y el panel lo muestra en Pedidos.
--
-- crear_solicitud es la de sql/013 con DOS cambios marcados "036": lee
-- p->>'codigo_postal' y lo inserta. Si otra migración vuelve a definir
-- crear_solicitud, tiene que partir de ESTA versión.
--
-- La web ya manda el dato antes de correr esto (la función vieja lo ignora:
-- no se rompe nada, solo no se guarda). Requiere 001..035. Idempotente.
-- ============================================================

ALTER TABLE solicitudes ADD COLUMN IF NOT EXISTS codigo_postal TEXT;
COMMENT ON COLUMN solicitudes.codigo_postal IS 'Código postal de envío (4 dígitos o CPA). Lo carga crear_solicitud (sql/036).';

CREATE OR REPLACE FUNCTION crear_solicitud(p JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $func$
DECLARE
  v_nombre    TEXT;
  v_telefono  TEXT;
  v_tel_digits TEXT;
  v_localidad TEXT;
  v_direccion TEXT;
  v_cp        TEXT;
  v_entrega   TEXT;
  v_canal     TEXT;
  v_obs       TEXT;
  v_comercio  TEXT;
  v_cuit      TEXT;
  v_mayorista BOOLEAN;
  v_items     JSONB;
  v_item      JSONB;
  v_n         INT;
  v_pid       INT;
  v_cant      INT;
  v_prod      productos%ROWTYPE;
  v_precio    NUMERIC(12,2);
  v_total     NUMERIC(12,2) := 0;
  v_hay_precio BOOLEAN := false;
  v_pendientes BOOLEAN := false;
  v_sol_id    BIGINT;
  v_codigo    TEXT;
  v_out_items JSONB := '[]'::jsonb;
  v_sin_stock JSONB := '[]'::jsonb;
  v_disp      INT;
  v_a_conf    BOOLEAN;
  v_pedidos   JSONB := '{}'::jsonb;   -- cantidad acumulada por producto (el mismo producto dos veces)
BEGIN
  v_nombre   := left(btrim(regexp_replace(coalesce(p->>'nombre',''),    '[\r\n\t]+', ' ', 'g')), 80);
  v_telefono := left(regexp_replace(coalesce(p->>'telefono',''), '[^0-9+ ()\-]', '', 'g'), 25);
  v_tel_digits := regexp_replace(v_telefono, '\D', '', 'g');
  v_localidad := nullif(left(btrim(regexp_replace(coalesce(p->>'localidad',''), '[\r\n\t]+', ' ', 'g')), 80), '');
  v_direccion := nullif(left(btrim(regexp_replace(coalesce(p->>'direccion',''), '[\r\n\t]+', ' ', 'g')), 160), '');
  -- 036: código postal (4 números, o el CPA de 8: S3000ABC). Cualquier otra cosa se descarta.
  v_cp        := upper(regexp_replace(coalesce(p->>'codigo_postal',''), '[^0-9A-Za-z]', '', 'g'));
  v_cp        := CASE WHEN v_cp ~ '^[0-9]{4}$' OR v_cp ~ '^[A-Z][0-9]{4}[A-Z]{3}$' THEN v_cp END;
  v_obs       := nullif(left(btrim(coalesce(p->>'observaciones','')), 600), '');
  v_comercio  := nullif(left(btrim(regexp_replace(coalesce(p->>'comercio',''), '[\r\n\t]+', ' ', 'g')), 100), '');
  v_cuit      := nullif(left(regexp_replace(coalesce(p->>'cuit',''), '[^0-9\-]', '', 'g'), 15), '');
  v_mayorista := coalesce((p->>'es_mayorista')::boolean, false);
  v_canal     := CASE WHEN p->>'canal' = 'mayorista' THEN 'mayorista' ELSE 'web' END;
  v_entrega   := CASE WHEN p->>'tipo_entrega' IN ('envio','retiro') THEN p->>'tipo_entrega' ELSE 'a_confirmar' END;

  IF length(v_nombre) < 2 THEN
    RAISE EXCEPTION 'nombre_invalido' USING HINT = 'Ingresá tu nombre y apellido.';
  END IF;
  IF length(v_tel_digits) < 6 OR length(v_tel_digits) > 15 THEN
    RAISE EXCEPTION 'telefono_invalido' USING HINT = 'Ingresá un teléfono válido.';
  END IF;

  SELECT count(*) INTO v_n FROM solicitudes
   WHERE telefono = v_telefono AND created_at > now() - interval '1 hour';
  IF v_n >= 5 THEN
    RAISE EXCEPTION 'limite_solicitudes' USING HINT = 'Ya recibimos varias solicitudes tuyas. Escribinos directo por WhatsApp.';
  END IF;
  SELECT count(*) INTO v_n FROM solicitudes WHERE created_at > now() - interval '1 hour';
  IF v_n >= 60 THEN
    RAISE EXCEPTION 'limite_global' USING HINT = 'Intentá de nuevo en unos minutos.';
  END IF;

  v_items := coalesce(p->'items', '[]'::jsonb);
  IF jsonb_typeof(v_items) <> 'array' OR jsonb_array_length(v_items) > 30 THEN
    RAISE EXCEPTION 'items_invalidos';
  END IF;
  IF v_canal = 'web' AND jsonb_array_length(v_items) = 0 THEN
    RAISE EXCEPTION 'carrito_vacio' USING HINT = 'Agregá al menos un producto.';
  END IF;

  -- ── Chequeo de stock ANTES de crear nada (controlados con precio) ──
  FOR v_item IN SELECT * FROM jsonb_array_elements(v_items) LOOP
    BEGIN
      v_pid  := (v_item->>'id')::int;
      v_cant := least(greatest(coalesce((v_item->>'cantidad')::int, 1), 1), 999);
    EXCEPTION WHEN OTHERS THEN
      RAISE EXCEPTION 'items_invalidos';
    END;
    v_pedidos := v_pedidos || jsonb_build_object(v_pid::text, coalesce((v_pedidos->>v_pid::text)::int, 0) + v_cant);
  END LOOP;
  FOR v_pid, v_cant IN SELECT key::int, value::int FROM jsonb_each_text(v_pedidos) LOOP
    SELECT * INTO v_prod FROM productos WHERE id = v_pid AND estado = 'activo';
    IF NOT FOUND THEN CONTINUE; END IF;
    IF fn_precio_venta(v_prod) IS NOT NULL
       AND v_prod.seguimiento_inventario AND NOT v_prod.permite_venta_sin_stock
       AND v_prod.stock_controlado THEN
      v_disp := greatest(stock_disponible(v_prod), 0);
      IF v_cant > v_disp THEN
        v_sin_stock := v_sin_stock || jsonb_build_object('id', v_prod.id, 'nombre', v_prod.nombre,
                                                         'pedido', v_cant, 'disponible', v_disp);
      END IF;
    END IF;
  END LOOP;
  IF jsonb_array_length(v_sin_stock) > 0 THEN
    RAISE EXCEPTION 'sin_stock'
      USING DETAIL = v_sin_stock::text,
            HINT = 'Algunos productos ya no tienen stock disponible. Ajustá las cantidades del carrito.';
  END IF;

  v_codigo := 'MH-' || to_char(now(), 'YYMMDD') || '-' ||
              upper(substr(md5(random()::text || clock_timestamp()::text), 1, 4));

  INSERT INTO solicitudes (codigo, canal, cliente_nombre, telefono, localidad, direccion, codigo_postal,
                           tipo_entrega, es_mayorista, comercio, cuit, observaciones, estado)
  VALUES (v_codigo, v_canal, v_nombre, v_telefono, v_localidad, v_direccion, v_cp,
          v_entrega, v_mayorista, v_comercio, v_cuit, v_obs, 'nueva')
  RETURNING id INTO v_sol_id;

  FOR v_item IN SELECT * FROM jsonb_array_elements(v_items) LOOP
    v_pid  := (v_item->>'id')::int;
    v_cant := least(greatest(coalesce((v_item->>'cantidad')::int, 1), 1), 999);

    SELECT * INTO v_prod FROM productos WHERE id = v_pid AND estado = 'activo';
    IF NOT FOUND THEN
      CONTINUE;
    END IF;

    v_precio := fn_precio_venta(v_prod);
    -- Con precio pero stock sin controlar: sale, pero el stock se confirma por WhatsApp
    v_a_conf := v_precio IS NOT NULL AND v_prod.seguimiento_inventario
                AND NOT v_prod.permite_venta_sin_stock AND NOT v_prod.stock_controlado;

    INSERT INTO solicitud_items (solicitud_id, producto_id, nombre, sku, cantidad, precio_unitario, subtotal, stock_a_confirmar)
    VALUES (v_sol_id, v_prod.id, v_prod.nombre, v_prod.sku, v_cant, v_precio,
            CASE WHEN v_precio IS NULL THEN NULL ELSE round(v_precio * v_cant, 2) END, v_a_conf);

    IF v_precio IS NULL OR v_a_conf THEN
      v_pendientes := true;
    END IF;
    IF v_precio IS NOT NULL THEN
      v_hay_precio := true;
      v_total := v_total + round(v_precio * v_cant, 2);
    END IF;

    v_out_items := v_out_items || jsonb_build_object(
      'nombre', v_prod.nombre, 'sku', v_prod.sku, 'cantidad', v_cant, 'precio', v_precio,
      'stock_a_confirmar', v_a_conf);
  END LOOP;

  IF v_canal = 'web' AND jsonb_array_length(v_out_items) = 0 THEN
    RAISE EXCEPTION 'carrito_vacio' USING HINT = 'Los productos del carrito ya no están disponibles.';
  END IF;

  UPDATE solicitudes
     SET total_estimado   = CASE WHEN v_pendientes OR NOT v_hay_precio THEN NULL ELSE v_total END,
         tiene_pendientes = v_pendientes
   WHERE id = v_sol_id;

  RETURN jsonb_build_object(
    'codigo', v_codigo,
    'items', v_out_items,
    'total', CASE WHEN v_pendientes OR NOT v_hay_precio THEN NULL ELSE v_total END,
    'tiene_pendientes', v_pendientes
  );
END;
$func$;

REVOKE ALL ON FUNCTION crear_solicitud(JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION crear_solicitud(JSONB) TO anon, authenticated;
