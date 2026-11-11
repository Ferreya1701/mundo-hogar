-- ============================================================
-- 020 — EDITAR UNA VENTA: QUITAR PRODUCTOS (2026-11-11)
-- Ejecutar en Supabase → SQL Editor, DESPUÉS del 019.
-- Idempotente: se puede correr más de una vez sin romper nada.
--
-- Caso: la vendedora ya hizo la venta (por ejemplo, un cliente de cuenta
-- corriente pidió por teléfono) y al final el cliente no se lleva todo.
-- En vez de anular y rehacer, se QUITAN productos o unidades:
--
--   • El stock de lo quitado vuelve (si el producto descontaba stock).
--   • El total se recalcula (el descuento se mantiene, sin pasar el
--     nuevo subtotal; el recargo de cuenta corriente baja con lo quitado).
--   • La plata se acomoda sola con los mismos disparadores del 018/019:
--       - venta cobrada (efectivo, transferencia, tarjeta…): sale de la
--         caja la devolución por la diferencia, por el mismo medio;
--       - venta en cuenta corriente: baja la deuda del cliente.
--   • Queda registrado QUÉ se quitó, cuánto, quién, cuándo y por qué
--     (venta_ediciones) y la venta se marca como "modificada".
--   • No se puede agregar ni cambiar precios (eso es una venta nueva) ni
--     dejar la venta vacía (para eso está anular).
--
-- Permisos nuevos: ventas.editar_propias (sus ventas de las últimas
-- 24 h) y ventas.editar_todas.
-- ============================================================


-- ──────────────────────────────────────────────
-- 1) Permisos
-- ──────────────────────────────────────────────
CREATE TEMP TABLE _permisos_020 (clave TEXT, modulo TEXT, nombre TEXT, descripcion TEXT, orden INT, roles TEXT[]) ON COMMIT DROP;
INSERT INTO _permisos_020 VALUES
  ('ventas.editar_propias', 'Ventas', 'Quitar productos de sus ventas (hasta 24 h)',
     'Sacar productos o unidades que el cliente al final no se llevó, en ventas propias de las últimas 24 horas.', 32, ARRAY['vendedor','encargado_stock']),
  ('ventas.editar_todas',   'Ventas', 'Quitar productos de cualquier venta',
     'Sacar productos de ventas de otros o de más de 24 horas.',                                                42, ARRAY[]::TEXT[]);

INSERT INTO permisos (clave, modulo, nombre, descripcion, orden)
SELECT clave, modulo, nombre, descripcion, orden FROM _permisos_020
ON CONFLICT (clave) DO UPDATE SET
  modulo = EXCLUDED.modulo, nombre = EXCLUDED.nombre,
  descripcion = EXCLUDED.descripcion, orden = EXCLUDED.orden;

INSERT INTO rol_permisos (rol, permiso)
SELECT unnest(n.roles), n.clave
FROM _permisos_020 n JOIN permisos p ON p.clave = n.clave
WHERE NOT p.iniciales_aplicados
ON CONFLICT DO NOTHING;

UPDATE permisos SET iniciales_aplicados = true
WHERE clave IN (SELECT clave FROM _permisos_020) AND NOT iniciales_aplicados;


-- ──────────────────────────────────────────────
-- 2) Columnas y registro de ediciones
-- ──────────────────────────────────────────────
-- Un renglón puede quedar en 0 (se quitó todo): se conserva para ver qué se vendió y qué se sacó
ALTER TABLE venta_items DROP CONSTRAINT IF EXISTS venta_items_cantidad_check;
ALTER TABLE venta_items ADD CONSTRAINT venta_items_cantidad_check CHECK (cantidad BETWEEN 0 AND 9999);
ALTER TABLE venta_items ADD COLUMN IF NOT EXISTS cantidad_original INT;

ALTER TABLE ventas ADD COLUMN IF NOT EXISTS editada_en TIMESTAMPTZ;
ALTER TABLE ventas ADD COLUMN IF NOT EXISTS ediciones  INT NOT NULL DEFAULT 0;

CREATE TABLE IF NOT EXISTS venta_ediciones (
  id              BIGSERIAL PRIMARY KEY,
  venta_id        BIGINT NOT NULL REFERENCES ventas(id),
  fecha           TIMESTAMPTZ NOT NULL DEFAULT now(),
  usuario_id      UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  usuario_nombre  TEXT,
  motivo          TEXT NOT NULL CHECK (length(btrim(motivo)) BETWEEN 1 AND 300),
  -- [{ item_id, producto_id, nombre, quitadas, precio_unitario, importe, stock_devuelto }]
  detalle         JSONB NOT NULL,
  total_anterior  NUMERIC(12,2) NOT NULL,
  total_nuevo     NUMERIC(12,2) NOT NULL,
  diferencia      NUMERIC(12,2) NOT NULL       -- lo que se devolvió o se descontó de la cuenta
);
CREATE INDEX IF NOT EXISTS idx_venta_ediciones_venta ON venta_ediciones (venta_id, fecha);

ALTER TABLE venta_ediciones ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "venta_ediciones_select" ON venta_ediciones;
-- Se ven si se ve la venta (la subconsulta respeta la política de ventas)
CREATE POLICY "venta_ediciones_select" ON venta_ediciones FOR SELECT
  USING (EXISTS (SELECT 1 FROM ventas v WHERE v.id = venta_ediciones.venta_id));
REVOKE ALL ON venta_ediciones FROM anon;
REVOKE INSERT, UPDATE, DELETE ON venta_ediciones FROM authenticated;
GRANT SELECT ON venta_ediciones TO authenticated;


-- ──────────────────────────────────────────────
-- 3) Anular una venta ya editada: no reponer renglones en 0
-- ──────────────────────────────────────────────
DO $migr$
DECLARE
  v_def    TEXT := pg_get_functiondef('venta_anular(bigint,text)'::regprocedure);
  v_antes  TEXT := 'WHERE venta_id = v_v.id AND afecto_stock AND producto_id IS NOT NULL LOOP';
  v_despues TEXT := 'WHERE venta_id = v_v.id AND afecto_stock AND producto_id IS NOT NULL AND cantidad > 0 LOOP';
BEGIN
  IF position(v_despues IN v_def) > 0 THEN
    NULL;   -- ya estaba
  ELSIF position(v_antes IN v_def) > 0 THEN
    EXECUTE replace(v_def, v_antes, v_despues);
  ELSE
    RAISE EXCEPTION '020: no encontré el recorrido de renglones esperado en venta_anular. Revisar esa función antes de seguir.';
  END IF;
END
$migr$;


-- ──────────────────────────────────────────────
-- 4) Quitar productos
-- ──────────────────────────────────────────────
-- p_items: [{ "item_id": 12, "quitar": 1 }, ...]   (quitar = unidades a sacar)
CREATE OR REPLACE FUNCTION venta_quitar_items(p_venta_id BIGINT, p_items JSONB, p_motivo TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v        ventas%ROWTYPE;
  v_it     venta_items%ROWTYPE;
  v_req    JSONB;
  v_q      INT;
  v_mot    TEXT := nullif(btrim(coalesce(p_motivo, '')), '');
  v_det    JSONB := '[]'::jsonb;
  v_sub    NUMERIC(12,2);
  v_desc   NUMERIC(12,2);
  v_total  NUMERIC(12,2);
  v_quien  TEXT;
  v_n      INT := 0;
  v_out    JSONB;
BEGIN
  IF NOT (fn_tiene_permiso('ventas.editar_propias') OR fn_tiene_permiso('ventas.editar_todas')) THEN
    RAISE EXCEPTION 'sin_permiso' USING HINT = 'Tu usuario no puede modificar ventas.';
  END IF;
  IF v_mot IS NULL THEN
    RAISE EXCEPTION 'motivo_requerido' USING HINT = 'Escribí por qué se quitan productos (ej. el cliente no se llevó la pava).';
  END IF;
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'items_invalidos' USING HINT = 'Elegí qué productos quitar.';
  END IF;

  SELECT * INTO v FROM ventas WHERE id = p_venta_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'venta_no_encontrada'; END IF;
  IF v.estado <> 'cerrada' THEN
    RAISE EXCEPTION 'venta_anulada' USING HINT = 'La venta está anulada: no se puede modificar.';
  END IF;
  IF NOT fn_tiene_permiso('ventas.editar_todas')
     AND (v.vendedor_id IS DISTINCT FROM auth.uid() OR v.fecha < now() - interval '24 hours') THEN
    RAISE EXCEPTION 'sin_permiso' USING HINT = 'Solo podés modificar tus ventas de las últimas 24 horas.';
  END IF;

  PERFORM set_config('mh.interno', '1', true);

  FOR v_req IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    BEGIN
      v_q := (v_req->>'quitar')::int;
    EXCEPTION WHEN OTHERS THEN v_q := NULL;
    END;
    SELECT * INTO v_it FROM venta_items WHERE id = (v_req->>'item_id')::bigint AND venta_id = v.id FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'item_no_encontrado' USING HINT = 'Uno de los productos no es de esta venta.';
    END IF;
    IF v_q IS NULL OR v_q < 0 THEN
      RAISE EXCEPTION 'cantidad_invalida' USING HINT = format('%s: cantidad a quitar inválida.', v_it.nombre);
    END IF;
    CONTINUE WHEN v_q = 0;
    IF v_q > v_it.cantidad THEN
      RAISE EXCEPTION 'cantidad_invalida' USING HINT = format('%s: se vendieron %s, no se pueden quitar %s.', v_it.nombre, v_it.cantidad, v_q);
    END IF;

    -- El stock vuelve (solo si ese renglón lo había descontado)
    IF v_it.afecto_stock AND v_it.producto_id IS NOT NULL THEN
      PERFORM fn_registrar_movimiento(v_it.producto_id, 'devolucion_cliente', v_q,
                                      'Quitado de la venta', left(v_mot, 200), v.codigo, false);
    END IF;

    UPDATE venta_items SET
      cantidad_original = coalesce(cantidad_original, cantidad),
      cantidad = cantidad - v_q,
      subtotal = round(precio_unitario * (cantidad - v_q), 2)
    WHERE id = v_it.id;

    v_det := v_det || jsonb_build_object('item_id', v_it.id, 'producto_id', v_it.producto_id, 'nombre', v_it.nombre,
                                         'quitadas', v_q, 'quedan', v_it.cantidad - v_q,
                                         'precio_unitario', v_it.precio_unitario,
                                         'importe', round(v_it.precio_unitario * v_q, 2),
                                         'stock_devuelto', v_it.afecto_stock AND v_it.producto_id IS NOT NULL);
    v_n := v_n + 1;
  END LOOP;

  IF v_n = 0 THEN
    RAISE EXCEPTION 'items_invalidos' USING HINT = 'Elegí al menos una unidad para quitar.';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM venta_items WHERE venta_id = v.id AND cantidad > 0) THEN
    RAISE EXCEPTION 'venta_vacia' USING HINT = 'Si el cliente no se lleva nada, anulá la venta.';
  END IF;

  SELECT coalesce(sum(subtotal), 0) INTO v_sub FROM venta_items WHERE venta_id = v.id;
  v_desc  := least(v.descuento, v_sub);
  v_total := round(v_sub - v_desc, 2);

  -- Al cambiar el total, los disparadores del 018/019 devuelven la diferencia
  -- (caja por el mismo medio, o baja de la deuda en cuenta corriente).
  UPDATE ventas SET
    subtotal = v_sub, descuento = v_desc, total = v_total,
    items_count = (SELECT count(*) FROM venta_items WHERE venta_id = v.id AND cantidad > 0),
    unidades = (SELECT coalesce(sum(cantidad), 0) FROM venta_items WHERE venta_id = v.id),
    recargo_total = (SELECT coalesce(sum(recargo_unitario * cantidad), 0) FROM venta_items WHERE venta_id = v.id),
    editada_en = now(), ediciones = ediciones + 1
  WHERE id = v.id;

  SELECT nombre INTO v_quien FROM profiles WHERE id = auth.uid();
  INSERT INTO venta_ediciones (venta_id, usuario_id, usuario_nombre, motivo, detalle, total_anterior, total_nuevo, diferencia)
  VALUES (v.id, auth.uid(), v_quien, left(v_mot, 300), v_det, v.total, v_total, v.total - v_total);

  INSERT INTO historial_actividad (accion, entidad, entidad_id, descripcion, usuario_id, valores_anteriores, valores_nuevos)
  VALUES ('actualizar', 'ventas', v.id::text,
          format('Venta %s: se quitaron productos (%s → %s): %s', v.codigo,
                 to_char(v.total, 'FM999G999G990D00'), to_char(v_total, 'FM999G999G990D00'), left(v_mot, 120)),
          auth.uid(), jsonb_build_object('total', v.total), jsonb_build_object('total', v_total, 'quitado', v_det));

  SELECT jsonb_build_object('ok', true, 'id', x.id, 'codigo', x.codigo, 'fecha', x.fecha,
           'total_anterior', v.total, 'total', x.total, 'diferencia', v.total - x.total,
           'medio_pago', x.medio_pago, 'quitado', v_det,
           'saldo_cuenta', (SELECT saldo FROM cc_cuentas WHERE id = x.cc_cuenta_id))
    INTO v_out FROM ventas x WHERE x.id = v.id;
  RETURN v_out;
END;
$$;
REVOKE ALL ON FUNCTION venta_quitar_items(BIGINT, JSONB, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION venta_quitar_items(BIGINT, JSONB, TEXT) TO authenticated;


NOTIFY pgrst, 'reload schema';

SELECT (SELECT count(*) FROM permisos WHERE clave LIKE 'ventas.editar%') AS permisos_editar,
       (SELECT count(*) FROM venta_ediciones)                          AS ediciones;
