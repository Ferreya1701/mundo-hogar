-- ============================================================
-- 016 — PERMISOS TILDABLES POR ROL (2026-11-11)
-- Ejecutar en Supabase → SQL Editor, DESPUÉS del 015.
-- Idempotente: se puede correr más de una vez sin romper nada.
--
-- Por qué existe: hasta ahora "qué puede hacer cada rol" estaba escrito
-- adentro de cada función y cada política (rol IN ('administrador',
-- 'vendedor') …). Para cambiar algo había que tocar código. Desde acá:
--
--   • permisos       → la lista de cosas que se pueden habilitar.
--   • rol_permisos   → qué tiene tildado cada rol (vendedor y encargado
--                       de stock). El ADMINISTRADOR siempre puede todo:
--                       no se guarda ni se puede quitar.
--   • fn_tiene_permiso('clave') → lo que consultan la base y el panel.
--
-- El control sigue estando EN LA BASE: si a un rol se le destilda un
-- permiso, la función o la política lo rechaza aunque la pantalla
-- mostrara el botón.
--
-- Al instalarse, cada rol queda con EXACTAMENTE lo que podía hacer antes
-- (nadie gana ni pierde acceso ese día). Cuando una migración futura
-- agrega permisos nuevos, sus valores iniciales se aplican una sola vez:
-- volver a correr el script no vuelve a tildar lo que el administrador
-- destildó.
--
-- Quedan SOLO para el administrador (no se delegan): usuarios, permisos,
-- configuración, cuentas bancarias, liquidaciones, historial de actividad
-- y borrar productos.
-- ============================================================


-- ──────────────────────────────────────────────
-- 1) Tablas
-- ──────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS permisos (
  clave              TEXT PRIMARY KEY CHECK (clave ~ '^[a-z_]+\.[a-z_]+$'),
  modulo             TEXT NOT NULL,
  nombre             TEXT NOT NULL,
  descripcion        TEXT,
  orden              INT  NOT NULL DEFAULT 0,
  -- Los valores iniciales ya se aplicaron (no se vuelven a aplicar)
  iniciales_aplicados BOOLEAN NOT NULL DEFAULT false
);

CREATE TABLE IF NOT EXISTS rol_permisos (
  rol        TEXT NOT NULL CHECK (rol IN ('encargado_stock', 'vendedor')),
  permiso    TEXT NOT NULL REFERENCES permisos(clave) ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  PRIMARY KEY (rol, permiso)
);


-- ──────────────────────────────────────────────
-- 2) Catálogo + valores iniciales (= lo que cada rol podía hacer antes)
-- ──────────────────────────────────────────────
CREATE TEMP TABLE _permisos_016 (clave TEXT, modulo TEXT, nombre TEXT, descripcion TEXT, orden INT, roles TEXT[]) ON COMMIT DROP;
INSERT INTO _permisos_016 VALUES
  ('ventas.crear',          'Ventas',      'Crear ventas en el local',
     'Usar "Crear venta" y cobrar en el mostrador.',                                         10, ARRAY['vendedor','encargado_stock']),
  ('ventas.ver_todas',      'Ventas',      'Ver las ventas de todos',
     'Sin este permiso, cada uno ve solo las ventas que hizo.',                             20, ARRAY['encargado_stock']),
  ('ventas.anular_propias', 'Ventas',      'Anular sus propias ventas (hasta 24 h)',
     'Anular una venta que hizo esa misma persona en las últimas 24 horas.',                 30, ARRAY['vendedor','encargado_stock']),
  ('ventas.anular_todas',   'Ventas',      'Anular cualquier venta',
     'Anular ventas de otros vendedores o de más de 24 horas.',                              40, ARRAY[]::TEXT[]),
  ('pedidos.gestionar',     'Pedidos web', 'Gestionar pedidos web',
     'Cambiar el estado de los pedidos de la tienda (confirmar, entregar, cancelar).',       50, ARRAY['vendedor']),
  ('pedidos.cobrar',        'Pedidos web', 'Cobrar pedidos web',
     'Habilitar el pago, confirmar o rechazar comprobantes de transferencia.',               60, ARRAY['vendedor']),
  ('pedidos.anular_pago',   'Pedidos web', 'Anular un pago confirmado',
     'Deshacer un cobro ya confirmado de un pedido web.',                                    70, ARRAY[]::TEXT[]),
  ('clientes.gestionar',    'Clientes',    'Ver y gestionar clientes',
     'Entrar a Clientes (CRM): contactos, oportunidades y notas.',                           80, ARRAY['vendedor']),
  ('productos.editar',      'Catálogo',    'Crear y editar productos',
     'Alta y edición de productos y sus fotos. Borrar productos es solo del administrador.', 90, ARRAY['encargado_stock']),
  ('categorias.editar',     'Catálogo',    'Crear y editar categorías',
     'Alta, edición y baja de categorías y subcategorías.',                                 100, ARRAY[]::TEXT[]),
  ('stock.contar',          'Stock',       'Contar stock',
     'Cargar conteos y pasar productos a "controlado" o "sin contar".',                     110, ARRAY['encargado_stock']),
  ('stock.ajustar',         'Stock',       'Ajuste manual de stock',
     'Registrar entradas, salidas, roturas y correcciones a mano.',                         120, ARRAY['encargado_stock']),
  ('compras.gestionar',     'Stock',       'Compras, proveedores y costos',
     'Cargar y recibir compras y ver o editar el costo de los productos.',                  130, ARRAY['encargado_stock']);

INSERT INTO permisos (clave, modulo, nombre, descripcion, orden)
SELECT clave, modulo, nombre, descripcion, orden FROM _permisos_016
ON CONFLICT (clave) DO UPDATE SET
  modulo = EXCLUDED.modulo, nombre = EXCLUDED.nombre,
  descripcion = EXCLUDED.descripcion, orden = EXCLUDED.orden;

INSERT INTO rol_permisos (rol, permiso)
SELECT unnest(n.roles), n.clave
FROM _permisos_016 n JOIN permisos p ON p.clave = n.clave
WHERE NOT p.iniciales_aplicados
ON CONFLICT DO NOTHING;

UPDATE permisos SET iniciales_aplicados = true
WHERE clave IN (SELECT clave FROM _permisos_016) AND NOT iniciales_aplicados;


-- ──────────────────────────────────────────────
-- 3) Consultas
-- ──────────────────────────────────────────────
-- ¿El usuario actual puede hacer esto? Cuenta desactivada o sin sesión: no.
CREATE OR REPLACE FUNCTION fn_tiene_permiso(p_clave TEXT)
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT coalesce((
    SELECT pr.rol = 'administrador'
        OR EXISTS (SELECT 1 FROM rol_permisos rp WHERE rp.rol = pr.rol AND rp.permiso = p_clave)
    FROM profiles pr
    WHERE pr.id = auth.uid() AND pr.activo
  ), false)
$$;

-- Lo que el panel necesita para mostrar u ocultar menús y botones.
CREATE OR REPLACE FUNCTION fn_mis_permisos()
RETURNS TEXT[] LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT coalesce(array_agg(p.clave ORDER BY p.orden), ARRAY[]::TEXT[])
  FROM permisos p
  WHERE fn_tiene_permiso(p.clave)
$$;

REVOKE ALL ON FUNCTION fn_tiene_permiso(TEXT) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION fn_mis_permisos()      FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION fn_tiene_permiso(TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION fn_mis_permisos()      TO authenticated;


-- ──────────────────────────────────────────────
-- 4) Guardar los permisos de un rol (solo administrador)
-- ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION permisos_rol_guardar(p_rol TEXT, p_permisos TEXT[])
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_lista      TEXT[] := ARRAY(SELECT DISTINCT unnest(coalesce(p_permisos, ARRAY[]::TEXT[])));
  v_desconoc   TEXT[];
  v_agregados  TEXT[];
  v_quitados   TEXT[];
BEGIN
  IF coalesce(fn_get_user_role(), '') <> 'administrador' THEN
    RAISE EXCEPTION 'sin_permiso' USING HINT = 'Solo el administrador puede cambiar permisos.';
  END IF;
  IF p_rol IS NULL OR p_rol NOT IN ('encargado_stock', 'vendedor') THEN
    RAISE EXCEPTION 'rol_invalido' USING HINT = 'El administrador siempre tiene todos los permisos; los demás roles son vendedor y encargado de stock.';
  END IF;
  v_desconoc := ARRAY(SELECT x FROM unnest(v_lista) x WHERE NOT EXISTS (SELECT 1 FROM permisos WHERE clave = x));
  IF cardinality(v_desconoc) > 0 THEN
    RAISE EXCEPTION 'permiso_desconocido' USING HINT = 'No existe el permiso: ' || array_to_string(v_desconoc, ', ');
  END IF;

  -- Un cambio de permisos por vez (dos administradores guardando a la par)
  PERFORM pg_advisory_xact_lock(hashtext('rol_permisos:' || p_rol));

  v_quitados := ARRAY(SELECT permiso FROM rol_permisos WHERE rol = p_rol AND permiso <> ALL (v_lista) ORDER BY permiso);
  v_agregados := ARRAY(SELECT x FROM unnest(v_lista) x
                       WHERE NOT EXISTS (SELECT 1 FROM rol_permisos WHERE rol = p_rol AND permiso = x) ORDER BY x);

  DELETE FROM rol_permisos WHERE rol = p_rol AND permiso = ANY (v_quitados);
  INSERT INTO rol_permisos (rol, permiso, created_by)
  SELECT p_rol, x, auth.uid() FROM unnest(v_agregados) x;

  IF cardinality(v_agregados) + cardinality(v_quitados) > 0 THEN
    INSERT INTO historial_actividad (usuario_id, accion, entidad, entidad_id, descripcion, valores_nuevos)
    VALUES (auth.uid(), 'actualizar', 'permisos', p_rol,
            'Permisos del rol ' || p_rol || ' cambiados',
            jsonb_build_object('agregados', to_jsonb(v_agregados), 'quitados', to_jsonb(v_quitados)));
  END IF;

  RETURN jsonb_build_object('ok', true, 'rol', p_rol,
                            'agregados', to_jsonb(v_agregados), 'quitados', to_jsonb(v_quitados));
END;
$$;

REVOKE ALL ON FUNCTION permisos_rol_guardar(TEXT, TEXT[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION permisos_rol_guardar(TEXT, TEXT[]) TO authenticated;


-- ──────────────────────────────────────────────
-- 5) Quién lee las tablas de permisos
-- ──────────────────────────────────────────────
ALTER TABLE permisos     ENABLE ROW LEVEL SECURITY;
ALTER TABLE rol_permisos ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "permisos_select_staff" ON permisos;
CREATE POLICY "permisos_select_staff" ON permisos FOR SELECT
  USING (fn_get_user_role() IS NOT NULL);

DROP POLICY IF EXISTS "rol_permisos_select_admin" ON rol_permisos;
CREATE POLICY "rol_permisos_select_admin" ON rol_permisos FOR SELECT
  USING (fn_get_user_role() = 'administrador');
-- Sin políticas de escritura: solo permisos_rol_guardar.

REVOKE ALL ON permisos, rol_permisos FROM anon;
GRANT SELECT ON permisos, rol_permisos TO authenticated;


-- ──────────────────────────────────────────────
-- 6) Las funciones existentes pasan a consultar permisos
-- ──────────────────────────────────────────────
-- Cada función se toma tal como está instalada y se cambia SOLO la línea
-- que controla el acceso (lo de la columna "antes" por lo de "después").
-- Si ya estaba cambiada, se saltea. Si no se encuentra ni lo uno ni lo
-- otro, el script se detiene sin cambiar nada: alguien modificó la
-- función a mano y hay que revisarla.
DO $migr$
DECLARE
  r      RECORD;
  v_def  TEXT;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    -- Ajuste manual (inventario.html). Las ventas y compras pasan por la vía interna.
    ('fn_registrar_movimiento(integer,text,integer,text,text,text,boolean)',
     $a$coalesce(fn_get_user_role(), '') NOT IN ('administrador','encargado_stock')$a$,
     $b$NOT fn_tiene_permiso('stock.ajustar')$b$),
    -- Contar stock
    ('fn_stock_contar(integer,integer,text)',
     $a$coalesce(fn_get_user_role(), '') NOT IN ('administrador','encargado_stock')$a$,
     $b$NOT fn_tiene_permiso('stock.contar')$b$),
    ('fn_stock_contar_lote(jsonb)',
     $a$coalesce(fn_get_user_role(), '') NOT IN ('administrador','encargado_stock')$a$,
     $b$NOT fn_tiene_permiso('stock.contar')$b$),
    -- Contar y recibir compras ya controlaron su permiso: el movimiento de
    -- stock que generan va por la vía interna (no exige "ajuste manual").
    ('fn_stock_contar(integer,integer,text)',
     $a$  v_delta := p_cantidad - v_prod.stock_actual;$a$,
     $b$  PERFORM set_config('mh.interno', '1', true);  -- 016: el permiso ya se controló arriba
  v_delta := p_cantidad - v_prod.stock_actual;$b$),
    ('fn_compra_recibir(bigint,jsonb,text,boolean)',
     $a$    v_mov := NULL; v_mov_prev := NULL;$a$,
     $b$    PERFORM set_config('mh.interno', '1', true);  -- 016: el permiso ya se controló en compra_recibir
    v_mov := NULL; v_mov_prev := NULL;$b$),
    ('fn_stock_quitar_control(integer)',
     $a$coalesce(fn_get_user_role(), '') NOT IN ('administrador','encargado_stock')$a$,
     $b$NOT fn_tiene_permiso('stock.contar')$b$),
    -- Alta rápida de producto (desde Contar stock / Compras)
    ('producto_crear_rapido(jsonb)',
     $a$coalesce(fn_get_user_role(), '') NOT IN ('administrador','encargado_stock')$a$,
     $b$NOT fn_tiene_permiso('productos.editar')$b$),
    -- Pedidos web
    ('cambiar_estado_solicitud(bigint,text)',
     $a$coalesce(fn_get_user_role(), '') NOT IN ('administrador','vendedor')$a$,
     $b$NOT fn_tiene_permiso('pedidos.gestionar')$b$),
    ('anular_pago(bigint,text)',
     $a$coalesce(fn_get_user_role(), '') <> 'administrador'$a$,
     $b$NOT fn_tiene_permiso('pedidos.anular_pago')$b$),
    -- Clientes (CRM)
    ('crm_nueva_consulta(jsonb)',
     $a$coalesce(fn_get_user_role(), '') NOT IN ('administrador','vendedor')$a$,
     $b$NOT fn_tiene_permiso('clientes.gestionar')$b$),
    ('crm_base_conversacion()',
     $a$coalesce(fn_get_user_role(), '') NOT IN ('administrador','vendedor')$a$,
     $b$NOT fn_tiene_permiso('clientes.gestionar')$b$),
    -- Ventas del local
    ('venta_registrar(jsonb)',
     $a$IF v_rol NOT IN ('administrador','vendedor','encargado_stock') THEN$a$,
     $b$IF NOT fn_tiene_permiso('ventas.crear') THEN$b$),
    ('venta_anular(bigint,text)',
     $a$IF v_rol NOT IN ('administrador','vendedor','encargado_stock') THEN$a$,
     $b$IF NOT (fn_tiene_permiso('ventas.anular_propias') OR fn_tiene_permiso('ventas.anular_todas')) THEN$b$),
    ('venta_anular(bigint,text)',
     $a$IF v_rol <> 'administrador' AND ($a$,
     $b$IF NOT fn_tiene_permiso('ventas.anular_todas') AND ($b$)
  ) AS t(fn, antes, despues)
  LOOP
    v_def := pg_get_functiondef(r.fn::regprocedure);
    IF position(r.despues IN v_def) > 0 THEN
      CONTINUE;  -- ya estaba cambiada (se corrió el 016 antes)
    ELSIF position(r.antes IN v_def) > 0 THEN
      EXECUTE replace(v_def, r.antes, r.despues);
    ELSE
      RAISE EXCEPTION '016: no encontré el control de acceso esperado en %. Revisar esa función antes de seguir.', r.fn;
    END IF;
  END LOOP;
END
$migr$;

-- Los dos atajos que usan muchas funciones y políticas de compras y cobros
CREATE OR REPLACE FUNCTION fn_es_staff_ventas()
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT fn_tiene_permiso('pedidos.cobrar')
$$;

CREATE OR REPLACE FUNCTION fn_es_staff_stock()
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT fn_tiene_permiso('compras.gestionar')
$$;


-- ──────────────────────────────────────────────
-- 7) Políticas que pasan a consultar permisos
-- ──────────────────────────────────────────────
-- Ventas: con "ver todas" ve todo; si no, solo las propias.
DROP POLICY IF EXISTS "ventas_select_staff" ON ventas;
CREATE POLICY "ventas_select_staff" ON ventas FOR SELECT
  USING (fn_tiene_permiso('ventas.ver_todas')
         OR (fn_get_user_role() IS NOT NULL AND vendedor_id = auth.uid()));

-- Pedidos web
DROP POLICY IF EXISTS "solicitudes_update_staff" ON solicitudes;
CREATE POLICY "solicitudes_update_staff" ON solicitudes FOR UPDATE
  USING (fn_tiene_permiso('pedidos.gestionar'));

-- Productos y fotos (borrar sigue siendo del administrador)
DROP POLICY IF EXISTS "productos_insert_staff" ON productos;
CREATE POLICY "productos_insert_staff" ON productos FOR INSERT
  WITH CHECK (fn_tiene_permiso('productos.editar'));
DROP POLICY IF EXISTS "productos_update_staff" ON productos;
CREATE POLICY "productos_update_staff" ON productos FOR UPDATE
  USING (fn_tiene_permiso('productos.editar'));
DROP POLICY IF EXISTS "imagenes_insert_staff" ON producto_imagenes;
CREATE POLICY "imagenes_insert_staff" ON producto_imagenes FOR INSERT
  WITH CHECK (fn_tiene_permiso('productos.editar'));
DROP POLICY IF EXISTS "imagenes_update_staff" ON producto_imagenes;
CREATE POLICY "imagenes_update_staff" ON producto_imagenes FOR UPDATE
  USING (fn_tiene_permiso('productos.editar'));

-- Categorías y subcategorías
DROP POLICY IF EXISTS "categorias_insert_admin" ON categorias;
CREATE POLICY "categorias_insert_admin" ON categorias FOR INSERT
  WITH CHECK (fn_tiene_permiso('categorias.editar'));
DROP POLICY IF EXISTS "categorias_update_admin" ON categorias;
CREATE POLICY "categorias_update_admin" ON categorias FOR UPDATE
  USING (fn_tiene_permiso('categorias.editar'));
DROP POLICY IF EXISTS "categorias_delete_admin" ON categorias;
CREATE POLICY "categorias_delete_admin" ON categorias FOR DELETE
  USING (fn_tiene_permiso('categorias.editar'));
DROP POLICY IF EXISTS "subcategorias_insert_admin" ON subcategorias;
CREATE POLICY "subcategorias_insert_admin" ON subcategorias FOR INSERT
  WITH CHECK (fn_tiene_permiso('categorias.editar'));
DROP POLICY IF EXISTS "subcategorias_update_admin" ON subcategorias;
CREATE POLICY "subcategorias_update_admin" ON subcategorias FOR UPDATE
  USING (fn_tiene_permiso('categorias.editar'));
DROP POLICY IF EXISTS "subcategorias_delete_admin" ON subcategorias;
CREATE POLICY "subcategorias_delete_admin" ON subcategorias FOR DELETE
  USING (fn_tiene_permiso('categorias.editar'));

-- Movimientos de stock escritos directo (el panel usa la función)
DROP POLICY IF EXISTS "movimientos_insert_staff" ON movimientos_inventario;
CREATE POLICY "movimientos_insert_staff" ON movimientos_inventario FOR INSERT
  WITH CHECK (fn_tiene_permiso('stock.ajustar'));

-- Clientes (CRM)
DROP POLICY IF EXISTS "crm_contactos_select" ON crm_contactos;
CREATE POLICY "crm_contactos_select" ON crm_contactos FOR SELECT
  USING (fn_tiene_permiso('clientes.gestionar'));
DROP POLICY IF EXISTS "crm_contactos_insert" ON crm_contactos;
CREATE POLICY "crm_contactos_insert" ON crm_contactos FOR INSERT
  WITH CHECK (fn_tiene_permiso('clientes.gestionar'));
DROP POLICY IF EXISTS "crm_contactos_update" ON crm_contactos;
CREATE POLICY "crm_contactos_update" ON crm_contactos FOR UPDATE
  USING (fn_tiene_permiso('clientes.gestionar'))
  WITH CHECK (fn_tiene_permiso('clientes.gestionar'));

DROP POLICY IF EXISTS "crm_oportunidades_select" ON crm_oportunidades;
CREATE POLICY "crm_oportunidades_select" ON crm_oportunidades FOR SELECT
  USING (fn_tiene_permiso('clientes.gestionar'));
DROP POLICY IF EXISTS "crm_oportunidades_insert" ON crm_oportunidades;
CREATE POLICY "crm_oportunidades_insert" ON crm_oportunidades FOR INSERT
  WITH CHECK (fn_tiene_permiso('clientes.gestionar'));
DROP POLICY IF EXISTS "crm_oportunidades_update" ON crm_oportunidades;
CREATE POLICY "crm_oportunidades_update" ON crm_oportunidades FOR UPDATE
  USING (fn_tiene_permiso('clientes.gestionar'))
  WITH CHECK (fn_tiene_permiso('clientes.gestionar'));

DROP POLICY IF EXISTS "crm_actividades_select" ON crm_actividades;
CREATE POLICY "crm_actividades_select" ON crm_actividades FOR SELECT
  USING (fn_tiene_permiso('clientes.gestionar'));
DROP POLICY IF EXISTS "crm_actividades_insert" ON crm_actividades;
CREATE POLICY "crm_actividades_insert" ON crm_actividades FOR INSERT
  WITH CHECK (fn_tiene_permiso('clientes.gestionar')
              AND usuario_id = auth.uid()
              AND tipo IN ('nota','llamada','whatsapp','instagram','visita'));


NOTIFY pgrst, 'reload schema';

-- Para revisar al correrlo: qué quedó tildado para cada rol.
SELECT r.rol, array_agg(r.permiso ORDER BY p.orden) AS permisos
FROM rol_permisos r JOIN permisos p ON p.clave = r.permiso
GROUP BY r.rol ORDER BY r.rol;
