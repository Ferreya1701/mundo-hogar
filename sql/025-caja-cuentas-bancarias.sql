-- ============================================================
-- 025 — CUENTAS BANCARIAS EN LA CAJA, IGUAL QUE EN LA WEB (2026-11-12)
-- Ejecutar en Supabase → SQL Editor, DESPUÉS del 024.
-- Idempotente: se puede correr más de una vez sin romper nada.
--
-- Antes: en Crear venta, al cobrar por transferencia o Mercado Pago, la
-- vendedora elegía la cuenta de una lista y eso era solo una etiqueta: no
-- miraba los límites ni contaba para los cupos. La web y la caja podían
-- cargar la misma cuenta por encima de su límite sin que nadie se enterara.
--
-- Ahora la caja usa EL MISMO reparto que el carrito de la web:
--   • La cuenta la ASIGNA el sistema (fn_cobros_elegir_cuenta): la que tiene
--     cupo diario y mensual para ese monto y viene más "descansada" según su
--     peso; si ninguna tiene cupo, la de respaldo.
--   • Al pedir la cuenta se RESERVA el monto unos minutos, para que dos cajas
--     (o la caja y la web) no manden al mismo tiempo dos pagos grandes a una
--     cuenta que está por llenarse.
--   • La venta queda asentada como cobro de esa cuenta (movimientos_cobro):
--     cuenta para los límites, para el resumen de Cuentas bancarias y para la
--     liquidación del mes, igual que un pedido web pagado.
--   • Anular la venta, o quitarle productos, devuelve el cupo solo.
--   • La caja NUNCA frena: si la plata ya se transfirió a una cuenta, la venta
--     se registra en esa cuenta aunque se pase del límite, y avisa.
--   • Si no hay ninguna cuenta activa cargada, todo sigue como antes.
--
-- También: N° de operación opcional en la venta, y resumen por cuenta en la
-- caja del día (para controlar las transferencias al cierre).
-- ============================================================

ALTER TABLE movimientos_cobro ADD COLUMN IF NOT EXISTS venta_id BIGINT REFERENCES ventas(id) ON DELETE SET NULL;
CREATE INDEX IF NOT EXISTS idx_mov_cobro_venta ON movimientos_cobro (venta_id) WHERE venta_id IS NOT NULL;
ALTER TABLE ventas ADD COLUMN IF NOT EXISTS nro_operacion TEXT CHECK (nro_operacion IS NULL OR length(nro_operacion) <= 60);

-- Reservas cortas: "le estoy por mandar $X a esta cuenta"
CREATE TABLE IF NOT EXISTS cobro_reservas (
  id              BIGSERIAL PRIMARY KEY,
  cuenta_cobro_id BIGINT NOT NULL REFERENCES cuentas_cobro(id) ON DELETE CASCADE,
  monto           NUMERIC(12,2) NOT NULL CHECK (monto > 0),
  usuario_id      UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  creada_en       TIMESTAMPTZ NOT NULL DEFAULT now(),
  vence_en        TIMESTAMPTZ NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_cobro_reservas_cuenta ON cobro_reservas (cuenta_cobro_id, vence_en);
ALTER TABLE cobro_reservas ENABLE ROW LEVEL SECURITY;   -- sin políticas: solo las funciones
REVOKE ALL ON cobro_reservas FROM anon, authenticated;


-- ──────────────────────────────────────────────
-- 1) Lo "tomado" de una cuenta ahora incluye las reservas vigentes de la caja
-- ──────────────────────────────────────────────
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
  + coalesce((
    SELECT sum(monto) FROM cobro_reservas
     WHERE cuenta_cobro_id = p_cuenta AND vence_en > now()), 0)
$$;

-- Mismo criterio de siempre, pudiendo dejar afuera algunas cuentas ("dame otra")
CREATE OR REPLACE FUNCTION fn_cobros_elegir_cuenta_excl(p_monto NUMERIC, p_excluir BIGINT[])
RETURNS BIGINT LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_hoy  TIMESTAMP := date_trunc('day',   fn_mh_local(now()));
  v_mes  TIMESTAMP := date_trunc('month', fn_mh_local(now()));
  v_exc  BIGINT[] := coalesce(p_excluir, ARRAY[]::BIGINT[]);
  v_id   BIGINT;
BEGIN
  SELECT c.id INTO v_id
    FROM cuentas_cobro c
   WHERE c.activa AND c.id <> ALL (v_exc)
     AND (c.limite_mensual IS NULL OR fn_cuenta_acumulado(c.id, v_mes) + p_monto <= c.limite_mensual)
     AND (c.limite_diario  IS NULL OR fn_cuenta_acumulado(c.id, v_hoy) + p_monto <= c.limite_diario)
   ORDER BY fn_cuenta_acumulado(c.id, v_mes) / c.peso ASC, c.orden ASC, c.id ASC
   LIMIT 1;
  IF v_id IS NOT NULL THEN RETURN v_id; END IF;

  -- Ninguna entra en sus límites: la de respaldo (sin mirar límites)
  SELECT c.id INTO v_id FROM cuentas_cobro c
   WHERE c.activa AND c.es_respaldo AND c.id <> ALL (v_exc)
   ORDER BY c.orden, c.id LIMIT 1;
  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION fn_cobros_elegir_cuenta(p_monto NUMERIC)
RETURNS BIGINT LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT fn_cobros_elegir_cuenta_excl(p_monto, ARRAY[]::BIGINT[])
$$;

-- Lo que se le muestra a la vendedora (y al cliente) de una cuenta: sin CUIT ni límites.
CREATE OR REPLACE FUNCTION fn_cobros_cuenta_publica(p_cuenta BIGINT)
RETURNS JSONB LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT jsonb_build_object('id', c.id, 'nombre', c.nombre, 'titular', c.titular, 'banco', c.banco,
                            'alias', nullif(btrim(c.alias), ''),
                            'cvu', CASE WHEN nullif(btrim(c.alias), '') IS NULL THEN c.cvu END,
                            'es_respaldo', c.es_respaldo)
  FROM cuentas_cobro c WHERE c.id = p_cuenta
$$;

-- ¿La cuenta quedó pasada de algún límite? Texto para avisar (NULL si está bien).
CREATE OR REPLACE FUNCTION fn_cobros_aviso_limite(p_cuenta BIGINT)
RETURNS TEXT LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  c     cuentas_cobro%ROWTYPE;
  v_dia NUMERIC; v_mes NUMERIC;
BEGIN
  SELECT * INTO c FROM cuentas_cobro WHERE id = p_cuenta;
  IF NOT FOUND THEN RETURN NULL; END IF;
  v_dia := fn_cuenta_acumulado(c.id, date_trunc('day',   fn_mh_local(now())));
  v_mes := fn_cuenta_acumulado(c.id, date_trunc('month', fn_mh_local(now())));
  IF c.limite_mensual IS NOT NULL AND v_mes > c.limite_mensual THEN
    RETURN format('La cuenta %s pasó su límite del mes (%s de %s). Avisale al administrador.', c.nombre,
                  to_char(v_mes, 'FM999G999G990'), to_char(c.limite_mensual, 'FM999G999G990'));
  ELSIF c.limite_diario IS NOT NULL AND v_dia > c.limite_diario THEN
    RETURN format('La cuenta %s pasó su límite de hoy (%s de %s). Avisale al administrador.', c.nombre,
                  to_char(v_dia, 'FM999G999G990'), to_char(c.limite_diario, 'FM999G999G990'));
  ELSIF NOT c.activa THEN
    RETURN format('La cuenta %s está desactivada. Avisale al administrador.', c.nombre);
  END IF;
  RETURN NULL;
END;
$$;

REVOKE ALL ON FUNCTION fn_cobros_elegir_cuenta_excl(NUMERIC, BIGINT[]) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION fn_cobros_cuenta_publica(BIGINT) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION fn_cobros_aviso_limite(BIGINT) FROM PUBLIC, anon, authenticated;


-- ──────────────────────────────────────────────
-- 2) La caja pide a qué cuenta transferir (y reserva el monto 15 minutos)
-- ──────────────────────────────────────────────
-- Devuelve { cuenta: {...} | null, motivo, aviso, vence_en }.
--   motivo = 'sin_cuentas' (no hay ninguna activa) | 'sin_cupo' (ninguna tiene cupo ni hay respaldo)
CREATE OR REPLACE FUNCTION caja_cuenta_pedir(p_monto NUMERIC, p_excluir BIGINT[] DEFAULT NULL)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_monto NUMERIC(12,2) := round(p_monto, 2);
  v_id    BIGINT;
  v_c     cuentas_cobro%ROWTYPE;
  v_vence TIMESTAMPTZ := now() + interval '15 minutes';
  v_aviso TEXT;
BEGIN
  IF NOT fn_tiene_permiso('ventas.crear') THEN
    RAISE EXCEPTION 'sin_permiso' USING HINT = 'Tu usuario no puede registrar ventas.';
  END IF;
  IF v_monto IS NULL OR v_monto <= 0 OR v_monto > 1000000000 THEN
    RAISE EXCEPTION 'monto_invalido' USING HINT = 'El total tiene que ser mayor a cero.';
  END IF;

  -- De a uno: dos cajas pidiendo a la vez no reciben la misma cuenta "casi llena"
  PERFORM pg_advisory_xact_lock(hashtext('cobros_cuenta'));
  DELETE FROM cobro_reservas WHERE usuario_id = auth.uid() OR vence_en <= now();

  IF NOT EXISTS (SELECT 1 FROM cuentas_cobro WHERE activa) THEN
    RETURN jsonb_build_object('ok', true, 'cuenta', NULL, 'motivo', 'sin_cuentas');
  END IF;
  v_id := fn_cobros_elegir_cuenta_excl(v_monto, p_excluir);
  IF v_id IS NULL AND coalesce(cardinality(p_excluir), 0) > 0 THEN
    v_id := fn_cobros_elegir_cuenta_excl(v_monto, NULL);    -- no hay "otra": la mejor disponible
    v_aviso := 'No hay otra cuenta con cupo para este monto.';
  END IF;
  IF v_id IS NULL THEN
    RETURN jsonb_build_object('ok', true, 'cuenta', NULL, 'motivo', 'sin_cupo');
  END IF;

  SELECT * INTO v_c FROM cuentas_cobro WHERE id = v_id;
  IF v_c.es_respaldo AND (
       (v_c.limite_mensual IS NOT NULL AND fn_cuenta_acumulado(v_id, date_trunc('month', fn_mh_local(now()))) + v_monto > v_c.limite_mensual)
    OR (v_c.limite_diario  IS NOT NULL AND fn_cuenta_acumulado(v_id, date_trunc('day',   fn_mh_local(now()))) + v_monto > v_c.limite_diario)) THEN
    v_aviso := 'Ninguna cuenta tiene cupo para este monto: se usa la de respaldo. Avisale al administrador.';
  END IF;

  INSERT INTO cobro_reservas (cuenta_cobro_id, monto, usuario_id, vence_en) VALUES (v_id, v_monto, auth.uid(), v_vence);

  RETURN jsonb_build_object('ok', true, 'cuenta', fn_cobros_cuenta_publica(v_id), 'monto', v_monto,
                            'aviso', v_aviso, 'vence_en', v_vence);
END;
$$;
REVOKE ALL ON FUNCTION caja_cuenta_pedir(NUMERIC, BIGINT[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION caja_cuenta_pedir(NUMERIC, BIGINT[]) TO authenticated;

-- Soltar la reserva (cambió el medio de pago, se vació el ticket)
CREATE OR REPLACE FUNCTION caja_cuenta_soltar()
RETURNS VOID LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
  DELETE FROM cobro_reservas WHERE usuario_id = auth.uid()
$$;
REVOKE ALL ON FUNCTION caja_cuenta_soltar() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION caja_cuenta_soltar() TO authenticated;


-- ──────────────────────────────────────────────
-- 3) Al registrar la venta: qué cuenta queda
-- ──────────────────────────────────────────────
-- La que vino (ahí ya está la plata), o la que elija el sistema si no vino
-- ninguna y hay cuentas activas. Suelta la reserva de quien vende.
CREATE OR REPLACE FUNCTION fn_caja_resolver_cuenta(p_cuenta BIGINT, p_total NUMERIC)
RETURNS BIGINT LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('cobros_cuenta'));
  DELETE FROM cobro_reservas WHERE usuario_id = auth.uid() OR vence_en <= now();
  IF p_cuenta IS NOT NULL AND EXISTS (SELECT 1 FROM cuentas_cobro WHERE id = p_cuenta) THEN
    RETURN p_cuenta;
  END IF;
  IF p_total IS NULL OR p_total <= 0 OR NOT EXISTS (SELECT 1 FROM cuentas_cobro WHERE activa) THEN
    RETURN NULL;
  END IF;
  RETURN fn_cobros_elegir_cuenta_excl(p_total, NULL);
END;
$$;
REVOKE ALL ON FUNCTION fn_caja_resolver_cuenta(BIGINT, NUMERIC) FROM PUBLIC, anon, authenticated;


-- ──────────────────────────────────────────────
-- 4) La venta por transferencia / Mercado Pago es un cobro de la cuenta
-- ──────────────────────────────────────────────
-- Igual que la caja y la cuenta corriente: lo que la venta debería tener
-- asentado en la cuenta contra lo que tiene; la diferencia se asienta como
-- cobro o como anulación. Sirve para el alta, anular y quitar productos.
CREATE OR REPLACE FUNCTION fn_cobros_sincronizar_venta(p_venta_id BIGINT)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v       ventas%ROWTYPE;
  v_cta   BIGINT;
  v_debe  NUMERIC(12,2);
  v_tiene NUMERIC(12,2);
  v_dif   NUMERIC(12,2);
BEGIN
  SELECT * INTO v FROM ventas WHERE id = p_venta_id;
  IF NOT FOUND THEN RETURN; END IF;
  PERFORM pg_advisory_xact_lock(hashtext('cobro_venta:' || p_venta_id));

  SELECT coalesce(sum(CASE WHEN tipo = 'cobro' THEN monto ELSE -monto END), 0), max(cuenta_cobro_id)
    INTO v_tiene, v_cta
  FROM movimientos_cobro WHERE venta_id = p_venta_id;
  v_cta := coalesce(v_cta, v.cuenta_cobro_id);          -- la devolución sale de la cuenta donde entró
  IF v_cta IS NULL THEN RETURN; END IF;

  v_debe := CASE WHEN v.estado = 'cerrada' AND v.medio_pago IN ('transferencia', 'mercadopago')
                  AND v.cuenta_cobro_id IS NOT NULL THEN v.total ELSE 0 END;
  v_dif := v_debe - v_tiene;
  IF v_dif = 0 THEN RETURN; END IF;

  INSERT INTO movimientos_cobro (cuenta_cobro_id, venta_id, tipo, monto, nro_operacion, detalle, usuario_id)
  VALUES (v_cta, v.id, CASE WHEN v_dif > 0 THEN 'cobro' ELSE 'anulacion' END, abs(v_dif),
          CASE WHEN v_dif > 0 THEN v.nro_operacion END,
          CASE WHEN v_dif > 0 THEN 'Venta en el local ' ELSE 'Devolución venta en el local ' END || v.codigo
            || CASE WHEN v.estado = 'anulada' AND v_dif < 0 THEN ' (anulada)' ELSE '' END,
          coalesce(auth.uid(), v.vendedor_id));
END;
$$;
REVOKE ALL ON FUNCTION fn_cobros_sincronizar_venta(BIGINT) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION fn_tr_ventas_cobros()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  PERFORM fn_cobros_sincronizar_venta(NEW.id);
  RETURN NULL;
END;
$$;
DROP TRIGGER IF EXISTS tr_ventas_cobros ON ventas;
CREATE TRIGGER tr_ventas_cobros AFTER UPDATE OF total, estado, medio_pago, cuenta_cobro_id ON ventas
  FOR EACH ROW EXECUTE FUNCTION fn_tr_ventas_cobros();


-- ──────────────────────────────────────────────
-- 5) venta_registrar: resuelve la cuenta al fijar el total
-- ──────────────────────────────────────────────
-- Se cambian SOLO tres puntos de la función instalada (la del 019). Si no
-- se encuentran, el script se detiene sin tocar nada.
DO $migr$
DECLARE
  v_def TEXT := pg_get_functiondef('venta_registrar(jsonb)'::regprocedure);
  r     RECORD;
BEGIN
  IF position('fn_caja_resolver_cuenta' IN v_def) > 0 THEN
    RAISE NOTICE '025: venta_registrar ya resuelve la cuenta bancaria, no se toca';
    RETURN;
  END IF;
  FOR r IN SELECT * FROM (VALUES
    ($a$  -- Al fijar el total, los disparadores asientan la caja (018) y la cuenta corriente (019)$a$,
     $b$  -- 025: transferencia o Mercado Pago → cuenta bancaria con el mismo reparto que la web
  IF v_medio IN ('transferencia', 'mercadopago') THEN
    v_cuenta := fn_caja_resolver_cuenta(v_cuenta, v_total);
  ELSE
    v_cuenta := NULL;
  END IF;

  -- Al fijar el total, los disparadores asientan la caja (018), la cuenta corriente (019) y la cuenta bancaria (025)$b$),
    ($a$items_count = v_n, unidades = v_unid, stock_afectado = v_afect, recargo_total = v_rec_tot$a$,
     $b$items_count = v_n, unidades = v_unid, stock_afectado = v_afect, recargo_total = v_rec_tot,
                    cuenta_cobro_id = v_cuenta,
                    nro_operacion = CASE WHEN v_cuenta IS NOT NULL THEN nullif(left(btrim(coalesce(p->>'nro_operacion', '')), 60), '') END$b$),
    ($a$'recargo_total', v_rec_tot, 'cuenta_corriente', v_cc_out);$a$,
     $b$'recargo_total', v_rec_tot, 'cuenta_corriente', v_cc_out,
                            'cuenta_cobro', fn_cobros_cuenta_publica(v_cuenta),
                            'aviso_cuenta', fn_cobros_aviso_limite(v_cuenta));$b$)
  ) AS t(antes, despues)
  LOOP
    IF position(r.antes IN v_def) = 0 THEN
      RAISE EXCEPTION '025: no encontré en venta_registrar el punto esperado (%). Revisar esa función antes de seguir.', left(r.antes, 60);
    END IF;
    v_def := replace(v_def, r.antes, r.despues);
  END LOOP;
  EXECUTE v_def;
END
$migr$;


-- ──────────────────────────────────────────────
-- 6) Caja del día: cuánto entró a cada cuenta (para controlar al cierre)
-- ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION caja_por_cuenta(p_sesion_id BIGINT DEFAULT NULL)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v_id BIGINT := coalesce(p_sesion_id, fn_caja_abierta_id());
BEGIN
  IF NOT fn_tiene_permiso('caja.ver') THEN
    RAISE EXCEPTION 'sin_permiso' USING HINT = 'Tu usuario no puede ver la caja.';
  END IF;
  IF v_id IS NULL THEN RETURN '[]'::jsonb; END IF;
  RETURN coalesce((
    SELECT jsonb_agg(jsonb_build_object('cuenta', x.nombre, 'titular', x.titular, 'alias', x.alias,
                                        'ventas', x.ventas, 'total', x.total) ORDER BY x.total DESC)
    FROM (
      SELECT coalesce(c.nombre, 'Sin cuenta asignada') AS nombre, c.titular, c.alias,
             count(DISTINCT m.venta_id) AS ventas,
             sum(CASE m.tipo WHEN 'ingreso' THEN m.monto ELSE -m.monto END) AS total
      FROM caja_movimientos m
      JOIN ventas v ON v.id = m.venta_id
      LEFT JOIN cuentas_cobro c ON c.id = v.cuenta_cobro_id
      WHERE m.sesion_id = v_id AND m.medio_pago IN ('transferencia', 'mercadopago')
      GROUP BY c.id, c.nombre, c.titular, c.alias
      HAVING sum(CASE m.tipo WHEN 'ingreso' THEN m.monto ELSE -m.monto END) <> 0
    ) x), '[]'::jsonb);
END;
$$;
REVOKE ALL ON FUNCTION caja_por_cuenta(BIGINT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION caja_por_cuenta(BIGINT) TO authenticated;

NOTIFY pgrst, 'reload schema';

SELECT (SELECT count(*) FROM cuentas_cobro WHERE activa) AS cuentas_activas,
       pg_get_functiondef('venta_registrar(jsonb)'::regprocedure) LIKE '%fn_caja_resolver_cuenta%' AS venta_usa_reparto;
