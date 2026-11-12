-- ============================================================
-- 030 — HISTORIAL DE CAMBIOS (auditoría) (2026-11-12)
-- Ejecutar DESPUÉS del 029. Idempotente.
--
-- Para saber quién hizo qué y cuándo, sobre todo lo delicado: precios,
-- anulaciones, devoluciones, ajustes de stock, movimientos de caja a mano,
-- diferencias de caja, cambios de permisos, de usuarios y de cuentas bancarias.
--
-- • Lo registra la BASE DE DATOS (triggers), no el navegador: no se puede
--   saltear usando el panel ni por fuera de él.
-- • Nadie lo puede editar ni borrar (tampoco un administrador desde el panel).
-- • Lo ve solo quien tenga el permiso "Ver el historial" (de entrada, solo
--   el administrador).
-- • Guarda solo lo que cambió (antes → después), no la fila entera.
-- • Lo automático y repetitivo (cada venta descontando stock, cada cobro
--   asentado en la caja) NO se registra acá: ya queda en sus propios
--   movimientos. Sí se registran las altas de ventas y todo cambio a mano.
-- ============================================================

-- 1) Permiso
INSERT INTO permisos (clave, modulo, nombre, descripcion, orden)
VALUES ('auditoria.ver', 'Administración', 'Ver el historial de cambios',
        'Quién cambió qué y cuándo: precios, anulaciones, stock, caja, permisos, usuarios.', 990)
ON CONFLICT (clave) DO NOTHING;
UPDATE permisos SET iniciales_aplicados = true WHERE clave = 'auditoria.ver';   -- nadie más que el admin de entrada

-- 2) La tabla
CREATE TABLE IF NOT EXISTS auditoria (
  id             BIGSERIAL PRIMARY KEY,
  fecha          TIMESTAMPTZ NOT NULL DEFAULT now(),
  usuario_id     UUID,
  usuario_nombre TEXT,
  tabla          TEXT NOT NULL,
  registro_id    TEXT,
  registro       TEXT,            -- cómo se llama lo que cambió (producto, venta, persona…)
  operacion      TEXT NOT NULL CHECK (operacion IN ('alta', 'cambio', 'baja')),
  tipo           TEXT NOT NULL,   -- para filtrar: ventas, caja, stock, precios, productos, usuarios, pedidos, cc, config, compras
  sensible       BOOLEAN NOT NULL DEFAULT false,
  cambios        JSONB NOT NULL DEFAULT '{}'::jsonb   -- {columna: [antes, después]}
);
CREATE INDEX IF NOT EXISTS idx_auditoria_fecha   ON auditoria (fecha DESC);
CREATE INDEX IF NOT EXISTS idx_auditoria_usuario ON auditoria (usuario_id, fecha DESC);
CREATE INDEX IF NOT EXISTS idx_auditoria_tipo    ON auditoria (tipo, fecha DESC);
CREATE INDEX IF NOT EXISTS idx_auditoria_sens    ON auditoria (fecha DESC) WHERE sensible;
CREATE INDEX IF NOT EXISTS idx_auditoria_reg     ON auditoria (tabla, registro_id);

ALTER TABLE auditoria ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auditoria_select" ON auditoria;
CREATE POLICY "auditoria_select" ON auditoria FOR SELECT USING (fn_tiene_permiso('auditoria.ver'));
REVOKE ALL ON auditoria FROM anon;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON auditoria FROM authenticated;
GRANT SELECT ON auditoria TO authenticated;

-- Ni editar ni borrar, venga de donde venga
CREATE OR REPLACE FUNCTION fn_auditoria_inmutable()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'historial_inmutable' USING HINT = 'El historial no se modifica ni se borra.';
END;
$$;
DROP TRIGGER IF EXISTS tr_auditoria_inmutable ON auditoria;
CREATE TRIGGER tr_auditoria_inmutable BEFORE UPDATE OR DELETE ON auditoria
  FOR EACH ROW EXECUTE FUNCTION fn_auditoria_inmutable();
DROP TRIGGER IF EXISTS tr_auditoria_no_truncate ON auditoria;
CREATE TRIGGER tr_auditoria_no_truncate BEFORE TRUNCATE ON auditoria
  FOR EACH STATEMENT EXECUTE FUNCTION fn_auditoria_inmutable();


-- 3) El registrador (uno solo para todas las tablas)
--    TG_ARGV: [0] columna id · [1] columna con el nombre · [2] columnas que no
--    interesan, separadas por coma · [3] tipo
CREATE OR REPLACE FUNCTION fn_auditar()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_old  JSONB := CASE WHEN TG_OP <> 'INSERT' THEN to_jsonb(OLD) END;
  v_new  JSONB := CASE WHEN TG_OP <> 'DELETE' THEN to_jsonb(NEW) END;
  v_fila JSONB := coalesce(v_new, v_old);
  v_fuera TEXT[] := string_to_array(coalesce(TG_ARGV[2], ''), ',') || ARRAY['updated_at', 'created_at'];
  v_tipo TEXT := TG_ARGV[3];
  v_camb JSONB := '{}'::jsonb;
  v_sens BOOLEAN := false;
  v_op   TEXT := CASE TG_OP WHEN 'INSERT' THEN 'alta' WHEN 'DELETE' THEN 'baja' ELSE 'cambio' END;
  k      TEXT;
  v_reg  TEXT;
  v_idc  TEXT := coalesce(nullif(TG_ARGV[0], ''), 'id');
  v_marca TEXT;
BEGIN
  v_marca := '|' || TG_TABLE_NAME || ':' || (coalesce(v_new, v_old) ->> v_idc) || '|';
  IF TG_OP = 'INSERT' AND TG_WHEN = 'AFTER' AND coalesce(TG_ARGV[4], '') = 'marcar' THEN
    -- Fila nueva: se anota para no registrar los retoques de esta misma operación
    -- (el alta se registra al final, con la fila ya completa: trigger diferido)
    PERFORM set_config('mh.aud_nuevos', coalesce(current_setting('mh.aud_nuevos', true), '') || v_marca, true);
    RETURN NULL;
  END IF;
  IF TG_OP IN ('UPDATE', 'DELETE') AND position(v_marca IN coalesce(current_setting('mh.aud_nuevos', true), '')) > 0 THEN
    RETURN NULL;   -- se creó en esta misma operación: queda como un alta (o no queda, si se borró)
  END IF;
  IF TG_OP = 'INSERT' AND TG_TABLE_NAME <> 'rol_permisos' THEN
    EXECUTE format('SELECT to_jsonb(x) FROM %I x WHERE %I::text = $1', TG_TABLE_NAME, v_idc) USING v_new ->> v_idc INTO v_new;
    IF v_new IS NULL THEN RETURN NULL; END IF;   -- se creó y se borró en la misma operación
    v_fila := v_new;
  END IF;
  -- Lo automático no se registra (ya queda en sus propios movimientos)
  IF TG_OP = 'INSERT' AND (
       (TG_TABLE_NAME = 'caja_movimientos' AND (v_new ->> 'venta_id' IS NOT NULL OR v_new ->> 'origen' IN ('venta', 'cierre', 'cobro_cc')))
    OR (TG_TABLE_NAME = 'movimientos_inventario' AND v_new ->> 'tipo' IN ('salida_venta', 'devolucion_cliente', 'entrada_compra', 'carga_inicial'))
    OR (TG_TABLE_NAME = 'cc_movimientos' AND v_new ->> 'tipo' IN ('cargo', 'devolucion') AND v_new ->> 'venta_id' IS NOT NULL)
    OR (TG_TABLE_NAME = 'movimientos_cobro' AND v_new ->> 'venta_id' IS NOT NULL)) THEN
    RETURN NULL;
  END IF;

  IF TG_OP = 'UPDATE' THEN
    FOR k IN SELECT jsonb_object_keys(v_new) LOOP
      CONTINUE WHEN k = ANY (v_fuera);
      IF v_new -> k IS DISTINCT FROM v_old -> k THEN
        v_camb := v_camb || jsonb_build_object(k, jsonb_build_array(v_old -> k, v_new -> k));
      END IF;
    END LOOP;
    IF v_camb = '{}'::jsonb THEN RETURN NULL; END IF;
  ELSE
    -- Alta o baja: la foto de la fila (sin lo que no interesa)
    FOR k IN SELECT jsonb_object_keys(v_fila) LOOP
      CONTINUE WHEN k = ANY (v_fuera) OR v_fila -> k = 'null'::jsonb;
      v_camb := v_camb || jsonb_build_object(k, CASE WHEN TG_OP = 'INSERT' THEN jsonb_build_array(NULL, v_fila -> k)
                                                     ELSE jsonb_build_array(v_fila -> k, NULL) END);
    END LOOP;
  END IF;

  -- Qué es delicado
  v_sens := CASE TG_TABLE_NAME
    WHEN 'productos' THEN TG_OP = 'DELETE' OR (TG_OP = 'UPDATE' AND (v_camb ?| ARRAY['precio_minorista','precio_mayorista','precio_oferta','precio_costo','en_oferta','descuento_porcentaje','estado']))
    WHEN 'ventas' THEN TG_OP = 'DELETE' OR (TG_OP = 'UPDATE' AND (
                         (v_camb ? 'estado' AND v_new ->> 'estado' = 'anulada')
                      OR (v_camb ? 'total' AND (v_new ->> 'total')::numeric < (v_old ->> 'total')::numeric)
                      OR (v_camb ? 'entrega_estado' AND v_old ->> 'entrega_estado' = 'entregado')
                      OR (v_camb ? 'descuento')
                      OR (v_camb ? 'devuelta_motivo' AND v_new ->> 'devuelta_motivo' IS NOT NULL)))
    WHEN 'caja_movimientos' THEN (TG_OP = 'INSERT' AND v_new ->> 'tipo' = 'egreso') OR (TG_OP = 'UPDATE' AND v_camb ? 'anulado') OR TG_OP = 'DELETE'
    WHEN 'caja_sesiones' THEN TG_OP = 'UPDATE' AND v_camb ? 'diferencia' AND coalesce((v_new ->> 'diferencia')::numeric, 0) <> 0
    WHEN 'movimientos_inventario' THEN true
    WHEN 'cc_movimientos' THEN (v_new ->> 'tipo') IN ('ajuste_debito', 'ajuste_credito', 'pago_anulado') OR (TG_OP = 'UPDATE' AND v_camb ? 'anulado')
    WHEN 'cc_cuentas' THEN v_camb ?| ARRAY['limite', 'habilitada', 'dia_pago']
    WHEN 'movimientos_cobro' THEN v_new ->> 'tipo' = 'anulacion'
    WHEN 'categorias' THEN v_camb ? 'recargo_cc' OR TG_OP = 'DELETE'
    WHEN 'profiles' THEN v_camb ?| ARRAY['rol', 'activo'] OR TG_OP = 'DELETE'
    WHEN 'rol_permisos' THEN true
    WHEN 'cuentas_cobro' THEN true
    WHEN 'site_settings' THEN true
    WHEN 'solicitudes' THEN TG_OP = 'DELETE' OR (v_camb ? 'estado_pago' AND v_old ->> 'estado_pago' = 'pagado')
    ELSE false END;
  IF TG_TABLE_NAME = 'productos' AND v_camb ?| ARRAY['precio_minorista','precio_mayorista','precio_oferta','precio_costo','en_oferta','descuento_porcentaje'] THEN
    v_tipo := 'precios';
  END IF;

  v_reg := CASE WHEN TG_ARGV[1] IS NOT NULL AND TG_ARGV[1] <> '' THEN v_fila ->> TG_ARGV[1] END;
  IF TG_TABLE_NAME = 'movimientos_inventario' THEN
    SELECT nombre INTO v_reg FROM productos WHERE id = (v_fila ->> 'producto_id')::int;
  ELSIF TG_TABLE_NAME IN ('cc_movimientos', 'cc_cuentas') THEN
    SELECT c.nombre INTO v_reg FROM cc_cuentas a JOIN crm_contactos c ON c.id = a.contacto_id
     WHERE a.id = (v_fila ->> CASE TG_TABLE_NAME WHEN 'cc_cuentas' THEN 'id' ELSE 'cuenta_id' END)::bigint;
  ELSIF TG_TABLE_NAME = 'rol_permisos' THEN
    SELECT nombre INTO v_reg FROM permisos WHERE clave = v_fila ->> 'permiso';
    v_reg := coalesce(v_reg, v_fila ->> 'permiso') || ' · ' || (v_fila ->> 'rol');
  ELSIF TG_TABLE_NAME = 'caja_movimientos' THEN
    v_reg := concat_ws(' · ', v_fila ->> 'concepto_nombre', v_fila ->> 'descripcion');
  ELSIF TG_TABLE_NAME = 'movimientos_cobro' THEN
    SELECT nombre INTO v_reg FROM cuentas_cobro WHERE id = (v_fila ->> 'cuenta_cobro_id')::bigint;
  END IF;

  INSERT INTO auditoria (usuario_id, usuario_nombre, tabla, registro_id, registro, operacion, tipo, sensible, cambios)
  VALUES (auth.uid(), coalesce(fn_mi_nombre(), CASE WHEN auth.uid() IS NULL THEN 'Sistema' END),
          TG_TABLE_NAME, v_fila ->> coalesce(nullif(TG_ARGV[0], ''), 'id'), left(v_reg, 200),
          v_op, v_tipo, coalesce(v_sens, false), v_camb);
  RETURN NULL;
END;
$$;
REVOKE ALL ON FUNCTION fn_auditar() FROM PUBLIC, anon, authenticated;


-- 4) Qué tablas se registran
DO $t$
DECLARE r RECORD;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    -- tabla,                  id,        nombre,             columnas que no interesan,                                                              tipo
    ('productos',              'id',      'nombre',           'stock_actual,stock_controlado_en,ultimo_conteo_en,updated_by,mas_vendido,orden',      'productos'),
    ('ventas',                 'id',      'codigo',           'items_count,unidades,stock_afectado,editada_en,ediciones,lista_en,cobrada_por,anulada_por,entregada_por', 'ventas'),
    ('caja_movimientos',       'id',      '',                 'anulado_por,usuario_id',                                                               'caja'),
    ('caja_sesiones',          'id',      'abierta_por_nombre','abierta_por,cerrada_por',                                                             'caja'),
    ('movimientos_inventario', 'id',      '',                 'usuario_id',                                                                           'stock'),
    ('cc_movimientos',         'id',      '',                 'usuario_id,anulado_por,caja_movimiento_id',                                            'cc'),
    ('cc_cuentas',             'id',      '',                 'saldo,created_by',                                                                     'cc'),
    ('movimientos_cobro',      'id',      '',                 'usuario_id',                                                                           'caja'),
    ('categorias',             'id',      'nombre',           'orden,imagen_url,slug',                                                                'productos'),
    ('profiles',               'id',      'nombre',           'ultimo_acceso,avatar_url,debe_cambiar_clave',                                          'usuarios'),
    ('rol_permisos',           'permiso', '',                 'created_by',                                                                           'usuarios'),
    ('cuentas_cobro',          'id',      'nombre',           'orden',                                                                                'config'),
    ('site_settings',          'id',      'nombre_tienda',    '',                                                                                     'config'),
    ('solicitudes',            'id',      'codigo',           'tenant_id,atendido_por,stock_descontado,tiene_pendientes',                             'pedidos'),
    ('compras',                'id',      'codigo',           'total_items,total_unidades,created_by',                                                'compras'),
    ('transportes',            'id',      'nombre',           'orden',                                                                                'config'),
    ('ubicaciones',            'id',      'lugar',            'orden',                                                                                'config'),
    ('caja_conceptos',         'id',      'nombre',           'orden',                                                                                'config')
  ) AS x(tabla, id, nombre, fuera, tipo) LOOP
    IF to_regclass('public.' || r.tabla) IS NULL THEN RAISE NOTICE 'auditoría: no existe %, se saltea', r.tabla; CONTINUE; END IF;
    EXECUTE format('DROP TRIGGER IF EXISTS tr_auditar ON %I', r.tabla);
    EXECUTE format('DROP TRIGGER IF EXISTS tr_auditar_nuevo ON %I', r.tabla);
    EXECUTE format('DROP TRIGGER IF EXISTS tr_auditar_alta ON %I', r.tabla);
    EXECUTE format('CREATE TRIGGER tr_auditar AFTER UPDATE OR DELETE ON %I FOR EACH ROW EXECUTE FUNCTION fn_auditar(%L, %L, %L, %L)',
                   r.tabla, r.id, r.nombre, r.fuera, r.tipo);
    IF r.tabla = 'rol_permisos' THEN   -- sin id propio: el alta se registra en el momento
      EXECUTE format('CREATE TRIGGER tr_auditar_alta AFTER INSERT ON %I FOR EACH ROW EXECUTE FUNCTION fn_auditar(%L, %L, %L, %L)',
                     r.tabla, r.id, r.nombre, r.fuera, r.tipo);
    ELSE
      EXECUTE format('CREATE TRIGGER tr_auditar_nuevo AFTER INSERT ON %I FOR EACH ROW EXECUTE FUNCTION fn_auditar(%L, %L, %L, %L, %L)',
                     r.tabla, r.id, r.nombre, r.fuera, r.tipo, 'marcar');
      EXECUTE format('CREATE CONSTRAINT TRIGGER tr_auditar_alta AFTER INSERT ON %I DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_auditar(%L, %L, %L, %L)',
                     r.tabla, r.id, r.nombre, r.fuera, r.tipo);
    END IF;
  END LOOP;
END
$t$;

NOTIFY pgrst, 'reload schema';

SELECT (SELECT count(*) FROM pg_trigger WHERE tgname = 'tr_auditar') AS tablas_registradas;
