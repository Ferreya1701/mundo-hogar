-- ============================================================
-- Mundo Hogar — Datos Iniciales
-- Ejecutar DESPUÉS de 002-rls-policies.sql
-- ============================================================

-- Categorías (coinciden con el catálogo JSON existente)
INSERT INTO categorias (nombre, slug, activo, orden) VALUES
  ('Electrodomésticos',     'electrodomesticos',    true, 1),
  ('Herramientas',          'herramientas',          true, 2),
  ('Tecnología y Celulares','tecnologia-celulares',  true, 3),
  ('Muebles y Hogar',       'muebles-hogar',         true, 4),
  ('Salud',                 'salud',                 true, 5),
  ('Seguridad',             'seguridad',             true, 6),
  ('Cuidado Personal',      'cuidado-personal',      true, 7)
ON CONFLICT (slug) DO UPDATE SET
  nombre = EXCLUDED.nombre,
  orden  = EXCLUDED.orden,
  activo = EXCLUDED.activo;

-- ──────────────────────────────────────────────
-- BUCKET DE STORAGE
-- Crear manualmente en Supabase Dashboard → Storage → New bucket:
--   Nombre: producto-imagenes
--   Public: SI (para que las imágenes sean accesibles sin autenticación)
-- ──────────────────────────────────────────────

-- ──────────────────────────────────────────────
-- PRIMER ADMINISTRADOR
-- El primer usuario debe crearse desde:
-- Supabase Dashboard → Authentication → Users → Add user
-- Luego actualizar su rol en profiles:
--
-- UPDATE profiles SET rol = 'administrador', nombre = 'Tu Nombre'
-- WHERE email = 'tu@email.com';
-- ──────────────────────────────────────────────
