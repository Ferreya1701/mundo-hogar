-- ============================================================
-- Mundo Hogar — Esquema de base de datos v1.0
-- Ejecutar en: Supabase Dashboard → SQL Editor
-- ============================================================

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- ──────────────────────────────────────────────
-- PERFILES (extiende auth.users de Supabase)
-- ──────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS profiles (
  id              UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  nombre          TEXT NOT NULL,
  email           TEXT,
  rol             TEXT NOT NULL DEFAULT 'vendedor'
                    CHECK (rol IN ('administrador', 'encargado_stock', 'vendedor')),
  activo          BOOLEAN NOT NULL DEFAULT true,
  avatar_url      TEXT,
  ultimo_acceso   TIMESTAMPTZ,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ──────────────────────────────────────────────
-- CATEGORÍAS
-- ──────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS categorias (
  id          SERIAL PRIMARY KEY,
  nombre      TEXT NOT NULL,
  slug        TEXT NOT NULL UNIQUE,
  descripcion TEXT,
  imagen_url  TEXT,
  activo      BOOLEAN NOT NULL DEFAULT true,
  orden       INT NOT NULL DEFAULT 0,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ──────────────────────────────────────────────
-- SUBCATEGORÍAS
-- ──────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS subcategorias (
  id           SERIAL PRIMARY KEY,
  categoria_id INT NOT NULL REFERENCES categorias(id) ON DELETE RESTRICT,
  nombre       TEXT NOT NULL,
  slug         TEXT NOT NULL,
  descripcion  TEXT,
  activo       BOOLEAN NOT NULL DEFAULT true,
  orden        INT NOT NULL DEFAULT 0,
  UNIQUE(categoria_id, slug)
);

-- ──────────────────────────────────────────────
-- PRODUCTOS
-- ──────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS productos (
  id                        SERIAL PRIMARY KEY,
  sku                       TEXT UNIQUE,
  codigo_barras             TEXT,
  nombre                    TEXT NOT NULL,
  slug                      TEXT UNIQUE,
  descripcion_corta         TEXT,
  descripcion               TEXT,
  categoria_id              INT REFERENCES categorias(id) ON DELETE SET NULL,
  subcategoria_id           INT REFERENCES subcategorias(id) ON DELETE SET NULL,
  marca                     TEXT,
  precio_costo              NUMERIC(12,2),
  precio_minorista          NUMERIC(12,2),
  precio_mayorista          NUMERIC(12,2),
  precio_oferta             NUMERIC(12,2),
  en_oferta                 BOOLEAN NOT NULL DEFAULT false,
  stock_actual              INT NOT NULL DEFAULT 0,
  stock_minimo              INT NOT NULL DEFAULT 0,
  unidad                    TEXT NOT NULL DEFAULT 'unidad',
  ubicacion                 TEXT,
  proveedor                 TEXT,
  permite_venta_sin_stock   BOOLEAN NOT NULL DEFAULT false,
  seguimiento_inventario    BOOLEAN NOT NULL DEFAULT true,
  estado                    TEXT NOT NULL DEFAULT 'activo'
                              CHECK (estado IN ('activo', 'inactivo', 'archivado')),
  destacado                 BOOLEAN NOT NULL DEFAULT false,
  es_nuevo                  BOOLEAN NOT NULL DEFAULT false,
  peso                      NUMERIC(10,3),
  alto                      NUMERIC(10,2),
  ancho                     NUMERIC(10,2),
  profundidad               NUMERIC(10,2),
  material                  TEXT,
  color                     TEXT,
  garantia                  TEXT,
  etiquetas                 TEXT[] DEFAULT '{}',
  observaciones             TEXT,
  imagen_principal_url      TEXT,
  created_at                TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at                TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_by                UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  updated_by                UUID REFERENCES auth.users(id) ON DELETE SET NULL
);

-- ──────────────────────────────────────────────
-- IMÁGENES DE PRODUCTOS
-- ──────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS producto_imagenes (
  id           SERIAL PRIMARY KEY,
  producto_id  INT NOT NULL REFERENCES productos(id) ON DELETE CASCADE,
  url          TEXT NOT NULL,
  alt          TEXT,
  es_principal BOOLEAN NOT NULL DEFAULT false,
  orden        INT NOT NULL DEFAULT 0,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ──────────────────────────────────────────────
-- MOVIMIENTOS DE INVENTARIO
-- ──────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS movimientos_inventario (
  id              SERIAL PRIMARY KEY,
  producto_id     INT NOT NULL REFERENCES productos(id) ON DELETE RESTRICT,
  tipo            TEXT NOT NULL CHECK (tipo IN (
                    'carga_inicial', 'entrada_compra', 'salida_venta',
                    'ajuste_positivo', 'ajuste_negativo',
                    'devolucion_cliente', 'devolucion_proveedor',
                    'producto_danado', 'perdida', 'transferencia', 'correccion'
                  )),
  cantidad        INT NOT NULL,
  stock_anterior  INT NOT NULL,
  stock_posterior INT NOT NULL,
  motivo          TEXT,
  observacion     TEXT,
  referencia      TEXT,
  usuario_id      UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ──────────────────────────────────────────────
-- HISTORIAL DE ACTIVIDAD (auditoría)
-- ──────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS historial_actividad (
  id                  SERIAL PRIMARY KEY,
  accion              TEXT NOT NULL,
  entidad             TEXT,
  entidad_id          TEXT,
  descripcion         TEXT,
  valores_anteriores  JSONB,
  valores_nuevos      JSONB,
  usuario_id          UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ──────────────────────────────────────────────
-- ÍNDICES
-- ──────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_productos_categoria  ON productos(categoria_id);
CREATE INDEX IF NOT EXISTS idx_productos_estado     ON productos(estado);
CREATE INDEX IF NOT EXISTS idx_productos_sku        ON productos(sku) WHERE sku IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_mov_producto         ON movimientos_inventario(producto_id);
CREATE INDEX IF NOT EXISTS idx_mov_created          ON movimientos_inventario(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_hist_usuario         ON historial_actividad(usuario_id);
CREATE INDEX IF NOT EXISTS idx_hist_created         ON historial_actividad(created_at DESC);

-- ──────────────────────────────────────────────
-- FUNCIÓN: updated_at automático
-- ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;

CREATE OR REPLACE TRIGGER tr_productos_updated_at
  BEFORE UPDATE ON productos FOR EACH ROW EXECUTE FUNCTION fn_updated_at();
CREATE OR REPLACE TRIGGER tr_categorias_updated_at
  BEFORE UPDATE ON categorias FOR EACH ROW EXECUTE FUNCTION fn_updated_at();
CREATE OR REPLACE TRIGGER tr_profiles_updated_at
  BEFORE UPDATE ON profiles FOR EACH ROW EXECUTE FUNCTION fn_updated_at();

-- ──────────────────────────────────────────────
-- FUNCIÓN: crear perfil automáticamente
-- ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_create_profile()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  INSERT INTO profiles (id, email, nombre, rol)
  VALUES (
    NEW.id,
    NEW.email,
    COALESCE(NEW.raw_user_meta_data->>'nombre', split_part(NEW.email, '@', 1)),
    COALESCE(NEW.raw_user_meta_data->>'rol', 'vendedor')
  )
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE TRIGGER tr_auth_user_created
  AFTER INSERT ON auth.users FOR EACH ROW EXECUTE FUNCTION fn_create_profile();

-- ──────────────────────────────────────────────
-- FUNCIÓN: obtener rol del usuario actual
-- ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_get_user_role()
RETURNS TEXT LANGUAGE SQL STABLE SECURITY DEFINER AS $$
  SELECT rol FROM profiles WHERE id = auth.uid() AND activo = true;
$$;

-- ──────────────────────────────────────────────
-- FUNCIÓN: registrar movimiento y actualizar stock (transacción atómica)
-- ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_registrar_movimiento(
  p_producto_id   INT,
  p_tipo          TEXT,
  p_cantidad      INT,
  p_motivo        TEXT DEFAULT NULL,
  p_observacion   TEXT DEFAULT NULL,
  p_referencia    TEXT DEFAULT NULL
)
RETURNS movimientos_inventario LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_stock_ant  INT;
  v_stock_new  INT;
  v_delta      INT;
  v_result     movimientos_inventario;
BEGIN
  SELECT stock_actual INTO v_stock_ant
  FROM productos WHERE id = p_producto_id FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Producto no encontrado: %', p_producto_id;
  END IF;

  -- Determinar delta (positivo = suma, negativo = resta)
  CASE p_tipo
    WHEN 'carga_inicial','entrada_compra','ajuste_positivo','devolucion_cliente'
      THEN v_delta :=  ABS(p_cantidad);
    WHEN 'salida_venta','ajuste_negativo','devolucion_proveedor','producto_danado','perdida'
      THEN v_delta := -ABS(p_cantidad);
    ELSE v_delta := p_cantidad; -- transferencia/correccion: valor firmado
  END CASE;

  v_stock_new := v_stock_ant + v_delta;

  IF v_stock_new < 0 THEN
    RAISE EXCEPTION 'Stock insuficiente. Actual: %, Movimiento: %', v_stock_ant, v_delta;
  END IF;

  UPDATE productos SET stock_actual = v_stock_new, updated_by = auth.uid()
  WHERE id = p_producto_id;

  INSERT INTO movimientos_inventario
    (producto_id, tipo, cantidad, stock_anterior, stock_posterior,
     motivo, observacion, referencia, usuario_id)
  VALUES
    (p_producto_id, p_tipo, ABS(p_cantidad), v_stock_ant, v_stock_new,
     p_motivo, p_observacion, p_referencia, auth.uid())
  RETURNING * INTO v_result;

  RETURN v_result;
END;
$$;
