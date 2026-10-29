-- ============================================================
-- 013 — VENTAS EN EL LOCAL, COMPRAS/LLEGADAS Y STOCK CONTROLADO
--       (diseño 2026-10-29)
-- Ejecutar en Supabase → SQL Editor, DESPUÉS del 012.
-- Idempotente: se puede correr más de una vez sin romper nada.
--
-- Por qué existe:
--   Para vender online hace falta stock real. El stock solo es real si
--   (a) cada venta del local lo descuenta en el momento y (b) cada
--   compra que llega lo carga. Y como el catálogo nunca está 100 %
--   contado, el sistema distingue por producto si su stock ya está
--   CONTROLADO (contado o recibido por compra) o todavía no.
--
-- Qué agrega:
--   1) productos.stock_controlado (+ fechas). Sin controlar: se vende en
--      el local sin tocar stock y la tienda muestra "Consultar".
--      Controlado: cada venta descuenta; la tienda vende si hay.
--   2) Conteo de stock (fn_stock_contar / _lote): número ABSOLUTO contado
--      en el depósito → movimiento por la diferencia + marca controlado.
--   3) Ventas en el local (ventas / venta_items + venta_registrar /
--      venta_anular): ticket con varios ítems, medio de pago, descuento;
--      descuenta stock solo de los controlados; permite vender aunque el
--      sistema diga 0 (queda negativo para revisar, nunca frena la caja).
--   4) Compras (compras / compra_items / compra_recepciones):
--      la lista del pedido al proveedor entra tal cual; compra_sugerir
--      busca el producto por SKU, código de barras, código del proveedor o
--      parecido del nombre (pg_trgm); lo que no existe se crea como
--      producto nuevo; al recibir, entrada_compra + stock controlado.
--   5) Disponible para la web = stock − comprometido por pedidos web que
--      esperan el pago (columna calculada stock_comprometido / stock_disponible,
--      legible por PostgREST en el mismo select de productos).
--   6) crear_solicitud revisa stock al crear el pedido: si un producto
--      controlado no alcanza, el pedido NO se crea (error 'sin_stock' con
--      el detalle) y el carrito lo muestra. Productos sin controlar con
--      precio quedan "stock a confirmar" (van por WhatsApp, sin pago online).
-- ============================================================


-- ──────────────────────────────────────────────
-- 0) EXTENSIÓN pg_trgm (parecido entre nombres de productos)
--    En Supabase vive en el esquema "extensions"; si ya estaba instalada
--    en otro esquema, IF NOT EXISTS la deja donde está. Las funciones que
--    la usan buscan en public y extensions.
-- ──────────────────────────────────────────────
CREATE SCHEMA IF NOT EXISTS extensions;
CREATE EXTENSION IF NOT EXISTS pg_trgm WITH SCHEMA extensions;


-- ──────────────────────────────────────────────
-- 1) STOCK CONTROLADO
-- ──────────────────────────────────────────────
ALTER TABLE productos ADD COLUMN IF NOT EXISTS stock_controlado    BOOLEAN NOT NULL DEFAULT false;
ALTER TABLE productos ADD COLUMN IF NOT EXISTS stock_controlado_en TIMESTAMPTZ;
ALTER TABLE productos ADD COLUMN IF NOT EXISTS ultimo_conteo_en    TIMESTAMPTZ;
-- Código con el que el proveedor (China) identifica el producto en sus
-- listas: la próxima compra lo encuentra solo.
ALTER TABLE productos ADD COLUMN IF NOT EXISTS sku_proveedor       TEXT;

CREATE INDEX IF NOT EXISTS idx_productos_controlado ON productos(stock_controlado);
CREATE INDEX IF NOT EXISTS idx_productos_barras ON productos(codigo_barras) WHERE codigo_barras IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_productos_sku_prov ON productos(sku_proveedor) WHERE sku_proveedor IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_solicitud_items_producto ON solicitud_items(producto_id);

-- Quien ya cargó stock a mano (carga inicial / ajuste / entrada) lo contó:
-- queda controlado. El resto arranca "sin contar".
UPDATE productos p
   SET stock_controlado = true,
       stock_controlado_en = coalesce(p.stock_controlado_en, m.primera),
       ultimo_conteo_en = coalesce(p.ultimo_conteo_en, m.ultima)
  FROM (SELECT producto_id, min(created_at) AS primera, max(created_at) AS ultima
          FROM movimientos_inventario
         WHERE tipo IN ('carga_inicial','entrada_compra','ajuste_positivo','ajuste_negativo','correccion')
         GROUP BY producto_id) m
 WHERE m.producto_id = p.id AND NOT p.stock_controlado;

-- Texto normalizado para comparar nombres (sin acentos, minúsculas, un espacio)
CREATE OR REPLACE FUNCTION fn_mh_norm(p TEXT)
RETURNS TEXT LANGUAGE sql IMMUTABLE AS $$
  SELECT btrim(regexp_replace(
           translate(lower(coalesce(p, '')), 'áéíóúüñàèìòùâêîôûç', 'aeiouunaeiouaeiouc'),
           '[^a-z0-9]+', ' ', 'g'))
$$;

-- Número tolerante: NULL si el texto no es numérico (evita que un dato
-- mal tipeado en una lista tire toda la operación)
CREATE OR REPLACE FUNCTION fn_mh_num(p TEXT)
RETURNS NUMERIC LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
  RETURN replace(btrim(coalesce(p, '')), ',', '.')::numeric;
EXCEPTION WHEN OTHERS THEN
  RETURN NULL;
END;
$$;

-- Slug para URL (misma regla que Utils.slug del panel)
CREATE OR REPLACE FUNCTION fn_mh_slug(p TEXT)
RETURNS TEXT LANGUAGE sql IMMUTABLE AS $$
  SELECT btrim(regexp_replace(fn_mh_norm(p), '\s+', '-', 'g'), '-')
$$;

-- Comprometido: unidades de pedidos WEB que eligieron pagar por transferencia
-- y todavía no se confirmaron (no descontaron). No cuenta lo que solo salió
-- por WhatsApp sin pagar (puede no volver). Columna calculada de PostgREST:
--   GET /rest/v1/productos?select=id,stock_actual,stock_comprometido,stock_disponible
CREATE OR REPLACE FUNCTION stock_comprometido(p productos)
RETURNS INT LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT coalesce(sum(i.cantidad), 0)::int
    FROM solicitud_items i
    JOIN solicitudes s ON s.id = i.solicitud_id
   WHERE i.producto_id = p.id
     AND NOT s.stock_descontado
     AND s.estado NOT IN ('cancelado','entregado')
     AND s.estado_pago IN ('pendiente','comprobante_recibido','en_revision')
     AND (s.estado_pago <> 'pendiente' OR s.pago_vence_en IS NULL OR s.pago_vence_en > now())
$$;

CREATE OR REPLACE FUNCTION stock_disponible(p productos)
RETURNS INT LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT p.stock_actual - stock_comprometido(p)
$$;

GRANT EXECUTE ON FUNCTION stock_comprometido(productos) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION stock_disponible(productos) TO anon, authenticated;

-- ¿Se puede vender online? (misma regla en la tienda: MH.availability)
--   'ok'        → tiene precio, controlado y disponible > 0 (o no sigue stock / backorder)
--   'sin_stock' → controlado y no alcanza
--   'consultar' → sin precio, o con precio pero stock sin controlar
CREATE OR REPLACE FUNCTION disponibilidad_web(p productos)
RETURNS TEXT LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT CASE
    WHEN p.estado <> 'activo' THEN 'sin_stock'
    WHEN NOT (coalesce(p.precio_minorista, 0) > 0 OR (p.en_oferta AND coalesce(p.precio_oferta, 0) > 0)) THEN 'consultar'
    WHEN NOT p.seguimiento_inventario OR p.permite_venta_sin_stock THEN 'ok'
    WHEN NOT p.stock_controlado THEN 'consultar'
    WHEN stock_disponible(p) > 0 THEN 'ok'
    ELSE 'sin_stock'
  END
$$;
GRANT EXECUTE ON FUNCTION disponibilidad_web(productos) TO anon, authenticated;

-- Marca el producto como controlado (idempotente). Uso interno.
CREATE OR REPLACE FUNCTION fn_stock_marcar_controlado(p_producto_id INT, p_conteo BOOLEAN DEFAULT false)
RETURNS VOID LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
  UPDATE productos
     SET stock_controlado = true,
         stock_controlado_en = coalesce(stock_controlado_en, now()),
         ultimo_conteo_en = CASE WHEN p_conteo THEN now() ELSE ultimo_conteo_en END
   WHERE id = p_producto_id
$$;
REVOKE ALL ON FUNCTION fn_stock_marcar_controlado(INT, BOOLEAN) FROM PUBLIC, anon, authenticated;

-- Conteo: cantidad ABSOLUTA que hay en el depósito. La diferencia se asienta
-- como movimiento (carga_inicial si nunca se contó y suma; correccion firmada
-- si no) y el producto queda controlado. Contar 0 también vale: "no hay".
CREATE OR REPLACE FUNCTION fn_stock_contar(p_producto_id INT, p_cantidad INT, p_observacion TEXT DEFAULT NULL)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_prod  productos%ROWTYPE;
  v_delta INT;
  v_mov   movimientos_inventario;
  v_tipo  TEXT;
BEGIN
  IF coalesce(fn_get_user_role(), '') NOT IN ('administrador','encargado_stock') THEN
    RAISE EXCEPTION 'sin_permiso' USING HINT = 'Solo administrador o encargado de stock pueden contar stock.';
  END IF;
  IF p_cantidad IS NULL OR p_cantidad < 0 THEN
    RAISE EXCEPTION 'cantidad_invalida' USING HINT = 'La cantidad contada no puede ser negativa.';
  END IF;

  SELECT * INTO v_prod FROM productos WHERE id = p_producto_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'producto_no_encontrado'; END IF;

  v_delta := p_cantidad - v_prod.stock_actual;
  IF v_delta <> 0 THEN
    v_tipo := CASE WHEN NOT v_prod.stock_controlado AND v_delta > 0 THEN 'carga_inicial' ELSE 'correccion' END;
    v_mov := fn_registrar_movimiento(
      p_producto_id, v_tipo,
      v_delta,
      CASE WHEN v_prod.stock_controlado THEN 'Conteo de stock' ELSE 'Conteo inicial' END,
      p_observacion, NULL, false);
  END IF;

  PERFORM fn_stock_marcar_controlado(p_producto_id, true);

  RETURN jsonb_build_object(
    'ok', true, 'producto_id', p_producto_id,
    'stock_anterior', v_prod.stock_actual, 'stock_actual', p_cantidad,
    'diferencia', v_delta, 'movimiento_id', v_mov.id,
    'ya_estaba_controlado', v_prod.stock_controlado);
END;
$$;
REVOKE ALL ON FUNCTION fn_stock_contar(INT, INT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION fn_stock_contar(INT, INT, TEXT) TO authenticated;

-- Varios conteos en una sola llamada (el celular guarda todo junto).
-- Cada ítem se procesa por separado: uno que falle no tira los demás.
-- p_items: [{ "producto_id": 1, "cantidad": 7, "observacion": null }, ...]
CREATE OR REPLACE FUNCTION fn_stock_contar_lote(p_items JSONB)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_item JSONB;
  v_res  JSONB := '[]'::jsonb;
  v_r    JSONB;
  v_ok   INT := 0;
  v_err  INT := 0;
  v_hint TEXT;
BEGIN
  IF coalesce(fn_get_user_role(), '') NOT IN ('administrador','encargado_stock') THEN
    RAISE EXCEPTION 'sin_permiso' USING HINT = 'Solo administrador o encargado de stock pueden contar stock.';
  END IF;
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) > 500 THEN
    RAISE EXCEPTION 'items_invalidos';
  END IF;
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    BEGIN
      v_r := fn_stock_contar((v_item->>'producto_id')::int, (v_item->>'cantidad')::int, v_item->>'observacion');
      v_ok := v_ok + 1;
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_hint = PG_EXCEPTION_HINT;
      v_err := v_err + 1;
      v_r := jsonb_build_object('ok', false, 'producto_id', v_item->>'producto_id',
                                'error', SQLERRM, 'hint', coalesce(v_hint, ''));
    END;
    v_res := v_res || v_r;
  END LOOP;
  RETURN jsonb_build_object('ok', v_err = 0, 'contados', v_ok, 'fallidos', v_err, 'items', v_res);
END;
$$;
REVOKE ALL ON FUNCTION fn_stock_contar_lote(JSONB) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION fn_stock_contar_lote(JSONB) TO authenticated;

-- "Me equivoqué, este todavía no está contado": vuelve a sin controlar.
-- No toca el stock_actual (queda como registro); la tienda deja de venderlo.
CREATE OR REPLACE FUNCTION fn_stock_quitar_control(p_producto_id INT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF coalesce(fn_get_user_role(), '') NOT IN ('administrador','encargado_stock') THEN
    RAISE EXCEPTION 'sin_permiso' USING HINT = 'Solo administrador o encargado de stock pueden cambiar el control de stock.';
  END IF;
  UPDATE productos SET stock_controlado = false WHERE id = p_producto_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'producto_no_encontrado'; END IF;
  RETURN jsonb_build_object('ok', true, 'producto_id', p_producto_id, 'stock_controlado', false);
END;
$$;
REVOKE ALL ON FUNCTION fn_stock_quitar_control(INT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION fn_stock_quitar_control(INT) TO authenticated;


-- ──────────────────────────────────────────────
-- 2) ALTA RÁPIDA DE PRODUCTO (la usan las compras y el conteo)
--    Nace con stock 0 (el 008 lo exige); el stock entra por movimiento.
--    SKU: el que venga o MH-00042 (por id). Slug único por nombre (+id si choca).
--    p: { nombre*, sku, codigo_barras, sku_proveedor, categoria_id, marca,
--         precio_costo, precio_minorista, proveedor, estado ('activo'|'inactivo'),
--         descripcion_corta }
-- ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_producto_crear_basico(p JSONB)
RETURNS INT LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_nombre TEXT := left(btrim(regexp_replace(coalesce(p->>'nombre',''), '\s+', ' ', 'g')), 160);
  v_sku    TEXT := nullif(left(btrim(coalesce(p->>'sku','')), 60), '');
  v_slug   TEXT;
  v_id     INT;
  v_estado TEXT := CASE WHEN p->>'estado' = 'activo' THEN 'activo' ELSE 'inactivo' END;
  v_cat    INT;
BEGIN
  IF length(v_nombre) < 2 THEN
    RAISE EXCEPTION 'nombre_invalido' USING HINT = 'El producto necesita un nombre.';
  END IF;
  IF v_sku IS NOT NULL AND EXISTS (SELECT 1 FROM productos WHERE lower(sku) = lower(v_sku)) THEN
    RAISE EXCEPTION 'sku_duplicado' USING HINT = format('Ya existe un producto con el SKU %s.', v_sku);
  END IF;
  BEGIN v_cat := (p->>'categoria_id')::int; EXCEPTION WHEN OTHERS THEN v_cat := NULL; END;
  IF v_cat IS NOT NULL AND NOT EXISTS (SELECT 1 FROM categorias WHERE id = v_cat) THEN v_cat := NULL; END IF;

  v_slug := nullif(fn_mh_slug(v_nombre), '');
  IF v_slug IS NULL THEN v_slug := 'producto'; END IF;
  IF EXISTS (SELECT 1 FROM productos WHERE slug = v_slug) THEN
    v_slug := v_slug || '-' || to_char(now(), 'YYMMDD') || '-' || upper(substr(md5(random()::text), 1, 4));
  END IF;

  INSERT INTO productos (nombre, slug, sku, codigo_barras, sku_proveedor, categoria_id, marca,
                         precio_costo, precio_minorista, proveedor, descripcion_corta,
                         estado, stock_actual, created_by, updated_by)
  VALUES (v_nombre, v_slug, v_sku,
          nullif(left(btrim(coalesce(p->>'codigo_barras','')), 40), ''),
          nullif(left(btrim(coalesce(p->>'sku_proveedor','')), 80), ''),
          v_cat,
          nullif(left(btrim(coalesce(p->>'marca','')), 80), ''),
          fn_mh_num(p->>'precio_costo'),
          fn_mh_num(p->>'precio_minorista'),
          nullif(left(btrim(coalesce(p->>'proveedor','')), 120), ''),
          nullif(left(btrim(coalesce(p->>'descripcion_corta','')), 300), ''),
          v_estado, 0, auth.uid(), auth.uid())
  RETURNING id INTO v_id;

  IF v_sku IS NULL THEN
    UPDATE productos SET sku = 'MH-' || lpad(v_id::text, 5, '0') WHERE id = v_id;
  END IF;
  RETURN v_id;
END;
$$;
REVOKE ALL ON FUNCTION fn_producto_crear_basico(JSONB) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION producto_crear_rapido(p JSONB)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_id INT; v_p productos%ROWTYPE;
BEGIN
  IF coalesce(fn_get_user_role(), '') NOT IN ('administrador','encargado_stock') THEN
    RAISE EXCEPTION 'sin_permiso' USING HINT = 'Solo administrador o encargado de stock pueden crear productos.';
  END IF;
  v_id := fn_producto_crear_basico(p);
  SELECT * INTO v_p FROM productos WHERE id = v_id;
  INSERT INTO historial_actividad (accion, entidad, entidad_id, descripcion, usuario_id)
  VALUES ('create', 'productos', v_id::text, 'Alta rápida: ' || v_p.nombre, auth.uid());
  RETURN jsonb_build_object('ok', true, 'id', v_id, 'nombre', v_p.nombre, 'sku', v_p.sku,
                            'slug', v_p.slug, 'estado', v_p.estado);
END;
$$;
REVOKE ALL ON FUNCTION producto_crear_rapido(JSONB) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION producto_crear_rapido(JSONB) TO authenticated;


-- ──────────────────────────────────────────────
-- 3) VENTAS EN EL LOCAL
-- ──────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS ventas (
  id                BIGSERIAL PRIMARY KEY,
  codigo            TEXT NOT NULL UNIQUE,                 -- VL-AAMMDD-XXXX
  fecha             TIMESTAMPTZ NOT NULL DEFAULT now(),
  vendedor_id       UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  vendedor_nombre   TEXT,
  cliente_nombre    TEXT,
  cliente_telefono  TEXT,
  medio_pago        TEXT NOT NULL DEFAULT 'efectivo'
                      CHECK (medio_pago IN ('efectivo','transferencia','debito','credito','mercadopago','cuenta_corriente','otro')),
  cuenta_cobro_id   BIGINT REFERENCES cuentas_cobro(id) ON DELETE SET NULL,  -- si fue transferencia a una cuenta conocida
  subtotal          NUMERIC(12,2) NOT NULL DEFAULT 0,
  descuento         NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (descuento >= 0),
  total             NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (total >= 0),
  items_count       INT NOT NULL DEFAULT 0,
  unidades          INT NOT NULL DEFAULT 0,
  stock_afectado    INT NOT NULL DEFAULT 0,               -- cuántos ítems descontaron stock
  estado            TEXT NOT NULL DEFAULT 'cerrada' CHECK (estado IN ('cerrada','anulada')),
  anulada_en        TIMESTAMPTZ,
  anulada_por       UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  motivo_anulacion  TEXT,
  notas             TEXT,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_ventas_fecha ON ventas(fecha DESC);
CREATE INDEX IF NOT EXISTS idx_ventas_vendedor ON ventas(vendedor_id);
CREATE OR REPLACE TRIGGER tr_ventas_updated_at BEFORE UPDATE ON ventas FOR EACH ROW EXECUTE FUNCTION fn_updated_at();

CREATE TABLE IF NOT EXISTS venta_items (
  id               BIGSERIAL PRIMARY KEY,
  venta_id         BIGINT NOT NULL REFERENCES ventas(id) ON DELETE CASCADE,
  producto_id      INT REFERENCES productos(id) ON DELETE SET NULL,   -- NULL = ítem libre (no está en el catálogo)
  nombre           TEXT NOT NULL,
  sku              TEXT,
  cantidad         INT NOT NULL CHECK (cantidad BETWEEN 1 AND 9999),
  precio_unitario  NUMERIC(12,2) NOT NULL CHECK (precio_unitario >= 0),
  subtotal         NUMERIC(12,2) NOT NULL,
  afecto_stock     BOOLEAN NOT NULL DEFAULT false,
  movimiento_id    INT REFERENCES movimientos_inventario(id) ON DELETE SET NULL,
  stock_posterior  INT,
  orden            INT NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_venta_items_venta ON venta_items(venta_id);
CREATE INDEX IF NOT EXISTS idx_venta_items_producto ON venta_items(producto_id);

ALTER TABLE ventas      ENABLE ROW LEVEL SECURITY;
ALTER TABLE venta_items ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "ventas_select_staff" ON ventas;
CREATE POLICY "ventas_select_staff" ON ventas FOR SELECT USING (auth.uid() IS NOT NULL);
DROP POLICY IF EXISTS "venta_items_select_staff" ON venta_items;
CREATE POLICY "venta_items_select_staff" ON venta_items FOR SELECT USING (auth.uid() IS NOT NULL);
-- Sin políticas de escritura: solo las RPC (SECURITY DEFINER).

-- Precio que se cobra si la caja no manda otro: oferta vigente o minorista.
CREATE OR REPLACE FUNCTION fn_precio_venta(p productos)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
  SELECT CASE WHEN p.en_oferta AND coalesce(p.precio_oferta, 0) > 0 THEN p.precio_oferta
              WHEN coalesce(p.precio_minorista, 0) > 0 THEN p.precio_minorista END
$$;

-- Registrar una venta del local. Todo o nada.
-- p: { items: [{ producto_id | nombre, cantidad, precio_unitario }],
--      medio_pago, cuenta_cobro_id, cliente_nombre, cliente_telefono,
--      descuento, notas, permitir_negativo (default true) }
CREATE OR REPLACE FUNCTION venta_registrar(p JSONB)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_rol      TEXT := coalesce(fn_get_user_role(), '');
  v_items    JSONB := coalesce(p->'items', '[]'::jsonb);
  v_item     JSONB;
  v_prod     productos%ROWTYPE;
  v_pid      INT;
  v_cant     INT;
  v_precio   NUMERIC(12,2);
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
BEGIN
  IF v_rol NOT IN ('administrador','vendedor','encargado_stock') THEN
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

  SELECT nombre INTO v_vend FROM profiles WHERE id = auth.uid();
  v_codigo := 'VL-' || to_char(now(), 'YYMMDD') || '-' ||
              upper(substr(md5(random()::text || clock_timestamp()::text), 1, 4));

  INSERT INTO ventas (codigo, vendedor_id, vendedor_nombre, cliente_nombre, cliente_telefono,
                      medio_pago, cuenta_cobro_id, notas)
  VALUES (v_codigo, auth.uid(), v_vend,
          nullif(left(btrim(coalesce(p->>'cliente_nombre','')), 80), ''),
          nullif(left(regexp_replace(coalesce(p->>'cliente_telefono',''), '[^0-9+ ()\-]', '', 'g'), 25), ''),
          v_medio, v_cuenta, nullif(left(btrim(coalesce(p->>'notas','')), 400), ''))
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

    v_afecta := false; v_mov := NULL;
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
    v_sub := round(v_precio * v_cant, 2);
    v_subtotal := v_subtotal + v_sub;
    v_n := v_n + 1; v_unid := v_unid + v_cant;

    INSERT INTO venta_items (venta_id, producto_id, nombre, sku, cantidad, precio_unitario, subtotal,
                             afecto_stock, movimiento_id, stock_posterior, orden)
    VALUES (v_venta_id, v_pid, v_nombre, v_sku, v_cant, v_precio, v_sub,
            v_afecta, v_mov.id, v_mov.stock_posterior, v_i);

    v_out := v_out || jsonb_build_object('producto_id', v_pid, 'nombre', v_nombre, 'sku', v_sku,
                                         'cantidad', v_cant, 'precio_unitario', v_precio, 'subtotal', v_sub,
                                         'afecto_stock', v_afecta, 'stock_posterior', v_mov.stock_posterior);
  END LOOP;

  IF v_desc > v_subtotal THEN
    RAISE EXCEPTION 'descuento_invalido' USING HINT = 'El descuento no puede superar el subtotal.';
  END IF;
  v_total := round(v_subtotal - v_desc, 2);

  UPDATE ventas SET subtotal = v_subtotal, descuento = v_desc, total = v_total,
                    items_count = v_n, unidades = v_unid, stock_afectado = v_afect
   WHERE id = v_venta_id;

  INSERT INTO historial_actividad (accion, entidad, entidad_id, descripcion, usuario_id)
  VALUES ('venta', 'ventas', v_venta_id::text,
          format('Venta %s: %s ítem(s), total %s (%s)', v_codigo, v_n, to_char(v_total, 'FM999G999G999D00'), v_medio),
          auth.uid());

  RETURN jsonb_build_object('ok', true, 'id', v_venta_id, 'codigo', v_codigo, 'fecha', now(),
                            'subtotal', v_subtotal, 'descuento', v_desc, 'total', v_total,
                            'medio_pago', v_medio, 'items', v_out, 'stock_afectado', v_afect,
                            'advertencias', v_avisos, 'vendedor', v_vend);
END;
$$;
REVOKE ALL ON FUNCTION venta_registrar(JSONB) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION venta_registrar(JSONB) TO authenticated;

-- Anular una venta: repone el stock de los ítems que lo descontaron.
-- Administrador: siempre. Vendedor / encargado: solo sus ventas de las últimas 24 h.
CREATE OR REPLACE FUNCTION venta_anular(p_venta_id BIGINT, p_motivo TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_rol   TEXT := coalesce(fn_get_user_role(), '');
  v_v     ventas%ROWTYPE;
  v_it    RECORD;
  v_movs  INT := 0;
BEGIN
  IF v_rol NOT IN ('administrador','vendedor','encargado_stock') THEN
    RAISE EXCEPTION 'sin_permiso' USING HINT = 'Tu usuario no puede anular ventas.';
  END IF;
  IF nullif(btrim(coalesce(p_motivo, '')), '') IS NULL THEN
    RAISE EXCEPTION 'motivo_requerido' USING HINT = 'Escribí por qué se anula la venta.';
  END IF;
  SELECT * INTO v_v FROM ventas WHERE id = p_venta_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'venta_no_encontrada'; END IF;
  IF v_v.estado = 'anulada' THEN
    RETURN jsonb_build_object('ok', true, 'sin_cambios', true, 'estado', 'anulada');
  END IF;
  IF v_rol <> 'administrador' AND (v_v.vendedor_id IS DISTINCT FROM auth.uid() OR v_v.fecha < now() - interval '24 hours') THEN
    RAISE EXCEPTION 'sin_permiso' USING HINT = 'Solo un administrador puede anular ventas de otros o de más de 24 horas.';
  END IF;

  PERFORM set_config('mh.interno', '1', true);
  FOR v_it IN SELECT * FROM venta_items WHERE venta_id = v_v.id AND afecto_stock AND producto_id IS NOT NULL LOOP
    PERFORM fn_registrar_movimiento(v_it.producto_id, 'devolucion_cliente', v_it.cantidad,
                                    'Venta anulada', left(p_motivo, 200), v_v.codigo, false);
    v_movs := v_movs + 1;
  END LOOP;

  UPDATE ventas SET estado = 'anulada', anulada_en = now(), anulada_por = auth.uid(),
                    motivo_anulacion = left(btrim(p_motivo), 300)
   WHERE id = v_v.id;

  INSERT INTO historial_actividad (accion, entidad, entidad_id, descripcion, usuario_id)
  VALUES ('anular', 'ventas', v_v.id::text, format('Venta %s anulada: %s', v_v.codigo, left(p_motivo, 120)), auth.uid());

  RETURN jsonb_build_object('ok', true, 'estado', 'anulada', 'movimientos', v_movs);
END;
$$;
REVOKE ALL ON FUNCTION venta_anular(BIGINT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION venta_anular(BIGINT, TEXT) TO authenticated;

-- Resumen por día y medio de pago (para la caja y el listado)
CREATE OR REPLACE VIEW v_ventas_resumen WITH (security_invoker = true) AS
SELECT fn_mh_local(fecha)::date AS dia,
       medio_pago,
       count(*)::int AS ventas,
       sum(total) AS total,
       sum(unidades)::int AS unidades
  FROM ventas
 WHERE estado = 'cerrada'
 GROUP BY 1, 2;
GRANT SELECT ON v_ventas_resumen TO authenticated;


-- ──────────────────────────────────────────────
-- 4) COMPRAS (pedidos al proveedor) Y LLEGADAS
-- ──────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS compras (
  id              BIGSERIAL PRIMARY KEY,
  codigo          TEXT NOT NULL UNIQUE,                   -- OC-AAMMDD-XXXX
  proveedor       TEXT,
  origen          TEXT NOT NULL DEFAULT 'China',
  referencia      TEXT,                                   -- nº de pedido / contenedor / factura
  moneda          TEXT NOT NULL DEFAULT 'USD',
  tipo_cambio     NUMERIC(14,4) CHECK (tipo_cambio IS NULL OR tipo_cambio > 0),  -- ARS por 1 unidad de moneda
  estado          TEXT NOT NULL DEFAULT 'pedido'
                    CHECK (estado IN ('pedido','en_transito','recibido_parcial','recibido','cancelado')),
  fecha_pedido    DATE NOT NULL DEFAULT current_date,
  fecha_estimada  DATE,
  fecha_recibido  TIMESTAMPTZ,
  total_items     INT NOT NULL DEFAULT 0,
  total_unidades  INT NOT NULL DEFAULT 0,
  total_costo     NUMERIC(14,2),                          -- en la moneda de la compra
  notas           TEXT,
  created_by      UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_compras_estado ON compras(estado);
CREATE INDEX IF NOT EXISTS idx_compras_fecha ON compras(fecha_pedido DESC);
CREATE OR REPLACE TRIGGER tr_compras_updated_at BEFORE UPDATE ON compras FOR EACH ROW EXECUTE FUNCTION fn_updated_at();

CREATE TABLE IF NOT EXISTS compra_items (
  id                    BIGSERIAL PRIMARY KEY,
  compra_id             BIGINT NOT NULL REFERENCES compras(id) ON DELETE CASCADE,
  producto_id           INT REFERENCES productos(id) ON DELETE SET NULL,
  descripcion_original  TEXT NOT NULL,                    -- tal cual vino en la lista
  sku_proveedor         TEXT,
  cantidad_pedida       INT NOT NULL CHECK (cantidad_pedida > 0),
  cantidad_recibida     INT NOT NULL DEFAULT 0 CHECK (cantidad_recibida >= 0),
  costo_unitario        NUMERIC(14,4) CHECK (costo_unitario IS NULL OR costo_unitario >= 0),
  producto_nuevo        BOOLEAN NOT NULL DEFAULT false,   -- se creó con esta compra
  orden                 INT NOT NULL DEFAULT 0,
  created_at            TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_compra_items_compra ON compra_items(compra_id);
CREATE INDEX IF NOT EXISTS idx_compra_items_producto ON compra_items(producto_id);

CREATE TABLE IF NOT EXISTS compra_recepciones (
  id              BIGSERIAL PRIMARY KEY,
  compra_id       BIGINT NOT NULL REFERENCES compras(id) ON DELETE CASCADE,
  fecha           TIMESTAMPTZ NOT NULL DEFAULT now(),
  usuario_id      UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  total_unidades  INT NOT NULL DEFAULT 0,
  notas           TEXT
);
CREATE INDEX IF NOT EXISTS idx_compra_recep_compra ON compra_recepciones(compra_id);

CREATE TABLE IF NOT EXISTS compra_recepcion_items (
  id                   BIGSERIAL PRIMARY KEY,
  recepcion_id         BIGINT NOT NULL REFERENCES compra_recepciones(id) ON DELETE CASCADE,
  compra_item_id       BIGINT NOT NULL REFERENCES compra_items(id) ON DELETE CASCADE,
  cantidad             INT NOT NULL CHECK (cantidad >= 0),
  ya_habia             INT NOT NULL DEFAULT 0 CHECK (ya_habia >= 0),  -- unidades viejas contadas al recibir
  movimiento_id        INT REFERENCES movimientos_inventario(id) ON DELETE SET NULL,
  movimiento_previo_id INT REFERENCES movimientos_inventario(id) ON DELETE SET NULL
);
CREATE INDEX IF NOT EXISTS idx_compra_recep_items_recep ON compra_recepcion_items(recepcion_id);

ALTER TABLE compras                 ENABLE ROW LEVEL SECURITY;
ALTER TABLE compra_items            ENABLE ROW LEVEL SECURITY;
ALTER TABLE compra_recepciones      ENABLE ROW LEVEL SECURITY;
ALTER TABLE compra_recepcion_items  ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "compras_select_staff" ON compras;
CREATE POLICY "compras_select_staff" ON compras FOR SELECT USING (auth.uid() IS NOT NULL);
DROP POLICY IF EXISTS "compra_items_select_staff" ON compra_items;
CREATE POLICY "compra_items_select_staff" ON compra_items FOR SELECT USING (auth.uid() IS NOT NULL);
DROP POLICY IF EXISTS "compra_recep_select_staff" ON compra_recepciones;
CREATE POLICY "compra_recep_select_staff" ON compra_recepciones FOR SELECT USING (auth.uid() IS NOT NULL);
DROP POLICY IF EXISTS "compra_recep_items_select_staff" ON compra_recepcion_items;
CREATE POLICY "compra_recep_items_select_staff" ON compra_recepcion_items FOR SELECT USING (auth.uid() IS NOT NULL);
-- Sin políticas de escritura: solo las RPC.

CREATE OR REPLACE FUNCTION fn_es_staff_stock()
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT coalesce(fn_get_user_role(), '') IN ('administrador','encargado_stock')
$$;

-- Sugerir a qué producto corresponde cada línea de la lista del proveedor.
-- p_lineas: [{ "i": 0, "descripcion": "...", "sku": "...", "codigo_barras": "..." }, ...]
-- Devuelve por línea hasta 4 candidatos con puntaje 0..100 y el motivo.
--   100 = SKU / código de barras / código de proveedor exacto
--    95 = nombre exacto (normalizado)
--  40-90 = parecido del nombre (pg_trgm)
CREATE OR REPLACE FUNCTION compra_sugerir(p_lineas JSONB)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
  v_l    JSONB;
  v_res  JSONB := '[]'::jsonb;
  v_cand JSONB;
  v_desc TEXT;
  v_norm TEXT;
  v_sku  TEXT;
  v_bar  TEXT;
BEGIN
  IF NOT fn_es_staff_stock() THEN
    RAISE EXCEPTION 'sin_permiso' USING HINT = 'Solo administrador o encargado de stock pueden cargar compras.';
  END IF;
  IF p_lineas IS NULL OR jsonb_typeof(p_lineas) <> 'array' OR jsonb_array_length(p_lineas) > 1000 THEN
    RAISE EXCEPTION 'lineas_invalidas';
  END IF;

  FOR v_l IN SELECT * FROM jsonb_array_elements(p_lineas) LOOP
    v_desc := left(btrim(coalesce(v_l->>'descripcion', '')), 300);
    v_norm := fn_mh_norm(v_desc);
    v_sku  := nullif(lower(btrim(coalesce(v_l->>'sku', ''))), '');
    v_bar  := nullif(regexp_replace(coalesce(v_l->>'codigo_barras', ''), '\D', '', 'g'), '');

    SELECT coalesce(jsonb_agg(jsonb_build_object(
             'id', c.id, 'nombre', c.nombre, 'sku', c.sku, 'estado', c.estado,
             'stock_actual', c.stock_actual, 'stock_controlado', c.stock_controlado,
             'precio_minorista', c.precio_minorista, 'score', c.score, 'motivo', c.motivo)
             ORDER BY c.score DESC, c.nombre), '[]'::jsonb)
      INTO v_cand
      FROM (
        SELECT DISTINCT ON (x.id) x.*
          FROM (
            SELECT p.id, p.nombre, p.sku, p.estado, p.stock_actual, p.stock_controlado, p.precio_minorista,
                   100 AS score, 'SKU exacto' AS motivo
              FROM productos p WHERE v_sku IS NOT NULL AND lower(p.sku) = v_sku AND p.estado <> 'archivado'
            UNION ALL
            SELECT p.id, p.nombre, p.sku, p.estado, p.stock_actual, p.stock_controlado, p.precio_minorista,
                   100, 'Código del proveedor'
              FROM productos p WHERE v_sku IS NOT NULL AND lower(p.sku_proveedor) = v_sku AND p.estado <> 'archivado'
            UNION ALL
            SELECT p.id, p.nombre, p.sku, p.estado, p.stock_actual, p.stock_controlado, p.precio_minorista,
                   100, 'Código de barras'
              FROM productos p WHERE v_bar IS NOT NULL AND length(v_bar) >= 8
                                 AND regexp_replace(coalesce(p.codigo_barras,''), '\D', '', 'g') = v_bar
                                 AND p.estado <> 'archivado'
            UNION ALL
            SELECT p.id, p.nombre, p.sku, p.estado, p.stock_actual, p.stock_controlado, p.precio_minorista,
                   95, 'Mismo nombre'
              FROM productos p WHERE v_norm <> '' AND fn_mh_norm(p.nombre) = v_norm AND p.estado <> 'archivado'
            UNION ALL
            SELECT p.id, p.nombre, p.sku, p.estado, p.stock_actual, p.stock_controlado, p.precio_minorista,
                   round(similarity(fn_mh_norm(p.nombre), v_norm) * 90)::int, 'Nombre parecido'
              FROM productos p
             WHERE v_norm <> '' AND length(v_norm) >= 4 AND p.estado <> 'archivado'
               AND similarity(fn_mh_norm(p.nombre), v_norm) >= 0.42
          ) x
         ORDER BY x.id, x.score DESC
      ) c
     WHERE c.score >= 38;

    -- Nos quedamos con los 4 mejores
    SELECT coalesce(jsonb_agg(e ORDER BY (e->>'score')::int DESC), '[]'::jsonb)
      INTO v_cand
      FROM (SELECT e FROM jsonb_array_elements(v_cand) e ORDER BY (e->>'score')::int DESC LIMIT 4) t;

    v_res := v_res || jsonb_build_object(
      'i', coalesce((v_l->>'i')::int, jsonb_array_length(v_res)),
      'descripcion', v_desc,
      'candidatos', v_cand,
      'seguro', jsonb_array_length(v_cand) > 0 AND (v_cand->0->>'score')::int >= 95);
  END LOOP;
  RETURN v_res;
END;
$$;
REVOKE ALL ON FUNCTION compra_sugerir(JSONB) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION compra_sugerir(JSONB) TO authenticated;

-- Recibir mercadería de una compra (interno; la RPC pública valida el rol).
-- p_items: [{ "item_id": 12, "cantidad": 10, "ya_habia": 0 }, ...]
--   cantidad = unidades que llegaron ahora (entrada_compra)
--   ya_habia = unidades viejas que había en el local de un producto que
--              todavía no estaba controlado (se asientan como carga_inicial)
-- Todo producto recibido queda con stock controlado.
CREATE OR REPLACE FUNCTION fn_compra_recibir(p_compra_id BIGINT, p_items JSONB, p_notas TEXT, p_cerrar BOOLEAN)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_c        compras%ROWTYPE;
  v_it       compra_items%ROWTYPE;
  v_prod     productos%ROWTYPE;
  v_item     JSONB;
  v_cant     INT;
  v_viejo    INT;
  v_rec_id   BIGINT;
  v_mov      movimientos_inventario;
  v_mov_prev movimientos_inventario;
  v_unid     INT := 0;
  v_lineas   INT := 0;
  v_nuevos_ctrl INT := 0;
  v_out      JSONB := '[]'::jsonb;
  v_costo_ars NUMERIC;
  v_pendientes INT;
BEGIN
  SELECT * INTO v_c FROM compras WHERE id = p_compra_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'compra_no_encontrada'; END IF;
  IF v_c.estado = 'cancelado' THEN
    RAISE EXCEPTION 'compra_cancelada' USING HINT = 'La compra está cancelada.';
  END IF;
  IF v_c.estado = 'recibido' THEN
    RAISE EXCEPTION 'compra_ya_recibida' USING HINT = 'Esta compra ya se recibió completa.';
  END IF;
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' THEN
    RAISE EXCEPTION 'items_invalidos';
  END IF;

  INSERT INTO compra_recepciones (compra_id, usuario_id, notas)
  VALUES (v_c.id, auth.uid(), nullif(left(btrim(coalesce(p_notas,'')), 400), ''))
  RETURNING id INTO v_rec_id;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    BEGIN
      v_cant  := coalesce((v_item->>'cantidad')::int, 0);
      v_viejo := coalesce((v_item->>'ya_habia')::int, 0);
    EXCEPTION WHEN OTHERS THEN
      RAISE EXCEPTION 'items_invalidos';
    END;
    IF v_cant < 0 OR v_viejo < 0 THEN RAISE EXCEPTION 'cantidad_invalida'; END IF;

    SELECT * INTO v_it FROM compra_items WHERE id = (v_item->>'item_id')::bigint AND compra_id = v_c.id FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'item_no_encontrado' USING HINT = format('El renglón %s no pertenece a esta compra.', v_item->>'item_id');
    END IF;
    IF v_cant = 0 AND v_viejo = 0 THEN CONTINUE; END IF;
    IF v_it.producto_id IS NULL THEN
      RAISE EXCEPTION 'item_sin_producto'
        USING HINT = format('"%s" no está vinculado a ningún producto: vinculalo o creálo antes de recibir.', left(v_it.descripcion_original, 60));
    END IF;

    SELECT * INTO v_prod FROM productos WHERE id = v_it.producto_id FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'producto_no_encontrado' USING HINT = format('El producto del renglón "%s" ya no existe.', left(v_it.descripcion_original, 60));
    END IF;

    v_mov := NULL; v_mov_prev := NULL;
    -- Unidades viejas que había (solo tiene sentido si el producto no estaba controlado)
    IF v_viejo > 0 AND NOT v_prod.stock_controlado THEN
      v_mov_prev := fn_registrar_movimiento(v_prod.id, 'carga_inicial', v_viejo,
                      'Conteo al recibir compra', NULL, v_c.codigo, false);
    END IF;
    IF v_cant > 0 THEN
      v_mov := fn_registrar_movimiento(v_prod.id, 'entrada_compra', v_cant,
                 'Recepción de compra', nullif(left(btrim(coalesce(p_notas,'')), 200), ''), v_c.codigo, false);
      v_unid := v_unid + v_cant;
    END IF;

    IF NOT v_prod.stock_controlado THEN v_nuevos_ctrl := v_nuevos_ctrl + 1; END IF;
    PERFORM fn_stock_marcar_controlado(v_prod.id, v_viejo > 0);

    -- Último costo conocido (en pesos si hay tipo de cambio o la compra es en ARS)
    IF v_it.costo_unitario IS NOT NULL THEN
      v_costo_ars := CASE WHEN v_c.moneda = 'ARS' THEN v_it.costo_unitario
                          WHEN v_c.tipo_cambio IS NOT NULL THEN round(v_it.costo_unitario * v_c.tipo_cambio, 2) END;
      IF v_costo_ars IS NOT NULL THEN
        UPDATE productos SET precio_costo = v_costo_ars, updated_by = auth.uid() WHERE id = v_prod.id;
      END IF;
    END IF;
    IF v_it.sku_proveedor IS NOT NULL AND v_prod.sku_proveedor IS NULL THEN
      UPDATE productos SET sku_proveedor = v_it.sku_proveedor WHERE id = v_prod.id;
    END IF;

    UPDATE compra_items SET cantidad_recibida = cantidad_recibida + v_cant WHERE id = v_it.id;
    INSERT INTO compra_recepcion_items (recepcion_id, compra_item_id, cantidad, ya_habia, movimiento_id, movimiento_previo_id)
    VALUES (v_rec_id, v_it.id, v_cant, v_viejo, v_mov.id, v_mov_prev.id);
    v_lineas := v_lineas + 1;

    v_out := v_out || jsonb_build_object('item_id', v_it.id, 'producto_id', v_prod.id, 'nombre', v_prod.nombre,
                                         'recibido', v_cant, 'ya_habia', v_viejo,
                                         'stock_actual', coalesce(v_mov.stock_posterior, v_mov_prev.stock_posterior, v_prod.stock_actual));
  END LOOP;

  UPDATE compra_recepciones SET total_unidades = v_unid WHERE id = v_rec_id;

  SELECT count(*) INTO v_pendientes FROM compra_items WHERE compra_id = v_c.id AND cantidad_recibida < cantidad_pedida;
  UPDATE compras
     SET estado = CASE WHEN v_pendientes = 0 OR p_cerrar THEN 'recibido' ELSE 'recibido_parcial' END,
         fecha_recibido = CASE WHEN v_pendientes = 0 OR p_cerrar THEN now() ELSE fecha_recibido END
   WHERE id = v_c.id;

  INSERT INTO historial_actividad (accion, entidad, entidad_id, descripcion, usuario_id)
  VALUES ('recepcion', 'compras', v_c.id::text,
          format('Compra %s: recibidas %s unidades en %s renglón(es)', v_c.codigo, v_unid, v_lineas), auth.uid());

  RETURN jsonb_build_object('ok', true, 'recepcion_id', v_rec_id, 'compra_id', v_c.id, 'codigo', v_c.codigo,
                            'unidades', v_unid, 'renglones', v_lineas, 'nuevos_controlados', v_nuevos_ctrl,
                            'pendientes', CASE WHEN p_cerrar THEN 0 ELSE v_pendientes END,
                            'estado', CASE WHEN v_pendientes = 0 OR p_cerrar THEN 'recibido' ELSE 'recibido_parcial' END,
                            'items', v_out);
END;
$$;
REVOKE ALL ON FUNCTION fn_compra_recibir(BIGINT, JSONB, TEXT, BOOLEAN) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION compra_recibir(p_compra_id BIGINT, p_items JSONB, p_notas TEXT DEFAULT NULL, p_cerrar BOOLEAN DEFAULT false)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT fn_es_staff_stock() THEN
    RAISE EXCEPTION 'sin_permiso' USING HINT = 'Solo administrador o encargado de stock pueden recibir mercadería.';
  END IF;
  RETURN fn_compra_recibir(p_compra_id, p_items, p_notas, coalesce(p_cerrar, false));
END;
$$;
REVOKE ALL ON FUNCTION compra_recibir(BIGINT, JSONB, TEXT, BOOLEAN) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION compra_recibir(BIGINT, JSONB, TEXT, BOOLEAN) TO authenticated;

-- Crear la compra a partir de la lista revisada.
-- p: { proveedor, origen, referencia, moneda, tipo_cambio, fecha_pedido, fecha_estimada, notas,
--      publicar_nuevos (bool: los productos nuevos nacen activos en la tienda; default false),
--      categoria_nuevos (id para los nuevos que no traigan categoría),
--      recibir_ahora (bool: ya llegó todo → se recibe en la misma operación),
--      items: [{ descripcion, sku_proveedor, cantidad, costo_unitario,
--                accion: 'vincular' | 'crear' | 'omitir',
--                producto_id (vincular),
--                nuevo: { nombre, sku, codigo_barras, categoria_id, marca, precio_minorista } (crear),
--                ya_habia (solo con recibir_ahora) }] }
CREATE OR REPLACE FUNCTION compra_crear(p JSONB)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_items    JSONB := coalesce(p->'items', '[]'::jsonb);
  v_item     JSONB;
  v_id       BIGINT;
  v_codigo   TEXT;
  v_moneda   TEXT := upper(coalesce(nullif(btrim(p->>'moneda'),''), 'USD'));
  v_tc       NUMERIC;
  v_accion   TEXT;
  v_pid      INT;
  v_cant     INT;
  v_costo    NUMERIC;
  v_desc     TEXT;
  v_skuprov  TEXT;
  v_nuevo    JSONB;
  v_n        INT := 0;
  v_unid     INT := 0;
  v_costo_total NUMERIC := 0;
  v_hay_costo BOOLEAN := false;
  v_creados  JSONB := '[]'::jsonb;
  v_item_id  BIGINT;
  v_recibir  JSONB := '[]'::jsonb;
  v_rec      JSONB := NULL;
  v_publicar BOOLEAN := coalesce((p->>'publicar_nuevos')::boolean, false);
  v_cat_def  INT;
  v_fecha    DATE;
  v_fecha_est DATE;
  v_i        INT := 0;
BEGIN
  IF NOT fn_es_staff_stock() THEN
    RAISE EXCEPTION 'sin_permiso' USING HINT = 'Solo administrador o encargado de stock pueden cargar compras.';
  END IF;
  IF jsonb_typeof(v_items) <> 'array' OR jsonb_array_length(v_items) = 0 THEN
    RAISE EXCEPTION 'compra_vacia' USING HINT = 'La compra necesita al menos un renglón.';
  END IF;
  IF jsonb_array_length(v_items) > 1000 THEN
    RAISE EXCEPTION 'items_invalidos' USING HINT = 'Demasiados renglones: dividí la compra.';
  END IF;
  IF v_moneda !~ '^[A-Z]{3}$' THEN v_moneda := 'USD'; END IF;
  BEGIN v_tc := nullif(p->>'tipo_cambio','')::numeric; EXCEPTION WHEN OTHERS THEN v_tc := NULL; END;
  IF v_tc IS NOT NULL AND v_tc <= 0 THEN v_tc := NULL; END IF;
  BEGIN v_cat_def := nullif(p->>'categoria_nuevos','')::int; EXCEPTION WHEN OTHERS THEN v_cat_def := NULL; END;
  BEGIN v_fecha := coalesce(nullif(p->>'fecha_pedido','')::date, current_date); EXCEPTION WHEN OTHERS THEN v_fecha := current_date; END;
  BEGIN v_fecha_est := nullif(p->>'fecha_estimada','')::date; EXCEPTION WHEN OTHERS THEN v_fecha_est := NULL; END;

  v_codigo := 'OC-' || to_char(now(), 'YYMMDD') || '-' ||
              upper(substr(md5(random()::text || clock_timestamp()::text), 1, 4));

  INSERT INTO compras (codigo, proveedor, origen, referencia, moneda, tipo_cambio, fecha_pedido, fecha_estimada, notas, created_by)
  VALUES (v_codigo,
          nullif(left(btrim(coalesce(p->>'proveedor','')), 120), ''),
          coalesce(nullif(left(btrim(coalesce(p->>'origen','')), 60), ''), 'China'),
          nullif(left(btrim(coalesce(p->>'referencia','')), 120), ''),
          v_moneda, v_tc, v_fecha, v_fecha_est,
          nullif(left(btrim(coalesce(p->>'notas','')), 1000), ''),
          auth.uid())
  RETURNING id INTO v_id;

  FOR v_item IN SELECT * FROM jsonb_array_elements(v_items) LOOP
    v_i := v_i + 1;
    v_accion := coalesce(v_item->>'accion', 'crear');
    IF v_accion = 'omitir' THEN CONTINUE; END IF;
    IF v_accion NOT IN ('vincular','crear') THEN
      RAISE EXCEPTION 'items_invalidos' USING HINT = format('Renglón %s: acción desconocida.', v_i);
    END IF;

    BEGIN
      v_cant  := (v_item->>'cantidad')::int;
      v_costo := nullif(v_item->>'costo_unitario','')::numeric;
    EXCEPTION WHEN OTHERS THEN
      RAISE EXCEPTION 'items_invalidos' USING HINT = format('Renglón %s: cantidad o costo inválidos.', v_i);
    END;
    IF v_cant IS NULL OR v_cant < 1 THEN
      RAISE EXCEPTION 'cantidad_invalida' USING HINT = format('Renglón %s: la cantidad tiene que ser 1 o más.', v_i);
    END IF;
    IF v_costo IS NOT NULL AND v_costo < 0 THEN v_costo := NULL; END IF;

    v_desc := left(btrim(regexp_replace(coalesce(v_item->>'descripcion',''), '\s+', ' ', 'g')), 300);
    v_skuprov := nullif(left(btrim(coalesce(v_item->>'sku_proveedor','')), 80), '');

    IF v_accion = 'vincular' THEN
      BEGIN v_pid := (v_item->>'producto_id')::int; EXCEPTION WHEN OTHERS THEN v_pid := NULL; END;
      IF v_pid IS NULL OR NOT EXISTS (SELECT 1 FROM productos WHERE id = v_pid) THEN
        RAISE EXCEPTION 'producto_no_encontrado' USING HINT = format('Renglón %s: el producto elegido no existe.', v_i);
      END IF;
      IF v_desc = '' THEN SELECT nombre INTO v_desc FROM productos WHERE id = v_pid; END IF;
    ELSE
      v_nuevo := coalesce(v_item->'nuevo', '{}'::jsonb);
      IF jsonb_typeof(v_nuevo) <> 'object' THEN v_nuevo := '{}'::jsonb; END IF;
      IF nullif(btrim(coalesce(v_nuevo->>'nombre','')), '') IS NULL THEN
        v_nuevo := v_nuevo || jsonb_build_object('nombre', v_desc);
      END IF;
      IF v_desc = '' THEN v_desc := v_nuevo->>'nombre'; END IF;
      IF nullif(v_nuevo->>'categoria_id','') IS NULL AND v_cat_def IS NOT NULL THEN
        v_nuevo := v_nuevo || jsonb_build_object('categoria_id', v_cat_def);
      END IF;
      v_nuevo := v_nuevo || jsonb_build_object(
        'estado', CASE WHEN v_publicar THEN 'activo' ELSE 'inactivo' END,
        'sku_proveedor', coalesce(v_nuevo->>'sku_proveedor', v_skuprov),
        'proveedor', coalesce(v_nuevo->>'proveedor', p->>'proveedor'),
        'precio_costo', CASE WHEN v_costo IS NOT NULL AND v_moneda = 'ARS' THEN v_costo
                             WHEN v_costo IS NOT NULL AND v_tc IS NOT NULL THEN round(v_costo * v_tc, 2) END);
      v_pid := fn_producto_crear_basico(v_nuevo);
      v_creados := v_creados || jsonb_build_object('id', v_pid, 'nombre', v_nuevo->>'nombre');
    END IF;

    INSERT INTO compra_items (compra_id, producto_id, descripcion_original, sku_proveedor, cantidad_pedida,
                              costo_unitario, producto_nuevo, orden)
    VALUES (v_id, v_pid, coalesce(nullif(v_desc,''), 'Renglón ' || v_i), v_skuprov, v_cant, v_costo, v_accion = 'crear', v_i)
    RETURNING id INTO v_item_id;

    v_n := v_n + 1; v_unid := v_unid + v_cant;
    IF v_costo IS NOT NULL THEN v_hay_costo := true; v_costo_total := v_costo_total + v_costo * v_cant; END IF;

    v_recibir := v_recibir || jsonb_build_object('item_id', v_item_id, 'cantidad', v_cant,
                                                 'ya_habia', coalesce(nullif(v_item->>'ya_habia','')::int, 0));
  END LOOP;

  IF v_n = 0 THEN
    RAISE EXCEPTION 'compra_vacia' USING HINT = 'Todos los renglones quedaron omitidos.';
  END IF;

  UPDATE compras SET total_items = v_n, total_unidades = v_unid,
                     total_costo = CASE WHEN v_hay_costo THEN round(v_costo_total, 2) END
   WHERE id = v_id;

  INSERT INTO historial_actividad (accion, entidad, entidad_id, descripcion, usuario_id)
  VALUES ('create', 'compras', v_id::text,
          format('Compra %s: %s renglón(es), %s unidades, %s producto(s) nuevo(s)', v_codigo, v_n, v_unid, jsonb_array_length(v_creados)),
          auth.uid());

  IF coalesce((p->>'recibir_ahora')::boolean, false) THEN
    v_rec := fn_compra_recibir(v_id, v_recibir, 'Recibida al cargar la compra', true);
  END IF;

  RETURN jsonb_build_object('ok', true, 'id', v_id, 'codigo', v_codigo, 'renglones', v_n, 'unidades', v_unid,
                            'productos_nuevos', v_creados, 'recepcion', v_rec,
                            'estado', CASE WHEN v_rec IS NOT NULL THEN v_rec->>'estado' ELSE 'pedido' END);
END;
$$;
REVOKE ALL ON FUNCTION compra_crear(JSONB) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION compra_crear(JSONB) TO authenticated;

-- Cambiar un renglón de producto antes de recibirlo (o crear el producto en ese momento)
CREATE OR REPLACE FUNCTION compra_item_vincular(p_item_id BIGINT, p_producto_id INT DEFAULT NULL, p_nuevo JSONB DEFAULT NULL)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_it compra_items%ROWTYPE; v_pid INT := p_producto_id; v_c compras%ROWTYPE;
BEGIN
  IF NOT fn_es_staff_stock() THEN
    RAISE EXCEPTION 'sin_permiso' USING HINT = 'Solo administrador o encargado de stock pueden editar compras.';
  END IF;
  SELECT * INTO v_it FROM compra_items WHERE id = p_item_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'item_no_encontrado'; END IF;
  SELECT * INTO v_c FROM compras WHERE id = v_it.compra_id;
  IF v_c.estado IN ('recibido','cancelado') THEN
    RAISE EXCEPTION 'compra_cerrada' USING HINT = 'La compra ya está cerrada.';
  END IF;
  IF v_it.cantidad_recibida > 0 THEN
    RAISE EXCEPTION 'item_ya_recibido' USING HINT = 'Este renglón ya recibió unidades: no se puede cambiar de producto.';
  END IF;
  IF v_pid IS NULL AND p_nuevo IS NOT NULL THEN
    v_pid := fn_producto_crear_basico(p_nuevo || jsonb_build_object(
               'nombre', coalesce(nullif(p_nuevo->>'nombre',''), v_it.descripcion_original),
               'sku_proveedor', coalesce(p_nuevo->>'sku_proveedor', v_it.sku_proveedor),
               'estado', coalesce(p_nuevo->>'estado', 'inactivo')));
  END IF;
  IF v_pid IS NULL OR NOT EXISTS (SELECT 1 FROM productos WHERE id = v_pid) THEN
    RAISE EXCEPTION 'producto_no_encontrado';
  END IF;
  UPDATE compra_items SET producto_id = v_pid, producto_nuevo = (p_producto_id IS NULL AND p_nuevo IS NOT NULL) WHERE id = v_it.id;
  RETURN jsonb_build_object('ok', true, 'item_id', v_it.id, 'producto_id', v_pid);
END;
$$;
REVOKE ALL ON FUNCTION compra_item_vincular(BIGINT, INT, JSONB) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION compra_item_vincular(BIGINT, INT, JSONB) TO authenticated;

-- Marcar en tránsito, volver a "pedido" o cancelar (si no se recibió nada)
CREATE OR REPLACE FUNCTION compra_cambiar_estado(p_compra_id BIGINT, p_estado TEXT, p_fecha_estimada DATE DEFAULT NULL)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_c compras%ROWTYPE;
BEGIN
  IF NOT fn_es_staff_stock() THEN
    RAISE EXCEPTION 'sin_permiso' USING HINT = 'Solo administrador o encargado de stock pueden editar compras.';
  END IF;
  SELECT * INTO v_c FROM compras WHERE id = p_compra_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'compra_no_encontrada'; END IF;
  IF p_estado NOT IN ('pedido','en_transito','cancelado') THEN
    RAISE EXCEPTION 'estado_invalido' USING HINT = 'Las recepciones se registran con "Recibir".';
  END IF;
  IF v_c.estado IN ('recibido','recibido_parcial') THEN
    RAISE EXCEPTION 'compra_con_recepciones' USING HINT = 'Ya tiene mercadería recibida: no se puede cambiar el estado.';
  END IF;
  IF v_c.estado = 'cancelado' THEN
    RAISE EXCEPTION 'compra_cancelada' USING HINT = 'La compra está cancelada.';
  END IF;
  UPDATE compras SET estado = p_estado, fecha_estimada = coalesce(p_fecha_estimada, fecha_estimada) WHERE id = v_c.id;
  INSERT INTO historial_actividad (accion, entidad, entidad_id, descripcion, usuario_id)
  VALUES ('update', 'compras', v_c.id::text, format('Compra %s → %s', v_c.codigo, p_estado), auth.uid());
  RETURN jsonb_build_object('ok', true, 'estado', p_estado);
END;
$$;
REVOKE ALL ON FUNCTION compra_cambiar_estado(BIGINT, TEXT, DATE) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION compra_cambiar_estado(BIGINT, TEXT, DATE) TO authenticated;


-- ──────────────────────────────────────────────
-- 5) PEDIDOS WEB: revisar stock al crear la solicitud
--    Misma función del 006 con dos agregados:
--    - producto controlado sin disponible → el pedido NO se crea
--      ('sin_stock' con el detalle por producto; el carrito lo muestra)
--    - producto con precio pero sin controlar → stock_a_confirmar
--      (el pedido sale, pero "a confirmar": sin pago online)
-- ──────────────────────────────────────────────
ALTER TABLE solicitud_items ADD COLUMN IF NOT EXISTS stock_a_confirmar BOOLEAN NOT NULL DEFAULT false;

CREATE OR REPLACE FUNCTION crear_solicitud(p JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $func$
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
  v_prod      productos%ROWTYPE;
  v_precio    NUMERIC(12,2);
  v_total     NUMERIC(12,2) := 0;
  v_hay_precio BOOLEAN := false;
  v_pendientes BOOLEAN := false;
  v_sol_id    BIGINT;
  v_codigo    TEXT;
  v_out_items JSONB := '[]'::jsonb;
  v_sin_stock JSONB := '[]'::jsonb;
  v_disp      INT;
  v_a_conf    BOOLEAN;
  v_pedidos   JSONB := '{}'::jsonb;   -- cantidad acumulada por producto (el mismo producto dos veces)
BEGIN
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

  SELECT count(*) INTO v_n FROM solicitudes
   WHERE telefono = v_telefono AND created_at > now() - interval '1 hour';
  IF v_n >= 5 THEN
    RAISE EXCEPTION 'limite_solicitudes' USING HINT = 'Ya recibimos varias solicitudes tuyas. Escribinos directo por WhatsApp.';
  END IF;
  SELECT count(*) INTO v_n FROM solicitudes WHERE created_at > now() - interval '1 hour';
  IF v_n >= 60 THEN
    RAISE EXCEPTION 'limite_global' USING HINT = 'Intentá de nuevo en unos minutos.';
  END IF;

  v_items := coalesce(p->'items', '[]'::jsonb);
  IF jsonb_typeof(v_items) <> 'array' OR jsonb_array_length(v_items) > 30 THEN
    RAISE EXCEPTION 'items_invalidos';
  END IF;
  IF v_canal = 'web' AND jsonb_array_length(v_items) = 0 THEN
    RAISE EXCEPTION 'carrito_vacio' USING HINT = 'Agregá al menos un producto.';
  END IF;

  -- ── Chequeo de stock ANTES de crear nada (controlados con precio) ──
  FOR v_item IN SELECT * FROM jsonb_array_elements(v_items) LOOP
    BEGIN
      v_pid  := (v_item->>'id')::int;
      v_cant := least(greatest(coalesce((v_item->>'cantidad')::int, 1), 1), 999);
    EXCEPTION WHEN OTHERS THEN
      RAISE EXCEPTION 'items_invalidos';
    END;
    v_pedidos := v_pedidos || jsonb_build_object(v_pid::text, coalesce((v_pedidos->>v_pid::text)::int, 0) + v_cant);
  END LOOP;
  FOR v_pid, v_cant IN SELECT key::int, value::int FROM jsonb_each_text(v_pedidos) LOOP
    SELECT * INTO v_prod FROM productos WHERE id = v_pid AND estado = 'activo';
    IF NOT FOUND THEN CONTINUE; END IF;
    IF fn_precio_venta(v_prod) IS NOT NULL
       AND v_prod.seguimiento_inventario AND NOT v_prod.permite_venta_sin_stock
       AND v_prod.stock_controlado THEN
      v_disp := greatest(stock_disponible(v_prod), 0);
      IF v_cant > v_disp THEN
        v_sin_stock := v_sin_stock || jsonb_build_object('id', v_prod.id, 'nombre', v_prod.nombre,
                                                         'pedido', v_cant, 'disponible', v_disp);
      END IF;
    END IF;
  END LOOP;
  IF jsonb_array_length(v_sin_stock) > 0 THEN
    RAISE EXCEPTION 'sin_stock'
      USING DETAIL = v_sin_stock::text,
            HINT = 'Algunos productos ya no tienen stock disponible. Ajustá las cantidades del carrito.';
  END IF;

  v_codigo := 'MH-' || to_char(now(), 'YYMMDD') || '-' ||
              upper(substr(md5(random()::text || clock_timestamp()::text), 1, 4));

  INSERT INTO solicitudes (codigo, canal, cliente_nombre, telefono, localidad, direccion,
                           tipo_entrega, es_mayorista, comercio, cuit, observaciones, estado)
  VALUES (v_codigo, v_canal, v_nombre, v_telefono, v_localidad, v_direccion,
          v_entrega, v_mayorista, v_comercio, v_cuit, v_obs, 'nueva')
  RETURNING id INTO v_sol_id;

  FOR v_item IN SELECT * FROM jsonb_array_elements(v_items) LOOP
    v_pid  := (v_item->>'id')::int;
    v_cant := least(greatest(coalesce((v_item->>'cantidad')::int, 1), 1), 999);

    SELECT * INTO v_prod FROM productos WHERE id = v_pid AND estado = 'activo';
    IF NOT FOUND THEN
      CONTINUE;
    END IF;

    v_precio := fn_precio_venta(v_prod);
    -- Con precio pero stock sin controlar: sale, pero el stock se confirma por WhatsApp
    v_a_conf := v_precio IS NOT NULL AND v_prod.seguimiento_inventario
                AND NOT v_prod.permite_venta_sin_stock AND NOT v_prod.stock_controlado;

    INSERT INTO solicitud_items (solicitud_id, producto_id, nombre, sku, cantidad, precio_unitario, subtotal, stock_a_confirmar)
    VALUES (v_sol_id, v_prod.id, v_prod.nombre, v_prod.sku, v_cant, v_precio,
            CASE WHEN v_precio IS NULL THEN NULL ELSE round(v_precio * v_cant, 2) END, v_a_conf);

    IF v_precio IS NULL OR v_a_conf THEN
      v_pendientes := true;
    END IF;
    IF v_precio IS NOT NULL THEN
      v_hay_precio := true;
      v_total := v_total + round(v_precio * v_cant, 2);
    END IF;

    v_out_items := v_out_items || jsonb_build_object(
      'nombre', v_prod.nombre, 'sku', v_prod.sku, 'cantidad', v_cant, 'precio', v_precio,
      'stock_a_confirmar', v_a_conf);
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
$func$;

REVOKE ALL ON FUNCTION crear_solicitud(JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION crear_solicitud(JSONB) TO anon, authenticated;


-- ──────────────────────────────────────────────
-- 6) CATÁLOGO DEL BOT: informa si el stock está controlado
--    (se agrega una columna al final: CREATE OR REPLACE lo permite)
-- ──────────────────────────────────────────────
CREATE OR REPLACE VIEW catalogo_bot WITH (security_invoker = true) AS
SELECT
  p.id,
  p.sku,
  p.nombre,
  coalesce(nullif(btrim(p.descripcion_corta), ''), left(p.descripcion, 400)) AS descripcion,
  c.nombre AS categoria,
  p.marca,
  CASE WHEN p.en_oferta AND coalesce(p.precio_oferta, 0) > 0 THEN p.precio_oferta
       WHEN coalesce(p.precio_minorista, 0) > 0 THEN p.precio_minorista
  END AS precio,
  (p.en_oferta AND coalesce(p.precio_oferta, 0) > 0) AS en_oferta,
  CASE WHEN p.en_oferta AND coalesce(p.precio_oferta, 0) > 0
             AND coalesce(p.precio_minorista, 0) > p.precio_oferta
       THEN p.precio_minorista
  END AS precio_anterior,
  -- true = se puede ofrecer (o consultar). false solo si está controlado y no hay.
  CASE
    WHEN NOT (coalesce(p.precio_minorista, 0) > 0
              OR (p.en_oferta AND coalesce(p.precio_oferta, 0) > 0)) THEN true
    WHEN NOT p.seguimiento_inventario OR p.permite_venta_sin_stock THEN true
    WHEN NOT p.stock_controlado THEN true
    ELSE stock_disponible(p) > 0
  END AS disponible,
  'https://mundohogarstf.com/producto/' || p.slug AS url,
  p.imagen_principal_url AS imagen,
  p.updated_at AS actualizado,
  p.stock_controlado
FROM productos p
LEFT JOIN categorias c ON c.id = p.categoria_id
WHERE p.estado = 'activo';
GRANT SELECT ON catalogo_bot TO anon, authenticated;


NOTIFY pgrst, 'reload schema';

-- ============================================================
-- VERIFICACIÓN RÁPIDA (correr aparte):
--   1. SELECT id, nombre, stock_actual, stock_controlado, stock_disponible
--        FROM productos LIMIT 5;   (la columna calculada responde)
--   2. Panel → Contar stock → contar 3 de un producto → queda controlado,
--      aparece el movimiento y la tienda lo muestra "Agregar".
--   3. Panel → Vender → vender 1 → stock 2, venta VL-… en el listado;
--      vender un producto sin controlar → no toca stock.
--   4. Panel → Compras → pegar lista → coincidencias → crear → recibir →
--      entradas de stock con referencia OC-….
--   5. Como anónimo: crear_solicitud con más unidades que el disponible
--      de un producto controlado → 'sin_stock'.
-- ============================================================
