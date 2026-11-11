-- ============================================================
-- 019 — CUENTAS CORRIENTES DE CLIENTES (2026-11-11)
-- Ejecutar en Supabase → SQL Editor, DESPUÉS del 018.
-- Idempotente: se puede correr más de una vez sin romper nada.
--
-- Cómo funciona:
--   • Un cliente del CRM (crm_contactos) se HABILITA para cuenta
--     corriente con un día fijo de pago (1 a 28) y, si se quiere, un
--     límite de crédito. El cliente tiene UN saldo.
--   • Vender en cuenta corriente suma el total al saldo. Cada categoría
--     puede tener un RECARGO FIJO POR UNIDAD para estas ventas (ej.
--     celulares +$20.000 c/u): lo suma la base, no depende de la
--     vendedora. Queda a la vista en la venta y en el ticket.
--   • Vencimientos: lo comprado en un mes vence el día de pago del mes
--     siguiente. Los pagos cancelan primero lo más viejo. "Vencido" es
--     lo comprado antes del último vencimiento que todavía no se pagó.
--   • PAGOS: bajan el saldo, entran a la caja (como cualquier cobro: si
--     la caja está cerrada quedan pendientes) y tienen RECIBO numerado.
--   • Anular una venta en cuenta corriente baja la deuda sola.
--   • Nada se borra: los pagos se anulan (vuelve la deuda y sale el
--     egreso de caja) y las correcciones son ajustes con motivo.
--
-- Permisos nuevos (Admin → Permisos): cc.ver, cc.vender, cc.cobrar,
-- cc.gestionar, cc.ajustar, cc.recargos, cc.exceder_limite.
-- ============================================================


-- ──────────────────────────────────────────────
-- 1) Permisos (mismo mecanismo que el 016)
-- ──────────────────────────────────────────────
CREATE TEMP TABLE _permisos_019 (clave TEXT, modulo TEXT, nombre TEXT, descripcion TEXT, orden INT, roles TEXT[]) ON COMMIT DROP;
INSERT INTO _permisos_019 VALUES
  ('cc.ver',            'Cuentas corrientes', 'Ver cuentas corrientes y saldos',
     'Ver la lista de clientes con cuenta, sus saldos, vencimientos y movimientos.',          300, ARRAY['vendedor']),
  ('cc.vender',         'Cuentas corrientes', 'Vender en cuenta corriente',
     'Elegir "Cuenta corriente" como medio de pago al vender.',                               310, ARRAY['vendedor','encargado_stock']),
  ('cc.cobrar',         'Cuentas corrientes', 'Registrar pagos de clientes',
     'Cobrar a cuenta y entregar el recibo. El cobro entra a la caja.',                       320, ARRAY['vendedor']),
  ('cc.gestionar',      'Cuentas corrientes', 'Habilitar cuentas y cambiar límite y día de pago',
     'Abrir o suspender la cuenta de un cliente, su límite de crédito y su día de pago.',    330, ARRAY[]::TEXT[]),
  ('cc.ajustar',        'Cuentas corrientes', 'Ajustes de saldo y anular pagos',
     'Cargar saldos iniciales, corregir con ajustes y anular pagos mal cargados.',            340, ARRAY[]::TEXT[]),
  ('cc.recargos',       'Cuentas corrientes', 'Cambiar recargos por categoría',
     'Definir cuánto se suma por unidad al vender en cuenta corriente, por categoría.',       350, ARRAY[]::TEXT[]),
  ('cc.exceder_limite', 'Cuentas corrientes', 'Vender por encima del límite',
     'Permite una venta aunque el cliente supere su límite de crédito.',                     360, ARRAY[]::TEXT[]);

INSERT INTO permisos (clave, modulo, nombre, descripcion, orden)
SELECT clave, modulo, nombre, descripcion, orden FROM _permisos_019
ON CONFLICT (clave) DO UPDATE SET
  modulo = EXCLUDED.modulo, nombre = EXCLUDED.nombre,
  descripcion = EXCLUDED.descripcion, orden = EXCLUDED.orden;

INSERT INTO rol_permisos (rol, permiso)
SELECT unnest(n.roles), n.clave
FROM _permisos_019 n JOIN permisos p ON p.clave = n.clave
WHERE NOT p.iniciales_aplicados
ON CONFLICT DO NOTHING;

UPDATE permisos SET iniciales_aplicados = true
WHERE clave IN (SELECT clave FROM _permisos_019) AND NOT iniciales_aplicados;


-- ──────────────────────────────────────────────
-- 2) Recargo por categoría
-- ──────────────────────────────────────────────
ALTER TABLE categorias ADD COLUMN IF NOT EXISTS recargo_cc NUMERIC(12,2) NOT NULL DEFAULT 0;
ALTER TABLE categorias DROP CONSTRAINT IF EXISTS categorias_recargo_cc_valido;
ALTER TABLE categorias ADD CONSTRAINT categorias_recargo_cc_valido CHECK (recargo_cc >= 0 AND recargo_cc <= 100000000);

-- Quien edita categorías no puede tocar el recargo sin el permiso de recargos
CREATE OR REPLACE FUNCTION fn_categorias_proteger_recargo()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NEW.recargo_cc IS DISTINCT FROM (CASE WHEN TG_OP = 'INSERT' THEN 0 ELSE OLD.recargo_cc END)
     AND auth.uid() IS NOT NULL AND NOT fn_tiene_permiso('cc.recargos') THEN
    RAISE EXCEPTION 'sin_permiso' USING HINT = 'Tu usuario no puede cambiar los recargos de cuenta corriente.';
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS tr_categorias_proteger_recargo ON categorias;
CREATE TRIGGER tr_categorias_proteger_recargo BEFORE INSERT OR UPDATE OF recargo_cc ON categorias
  FOR EACH ROW EXECUTE FUNCTION fn_categorias_proteger_recargo();

CREATE OR REPLACE FUNCTION cc_recargo_guardar(p_categoria_id INT, p_monto NUMERIC)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_ant NUMERIC(12,2);
  v_nom TEXT;
  v_m   NUMERIC(12,2) := round(p_monto, 2);
BEGIN
  IF NOT fn_tiene_permiso('cc.recargos') THEN
    RAISE EXCEPTION 'sin_permiso' USING HINT = 'Tu usuario no puede cambiar los recargos de cuenta corriente.';
  END IF;
  IF v_m IS NULL OR v_m < 0 OR v_m > 100000000 THEN
    RAISE EXCEPTION 'monto_invalido' USING HINT = 'El recargo tiene que ser 0 o más.';
  END IF;
  SELECT recargo_cc, nombre INTO v_ant, v_nom FROM categorias WHERE id = p_categoria_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'categoria_no_encontrada'; END IF;
  IF v_ant = v_m THEN RETURN jsonb_build_object('ok', true, 'sin_cambios', true); END IF;
  UPDATE categorias SET recargo_cc = v_m WHERE id = p_categoria_id;
  INSERT INTO historial_actividad (usuario_id, accion, entidad, entidad_id, descripcion, valores_anteriores, valores_nuevos)
  VALUES (auth.uid(), 'actualizar', 'recargo_cc', p_categoria_id::text,
          format('Recargo de cuenta corriente de %s: %s → %s', v_nom, v_ant, v_m),
          jsonb_build_object('recargo_cc', v_ant), jsonb_build_object('recargo_cc', v_m));
  RETURN jsonb_build_object('ok', true, 'categoria_id', p_categoria_id, 'anterior', v_ant, 'recargo_cc', v_m);
END;
$$;


-- ──────────────────────────────────────────────
-- 3) Cuentas y movimientos
-- ──────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS cc_cuentas (
  id           BIGSERIAL PRIMARY KEY,
  contacto_id  BIGINT NOT NULL UNIQUE REFERENCES crm_contactos(id),
  habilitada   BOOLEAN NOT NULL DEFAULT true,          -- false = suspendida: no compra, sí paga
  limite       NUMERIC(12,2) CHECK (limite IS NULL OR limite > 0),   -- NULL = sin límite
  dia_pago     SMALLINT NOT NULL DEFAULT 10 CHECK (dia_pago BETWEEN 1 AND 28),
  saldo        NUMERIC(12,2) NOT NULL DEFAULT 0,       -- + debe, − a favor. Lo mueve solo fn_cc_asentar
  notas        TEXT CHECK (notas IS NULL OR length(notas) <= 500),
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_by   UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE SEQUENCE IF NOT EXISTS cc_recibo_seq;

CREATE TABLE IF NOT EXISTS cc_movimientos (
  id                 BIGSERIAL PRIMARY KEY,
  cuenta_id          BIGINT NOT NULL REFERENCES cc_cuentas(id),
  fecha              TIMESTAMPTZ NOT NULL DEFAULT now(),
  -- Suman deuda: cargo (venta), ajuste_debito, pago_anulado. Restan: pago, devolucion, ajuste_credito.
  tipo               TEXT NOT NULL CHECK (tipo IN ('cargo','pago','devolucion','ajuste_debito','ajuste_credito','pago_anulado')),
  monto              NUMERIC(12,2) NOT NULL CHECK (monto > 0),
  saldo_anterior     NUMERIC(12,2) NOT NULL,
  saldo_posterior    NUMERIC(12,2) NOT NULL,
  venta_id           BIGINT REFERENCES ventas(id),
  medio_pago         TEXT CHECK (medio_pago IS NULL OR medio_pago IN ('efectivo','transferencia','debito','credito','mercadopago','otro')),
  caja_movimiento_id BIGINT REFERENCES caja_movimientos(id),
  recibo_numero      TEXT UNIQUE,
  descripcion        TEXT CHECK (descripcion IS NULL OR length(descripcion) <= 300),
  usuario_id         UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  usuario_nombre     TEXT,
  anulado            BOOLEAN NOT NULL DEFAULT false,
  anulado_en         TIMESTAMPTZ,
  anulado_por        UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  motivo_anulacion   TEXT,
  revierte_a_id      BIGINT UNIQUE REFERENCES cc_movimientos(id),
  CHECK (saldo_posterior = saldo_anterior
         + CASE WHEN tipo IN ('cargo','ajuste_debito','pago_anulado') THEN monto ELSE -monto END)
);
CREATE INDEX IF NOT EXISTS idx_cc_mov_cuenta ON cc_movimientos (cuenta_id, fecha, id);
CREATE INDEX IF NOT EXISTS idx_cc_mov_venta  ON cc_movimientos (venta_id) WHERE venta_id IS NOT NULL;

-- Ventas: a qué cuenta, quién retira y cuánto fue de recargo
ALTER TABLE ventas      ADD COLUMN IF NOT EXISTS cc_cuenta_id  BIGINT REFERENCES cc_cuentas(id);
ALTER TABLE ventas      ADD COLUMN IF NOT EXISTS retira_nombre TEXT CHECK (retira_nombre IS NULL OR length(retira_nombre) <= 80);
ALTER TABLE ventas      ADD COLUMN IF NOT EXISTS recargo_total NUMERIC(12,2) NOT NULL DEFAULT 0;
ALTER TABLE venta_items ADD COLUMN IF NOT EXISTS recargo_unitario NUMERIC(12,2) NOT NULL DEFAULT 0;
CREATE INDEX IF NOT EXISTS idx_ventas_cc ON ventas (cc_cuenta_id) WHERE cc_cuenta_id IS NOT NULL;
ALTER TABLE ventas DROP CONSTRAINT IF EXISTS ventas_cc_con_cuenta;
ALTER TABLE ventas ADD CONSTRAINT ventas_cc_con_cuenta
  CHECK (medio_pago <> 'cuenta_corriente' OR cc_cuenta_id IS NOT NULL) NOT VALID;   -- las viejas sin cuenta quedan como estaban

-- Nada se edita ni se borra fuera de las funciones de este archivo
CREATE OR REPLACE FUNCTION fn_cc_inmutable()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF coalesce(current_setting('mh.cc', true), '') <> '1' THEN
    RAISE EXCEPTION 'cc_inmutable' USING HINT = 'Los movimientos y saldos de cuenta corriente no se modifican a mano: se ajustan o se anulan.';
  END IF;
  RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END;
$$;
DROP TRIGGER IF EXISTS tr_cc_mov_inmutable ON cc_movimientos;
CREATE TRIGGER tr_cc_mov_inmutable BEFORE UPDATE OR DELETE ON cc_movimientos
  FOR EACH ROW EXECUTE FUNCTION fn_cc_inmutable();
DROP TRIGGER IF EXISTS tr_cc_cuentas_saldo ON cc_cuentas;
CREATE TRIGGER tr_cc_cuentas_saldo BEFORE UPDATE OF saldo ON cc_cuentas
  FOR EACH ROW WHEN (NEW.saldo IS DISTINCT FROM OLD.saldo) EXECUTE FUNCTION fn_cc_inmutable();
DROP TRIGGER IF EXISTS tr_cc_cuentas_borrar ON cc_cuentas;
CREATE TRIGGER tr_cc_cuentas_borrar BEFORE DELETE ON cc_cuentas
  FOR EACH ROW EXECUTE FUNCTION fn_cc_inmutable();

-- Conceptos de caja para los cobros
INSERT INTO caja_conceptos (nombre, tipo, clave, orden) VALUES
  ('Cobro cuenta corriente',          'ingreso', 'cobro_cc',         1),
  ('Anulación cobro cuenta corriente','egreso',  'cobro_cc_anulado', 1)
ON CONFLICT (clave) DO NOTHING;


-- ──────────────────────────────────────────────
-- 4) Asentar un movimiento (ÚNICO lugar que cambia el saldo)
-- ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_cc_asentar(p_cuenta_id BIGINT, p_tipo TEXT, p_monto NUMERIC,
                                         p_descripcion TEXT DEFAULT NULL, p_venta_id BIGINT DEFAULT NULL,
                                         p_medio TEXT DEFAULT NULL, p_caja_mov BIGINT DEFAULT NULL,
                                         p_recibo TEXT DEFAULT NULL, p_revierte BIGINT DEFAULT NULL)
RETURNS cc_movimientos LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_ant  NUMERIC(12,2);
  v_pos  NUMERIC(12,2);
  v_m    NUMERIC(12,2) := round(p_monto, 2);
  v_row  cc_movimientos;
BEGIN
  SELECT saldo INTO v_ant FROM cc_cuentas WHERE id = p_cuenta_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'cuenta_no_encontrada'; END IF;
  v_pos := v_ant + CASE WHEN p_tipo IN ('cargo','ajuste_debito','pago_anulado') THEN v_m ELSE -v_m END;

  PERFORM set_config('mh.cc', '1', true);
  UPDATE cc_cuentas SET saldo = v_pos, updated_at = now() WHERE id = p_cuenta_id;
  PERFORM set_config('mh.cc', '', true);

  INSERT INTO cc_movimientos (cuenta_id, tipo, monto, saldo_anterior, saldo_posterior, venta_id, medio_pago,
                              caja_movimiento_id, recibo_numero, descripcion, usuario_id, usuario_nombre, revierte_a_id)
  VALUES (p_cuenta_id, p_tipo, v_m, v_ant, v_pos, p_venta_id, p_medio, p_caja_mov, p_recibo,
          left(p_descripcion, 300), auth.uid(), fn_mi_nombre(), p_revierte)
  RETURNING * INTO v_row;
  RETURN v_row;
END;
$$;
REVOKE ALL ON FUNCTION fn_cc_asentar(BIGINT, TEXT, NUMERIC, TEXT, BIGINT, TEXT, BIGINT, TEXT, BIGINT) FROM PUBLIC, anon, authenticated;


-- ──────────────────────────────────────────────
-- 5) Vencimientos
-- ──────────────────────────────────────────────
-- Día de pago d en el mes de una fecha (siempre existe: d ≤ 28)
CREATE OR REPLACE FUNCTION fn_cc_fecha_pago(p_mes DATE, p_dia INT)
RETURNS DATE LANGUAGE sql IMMUTABLE AS $$
  SELECT (date_trunc('month', p_mes)::date + (p_dia - 1))
$$;

-- Estado de una cuenta a una fecha (hoy por defecto, hora de Argentina).
--   vencido:            lo comprado antes del mes del último vencimiento pasado, menos todo lo pagado.
--   proximo_vencimiento: la próxima fecha de pago (hoy incluido) y cuánto hay que tener pagado ese día.
CREATE OR REPLACE FUNCTION fn_cc_estado(p_cuenta_id BIGINT, p_hoy DATE DEFAULT NULL)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_c        cc_cuentas%ROWTYPE;
  v_hoy      DATE := coalesce(p_hoy, (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date);
  v_ult      DATE;     -- último vencimiento ya pasado (< hoy)
  v_prox     DATE;     -- próximo vencimiento (>= hoy)
  v_creditos NUMERIC;
  v_deb_ult  NUMERIC;
  v_deb_prox NUMERIC;
BEGIN
  -- La usa la vista v_cc_cuentas (y por eso la puede llamar el panel): solo
  -- responde a quien trabaja con cuentas corrientes.
  IF auth.uid() IS NOT NULL
     AND NOT (fn_tiene_permiso('cc.ver') OR fn_tiene_permiso('cc.vender') OR fn_tiene_permiso('cc.cobrar')) THEN
    RETURN NULL;
  END IF;
  SELECT * INTO v_c FROM cc_cuentas WHERE id = p_cuenta_id;
  IF NOT FOUND THEN RETURN NULL; END IF;

  v_prox := fn_cc_fecha_pago(v_hoy, v_c.dia_pago);
  IF v_prox < v_hoy THEN v_prox := fn_cc_fecha_pago((v_hoy + interval '1 month')::date, v_c.dia_pago); END IF;
  v_ult := fn_cc_fecha_pago((v_prox - interval '1 month')::date, v_c.dia_pago);

  SELECT coalesce(sum(monto) FILTER (WHERE tipo IN ('pago','devolucion','ajuste_credito')), 0)
       - coalesce(sum(monto) FILTER (WHERE tipo = 'pago_anulado'), 0),
         coalesce(sum(monto) FILTER (WHERE tipo IN ('cargo','ajuste_debito')
                                       AND (fecha AT TIME ZONE 'America/Argentina/Buenos_Aires')::date < date_trunc('month', v_ult)::date), 0),
         coalesce(sum(monto) FILTER (WHERE tipo IN ('cargo','ajuste_debito')
                                       AND (fecha AT TIME ZONE 'America/Argentina/Buenos_Aires')::date < date_trunc('month', v_prox)::date), 0)
    INTO v_creditos, v_deb_ult, v_deb_prox
  FROM cc_movimientos WHERE cuenta_id = p_cuenta_id;

  RETURN jsonb_build_object(
    'saldo', v_c.saldo,
    'vencido', greatest(0, least(v_c.saldo, v_deb_ult - v_creditos)),
    'ultimo_vencimiento', v_ult,
    'proximo_vencimiento', v_prox,
    'a_pagar_proximo', greatest(0, least(v_c.saldo, v_deb_prox - v_creditos)),
    'disponible', CASE WHEN v_c.limite IS NULL THEN NULL ELSE v_c.limite - v_c.saldo END);
END;
$$;
REVOKE ALL ON FUNCTION fn_cc_estado(BIGINT, DATE) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION fn_cc_estado(BIGINT, DATE) TO authenticated;


-- ──────────────────────────────────────────────
-- 6) Lista para el panel (con nombre del cliente y vencimientos)
-- ──────────────────────────────────────────────
-- Vista con los permisos de su dueño: el filtro por permiso va adentro.
CREATE OR REPLACE VIEW v_cc_cuentas AS
SELECT c.id, c.contacto_id, k.nombre, k.telefono, k.cuit, k.localidad,
       c.habilitada, c.limite, c.dia_pago, c.saldo, c.notas, c.created_at,
       (e->>'vencido')::numeric             AS vencido,
       (e->>'proximo_vencimiento')::date    AS proximo_vencimiento,
       (e->>'a_pagar_proximo')::numeric     AS a_pagar_proximo,
       (e->>'disponible')::numeric          AS disponible,
       (SELECT max(m.fecha) FROM cc_movimientos m WHERE m.cuenta_id = c.id AND m.tipo = 'pago' AND NOT m.anulado) AS ultimo_pago
FROM cc_cuentas c
JOIN crm_contactos k ON k.id = c.contacto_id
CROSS JOIN LATERAL fn_cc_estado(c.id) e
WHERE fn_tiene_permiso('cc.ver');

REVOKE ALL ON v_cc_cuentas FROM PUBLIC, anon;
GRANT SELECT ON v_cc_cuentas TO authenticated;


-- ──────────────────────────────────────────────
-- 7) Alta y edición de cuentas
-- ──────────────────────────────────────────────
-- p: { contacto_id } o { contacto: { nombre*, telefono, cuit, localidad } }
--    + habilitada, limite (null/0 = sin límite), dia_pago, notas
--    Para editar: { cuenta_id, ...lo que cambia }
CREATE OR REPLACE FUNCTION cc_cuenta_guardar(p JSONB)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_id       BIGINT := nullif(p->>'cuenta_id', '')::bigint;
  v_cont     BIGINT := nullif(p->>'contacto_id', '')::bigint;
  v_k        JSONB := p->'contacto';
  v_lim      NUMERIC(12,2);
  v_dia      INT;
  v_ant      cc_cuentas%ROWTYPE;
  v_nuevo    BOOLEAN := false;
BEGIN
  IF NOT fn_tiene_permiso('cc.gestionar') THEN
    RAISE EXCEPTION 'sin_permiso' USING HINT = 'Tu usuario no puede abrir ni modificar cuentas corrientes.';
  END IF;
  IF p ? 'limite' THEN
    v_lim := nullif(round(coalesce(nullif(p->>'limite', '')::numeric, 0), 2), 0);
    IF v_lim < 0 THEN RAISE EXCEPTION 'limite_invalido' USING HINT = 'El límite tiene que ser mayor a cero (o vacío = sin límite).'; END IF;
  END IF;
  IF p ? 'dia_pago' THEN
    v_dia := (p->>'dia_pago')::int;
    IF v_dia IS NULL OR v_dia NOT BETWEEN 1 AND 28 THEN
      RAISE EXCEPTION 'dia_invalido' USING HINT = 'El día de pago tiene que ser del 1 al 28.';
    END IF;
  END IF;

  IF v_id IS NULL THEN
    -- Cliente nuevo en el CRM, o uno que ya existe
    IF v_cont IS NULL THEN
      IF v_k IS NULL OR length(btrim(coalesce(v_k->>'nombre', ''))) < 2 THEN
        RAISE EXCEPTION 'cliente_requerido' USING HINT = 'Elegí un cliente o escribí su nombre.';
      END IF;
      SELECT id INTO v_cont FROM crm_contactos
      WHERE NOT archivado AND telefono_clave IS NOT NULL AND telefono_clave = fn_crm_tel_clave(v_k->>'telefono') LIMIT 1;
      IF v_cont IS NULL THEN
        INSERT INTO crm_contactos (nombre, telefono, cuit, localidad, canal_origen, notas)
        VALUES (left(btrim(v_k->>'nombre'), 120), nullif(left(btrim(coalesce(v_k->>'telefono', '')), 40), ''),
                nullif(left(btrim(coalesce(v_k->>'cuit', '')), 15), ''), nullif(left(btrim(coalesce(v_k->>'localidad', '')), 80), ''),
                'mostrador', 'Alta desde cuentas corrientes')
        RETURNING id INTO v_cont;
      END IF;
    ELSIF NOT EXISTS (SELECT 1 FROM crm_contactos WHERE id = v_cont AND NOT archivado) THEN
      RAISE EXCEPTION 'cliente_no_encontrado';
    END IF;
    SELECT id INTO v_id FROM cc_cuentas WHERE contacto_id = v_cont;
    IF v_id IS NOT NULL THEN
      RAISE EXCEPTION 'cuenta_existente' USING HINT = 'Ese cliente ya tiene cuenta corriente.';
    END IF;
    INSERT INTO cc_cuentas (contacto_id, habilitada, limite, dia_pago, notas, created_by)
    VALUES (v_cont, coalesce((p->>'habilitada')::boolean, true), v_lim, coalesce(v_dia, 10),
            nullif(left(btrim(coalesce(p->>'notas', '')), 500), ''), auth.uid())
    RETURNING id INTO v_id;
    v_nuevo := true;
  ELSE
    SELECT * INTO v_ant FROM cc_cuentas WHERE id = v_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'cuenta_no_encontrada'; END IF;
    UPDATE cc_cuentas SET
      habilitada = CASE WHEN p ? 'habilitada' THEN (p->>'habilitada')::boolean ELSE habilitada END,
      limite     = CASE WHEN p ? 'limite' THEN v_lim ELSE limite END,
      dia_pago   = coalesce(v_dia, dia_pago),
      notas      = CASE WHEN p ? 'notas' THEN nullif(left(btrim(coalesce(p->>'notas', '')), 500), '') ELSE notas END,
      updated_at = now()
    WHERE id = v_id;
  END IF;

  INSERT INTO historial_actividad (usuario_id, accion, entidad, entidad_id, descripcion, valores_anteriores, valores_nuevos)
  SELECT auth.uid(), CASE WHEN v_nuevo THEN 'crear' ELSE 'actualizar' END, 'cuenta_corriente', v_id::text,
         CASE WHEN v_nuevo THEN 'Abrió cuenta corriente' ELSE 'Modificó cuenta corriente' END,
         CASE WHEN v_nuevo THEN NULL ELSE jsonb_build_object('habilitada', v_ant.habilitada, 'limite', v_ant.limite, 'dia_pago', v_ant.dia_pago) END,
         jsonb_build_object('habilitada', c.habilitada, 'limite', c.limite, 'dia_pago', c.dia_pago)
  FROM cc_cuentas c WHERE c.id = v_id;

  RETURN jsonb_build_object('ok', true, 'cuenta_id', v_id, 'contacto_id', v_cont, 'nueva', v_nuevo);
END;
$$;


-- ──────────────────────────────────────────────
-- 8) Buscar un cliente para venderle (Crear venta)
-- ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION cc_buscar(p_q TEXT)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_q   TEXT := lower(btrim(coalesce(p_q, '')));
  v_tel TEXT := fn_crm_tel_clave(p_q);
BEGIN
  IF NOT (fn_tiene_permiso('cc.vender') OR fn_tiene_permiso('cc.cobrar') OR fn_tiene_permiso('cc.ver')) THEN
    RAISE EXCEPTION 'sin_permiso' USING HINT = 'Tu usuario no puede usar cuentas corrientes.';
  END IF;
  RETURN coalesce((
    SELECT jsonb_agg(x ORDER BY x->>'nombre') FROM (
      SELECT jsonb_build_object(
               'id', c.id, 'nombre', k.nombre, 'telefono', k.telefono, 'cuit', k.cuit,
               'habilitada', c.habilitada, 'limite', c.limite, 'dia_pago', c.dia_pago) || fn_cc_estado(c.id) AS x
      FROM cc_cuentas c JOIN crm_contactos k ON k.id = c.contacto_id
      WHERE v_q = ''
         OR lower(k.nombre) LIKE '%' || v_q || '%'
         OR (v_tel IS NOT NULL AND k.telefono_clave LIKE '%' || v_tel || '%')
         OR replace(coalesce(k.cuit, ''), '-', '') LIKE '%' || replace(v_q, '-', '') || '%'
      ORDER BY k.nombre LIMIT 20) s), '[]'::jsonb);
END;
$$;


-- ──────────────────────────────────────────────
-- 9) Las ventas en cuenta corriente mueven el saldo solas
-- ──────────────────────────────────────────────
-- Igual que la caja: lo que la venta debería haber cargado (total si está
-- cerrada y es cuenta corriente; 0 si se anuló) contra lo que ya cargó.
CREATE OR REPLACE FUNCTION fn_cc_sincronizar_venta(p_venta_id BIGINT)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v       ventas%ROWTYPE;
  v_debe  NUMERIC(12,2);
  v_tiene NUMERIC(12,2);
  v_dif   NUMERIC(12,2);
  v_cta   BIGINT;
BEGIN
  SELECT * INTO v FROM ventas WHERE id = p_venta_id;
  IF NOT FOUND THEN RETURN; END IF;
  PERFORM pg_advisory_xact_lock(hashtext('cc_venta:' || p_venta_id));

  SELECT coalesce(sum(CASE WHEN tipo = 'cargo' THEN monto ELSE -monto END), 0), max(cuenta_id)
    INTO v_tiene, v_cta
  FROM cc_movimientos WHERE venta_id = p_venta_id AND tipo IN ('cargo', 'devolucion');
  v_cta  := coalesce(v.cc_cuenta_id, v_cta);
  IF v_cta IS NULL THEN RETURN; END IF;
  v_debe := CASE WHEN v.estado = 'cerrada' AND v.medio_pago = 'cuenta_corriente' THEN v.total ELSE 0 END;
  v_dif  := v_debe - v_tiene;
  IF v_dif = 0 THEN RETURN; END IF;

  PERFORM fn_cc_asentar(v_cta, CASE WHEN v_dif > 0 THEN 'cargo' ELSE 'devolucion' END, abs(v_dif),
                        CASE WHEN v_dif > 0 THEN 'Compra ' ELSE 'Devolución compra ' END || v.codigo
                          || CASE WHEN v.estado = 'anulada' AND v_dif < 0 THEN ' (anulada)' ELSE '' END,
                        v.id);
END;
$$;
REVOKE ALL ON FUNCTION fn_cc_sincronizar_venta(BIGINT) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION fn_tr_ventas_cc()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NEW.medio_pago = 'cuenta_corriente' OR NEW.cc_cuenta_id IS NOT NULL THEN
    PERFORM fn_cc_sincronizar_venta(NEW.id);
  END IF;
  RETURN NULL;
END;
$$;
DROP TRIGGER IF EXISTS tr_ventas_cc ON ventas;
CREATE TRIGGER tr_ventas_cc AFTER UPDATE OF total, estado, medio_pago ON ventas
  FOR EACH ROW EXECUTE FUNCTION fn_tr_ventas_cc();


-- ──────────────────────────────────────────────
-- 10) Registrar una venta (reemplaza la del 013/016)
-- ──────────────────────────────────────────────
-- p: { items: [{ producto_id | nombre, cantidad, precio_unitario }],
--      medio_pago, cuenta_cobro_id, cliente_nombre, cliente_telefono, retira_nombre,
--      cc_cuenta_id (obligatorio si medio_pago = 'cuenta_corriente'),
--      descuento, notas, permitir_negativo (default true) }
-- En cuenta corriente, precio_unitario es el precio de lista: la base le
-- suma el recargo de la categoría de cada producto.
CREATE OR REPLACE FUNCTION venta_registrar(p JSONB)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_items    JSONB := coalesce(p->'items', '[]'::jsonb);
  v_item     JSONB;
  v_prod     productos%ROWTYPE;
  v_pid      INT;
  v_cant     INT;
  v_precio   NUMERIC(12,2);
  v_recargo  NUMERIC(12,2);
  v_rec_tot  NUMERIC(12,2) := 0;
  v_nombre   TEXT;
  v_sku      TEXT;
  v_sub      NUMERIC(12,2);
  v_subtotal NUMERIC(12,2) := 0;
  v_desc     NUMERIC(12,2) := 0;
  v_total    NUMERIC(12,2);
  v_n        INT := 0;
  v_unid     INT := 0;
  v_afect    INT := 0;
  v_venta_id BIGINT;
  v_codigo   TEXT;
  v_medio    TEXT := coalesce(p->>'medio_pago', 'efectivo');
  v_cuenta   BIGINT;
  v_neg_ok   BOOLEAN := coalesce((p->>'permitir_negativo')::boolean, true);
  v_mov      movimientos_inventario;
  v_afecta   BOOLEAN;
  v_out      JSONB := '[]'::jsonb;
  v_avisos   JSONB := '[]'::jsonb;
  v_vend     TEXT;
  v_i        INT := 0;
  v_es_cc    BOOLEAN;
  v_cc       cc_cuentas%ROWTYPE;
  v_cliente  TEXT;
  v_tel      TEXT;
  v_cc_out   JSONB;
BEGIN
  IF NOT fn_tiene_permiso('ventas.crear') THEN
    RAISE EXCEPTION 'sin_permiso' USING HINT = 'Tu usuario no puede registrar ventas.';
  END IF;
  IF jsonb_typeof(v_items) <> 'array' OR jsonb_array_length(v_items) = 0 THEN
    RAISE EXCEPTION 'venta_vacia' USING HINT = 'Agregá al menos un producto.';
  END IF;
  IF jsonb_array_length(v_items) > 100 THEN
    RAISE EXCEPTION 'items_invalidos' USING HINT = 'Demasiados ítems en una sola venta.';
  END IF;
  IF v_medio NOT IN ('efectivo','transferencia','debito','credito','mercadopago','cuenta_corriente','otro') THEN
    RAISE EXCEPTION 'medio_pago_invalido';
  END IF;
  BEGIN v_cuenta := nullif(p->>'cuenta_cobro_id','')::bigint; EXCEPTION WHEN OTHERS THEN v_cuenta := NULL; END;
  IF v_cuenta IS NOT NULL AND NOT EXISTS (SELECT 1 FROM cuentas_cobro WHERE id = v_cuenta) THEN v_cuenta := NULL; END IF;
  BEGIN v_desc := greatest(coalesce(nullif(p->>'descuento','')::numeric, 0), 0); EXCEPTION WHEN OTHERS THEN v_desc := 0; END;

  v_cliente := nullif(left(btrim(coalesce(p->>'cliente_nombre','')), 80), '');
  v_tel     := nullif(left(regexp_replace(coalesce(p->>'cliente_telefono',''), '[^0-9+ ()\-]', '', 'g'), 25), '');

  -- Cuenta corriente: cliente habilitado; el nombre y teléfono salen de su ficha
  v_es_cc := v_medio = 'cuenta_corriente';
  IF v_es_cc THEN
    IF NOT fn_tiene_permiso('cc.vender') THEN
      RAISE EXCEPTION 'sin_permiso' USING HINT = 'Tu usuario no puede vender en cuenta corriente.';
    END IF;
    SELECT * INTO v_cc FROM cc_cuentas WHERE id = nullif(p->>'cc_cuenta_id', '')::bigint FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'cuenta_requerida' USING HINT = 'Elegí el cliente de cuenta corriente.';
    END IF;
    IF NOT v_cc.habilitada THEN
      RAISE EXCEPTION 'cuenta_suspendida' USING HINT = 'La cuenta corriente de este cliente está suspendida: puede pagar, no comprar.';
    END IF;
    SELECT left(nombre, 80), left(telefono, 25) INTO v_cliente, v_tel FROM crm_contactos WHERE id = v_cc.contacto_id;
  END IF;

  SELECT nombre INTO v_vend FROM profiles WHERE id = auth.uid();
  v_codigo := 'VL-' || to_char(now(), 'YYMMDD') || '-' ||
              upper(substr(md5(random()::text || clock_timestamp()::text), 1, 4));

  INSERT INTO ventas (codigo, vendedor_id, vendedor_nombre, cliente_nombre, cliente_telefono,
                      medio_pago, cuenta_cobro_id, notas, cc_cuenta_id, retira_nombre)
  VALUES (v_codigo, auth.uid(), v_vend, v_cliente, v_tel,
          v_medio, v_cuenta, nullif(left(btrim(coalesce(p->>'notas','')), 400), ''),
          CASE WHEN v_es_cc THEN v_cc.id END,
          nullif(left(btrim(coalesce(p->>'retira_nombre','')), 80), ''))
  RETURNING id INTO v_venta_id;

  -- La vía interna deja que fn_registrar_movimiento acepte negativo
  -- (la venta ya pasó en el mostrador; el sistema registra la realidad).
  PERFORM set_config('mh.interno', '1', true);

  FOR v_item IN SELECT * FROM jsonb_array_elements(v_items) LOOP
    v_i := v_i + 1;
    BEGIN
      v_pid  := nullif(v_item->>'producto_id','')::int;
      v_cant := (v_item->>'cantidad')::int;
      v_precio := nullif(v_item->>'precio_unitario','')::numeric;
    EXCEPTION WHEN OTHERS THEN
      RAISE EXCEPTION 'items_invalidos' USING HINT = format('Ítem %s: datos inválidos.', v_i);
    END;
    IF v_cant IS NULL OR v_cant < 1 OR v_cant > 9999 THEN
      RAISE EXCEPTION 'cantidad_invalida' USING HINT = format('Ítem %s: la cantidad tiene que ser 1 o más.', v_i);
    END IF;

    v_afecta := false; v_mov := NULL; v_recargo := 0;
    IF v_pid IS NOT NULL THEN
      SELECT * INTO v_prod FROM productos WHERE id = v_pid FOR UPDATE;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'producto_no_encontrado' USING HINT = format('Ítem %s: el producto ya no existe.', v_i);
      END IF;
      IF v_prod.estado = 'archivado' THEN
        RAISE EXCEPTION 'producto_archivado' USING HINT = format('%s está archivado: no se puede vender.', v_prod.nombre);
      END IF;
      v_nombre := v_prod.nombre; v_sku := v_prod.sku;
      IF v_precio IS NULL THEN v_precio := fn_precio_venta(v_prod); END IF;
      IF v_precio IS NULL THEN
        RAISE EXCEPTION 'precio_requerido'
          USING DETAIL = jsonb_build_object('producto_id', v_pid, 'nombre', v_prod.nombre)::text,
                HINT = format('%s no tiene precio cargado: indicá el precio en la venta.', v_prod.nombre);
      END IF;
      IF v_es_cc THEN
        SELECT coalesce(recargo_cc, 0) INTO v_recargo FROM categorias WHERE id = v_prod.categoria_id;
        v_recargo := coalesce(v_recargo, 0);
      END IF;

      IF v_prod.stock_controlado AND v_prod.seguimiento_inventario THEN
        IF v_prod.stock_actual - v_cant < 0 AND NOT v_neg_ok THEN
          RAISE EXCEPTION 'stock_insuficiente'
            USING DETAIL = jsonb_build_object('producto_id', v_pid, 'nombre', v_prod.nombre,
                                              'pedido', v_cant, 'disponible', v_prod.stock_actual)::text,
                  HINT = format('%s: hay %s y se quieren vender %s.', v_prod.nombre, v_prod.stock_actual, v_cant);
        END IF;
        v_mov := fn_registrar_movimiento(v_pid, 'salida_venta', v_cant, 'Venta en el local', NULL, v_codigo, true);
        v_afecta := true; v_afect := v_afect + 1;
        IF v_mov.stock_posterior < 0 THEN
          v_avisos := v_avisos || jsonb_build_object('producto_id', v_pid, 'nombre', v_prod.nombre,
                                                     'stock', v_mov.stock_posterior,
                                                     'detalle', 'El stock quedó en negativo: revisar conteo');
        END IF;
      END IF;
    ELSE
      v_nombre := left(btrim(regexp_replace(coalesce(v_item->>'nombre',''), '\s+', ' ', 'g')), 120);
      v_sku := NULL;
      IF length(v_nombre) < 2 THEN
        RAISE EXCEPTION 'items_invalidos' USING HINT = format('Ítem %s: escribí qué se vendió.', v_i);
      END IF;
      IF v_precio IS NULL THEN
        RAISE EXCEPTION 'precio_requerido' USING HINT = format('%s: indicá el precio.', v_nombre);
      END IF;
    END IF;

    IF v_precio < 0 THEN
      RAISE EXCEPTION 'precio_invalido' USING HINT = format('Ítem %s: el precio no puede ser negativo.', v_i);
    END IF;
    v_precio := v_precio + v_recargo;
    v_sub := round(v_precio * v_cant, 2);
    v_subtotal := v_subtotal + v_sub;
    v_rec_tot := v_rec_tot + v_recargo * v_cant;
    v_n := v_n + 1; v_unid := v_unid + v_cant;

    INSERT INTO venta_items (venta_id, producto_id, nombre, sku, cantidad, precio_unitario, subtotal,
                             afecto_stock, movimiento_id, stock_posterior, orden, recargo_unitario)
    VALUES (v_venta_id, v_pid, v_nombre, v_sku, v_cant, v_precio, v_sub,
            v_afecta, v_mov.id, v_mov.stock_posterior, v_i, v_recargo);

    v_out := v_out || jsonb_build_object('producto_id', v_pid, 'nombre', v_nombre, 'sku', v_sku,
                                         'cantidad', v_cant, 'precio_unitario', v_precio, 'subtotal', v_sub,
                                         'recargo_unitario', v_recargo,
                                         'afecto_stock', v_afecta, 'stock_posterior', v_mov.stock_posterior);
  END LOOP;

  IF v_desc > v_subtotal THEN
    RAISE EXCEPTION 'descuento_invalido' USING HINT = 'El descuento no puede superar el subtotal.';
  END IF;
  v_total := round(v_subtotal - v_desc, 2);

  -- Límite de crédito
  IF v_es_cc AND v_cc.limite IS NOT NULL AND v_cc.saldo + v_total > v_cc.limite
     AND NOT fn_tiene_permiso('cc.exceder_limite') THEN
    RAISE EXCEPTION 'limite_superado'
      USING HINT = format('Con esta compra el cliente debería %s y su límite es %s (disponible %s).',
                          to_char(v_cc.saldo + v_total, 'FM999G999G990D00'), to_char(v_cc.limite, 'FM999G999G990D00'),
                          to_char(greatest(v_cc.limite - v_cc.saldo, 0), 'FM999G999G990D00'));
  END IF;

  -- Al fijar el total, los disparadores asientan la caja (018) y la cuenta corriente (019)
  UPDATE ventas SET subtotal = v_subtotal, descuento = v_desc, total = v_total,
                    items_count = v_n, unidades = v_unid, stock_afectado = v_afect, recargo_total = v_rec_tot
   WHERE id = v_venta_id;

  IF v_es_cc THEN
    SELECT jsonb_build_object('cuenta_id', c.id, 'saldo_anterior', c.saldo - v_total, 'saldo_actual', c.saldo,
                              'recargo_total', v_rec_tot) || fn_cc_estado(c.id)
      INTO v_cc_out FROM cc_cuentas c WHERE c.id = v_cc.id;
  END IF;

  INSERT INTO historial_actividad (accion, entidad, entidad_id, descripcion, usuario_id)
  VALUES ('venta', 'ventas', v_venta_id::text,
          format('Venta %s: %s ítem(s), total %s (%s)', v_codigo, v_n, to_char(v_total, 'FM999G999G999D00'), v_medio),
          auth.uid());

  RETURN jsonb_build_object('ok', true, 'id', v_venta_id, 'codigo', v_codigo, 'fecha', now(),
                            'subtotal', v_subtotal, 'descuento', v_desc, 'total', v_total,
                            'medio_pago', v_medio, 'items', v_out, 'stock_afectado', v_afect,
                            'advertencias', v_avisos, 'vendedor', v_vend,
                            'cliente_nombre', v_cliente, 'retira_nombre', nullif(btrim(coalesce(p->>'retira_nombre','')), ''),
                            'recargo_total', v_rec_tot, 'cuenta_corriente', v_cc_out);
END;
$$;
REVOKE ALL ON FUNCTION venta_registrar(JSONB) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION venta_registrar(JSONB) TO authenticated;


-- ──────────────────────────────────────────────
-- 11) Pagos (con recibo; entran a la caja)
-- ──────────────────────────────────────────────
-- p: { cuenta_id, monto, medio_pago (no cuenta_corriente), descripcion }
CREATE OR REPLACE FUNCTION cc_pago_registrar(p JSONB)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_cta    cc_cuentas%ROWTYPE;
  v_monto  NUMERIC(12,2);
  v_medio  TEXT := coalesce(nullif(p->>'medio_pago', ''), 'efectivo');
  v_desc   TEXT := nullif(btrim(coalesce(p->>'descripcion', '')), '');
  v_con    caja_conceptos;
  v_caja   BIGINT;
  v_recibo TEXT;
  v_mov    cc_movimientos;
  v_cli    crm_contactos%ROWTYPE;
BEGIN
  IF NOT fn_tiene_permiso('cc.cobrar') THEN
    RAISE EXCEPTION 'sin_permiso' USING HINT = 'Tu usuario no puede registrar pagos de cuenta corriente.';
  END IF;
  BEGIN v_monto := round((p->>'monto')::numeric, 2); EXCEPTION WHEN OTHERS THEN v_monto := NULL; END;
  IF v_monto IS NULL OR v_monto <= 0 OR v_monto > 100000000 THEN
    RAISE EXCEPTION 'monto_invalido' USING HINT = 'El pago tiene que ser mayor a cero.';
  END IF;
  IF v_medio NOT IN ('efectivo','transferencia','debito','credito','mercadopago','otro') THEN
    RAISE EXCEPTION 'medio_invalido' USING HINT = 'Elegí cómo pagó (efectivo, transferencia, tarjeta…).';
  END IF;
  SELECT * INTO v_cta FROM cc_cuentas WHERE id = (p->>'cuenta_id')::bigint FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'cuenta_no_encontrada'; END IF;
  SELECT * INTO v_cli FROM crm_contactos WHERE id = v_cta.contacto_id;

  v_recibo := 'R-' || lpad(nextval('cc_recibo_seq')::text, 6, '0');

  -- Entra a la caja abierta (o queda pendiente, como una venta)
  v_con := fn_caja_concepto('cobro_cc');
  INSERT INTO caja_movimientos (sesion_id, tipo, concepto_id, concepto_nombre, monto, medio_pago,
                                descripcion, origen, usuario_id, usuario_nombre)
  VALUES (fn_caja_abierta_id(), 'ingreso', v_con.id, v_con.nombre, v_monto, v_medio,
          left(format('Recibo %s · %s', v_recibo, v_cli.nombre), 300), 'cobro_cc', auth.uid(), fn_mi_nombre())
  RETURNING id INTO v_caja;

  v_mov := fn_cc_asentar(v_cta.id, 'pago', v_monto, coalesce(v_desc, 'Pago a cuenta'), NULL, v_medio, v_caja, v_recibo);

  RETURN jsonb_build_object('ok', true, 'id', v_mov.id, 'recibo', jsonb_build_object(
    'numero', v_recibo, 'fecha', v_mov.fecha, 'cliente_nombre', v_cli.nombre, 'cliente_doc', v_cli.cuit,
    'concepto', coalesce(v_desc, 'Pago a cuenta corriente'), 'monto', v_monto, 'medio_pago', v_medio,
    'saldo_anterior', v_mov.saldo_anterior, 'saldo_actual', v_mov.saldo_posterior, 'usuario', v_mov.usuario_nombre),
    'caja_abierta', fn_caja_abierta_id() IS NOT NULL);
END;
$$;

-- Anular un pago mal cargado: vuelve la deuda y sale el egreso de caja
CREATE OR REPLACE FUNCTION cc_pago_anular(p_id BIGINT, p_motivo TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_m    cc_movimientos%ROWTYPE;
  v_mot  TEXT := nullif(btrim(coalesce(p_motivo, '')), '');
  v_con  caja_conceptos;
  v_caja BIGINT;
  v_inv  cc_movimientos;
BEGIN
  IF NOT fn_tiene_permiso('cc.ajustar') THEN
    RAISE EXCEPTION 'sin_permiso' USING HINT = 'Tu usuario no puede anular pagos de cuenta corriente.';
  END IF;
  IF v_mot IS NULL THEN RAISE EXCEPTION 'motivo_requerido' USING HINT = 'Escribí por qué se anula el pago.'; END IF;
  SELECT * INTO v_m FROM cc_movimientos WHERE id = p_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'movimiento_no_encontrado'; END IF;
  IF v_m.tipo <> 'pago' THEN
    RAISE EXCEPTION 'no_anulable' USING HINT = 'Solo se anulan pagos. Para corregir otra cosa usá un ajuste.';
  END IF;
  IF v_m.anulado THEN RETURN jsonb_build_object('ok', true, 'sin_cambios', true); END IF;

  v_con := fn_caja_concepto('cobro_cc_anulado');
  INSERT INTO caja_movimientos (sesion_id, tipo, concepto_id, concepto_nombre, monto, medio_pago,
                                descripcion, origen, usuario_id, usuario_nombre)
  VALUES (fn_caja_abierta_id(), 'egreso', v_con.id, v_con.nombre, v_m.monto, v_m.medio_pago,
          left(format('Anula recibo %s: %s', v_m.recibo_numero, v_mot), 300), 'cobro_cc', auth.uid(), fn_mi_nombre())
  RETURNING id INTO v_caja;

  PERFORM set_config('mh.cc', '1', true);
  UPDATE cc_movimientos SET anulado = true, anulado_en = now(), anulado_por = auth.uid(),
                            motivo_anulacion = left(v_mot, 300)
  WHERE id = p_id;
  PERFORM set_config('mh.cc', '', true);

  v_inv := fn_cc_asentar(v_m.cuenta_id, 'pago_anulado', v_m.monto,
                         left(format('Anula recibo %s: %s', v_m.recibo_numero, v_mot), 300),
                         NULL, v_m.medio_pago, v_caja, NULL, v_m.id);

  INSERT INTO historial_actividad (usuario_id, accion, entidad, entidad_id, descripcion, valores_anteriores)
  VALUES (auth.uid(), 'anular', 'cc_pago', p_id::text, 'Anuló el recibo ' || v_m.recibo_numero || ': ' || v_mot, to_jsonb(v_m));

  RETURN jsonb_build_object('ok', true, 'id', p_id, 'saldo_actual', v_inv.saldo_posterior);
END;
$$;

-- Ajustes: saldo inicial (lo que ya debían en papel), correcciones, bonificaciones
-- p: { cuenta_id, tipo: 'ajuste_debito'|'ajuste_credito', monto, motivo }
CREATE OR REPLACE FUNCTION cc_ajuste(p JSONB)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_monto NUMERIC(12,2);
  v_mot   TEXT := nullif(btrim(coalesce(p->>'motivo', '')), '');
  v_mov   cc_movimientos;
BEGIN
  IF NOT fn_tiene_permiso('cc.ajustar') THEN
    RAISE EXCEPTION 'sin_permiso' USING HINT = 'Tu usuario no puede hacer ajustes de cuenta corriente.';
  END IF;
  IF p->>'tipo' NOT IN ('ajuste_debito', 'ajuste_credito') THEN
    RAISE EXCEPTION 'tipo_invalido' USING HINT = 'Elegí si el ajuste suma o resta deuda.';
  END IF;
  BEGIN v_monto := round((p->>'monto')::numeric, 2); EXCEPTION WHEN OTHERS THEN v_monto := NULL; END;
  IF v_monto IS NULL OR v_monto <= 0 OR v_monto > 100000000 THEN
    RAISE EXCEPTION 'monto_invalido' USING HINT = 'El monto tiene que ser mayor a cero.';
  END IF;
  IF v_mot IS NULL THEN RAISE EXCEPTION 'motivo_requerido' USING HINT = 'Escribí el motivo del ajuste.'; END IF;
  IF NOT EXISTS (SELECT 1 FROM cc_cuentas WHERE id = (p->>'cuenta_id')::bigint) THEN
    RAISE EXCEPTION 'cuenta_no_encontrada';
  END IF;

  v_mov := fn_cc_asentar((p->>'cuenta_id')::bigint, p->>'tipo', v_monto, v_mot);
  INSERT INTO historial_actividad (usuario_id, accion, entidad, entidad_id, descripcion, valores_nuevos)
  VALUES (auth.uid(), 'crear', 'cc_ajuste', v_mov.cuenta_id::text, 'Ajuste de cuenta corriente: ' || v_mot, to_jsonb(v_mov));
  RETURN jsonb_build_object('ok', true, 'id', v_mov.id, 'saldo_actual', v_mov.saldo_posterior);
END;
$$;


-- ──────────────────────────────────────────────
-- 12) Quién lee qué
-- ──────────────────────────────────────────────
ALTER TABLE cc_cuentas     ENABLE ROW LEVEL SECURITY;
ALTER TABLE cc_movimientos ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "cc_cuentas_select" ON cc_cuentas;
CREATE POLICY "cc_cuentas_select" ON cc_cuentas FOR SELECT USING (fn_tiene_permiso('cc.ver'));
DROP POLICY IF EXISTS "cc_movimientos_select" ON cc_movimientos;
CREATE POLICY "cc_movimientos_select" ON cc_movimientos FOR SELECT USING (fn_tiene_permiso('cc.ver'));
-- Sin políticas de escritura: solo las funciones.

REVOKE ALL ON cc_cuentas, cc_movimientos FROM anon;
REVOKE INSERT, UPDATE, DELETE ON cc_cuentas, cc_movimientos FROM authenticated;
GRANT SELECT ON cc_cuentas, cc_movimientos TO authenticated;

REVOKE ALL ON FUNCTION cc_recargo_guardar(INT, NUMERIC) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION cc_cuenta_guardar(JSONB)         FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION cc_buscar(TEXT)                  FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION cc_pago_registrar(JSONB)         FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION cc_pago_anular(BIGINT, TEXT)     FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION cc_ajuste(JSONB)                 FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION cc_recargo_guardar(INT, NUMERIC) TO authenticated;
GRANT EXECUTE ON FUNCTION cc_cuenta_guardar(JSONB)         TO authenticated;
GRANT EXECUTE ON FUNCTION cc_buscar(TEXT)                  TO authenticated;
GRANT EXECUTE ON FUNCTION cc_pago_registrar(JSONB)         TO authenticated;
GRANT EXECUTE ON FUNCTION cc_pago_anular(BIGINT, TEXT)     TO authenticated;
GRANT EXECUTE ON FUNCTION cc_ajuste(JSONB)                 TO authenticated;


NOTIFY pgrst, 'reload schema';

SELECT (SELECT count(*) FROM permisos WHERE modulo = 'Cuentas corrientes') AS permisos_cc,
       (SELECT count(*) FROM cc_cuentas)                                    AS cuentas,
       (SELECT count(*) FROM caja_conceptos WHERE clave LIKE 'cobro_cc%')   AS conceptos_caja;
