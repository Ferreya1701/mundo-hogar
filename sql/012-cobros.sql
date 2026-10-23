-- ============================================================
-- 012 — COBROS POR TRANSFERENCIA (2026-10-23)
-- Ejecutar en Supabase → SQL Editor, DESPUÉS del 011.
-- Idempotente: se puede correr más de una vez sin romper nada.
--
-- Qué agrega (gestor de ventas y cobros; NO factura ni habla con ARCA):
--   1) cuentas_cobro: las cuentas (alias/CVU de Mercado Pago u otro
--      banco) a las que el cliente transfiere. Reparto automático: cada
--      pedido va a la cuenta que menos acumuló en el mes (según su peso),
--      respetando límites diarios y mensuales.
--   2) Columnas de pago en solicitudes: estado_pago, cuenta asignada,
--      monto a pagar (con centavos únicos para reconocer la transferencia),
--      vencimiento.
--   3) comprobantes: lo que sube el cliente + lo que leyó la IA + el
--      resultado del cruce con el pedido.
--   4) movimientos_cobro: un renglón por pago confirmado (o anulado) en
--      cada cuenta. Es la base del reporte cuenta por cuenta.
--   5) liquidaciones: cierre mensual con el porcentaje de comisión.
--   6) RPCs públicas (anon) para la página /pedido/<código>: ver el pedido,
--      elegir pagar por transferencia, subir comprobante. Siempre con
--      código + teléfono del cliente.
--   7) RPCs del panel: confirmar pago, rechazar comprobante, anular pago,
--      habilitar pago de una cotización, cerrar liquidación.
--   8) Bucket privado 'comprobantes' en Storage.
--
-- El dinero entra a las cuentas del negocio. Este sistema solo registra
-- y ordena. Ver PROJECT_STATUS.md → Cobros.
-- ============================================================


-- ──────────────────────────────────────────────
-- 0) CONFIGURACIÓN (site_settings, una sola fila)
--    La tabla la crea setup-completo.sql; se repite acá (IF NOT EXISTS)
--    para que el script también corra en una base armada con 001..011.
-- ──────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS site_settings (
  id                        INT PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  nombre_tienda             TEXT,
  whatsapp                  TEXT,
  telefono                  TEXT,
  email                     TEXT,
  direccion                 TEXT,
  horarios                  TEXT,
  redes                     JSONB NOT NULL DEFAULT '{}'::jsonb,
  moneda                    TEXT NOT NULL DEFAULT 'ARS',
  mensaje_promo             TEXT,
  compra_minima_mayorista   NUMERIC(12,2),
  envio_info                TEXT,
  modo_mantenimiento        BOOLEAN NOT NULL DEFAULT false,
  updated_at                TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
ALTER TABLE site_settings ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "settings_select_public" ON site_settings;
CREATE POLICY "settings_select_public" ON site_settings FOR SELECT USING (true);
DROP POLICY IF EXISTS "settings_write_admin" ON site_settings;
CREATE POLICY "settings_write_admin" ON site_settings FOR ALL
  USING (fn_get_user_role() = 'administrador') WITH CHECK (fn_get_user_role() = 'administrador');
INSERT INTO site_settings (id) VALUES (1) ON CONFLICT (id) DO NOTHING;

ALTER TABLE site_settings ADD COLUMN IF NOT EXISTS cobros_activos        BOOLEAN NOT NULL DEFAULT false;
ALTER TABLE site_settings ADD COLUMN IF NOT EXISTS cobros_plazo_horas    INT     NOT NULL DEFAULT 72;
ALTER TABLE site_settings ADD COLUMN IF NOT EXISTS cobros_auto_confirmar BOOLEAN NOT NULL DEFAULT false;
ALTER TABLE site_settings ADD COLUMN IF NOT EXISTS comision_pct          NUMERIC(5,2) NOT NULL DEFAULT 0;
ALTER TABLE site_settings ADD COLUMN IF NOT EXISTS cobros_instrucciones  TEXT;
-- Carrito y pedidos visibles en la tienda pública. Apagado: la tienda es solo
-- catálogo + WhatsApp; el equipo igual puede probar el circuito completo
-- entrando con ?preview=1 (queda guardado en ese navegador).
ALTER TABLE site_settings ADD COLUMN IF NOT EXISTS carrito_activo        BOOLEAN NOT NULL DEFAULT false;


-- ──────────────────────────────────────────────
-- 1) CUENTAS DE COBRO
-- ──────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS cuentas_cobro (
  id              BIGSERIAL PRIMARY KEY,
  nombre          TEXT NOT NULL,                      -- etiqueta interna ("Cuenta 1 — Juan")
  titular         TEXT NOT NULL,                      -- como figura en la cuenta
  alias           TEXT,
  cvu             TEXT,                               -- CBU o CVU (22 dígitos)
  cuit_cuil       TEXT,
  banco           TEXT NOT NULL DEFAULT 'Mercado Pago',
  activa          BOOLEAN NOT NULL DEFAULT true,
  es_respaldo     BOOLEAN NOT NULL DEFAULT false,     -- se usa cuando ninguna otra puede tomar el pedido
  peso            INT NOT NULL DEFAULT 5 CHECK (peso BETWEEN 1 AND 10),
  orden           INT NOT NULL DEFAULT 0,             -- desempate
  limite_diario   NUMERIC(12,2) CHECK (limite_diario IS NULL OR limite_diario > 0),
  limite_mensual  NUMERIC(12,2) CHECK (limite_mensual IS NULL OR limite_mensual > 0),
  notas           TEXT,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT cuentas_cobro_destino CHECK (nullif(btrim(alias), '') IS NOT NULL OR nullif(btrim(cvu), '') IS NOT NULL)
);

CREATE OR REPLACE TRIGGER tr_cuentas_cobro_updated_at
  BEFORE UPDATE ON cuentas_cobro FOR EACH ROW EXECUTE FUNCTION fn_updated_at();


-- ──────────────────────────────────────────────
-- 2) PAGO EN LAS SOLICITUDES
-- ──────────────────────────────────────────────
ALTER TABLE solicitudes ADD COLUMN IF NOT EXISTS estado_pago TEXT NOT NULL DEFAULT 'sin_pago';
ALTER TABLE solicitudes DROP CONSTRAINT IF EXISTS solicitudes_estado_pago_check;
ALTER TABLE solicitudes ADD CONSTRAINT solicitudes_estado_pago_check
  CHECK (estado_pago IN ('sin_pago','pendiente','comprobante_recibido','en_revision','pagado','vencido'));
ALTER TABLE solicitudes ADD COLUMN IF NOT EXISTS cuenta_cobro_id    BIGINT REFERENCES cuentas_cobro(id) ON DELETE SET NULL;
ALTER TABLE solicitudes ADD COLUMN IF NOT EXISTS monto_a_pagar      NUMERIC(12,2);
ALTER TABLE solicitudes ADD COLUMN IF NOT EXISTS monto_pagado       NUMERIC(12,2) NOT NULL DEFAULT 0;
ALTER TABLE solicitudes ADD COLUMN IF NOT EXISTS pago_habilitado_en TIMESTAMPTZ;
ALTER TABLE solicitudes ADD COLUMN IF NOT EXISTS pago_vence_en      TIMESTAMPTZ;
ALTER TABLE solicitudes ADD COLUMN IF NOT EXISTS pagado_en          TIMESTAMPTZ;

CREATE INDEX IF NOT EXISTS idx_solicitudes_estado_pago ON solicitudes(estado_pago);
CREATE INDEX IF NOT EXISTS idx_solicitudes_cuenta_cobro ON solicitudes(cuenta_cobro_id);


-- ──────────────────────────────────────────────
-- 3) COMPROBANTES
--    estado: recibido (subido, sin leer) → coincide / no_coincide / ilegible
--            (resultado de la lectura) → aceptado / rechazado (decisión final)
-- ──────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS comprobantes (
  id              BIGSERIAL PRIMARY KEY,
  solicitud_id    BIGINT NOT NULL REFERENCES solicitudes(id) ON DELETE CASCADE,
  archivo         TEXT NOT NULL,                      -- ruta dentro del bucket 'comprobantes'
  mime            TEXT,
  tamano          INT,
  estado          TEXT NOT NULL DEFAULT 'recibido'
                    CHECK (estado IN ('recibido','coincide','no_coincide','ilegible','aceptado','rechazado')),
  lectura         JSONB,                              -- respuesta completa de la IA
  monto_leido     NUMERIC(12,2),
  fecha_leida     DATE,
  destino_leido   TEXT,                               -- alias / CVU / titular que figura como destino
  nro_operacion   TEXT,
  confianza       INT CHECK (confianza IS NULL OR confianza BETWEEN 0 AND 100),
  motivo          TEXT,                               -- por qué no coincide / por qué se rechazó
  leido_en        TIMESTAMPTZ,
  revisado_por    UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  revisado_en     TIMESTAMPTZ,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_comprobantes_solicitud ON comprobantes(solicitud_id);
CREATE INDEX IF NOT EXISTS idx_comprobantes_nro_op ON comprobantes(nro_operacion) WHERE nro_operacion IS NOT NULL;


-- ──────────────────────────────────────────────
-- 4) MOVIMIENTOS DE COBRO (libro inmutable por cuenta)
-- ──────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS movimientos_cobro (
  id              BIGSERIAL PRIMARY KEY,
  cuenta_cobro_id BIGINT NOT NULL REFERENCES cuentas_cobro(id),
  solicitud_id    BIGINT REFERENCES solicitudes(id) ON DELETE SET NULL,
  comprobante_id  BIGINT REFERENCES comprobantes(id) ON DELETE SET NULL,
  tipo            TEXT NOT NULL CHECK (tipo IN ('cobro','anulacion')),
  monto           NUMERIC(12,2) NOT NULL CHECK (monto > 0),   -- siempre positivo; el tipo da el signo
  fecha           TIMESTAMPTZ NOT NULL DEFAULT NOW(),         -- cuándo entró la plata
  nro_operacion   TEXT,
  detalle         TEXT,
  usuario_id      UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_mov_cobro_cuenta_fecha ON movimientos_cobro(cuenta_cobro_id, fecha DESC);
CREATE INDEX IF NOT EXISTS idx_mov_cobro_solicitud ON movimientos_cobro(solicitud_id);


-- ──────────────────────────────────────────────
-- 5) LIQUIDACIONES (cierre mensual de la comisión)
-- ──────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS liquidaciones (
  id              BIGSERIAL PRIMARY KEY,
  periodo         TEXT NOT NULL UNIQUE CHECK (periodo ~ '^\d{4}-\d{2}$'),   -- 'AAAA-MM'
  porcentaje      NUMERIC(5,2) NOT NULL,
  total_cobrado   NUMERIC(14,2) NOT NULL,
  comision        NUMERIC(14,2) NOT NULL,
  detalle         JSONB NOT NULL,                     -- por cuenta + pedidos incluidos
  cerrada_por     UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);


-- ──────────────────────────────────────────────
-- 6) RLS
--    - cuentas_cobro: todo el staff la ve (el panel de pedidos muestra el
--      alias asignado); solo administrador la edita.
--    - comprobantes: el staff ve; escribe solo por RPC.
--    - movimientos_cobro y liquidaciones: solo administrador ve; escribe
--      solo por RPC.
--    El público no toca ninguna tabla: entra por las RPC con código+teléfono.
-- ──────────────────────────────────────────────
ALTER TABLE cuentas_cobro     ENABLE ROW LEVEL SECURITY;
ALTER TABLE comprobantes      ENABLE ROW LEVEL SECURITY;
ALTER TABLE movimientos_cobro ENABLE ROW LEVEL SECURITY;
ALTER TABLE liquidaciones     ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "cuentas_cobro_select_staff" ON cuentas_cobro;
CREATE POLICY "cuentas_cobro_select_staff" ON cuentas_cobro FOR SELECT
  USING (auth.uid() IS NOT NULL);
DROP POLICY IF EXISTS "cuentas_cobro_write_admin" ON cuentas_cobro;
CREATE POLICY "cuentas_cobro_write_admin" ON cuentas_cobro FOR ALL
  USING (fn_get_user_role() = 'administrador') WITH CHECK (fn_get_user_role() = 'administrador');

DROP POLICY IF EXISTS "comprobantes_select_staff" ON comprobantes;
CREATE POLICY "comprobantes_select_staff" ON comprobantes FOR SELECT
  USING (auth.uid() IS NOT NULL);

DROP POLICY IF EXISTS "mov_cobro_select_admin" ON movimientos_cobro;
CREATE POLICY "mov_cobro_select_admin" ON movimientos_cobro FOR SELECT
  USING (fn_get_user_role() = 'administrador');

DROP POLICY IF EXISTS "liquidaciones_select_admin" ON liquidaciones;
CREATE POLICY "liquidaciones_select_admin" ON liquidaciones FOR SELECT
  USING (fn_get_user_role() = 'administrador');


-- ──────────────────────────────────────────────
-- 7) HELPERS
-- ──────────────────────────────────────────────
-- Zona horaria del negocio: "hoy" y "este mes" se cuentan en hora argentina.
CREATE OR REPLACE FUNCTION fn_mh_local(p TIMESTAMPTZ)
RETURNS TIMESTAMP LANGUAGE sql IMMUTABLE AS $$
  SELECT p AT TIME ZONE 'America/Argentina/Buenos_Aires'
$$;

-- ¿El teléfono que escribe el cliente es el del pedido? Usa la misma clave
-- que el CRM (fn_crm_tel_clave, sql/009): +54 9 / 0 / 15 escritos distinto
-- dan la misma clave.
CREATE OR REPLACE FUNCTION fn_tel_coincide(p_guardado TEXT, p_ingresado TEXT)
RETURNS BOOLEAN LANGUAGE sql IMMUTABLE SET search_path = public AS $$
  SELECT fn_crm_tel_clave(p_ingresado) IS NOT NULL
     AND fn_crm_tel_clave(p_guardado) = fn_crm_tel_clave(p_ingresado)
$$;

CREATE OR REPLACE FUNCTION fn_es_staff_ventas()
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT coalesce(fn_get_user_role(), '') IN ('administrador','vendedor')
$$;

-- Lo que la cuenta ya tiene "tomado" en un rango: cobros confirmados menos
-- anulaciones, MÁS los pedidos asignados que todavía esperan el pago
-- (así dos pedidos grandes del mismo día no caen en la misma cuenta).
CREATE OR REPLACE FUNCTION fn_cuenta_acumulado(p_cuenta BIGINT, p_desde TIMESTAMP)
RETURNS NUMERIC LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT coalesce((
    SELECT sum(CASE WHEN tipo = 'cobro' THEN monto ELSE -monto END)
      FROM movimientos_cobro
     WHERE cuenta_cobro_id = p_cuenta AND fn_mh_local(fecha) >= p_desde), 0)
  + coalesce((
    SELECT sum(monto_a_pagar)
      FROM solicitudes
     WHERE cuenta_cobro_id = p_cuenta
       AND estado_pago IN ('pendiente','comprobante_recibido','en_revision')
       AND fn_mh_local(pago_habilitado_en) >= p_desde), 0)
$$;

-- Elige la cuenta para un pedido de p_monto. NULL si ninguna puede.
CREATE OR REPLACE FUNCTION fn_cobros_elegir_cuenta(p_monto NUMERIC)
RETURNS BIGINT LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_hoy  TIMESTAMP := date_trunc('day',   fn_mh_local(now()));
  v_mes  TIMESTAMP := date_trunc('month', fn_mh_local(now()));
  v_id   BIGINT;
BEGIN
  SELECT c.id INTO v_id
    FROM cuentas_cobro c
   WHERE c.activa
     AND (c.limite_mensual IS NULL OR fn_cuenta_acumulado(c.id, v_mes) + p_monto <= c.limite_mensual)
     AND (c.limite_diario  IS NULL OR fn_cuenta_acumulado(c.id, v_hoy) + p_monto <= c.limite_diario)
   ORDER BY fn_cuenta_acumulado(c.id, v_mes) / c.peso ASC, c.orden ASC, c.id ASC
   LIMIT 1;
  IF v_id IS NOT NULL THEN RETURN v_id; END IF;

  -- Ninguna entra en sus límites: la de respaldo (sin mirar límites)
  SELECT c.id INTO v_id FROM cuentas_cobro c
   WHERE c.activa AND c.es_respaldo
   ORDER BY c.orden, c.id LIMIT 1;
  RETURN v_id;
END;
$$;

-- Monto a pagar con centavos únicos entre los pedidos pendientes de la misma
-- cuenta: así la transferencia se reconoce por el importe exacto.
-- Nunca cobra menos que el total: si el total trae centavos, se redondea
-- hacia arriba al peso y se le suman los centavos distintivos.
CREATE OR REPLACE FUNCTION fn_cobros_monto_unico(p_total NUMERIC, p_cuenta BIGINT)
RETURNS NUMERIC LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_base NUMERIC := ceil(p_total);
  v_cand NUMERIC;
  i INT;
BEGIN
  FOR i IN 1..40 LOOP
    v_cand := round(v_base + (1 + floor(random() * 99))::int / 100.0, 2);
    IF NOT EXISTS (
      SELECT 1 FROM solicitudes
       WHERE cuenta_cobro_id = p_cuenta
         AND monto_a_pagar = v_cand
         AND estado_pago IN ('pendiente','comprobante_recibido','en_revision')) THEN
      RETURN v_cand;
    END IF;
  END LOOP;
  RETURN v_cand; -- 40 colisiones seguidas: improbable; el panel igual revisa
END;
$$;

REVOKE ALL ON FUNCTION fn_cuenta_acumulado(BIGINT, TIMESTAMP) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION fn_cobros_elegir_cuenta(NUMERIC) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION fn_cobros_monto_unico(NUMERIC, BIGINT) FROM PUBLIC, anon, authenticated;


-- ──────────────────────────────────────────────
-- 8) cambiar_estado_solicitud: misma función del 007 con UN cambio:
--    también puede llamarla la vía interna (mh.interno = 1), para que la
--    confirmación de un pago pueda pasar el pedido a "confirmado" (y
--    descontar stock) aunque la dispare la confirmación automática de la
--    IA, que no tiene usuario del panel.
-- ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION cambiar_estado_solicitud(
  p_solicitud_id BIGINT,
  p_nuevo_estado TEXT
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $func$
DECLARE
  v_sol        solicitudes%ROWTYPE;
  v_item       RECORD;
  v_faltantes  JSONB := '[]'::jsonb;
  v_movs       INT := 0;
  v_permitidas TEXT[];
  v_interno    BOOLEAN := coalesce(current_setting('mh.interno', true), '') = '1';
BEGIN
  IF NOT v_interno AND coalesce(fn_get_user_role(), '') NOT IN ('administrador','vendedor') THEN
    RAISE EXCEPTION 'sin_permiso' USING HINT = 'Tu rol no puede cambiar estados de solicitudes.';
  END IF;

  SELECT * INTO v_sol FROM solicitudes WHERE id = p_solicitud_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'solicitud_no_encontrada';
  END IF;

  v_permitidas := CASE v_sol.estado
    WHEN 'nueva'              THEN ARRAY['contactado','cotizacion_enviada','confirmado','cancelado']
    WHEN 'contactado'         THEN ARRAY['cotizacion_enviada','confirmado','cancelado']
    WHEN 'cotizacion_enviada' THEN ARRAY['confirmado','cancelado']
    WHEN 'confirmado'         THEN ARRAY['en_preparacion','entregado','cancelado']
    WHEN 'en_preparacion'     THEN ARRAY['entregado','cancelado']
    ELSE ARRAY[]::TEXT[]
  END;

  IF p_nuevo_estado = v_sol.estado THEN
    RETURN jsonb_build_object('ok', true, 'estado', v_sol.estado, 'sin_cambios', true);
  END IF;
  IF NOT (p_nuevo_estado = ANY (v_permitidas)) THEN
    RAISE EXCEPTION 'transicion_invalida'
      USING HINT = format('No se puede pasar de "%s" a "%s".', v_sol.estado, p_nuevo_estado);
  END IF;

  PERFORM set_config('mh.interno', '1', true);

  IF p_nuevo_estado = 'confirmado' AND NOT v_sol.stock_descontado THEN
    SELECT coalesce(jsonb_agg(jsonb_build_object(
             'producto_id', t.producto_id, 'nombre', t.nombre,
             'pedido', t.pedido, 'disponible', t.stock_actual)), '[]'::jsonb)
      INTO v_faltantes
      FROM (
        SELECT i.producto_id, min(p.nombre) AS nombre,
               sum(i.cantidad)::int AS pedido, min(p.stock_actual) AS stock_actual
          FROM solicitud_items i
          JOIN productos p ON p.id = i.producto_id
         WHERE i.solicitud_id = v_sol.id
           AND p.seguimiento_inventario
           AND NOT p.permite_venta_sin_stock
         GROUP BY i.producto_id
        HAVING sum(i.cantidad) > min(p.stock_actual)
      ) t;

    IF jsonb_array_length(v_faltantes) > 0 THEN
      RAISE EXCEPTION 'stock_insuficiente'
        USING DETAIL = v_faltantes::text,
              HINT = 'Ajustá el stock en Inventario o cancelá la solicitud.';
    END IF;

    FOR v_item IN
      SELECT i.producto_id, i.cantidad, p.permite_venta_sin_stock
        FROM solicitud_items i
        JOIN productos p ON p.id = i.producto_id
       WHERE i.solicitud_id = v_sol.id
         AND p.seguimiento_inventario
    LOOP
      PERFORM fn_registrar_movimiento(
        v_item.producto_id, 'salida_venta', v_item.cantidad,
        'Solicitud confirmada', NULL, v_sol.codigo, v_item.permite_venta_sin_stock);
      v_movs := v_movs + 1;
    END LOOP;

    UPDATE solicitudes SET stock_descontado = true WHERE id = v_sol.id;
  END IF;

  IF p_nuevo_estado = 'cancelado' AND v_sol.stock_descontado THEN
    FOR v_item IN
      SELECT i.producto_id, i.cantidad
        FROM solicitud_items i
        JOIN productos p ON p.id = i.producto_id
       WHERE i.solicitud_id = v_sol.id
         AND p.seguimiento_inventario
    LOOP
      PERFORM fn_registrar_movimiento(
        v_item.producto_id, 'devolucion_cliente', v_item.cantidad,
        'Solicitud cancelada', NULL, v_sol.codigo, false);
      v_movs := v_movs + 1;
    END LOOP;

    UPDATE solicitudes SET stock_descontado = false WHERE id = v_sol.id;
  END IF;

  UPDATE solicitudes
     SET estado = p_nuevo_estado,
         atendido_por = coalesce(atendido_por, auth.uid())
   WHERE id = v_sol.id;

  INSERT INTO solicitud_eventos (solicitud_id, estado_anterior, estado_nuevo, detalle, usuario_id)
  VALUES (v_sol.id, v_sol.estado, p_nuevo_estado,
          CASE WHEN v_movs > 0 THEN format('%s movimiento(s) de stock', v_movs) END,
          auth.uid());

  RETURN jsonb_build_object('ok', true, 'estado', p_nuevo_estado, 'movimientos', v_movs);
END;
$func$;

REVOKE ALL ON FUNCTION cambiar_estado_solicitud(BIGINT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION cambiar_estado_solicitud(BIGINT, TEXT) TO authenticated;


-- ──────────────────────────────────────────────
-- 9) NÚCLEO: habilitar el pago de un pedido
--    (lo usan la RPC pública y la del panel)
-- ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_cobros_habilitar(p_solicitud_id BIGINT, p_monto NUMERIC, p_origen TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_sol     solicitudes%ROWTYPE;
  v_cta     cuentas_cobro%ROWTYPE;
  v_total   NUMERIC;
  v_monto   NUMERIC;
  v_plazo   INT;
BEGIN
  SELECT * INTO v_sol FROM solicitudes WHERE id = p_solicitud_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'pedido_no_encontrado'; END IF;

  IF v_sol.estado IN ('cancelado','entregado') THEN
    RAISE EXCEPTION 'pedido_cerrado' USING HINT = 'El pedido ya está cerrado.';
  END IF;
  IF v_sol.estado_pago = 'pagado' THEN
    RAISE EXCEPTION 'pedido_ya_pagado' USING HINT = 'Este pedido ya figura pagado.';
  END IF;

  -- Ya habilitado: devolver lo mismo (idempotente), salvo que el panel mande otro monto
  IF v_sol.estado_pago IN ('pendiente','comprobante_recibido','en_revision')
     AND v_sol.cuenta_cobro_id IS NOT NULL
     AND (p_monto IS NULL OR ceil(p_monto) = floor(v_sol.monto_a_pagar)) THEN
    SELECT * INTO v_cta FROM cuentas_cobro WHERE id = v_sol.cuenta_cobro_id;
    RETURN jsonb_build_object('ok', true, 'sin_cambios', true, 'codigo', v_sol.codigo,
      'monto', v_sol.monto_a_pagar, 'vence_en', v_sol.pago_vence_en, 'estado_pago', v_sol.estado_pago,
      'cuenta', jsonb_build_object('alias', v_cta.alias, 'cvu', v_cta.cvu, 'titular', v_cta.titular, 'banco', v_cta.banco));
  END IF;
  IF v_sol.estado_pago IN ('comprobante_recibido','en_revision') THEN
    RAISE EXCEPTION 'pedido_con_comprobante' USING HINT = 'Ya hay un comprobante en revisión; no se puede cambiar el monto.';
  END IF;

  v_total := coalesce(p_monto, v_sol.total_estimado);
  IF v_total IS NULL OR v_total <= 0 THEN
    RAISE EXCEPTION 'pedido_sin_total' USING HINT = 'El pedido no tiene un total definido todavía.';
  END IF;
  IF p_monto IS NULL AND v_sol.tiene_pendientes THEN
    RAISE EXCEPTION 'pedido_a_cotizar' USING HINT = 'Hay productos a cotizar: el total se confirma por WhatsApp.';
  END IF;

  SELECT * INTO v_cta FROM cuentas_cobro WHERE id = fn_cobros_elegir_cuenta(v_total);
  IF NOT FOUND THEN
    RAISE EXCEPTION 'sin_cuenta_cobro' USING HINT = 'No hay una cuenta disponible para cobrar ahora. Escribinos por WhatsApp.';
  END IF;

  v_monto := fn_cobros_monto_unico(v_total, v_cta.id);
  SELECT coalesce(cobros_plazo_horas, 72) INTO v_plazo FROM site_settings WHERE id = 1;

  UPDATE solicitudes
     SET estado_pago = 'pendiente',
         cuenta_cobro_id = v_cta.id,
         monto_a_pagar = v_monto,
         pago_habilitado_en = now(),
         pago_vence_en = now() + make_interval(hours => coalesce(v_plazo, 72))
   WHERE id = v_sol.id;

  INSERT INTO solicitud_eventos (solicitud_id, estado_anterior, estado_nuevo, detalle, usuario_id)
  VALUES (v_sol.id, v_sol.estado, v_sol.estado,
          format('Pago por transferencia habilitado (%s): %s en %s', p_origen,
                 to_char(v_monto, 'FM999G999G999D00'), v_cta.nombre),
          auth.uid());

  RETURN jsonb_build_object('ok', true, 'codigo', v_sol.codigo, 'monto', v_monto,
    'vence_en', now() + make_interval(hours => coalesce(v_plazo, 72)), 'estado_pago', 'pendiente',
    'cuenta', jsonb_build_object('alias', v_cta.alias, 'cvu', v_cta.cvu, 'titular', v_cta.titular, 'banco', v_cta.banco));
END;
$$;
REVOKE ALL ON FUNCTION fn_cobros_habilitar(BIGINT, NUMERIC, TEXT) FROM PUBLIC, anon, authenticated;


-- ──────────────────────────────────────────────
-- 10) NÚCLEO: confirmar un pago (registra el movimiento, marca pagado y
--     pasa el pedido a "confirmado", que descuenta stock)
-- ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_cobros_confirmar(
  p_solicitud_id  BIGINT,
  p_comprobante_id BIGINT,
  p_monto         NUMERIC,
  p_nro_operacion TEXT,
  p_fecha         TIMESTAMPTZ,
  p_detalle       TEXT,
  p_cuenta_id     BIGINT
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_sol    solicitudes%ROWTYPE;
  v_cta    BIGINT;
  v_monto  NUMERIC;
  v_mov    BIGINT;
  v_estado JSONB := NULL;
BEGIN
  SELECT * INTO v_sol FROM solicitudes WHERE id = p_solicitud_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'pedido_no_encontrado'; END IF;
  IF v_sol.estado_pago = 'pagado' THEN
    RETURN jsonb_build_object('ok', true, 'sin_cambios', true, 'estado_pago', 'pagado');
  END IF;
  IF v_sol.estado = 'cancelado' THEN
    RAISE EXCEPTION 'pedido_cerrado' USING HINT = 'El pedido está cancelado. Reabrilo antes de registrar el pago.';
  END IF;

  v_cta := coalesce(p_cuenta_id, v_sol.cuenta_cobro_id);
  IF v_cta IS NULL THEN
    RAISE EXCEPTION 'sin_cuenta' USING HINT = 'Indicá en qué cuenta entró el pago.';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM cuentas_cobro WHERE id = v_cta) THEN
    RAISE EXCEPTION 'cuenta_no_encontrada';
  END IF;

  v_monto := coalesce(p_monto, v_sol.monto_a_pagar, v_sol.total_estimado);
  IF v_monto IS NULL OR v_monto <= 0 THEN
    RAISE EXCEPTION 'monto_invalido' USING HINT = 'Indicá el monto que entró.';
  END IF;

  INSERT INTO movimientos_cobro (cuenta_cobro_id, solicitud_id, comprobante_id, tipo, monto, fecha, nro_operacion, detalle, usuario_id)
  VALUES (v_cta, v_sol.id, p_comprobante_id, 'cobro', v_monto, coalesce(p_fecha, now()), nullif(btrim(p_nro_operacion), ''), p_detalle, auth.uid())
  RETURNING id INTO v_mov;

  UPDATE solicitudes
     SET estado_pago = 'pagado', monto_pagado = v_monto, pagado_en = coalesce(p_fecha, now()),
         cuenta_cobro_id = v_cta
   WHERE id = v_sol.id;

  IF p_comprobante_id IS NOT NULL THEN
    UPDATE comprobantes SET estado = 'aceptado', revisado_por = auth.uid(), revisado_en = now()
     WHERE id = p_comprobante_id AND solicitud_id = v_sol.id;
  END IF;

  -- El pedido pasa a confirmado (descuenta stock). Si el stock no alcanza,
  -- TODO se deshace y el panel muestra el detalle: primero se ajusta stock.
  IF v_sol.estado IN ('nueva','contactado','cotizacion_enviada') THEN
    PERFORM set_config('mh.interno', '1', true);
    v_estado := cambiar_estado_solicitud(v_sol.id, 'confirmado');
  END IF;

  INSERT INTO solicitud_eventos (solicitud_id, estado_anterior, estado_nuevo, detalle, usuario_id)
  VALUES (v_sol.id, coalesce(v_estado->>'estado', v_sol.estado), coalesce(v_estado->>'estado', v_sol.estado),
          format('Pago confirmado: %s%s', to_char(v_monto, 'FM999G999G999D00'),
                 CASE WHEN p_detalle IS NOT NULL THEN ' · ' || p_detalle ELSE '' END),
          auth.uid());

  RETURN jsonb_build_object('ok', true, 'estado_pago', 'pagado', 'movimiento_id', v_mov,
                            'monto', v_monto, 'estado', coalesce(v_estado->>'estado', v_sol.estado),
                            'movimientos_stock', coalesce((v_estado->>'movimientos')::int, 0));
END;
$$;
REVOKE ALL ON FUNCTION fn_cobros_confirmar(BIGINT, BIGINT, NUMERIC, TEXT, TIMESTAMPTZ, TEXT, BIGINT) FROM PUBLIC, anon, authenticated;


-- ──────────────────────────────────────────────
-- 11) RPC PÚBLICAS (anon): página /pedido/<código>
--     Siempre código + teléfono. Nunca devuelven datos de otros pedidos.
-- ──────────────────────────────────────────────

-- Marca vencidos los pagos pendientes sin comprobante que pasaron el plazo.
CREATE OR REPLACE FUNCTION fn_cobros_vencer(p_solicitud_id BIGINT DEFAULT NULL)
RETURNS INT LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_n INT;
BEGIN
  WITH v AS (
    UPDATE solicitudes s
       SET estado_pago = 'vencido'
     WHERE s.estado_pago = 'pendiente'
       AND s.pago_vence_en < now()
       AND (p_solicitud_id IS NULL OR s.id = p_solicitud_id)
       AND NOT EXISTS (SELECT 1 FROM comprobantes c WHERE c.solicitud_id = s.id AND c.estado <> 'rechazado')
    RETURNING s.id, s.estado
  )
  INSERT INTO solicitud_eventos (solicitud_id, estado_anterior, estado_nuevo, detalle)
  SELECT id, estado, estado, 'Pago vencido: no llegó el comprobante en el plazo' FROM v;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END;
$$;
REVOKE ALL ON FUNCTION fn_cobros_vencer(BIGINT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION fn_cobros_vencer(BIGINT) TO authenticated;

CREATE OR REPLACE FUNCTION pedido_consultar(p_codigo TEXT, p_telefono TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_sol   solicitudes%ROWTYPE;
  v_cta   cuentas_cobro%ROWTYPE;
  v_set   site_settings%ROWTYPE;
  v_items JSONB;
  v_comps JSONB;
  v_puede BOOLEAN;
BEGIN
  SELECT * INTO v_sol FROM solicitudes WHERE codigo = upper(btrim(p_codigo));
  IF NOT FOUND OR NOT fn_tel_coincide(v_sol.telefono, p_telefono) THEN
    RAISE EXCEPTION 'pedido_no_encontrado' USING HINT = 'No encontramos un pedido con ese código y teléfono.';
  END IF;

  PERFORM fn_cobros_vencer(v_sol.id);
  SELECT * INTO v_sol FROM solicitudes WHERE id = v_sol.id;
  SELECT * INTO v_set FROM site_settings WHERE id = 1;

  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'nombre', i.nombre, 'sku', i.sku, 'cantidad', i.cantidad,
           'precio', i.precio_unitario, 'subtotal', i.subtotal) ORDER BY i.id), '[]'::jsonb)
    INTO v_items FROM solicitud_items i WHERE i.solicitud_id = v_sol.id;

  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'id', c.id, 'estado', c.estado, 'motivo', c.motivo,
           'monto_leido', c.monto_leido, 'fecha', c.created_at) ORDER BY c.id), '[]'::jsonb)
    INTO v_comps FROM comprobantes c WHERE c.solicitud_id = v_sol.id;

  IF v_sol.cuenta_cobro_id IS NOT NULL THEN
    SELECT * INTO v_cta FROM cuentas_cobro WHERE id = v_sol.cuenta_cobro_id;
  END IF;

  v_puede := coalesce(v_set.cobros_activos, false)
         AND v_sol.estado NOT IN ('cancelado','entregado')
         AND v_sol.estado_pago IN ('sin_pago','vencido')
         AND coalesce(v_sol.total_estimado, 0) > 0
         AND NOT v_sol.tiene_pendientes;

  RETURN jsonb_build_object(
    'codigo', v_sol.codigo,
    'fecha', v_sol.created_at,
    'cliente', v_sol.cliente_nombre,
    'estado', v_sol.estado,
    'estado_pago', v_sol.estado_pago,
    'tipo_entrega', v_sol.tipo_entrega,
    'localidad', v_sol.localidad,
    'items', v_items,
    'total', v_sol.total_estimado,
    'tiene_pendientes', v_sol.tiene_pendientes,
    'monto_a_pagar', v_sol.monto_a_pagar,
    'monto_pagado', CASE WHEN v_sol.estado_pago = 'pagado' THEN v_sol.monto_pagado END,
    'vence_en', v_sol.pago_vence_en,
    'pagado_en', v_sol.pagado_en,
    'puede_pagar', v_puede,
    'cobros_activos', coalesce(v_set.cobros_activos, false),
    'instrucciones', v_set.cobros_instrucciones,
    'cuenta', CASE WHEN v_sol.estado_pago IN ('pendiente','comprobante_recibido','en_revision') AND v_cta.id IS NOT NULL
                   THEN jsonb_build_object('alias', v_cta.alias, 'cvu', v_cta.cvu, 'titular', v_cta.titular, 'banco', v_cta.banco) END,
    'comprobantes', v_comps
  );
END;
$$;
REVOKE ALL ON FUNCTION pedido_consultar(TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pedido_consultar(TEXT, TEXT) TO anon, authenticated;

CREATE OR REPLACE FUNCTION pedido_pagar_transferencia(p_codigo TEXT, p_telefono TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_sol solicitudes%ROWTYPE;
  v_activo BOOLEAN;
BEGIN
  SELECT cobros_activos INTO v_activo FROM site_settings WHERE id = 1;
  IF NOT coalesce(v_activo, false) THEN
    RAISE EXCEPTION 'cobros_inactivos' USING HINT = 'El pago online no está habilitado por ahora.';
  END IF;
  SELECT * INTO v_sol FROM solicitudes WHERE codigo = upper(btrim(p_codigo));
  IF NOT FOUND OR NOT fn_tel_coincide(v_sol.telefono, p_telefono) THEN
    RAISE EXCEPTION 'pedido_no_encontrado' USING HINT = 'No encontramos un pedido con ese código y teléfono.';
  END IF;
  RETURN fn_cobros_habilitar(v_sol.id, NULL, 'web');
END;
$$;
REVOKE ALL ON FUNCTION pedido_pagar_transferencia(TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pedido_pagar_transferencia(TEXT, TEXT) TO anon, authenticated;

-- El archivo ya tiene que estar subido al bucket 'comprobantes' en la
-- carpeta del código (MH-.../archivo). Acá solo se registra.
CREATE OR REPLACE FUNCTION pedido_subir_comprobante(
  p_codigo TEXT, p_telefono TEXT, p_archivo TEXT, p_mime TEXT, p_tamano INT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_sol solicitudes%ROWTYPE;
  v_n   INT;
  v_id  BIGINT;
  v_existe BOOLEAN := true;
BEGIN
  SELECT * INTO v_sol FROM solicitudes WHERE codigo = upper(btrim(p_codigo)) FOR UPDATE;
  IF NOT FOUND OR NOT fn_tel_coincide(v_sol.telefono, p_telefono) THEN
    RAISE EXCEPTION 'pedido_no_encontrado' USING HINT = 'No encontramos un pedido con ese código y teléfono.';
  END IF;
  IF v_sol.estado_pago NOT IN ('pendiente','comprobante_recibido','en_revision','vencido') THEN
    RAISE EXCEPTION 'pedido_sin_pago_pendiente' USING HINT = 'Este pedido no está esperando un pago.';
  END IF;
  IF p_archivo IS NULL OR position(v_sol.codigo || '/' IN p_archivo) <> 1 OR p_archivo ~ '\.\.' THEN
    RAISE EXCEPTION 'archivo_invalido';
  END IF;
  SELECT count(*) INTO v_n FROM comprobantes WHERE solicitud_id = v_sol.id;
  IF v_n >= 5 THEN
    RAISE EXCEPTION 'limite_comprobantes' USING HINT = 'Ya subiste varios comprobantes. Escribinos por WhatsApp.';
  END IF;
  -- En Supabase verificamos que el archivo exista en Storage
  IF to_regclass('storage.objects') IS NOT NULL THEN
    EXECUTE 'SELECT EXISTS (SELECT 1 FROM storage.objects WHERE bucket_id = ''comprobantes'' AND name = $1)'
       INTO v_existe USING p_archivo;
    IF NOT v_existe THEN
      RAISE EXCEPTION 'archivo_no_subido' USING HINT = 'El archivo no llegó. Probá de nuevo.';
    END IF;
  END IF;

  INSERT INTO comprobantes (solicitud_id, archivo, mime, tamano)
  VALUES (v_sol.id, p_archivo, left(p_mime, 80), p_tamano) RETURNING id INTO v_id;

  -- Un pago vencido que recibe comprobante vuelve a estar en juego
  UPDATE solicitudes SET estado_pago = 'comprobante_recibido' WHERE id = v_sol.id;

  INSERT INTO solicitud_eventos (solicitud_id, estado_anterior, estado_nuevo, detalle)
  VALUES (v_sol.id, v_sol.estado, v_sol.estado, 'El cliente subió un comprobante');

  RETURN jsonb_build_object('ok', true, 'comprobante_id', v_id, 'estado_pago', 'comprobante_recibido');
END;
$$;
REVOKE ALL ON FUNCTION pedido_subir_comprobante(TEXT, TEXT, TEXT, TEXT, INT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pedido_subir_comprobante(TEXT, TEXT, TEXT, TEXT, INT) TO anon, authenticated;


-- ──────────────────────────────────────────────
-- 12) LECTURA DEL COMPROBANTE (la llama la Edge Function con la clave de
--     servicio; ni anon ni el panel pueden ejecutarla)
--     p_lectura: { legible, monto, fecha, destino_alias, destino_cvu,
--                  destino_titular, origen, nro_operacion, confianza, notas }
-- ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION comprobante_registrar_lectura(p_comprobante_id BIGINT, p_lectura JSONB)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_c       comprobantes%ROWTYPE;
  v_sol     solicitudes%ROWTYPE;
  v_cta     cuentas_cobro%ROWTYPE;
  v_set     site_settings%ROWTYPE;
  v_monto   NUMERIC;
  v_fecha   DATE;
  v_alias   TEXT := lower(regexp_replace(coalesce(p_lectura->>'destino_alias', ''), '\s', '', 'g'));
  v_cvu     TEXT := regexp_replace(coalesce(p_lectura->>'destino_cvu', ''), '\D', '', 'g');
  v_titular TEXT := lower(btrim(coalesce(p_lectura->>'destino_titular', '')));
  v_nro     TEXT := nullif(left(btrim(coalesce(p_lectura->>'nro_operacion', '')), 60), '');
  v_conf    INT  := least(greatest(coalesce((p_lectura->>'confianza')::int, 0), 0), 100);
  v_estado  TEXT := 'coincide';
  v_motivos TEXT[] := ARRAY[]::TEXT[];
  v_dup     TEXT;
  v_auto    JSONB := NULL;
BEGIN
  SELECT * INTO v_c FROM comprobantes WHERE id = p_comprobante_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'comprobante_no_encontrado'; END IF;
  IF v_c.estado IN ('aceptado','rechazado') THEN
    RETURN jsonb_build_object('ok', true, 'sin_cambios', true, 'estado', v_c.estado);
  END IF;
  SELECT * INTO v_sol FROM solicitudes WHERE id = v_c.solicitud_id FOR UPDATE;
  SELECT * INTO v_cta FROM cuentas_cobro WHERE id = v_sol.cuenta_cobro_id;
  SELECT * INTO v_set FROM site_settings WHERE id = 1;

  BEGIN v_monto := (p_lectura->>'monto')::numeric; EXCEPTION WHEN OTHERS THEN v_monto := NULL; END;
  BEGIN v_fecha := (p_lectura->>'fecha')::date;    EXCEPTION WHEN OTHERS THEN v_fecha := NULL; END;

  IF NOT coalesce((p_lectura->>'legible')::boolean, false) OR v_conf < 40 OR v_monto IS NULL THEN
    v_estado := 'ilegible';
    v_motivos := array_append(v_motivos, coalesce(nullif(left(p_lectura->>'notas', 200), ''), 'No se pudo leer con claridad el comprobante'));
  ELSE
    IF v_sol.monto_a_pagar IS NOT NULL AND abs(v_monto - v_sol.monto_a_pagar) > 0.005 THEN
      v_estado := 'no_coincide';
      v_motivos := array_append(v_motivos, format('Monto leído %s, esperado %s',
        to_char(v_monto, 'FM999G999G999D00'), to_char(v_sol.monto_a_pagar, 'FM999G999G999D00')));
    END IF;
    IF v_cta.id IS NOT NULL AND (v_alias <> '' OR length(v_cvu) >= 10) THEN
      IF NOT ( (v_alias <> '' AND v_alias = lower(regexp_replace(coalesce(v_cta.alias, ''), '\s', '', 'g')))
            OR (length(v_cvu) >= 10 AND v_cvu = regexp_replace(coalesce(v_cta.cvu, ''), '\D', '', 'g')) ) THEN
        v_estado := 'no_coincide';
        v_motivos := array_append(v_motivos, format('Cuenta destino distinta (leída: %s)', nullif(coalesce(nullif(v_alias,''), v_cvu), '')));
      END IF;
    ELSIF v_cta.id IS NOT NULL AND v_titular <> '' AND v_cta.titular IS NOT NULL
          AND position(split_part(lower(v_cta.titular), ' ', 1) IN v_titular) = 0 THEN
      v_estado := 'no_coincide';
      v_motivos := array_append(v_motivos, format('Titular destino distinto (leído: %s)', v_titular));
    END IF;
    IF v_fecha IS NOT NULL AND v_sol.pago_habilitado_en IS NOT NULL
       AND v_fecha < (fn_mh_local(v_sol.pago_habilitado_en)::date - 1) THEN
      v_estado := 'no_coincide';
      v_motivos := array_append(v_motivos, format('Fecha del comprobante (%s) anterior al pedido', to_char(v_fecha, 'DD/MM/YYYY')));
    END IF;
    IF v_nro IS NOT NULL THEN
      SELECT s.codigo INTO v_dup
        FROM comprobantes c JOIN solicitudes s ON s.id = c.solicitud_id
       WHERE c.nro_operacion = v_nro AND c.solicitud_id <> v_sol.id
         AND c.estado IN ('coincide','aceptado') LIMIT 1;
      IF v_dup IS NOT NULL THEN
        v_estado := 'no_coincide';
        v_motivos := array_append(v_motivos, format('El número de operación ya se usó en el pedido %s', v_dup));
      END IF;
    END IF;
  END IF;

  UPDATE comprobantes
     SET estado = v_estado, lectura = p_lectura, monto_leido = v_monto, fecha_leida = v_fecha,
         destino_leido = nullif(coalesce(nullif(p_lectura->>'destino_alias',''), nullif(p_lectura->>'destino_cvu',''), p_lectura->>'destino_titular'), ''),
         nro_operacion = v_nro, confianza = v_conf,
         motivo = nullif(array_to_string(v_motivos, ' · '), ''), leido_en = now()
   WHERE id = v_c.id;

  IF v_sol.estado_pago IN ('comprobante_recibido','pendiente','vencido') THEN
    UPDATE solicitudes SET estado_pago = 'en_revision' WHERE id = v_sol.id;
  END IF;

  INSERT INTO solicitud_eventos (solicitud_id, estado_anterior, estado_nuevo, detalle)
  VALUES (v_sol.id, v_sol.estado, v_sol.estado,
          CASE v_estado WHEN 'coincide' THEN 'Comprobante leído: coincide con el pedido'
                        ELSE 'Comprobante leído: ' || coalesce(array_to_string(v_motivos, ' · '), v_estado) END);

  -- Confirmación automática (opcional, desde Configuración)
  IF v_estado = 'coincide' AND coalesce(v_set.cobros_auto_confirmar, false) AND v_conf >= 80 THEN
    BEGIN
      v_auto := fn_cobros_confirmar(v_sol.id, v_c.id, NULL, v_nro, coalesce(v_fecha::timestamptz, now()),
                                    'Confirmación automática por comprobante leído', NULL);
    EXCEPTION WHEN OTHERS THEN
      -- p.ej. stock insuficiente: queda en revisión con el motivo a la vista
      UPDATE comprobantes SET motivo = 'No se pudo confirmar solo: ' || SQLERRM WHERE id = v_c.id;
      v_auto := jsonb_build_object('ok', false, 'error', SQLERRM);
    END;
  END IF;

  RETURN jsonb_build_object('ok', true, 'estado', v_estado, 'motivo', nullif(array_to_string(v_motivos, ' · '), ''),
                            'auto', v_auto);
END;
$$;
REVOKE ALL ON FUNCTION comprobante_registrar_lectura(BIGINT, JSONB) FROM PUBLIC, anon, authenticated;


-- ──────────────────────────────────────────────
-- 13) RPC DEL PANEL
-- ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION habilitar_pago(p_solicitud_id BIGINT, p_monto NUMERIC DEFAULT NULL)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT fn_es_staff_ventas() THEN
    RAISE EXCEPTION 'sin_permiso' USING HINT = 'Tu rol no puede habilitar pagos.';
  END IF;
  IF p_monto IS NOT NULL AND p_monto <= 0 THEN
    RAISE EXCEPTION 'monto_invalido' USING HINT = 'El monto tiene que ser mayor a cero.';
  END IF;
  RETURN fn_cobros_habilitar(p_solicitud_id, p_monto, 'panel');
END;
$$;
REVOKE ALL ON FUNCTION habilitar_pago(BIGINT, NUMERIC) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION habilitar_pago(BIGINT, NUMERIC) TO authenticated;

CREATE OR REPLACE FUNCTION confirmar_pago(
  p_solicitud_id   BIGINT,
  p_comprobante_id BIGINT DEFAULT NULL,
  p_monto          NUMERIC DEFAULT NULL,
  p_nro_operacion  TEXT DEFAULT NULL,
  p_fecha          TIMESTAMPTZ DEFAULT NULL,
  p_nota           TEXT DEFAULT NULL,
  p_cuenta_id      BIGINT DEFAULT NULL
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT fn_es_staff_ventas() THEN
    RAISE EXCEPTION 'sin_permiso' USING HINT = 'Tu rol no puede confirmar pagos.';
  END IF;
  IF p_monto IS NOT NULL AND p_monto <= 0 THEN
    RAISE EXCEPTION 'monto_invalido' USING HINT = 'El monto tiene que ser mayor a cero.';
  END IF;
  RETURN fn_cobros_confirmar(p_solicitud_id, p_comprobante_id, p_monto, p_nro_operacion, p_fecha,
                             nullif(left(btrim(coalesce(p_nota, '')), 300), ''), p_cuenta_id);
END;
$$;
REVOKE ALL ON FUNCTION confirmar_pago(BIGINT, BIGINT, NUMERIC, TEXT, TIMESTAMPTZ, TEXT, BIGINT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION confirmar_pago(BIGINT, BIGINT, NUMERIC, TEXT, TIMESTAMPTZ, TEXT, BIGINT) TO authenticated;

CREATE OR REPLACE FUNCTION rechazar_comprobante(p_comprobante_id BIGINT, p_motivo TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_c   comprobantes%ROWTYPE;
  v_sol solicitudes%ROWTYPE;
  v_motivo TEXT := nullif(left(btrim(coalesce(p_motivo, '')), 300), '');
BEGIN
  IF NOT fn_es_staff_ventas() THEN
    RAISE EXCEPTION 'sin_permiso' USING HINT = 'Tu rol no puede rechazar comprobantes.';
  END IF;
  IF v_motivo IS NULL THEN
    RAISE EXCEPTION 'motivo_requerido' USING HINT = 'Escribí por qué se rechaza: el cliente lo va a ver.';
  END IF;
  SELECT * INTO v_c FROM comprobantes WHERE id = p_comprobante_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'comprobante_no_encontrado'; END IF;
  IF v_c.estado = 'aceptado' THEN
    RAISE EXCEPTION 'comprobante_aceptado' USING HINT = 'Este comprobante ya respalda un pago confirmado. Anulá el pago primero.';
  END IF;
  SELECT * INTO v_sol FROM solicitudes WHERE id = v_c.solicitud_id FOR UPDATE;

  UPDATE comprobantes SET estado = 'rechazado', motivo = v_motivo, revisado_por = auth.uid(), revisado_en = now()
   WHERE id = v_c.id;

  -- Si no queda ningún otro comprobante en juego, el pedido vuelve a esperar el pago
  IF v_sol.estado_pago IN ('comprobante_recibido','en_revision')
     AND NOT EXISTS (SELECT 1 FROM comprobantes WHERE solicitud_id = v_sol.id AND estado NOT IN ('rechazado')) THEN
    UPDATE solicitudes SET estado_pago = 'pendiente' WHERE id = v_sol.id;
  END IF;

  INSERT INTO solicitud_eventos (solicitud_id, estado_anterior, estado_nuevo, detalle, usuario_id)
  VALUES (v_sol.id, v_sol.estado, v_sol.estado, 'Comprobante rechazado: ' || v_motivo, auth.uid());

  RETURN jsonb_build_object('ok', true);
END;
$$;
REVOKE ALL ON FUNCTION rechazar_comprobante(BIGINT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION rechazar_comprobante(BIGINT, TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION anular_pago(p_solicitud_id BIGINT, p_motivo TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_sol solicitudes%ROWTYPE;
  v_motivo TEXT := nullif(left(btrim(coalesce(p_motivo, '')), 300), '');
BEGIN
  IF coalesce(fn_get_user_role(), '') <> 'administrador' THEN
    RAISE EXCEPTION 'sin_permiso' USING HINT = 'Solo un administrador puede anular un pago.';
  END IF;
  IF v_motivo IS NULL THEN
    RAISE EXCEPTION 'motivo_requerido' USING HINT = 'Escribí el motivo de la anulación.';
  END IF;
  SELECT * INTO v_sol FROM solicitudes WHERE id = p_solicitud_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'pedido_no_encontrado'; END IF;
  IF v_sol.estado_pago <> 'pagado' THEN
    RAISE EXCEPTION 'pedido_no_pagado' USING HINT = 'Este pedido no tiene un pago confirmado.';
  END IF;

  INSERT INTO movimientos_cobro (cuenta_cobro_id, solicitud_id, tipo, monto, fecha, detalle, usuario_id)
  VALUES (v_sol.cuenta_cobro_id, v_sol.id, 'anulacion', v_sol.monto_pagado, now(), v_motivo, auth.uid());

  UPDATE solicitudes SET estado_pago = 'pendiente', monto_pagado = 0, pagado_en = NULL WHERE id = v_sol.id;
  UPDATE comprobantes SET estado = 'no_coincide', motivo = 'Pago anulado: ' || v_motivo
   WHERE solicitud_id = v_sol.id AND estado = 'aceptado';

  INSERT INTO solicitud_eventos (solicitud_id, estado_anterior, estado_nuevo, detalle, usuario_id)
  VALUES (v_sol.id, v_sol.estado, v_sol.estado, 'Pago anulado: ' || v_motivo, auth.uid());

  RETURN jsonb_build_object('ok', true, 'estado_pago', 'pendiente');
END;
$$;
REVOKE ALL ON FUNCTION anular_pago(BIGINT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION anular_pago(BIGINT, TEXT) TO authenticated;

-- Cierre mensual: congela el total cobrado por cuenta y la comisión del período.
CREATE OR REPLACE FUNCTION cerrar_liquidacion(p_periodo TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_desde TIMESTAMP;
  v_hasta TIMESTAMP;
  v_pct   NUMERIC;
  v_total NUMERIC;
  v_det   JSONB;
  v_id    BIGINT;
BEGIN
  IF coalesce(fn_get_user_role(), '') <> 'administrador' THEN
    RAISE EXCEPTION 'sin_permiso' USING HINT = 'Solo un administrador puede cerrar liquidaciones.';
  END IF;
  IF p_periodo !~ '^\d{4}-\d{2}$' THEN RAISE EXCEPTION 'periodo_invalido'; END IF;
  IF EXISTS (SELECT 1 FROM liquidaciones WHERE periodo = p_periodo) THEN
    RAISE EXCEPTION 'liquidacion_ya_cerrada' USING HINT = 'Ese período ya está cerrado.';
  END IF;
  v_desde := to_timestamp(p_periodo || '-01', 'YYYY-MM-DD')::timestamp;
  v_hasta := v_desde + interval '1 month';
  IF v_hasta > fn_mh_local(now()) THEN
    RAISE EXCEPTION 'periodo_abierto' USING HINT = 'El mes todavía no terminó.';
  END IF;
  SELECT coalesce(comision_pct, 0) INTO v_pct FROM site_settings WHERE id = 1;

  WITH m AS (
    SELECT mc.cuenta_cobro_id, c.nombre, c.titular,
           sum(CASE WHEN mc.tipo = 'cobro' THEN mc.monto ELSE -mc.monto END) AS total,
           count(*) FILTER (WHERE mc.tipo = 'cobro') AS cobros,
           count(*) FILTER (WHERE mc.tipo = 'anulacion') AS anulaciones
      FROM movimientos_cobro mc JOIN cuentas_cobro c ON c.id = mc.cuenta_cobro_id
     WHERE fn_mh_local(mc.fecha) >= v_desde AND fn_mh_local(mc.fecha) < v_hasta
     GROUP BY mc.cuenta_cobro_id, c.nombre, c.titular
  )
  SELECT coalesce(sum(total), 0),
         coalesce(jsonb_agg(jsonb_build_object('cuenta_id', cuenta_cobro_id, 'nombre', nombre, 'titular', titular,
                  'total', total, 'cobros', cobros, 'anulaciones', anulaciones) ORDER BY nombre), '[]'::jsonb)
    INTO v_total, v_det FROM m;

  INSERT INTO liquidaciones (periodo, porcentaje, total_cobrado, comision, detalle, cerrada_por)
  VALUES (p_periodo, v_pct, v_total, round(v_total * v_pct / 100, 2),
          jsonb_build_object('cuentas', v_det,
            'pedidos', (SELECT coalesce(jsonb_agg(jsonb_build_object('codigo', s.codigo, 'monto', mc.monto, 'tipo', mc.tipo,
                               'fecha', mc.fecha, 'cuenta_id', mc.cuenta_cobro_id) ORDER BY mc.fecha), '[]'::jsonb)
                          FROM movimientos_cobro mc LEFT JOIN solicitudes s ON s.id = mc.solicitud_id
                         WHERE fn_mh_local(mc.fecha) >= v_desde AND fn_mh_local(mc.fecha) < v_hasta)),
          auth.uid())
  RETURNING id INTO v_id;

  RETURN jsonb_build_object('ok', true, 'id', v_id, 'periodo', p_periodo, 'total_cobrado', v_total,
                            'porcentaje', v_pct, 'comision', round(v_total * v_pct / 100, 2));
END;
$$;
REVOKE ALL ON FUNCTION cerrar_liquidacion(TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION cerrar_liquidacion(TEXT) TO authenticated;


-- ──────────────────────────────────────────────
-- 14) VISTA PARA EL PANEL: resumen por cuenta
--     security_invoker: respeta el RLS (cuentas: staff; movimientos: admin)
-- ──────────────────────────────────────────────
CREATE OR REPLACE VIEW v_cuentas_cobro_resumen WITH (security_invoker = true) AS
SELECT c.*,
       coalesce((SELECT sum(CASE WHEN m.tipo = 'cobro' THEN m.monto ELSE -m.monto END) FROM movimientos_cobro m
                  WHERE m.cuenta_cobro_id = c.id AND fn_mh_local(m.fecha) >= date_trunc('day', fn_mh_local(now()))), 0)   AS cobrado_hoy,
       coalesce((SELECT sum(CASE WHEN m.tipo = 'cobro' THEN m.monto ELSE -m.monto END) FROM movimientos_cobro m
                  WHERE m.cuenta_cobro_id = c.id AND fn_mh_local(m.fecha) >= date_trunc('month', fn_mh_local(now()))), 0) AS cobrado_mes,
       coalesce((SELECT sum(CASE WHEN m.tipo = 'cobro' THEN m.monto ELSE -m.monto END) FROM movimientos_cobro m
                  WHERE m.cuenta_cobro_id = c.id), 0)                                                                        AS cobrado_total,
       (SELECT count(*) FROM movimientos_cobro m WHERE m.cuenta_cobro_id = c.id AND m.tipo = 'cobro'
          AND fn_mh_local(m.fecha) >= date_trunc('month', fn_mh_local(now())))                                               AS cobros_mes,
       coalesce((SELECT sum(s.monto_a_pagar) FROM solicitudes s
                  WHERE s.cuenta_cobro_id = c.id AND s.estado_pago IN ('pendiente','comprobante_recibido','en_revision')), 0) AS pendiente,
       (SELECT count(*) FROM solicitudes s
          WHERE s.cuenta_cobro_id = c.id AND s.estado_pago IN ('pendiente','comprobante_recibido','en_revision'))          AS pedidos_pendientes,
       (SELECT max(m.fecha) FROM movimientos_cobro m WHERE m.cuenta_cobro_id = c.id AND m.tipo = 'cobro')                     AS ultimo_cobro
  FROM cuentas_cobro c;

GRANT SELECT ON v_cuentas_cobro_resumen TO authenticated;


-- ──────────────────────────────────────────────
-- 15) STORAGE: bucket privado 'comprobantes'
--     - el público sube a la carpeta de su código (MH-.../archivo)
--     - solo el staff lee (el panel pide URLs firmadas)
--     - solo administrador borra
--     Solo corre en Supabase (en pruebas locales no existe storage).
-- ──────────────────────────────────────────────
DO $$
BEGIN
  IF to_regclass('storage.buckets') IS NULL THEN RETURN; END IF;

  INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
  VALUES ('comprobantes', 'comprobantes', false, 10485760,
          ARRAY['image/jpeg','image/png','image/webp','image/heic','application/pdf'])
  ON CONFLICT (id) DO UPDATE SET public = false, file_size_limit = EXCLUDED.file_size_limit,
                                 allowed_mime_types = EXCLUDED.allowed_mime_types;

  EXECUTE 'DROP POLICY IF EXISTS "comprobantes_subida_publica" ON storage.objects';
  EXECUTE $p$CREATE POLICY "comprobantes_subida_publica" ON storage.objects FOR INSERT
    WITH CHECK (bucket_id = 'comprobantes' AND name ~ '^MH-[0-9]{6}-[A-Z0-9]{4}/[^/]{1,120}$')$p$;

  EXECUTE 'DROP POLICY IF EXISTS "comprobantes_lectura_staff" ON storage.objects';
  EXECUTE $p$CREATE POLICY "comprobantes_lectura_staff" ON storage.objects FOR SELECT
    USING (bucket_id = 'comprobantes' AND auth.uid() IS NOT NULL)$p$;

  EXECUTE 'DROP POLICY IF EXISTS "comprobantes_borrar_admin" ON storage.objects';
  EXECUTE $p$CREATE POLICY "comprobantes_borrar_admin" ON storage.objects FOR DELETE
    USING (bucket_id = 'comprobantes' AND fn_get_user_role() = 'administrador')$p$;
END $$;

NOTIFY pgrst, 'reload schema';

-- ============================================================
-- VERIFICACIÓN RÁPIDA (opcional):
--   1. node scripts/test-cobros-sql.mjs  (pruebas locales con PGlite)
--   2. Panel → Cuentas de cobro: crear una cuenta con alias.
--   3. Panel → Configuración → activar "Cobros por transferencia".
--   4. Tienda: carrito → pedido → "Pagar por transferencia" → muestra alias
--      y monto con centavos → subir una imagen → aparece en Pedidos → Para revisar.
--   5. Confirmar el pago → el pedido pasa a "confirmado" y descuenta stock;
--      el movimiento aparece en Cuentas de cobro.
-- ============================================================
