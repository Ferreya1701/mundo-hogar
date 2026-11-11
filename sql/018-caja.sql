-- ============================================================
-- 018 — CAJA DIARIA: APERTURA, MOVIMIENTOS Y CIERRE (2026-11-11)
-- Ejecutar en Supabase → SQL Editor, DESPUÉS del 017.
-- Idempotente: se puede correr más de una vez sin romper nada.
--
-- Cómo funciona:
--   • Se ABRE con el efectivo que hay en el cajón (por defecto, el fondo
--     que dejó el último cierre).
--   • Las VENTAS entran solas (disparador sobre `ventas`): efectivo suma
--     al cajón; transferencia, débito, crédito, Mercado Pago y "otro" se
--     ven en el resumen pero NO suman al efectivo. Cuenta corriente no es
--     ingreso de caja (entra cuando el cliente paga).
--   • Si una venta se ANULA (o en el futuro baja su total), sale solo el
--     egreso de devolución por la diferencia. Nunca se borra nada.
--   • INGRESOS y EGRESOS manuales (compras chicas, retiros, servicios…)
--     se cargan con un concepto y solo con la caja abierta.
--   • Se CIERRA contando el efectivo: queda registrada la diferencia
--     (sobrante o faltante, con explicación obligatoria), lo que se retira
--     y el fondo que queda para el día siguiente.
--   • La caja NUNCA frena una venta: si está cerrada, la venta se registra
--     igual y su movimiento queda "pendiente"; se suma a la próxima apertura.
--
-- Los movimientos no se editan ni se borran. Uno manual mal cargado se
-- ANULA: queda marcado y se agrega el movimiento inverso, con motivo.
--
-- Permisos nuevos (se suman a Admin → Permisos):
--   caja.ver, caja.abrir_cerrar, caja.movimientos, caja.anular,
--   caja.historial, caja.conceptos.
-- ============================================================


-- ──────────────────────────────────────────────
-- 1) Permisos de caja (mismo mecanismo que el 016)
-- ──────────────────────────────────────────────
CREATE TEMP TABLE _permisos_018 (clave TEXT, modulo TEXT, nombre TEXT, descripcion TEXT, orden INT, roles TEXT[]) ON COMMIT DROP;
INSERT INTO _permisos_018 VALUES
  ('caja.ver',          'Caja', 'Ver la caja del día',
     'Ver si la caja está abierta, sus movimientos y el resumen del día.',                 200, ARRAY['vendedor','encargado_stock']),
  ('caja.abrir_cerrar', 'Caja', 'Abrir y cerrar la caja',
     'Abrir con el efectivo inicial y cerrar contando el efectivo (arqueo).',             210, ARRAY['vendedor']),
  ('caja.movimientos',  'Caja', 'Cargar ingresos y egresos',
     'Registrar entradas y salidas de dinero que no son ventas (gastos, retiros, aportes).', 220, ARRAY['vendedor']),
  ('caja.anular',       'Caja', 'Anular movimientos de caja',
     'Deshacer un ingreso o egreso cargado a mano (queda registrado con motivo).',          230, ARRAY[]::TEXT[]),
  ('caja.historial',    'Caja', 'Ver cajas anteriores',
     'Ver los cierres de días anteriores, sus diferencias y movimientos.',                  240, ARRAY[]::TEXT[]),
  ('caja.conceptos',    'Caja', 'Editar conceptos de caja',
     'Crear, renombrar o desactivar los conceptos de ingresos y egresos.',                  250, ARRAY[]::TEXT[]);

INSERT INTO permisos (clave, modulo, nombre, descripcion, orden)
SELECT clave, modulo, nombre, descripcion, orden FROM _permisos_018
ON CONFLICT (clave) DO UPDATE SET
  modulo = EXCLUDED.modulo, nombre = EXCLUDED.nombre,
  descripcion = EXCLUDED.descripcion, orden = EXCLUDED.orden;

INSERT INTO rol_permisos (rol, permiso)
SELECT unnest(n.roles), n.clave
FROM _permisos_018 n JOIN permisos p ON p.clave = n.clave
WHERE NOT p.iniciales_aplicados
ON CONFLICT DO NOTHING;

UPDATE permisos SET iniciales_aplicados = true
WHERE clave IN (SELECT clave FROM _permisos_018) AND NOT iniciales_aplicados;


-- ──────────────────────────────────────────────
-- 2) Tablas
-- ──────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS caja_conceptos (
  id          SERIAL PRIMARY KEY,
  nombre      TEXT NOT NULL CHECK (length(btrim(nombre)) BETWEEN 2 AND 60),
  tipo        TEXT NOT NULL CHECK (tipo IN ('ingreso', 'egreso')),
  -- Los del sistema (ventas, diferencias, retiro al cierre) los usa la base: no se eligen a mano
  clave       TEXT UNIQUE,
  activo      BOOLEAN NOT NULL DEFAULT true,
  orden       INT NOT NULL DEFAULT 0,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_caja_conceptos_nombre ON caja_conceptos (tipo, lower(btrim(nombre)));

INSERT INTO caja_conceptos (nombre, tipo, clave, orden) VALUES
  ('Venta',                         'ingreso', 'venta',            0),
  ('Devolución / anulación de venta','egreso', 'venta_devolucion', 0),
  ('Sobrante de caja',              'ingreso', 'sobrante',         90),
  ('Faltante de caja',              'egreso',  'faltante',         90),
  ('Retiro al cierre',              'egreso',  'retiro_cierre',    91)
ON CONFLICT (clave) DO NOTHING;

-- Conceptos para cargar a mano (se pueden editar en la pantalla de Caja)
INSERT INTO caja_conceptos (nombre, tipo, orden)
SELECT v.nombre, v.tipo, v.orden FROM (VALUES
  ('Aporte de efectivo',       'ingreso', 10),
  ('Otros ingresos',           'ingreso', 80),
  ('Compras menores',          'egreso',  10),
  ('Retiro del dueño',         'egreso',  20),
  ('Sueldos y adelantos',      'egreso',  30),
  ('Servicios e impuestos',    'egreso',  40),
  ('Fletes y envíos',          'egreso',  50),
  ('Limpieza y mantenimiento', 'egreso',  60),
  ('Otros egresos',            'egreso',  80)
) AS v(nombre, tipo, orden)
WHERE NOT EXISTS (SELECT 1 FROM caja_conceptos c WHERE c.tipo = v.tipo AND lower(c.nombre) = lower(v.nombre));


CREATE TABLE IF NOT EXISTS caja_sesiones (
  id                 BIGSERIAL PRIMARY KEY,
  estado             TEXT NOT NULL DEFAULT 'abierta' CHECK (estado IN ('abierta', 'cerrada')),
  abierta_en         TIMESTAMPTZ NOT NULL DEFAULT now(),
  abierta_por        UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  abierta_por_nombre TEXT,
  monto_inicial      NUMERIC(12,2) NOT NULL CHECK (monto_inicial >= 0),
  -- Fondo que había dejado el cierre anterior (para ver si faltó plata entre cierre y apertura)
  fondo_anterior     NUMERIC(12,2),
  notas_apertura     TEXT,
  cerrada_en         TIMESTAMPTZ,
  cerrada_por        UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  cerrada_por_nombre TEXT,
  efectivo_esperado  NUMERIC(12,2),
  efectivo_contado   NUMERIC(12,2) CHECK (efectivo_contado IS NULL OR efectivo_contado >= 0),
  diferencia         NUMERIC(12,2),          -- contado − esperado (+ sobra, − falta)
  retiro             NUMERIC(12,2) CHECK (retiro IS NULL OR retiro >= 0),
  fondo_siguiente    NUMERIC(12,2) CHECK (fondo_siguiente IS NULL OR fondo_siguiente >= 0),
  notas_cierre       TEXT,
  CHECK ((estado = 'abierta') = (cerrada_en IS NULL))
);
-- Una sola caja abierta a la vez
CREATE UNIQUE INDEX IF NOT EXISTS uq_caja_una_abierta ON caja_sesiones ((true)) WHERE estado = 'abierta';
CREATE INDEX IF NOT EXISTS idx_caja_sesiones_abierta_en ON caja_sesiones (abierta_en DESC);


CREATE TABLE IF NOT EXISTS caja_movimientos (
  id              BIGSERIAL PRIMARY KEY,
  sesion_id       BIGINT REFERENCES caja_sesiones(id),      -- NULL = hecho con la caja cerrada (pendiente)
  fecha           TIMESTAMPTZ NOT NULL DEFAULT now(),
  tipo            TEXT NOT NULL CHECK (tipo IN ('ingreso', 'egreso')),
  concepto_id     INT NOT NULL REFERENCES caja_conceptos(id),
  concepto_nombre TEXT NOT NULL,                           -- copia: renombrar el concepto no cambia el pasado
  monto           NUMERIC(12,2) NOT NULL CHECK (monto > 0),
  medio_pago      TEXT NOT NULL DEFAULT 'efectivo'
                    CHECK (medio_pago IN ('efectivo','transferencia','debito','credito','mercadopago','otro')),
  descripcion     TEXT CHECK (descripcion IS NULL OR length(descripcion) <= 300),
  origen          TEXT NOT NULL CHECK (origen IN ('venta', 'manual', 'anulacion', 'cierre', 'cobro_cc')),
  venta_id        BIGINT REFERENCES ventas(id),
  usuario_id      UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  usuario_nombre  TEXT,
  -- Anulación de un movimiento manual: el original queda marcado y se agrega el inverso
  anulado         BOOLEAN NOT NULL DEFAULT false,
  anulado_en      TIMESTAMPTZ,
  anulado_por     UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  motivo_anulacion TEXT,
  revierte_a_id   BIGINT UNIQUE REFERENCES caja_movimientos(id)
);
CREATE INDEX IF NOT EXISTS idx_caja_mov_sesion ON caja_movimientos (sesion_id, fecha);
CREATE INDEX IF NOT EXISTS idx_caja_mov_venta  ON caja_movimientos (venta_id) WHERE venta_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_caja_mov_pendientes ON caja_movimientos (fecha) WHERE sesion_id IS NULL;

-- Nada se edita ni se borra fuera de las funciones de este archivo
CREATE OR REPLACE FUNCTION fn_caja_inmutable()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF coalesce(current_setting('mh.caja', true), '') <> '1' THEN
    RAISE EXCEPTION 'caja_inmutable' USING HINT = 'Los movimientos y cierres de caja no se modifican ni se borran: se anulan.';
  END IF;
  RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END;
$$;
DROP TRIGGER IF EXISTS tr_caja_mov_inmutable ON caja_movimientos;
CREATE TRIGGER tr_caja_mov_inmutable BEFORE UPDATE OR DELETE ON caja_movimientos
  FOR EACH ROW EXECUTE FUNCTION fn_caja_inmutable();
DROP TRIGGER IF EXISTS tr_caja_ses_inmutable ON caja_sesiones;
CREATE TRIGGER tr_caja_ses_inmutable BEFORE UPDATE OR DELETE ON caja_sesiones
  FOR EACH ROW EXECUTE FUNCTION fn_caja_inmutable();


-- ──────────────────────────────────────────────
-- 3) Ayudas internas
-- ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_caja_abierta_id()
RETURNS BIGINT LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT id FROM caja_sesiones WHERE estado = 'abierta' LIMIT 1
$$;

CREATE OR REPLACE FUNCTION fn_caja_concepto(p_clave TEXT)
RETURNS caja_conceptos LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT * FROM caja_conceptos WHERE clave = p_clave
$$;

CREATE OR REPLACE FUNCTION fn_mi_nombre()
RETURNS TEXT LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT nombre FROM profiles WHERE id = auth.uid()
$$;

-- Efectivo que debería haber en el cajón: inicial + ingresos − egresos en efectivo
CREATE OR REPLACE FUNCTION fn_caja_efectivo_esperado(p_sesion_id BIGINT)
RETURNS NUMERIC LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT s.monto_inicial + coalesce((
    SELECT sum(CASE m.tipo WHEN 'ingreso' THEN m.monto ELSE -m.monto END)
    FROM caja_movimientos m
    WHERE m.sesion_id = s.id AND m.medio_pago = 'efectivo'
      AND m.origen <> 'cierre'          -- diferencias y retiro del cierre van aparte
  ), 0)
  FROM caja_sesiones s WHERE s.id = p_sesion_id
$$;

REVOKE ALL ON FUNCTION fn_caja_concepto(TEXT) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION fn_caja_efectivo_esperado(BIGINT) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION fn_caja_abierta_id() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION fn_mi_nombre() FROM PUBLIC, anon, authenticated;


-- ──────────────────────────────────────────────
-- 4) Las ventas entran solas a la caja
-- ──────────────────────────────────────────────
-- Lo que la venta tiene que haber dejado en la caja (total si está cerrada
-- y no es cuenta corriente; 0 si está anulada) contra lo que ya dejó.
-- Si no coincide, se asienta la diferencia: ingreso "Venta" o egreso
-- "Devolución". Sirve para el alta, la anulación y una futura edición.
CREATE OR REPLACE FUNCTION fn_caja_sincronizar_venta(p_venta_id BIGINT)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v        ventas%ROWTYPE;
  v_debe   NUMERIC(12,2);
  v_tiene  NUMERIC(12,2);
  v_dif    NUMERIC(12,2);
  v_con    caja_conceptos;
  v_medio  TEXT;
BEGIN
  SELECT * INTO v FROM ventas WHERE id = p_venta_id;
  IF NOT FOUND THEN RETURN; END IF;

  v_medio := CASE WHEN v.medio_pago = 'cuenta_corriente' THEN NULL ELSE v.medio_pago END;
  v_debe  := CASE WHEN v.estado = 'cerrada' AND v_medio IS NOT NULL THEN v.total ELSE 0 END;

  -- Una venta a la vez (dos anulaciones simultáneas no duplican la devolución)
  PERFORM pg_advisory_xact_lock(hashtext('caja_venta:' || p_venta_id));
  SELECT coalesce(sum(CASE tipo WHEN 'ingreso' THEN monto ELSE -monto END), 0) INTO v_tiene
  FROM caja_movimientos WHERE venta_id = p_venta_id;

  v_dif := v_debe - v_tiene;
  IF v_dif = 0 THEN RETURN; END IF;

  v_con := fn_caja_concepto(CASE WHEN v_dif > 0 THEN 'venta' ELSE 'venta_devolucion' END);
  -- La devolución sale por el mismo medio por el que entró la plata
  IF v_medio IS NULL THEN
    SELECT medio_pago INTO v_medio FROM caja_movimientos WHERE venta_id = p_venta_id ORDER BY id DESC LIMIT 1;
  END IF;

  INSERT INTO caja_movimientos (sesion_id, tipo, concepto_id, concepto_nombre, monto, medio_pago,
                                descripcion, origen, venta_id, usuario_id, usuario_nombre)
  VALUES (fn_caja_abierta_id(), CASE WHEN v_dif > 0 THEN 'ingreso' ELSE 'egreso' END,
          v_con.id, v_con.nombre, abs(v_dif), coalesce(v_medio, 'efectivo'),
          CASE WHEN v_dif > 0 THEN 'Venta ' ELSE 'Devolución venta ' END || v.codigo
            || CASE WHEN v.estado = 'anulada' AND v_dif < 0 THEN ' (anulada)' ELSE '' END,
          CASE WHEN v_dif > 0 THEN 'venta' ELSE 'anulacion' END,
          v.id, coalesce(auth.uid(), v.vendedor_id), coalesce(fn_mi_nombre(), v.vendedor_nombre));
END;
$$;
REVOKE ALL ON FUNCTION fn_caja_sincronizar_venta(BIGINT) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION fn_tr_ventas_caja()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  PERFORM fn_caja_sincronizar_venta(NEW.id);
  RETURN NULL;
END;
$$;
DROP TRIGGER IF EXISTS tr_ventas_caja ON ventas;
CREATE TRIGGER tr_ventas_caja AFTER INSERT OR UPDATE OF total, estado, medio_pago ON ventas
  FOR EACH ROW EXECUTE FUNCTION fn_tr_ventas_caja();


-- ──────────────────────────────────────────────
-- 5) Abrir la caja
-- ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION caja_abrir(p_monto_inicial NUMERIC, p_notas TEXT DEFAULT NULL)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_fondo   NUMERIC(12,2);
  v_id      BIGINT;
  v_pend    INT;
  v_notas   TEXT := nullif(btrim(coalesce(p_notas, '')), '');
BEGIN
  IF NOT fn_tiene_permiso('caja.abrir_cerrar') THEN
    RAISE EXCEPTION 'sin_permiso' USING HINT = 'Tu usuario no puede abrir la caja.';
  END IF;
  IF p_monto_inicial IS NULL OR p_monto_inicial < 0 OR p_monto_inicial > 100000000 THEN
    RAISE EXCEPTION 'monto_invalido' USING HINT = 'Poné cuánto efectivo hay en la caja al abrir (0 o más).';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext('caja_sesion'));
  IF fn_caja_abierta_id() IS NOT NULL THEN
    RAISE EXCEPTION 'caja_ya_abierta' USING HINT = 'La caja ya está abierta.';
  END IF;

  SELECT fondo_siguiente INTO v_fondo FROM caja_sesiones WHERE estado = 'cerrada' ORDER BY cerrada_en DESC LIMIT 1;
  IF v_fondo IS NOT NULL AND round(p_monto_inicial, 2) <> v_fondo AND v_notas IS NULL THEN
    RAISE EXCEPTION 'nota_requerida'
      USING HINT = format('El cierre anterior dejó %s de fondo y estás abriendo con %s: explicá la diferencia.',
                          to_char(v_fondo, 'FM999G999G990D00'), to_char(p_monto_inicial, 'FM999G999G990D00'));
  END IF;

  PERFORM set_config('mh.caja', '1', true);
  INSERT INTO caja_sesiones (abierta_por, abierta_por_nombre, monto_inicial, fondo_anterior, notas_apertura)
  VALUES (auth.uid(), fn_mi_nombre(), round(p_monto_inicial, 2), v_fondo, left(v_notas, 300))
  RETURNING id INTO v_id;

  -- Lo que se vendió con la caja cerrada entra en esta
  UPDATE caja_movimientos SET sesion_id = v_id WHERE sesion_id IS NULL;
  GET DIAGNOSTICS v_pend = ROW_COUNT;
  PERFORM set_config('mh.caja', '', true);

  INSERT INTO historial_actividad (usuario_id, accion, entidad, entidad_id, descripcion, valores_nuevos)
  VALUES (auth.uid(), 'crear', 'caja', v_id::text, 'Abrió la caja',
          jsonb_build_object('monto_inicial', round(p_monto_inicial, 2), 'fondo_anterior', v_fondo, 'pendientes', v_pend));

  RETURN jsonb_build_object('ok', true, 'sesion_id', v_id, 'monto_inicial', round(p_monto_inicial, 2),
                            'fondo_anterior', v_fondo, 'pendientes_sumados', v_pend);
END;
$$;


-- ──────────────────────────────────────────────
-- 6) Ingresos y egresos manuales
-- ──────────────────────────────────────────────
-- p: { tipo: 'ingreso'|'egreso', concepto_id, monto, medio_pago (def. efectivo), descripcion }
CREATE OR REPLACE FUNCTION caja_movimiento_registrar(p JSONB)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_ses    BIGINT;
  v_con    caja_conceptos%ROWTYPE;
  v_monto  NUMERIC(12,2);
  v_medio  TEXT := coalesce(nullif(p->>'medio_pago', ''), 'efectivo');
  v_desc   TEXT := nullif(btrim(coalesce(p->>'descripcion', '')), '');
  v_id     BIGINT;
BEGIN
  IF NOT fn_tiene_permiso('caja.movimientos') THEN
    RAISE EXCEPTION 'sin_permiso' USING HINT = 'Tu usuario no puede cargar ingresos ni egresos de caja.';
  END IF;
  v_ses := fn_caja_abierta_id();
  IF v_ses IS NULL THEN
    RAISE EXCEPTION 'caja_cerrada' USING HINT = 'Abrí la caja antes de cargar ingresos o egresos.';
  END IF;
  IF p->>'tipo' NOT IN ('ingreso', 'egreso') THEN
    RAISE EXCEPTION 'tipo_invalido' USING HINT = 'Elegí si es un ingreso o un egreso.';
  END IF;
  BEGIN
    v_monto := round((p->>'monto')::numeric, 2);
  EXCEPTION WHEN OTHERS THEN v_monto := NULL;
  END;
  IF v_monto IS NULL OR v_monto <= 0 OR v_monto > 100000000 THEN
    RAISE EXCEPTION 'monto_invalido' USING HINT = 'El monto tiene que ser mayor a cero.';
  END IF;
  IF v_medio NOT IN ('efectivo','transferencia','debito','credito','mercadopago','otro') THEN
    RAISE EXCEPTION 'medio_invalido';
  END IF;
  SELECT * INTO v_con FROM caja_conceptos WHERE id = (p->>'concepto_id')::int;
  IF NOT FOUND OR NOT v_con.activo OR v_con.clave IS NOT NULL OR v_con.tipo <> p->>'tipo' THEN
    RAISE EXCEPTION 'concepto_invalido' USING HINT = 'Elegí un concepto de la lista.';
  END IF;
  IF v_desc IS NULL AND v_con.nombre ILIKE 'Otros%' THEN
    RAISE EXCEPTION 'descripcion_requerida' USING HINT = 'Para "Otros" escribí de qué se trata.';
  END IF;

  INSERT INTO caja_movimientos (sesion_id, tipo, concepto_id, concepto_nombre, monto, medio_pago,
                                descripcion, origen, usuario_id, usuario_nombre)
  VALUES (v_ses, p->>'tipo', v_con.id, v_con.nombre, v_monto, v_medio, left(v_desc, 300), 'manual',
          auth.uid(), fn_mi_nombre())
  RETURNING id INTO v_id;

  RETURN jsonb_build_object('ok', true, 'id', v_id, 'sesion_id', v_ses);
END;
$$;


-- ──────────────────────────────────────────────
-- 7) Anular un movimiento manual
-- ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION caja_movimiento_anular(p_id BIGINT, p_motivo TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_m    caja_movimientos%ROWTYPE;
  v_ses  BIGINT;
  v_id   BIGINT;
  v_mot  TEXT := nullif(btrim(coalesce(p_motivo, '')), '');
BEGIN
  IF NOT fn_tiene_permiso('caja.anular') THEN
    RAISE EXCEPTION 'sin_permiso' USING HINT = 'Tu usuario no puede anular movimientos de caja.';
  END IF;
  IF v_mot IS NULL THEN
    RAISE EXCEPTION 'motivo_requerido' USING HINT = 'Escribí por qué se anula.';
  END IF;
  v_ses := fn_caja_abierta_id();
  IF v_ses IS NULL THEN
    RAISE EXCEPTION 'caja_cerrada' USING HINT = 'Abrí la caja para anular: el movimiento inverso entra en la caja de hoy.';
  END IF;

  SELECT * INTO v_m FROM caja_movimientos WHERE id = p_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'movimiento_no_encontrado'; END IF;
  IF v_m.origen <> 'manual' THEN
    RAISE EXCEPTION 'no_anulable'
      USING HINT = 'Solo se anulan ingresos y egresos cargados a mano. Una venta se anula desde Ventas.';
  END IF;
  IF v_m.anulado THEN
    RETURN jsonb_build_object('ok', true, 'sin_cambios', true);
  END IF;

  PERFORM set_config('mh.caja', '1', true);
  UPDATE caja_movimientos SET anulado = true, anulado_en = now(), anulado_por = auth.uid(),
                              motivo_anulacion = left(v_mot, 300)
  WHERE id = p_id;
  PERFORM set_config('mh.caja', '', true);

  INSERT INTO caja_movimientos (sesion_id, tipo, concepto_id, concepto_nombre, monto, medio_pago,
                                descripcion, origen, usuario_id, usuario_nombre, revierte_a_id)
  VALUES (v_ses, CASE v_m.tipo WHEN 'ingreso' THEN 'egreso' ELSE 'ingreso' END,
          v_m.concepto_id, v_m.concepto_nombre, v_m.monto, v_m.medio_pago,
          left('Anula #' || v_m.id || ': ' || v_mot, 300), 'anulacion', auth.uid(), fn_mi_nombre(), v_m.id)
  RETURNING id INTO v_id;

  INSERT INTO historial_actividad (usuario_id, accion, entidad, entidad_id, descripcion, valores_anteriores)
  VALUES (auth.uid(), 'anular', 'caja_movimiento', p_id::text, 'Anuló un movimiento de caja: ' || v_mot,
          to_jsonb(v_m));

  RETURN jsonb_build_object('ok', true, 'id', p_id, 'inverso_id', v_id);
END;
$$;


-- ──────────────────────────────────────────────
-- 8) Resumen (para la pantalla y el cierre)
-- ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION caja_resumen(p_sesion_id BIGINT DEFAULT NULL)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_s     caja_sesiones%ROWTYPE;
  v_id    BIGINT := coalesce(p_sesion_id, fn_caja_abierta_id());
BEGIN
  IF NOT fn_tiene_permiso('caja.ver') THEN
    RAISE EXCEPTION 'sin_permiso' USING HINT = 'Tu usuario no puede ver la caja.';
  END IF;
  IF v_id IS NULL THEN
    RETURN jsonb_build_object(
      'abierta', false,
      'ultimo_fondo', (SELECT fondo_siguiente FROM caja_sesiones WHERE estado = 'cerrada' ORDER BY cerrada_en DESC LIMIT 1),
      'pendientes', (SELECT jsonb_build_object('cantidad', count(*), 'efectivo',
                       coalesce(sum(CASE WHEN medio_pago = 'efectivo' THEN CASE tipo WHEN 'ingreso' THEN monto ELSE -monto END END), 0))
                     FROM caja_movimientos WHERE sesion_id IS NULL));
  END IF;
  SELECT * INTO v_s FROM caja_sesiones WHERE id = v_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'caja_no_encontrada'; END IF;
  -- Una caja de otro día: solo con "ver cajas anteriores"
  IF v_s.estado = 'cerrada' AND NOT fn_tiene_permiso('caja.historial')
     AND (v_s.abierta_en AT TIME ZONE 'America/Argentina/Buenos_Aires')::date
         <> (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date THEN
    RAISE EXCEPTION 'sin_permiso' USING HINT = 'Tu usuario no puede ver cajas de días anteriores.';
  END IF;

  RETURN jsonb_build_object(
    'abierta', v_s.estado = 'abierta',
    'sesion', to_jsonb(v_s),
    'efectivo', jsonb_build_object(
      'inicial',  v_s.monto_inicial,
      'ingresos', coalesce((SELECT sum(monto) FROM caja_movimientos WHERE sesion_id = v_id AND medio_pago = 'efectivo' AND tipo = 'ingreso' AND origen <> 'cierre'), 0),
      'egresos',  coalesce((SELECT sum(monto) FROM caja_movimientos WHERE sesion_id = v_id AND medio_pago = 'efectivo' AND tipo = 'egreso'  AND origen <> 'cierre'), 0),
      'esperado', fn_caja_efectivo_esperado(v_id)),
    'por_medio', coalesce((
      SELECT jsonb_agg(jsonb_build_object('medio', medio_pago, 'ingresos', ing, 'egresos', egr, 'neto', ing - egr) ORDER BY medio_pago)
      FROM (SELECT medio_pago,
                   coalesce(sum(monto) FILTER (WHERE tipo = 'ingreso'), 0) AS ing,
                   coalesce(sum(monto) FILTER (WHERE tipo = 'egreso'), 0)  AS egr
            FROM caja_movimientos WHERE sesion_id = v_id AND origen <> 'cierre' GROUP BY medio_pago) x), '[]'::jsonb),
    'ventas', (SELECT jsonb_build_object('cantidad', count(DISTINCT venta_id), 'total',
                 coalesce(sum(CASE tipo WHEN 'ingreso' THEN monto ELSE -monto END), 0))
               FROM caja_movimientos WHERE sesion_id = v_id AND venta_id IS NOT NULL),
    'por_concepto', coalesce((
      SELECT jsonb_agg(jsonb_build_object('tipo', tipo, 'concepto', concepto_nombre, 'total', total) ORDER BY tipo, total DESC)
      FROM (SELECT tipo, concepto_nombre, sum(monto) AS total FROM caja_movimientos
            WHERE sesion_id = v_id AND origen IN ('manual', 'anulacion') AND venta_id IS NULL
            GROUP BY tipo, concepto_nombre) x), '[]'::jsonb)
  );
END;
$$;


-- ──────────────────────────────────────────────
-- 9) Cerrar la caja (arqueo)
-- ──────────────────────────────────────────────
-- p_contado: efectivo contado en el cajón.
-- p_fondo:   cuánto queda en el cajón para mañana (el resto se retira).
-- p_notas:   obligatoria si hay diferencia entre lo contado y lo esperado.
CREATE OR REPLACE FUNCTION caja_cerrar(p_contado NUMERIC, p_fondo NUMERIC, p_notas TEXT DEFAULT NULL)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_s        caja_sesiones%ROWTYPE;
  v_esp      NUMERIC(12,2);
  v_cont     NUMERIC(12,2) := round(p_contado, 2);
  v_fondo    NUMERIC(12,2) := round(p_fondo, 2);
  v_dif      NUMERIC(12,2);
  v_retiro   NUMERIC(12,2);
  v_notas    TEXT := nullif(btrim(coalesce(p_notas, '')), '');
  v_con      caja_conceptos;
  v_quien    TEXT := fn_mi_nombre();
BEGIN
  IF NOT fn_tiene_permiso('caja.abrir_cerrar') THEN
    RAISE EXCEPTION 'sin_permiso' USING HINT = 'Tu usuario no puede cerrar la caja.';
  END IF;
  IF v_cont IS NULL OR v_cont < 0 OR v_cont > 100000000 THEN
    RAISE EXCEPTION 'monto_invalido' USING HINT = 'Poné el efectivo que contaste (0 o más).';
  END IF;
  IF v_fondo IS NULL OR v_fondo < 0 OR v_fondo > v_cont THEN
    RAISE EXCEPTION 'fondo_invalido' USING HINT = 'El fondo para mañana tiene que estar entre 0 y lo que contaste.';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext('caja_sesion'));
  SELECT * INTO v_s FROM caja_sesiones WHERE estado = 'abierta' FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'caja_cerrada' USING HINT = 'La caja no está abierta.';
  END IF;

  v_esp := fn_caja_efectivo_esperado(v_s.id);
  v_dif := v_cont - v_esp;
  IF v_dif <> 0 AND v_notas IS NULL THEN
    RAISE EXCEPTION 'nota_requerida'
      USING HINT = format('Hay una diferencia de %s entre lo contado y lo esperado: explicá qué pasó.',
                          to_char(v_dif, 'FMS999G999G990D00'));
  END IF;
  v_retiro := v_cont - v_fondo;

  -- La diferencia y el retiro quedan como movimientos (en efectivo) para que el libro cierre
  IF v_dif <> 0 THEN
    v_con := fn_caja_concepto(CASE WHEN v_dif > 0 THEN 'sobrante' ELSE 'faltante' END);
    INSERT INTO caja_movimientos (sesion_id, tipo, concepto_id, concepto_nombre, monto, medio_pago,
                                  descripcion, origen, usuario_id, usuario_nombre)
    VALUES (v_s.id, CASE WHEN v_dif > 0 THEN 'ingreso' ELSE 'egreso' END, v_con.id, v_con.nombre,
            abs(v_dif), 'efectivo', left(v_notas, 300), 'cierre', auth.uid(), v_quien);
  END IF;
  IF v_retiro > 0 THEN
    v_con := fn_caja_concepto('retiro_cierre');
    INSERT INTO caja_movimientos (sesion_id, tipo, concepto_id, concepto_nombre, monto, medio_pago,
                                  descripcion, origen, usuario_id, usuario_nombre)
    VALUES (v_s.id, 'egreso', v_con.id, v_con.nombre, v_retiro, 'efectivo',
            'Retiro al cerrar la caja', 'cierre', auth.uid(), v_quien);
  END IF;

  PERFORM set_config('mh.caja', '1', true);
  UPDATE caja_sesiones SET
    estado = 'cerrada', cerrada_en = now(), cerrada_por = auth.uid(), cerrada_por_nombre = v_quien,
    efectivo_esperado = v_esp, efectivo_contado = v_cont, diferencia = v_dif,
    retiro = v_retiro, fondo_siguiente = v_fondo, notas_cierre = left(v_notas, 500)
  WHERE id = v_s.id;
  PERFORM set_config('mh.caja', '', true);

  INSERT INTO historial_actividad (usuario_id, accion, entidad, entidad_id, descripcion, valores_nuevos)
  VALUES (auth.uid(), 'actualizar', 'caja', v_s.id::text, 'Cerró la caja',
          jsonb_build_object('esperado', v_esp, 'contado', v_cont, 'diferencia', v_dif,
                             'retiro', v_retiro, 'fondo', v_fondo));

  RETURN jsonb_build_object('ok', true, 'sesion_id', v_s.id, 'esperado', v_esp, 'contado', v_cont,
                            'diferencia', v_dif, 'retiro', v_retiro, 'fondo', v_fondo);
END;
$$;


-- ──────────────────────────────────────────────
-- 10) ¿Está abierta? (para avisar en Crear venta; lo ve cualquier staff)
-- ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION caja_esta_abierta()
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT CASE WHEN fn_get_user_role() IS NULL THEN NULL ELSE fn_caja_abierta_id() IS NOT NULL END
$$;


-- ──────────────────────────────────────────────
-- 11) Quién lee qué
-- ──────────────────────────────────────────────
ALTER TABLE caja_conceptos   ENABLE ROW LEVEL SECURITY;
ALTER TABLE caja_sesiones    ENABLE ROW LEVEL SECURITY;
ALTER TABLE caja_movimientos ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "caja_conceptos_select" ON caja_conceptos;
CREATE POLICY "caja_conceptos_select" ON caja_conceptos FOR SELECT USING (fn_get_user_role() IS NOT NULL);
-- Los del sistema no se tocan; los demás, con el permiso de conceptos (no se borran: se desactivan)
DROP POLICY IF EXISTS "caja_conceptos_insert" ON caja_conceptos;
CREATE POLICY "caja_conceptos_insert" ON caja_conceptos FOR INSERT
  WITH CHECK (fn_tiene_permiso('caja.conceptos') AND clave IS NULL);
DROP POLICY IF EXISTS "caja_conceptos_update" ON caja_conceptos;
CREATE POLICY "caja_conceptos_update" ON caja_conceptos FOR UPDATE
  USING (fn_tiene_permiso('caja.conceptos') AND clave IS NULL)
  WITH CHECK (fn_tiene_permiso('caja.conceptos') AND clave IS NULL);

-- Caja del día: con "ver"; días anteriores: con "historial"
DROP POLICY IF EXISTS "caja_sesiones_select" ON caja_sesiones;
CREATE POLICY "caja_sesiones_select" ON caja_sesiones FOR SELECT
  USING (fn_tiene_permiso('caja.historial')
         OR (fn_tiene_permiso('caja.ver')
             AND (estado = 'abierta'
                  OR (abierta_en AT TIME ZONE 'America/Argentina/Buenos_Aires')::date
                     = (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date)));

DROP POLICY IF EXISTS "caja_movimientos_select" ON caja_movimientos;
CREATE POLICY "caja_movimientos_select" ON caja_movimientos FOR SELECT
  USING (fn_tiene_permiso('caja.historial')
         OR (fn_tiene_permiso('caja.ver')
             AND (sesion_id IS NULL OR EXISTS (SELECT 1 FROM caja_sesiones s WHERE s.id = caja_movimientos.sesion_id))));
-- Sin políticas de escritura en sesiones y movimientos: solo las funciones.

REVOKE ALL ON caja_conceptos, caja_sesiones, caja_movimientos FROM anon;
REVOKE INSERT, UPDATE, DELETE ON caja_sesiones, caja_movimientos FROM authenticated;
GRANT SELECT ON caja_sesiones, caja_movimientos TO authenticated;
GRANT SELECT, INSERT, UPDATE ON caja_conceptos TO authenticated;
GRANT USAGE ON SEQUENCE caja_conceptos_id_seq TO authenticated;

REVOKE ALL ON FUNCTION caja_abrir(NUMERIC, TEXT)                  FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION caja_cerrar(NUMERIC, NUMERIC, TEXT)        FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION caja_movimiento_registrar(JSONB)           FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION caja_movimiento_anular(BIGINT, TEXT)       FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION caja_resumen(BIGINT)                       FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION caja_esta_abierta()                        FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION caja_abrir(NUMERIC, TEXT)               TO authenticated;
GRANT EXECUTE ON FUNCTION caja_cerrar(NUMERIC, NUMERIC, TEXT)     TO authenticated;
GRANT EXECUTE ON FUNCTION caja_movimiento_registrar(JSONB)        TO authenticated;
GRANT EXECUTE ON FUNCTION caja_movimiento_anular(BIGINT, TEXT)    TO authenticated;
GRANT EXECUTE ON FUNCTION caja_resumen(BIGINT)                    TO authenticated;
GRANT EXECUTE ON FUNCTION caja_esta_abierta()                     TO authenticated;


NOTIFY pgrst, 'reload schema';

SELECT (SELECT count(*) FROM caja_conceptos)                    AS conceptos,
       (SELECT count(*) FROM permisos WHERE modulo = 'Caja')    AS permisos_caja,
       (SELECT count(*) FROM caja_sesiones WHERE estado = 'abierta') AS cajas_abiertas;
