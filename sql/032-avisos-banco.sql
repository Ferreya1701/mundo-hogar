-- ============================================================
-- 032 — Verificación de pagos con el aviso del banco (2026-11-16)
-- ------------------------------------------------------------
-- Un comprobante es una captura: se puede editar. La prueba de que la plata
-- entró es el mail que manda el banco / Mercado Pago a quien RECIBE
-- ("Recibiste una transferencia de $X"). Cada titular reenvía esos avisos
-- (filtro de Gmail) a la dirección secreta de su cuenta:
--     c-<token>@avisos.mundohogarstf.com
-- Cloudflare (worker/index.js) recibe el mail, la Edge Function
-- "avisos-banco" saca monto / ordenante / nº de operación, y esta base
-- empareja el aviso con el pedido por CUENTA + MONTO (los centavos son
-- únicos entre los pedidos pendientes de cada cuenta, sql/012).
--
--   comprobante "coincide" + aviso del banco del mismo importe
--     → el pago se confirma solo (sin nadie).
--   comprobante sin aviso pasados N minutos (7 por defecto)
--     → alerta en el panel y por mail para revisar a mano; si el aviso
--       llega después, igual se confirma solo y la alerta se cierra.
--   diferencia de hasta $50 (configurable) → se acepta y queda anotada.
--
-- Requiere 001..031. Idempotente: se puede correr más de una vez.
-- ============================================================


-- ──────────────────────────────────────────────
-- 1) Configuración (privada: site_settings es pública)
-- ──────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS cobros_avisos_config (
  id                INT PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  auto_con_aviso    BOOLEAN NOT NULL DEFAULT true,     -- comprobante + aviso → confirma solo
  tolerancia        NUMERIC(12,2) NOT NULL DEFAULT 50 CHECK (tolerancia BETWEEN 0 AND 5000),
  minutos_espera    INT NOT NULL DEFAULT 7 CHECK (minutos_espera BETWEEN 1 AND 240),
  mail_alertas      TEXT,                              -- a quién le llega el mail de alerta
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);
INSERT INTO cobros_avisos_config (id) VALUES (1) ON CONFLICT (id) DO NOTHING;
ALTER TABLE cobros_avisos_config ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "avisos_config_ver" ON cobros_avisos_config;
CREATE POLICY "avisos_config_ver" ON cobros_avisos_config FOR SELECT USING (fn_es_staff_ventas());
DROP POLICY IF EXISTS "avisos_config_admin" ON cobros_avisos_config;
CREATE POLICY "avisos_config_admin" ON cobros_avisos_config FOR UPDATE
  USING (fn_get_user_role() = 'administrador') WITH CHECK (fn_get_user_role() = 'administrador');
GRANT SELECT, UPDATE ON cobros_avisos_config TO authenticated;

CREATE OR REPLACE FUNCTION fn_cobros_tolerancia()
RETURNS NUMERIC LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT coalesce((SELECT tolerancia FROM cobros_avisos_config WHERE id = 1), 50)
$$;
GRANT EXECUTE ON FUNCTION fn_cobros_tolerancia() TO authenticated;


-- ──────────────────────────────────────────────
-- 2) Dirección de avisos de cada cuenta (solo administrador)
-- ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_avisos_token_nuevo()
RETURNS TEXT LANGUAGE sql VOLATILE AS $$
  SELECT left(md5(random()::text || clock_timestamp()::text || random()::text), 12)
$$;

CREATE TABLE IF NOT EXISTS cuentas_cobro_avisos (
  cuenta_cobro_id   BIGINT PRIMARY KEY REFERENCES cuentas_cobro(id) ON DELETE CASCADE,
  token             TEXT NOT NULL UNIQUE DEFAULT fn_avisos_token_nuevo(),
  gmail_codigo      TEXT,          -- código que manda Gmail para confirmar el reenvío
  gmail_link        TEXT,
  gmail_en          TIMESTAMPTZ,
  primer_aviso_en   TIMESTAMPTZ,   -- desde acá la cuenta "tiene verificación"
  ultimo_aviso_en   TIMESTAMPTZ,
  ultimo_mail_en    TIMESTAMPTZ,   -- cualquier mail (aunque no sea un ingreso)
  alerta_caida_en   TIMESTAMPTZ,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE cuentas_cobro_avisos ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "cca_admin" ON cuentas_cobro_avisos;
CREATE POLICY "cca_admin" ON cuentas_cobro_avisos FOR SELECT USING (fn_get_user_role() = 'administrador');
GRANT SELECT ON cuentas_cobro_avisos TO authenticated;

INSERT INTO cuentas_cobro_avisos (cuenta_cobro_id)
SELECT id FROM cuentas_cobro ON CONFLICT DO NOTHING;

CREATE OR REPLACE FUNCTION fn_tr_cuenta_cobro_avisos()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  INSERT INTO cuentas_cobro_avisos (cuenta_cobro_id) VALUES (NEW.id) ON CONFLICT DO NOTHING;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION fn_tr_cuenta_cobro_avisos() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS tr_cuenta_cobro_avisos ON cuentas_cobro;
CREATE TRIGGER tr_cuenta_cobro_avisos AFTER INSERT ON cuentas_cobro
  FOR EACH ROW EXECUTE FUNCTION fn_tr_cuenta_cobro_avisos();


-- ──────────────────────────────────────────────
-- 3) Avisos recibidos (libro: no se borran, solo cambian de estado)
-- ──────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS avisos_ingreso (
  id               BIGSERIAL PRIMARY KEY,
  cuenta_cobro_id  BIGINT REFERENCES cuentas_cobro(id) ON DELETE SET NULL,
  message_id       TEXT UNIQUE,
  remitente        TEXT,
  asunto           TEXT,
  recibido_en      TIMESTAMPTZ NOT NULL DEFAULT now(),
  tipo             TEXT NOT NULL DEFAULT 'ingreso' CHECK (tipo IN ('ingreso','otro','confirmacion_gmail')),
  monto            NUMERIC(12,2),
  fecha_operacion  TIMESTAMPTZ,
  ordenante        TEXT,
  ordenante_cuit   TEXT,
  nro_operacion    TEXT,
  confianza        INT,
  remitente_banco  BOOLEAN NOT NULL DEFAULT true,   -- el mail viene de un banco / billetera conocido
  lectura          JSONB,
  texto            TEXT,
  estado           TEXT NOT NULL DEFAULT 'sin_asignar'
                     CHECK (estado IN ('sin_asignar','asignado','usado','venta_local','descartado','no_es_ingreso')),
  solicitud_id     BIGINT REFERENCES solicitudes(id) ON DELETE SET NULL,
  comprobante_id   BIGINT REFERENCES comprobantes(id) ON DELETE SET NULL,
  movimiento_id    BIGINT REFERENCES movimientos_cobro(id) ON DELETE SET NULL,
  nota             TEXT,
  revisado_por     UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  revisado_en      TIMESTAMPTZ
);
ALTER TABLE avisos_ingreso ADD COLUMN IF NOT EXISTS remitente_banco BOOLEAN NOT NULL DEFAULT true;
CREATE INDEX IF NOT EXISTS idx_avisos_cuenta_estado ON avisos_ingreso(cuenta_cobro_id, estado);
CREATE INDEX IF NOT EXISTS idx_avisos_solicitud ON avisos_ingreso(solicitud_id) WHERE solicitud_id IS NOT NULL;
ALTER TABLE avisos_ingreso ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "avisos_ver" ON avisos_ingreso;
CREATE POLICY "avisos_ver" ON avisos_ingreso FOR SELECT USING (fn_es_staff_ventas());
GRANT SELECT ON avisos_ingreso TO authenticated;

ALTER TABLE comprobantes ADD COLUMN IF NOT EXISTS aviso_id BIGINT REFERENCES avisos_ingreso(id) ON DELETE SET NULL;
ALTER TABLE comprobantes ADD COLUMN IF NOT EXISTS archivo_sha256 TEXT;
-- Notas para el panel (el cliente ve 'motivo', nunca esto)
ALTER TABLE comprobantes ADD COLUMN IF NOT EXISTS nota_interna TEXT;
CREATE INDEX IF NOT EXISTS idx_comprobantes_sha ON comprobantes(archivo_sha256) WHERE archivo_sha256 IS NOT NULL;


-- ──────────────────────────────────────────────
-- 4) Alertas de cobros (panel + mail)
-- ──────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS cobros_alertas (
  id               BIGSERIAL PRIMARY KEY,
  clave            TEXT NOT NULL UNIQUE,              -- evita repetir la misma alerta
  tipo             TEXT NOT NULL CHECK (tipo IN ('sin_aviso','comprobante_no_valido','sin_lectura',
                                                 'aviso_sin_pedido','reenvio_caido','no_se_pudo_confirmar')),
  solicitud_id     BIGINT REFERENCES solicitudes(id) ON DELETE CASCADE,
  comprobante_id   BIGINT REFERENCES comprobantes(id) ON DELETE SET NULL,
  aviso_id         BIGINT REFERENCES avisos_ingreso(id) ON DELETE SET NULL,
  cuenta_cobro_id  BIGINT REFERENCES cuentas_cobro(id) ON DELETE SET NULL,
  titulo           TEXT NOT NULL,
  detalle          TEXT,
  creada_en        TIMESTAMPTZ NOT NULL DEFAULT now(),
  mail_estado      TEXT NOT NULL DEFAULT 'pendiente' CHECK (mail_estado IN ('pendiente','enviado','no_corresponde','fallo')),
  mail_intentos    INT NOT NULL DEFAULT 0,
  mail_en          TIMESTAMPTZ,
  vista_por        UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  vista_en         TIMESTAMPTZ,
  resuelta_en      TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS idx_cobros_alertas_abiertas ON cobros_alertas(creada_en) WHERE resuelta_en IS NULL;
ALTER TABLE cobros_alertas ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "alertas_cobros_ver" ON cobros_alertas;
CREATE POLICY "alertas_cobros_ver" ON cobros_alertas FOR SELECT USING (fn_es_staff_ventas());
GRANT SELECT ON cobros_alertas TO authenticated;

CREATE OR REPLACE FUNCTION fn_cobros_alerta(p_clave TEXT, p_tipo TEXT, p_sol BIGINT, p_comp BIGINT,
                                            p_aviso BIGINT, p_cuenta BIGINT, p_titulo TEXT, p_detalle TEXT,
                                            p_mail BOOLEAN DEFAULT true)
RETURNS BIGINT LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_id BIGINT;
BEGIN
  INSERT INTO cobros_alertas (clave, tipo, solicitud_id, comprobante_id, aviso_id, cuenta_cobro_id, titulo, detalle, mail_estado)
  VALUES (p_clave, p_tipo, p_sol, p_comp, p_aviso, p_cuenta, p_titulo, p_detalle,
          CASE WHEN p_mail THEN 'pendiente' ELSE 'no_corresponde' END)
  ON CONFLICT (clave) DO NOTHING
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;
REVOKE ALL ON FUNCTION fn_cobros_alerta(TEXT, TEXT, BIGINT, BIGINT, BIGINT, BIGINT, TEXT, TEXT, BOOLEAN) FROM PUBLIC, anon, authenticated;


-- ──────────────────────────────────────────────
-- 5) La tolerancia también vale al pasar el pedido al mostrador (sql/028,
--    idénticas salvo el margen: antes $1 fijo, ahora la tolerancia de cobros)
-- ──────────────────────────────────────────────
-- 4) Marcar / desmarcar una venta como pagada online
-- ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_venta_pago_web(p_venta_id BIGINT, p_pagada BOOLEAN)
RETURNS BOOLEAN LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v   ventas%ROWTYPE;
  s   solicitudes%ROWTYPE;
BEGIN
  SELECT * INTO v FROM ventas WHERE id = p_venta_id FOR UPDATE;
  IF NOT FOUND OR v.estado = 'anulada' THEN RETURN false; END IF;

  IF p_pagada THEN
    IF v.estado <> 'pendiente_cobro' THEN RETURN false; END IF;
    SELECT * INTO s FROM solicitudes WHERE id = v.solicitud_id;
    IF NOT FOUND OR s.estado_pago <> 'pagado' OR coalesce(s.monto_pagado, 0) < v.total - greatest(1, fn_cobros_tolerancia()) THEN RETURN false; END IF;
    DELETE FROM venta_pagos WHERE venta_id = v.id;
    INSERT INTO venta_pagos (venta_id, medio_pago, monto, monto_original, cuenta_cobro_id, orden)
    VALUES (v.id, 'web', v.total, greatest(v.total, 0.01), s.cuenta_cobro_id, 1);
    UPDATE ventas SET estado = 'cerrada', medio_pago = 'web', cuenta_cobro_id = NULL,
                      cobrada_en = coalesce(s.pagado_en, now()), cobrada_por = NULL,
                      cobrada_por_nombre = 'Pago online'
     WHERE id = v.id;
    RETURN true;
  ELSE
    IF v.estado <> 'cerrada' OR v.medio_pago <> 'web' THEN RETURN false; END IF;
    IF v.entrega_estado = 'entregado' THEN
      RAISE EXCEPTION 'venta_entregada'
        USING HINT = format('La mercadería de la venta %s ya salió. Anulá la venta o cobrá la diferencia antes de anular el pago.', v.codigo);
    END IF;
    DELETE FROM venta_pagos WHERE venta_id = v.id;
    UPDATE ventas SET estado = 'pendiente_cobro', medio_pago = 'pendiente', cobrada_en = NULL,
                      cobrada_por = NULL, cobrada_por_nombre = NULL
     WHERE id = v.id;
    RETURN true;
  END IF;
END;
$$;
REVOKE ALL ON FUNCTION fn_venta_pago_web(BIGINT, BOOLEAN) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION pedido_a_venta(p_solicitud_id BIGINT, p_o JSONB DEFAULT '{}'::jsonb)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  s        solicitudes%ROWTYPE;
  r        RECORD;
  v_items  JSONB := '[]'::jsonb;
  v_falta  TEXT[] := '{}';
  v_precio NUMERIC;
  v_ent    JSONB;
  v_res    JSONB;
  v_id     BIGINT;
  v_total  NUMERIC;
  v_pagada BOOLEAN := false;
  v_prev   TEXT := current_setting('mh.interno', true);
BEGIN
  IF NOT fn_tiene_permiso('pedidos.gestionar') THEN
    RAISE EXCEPTION 'sin_permiso' USING HINT = 'Tu usuario no puede gestionar pedidos web.';
  END IF;
  IF NOT fn_tiene_permiso('ventas.crear') THEN
    RAISE EXCEPTION 'sin_permiso' USING HINT = 'Tu usuario no puede registrar ventas.';
  END IF;
  SELECT * INTO s FROM solicitudes WHERE id = p_solicitud_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'pedido_no_encontrado'; END IF;
  IF s.venta_id IS NOT NULL THEN
    RAISE EXCEPTION 'pedido_ya_en_venta'
      USING HINT = format('Este pedido ya es la venta %s.', (SELECT codigo FROM ventas WHERE id = s.venta_id));
  END IF;
  IF s.estado IN ('cancelado', 'entregado') THEN
    RAISE EXCEPTION 'pedido_cerrado' USING HINT = 'El pedido está cancelado o ya se entregó.';
  END IF;

  -- Ítems con su precio (el del pedido, o el corregido en el panel)
  FOR r IN SELECT i.* FROM solicitud_items i WHERE i.solicitud_id = s.id ORDER BY i.id LOOP
    v_precio := NULL;
    BEGIN
      SELECT nullif(x->>'precio', '')::numeric INTO v_precio
        FROM jsonb_array_elements(coalesce(p_o->'items', '[]'::jsonb)) x
       WHERE (x->>'id')::bigint = r.id LIMIT 1;
    EXCEPTION WHEN OTHERS THEN v_precio := NULL;
    END;
    v_precio := coalesce(v_precio, r.precio_unitario);
    IF v_precio IS NULL OR v_precio < 0 THEN v_falta := v_falta || r.nombre; CONTINUE; END IF;
    v_items := v_items || jsonb_build_object('producto_id', r.producto_id, 'nombre', r.nombre,
                                             'cantidad', r.cantidad, 'precio_unitario', v_precio);
  END LOOP;
  IF array_length(v_falta, 1) > 0 THEN
    RAISE EXCEPTION 'precio_requerido'
      USING HINT = 'Falta el precio de: ' || array_to_string(v_falta, ', ') || '.';
  END IF;
  IF jsonb_array_length(v_items) = 0 THEN RAISE EXCEPTION 'venta_vacia' USING HINT = 'El pedido no tiene productos.'; END IF;

  -- Si el pedido ya había descontado stock (al confirmarse), se repone: lo descuenta la venta
  IF s.stock_descontado THEN
    PERFORM set_config('mh.interno', '1', true);
    FOR r IN SELECT i.producto_id, i.cantidad FROM solicitud_items i JOIN productos p ON p.id = i.producto_id
              WHERE i.solicitud_id = s.id AND p.seguimiento_inventario LOOP
      PERFORM fn_registrar_movimiento(r.producto_id, 'devolucion_cliente', r.cantidad,
                                      'Pedido web pasa a venta', NULL, s.codigo, false);
    END LOOP;
    UPDATE solicitudes SET stock_descontado = false WHERE id = s.id;
    PERFORM set_config('mh.interno', coalesce(v_prev, ''), true);
  END IF;

  -- Entrega: la del panel, o la del pedido
  v_ent := coalesce(p_o->'entrega', CASE WHEN s.tipo_entrega = 'envio'
    THEN jsonb_build_object('tipo', 'envio', 'direccion', s.direccion, 'localidad', s.localidad,
                            'destinatario', s.cliente_nombre, 'telefono', s.telefono)
    ELSE jsonb_build_object('tipo', 'retiro') END);

  v_res := venta_registrar(jsonb_build_object(
    'items', v_items, 'cliente_nombre', s.cliente_nombre, 'cliente_telefono', s.telefono,
    'notas', left(concat_ws(' · ', 'Pedido web ' || s.codigo, nullif(btrim(coalesce(p_o->>'notas', '')), ''),
                            nullif(btrim(coalesce(s.observaciones, '')), '')), 400),
    'entrega', v_ent));
  v_id := (v_res->>'id')::bigint;

  UPDATE ventas SET origen = 'web', solicitud_id = s.id WHERE id = v_id RETURNING total INTO v_total;

  PERFORM set_config('mh.interno', '1', true);
  UPDATE solicitudes SET venta_id = v_id,
         estado = CASE WHEN estado IN ('nueva','contactado','cotizacion_enviada') THEN 'confirmado' ELSE estado END,
         atendido_por = coalesce(atendido_por, auth.uid())
   WHERE id = s.id;
  PERFORM set_config('mh.interno', coalesce(v_prev, ''), true);

  IF s.estado_pago = 'pagado' THEN
    IF coalesce(s.monto_pagado, 0) < v_total - greatest(1, fn_cobros_tolerancia()) THEN
      RAISE EXCEPTION 'pago_web_incompleto'
        USING HINT = format('El cliente pagó %s online y la venta suma %s. Corregí los precios o anulá el pago en Pedidos.',
                            to_char(s.monto_pagado, 'FM999G999G999'), to_char(v_total, 'FM999G999G999'));
    END IF;
    v_pagada := fn_venta_pago_web(v_id, true);
  END IF;

  INSERT INTO solicitud_eventos (solicitud_id, estado_anterior, estado_nuevo, detalle, usuario_id)
  VALUES (s.id, s.estado, (SELECT estado FROM solicitudes WHERE id = s.id),
          format('Pasó al mostrador: venta %s%s', v_res->>'codigo', CASE WHEN v_pagada THEN ' (ya pagada online)' ELSE ' (se cobra en la caja)' END),
          auth.uid());

  RETURN v_res || jsonb_build_object('estado', CASE WHEN v_pagada THEN 'cerrada' ELSE 'pendiente_cobro' END,
                                     'medio_pago', CASE WHEN v_pagada THEN 'web' ELSE v_res->>'medio_pago' END,
                                     'pagada_online', v_pagada, 'solicitud_codigo', s.codigo);
END;
$$;
REVOKE ALL ON FUNCTION pedido_a_venta(BIGINT, JSONB) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION pedido_a_venta(BIGINT, JSONB) TO authenticated;


-- ──────────────────────────────────────────────
-- 6) Conciliar: comprobante válido + aviso del banco → pago confirmado
-- ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_cobros_conciliar(p_solicitud_id BIGINT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_cfg  cobros_avisos_config%ROWTYPE;
  v_sol  solicitudes%ROWTYPE;
  v_c    comprobantes%ROWTYPE;
  v_a    avisos_ingreso%ROWTYPE;
  v_r    JSONB;
  v_dif  NUMERIC;
BEGIN
  SELECT * INTO v_cfg FROM cobros_avisos_config WHERE id = 1;
  SELECT * INTO v_sol FROM solicitudes WHERE id = p_solicitud_id FOR UPDATE;
  IF NOT FOUND OR v_sol.estado = 'cancelado'
     OR v_sol.estado_pago NOT IN ('pendiente','comprobante_recibido','en_revision','vencido') THEN
    RETURN NULL;
  END IF;

  SELECT * INTO v_c FROM comprobantes
   WHERE solicitud_id = v_sol.id AND estado = 'coincide' ORDER BY id DESC LIMIT 1;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'esperando_comprobante', true); END IF;

  -- ¿Ya hay un aviso emparejado con este pedido?
  SELECT * INTO v_a FROM avisos_ingreso
   WHERE solicitud_id = v_sol.id AND estado = 'asignado' ORDER BY id DESC LIMIT 1;
  IF NOT FOUND THEN
    -- Uno suelto de la misma cuenta con el mismo importe que el comprobante
    SELECT * INTO v_a FROM avisos_ingreso a
     WHERE a.estado = 'sin_asignar' AND a.tipo = 'ingreso' AND a.remitente_banco
       AND a.cuenta_cobro_id = v_sol.cuenta_cobro_id
       AND abs(a.monto - v_sol.monto_a_pagar) <= coalesce(v_cfg.tolerancia, 50)
       AND (abs(a.monto - v_c.monto_leido) <= 0.005
            OR (a.nro_operacion IS NOT NULL AND a.nro_operacion = v_c.nro_operacion))
       AND a.recibido_en >= coalesce(v_sol.pago_habilitado_en, v_sol.created_at) - interval '10 minutes'
     ORDER BY (a.nro_operacion IS NOT NULL AND a.nro_operacion = v_c.nro_operacion) DESC, a.recibido_en
     LIMIT 1
     FOR UPDATE;
    IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'esperando_aviso', true); END IF;
  END IF;

  -- El aviso y el comprobante tienen que hablar de la misma transferencia
  IF abs(v_a.monto - coalesce(v_c.monto_leido, -1)) > 0.005
     AND (v_a.nro_operacion IS NULL OR v_a.nro_operacion IS DISTINCT FROM v_c.nro_operacion) THEN
    UPDATE avisos_ingreso SET solicitud_id = v_sol.id, estado = 'asignado' WHERE id = v_a.id;
    RETURN jsonb_build_object('ok', false, 'aviso_distinto', true, 'aviso_id', v_a.id);
  END IF;

  UPDATE avisos_ingreso SET solicitud_id = v_sol.id, comprobante_id = v_c.id, estado = 'asignado' WHERE id = v_a.id;
  UPDATE comprobantes SET aviso_id = v_a.id WHERE id = v_c.id;

  IF NOT coalesce(v_cfg.auto_con_aviso, true) THEN
    RETURN jsonb_build_object('ok', false, 'manual', true, 'aviso_id', v_a.id);
  END IF;

  v_dif := v_a.monto - v_sol.monto_a_pagar;
  BEGIN
    v_r := fn_cobros_confirmar(v_sol.id, v_c.id, v_a.monto, coalesce(v_a.nro_operacion, v_c.nro_operacion),
             coalesce(v_a.fecha_operacion, v_a.recibido_en),
             'Confirmado solo: comprobante + aviso del banco'
               || CASE WHEN abs(v_dif) > 0.005
                       THEN format(' (pagó %s %s, dentro de la tolerancia)', to_char(abs(v_dif), 'FM999G999G990D00'),
                                   CASE WHEN v_dif < 0 THEN 'menos' ELSE 'más' END)
                       ELSE '' END,
             NULL);
    UPDATE avisos_ingreso SET estado = 'usado', movimiento_id = (v_r->>'movimiento_id')::bigint WHERE id = v_a.id;
    UPDATE cobros_alertas
       SET resuelta_en = now(), mail_estado = CASE WHEN mail_estado = 'pendiente' THEN 'no_corresponde' ELSE mail_estado END
     WHERE solicitud_id = v_sol.id AND resuelta_en IS NULL;
    RETURN v_r || jsonb_build_object('auto', 'aviso', 'aviso_id', v_a.id);
  EXCEPTION WHEN OTHERS THEN
    -- p.ej. stock insuficiente: la plata entró, pero falta una decisión
    UPDATE comprobantes SET nota_interna = 'Pago verificado con el aviso del banco, pero no se pudo confirmar solo: ' || SQLERRM
     WHERE id = v_c.id;
    PERFORM fn_cobros_alerta('no_confirma:' || v_c.id, 'no_se_pudo_confirmar', v_sol.id, v_c.id, v_a.id, v_sol.cuenta_cobro_id,
      format('Pedido %s: la plata entró pero no se pudo confirmar solo', v_sol.codigo),
      'El aviso del banco coincide con el comprobante. Motivo: ' || SQLERRM);
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM, 'aviso_id', v_a.id);
  END;
END;
$$;
REVOKE ALL ON FUNCTION fn_cobros_conciliar(BIGINT) FROM PUBLIC, anon, authenticated;


-- Un aviso nuevo busca su pedido: misma cuenta, importe dentro de la tolerancia.
-- Prioridad: el pedido con comprobante del mismo importe; si no, el de los
-- centavos exactos; si no, el único candidato. Más de uno → queda suelto.
CREATE OR REPLACE FUNCTION fn_aviso_emparejar(p_aviso_id BIGINT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_a     avisos_ingreso%ROWTYPE;
  v_tol   NUMERIC := fn_cobros_tolerancia();
  v_sol   BIGINT;
  v_comp  BIGINT[];
  v_exac  BIGINT[];
  v_todos BIGINT[];
  v_mov   BIGINT;
  v_venta TEXT;
BEGIN
  SELECT * INTO v_a FROM avisos_ingreso WHERE id = p_aviso_id FOR UPDATE;
  -- Un remitente que no es un banco conocido nunca se empareja solo (un mail trucho de "Recibiste $X")
  IF NOT FOUND OR v_a.estado <> 'sin_asignar' OR v_a.tipo <> 'ingreso' OR v_a.monto IS NULL OR v_a.cuenta_cobro_id IS NULL
     OR NOT v_a.remitente_banco THEN
    RETURN jsonb_build_object('ok', true, 'asignado', false);
  END IF;

  SELECT array_agg(c.id) FILTER (WHERE c.con_comp),
         array_agg(c.id) FILTER (WHERE c.dif <= 0.005),
         array_agg(c.id)
    INTO v_comp, v_exac, v_todos
    FROM (
      SELECT s.id, abs(s.monto_a_pagar - v_a.monto) AS dif,
             EXISTS (SELECT 1 FROM comprobantes c
                      WHERE c.solicitud_id = s.id AND c.estado = 'coincide'
                        AND (abs(c.monto_leido - v_a.monto) <= 0.005
                             OR (v_a.nro_operacion IS NOT NULL AND c.nro_operacion = v_a.nro_operacion))) AS con_comp
        FROM solicitudes s
       WHERE s.cuenta_cobro_id = v_a.cuenta_cobro_id
         AND s.estado <> 'cancelado'
         AND s.estado_pago IN ('pendiente','comprobante_recibido','en_revision','vencido')
         AND s.monto_a_pagar IS NOT NULL
         AND abs(s.monto_a_pagar - v_a.monto) <= v_tol
         AND coalesce(s.pago_habilitado_en, s.created_at) <= v_a.recibido_en + interval '10 minutes'
         AND NOT EXISTS (SELECT 1 FROM avisos_ingreso x WHERE x.solicitud_id = s.id AND x.estado IN ('asignado','usado'))
    ) c;

  IF cardinality(v_comp) = 1 THEN
    v_sol := v_comp[1];
  ELSIF coalesce(cardinality(v_comp), 0) = 0 THEN
    IF cardinality(v_exac) = 1 THEN
      v_sol := v_exac[1];
    ELSIF coalesce(cardinality(v_exac), 0) = 0 AND cardinality(v_todos) = 1 THEN
      v_sol := v_todos[1];
    END IF;
  END IF;

  IF v_sol IS NOT NULL THEN
    UPDATE avisos_ingreso SET estado = 'asignado', solicitud_id = v_sol WHERE id = v_a.id;
    INSERT INTO solicitud_eventos (solicitud_id, estado_anterior, estado_nuevo, detalle)
    SELECT id, estado, estado, format('Aviso del banco: entraron %s%s', to_char(v_a.monto, 'FM999G999G999D00'),
                                      CASE WHEN v_a.ordenante IS NOT NULL THEN ' de ' || v_a.ordenante ELSE '' END)
      FROM solicitudes WHERE id = v_sol;
    RETURN jsonb_build_object('ok', true, 'asignado', true, 'solicitud_id', v_sol,
                              'conciliacion', fn_cobros_conciliar(v_sol));
  END IF;

  -- ¿Es una transferencia cobrada en la caja del local? (sql/025)
  SELECT m.id, v.codigo INTO v_mov, v_venta
    FROM movimientos_cobro m JOIN ventas v ON v.id = m.venta_id
   WHERE m.cuenta_cobro_id = v_a.cuenta_cobro_id AND m.tipo = 'cobro' AND m.venta_id IS NOT NULL
     AND abs(m.monto - v_a.monto) <= 1
     AND m.fecha BETWEEN v_a.recibido_en - interval '6 hours' AND v_a.recibido_en + interval '6 hours'
     AND NOT EXISTS (SELECT 1 FROM avisos_ingreso x WHERE x.movimiento_id = m.id)
   ORDER BY abs(extract(epoch FROM m.fecha - v_a.recibido_en))
   LIMIT 1;
  IF v_mov IS NOT NULL THEN
    UPDATE avisos_ingreso SET estado = 'venta_local', movimiento_id = v_mov, nota = 'Venta del local ' || v_venta
     WHERE id = v_a.id;
    RETURN jsonb_build_object('ok', true, 'asignado', false, 'venta_local', v_venta);
  END IF;

  RETURN jsonb_build_object('ok', true, 'asignado', false,
                            'ambiguo', coalesce(cardinality(v_todos), 0) > 1);
END;
$$;
REVOKE ALL ON FUNCTION fn_aviso_emparejar(BIGINT) FROM PUBLIC, anon, authenticated;


-- ──────────────────────────────────────────────
-- 7) Lectura del comprobante (sql/012) con tres cambios:
--    • tolerancia: hasta $50 (config) de diferencia sigue "coincidiendo"
--      y queda anotado; más que eso, no coincide.
--    • el mismo archivo (huella sha256) en otro pedido → no coincide.
--    • fecha y hora: no puede ser de antes de habilitar el pago (15 min de margen).
--    Y al final intenta conciliar con el aviso del banco.
-- ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION comprobante_registrar_lectura(p_comprobante_id BIGINT, p_lectura JSONB)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_c       comprobantes%ROWTYPE;
  v_sol     solicitudes%ROWTYPE;
  v_cta     cuentas_cobro%ROWTYPE;
  v_set     site_settings%ROWTYPE;
  v_tol     NUMERIC := fn_cobros_tolerancia();
  v_monto   NUMERIC;
  v_fecha   DATE;
  v_ts      TIMESTAMPTZ;
  v_alias   TEXT := lower(regexp_replace(coalesce(p_lectura->>'destino_alias', ''), '\s', '', 'g'));
  v_cvu     TEXT := regexp_replace(coalesce(p_lectura->>'destino_cvu', ''), '\D', '', 'g');
  v_titular TEXT := lower(btrim(coalesce(p_lectura->>'destino_titular', '')));
  v_nro     TEXT := nullif(left(btrim(coalesce(p_lectura->>'nro_operacion', '')), 60), '');
  v_sha     TEXT := nullif(lower(btrim(coalesce(p_lectura->>'_sha256', ''))), '');
  v_edit    BOOLEAN := coalesce((p_lectura->>'posible_edicion')::boolean, false);
  v_conf    INT  := least(greatest(coalesce((p_lectura->>'confianza')::int, 0), 0), 100);
  v_estado  TEXT := 'coincide';
  v_motivos TEXT[] := ARRAY[]::TEXT[];
  v_notas   TEXT[] := ARRAY[]::TEXT[];
  v_dup     TEXT;
  v_dif     NUMERIC;
  v_auto    JSONB := NULL;
  v_conc    JSONB := NULL;
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
  BEGIN
    IF v_fecha IS NOT NULL AND (p_lectura->>'hora') ~ '^\d{1,2}:\d{2}' THEN
      v_ts := (v_fecha::text || ' ' || substring(p_lectura->>'hora' FROM '^\d{1,2}:\d{2}'))::timestamp
              AT TIME ZONE 'America/Argentina/Buenos_Aires';
    END IF;
  EXCEPTION WHEN OTHERS THEN v_ts := NULL; END;

  IF v_sha IS NOT NULL THEN
    SELECT s.codigo INTO v_dup
      FROM comprobantes c JOIN solicitudes s ON s.id = c.solicitud_id
     WHERE c.archivo_sha256 = v_sha AND c.solicitud_id <> v_sol.id AND c.estado <> 'rechazado' LIMIT 1;
    IF v_dup IS NOT NULL THEN
      v_estado := 'no_coincide';
      v_motivos := array_append(v_motivos, format('Es el mismo archivo que se subió en el pedido %s', v_dup));
    END IF;
    v_dup := NULL;
  END IF;

  IF NOT coalesce((p_lectura->>'legible')::boolean, false) OR v_conf < 40 OR v_monto IS NULL THEN
    v_estado := 'ilegible';
    v_motivos := array_append(v_motivos, coalesce(nullif(left(p_lectura->>'notas', 200), ''), 'No se pudo leer con claridad el comprobante'));
  ELSE
    IF v_sol.monto_a_pagar IS NOT NULL THEN
      v_dif := v_monto - v_sol.monto_a_pagar;
      IF abs(v_dif) > v_tol + 0.005 THEN
        v_estado := 'no_coincide';
        v_motivos := array_append(v_motivos, format('Monto leído %s, esperado %s',
          to_char(v_monto, 'FM999G999G999D00'), to_char(v_sol.monto_a_pagar, 'FM999G999G999D00')));
      ELSIF abs(v_dif) > 0.005 THEN
        v_notas := array_append(v_notas, format('Pagó %s %s (dentro de la tolerancia)',
          to_char(abs(v_dif), 'FM999G999G990D00'), CASE WHEN v_dif < 0 THEN 'menos' ELSE 'más' END));
      END IF;
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
    IF v_ts IS NOT NULL AND v_sol.pago_habilitado_en IS NOT NULL
       AND v_ts < v_sol.pago_habilitado_en - interval '15 minutes' THEN
      v_estado := 'no_coincide';
      v_motivos := array_append(v_motivos, format('Fecha y hora del comprobante (%s) anteriores al pedido',
                                                  to_char(fn_mh_local(v_ts), 'DD/MM/YYYY HH24:MI')));
    ELSIF v_ts IS NULL AND v_fecha IS NOT NULL AND v_sol.pago_habilitado_en IS NOT NULL
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
    IF v_edit THEN
      v_notas := array_append(v_notas, 'La IA ve posibles señales de edición: confirmar solo con el aviso del banco');
    END IF;
  END IF;

  UPDATE comprobantes
     SET estado = v_estado, lectura = p_lectura, monto_leido = v_monto, fecha_leida = v_fecha,
         destino_leido = nullif(coalesce(nullif(p_lectura->>'destino_alias',''), nullif(p_lectura->>'destino_cvu',''), p_lectura->>'destino_titular'), ''),
         nro_operacion = v_nro, confianza = v_conf, archivo_sha256 = coalesce(v_sha, archivo_sha256),
         motivo = nullif(array_to_string(v_motivos, ' · '), ''),
         nota_interna = nullif(array_to_string(v_notas, ' · '), ''), leido_en = now()
   WHERE id = v_c.id;

  IF v_sol.estado_pago IN ('comprobante_recibido','pendiente','vencido') THEN
    UPDATE solicitudes SET estado_pago = 'en_revision' WHERE id = v_sol.id;
  END IF;

  INSERT INTO solicitud_eventos (solicitud_id, estado_anterior, estado_nuevo, detalle)
  VALUES (v_sol.id, v_sol.estado, v_sol.estado,
          CASE v_estado WHEN 'coincide' THEN 'Comprobante leído: coincide con el pedido'
                                             || coalesce(' · ' || nullif(array_to_string(v_notas, ' · '), ''), '')
                        ELSE 'Comprobante leído: ' || coalesce(array_to_string(v_motivos, ' · '), v_estado) END);

  IF v_estado = 'coincide' THEN
    -- 1º: con el aviso del banco (la plata entró de verdad)
    v_conc := fn_cobros_conciliar(v_sol.id);
    -- 2º: solo con el comprobante, si el dueño lo prendió (y la IA no ve edición)
    IF coalesce((v_conc->>'estado_pago') = 'pagado', false) THEN
      v_auto := v_conc;
    ELSIF coalesce(v_set.cobros_auto_confirmar, false) AND v_conf >= 80 AND NOT v_edit AND abs(coalesce(v_dif, 0)) <= 0.005 THEN
      BEGIN
        v_auto := fn_cobros_confirmar(v_sol.id, v_c.id, NULL, v_nro, coalesce(v_ts, v_fecha::timestamptz, now()),
                                      'Confirmación automática por comprobante leído', NULL);
      EXCEPTION WHEN OTHERS THEN
        UPDATE comprobantes SET motivo = 'No se pudo confirmar solo: ' || SQLERRM WHERE id = v_c.id;
        v_auto := jsonb_build_object('ok', false, 'error', SQLERRM);
      END;
    END IF;
  END IF;

  RETURN jsonb_build_object('ok', true, 'estado', v_estado,
                            'motivo', nullif(array_to_string(v_motivos, ' · '), ''),
                            'nota_interna', nullif(array_to_string(v_notas, ' · '), ''),
                            'auto', v_auto, 'conciliacion', v_conc);
END;
$$;
REVOKE ALL ON FUNCTION comprobante_registrar_lectura(BIGINT, JSONB) FROM PUBLIC, anon, authenticated;



-- ──────────────────────────────────────────────
-- 8) Entrada de avisos (solo la Edge Function "avisos-banco", con clave de servicio)
--    p_d: { message_id, remitente, asunto, tipo ('ingreso'|'otro'|'confirmacion_gmail'),
--           monto, fecha, hora, ordenante, ordenante_cuit, nro_operacion, confianza,
--           gmail_codigo, gmail_link, texto, lectura }
-- ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION aviso_registrar(p_token TEXT, p_d JSONB)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_cca   cuentas_cobro_avisos%ROWTYPE;
  v_tipo  TEXT := coalesce(nullif(p_d->>'tipo', ''), 'ingreso');
  v_monto NUMERIC;
  v_fecha TIMESTAMPTZ;
  v_nro   TEXT := nullif(left(btrim(coalesce(p_d->>'nro_operacion', '')), 60), '');
  v_mid   TEXT := nullif(left(btrim(coalesce(p_d->>'message_id', '')), 300), '');
  v_id    BIGINT;
  v_dup   BIGINT;
  v_conf  INT;
  v_banco BOOLEAN := coalesce((p_d->>'remitente_banco')::boolean, true);
BEGIN
  SELECT * INTO v_cca FROM cuentas_cobro_avisos WHERE token = lower(btrim(coalesce(p_token, ''))) FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'direccion_desconocida'); END IF;
  IF v_mid IS NOT NULL AND EXISTS (SELECT 1 FROM avisos_ingreso WHERE message_id = v_mid) THEN
    RETURN jsonb_build_object('ok', true, 'repetido', true);
  END IF;
  IF v_tipo NOT IN ('ingreso','otro','confirmacion_gmail') THEN v_tipo := 'otro'; END IF;

  BEGIN v_monto := round((p_d->>'monto')::numeric, 2); EXCEPTION WHEN OTHERS THEN v_monto := NULL; END;
  BEGIN v_conf := least(greatest((p_d->>'confianza')::int, 0), 100); EXCEPTION WHEN OTHERS THEN v_conf := NULL; END;
  BEGIN
    IF (p_d->>'fecha') ~ '^\d{4}-\d{2}-\d{2}$' THEN
      v_fecha := ((p_d->>'fecha') || ' ' || coalesce(substring(p_d->>'hora' FROM '^\d{1,2}:\d{2}'), '12:00'))::timestamp
                 AT TIME ZONE 'America/Argentina/Buenos_Aires';
    END IF;
  EXCEPTION WHEN OTHERS THEN v_fecha := NULL; END;
  IF v_tipo = 'ingreso' AND (v_monto IS NULL OR v_monto <= 0) THEN v_tipo := 'otro'; END IF;

  UPDATE cuentas_cobro_avisos SET ultimo_mail_en = now() WHERE cuenta_cobro_id = v_cca.cuenta_cobro_id;

  INSERT INTO avisos_ingreso (cuenta_cobro_id, message_id, remitente, asunto, tipo, monto, fecha_operacion,
                              ordenante, ordenante_cuit, nro_operacion, confianza, remitente_banco, lectura, texto, estado, nota)
  VALUES (v_cca.cuenta_cobro_id, v_mid, left(p_d->>'remitente', 200), left(p_d->>'asunto', 300), v_tipo,
          CASE WHEN v_tipo = 'ingreso' THEN v_monto END, v_fecha,
          nullif(left(btrim(coalesce(p_d->>'ordenante', '')), 150), ''),
          nullif(regexp_replace(coalesce(p_d->>'ordenante_cuit', ''), '\D', '', 'g'), ''),
          v_nro, v_conf, v_banco, p_d->'lectura', left(p_d->>'texto', 4000),
          CASE WHEN v_tipo = 'ingreso' THEN 'sin_asignar' ELSE 'no_es_ingreso' END,
          CASE WHEN v_tipo = 'ingreso' AND NOT v_banco
               THEN 'El remitente no es un banco conocido: no se usa solo. Asignarlo a mano si es real.' END)
  RETURNING id INTO v_id;

  IF v_tipo = 'confirmacion_gmail' THEN
    UPDATE cuentas_cobro_avisos
       SET gmail_codigo = nullif(left(p_d->>'gmail_codigo', 40), ''),
           gmail_link = nullif(left(p_d->>'gmail_link', 1000), ''), gmail_en = now()
     WHERE cuenta_cobro_id = v_cca.cuenta_cobro_id;
    RETURN jsonb_build_object('ok', true, 'aviso_id', v_id, 'tipo', v_tipo);
  END IF;
  IF v_tipo <> 'ingreso' THEN
    RETURN jsonb_build_object('ok', true, 'aviso_id', v_id, 'tipo', v_tipo);
  END IF;

  IF v_banco THEN
    UPDATE cuentas_cobro_avisos
       SET primer_aviso_en = coalesce(primer_aviso_en, now()), ultimo_aviso_en = now(), alerta_caida_en = NULL
     WHERE cuenta_cobro_id = v_cca.cuenta_cobro_id;
  END IF;

  -- El mismo ingreso reenviado dos veces (otro message-id, mismo nº de operación)
  IF v_nro IS NOT NULL THEN
    SELECT id INTO v_dup FROM avisos_ingreso
     WHERE cuenta_cobro_id = v_cca.cuenta_cobro_id AND nro_operacion = v_nro AND id <> v_id AND tipo = 'ingreso'
       AND estado <> 'descartado' LIMIT 1;
    IF v_dup IS NOT NULL THEN
      UPDATE avisos_ingreso SET estado = 'descartado', nota = format('Aviso repetido (el mismo que el #%s)', v_dup) WHERE id = v_id;
      RETURN jsonb_build_object('ok', true, 'aviso_id', v_id, 'repetido', true);
    END IF;
  END IF;

  RETURN jsonb_build_object('ok', true, 'aviso_id', v_id, 'tipo', v_tipo) || fn_aviso_emparejar(v_id);
END;
$$;
REVOKE ALL ON FUNCTION aviso_registrar(TEXT, JSONB) FROM PUBLIC, anon, authenticated;


-- ──────────────────────────────────────────────
-- 9) Revisión periódica (cada minuto, la dispara el Worker de Cloudflare):
--    reintenta emparejar, arma alertas, cierra las resueltas y devuelve
--    los mails a mandar.
-- ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION cobros_revisar()
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_cfg   cobros_avisos_config%ROWTYPE;
  v_min   INTERVAL;
  r       RECORD;
  v_tit   TEXT;
  v_det   TEXT;
  v_mails JSONB;
BEGIN
  SELECT * INTO v_cfg FROM cobros_avisos_config WHERE id = 1;
  v_min := make_interval(mins => coalesce(v_cfg.minutos_espera, 7));

  -- a) Avisos sueltos de los últimos 3 días: puede que ya esté el pedido o la venta del local
  FOR r IN SELECT id FROM avisos_ingreso
            WHERE estado = 'sin_asignar' AND tipo = 'ingreso' AND remitente_banco AND recibido_en > now() - interval '3 days'
            ORDER BY id LOOP
    PERFORM fn_aviso_emparejar(r.id);
  END LOOP;
  -- b) Pedidos con comprobante válido sin pagar: ¿llegó su aviso?
  FOR r IN SELECT DISTINCT s.id FROM solicitudes s JOIN comprobantes c ON c.solicitud_id = s.id
            WHERE c.estado = 'coincide' AND s.estado_pago IN ('pendiente','comprobante_recibido','en_revision','vencido')
              AND s.estado <> 'cancelado' AND c.leido_en > now() - interval '7 days' LOOP
    PERFORM fn_cobros_conciliar(r.id);
  END LOOP;

  -- c) Comprobante válido y pasaron N minutos sin confirmarse → revisar a mano
  FOR r IN
    SELECT c.id AS comp, s.id AS sol, s.codigo, s.cliente_nombre, s.monto_a_pagar, s.cuenta_cobro_id AS cta,
           k.nombre AS cuenta, cca.primer_aviso_en,
           (SELECT a.monto FROM avisos_ingreso a WHERE a.solicitud_id = s.id AND a.estado = 'asignado' ORDER BY a.id DESC LIMIT 1) AS aviso_monto
      FROM comprobantes c
      JOIN solicitudes s ON s.id = c.solicitud_id
      LEFT JOIN cuentas_cobro k ON k.id = s.cuenta_cobro_id
      LEFT JOIN cuentas_cobro_avisos cca ON cca.cuenta_cobro_id = s.cuenta_cobro_id
     WHERE c.estado = 'coincide' AND c.leido_en <= now() - v_min AND c.leido_en > now() - interval '7 days'
       AND s.estado_pago IN ('pendiente','comprobante_recibido','en_revision','vencido') AND s.estado <> 'cancelado'
  LOOP
    IF r.aviso_monto IS NOT NULL THEN
      v_tit := format('Pedido %s: el aviso del banco no coincide con el comprobante', r.codigo);
      v_det := format('Entraron %s en %s y el comprobante dice otra cosa. Revisar a mano.',
                      to_char(r.aviso_monto, 'FM999G999G999D00'), coalesce(r.cuenta, 'la cuenta'));
    ELSIF NOT coalesce(v_cfg.auto_con_aviso, true) THEN
      v_tit := format('Pedido %s: comprobante para revisar', r.codigo);
      v_det := 'La confirmación automática está apagada.';
    ELSIF r.primer_aviso_en IS NULL THEN
      v_tit := format('Pedido %s: comprobante OK, falta verificar el ingreso', r.codigo);
      v_det := format('%s todavía no reenvía los avisos del banco. Mirá el ingreso de %s en la cuenta y confirmá a mano.',
                      coalesce(r.cuenta, 'La cuenta'), to_char(r.monto_a_pagar, 'FM999G999G999D00'));
    ELSE
      v_tit := format('Pedido %s: no llegó el aviso del banco', r.codigo);
      v_det := format('El comprobante de %s (%s) coincide, pero en %s minutos no llegó el aviso de %s. Sigue esperando: si llega, se confirma solo. Mientras, revisalo a mano.',
                      coalesce(r.cliente_nombre, 'el cliente'), to_char(r.monto_a_pagar, 'FM999G999G999D00'),
                      coalesce(v_cfg.minutos_espera, 7), coalesce(r.cuenta, 'la cuenta'));
    END IF;
    PERFORM fn_cobros_alerta('sin_aviso:' || r.comp, 'sin_aviso', r.sol, r.comp, NULL, r.cta, v_tit, v_det);
  END LOOP;

  -- d) Comprobante que no coincide o no se pudo leer → revisar ya
  FOR r IN
    SELECT c.id AS comp, s.id AS sol, s.codigo, s.cuenta_cobro_id AS cta, c.estado, c.motivo
      FROM comprobantes c JOIN solicitudes s ON s.id = c.solicitud_id
     WHERE c.estado IN ('no_coincide','ilegible') AND c.leido_en > now() - interval '7 days'
       AND s.estado_pago IN ('pendiente','comprobante_recibido','en_revision','vencido') AND s.estado <> 'cancelado'
  LOOP
    PERFORM fn_cobros_alerta('invalido:' || r.comp, 'comprobante_no_valido', r.sol, r.comp, NULL, r.cta,
      format('Pedido %s: comprobante %s', r.codigo, CASE r.estado WHEN 'ilegible' THEN 'ilegible' ELSE 'que no coincide' END),
      coalesce(r.motivo, 'Revisar a mano.'));
  END LOOP;

  -- e) Comprobante subido que nunca se leyó (lectura caída o sin clave de IA)
  FOR r IN
    SELECT c.id AS comp, s.id AS sol, s.codigo, s.cuenta_cobro_id AS cta
      FROM comprobantes c JOIN solicitudes s ON s.id = c.solicitud_id
     WHERE c.estado = 'recibido' AND c.created_at <= now() - v_min AND c.created_at > now() - interval '7 days'
       AND s.estado_pago IN ('pendiente','comprobante_recibido','en_revision','vencido') AND s.estado <> 'cancelado'
  LOOP
    PERFORM fn_cobros_alerta('sin_lectura:' || r.comp, 'sin_lectura', r.sol, r.comp, NULL, r.cta,
      format('Pedido %s: comprobante sin leer', r.codigo),
      'La lectura automática no lo procesó. Revisarlo a mano (o "Releer con IA").');
  END LOOP;

  -- f) Entró plata y no se encontró a qué pedido corresponde (30 min de margen)
  FOR r IN
    SELECT a.id, a.monto, a.ordenante, a.cuenta_cobro_id AS cta, k.nombre AS cuenta
      FROM avisos_ingreso a LEFT JOIN cuentas_cobro k ON k.id = a.cuenta_cobro_id
     WHERE a.estado = 'sin_asignar' AND a.tipo = 'ingreso'
       AND a.recibido_en <= now() - interval '30 minutes' AND a.recibido_en > now() - interval '3 days'
  LOOP
    PERFORM fn_cobros_alerta('aviso:' || r.id, 'aviso_sin_pedido', NULL, NULL, r.id, r.cta,
      format('Entraron %s en %s sin pedido', to_char(r.monto, 'FM999G999G999D00'), coalesce(r.cuenta, 'una cuenta')),
      format('Transferencia%s sin pedido ni venta del local que coincida. Asignala o descartala en Cuentas bancarias → Avisos.',
             CASE WHEN r.ordenante IS NOT NULL THEN ' de ' || r.ordenante ELSE '' END));
  END LOOP;

  -- g) Reenvío caído: la cuenta mandaba avisos y ya van 2+ pedidos en 24 h sin aviso
  FOR r IN
    SELECT cca.cuenta_cobro_id AS cta, k.nombre AS cuenta, cca.ultimo_aviso_en, count(*) AS n
      FROM cuentas_cobro_avisos cca
      JOIN cuentas_cobro k ON k.id = cca.cuenta_cobro_id
      JOIN cobros_alertas al ON al.cuenta_cobro_id = cca.cuenta_cobro_id AND al.tipo = 'sin_aviso'
                            AND al.creada_en > now() - interval '24 hours'
                            AND al.creada_en > coalesce(cca.ultimo_aviso_en, '-infinity')
     WHERE cca.primer_aviso_en IS NOT NULL
       AND (cca.alerta_caida_en IS NULL OR cca.alerta_caida_en < now() - interval '24 hours')
     GROUP BY cca.cuenta_cobro_id, k.nombre, cca.ultimo_aviso_en
    HAVING count(*) >= 2
  LOOP
    PERFORM fn_cobros_alerta('caido:' || r.cta || ':' || to_char(fn_mh_local(now()), 'YYYYMMDD'), 'reenvio_caido', NULL, NULL, NULL, r.cta,
      format('El reenvío de avisos de %s parece caído', r.cuenta),
      format('Último aviso: %s. Ya hay %s pedidos sin aviso. Revisar el filtro de Gmail de esa cuenta.',
             coalesce(to_char(fn_mh_local(r.ultimo_aviso_en), 'DD/MM HH24:MI'), 'nunca'), r.n));
    UPDATE cuentas_cobro_avisos SET alerta_caida_en = now() WHERE cuenta_cobro_id = r.cta;
  END LOOP;

  -- h) Se cierran las alertas que ya no hacen falta
  UPDATE cobros_alertas al
     SET resuelta_en = now(), mail_estado = CASE WHEN mail_estado = 'pendiente' THEN 'no_corresponde' ELSE mail_estado END
   WHERE al.resuelta_en IS NULL AND (
         EXISTS (SELECT 1 FROM solicitudes s WHERE s.id = al.solicitud_id AND (s.estado_pago = 'pagado' OR s.estado = 'cancelado'))
      OR EXISTS (SELECT 1 FROM comprobantes c WHERE c.id = al.comprobante_id AND (
                   c.estado IN ('aceptado','rechazado')
                OR (al.tipo = 'comprobante_no_valido' AND c.estado NOT IN ('no_coincide','ilegible'))
                OR (al.tipo = 'sin_lectura' AND c.estado <> 'recibido')))
      OR (al.tipo = 'aviso_sin_pedido' AND EXISTS (SELECT 1 FROM avisos_ingreso a WHERE a.id = al.aviso_id AND a.estado <> 'sin_asignar'))
      OR (al.tipo = 'reenvio_caido' AND EXISTS (SELECT 1 FROM cuentas_cobro_avisos x
                                                  WHERE x.cuenta_cobro_id = al.cuenta_cobro_id AND x.ultimo_aviso_en > al.creada_en)));

  -- i) Mails para mandar (el Worker avisa después si salieron)
  IF nullif(btrim(coalesce(v_cfg.mail_alertas, '')), '') IS NULL THEN
    UPDATE cobros_alertas SET mail_estado = 'no_corresponde' WHERE mail_estado = 'pendiente';
    RETURN jsonb_build_object('ok', true, 'para', NULL, 'mails', '[]'::jsonb);
  END IF;
  UPDATE cobros_alertas SET mail_estado = 'fallo'
   WHERE mail_estado = 'pendiente' AND mail_intentos >= 3;
  WITH m AS (
    UPDATE cobros_alertas
       SET mail_intentos = mail_intentos + 1, mail_en = now()
     WHERE id IN (SELECT id FROM cobros_alertas
                   WHERE mail_estado = 'pendiente' AND resuelta_en IS NULL
                     AND (mail_en IS NULL OR mail_en < now() - interval '5 minutes')
                   ORDER BY id LIMIT 20)
    RETURNING id, titulo, detalle, solicitud_id, tipo
  )
  SELECT coalesce(jsonb_agg(jsonb_build_object('id', id, 'titulo', titulo, 'detalle', detalle, 'tipo', tipo,
           'link', CASE WHEN solicitud_id IS NOT NULL
                        THEN 'https://mundohogarstf.com/admin/app#/pedidos?ver=' || solicitud_id
                        ELSE 'https://mundohogarstf.com/admin/app#/cuentas-cobro' END) ORDER BY id), '[]'::jsonb)
    INTO v_mails FROM m;

  RETURN jsonb_build_object('ok', true, 'para', btrim(v_cfg.mail_alertas), 'mails', v_mails);
END;
$$;
REVOKE ALL ON FUNCTION cobros_revisar() FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION cobros_alertas_mail_resultado(p_ids BIGINT[], p_ok BOOLEAN)
RETURNS INT LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_n INT;
BEGIN
  UPDATE cobros_alertas
     SET mail_estado = CASE WHEN p_ok THEN 'enviado' WHEN mail_intentos >= 3 THEN 'fallo' ELSE 'pendiente' END
   WHERE id = ANY(p_ids) AND mail_estado = 'pendiente';
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END;
$$;
REVOKE ALL ON FUNCTION cobros_alertas_mail_resultado(BIGINT[], BOOLEAN) FROM PUBLIC, anon, authenticated;


-- ──────────────────────────────────────────────
-- 10) RPC del panel
-- ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION cobros_alerta_vista(p_id BIGINT DEFAULT NULL)
RETURNS INT LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_n INT;
BEGIN
  IF NOT fn_es_staff_ventas() THEN RAISE EXCEPTION 'sin_permiso'; END IF;
  UPDATE cobros_alertas SET vista_por = auth.uid(), vista_en = now()
   WHERE vista_en IS NULL AND (p_id IS NULL OR id = p_id);
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END;
$$;
REVOKE ALL ON FUNCTION cobros_alerta_vista(BIGINT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION cobros_alerta_vista(BIGINT) TO authenticated;

-- Asignar a mano un aviso suelto a un pedido (misma cuenta)
CREATE OR REPLACE FUNCTION aviso_asignar(p_aviso_id BIGINT, p_solicitud_id BIGINT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_a   avisos_ingreso%ROWTYPE;
  v_sol solicitudes%ROWTYPE;
BEGIN
  IF NOT fn_es_staff_ventas() THEN RAISE EXCEPTION 'sin_permiso' USING HINT = 'Tu rol no puede asignar avisos.'; END IF;
  SELECT * INTO v_a FROM avisos_ingreso WHERE id = p_aviso_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'aviso_no_encontrado'; END IF;
  IF v_a.estado NOT IN ('sin_asignar','asignado') OR v_a.tipo <> 'ingreso' THEN
    RAISE EXCEPTION 'aviso_no_disponible' USING HINT = 'Este aviso ya se usó o se descartó.';
  END IF;
  SELECT * INTO v_sol FROM solicitudes WHERE id = p_solicitud_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'pedido_no_encontrado'; END IF;
  IF v_sol.cuenta_cobro_id IS DISTINCT FROM v_a.cuenta_cobro_id THEN
    RAISE EXCEPTION 'cuenta_distinta' USING HINT = 'El aviso es de otra cuenta que la asignada al pedido.';
  END IF;
  IF v_sol.estado_pago = 'pagado' THEN
    RAISE EXCEPTION 'pedido_ya_pagado' USING HINT = 'Este pedido ya figura pagado.';
  END IF;
  UPDATE avisos_ingreso SET estado = 'asignado', solicitud_id = v_sol.id, revisado_por = auth.uid(), revisado_en = now()
   WHERE id = v_a.id;
  INSERT INTO solicitud_eventos (solicitud_id, estado_anterior, estado_nuevo, detalle, usuario_id)
  VALUES (v_sol.id, v_sol.estado, v_sol.estado,
          format('Aviso del banco asignado a mano: %s', to_char(v_a.monto, 'FM999G999G999D00')), auth.uid());
  RETURN jsonb_build_object('ok', true, 'conciliacion', fn_cobros_conciliar(v_sol.id));
END;
$$;
REVOKE ALL ON FUNCTION aviso_asignar(BIGINT, BIGINT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION aviso_asignar(BIGINT, BIGINT) TO authenticated;

CREATE OR REPLACE FUNCTION aviso_descartar(p_aviso_id BIGINT, p_nota TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_nota TEXT := nullif(left(btrim(coalesce(p_nota, '')), 300), '');
BEGIN
  IF NOT fn_es_staff_ventas() THEN RAISE EXCEPTION 'sin_permiso'; END IF;
  IF v_nota IS NULL THEN RAISE EXCEPTION 'motivo_requerido' USING HINT = 'Escribí por qué se descarta (ej.: transferencia personal).'; END IF;
  UPDATE avisos_ingreso SET estado = 'descartado', nota = v_nota, revisado_por = auth.uid(), revisado_en = now()
   WHERE id = p_aviso_id AND estado IN ('sin_asignar','asignado');
  IF NOT FOUND THEN RAISE EXCEPTION 'aviso_no_disponible' USING HINT = 'Este aviso ya se usó o se descartó.'; END IF;
  UPDATE cobros_alertas SET resuelta_en = now(), mail_estado = CASE WHEN mail_estado = 'pendiente' THEN 'no_corresponde' ELSE mail_estado END
   WHERE aviso_id = p_aviso_id AND resuelta_en IS NULL;
  RETURN jsonb_build_object('ok', true);
END;
$$;
REVOKE ALL ON FUNCTION aviso_descartar(BIGINT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION aviso_descartar(BIGINT, TEXT) TO authenticated;

-- Nueva dirección para una cuenta (si la vieja se filtró). Hay que cambiar el filtro de Gmail.
CREATE OR REPLACE FUNCTION cuenta_avisos_regenerar(p_cuenta_id BIGINT)
RETURNS TEXT LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_t TEXT := fn_avisos_token_nuevo();
BEGIN
  IF coalesce(fn_get_user_role(), '') <> 'administrador' THEN RAISE EXCEPTION 'sin_permiso'; END IF;
  INSERT INTO cuentas_cobro_avisos (cuenta_cobro_id, token) VALUES (p_cuenta_id, v_t)
  ON CONFLICT (cuenta_cobro_id) DO UPDATE
     SET token = v_t, gmail_codigo = NULL, gmail_link = NULL, gmail_en = NULL,
         primer_aviso_en = NULL, ultimo_aviso_en = NULL, ultimo_mail_en = NULL, alerta_caida_en = NULL;
  RETURN v_t;
END;
$$;
REVOKE ALL ON FUNCTION cuenta_avisos_regenerar(BIGINT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION cuenta_avisos_regenerar(BIGINT) TO authenticated;


-- ──────────────────────────────────────────────
-- 11) Permisos justos (Supabase da de más por defecto a las tablas nuevas;
--     RLS ya frena, pero se deja solo lo que se usa)
-- ──────────────────────────────────────────────
REVOKE ALL ON avisos_ingreso, cuentas_cobro_avisos, cobros_alertas, cobros_avisos_config FROM anon, authenticated;
GRANT SELECT ON avisos_ingreso, cuentas_cobro_avisos, cobros_alertas, cobros_avisos_config TO authenticated;
GRANT UPDATE ON cobros_avisos_config TO authenticated;
REVOKE ALL ON SEQUENCE avisos_ingreso_id_seq, cobros_alertas_id_seq FROM anon, authenticated;
