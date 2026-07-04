-- ============================================================
-- 005 — FASE 2: Solicitudes de pedido/cotización por WhatsApp
-- Ejecutar en Supabase → SQL Editor (idempotente).
-- Requiere 001..004 (o setup-completo.sql) ya ejecutados.
-- ============================================================

-- ──────────────────────────────────────────────
-- TABLAS
-- ──────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS solicitudes (
  id                BIGSERIAL PRIMARY KEY,
  tenant_id         INT NOT NULL DEFAULT 1,        -- preparado para multiempresa (Fase 6)
  codigo            TEXT NOT NULL UNIQUE,
  canal             TEXT NOT NULL DEFAULT 'web'
                      CHECK (canal IN ('web', 'mayorista')),
  cliente_nombre    TEXT NOT NULL,
  telefono          TEXT NOT NULL,
  localidad         TEXT,
  direccion         TEXT,                          -- solo si pide envío
  tipo_entrega      TEXT NOT NULL DEFAULT 'a_confirmar'
                      CHECK (tipo_entrega IN ('envio', 'retiro', 'a_confirmar')),
  es_mayorista      BOOLEAN NOT NULL DEFAULT false,
  comercio          TEXT,
  cuit              TEXT,
  observaciones     TEXT,
  total_estimado    NUMERIC(12,2),                 -- NULL = total a confirmar
  tiene_pendientes  BOOLEAN NOT NULL DEFAULT false,-- hay items sin precio
  estado            TEXT NOT NULL DEFAULT 'nueva'
                      CHECK (estado IN ('nueva','contactado','cotizacion_enviada',
                                        'confirmado','en_preparacion','entregado','cancelado')),
  atendido_por      UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  notas_internas    TEXT,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_solicitudes_estado   ON solicitudes(estado);
CREATE INDEX IF NOT EXISTS idx_solicitudes_fecha    ON solicitudes(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_solicitudes_telefono ON solicitudes(telefono);

CREATE TABLE IF NOT EXISTS solicitud_items (
  id              BIGSERIAL PRIMARY KEY,
  solicitud_id    BIGINT NOT NULL REFERENCES solicitudes(id) ON DELETE CASCADE,
  producto_id     INT REFERENCES productos(id) ON DELETE SET NULL,
  nombre          TEXT NOT NULL,                   -- snapshot al momento de la solicitud
  sku             TEXT,
  cantidad        INT NOT NULL CHECK (cantidad BETWEEN 1 AND 999),
  precio_unitario NUMERIC(12,2),                   -- NULL = a confirmar (precio leído de la DB, nunca del navegador)
  subtotal        NUMERIC(12,2)
);

CREATE INDEX IF NOT EXISTS idx_solicitud_items_solicitud ON solicitud_items(solicitud_id);

CREATE OR REPLACE TRIGGER tr_solicitudes_updated_at
  BEFORE UPDATE ON solicitudes FOR EACH ROW EXECUTE FUNCTION fn_updated_at();

-- ──────────────────────────────────────────────
-- RLS: el público NO accede a las tablas; solo crea vía RPC.
-- El staff autenticado las ve y gestiona desde el panel.
-- ──────────────────────────────────────────────
ALTER TABLE solicitudes     ENABLE ROW LEVEL SECURITY;
ALTER TABLE solicitud_items ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "solicitudes_select_staff" ON solicitudes;
CREATE POLICY "solicitudes_select_staff" ON solicitudes FOR SELECT
  USING (auth.uid() IS NOT NULL);

DROP POLICY IF EXISTS "solicitudes_update_staff" ON solicitudes;
CREATE POLICY "solicitudes_update_staff" ON solicitudes FOR UPDATE
  USING (fn_get_user_role() IN ('administrador','vendedor'));

DROP POLICY IF EXISTS "solicitud_items_select_staff" ON solicitud_items;
CREATE POLICY "solicitud_items_select_staff" ON solicitud_items FOR SELECT
  USING (auth.uid() IS NOT NULL);

-- ──────────────────────────────────────────────
-- RPC pública: crea la solicitud validando TODO en servidor.
-- Los precios se releen de `productos`; lo que mande el navegador se ignora.
-- ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION crear_solicitud(p JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_nombre    TEXT;
  v_telefono  TEXT;
  v_tel_digits TEXT;
  v_localidad TEXT;
  v_direccion TEXT;
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
  v_prod      RECORD;
  v_precio    NUMERIC(12,2);
  v_total     NUMERIC(12,2) := 0;
  v_hay_precio BOOLEAN := false;
  v_pendientes BOOLEAN := false;
  v_sol_id    BIGINT;
  v_codigo    TEXT;
  v_out_items JSONB := '[]'::jsonb;
BEGIN
  -- ── Sanitizar y validar datos del cliente ──
  v_nombre   := left(btrim(regexp_replace(coalesce(p->>'nombre',''),    '[\r\n\t]+', ' ', 'g')), 80);
  v_telefono := left(regexp_replace(coalesce(p->>'telefono',''), '[^0-9+ ()\-]', '', 'g'), 25);
  v_tel_digits := regexp_replace(v_telefono, '\D', '', 'g');
  v_localidad := nullif(left(btrim(regexp_replace(coalesce(p->>'localidad',''), '[\r\n\t]+', ' ', 'g')), 80), '');
  v_direccion := nullif(left(btrim(regexp_replace(coalesce(p->>'direccion',''), '[\r\n\t]+', ' ', 'g')), 160), '');
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

  -- ── Anti-abuso: límite por teléfono y global por hora ──
  SELECT count(*) INTO v_n FROM solicitudes
   WHERE telefono = v_telefono AND created_at > now() - interval '1 hour';
  IF v_n >= 5 THEN
    RAISE EXCEPTION 'limite_solicitudes' USING HINT = 'Ya recibimos varias solicitudes tuyas. Escribinos directo por WhatsApp.';
  END IF;
  SELECT count(*) INTO v_n FROM solicitudes WHERE created_at > now() - interval '1 hour';
  IF v_n >= 60 THEN
    RAISE EXCEPTION 'limite_global' USING HINT = 'Intentá de nuevo en unos minutos.';
  END IF;

  -- ── Validar items ──
  v_items := coalesce(p->'items', '[]'::jsonb);
  IF jsonb_typeof(v_items) <> 'array' OR jsonb_array_length(v_items) > 30 THEN
    RAISE EXCEPTION 'items_invalidos';
  END IF;
  IF v_canal = 'web' AND jsonb_array_length(v_items) = 0 THEN
    RAISE EXCEPTION 'carrito_vacio' USING HINT = 'Agregá al menos un producto.';
  END IF;

  v_codigo := 'MH-' || to_char(now(), 'YYMMDD') || '-' ||
              upper(substr(md5(random()::text || clock_timestamp()::text), 1, 4));

  INSERT INTO solicitudes (codigo, canal, cliente_nombre, telefono, localidad, direccion,
                           tipo_entrega, es_mayorista, comercio, cuit, observaciones, estado)
  VALUES (v_codigo, v_canal, v_nombre, v_telefono, v_localidad, v_direccion,
          v_entrega, v_mayorista, v_comercio, v_cuit, v_obs, 'nueva')
  RETURNING id INTO v_sol_id;

  -- ── Items: releer producto y precio desde la base (fuente de verdad) ──
  FOR v_item IN SELECT * FROM jsonb_array_elements(v_items) LOOP
    BEGIN
      v_pid  := (v_item->>'id')::int;
      v_cant := least(greatest(coalesce((v_item->>'cantidad')::int, 1), 1), 999);
    EXCEPTION WHEN OTHERS THEN
      RAISE EXCEPTION 'items_invalidos';
    END;

    SELECT id, nombre, sku, precio_minorista, precio_oferta, en_oferta
      INTO v_prod FROM productos
     WHERE id = v_pid AND estado = 'activo';
    IF NOT FOUND THEN
      CONTINUE; -- producto inexistente o pausado: se omite, no rompe la solicitud
    END IF;

    v_precio := CASE
      WHEN v_prod.en_oferta AND coalesce(v_prod.precio_oferta, 0) > 0 THEN v_prod.precio_oferta
      WHEN coalesce(v_prod.precio_minorista, 0) > 0 THEN v_prod.precio_minorista
      ELSE NULL
    END;

    INSERT INTO solicitud_items (solicitud_id, producto_id, nombre, sku, cantidad, precio_unitario, subtotal)
    VALUES (v_sol_id, v_prod.id, v_prod.nombre, v_prod.sku, v_cant, v_precio,
            CASE WHEN v_precio IS NULL THEN NULL ELSE round(v_precio * v_cant, 2) END);

    IF v_precio IS NULL THEN
      v_pendientes := true;
    ELSE
      v_hay_precio := true;
      v_total := v_total + round(v_precio * v_cant, 2);
    END IF;

    v_out_items := v_out_items || jsonb_build_object(
      'nombre', v_prod.nombre, 'sku', v_prod.sku, 'cantidad', v_cant, 'precio', v_precio);
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
$$;

REVOKE ALL ON FUNCTION crear_solicitud(JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION crear_solicitud(JSONB) TO anon, authenticated;
