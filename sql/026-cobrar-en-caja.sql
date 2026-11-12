-- ============================================================
-- 026 — LA VENTA SE COBRA EN LA CAJA, CON PAGO MIXTO (2026-11-12)
-- Ejecutar en Supabase → SQL Editor, DESPUÉS del 025.
-- Idempotente: se puede correr más de una vez sin romper nada.
--
-- Antes: Crear venta cobraba en el momento y la plata se asentaba ahí.
-- Ahora (decisión del dueño: SIEMPRE por caja):
--
--   1. La vendedora arma la venta y la ENVÍA A CAJA. Queda "esperando
--      cobro" (estado pendiente_cobro). La mercadería ya queda reservada
--      (el stock se descuenta en ese momento, como siempre). No entra
--      plata a ningún lado todavía.
--   2. La cajera la ve en Caja → "Para cobrar", elige cómo paga el cliente
--      —uno o VARIOS medios (pago mixto)— y cobra. Recién ahí:
--        • entra a la caja, cada parte por su medio;
--        • la parte por transferencia / Mercado Pago se asigna a una cuenta
--          bancaria con el reparto y los límites de siempre (025).
--   3. La cajera puede DEVOLVER la venta a la vendedora (con motivo) o
--      cancelarla; cancelar devuelve el stock.
--   • Cobrar exige la caja ABIERTA (la plata siempre cae en una caja).
--   • Las ventas en CUENTA CORRIENTE no pasan por caja: no hay plata que
--     cobrar; se cargan a la cuenta del cliente al crearlas, como hasta ahora.
--   • Anular o quitar productos de una venta ya cobrada devuelve la plata
--     por los medios con que se pagó (primero el efectivo).
--
-- Permiso nuevo: caja.cobrar ("Cobrar ventas en la caja").
-- ============================================================


-- ──────────────────────────────────────────────
-- 1) Permiso
-- ──────────────────────────────────────────────
CREATE TEMP TABLE _permisos_026 (clave TEXT, modulo TEXT, nombre TEXT, descripcion TEXT, orden INT, roles TEXT[]) ON COMMIT DROP;
INSERT INTO _permisos_026 VALUES
  ('caja.cobrar', 'Caja', 'Cobrar ventas en la caja',
     'Ver las ventas que esperan cobro, cobrarlas (uno o varios medios de pago), devolverlas a la vendedora o cancelarlas.', 205, ARRAY['vendedor']);

INSERT INTO permisos (clave, modulo, nombre, descripcion, orden)
SELECT clave, modulo, nombre, descripcion, orden FROM _permisos_026
ON CONFLICT (clave) DO UPDATE SET modulo = EXCLUDED.modulo, nombre = EXCLUDED.nombre, descripcion = EXCLUDED.descripcion, orden = EXCLUDED.orden;
INSERT INTO rol_permisos (rol, permiso)
SELECT unnest(n.roles), n.clave FROM _permisos_026 n JOIN permisos p ON p.clave = n.clave
WHERE NOT p.iniciales_aplicados ON CONFLICT DO NOTHING;
UPDATE permisos SET iniciales_aplicados = true WHERE clave IN (SELECT clave FROM _permisos_026) AND NOT iniciales_aplicados;


-- ──────────────────────────────────────────────
-- 2) Estados, medios y pagos de la venta
-- ──────────────────────────────────────────────
ALTER TABLE ventas DROP CONSTRAINT IF EXISTS ventas_estado_check;
ALTER TABLE ventas ADD CONSTRAINT ventas_estado_check CHECK (estado IN ('pendiente_cobro', 'cerrada', 'anulada'));
ALTER TABLE ventas DROP CONSTRAINT IF EXISTS ventas_medio_pago_check;
ALTER TABLE ventas ADD CONSTRAINT ventas_medio_pago_check
  CHECK (medio_pago IN ('efectivo','transferencia','debito','credito','mercadopago','cuenta_corriente','otro','pendiente','mixto'));

ALTER TABLE ventas ADD COLUMN IF NOT EXISTS cobrada_en         TIMESTAMPTZ;
ALTER TABLE ventas ADD COLUMN IF NOT EXISTS cobrada_por        UUID REFERENCES auth.users(id) ON DELETE SET NULL;
ALTER TABLE ventas ADD COLUMN IF NOT EXISTS cobrada_por_nombre TEXT;
-- La cajera la devolvió a la vendedora (no se puede cobrar así): motivo y cuándo
ALTER TABLE ventas ADD COLUMN IF NOT EXISTS devuelta_en        TIMESTAMPTZ;
ALTER TABLE ventas ADD COLUMN IF NOT EXISTS devuelta_motivo    TEXT CHECK (devuelta_motivo IS NULL OR length(devuelta_motivo) <= 300);
ALTER TABLE ventas ADD COLUMN IF NOT EXISTS devuelta_por_nombre TEXT;
CREATE INDEX IF NOT EXISTS idx_ventas_pendientes ON ventas (fecha) WHERE estado = 'pendiente_cobro';

-- Con qué se pagó cada venta (una fila por medio)
CREATE TABLE IF NOT EXISTS venta_pagos (
  id              BIGSERIAL PRIMARY KEY,
  venta_id        BIGINT NOT NULL REFERENCES ventas(id) ON DELETE CASCADE,
  medio_pago      TEXT NOT NULL CHECK (medio_pago IN ('efectivo','transferencia','debito','credito','mercadopago','otro')),
  monto           NUMERIC(12,2) NOT NULL CHECK (monto >= 0),       -- baja si después se quitan productos
  monto_original  NUMERIC(12,2) NOT NULL CHECK (monto_original > 0),
  cuenta_cobro_id BIGINT REFERENCES cuentas_cobro(id) ON DELETE SET NULL,
  nro_operacion   TEXT CHECK (nro_operacion IS NULL OR length(nro_operacion) <= 60),
  orden           INT NOT NULL DEFAULT 0,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_venta_pagos_venta ON venta_pagos (venta_id);
ALTER TABLE venta_pagos ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "venta_pagos_select" ON venta_pagos;
CREATE POLICY "venta_pagos_select" ON venta_pagos FOR SELECT
  USING (EXISTS (SELECT 1 FROM ventas v WHERE v.id = venta_pagos.venta_id));   -- se ven si se ve la venta
REVOKE ALL ON venta_pagos FROM anon;
REVOKE INSERT, UPDATE, DELETE ON venta_pagos FROM authenticated;
GRANT SELECT ON venta_pagos TO authenticated;

-- Quién ve las ventas: como antes, más la cajera (las que esperan cobro y las que ella cobró)
DROP POLICY IF EXISTS "ventas_select_staff" ON ventas;
CREATE POLICY "ventas_select_staff" ON ventas FOR SELECT
  USING (fn_tiene_permiso('ventas.ver_todas')
         OR (fn_get_user_role() IS NOT NULL AND (vendedor_id = auth.uid() OR cobrada_por = auth.uid()))
         OR (estado = 'pendiente_cobro' AND fn_tiene_permiso('caja.cobrar')));


-- ──────────────────────────────────────────────
-- 3) Con qué quedó pagada una venta (la única fuente para caja y cuentas bancarias)
-- ──────────────────────────────────────────────
--   • No está cobrada (esperando cobro o anulada): nada.
--   • Tiene pagos cargados por la caja: esos.
--   • Venta anterior al 026 (sin pagos): un solo medio, el de la venta.
--   • Cuenta corriente: no es plata; la lleva su propio libro (019).
CREATE OR REPLACE FUNCTION fn_venta_pagado(p_venta_id BIGINT)
RETURNS TABLE (medio TEXT, cuenta BIGINT, monto NUMERIC, nro_operacion TEXT)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT vp.medio_pago, vp.cuenta_cobro_id, vp.monto, vp.nro_operacion
    FROM venta_pagos vp JOIN ventas v ON v.id = vp.venta_id
   WHERE v.id = p_venta_id AND v.estado = 'cerrada' AND vp.monto > 0
  UNION ALL
  SELECT v.medio_pago, v.cuenta_cobro_id, v.total, v.nro_operacion
    FROM ventas v
   WHERE v.id = p_venta_id AND v.estado = 'cerrada' AND v.total > 0
     AND v.medio_pago NOT IN ('cuenta_corriente', 'pendiente', 'mixto')
     AND NOT EXISTS (SELECT 1 FROM venta_pagos vp WHERE vp.venta_id = v.id)
$$;
REVOKE ALL ON FUNCTION fn_venta_pagado(BIGINT) FROM PUBLIC, anon, authenticated;

-- Si baja el total de una venta ya cobrada (se quitaron productos), los pagos
-- bajan hasta igualarlo: primero el efectivo, después el resto. Así la
-- devolución sale primero del cajón.
CREATE OR REPLACE FUNCTION fn_tr_ventas_ajustar_pagos()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_sobra NUMERIC(12,2);
  r       RECORD;
  v_baja  NUMERIC(12,2);
BEGIN
  IF NEW.estado <> 'cerrada' OR NEW.total >= OLD.total THEN RETURN NEW; END IF;
  SELECT coalesce(sum(monto), 0) - NEW.total INTO v_sobra FROM venta_pagos WHERE venta_id = NEW.id;
  IF v_sobra IS NULL OR v_sobra <= 0 THEN RETURN NEW; END IF;
  FOR r IN SELECT id, monto FROM venta_pagos WHERE venta_id = NEW.id AND monto > 0
           ORDER BY (medio_pago = 'efectivo') DESC, monto DESC, id LOOP
    EXIT WHEN v_sobra <= 0;
    v_baja := least(r.monto, v_sobra);
    UPDATE venta_pagos SET monto = monto - v_baja WHERE id = r.id;
    v_sobra := v_sobra - v_baja;
  END LOOP;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS tr_ventas_ajustar_pagos ON ventas;
CREATE TRIGGER tr_ventas_ajustar_pagos BEFORE UPDATE OF total ON ventas
  FOR EACH ROW EXECUTE FUNCTION fn_tr_ventas_ajustar_pagos();


-- ──────────────────────────────────────────────
-- 4) Caja: lo que la venta debería haber dejado, POR MEDIO, contra lo que dejó
-- ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_caja_sincronizar_venta(p_venta_id BIGINT)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v     ventas%ROWTYPE;
  r     RECORD;
  v_con caja_conceptos;
BEGIN
  SELECT * INTO v FROM ventas WHERE id = p_venta_id;
  IF NOT FOUND THEN RETURN; END IF;
  -- Una venta a la vez (dos anulaciones simultáneas no duplican la devolución)
  PERFORM pg_advisory_xact_lock(hashtext('caja_venta:' || p_venta_id));

  FOR r IN
    SELECT x.medio, sum(x.debe) - sum(x.tiene) AS dif
    FROM (
      SELECT p.medio, p.monto AS debe, 0::numeric AS tiene FROM fn_venta_pagado(p_venta_id) p
      UNION ALL
      SELECT m.medio_pago, 0, CASE m.tipo WHEN 'ingreso' THEN m.monto ELSE -m.monto END
      FROM caja_movimientos m WHERE m.venta_id = p_venta_id
    ) x
    GROUP BY x.medio
    HAVING sum(x.debe) - sum(x.tiene) <> 0
    ORDER BY x.medio
  LOOP
    v_con := fn_caja_concepto(CASE WHEN r.dif > 0 THEN 'venta' ELSE 'venta_devolucion' END);
    INSERT INTO caja_movimientos (sesion_id, tipo, concepto_id, concepto_nombre, monto, medio_pago,
                                  descripcion, origen, venta_id, usuario_id, usuario_nombre)
    VALUES (fn_caja_abierta_id(), CASE WHEN r.dif > 0 THEN 'ingreso' ELSE 'egreso' END,
            v_con.id, v_con.nombre, abs(r.dif), r.medio,
            CASE WHEN r.dif > 0 THEN 'Venta ' ELSE 'Devolución venta ' END || v.codigo
              || CASE WHEN v.estado = 'anulada' AND r.dif < 0 THEN ' (anulada)' ELSE '' END,
            CASE WHEN r.dif > 0 THEN 'venta' ELSE 'anulacion' END,
            v.id, coalesce(auth.uid(), v.cobrada_por, v.vendedor_id),
            coalesce(fn_mi_nombre(), v.cobrada_por_nombre, v.vendedor_nombre));
  END LOOP;
END;
$$;
REVOKE ALL ON FUNCTION fn_caja_sincronizar_venta(BIGINT) FROM PUBLIC, anon, authenticated;


-- ──────────────────────────────────────────────
-- 5) Cuentas bancarias: lo mismo, POR CUENTA
-- ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_cobros_sincronizar_venta(p_venta_id BIGINT)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v ventas%ROWTYPE;
  r RECORD;
BEGIN
  SELECT * INTO v FROM ventas WHERE id = p_venta_id;
  IF NOT FOUND THEN RETURN; END IF;
  PERFORM pg_advisory_xact_lock(hashtext('cobro_venta:' || p_venta_id));

  FOR r IN
    SELECT x.cuenta, sum(x.debe) - sum(x.tiene) AS dif, max(x.nro) AS nro
    FROM (
      SELECT p.cuenta, p.monto AS debe, 0::numeric AS tiene, p.nro_operacion AS nro
      FROM fn_venta_pagado(p_venta_id) p
      WHERE p.medio IN ('transferencia', 'mercadopago') AND p.cuenta IS NOT NULL
      UNION ALL
      SELECT mc.cuenta_cobro_id, 0, CASE WHEN mc.tipo = 'cobro' THEN mc.monto ELSE -mc.monto END, NULL
      FROM movimientos_cobro mc WHERE mc.venta_id = p_venta_id
    ) x
    GROUP BY x.cuenta
    HAVING sum(x.debe) - sum(x.tiene) <> 0
  LOOP
    INSERT INTO movimientos_cobro (cuenta_cobro_id, venta_id, tipo, monto, nro_operacion, detalle, usuario_id)
    VALUES (r.cuenta, v.id, CASE WHEN r.dif > 0 THEN 'cobro' ELSE 'anulacion' END, abs(r.dif),
            CASE WHEN r.dif > 0 THEN r.nro END,
            CASE WHEN r.dif > 0 THEN 'Venta en el local ' ELSE 'Devolución venta en el local ' END || v.codigo
              || CASE WHEN v.estado = 'anulada' AND r.dif < 0 THEN ' (anulada)' ELSE '' END,
            coalesce(auth.uid(), v.cobrada_por, v.vendedor_id));
  END LOOP;
END;
$$;
REVOKE ALL ON FUNCTION fn_cobros_sincronizar_venta(BIGINT) FROM PUBLIC, anon, authenticated;


-- ──────────────────────────────────────────────
-- 6) Funciones existentes: se cambia SOLO lo necesario (como en 016/020/025)
-- ──────────────────────────────────────────────
DO $migr$
DECLARE
  r     RECORD;
  v_def TEXT;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    -- venta_registrar: lo que no es cuenta corriente nace "esperando cobro", sin medio ni cuenta
    ('venta_registrar(jsonb)', $m$v_medio := 'pendiente'$m$,
     $a$  v_es_cc := v_medio = 'cuenta_corriente';$a$,
     $b$  v_es_cc := v_medio = 'cuenta_corriente';
  -- 026: todo lo que no es cuenta corriente se cobra en la caja
  IF NOT v_es_cc THEN v_medio := 'pendiente'; v_cuenta := NULL; END IF;$b$),
    ('venta_registrar(jsonb)', $m$estado = CASE WHEN v_es_cc$m$,
     $a$                    cuenta_cobro_id = v_cuenta,$a$,
     $b$                    cuenta_cobro_id = v_cuenta,
                    estado = CASE WHEN v_es_cc THEN 'cerrada' ELSE 'pendiente_cobro' END,$b$),
    ('venta_registrar(jsonb)', $m$'estado', CASE WHEN v_es_cc$m$,
     $a$'medio_pago', v_medio, 'items', v_out,$a$,
     $b$'medio_pago', v_medio, 'estado', CASE WHEN v_es_cc THEN 'cerrada' ELSE 'pendiente_cobro' END, 'items', v_out,$b$),
    -- venta_anular: la cajera puede cancelar una venta que espera cobro
    ('venta_anular(bigint,text)', $m$OR fn_tiene_permiso('caja.cobrar')) THEN$m$,
     $a$IF NOT (fn_tiene_permiso('ventas.anular_propias') OR fn_tiene_permiso('ventas.anular_todas')) THEN$a$,
     $b$IF NOT (fn_tiene_permiso('ventas.anular_propias') OR fn_tiene_permiso('ventas.anular_todas') OR fn_tiene_permiso('caja.cobrar')) THEN$b$),
    ('venta_anular(bigint,text)', $m$AND NOT (v_v.estado = 'pendiente_cobro'$m$,
     $a$IF NOT fn_tiene_permiso('ventas.anular_todas') AND ($a$,
     $b$IF NOT fn_tiene_permiso('ventas.anular_todas')
     AND NOT (v_v.estado = 'pendiente_cobro' AND fn_tiene_permiso('caja.cobrar'))
     AND ($b$),
    -- venta_quitar_items: también antes de cobrar (la vendedora corrige lo que devolvió la caja)
    ('venta_quitar_items(bigint,jsonb,text)', $m$NOT IN ('cerrada', 'pendiente_cobro')$m$,
     $a$IF v.estado <> 'cerrada' THEN$a$,
     $b$IF v.estado NOT IN ('cerrada', 'pendiente_cobro') THEN$b$),
    -- caja_cuenta_pedir: ahora la pide quien cobra
    ('caja_cuenta_pedir(numeric,bigint[])', $m$fn_tiene_permiso('caja.cobrar')$m$,
     $a$IF NOT fn_tiene_permiso('ventas.crear') THEN$a$,
     $b$IF NOT (fn_tiene_permiso('caja.cobrar') OR fn_tiene_permiso('ventas.crear')) THEN$b$)
  ) AS t(fn, marca, antes, despues)
  LOOP
    v_def := pg_get_functiondef(r.fn::regprocedure);
    IF position(r.marca IN v_def) > 0 THEN CONTINUE; END IF;            -- ya estaba
    IF position(r.antes IN v_def) = 0 THEN
      RAISE EXCEPTION '026: no encontré en % el punto esperado (%). Revisar esa función antes de seguir.', r.fn, left(r.antes, 60);
    END IF;
    EXECUTE replace(v_def, r.antes, r.despues);
  END LOOP;
END
$migr$;


-- ──────────────────────────────────────────────
-- 7) COBRAR en la caja (uno o varios medios)
-- ──────────────────────────────────────────────
-- p_pagos: [{ "medio": "efectivo", "monto": 30000 },
--           { "medio": "transferencia", "monto": 20000, "cuenta_cobro_id": 3, "nro_operacion": "123" }]
-- La suma tiene que dar exactamente el total. Sin cuenta_cobro_id en una
-- transferencia, la asigna el sistema (si hay cuentas activas).
CREATE OR REPLACE FUNCTION venta_cobrar(p_venta_id BIGINT, p_pagos JSONB)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v        ventas%ROWTYPE;
  v_p      JSONB;
  v_medio  TEXT;
  v_monto  NUMERIC(12,2);
  v_suma   NUMERIC(12,2) := 0;
  v_cta    BIGINT;
  v_n      INT := 0;
  v_medios TEXT[] := ARRAY[]::TEXT[];
  v_ctas   BIGINT[] := ARRAY[]::BIGINT[];
  v_quien  TEXT := fn_mi_nombre();
  v_avisos TEXT[] := ARRAY[]::TEXT[];
  v_aviso  TEXT;
  v_out    JSONB;
BEGIN
  IF NOT fn_tiene_permiso('caja.cobrar') THEN
    RAISE EXCEPTION 'sin_permiso' USING HINT = 'Tu usuario no puede cobrar ventas en la caja.';
  END IF;
  IF fn_caja_abierta_id() IS NULL THEN
    RAISE EXCEPTION 'caja_cerrada' USING HINT = 'Abrí la caja antes de cobrar.';
  END IF;
  IF p_pagos IS NULL OR jsonb_typeof(p_pagos) <> 'array' OR jsonb_array_length(p_pagos) = 0 OR jsonb_array_length(p_pagos) > 6 THEN
    RAISE EXCEPTION 'pagos_invalidos' USING HINT = 'Indicá cómo paga el cliente (hasta 6 medios).';
  END IF;

  SELECT * INTO v FROM ventas WHERE id = p_venta_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'venta_no_encontrada'; END IF;
  IF v.estado = 'cerrada' THEN
    RAISE EXCEPTION 'venta_ya_cobrada' USING HINT = format('La venta %s ya fue cobrada por %s.', v.codigo, coalesce(v.cobrada_por_nombre, 'otra persona'));
  ELSIF v.estado <> 'pendiente_cobro' THEN
    RAISE EXCEPTION 'venta_no_cobrable' USING HINT = format('La venta %s está %s: no se puede cobrar.', v.codigo, v.estado);
  END IF;
  IF v.total <= 0 THEN RAISE EXCEPTION 'venta_no_cobrable' USING HINT = 'La venta no tiene nada para cobrar.'; END IF;

  FOR v_p IN SELECT * FROM jsonb_array_elements(p_pagos) LOOP
    v_medio := v_p->>'medio';
    BEGIN v_monto := round((v_p->>'monto')::numeric, 2); EXCEPTION WHEN OTHERS THEN v_monto := NULL; END;
    IF v_medio IS NULL OR v_medio NOT IN ('efectivo','transferencia','debito','credito','mercadopago','otro') THEN
      RAISE EXCEPTION 'medio_invalido' USING HINT = 'Elegí un medio de pago válido en cada renglón.';
    END IF;
    IF v_monto IS NULL OR v_monto <= 0 THEN
      RAISE EXCEPTION 'monto_invalido' USING HINT = 'Cada medio de pago tiene que tener un monto mayor a cero.';
    END IF;
    v_cta := NULL;
    IF v_medio IN ('transferencia', 'mercadopago') THEN
      BEGIN v_cta := nullif(v_p->>'cuenta_cobro_id', '')::bigint; EXCEPTION WHEN OTHERS THEN v_cta := NULL; END;
      v_cta := fn_caja_resolver_cuenta(v_cta, v_monto);
      IF v_cta IS NOT NULL THEN v_ctas := v_ctas || v_cta; END IF;
    END IF;
    v_n := v_n + 1; v_suma := v_suma + v_monto;
    IF NOT (v_medio = ANY (v_medios)) THEN v_medios := v_medios || v_medio; END IF;
    INSERT INTO venta_pagos (venta_id, medio_pago, monto, monto_original, cuenta_cobro_id, nro_operacion, orden)
    VALUES (v.id, v_medio, v_monto, v_monto, v_cta,
            CASE WHEN v_cta IS NOT NULL THEN nullif(left(btrim(coalesce(v_p->>'nro_operacion', '')), 60), '') END, v_n);
  END LOOP;

  IF v_suma <> v.total THEN
    RAISE EXCEPTION 'pagos_no_suman'
      USING HINT = format('Los pagos suman %s y la venta es de %s.', to_char(v_suma, 'FM999G999G990D00'), to_char(v.total, 'FM999G999G990D00'));
  END IF;

  -- Al pasar a "cerrada", los disparadores asientan la caja (por medio) y las cuentas bancarias
  UPDATE ventas SET
    estado = 'cerrada',
    medio_pago = CASE WHEN cardinality(v_medios) = 1 THEN v_medios[1] ELSE 'mixto' END,
    cuenta_cobro_id = CASE WHEN cardinality(v_ctas) = 1 THEN v_ctas[1] END,
    cobrada_en = now(), cobrada_por = auth.uid(), cobrada_por_nombre = v_quien,
    devuelta_en = NULL, devuelta_motivo = NULL, devuelta_por_nombre = NULL
  WHERE id = v.id;

  FOREACH v_cta IN ARRAY v_ctas LOOP
    v_aviso := fn_cobros_aviso_limite(v_cta);
    IF v_aviso IS NOT NULL THEN v_avisos := v_avisos || v_aviso; END IF;
  END LOOP;

  INSERT INTO historial_actividad (accion, entidad, entidad_id, descripcion, usuario_id)
  VALUES ('cobrar', 'ventas', v.id::text,
          format('Cobró la venta %s: %s (%s)', v.codigo, to_char(v.total, 'FM999G999G990D00'), array_to_string(v_medios, ' + ')), auth.uid());

  SELECT to_jsonb(x) || jsonb_build_object(
           'ok', true,
           'items', (SELECT coalesce(jsonb_agg(to_jsonb(i) ORDER BY i.orden), '[]'::jsonb) FROM venta_items i WHERE i.venta_id = x.id),
           'pagos', (SELECT jsonb_agg(jsonb_build_object('medio', vp.medio_pago, 'monto', vp.monto, 'nro_operacion', vp.nro_operacion,
                                                         'cuenta', fn_cobros_cuenta_publica(vp.cuenta_cobro_id)) ORDER BY vp.orden)
                     FROM venta_pagos vp WHERE vp.venta_id = x.id),
           'cuenta_cobro', fn_cobros_cuenta_publica(x.cuenta_cobro_id),
           'avisos', to_jsonb(v_avisos))
    INTO v_out FROM ventas x WHERE x.id = v.id;
  RETURN v_out;
END;
$$;
REVOKE ALL ON FUNCTION venta_cobrar(BIGINT, JSONB) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION venta_cobrar(BIGINT, JSONB) TO authenticated;


-- ──────────────────────────────────────────────
-- 8) Devolver a la vendedora / volver a mandar a caja
-- ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION venta_devolver(p_venta_id BIGINT, p_motivo TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v     ventas%ROWTYPE;
  v_mot TEXT := nullif(btrim(coalesce(p_motivo, '')), '');
BEGIN
  IF NOT fn_tiene_permiso('caja.cobrar') THEN
    RAISE EXCEPTION 'sin_permiso' USING HINT = 'Tu usuario no puede devolver ventas desde la caja.';
  END IF;
  IF v_mot IS NULL THEN RAISE EXCEPTION 'motivo_requerido' USING HINT = 'Escribí qué tiene que corregir la vendedora.'; END IF;
  SELECT * INTO v FROM ventas WHERE id = p_venta_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'venta_no_encontrada'; END IF;
  IF v.estado <> 'pendiente_cobro' THEN
    RAISE EXCEPTION 'venta_no_cobrable' USING HINT = 'Solo se devuelven ventas que esperan cobro.';
  END IF;
  UPDATE ventas SET devuelta_en = now(), devuelta_motivo = left(v_mot, 300), devuelta_por_nombre = fn_mi_nombre() WHERE id = v.id;
  INSERT INTO historial_actividad (accion, entidad, entidad_id, descripcion, usuario_id)
  VALUES ('actualizar', 'ventas', v.id::text, format('La caja devolvió la venta %s: %s', v.codigo, left(v_mot, 120)), auth.uid());
  RETURN jsonb_build_object('ok', true, 'id', v.id);
END;
$$;

-- La vendedora (dueña de la venta) o quien cobra la vuelve a poner en la fila
CREATE OR REPLACE FUNCTION venta_reenviar_a_caja(p_venta_id BIGINT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v ventas%ROWTYPE;
BEGIN
  SELECT * INTO v FROM ventas WHERE id = p_venta_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'venta_no_encontrada'; END IF;
  IF NOT (fn_tiene_permiso('caja.cobrar') OR (fn_tiene_permiso('ventas.crear') AND v.vendedor_id = auth.uid())) THEN
    RAISE EXCEPTION 'sin_permiso' USING HINT = 'Solo quien hizo la venta puede volver a mandarla a caja.';
  END IF;
  IF v.estado <> 'pendiente_cobro' THEN
    RAISE EXCEPTION 'venta_no_cobrable' USING HINT = 'Esa venta ya no espera cobro.';
  END IF;
  UPDATE ventas SET devuelta_en = NULL, devuelta_motivo = NULL, devuelta_por_nombre = NULL WHERE id = v.id;
  RETURN jsonb_build_object('ok', true, 'id', v.id);
END;
$$;

REVOKE ALL ON FUNCTION venta_devolver(BIGINT, TEXT) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION venta_reenviar_a_caja(BIGINT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION venta_devolver(BIGINT, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION venta_reenviar_a_caja(BIGINT) TO authenticated;

NOTIFY pgrst, 'reload schema';

SELECT (SELECT count(*) FROM ventas WHERE estado = 'pendiente_cobro') AS esperando_cobro,
       pg_get_functiondef('venta_registrar(jsonb)'::regprocedure) LIKE '%pendiente_cobro%' AS ventas_van_a_caja;
