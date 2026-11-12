-- ============================================================
-- 029 — ROL "CAJERO" (2026-11-12)
-- Ejecutar DESPUÉS del 028. Idempotente.
--
-- Separa quién vende de quién cobra. El cajero arranca con:
--   caja (ver, abrir y cerrar, cobrar, ingresos y egresos),
--   cuentas corrientes (ver y registrar pagos), cobrar pedidos web,
--   retiros y envíos (ver y entregar).
-- No crea ventas. Todo se cambia después en Administración → Permisos.
-- Al vendedor NO se le saca nada: cuando haya un cajero, el administrador
-- destilda "Cobrar ventas en la caja" al vendedor si quiere que cobre solo él.
-- ============================================================

-- 1) El rol existe para los usuarios y para los permisos
--    (se borra la regla vieja de roles, se llame como se llame)
DO $c$
DECLARE r RECORD;
BEGIN
  FOR r IN SELECT conrelid::regclass AS t, conname FROM pg_constraint
            WHERE contype = 'c' AND conrelid::regclass::text IN ('profiles', 'rol_permisos')
              AND pg_get_constraintdef(oid) ~ 'vendedor' LOOP
    EXECUTE format('ALTER TABLE %s DROP CONSTRAINT %I', r.t, r.conname);
  END LOOP;
END
$c$;
ALTER TABLE profiles ADD CONSTRAINT profiles_rol_check
  CHECK (rol IN ('administrador', 'encargado_stock', 'vendedor', 'cajero'));
ALTER TABLE rol_permisos ADD CONSTRAINT rol_permisos_rol_check
  CHECK (rol IN ('encargado_stock', 'vendedor', 'cajero'));

-- 2) Guardar permisos acepta el rol nuevo
DO $patch$
DECLARE d TEXT; a TEXT;
BEGIN
  d := pg_get_functiondef('permisos_rol_guardar(text,text[])'::regprocedure);
  IF position('''cajero''' IN d) = 0 THEN
    a := 'p_rol NOT IN (''encargado_stock'', ''vendedor'')';
    IF position(a IN d) = 0 THEN RAISE EXCEPTION '029: permisos_rol_guardar no tiene el texto esperado'; END IF;
    d := replace(d, a, 'p_rol NOT IN (''encargado_stock'', ''vendedor'', ''cajero'')');
    d := replace(d, 'los demás roles son vendedor y encargado de stock.', 'los demás roles son vendedor, cajero y encargado de stock.');
    EXECUTE d;
  END IF;
END
$patch$;

-- 3) Permisos iniciales del cajero (solo la primera vez: si después el
--    administrador los cambia, correr esto de nuevo no los pisa)
INSERT INTO rol_permisos (rol, permiso)
SELECT 'cajero', p.clave FROM permisos p
 WHERE p.clave IN ('caja.ver', 'caja.abrir_cerrar', 'caja.cobrar', 'caja.movimientos',
                   'cc.ver', 'cc.cobrar', 'pedidos.cobrar', 'entregas.ver', 'entregas.gestionar')
   AND NOT EXISTS (SELECT 1 FROM rol_permisos WHERE rol = 'cajero')
ON CONFLICT DO NOTHING;

NOTIFY pgrst, 'reload schema';

SELECT (SELECT array_agg(permiso ORDER BY permiso) FROM rol_permisos WHERE rol = 'cajero') AS permisos_cajero;
