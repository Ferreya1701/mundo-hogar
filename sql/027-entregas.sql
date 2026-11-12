-- ============================================================
-- 027 — ENTREGAS: RETIROS EN EL LOCAL Y ENVÍOS (2026-11-12)
-- Ejecutar en Supabase → SQL Editor, DESPUÉS del 026.
-- Idempotente: se puede correr más de una vez sin romper nada.
--
-- Cada venta dice cómo se entrega:
--   • en_el_momento → el cliente se la lleva (como hasta ahora; no aparece
--                      en ninguna lista).
--   • retiro        → queda en el local para que la pasen a buscar.
--   • envio         → se despacha por una empresa de transporte, con
--                      dirección y fecha de despacho.
--
-- Las de retiro y envío pasan por: pendiente → listo (preparada; opcional)
-- → entregado (retirada / despachada).
--
-- REGLA: lo que no está pagado NO sale. Solo se entrega o despacha una
-- venta cobrada o cargada a cuenta corriente. Una venta que todavía espera
-- cobro en la caja se ve en la lista, pero no se puede entregar.
--
-- Al entregar queda quién retiró (nombre y DNI opcional) y quién entregó;
-- al despachar, el número de seguimiento si lo hay.
--
-- Las empresas de transporte son una lista propia (como las ubicaciones).
--
-- Permisos nuevos: entregas.ver, entregas.gestionar, entregas.transportes.
-- ============================================================

CREATE TEMP TABLE _permisos_027 (clave TEXT, modulo TEXT, nombre TEXT, descripcion TEXT, orden INT, roles TEXT[]) ON COMMIT DROP;
INSERT INTO _permisos_027 VALUES
  ('entregas.ver',         'Entregas', 'Ver retiros y envíos',
     'Ver lo que está para retirar en el local y lo que hay que despachar, de todas las vendedoras.',  400, ARRAY['vendedor','encargado_stock']),
  ('entregas.gestionar',   'Entregas', 'Entregar y despachar',
     'Marcar una venta como lista, entregarla a quien la retira o despacharla por el transporte.',     410, ARRAY['vendedor','encargado_stock']),
  ('entregas.transportes', 'Entregas', 'Editar empresas de transporte',
     'Agregar, renombrar o desactivar las empresas de envío.',                                           420, ARRAY[]::TEXT[]);
INSERT INTO permisos (clave, modulo, nombre, descripcion, orden)
SELECT clave, modulo, nombre, descripcion, orden FROM _permisos_027
ON CONFLICT (clave) DO UPDATE SET modulo = EXCLUDED.modulo, nombre = EXCLUDED.nombre, descripcion = EXCLUDED.descripcion, orden = EXCLUDED.orden;
INSERT INTO rol_permisos (rol, permiso)
SELECT unnest(n.roles), n.clave FROM _permisos_027 n JOIN permisos p ON p.clave = n.clave
WHERE NOT p.iniciales_aplicados ON CONFLICT DO NOTHING;
UPDATE permisos SET iniciales_aplicados = true WHERE clave IN (SELECT clave FROM _permisos_027) AND NOT iniciales_aplicados;


-- ──────────────────────────────────────────────
-- 1) Empresas de transporte
-- ──────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS transportes (
  id         SERIAL PRIMARY KEY,
  nombre     TEXT NOT NULL CHECK (length(btrim(nombre)) BETWEEN 2 AND 60),
  notas      TEXT CHECK (notas IS NULL OR length(notas) <= 200),     -- horario de retiro, teléfono…
  activo     BOOLEAN NOT NULL DEFAULT true,
  orden      INT NOT NULL DEFAULT 0,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_transportes_nombre ON transportes (lower(btrim(nombre)));
ALTER TABLE transportes ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "transportes_select" ON transportes;
CREATE POLICY "transportes_select" ON transportes FOR SELECT USING (fn_get_user_role() IS NOT NULL);
DROP POLICY IF EXISTS "transportes_insert" ON transportes;
CREATE POLICY "transportes_insert" ON transportes FOR INSERT WITH CHECK (fn_tiene_permiso('entregas.transportes'));
DROP POLICY IF EXISTS "transportes_update" ON transportes;
CREATE POLICY "transportes_update" ON transportes FOR UPDATE
  USING (fn_tiene_permiso('entregas.transportes')) WITH CHECK (fn_tiene_permiso('entregas.transportes'));
REVOKE ALL ON transportes FROM anon;
REVOKE DELETE, TRUNCATE ON transportes FROM authenticated;
GRANT SELECT, INSERT, UPDATE ON transportes TO authenticated;
GRANT USAGE ON SEQUENCE transportes_id_seq TO authenticated;


-- ──────────────────────────────────────────────
-- 2) La entrega de cada venta
-- ──────────────────────────────────────────────
ALTER TABLE ventas ADD COLUMN IF NOT EXISTS entrega_tipo   TEXT NOT NULL DEFAULT 'en_el_momento';
ALTER TABLE ventas DROP CONSTRAINT IF EXISTS ventas_entrega_tipo_check;
ALTER TABLE ventas ADD CONSTRAINT ventas_entrega_tipo_check CHECK (entrega_tipo IN ('en_el_momento', 'retiro', 'envio'));
ALTER TABLE ventas ADD COLUMN IF NOT EXISTS entrega_estado TEXT;       -- NULL en "en el momento"
ALTER TABLE ventas DROP CONSTRAINT IF EXISTS ventas_entrega_estado_check;
ALTER TABLE ventas ADD CONSTRAINT ventas_entrega_estado_check
  CHECK ((entrega_tipo = 'en_el_momento' AND entrega_estado IS NULL)
      OR (entrega_tipo <> 'en_el_momento' AND entrega_estado IN ('pendiente', 'listo', 'entregado')));
ALTER TABLE ventas ADD COLUMN IF NOT EXISTS entrega_fecha        DATE;   -- cuándo retira / cuándo hay que despachar
ALTER TABLE ventas ADD COLUMN IF NOT EXISTS transporte_id        INT REFERENCES transportes(id) ON DELETE SET NULL;
ALTER TABLE ventas ADD COLUMN IF NOT EXISTS envio_destinatario   TEXT CHECK (envio_destinatario IS NULL OR length(envio_destinatario) <= 120);
ALTER TABLE ventas ADD COLUMN IF NOT EXISTS envio_telefono       TEXT CHECK (envio_telefono IS NULL OR length(envio_telefono) <= 40);
ALTER TABLE ventas ADD COLUMN IF NOT EXISTS envio_direccion      TEXT CHECK (envio_direccion IS NULL OR length(envio_direccion) <= 200);
ALTER TABLE ventas ADD COLUMN IF NOT EXISTS envio_localidad      TEXT CHECK (envio_localidad IS NULL OR length(envio_localidad) <= 120);
ALTER TABLE ventas ADD COLUMN IF NOT EXISTS envio_notas          TEXT CHECK (envio_notas IS NULL OR length(envio_notas) <= 300);
ALTER TABLE ventas ADD COLUMN IF NOT EXISTS envio_bultos         INT CHECK (envio_bultos IS NULL OR envio_bultos BETWEEN 1 AND 99);
ALTER TABLE ventas ADD COLUMN IF NOT EXISTS envio_seguimiento    TEXT CHECK (envio_seguimiento IS NULL OR length(envio_seguimiento) <= 80);
ALTER TABLE ventas ADD COLUMN IF NOT EXISTS lista_en             TIMESTAMPTZ;
ALTER TABLE ventas ADD COLUMN IF NOT EXISTS lista_por_nombre     TEXT;
ALTER TABLE ventas ADD COLUMN IF NOT EXISTS entregada_en         TIMESTAMPTZ;
ALTER TABLE ventas ADD COLUMN IF NOT EXISTS entregada_por        UUID REFERENCES auth.users(id) ON DELETE SET NULL;
ALTER TABLE ventas ADD COLUMN IF NOT EXISTS entregada_por_nombre TEXT;
ALTER TABLE ventas ADD COLUMN IF NOT EXISTS recibio_nombre       TEXT CHECK (recibio_nombre IS NULL OR length(recibio_nombre) <= 120);
ALTER TABLE ventas ADD COLUMN IF NOT EXISTS recibio_dni          TEXT CHECK (recibio_dni IS NULL OR length(recibio_dni) <= 20);
CREATE INDEX IF NOT EXISTS idx_ventas_entregas ON ventas (entrega_tipo, entrega_estado, entrega_fecha)
  WHERE entrega_tipo <> 'en_el_momento' AND estado <> 'anulada';

-- Quién ve las ventas: lo de siempre (026) + quien maneja entregas ve las de retiro y envío
DROP POLICY IF EXISTS "ventas_select_staff" ON ventas;
CREATE POLICY "ventas_select_staff" ON ventas FOR SELECT
  USING (fn_tiene_permiso('ventas.ver_todas')
         OR (fn_get_user_role() IS NOT NULL AND (vendedor_id = auth.uid() OR cobrada_por = auth.uid()))
         OR (estado = 'pendiente_cobro' AND fn_tiene_permiso('caja.cobrar'))
         OR (entrega_tipo <> 'en_el_momento' AND fn_tiene_permiso('entregas.ver')));


-- ──────────────────────────────────────────────
-- 3) Definir (o corregir) la entrega de una venta
-- ──────────────────────────────────────────────
-- p_e: { tipo: 'en_el_momento'|'retiro'|'envio', fecha: 'YYYY-MM-DD',
--        transporte_id, destinatario, telefono, direccion, localidad, notas, bultos }
-- NULL o sin "tipo" → no cambia nada.
CREATE OR REPLACE FUNCTION fn_venta_entrega_set(p_venta_id BIGINT, p_e JSONB)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_tipo  TEXT := p_e->>'tipo';
  v_fecha DATE;
  v_tr    INT;
  v_dir   TEXT := nullif(left(btrim(coalesce(p_e->>'direccion', '')), 200), '');
  v_loc   TEXT := nullif(left(btrim(coalesce(p_e->>'localidad', '')), 120), '');
  v_hoy   DATE := (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date;
BEGIN
  IF p_e IS NULL OR jsonb_typeof(p_e) <> 'object' OR v_tipo IS NULL THEN RETURN; END IF;
  IF v_tipo NOT IN ('en_el_momento', 'retiro', 'envio') THEN
    RAISE EXCEPTION 'entrega_invalida' USING HINT = 'Elegí si se lo lleva ahora, retira después o es un envío.';
  END IF;
  BEGIN v_fecha := nullif(p_e->>'fecha', '')::date; EXCEPTION WHEN OTHERS THEN v_fecha := NULL; END;
  BEGIN v_tr := nullif(p_e->>'transporte_id', '')::int; EXCEPTION WHEN OTHERS THEN v_tr := NULL; END;

  IF v_tipo = 'envio' THEN
    IF v_dir IS NULL OR v_loc IS NULL THEN
      RAISE EXCEPTION 'envio_incompleto' USING HINT = 'Para un envío hacen falta la dirección y la localidad.';
    END IF;
    IF v_tr IS NOT NULL AND NOT EXISTS (SELECT 1 FROM transportes WHERE id = v_tr) THEN v_tr := NULL; END IF;
  END IF;

  UPDATE ventas SET
    entrega_tipo   = v_tipo,
    entrega_estado = CASE WHEN v_tipo = 'en_el_momento' THEN NULL ELSE 'pendiente' END,
    entrega_fecha  = CASE WHEN v_tipo = 'en_el_momento' THEN NULL ELSE coalesce(v_fecha, v_hoy) END,
    transporte_id      = CASE WHEN v_tipo = 'envio' THEN v_tr END,
    envio_destinatario = CASE WHEN v_tipo = 'envio' THEN nullif(left(btrim(coalesce(p_e->>'destinatario', '')), 120), '') END,
    envio_telefono     = CASE WHEN v_tipo = 'envio' THEN nullif(left(btrim(coalesce(p_e->>'telefono', '')), 40), '') END,
    envio_direccion    = CASE WHEN v_tipo = 'envio' THEN v_dir END,
    envio_localidad    = CASE WHEN v_tipo = 'envio' THEN v_loc END,
    envio_notas        = CASE WHEN v_tipo <> 'en_el_momento' THEN nullif(left(btrim(coalesce(p_e->>'notas', '')), 300), '') END,
    envio_bultos       = CASE WHEN v_tipo = 'envio' THEN nullif(greatest(least(coalesce(nullif(regexp_replace(coalesce(p_e->>'bultos', ''), '\D', '', 'g'), '')::int, 0), 99), 0), 0) END,
    lista_en = NULL, lista_por_nombre = NULL
  WHERE id = p_venta_id;
END;
$$;
REVOKE ALL ON FUNCTION fn_venta_entrega_set(BIGINT, JSONB) FROM PUBLIC, anon, authenticated;

-- Corregir la entrega después (quien vendió, o quien maneja entregas). No si ya salió.
CREATE OR REPLACE FUNCTION venta_entrega_guardar(p_venta_id BIGINT, p_e JSONB)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v ventas%ROWTYPE;
BEGIN
  SELECT * INTO v FROM ventas WHERE id = p_venta_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'venta_no_encontrada'; END IF;
  IF NOT (fn_tiene_permiso('entregas.gestionar') OR (fn_tiene_permiso('ventas.crear') AND v.vendedor_id = auth.uid())) THEN
    RAISE EXCEPTION 'sin_permiso' USING HINT = 'Tu usuario no puede cambiar la entrega de esta venta.';
  END IF;
  IF v.estado = 'anulada' THEN RAISE EXCEPTION 'venta_anulada' USING HINT = 'La venta está anulada.'; END IF;
  IF v.entrega_estado = 'entregado' THEN
    RAISE EXCEPTION 'ya_entregada' USING HINT = 'Esa venta ya salió: no se puede cambiar la entrega.';
  END IF;
  IF p_e IS NULL OR p_e->>'tipo' IS NULL THEN RAISE EXCEPTION 'entrega_invalida' USING HINT = 'Elegí el tipo de entrega.'; END IF;
  PERFORM fn_venta_entrega_set(p_venta_id, p_e);
  RETURN jsonb_build_object('ok', true, 'id', p_venta_id);
END;
$$;

-- venta_registrar: toma p->'entrega' (un solo punto de la función instalada)
DO $migr$
DECLARE
  v_def   TEXT := pg_get_functiondef('venta_registrar(jsonb)'::regprocedure);
  v_antes TEXT := $a$  INSERT INTO historial_actividad (accion, entidad, entidad_id, descripcion, usuario_id)
  VALUES ('venta', 'ventas', v_venta_id::text,$a$;
BEGIN
  IF position('fn_venta_entrega_set' IN v_def) > 0 THEN
    RAISE NOTICE '027: venta_registrar ya toma la entrega';
  ELSIF position(v_antes IN v_def) = 0 THEN
    RAISE EXCEPTION '027: no encontré en venta_registrar el punto esperado. Revisar esa función antes de seguir.';
  ELSE
    EXECUTE replace(v_def, v_antes, $b$  -- 027: cómo se entrega (se lo lleva / retira después / envío)
  PERFORM fn_venta_entrega_set(v_venta_id, p->'entrega');

$b$ || v_antes);
  END IF;
END
$migr$;


-- ──────────────────────────────────────────────
-- 4) Marcar listas, entregar / despachar, deshacer
-- ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION venta_entrega_lista(p_ids BIGINT[], p_lista BOOLEAN DEFAULT true)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_n INT;
BEGIN
  IF NOT fn_tiene_permiso('entregas.gestionar') THEN
    RAISE EXCEPTION 'sin_permiso' USING HINT = 'Tu usuario no puede preparar entregas.';
  END IF;
  UPDATE ventas SET entrega_estado = CASE WHEN p_lista THEN 'listo' ELSE 'pendiente' END,
                    lista_en = CASE WHEN p_lista THEN now() END,
                    lista_por_nombre = CASE WHEN p_lista THEN fn_mi_nombre() END
  WHERE id = ANY (p_ids) AND estado <> 'anulada' AND entrega_tipo <> 'en_el_momento'
    AND entrega_estado = CASE WHEN p_lista THEN 'pendiente' ELSE 'listo' END;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN jsonb_build_object('ok', true, 'cambiadas', v_n);
END;
$$;

-- p_datos: { recibio_nombre, recibio_dni }  (retiro)
--          { seguimientos: { "<venta_id>": "N° de guía" } }  (despacho de varios envíos)
-- Todo o nada: si una no se puede entregar (sin pagar, anulada…), no sale ninguna y dice cuál.
CREATE OR REPLACE FUNCTION venta_entregar(p_ids BIGINT[], p_datos JSONB DEFAULT '{}'::jsonb)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v      ventas%ROWTYPE;
  v_id   BIGINT;
  v_n    INT := 0;
  v_nom  TEXT := nullif(left(btrim(coalesce(p_datos->>'recibio_nombre', '')), 120), '');
  v_dni  TEXT := nullif(left(regexp_replace(coalesce(p_datos->>'recibio_dni', ''), '[^0-9A-Za-z.\-]', '', 'g'), 20), '');
  v_yo   TEXT := fn_mi_nombre();
BEGIN
  IF NOT fn_tiene_permiso('entregas.gestionar') THEN
    RAISE EXCEPTION 'sin_permiso' USING HINT = 'Tu usuario no puede entregar ni despachar.';
  END IF;
  IF p_ids IS NULL OR cardinality(p_ids) = 0 OR cardinality(p_ids) > 200 THEN
    RAISE EXCEPTION 'seleccion_invalida' USING HINT = 'Elegí qué entregar.';
  END IF;

  FOREACH v_id IN ARRAY p_ids LOOP
    SELECT * INTO v FROM ventas WHERE id = v_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'venta_no_encontrada'; END IF;
    IF v.entrega_tipo = 'en_el_momento' THEN
      RAISE EXCEPTION 'sin_entrega' USING HINT = format('La venta %s no tiene retiro ni envío pendiente.', v.codigo);
    END IF;
    IF v.estado = 'anulada' THEN
      RAISE EXCEPTION 'venta_anulada' USING HINT = format('La venta %s está anulada: no se entrega.', v.codigo);
    END IF;
    IF v.estado <> 'cerrada' THEN
      RAISE EXCEPTION 'sin_pagar' USING HINT = format('La venta %s todavía no se cobró en la caja: no puede salir.', v.codigo);
    END IF;
    IF v.entrega_estado = 'entregado' THEN CONTINUE; END IF;      -- ya había salido: no se pisa

    UPDATE ventas SET
      entrega_estado = 'entregado', entregada_en = now(), entregada_por = auth.uid(), entregada_por_nombre = v_yo,
      recibio_nombre = CASE WHEN v.entrega_tipo = 'retiro' THEN coalesce(v_nom, v.retira_nombre, v.cliente_nombre) ELSE v.envio_destinatario END,
      recibio_dni    = CASE WHEN v.entrega_tipo = 'retiro' THEN v_dni END,
      envio_seguimiento = CASE WHEN v.entrega_tipo = 'envio'
                               THEN coalesce(nullif(left(btrim(coalesce(p_datos->'seguimientos'->>(v.id::text), '')), 80), ''), v.envio_seguimiento) END
    WHERE id = v.id;
    v_n := v_n + 1;

    INSERT INTO historial_actividad (accion, entidad, entidad_id, descripcion, usuario_id)
    VALUES ('entregar', 'ventas', v.id::text,
            CASE WHEN v.entrega_tipo = 'retiro'
                 THEN format('Entregó la venta %s a %s', v.codigo, coalesce(v_nom, v.retira_nombre, v.cliente_nombre, 'quien retira'))
                 ELSE format('Despachó la venta %s', v.codigo) END, auth.uid());
  END LOOP;
  RETURN jsonb_build_object('ok', true, 'entregadas', v_n);
END;
$$;

-- Se marcó por error: vuelve a "pendiente" (con motivo)
CREATE OR REPLACE FUNCTION venta_entrega_deshacer(p_venta_id BIGINT, p_motivo TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v     ventas%ROWTYPE;
  v_mot TEXT := nullif(btrim(coalesce(p_motivo, '')), '');
BEGIN
  IF NOT fn_tiene_permiso('entregas.gestionar') THEN
    RAISE EXCEPTION 'sin_permiso' USING HINT = 'Tu usuario no puede cambiar entregas.';
  END IF;
  IF v_mot IS NULL THEN RAISE EXCEPTION 'motivo_requerido' USING HINT = 'Escribí por qué se deshace la entrega.'; END IF;
  SELECT * INTO v FROM ventas WHERE id = p_venta_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'venta_no_encontrada'; END IF;
  IF v.entrega_estado IS DISTINCT FROM 'entregado' THEN
    RETURN jsonb_build_object('ok', true, 'sin_cambios', true);
  END IF;
  UPDATE ventas SET entrega_estado = 'pendiente', entregada_en = NULL, entregada_por = NULL, entregada_por_nombre = NULL,
                    recibio_nombre = NULL, recibio_dni = NULL, lista_en = NULL, lista_por_nombre = NULL
  WHERE id = v.id;
  INSERT INTO historial_actividad (accion, entidad, entidad_id, descripcion, usuario_id)
  VALUES ('actualizar', 'ventas', v.id::text, format('Deshizo la entrega de %s: %s', v.codigo, left(v_mot, 120)), auth.uid());
  RETURN jsonb_build_object('ok', true, 'id', v.id);
END;
$$;

REVOKE ALL ON FUNCTION venta_entrega_guardar(BIGINT, JSONB)   FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION venta_entrega_lista(BIGINT[], BOOLEAN) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION venta_entregar(BIGINT[], JSONB)        FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION venta_entrega_deshacer(BIGINT, TEXT)   FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION venta_entrega_guardar(BIGINT, JSONB)   TO authenticated;
GRANT EXECUTE ON FUNCTION venta_entrega_lista(BIGINT[], BOOLEAN) TO authenticated;
GRANT EXECUTE ON FUNCTION venta_entregar(BIGINT[], JSONB)        TO authenticated;
GRANT EXECUTE ON FUNCTION venta_entrega_deshacer(BIGINT, TEXT)   TO authenticated;

NOTIFY pgrst, 'reload schema';

SELECT (SELECT count(*) FROM transportes) AS transportes,
       (SELECT count(*) FROM ventas WHERE entrega_tipo <> 'en_el_momento' AND estado <> 'anulada' AND entrega_estado <> 'entregado') AS entregas_pendientes;
