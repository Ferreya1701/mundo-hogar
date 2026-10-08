-- ============================================================
-- 009 — CRM: contactos, oportunidades y seguimiento (2026-10-07)
-- Ejecutar en Supabase → SQL Editor, DESPUÉS del 008.
-- Idempotente: se puede correr más de una vez sin romper nada.
-- No modifica ni borra datos existentes: agrega tablas nuevas y
-- conecta las solicitudes de la tienda al CRM.
--
-- Qué agrega:
--   1) crm_contactos      — personas y comercios (uno por teléfono)
--   2) crm_oportunidades  — cada consulta o pedido, con su etapa
--   3) crm_actividades    — historial inmutable: llamadas, WhatsApp,
--                           notas y cambios de etapa
--   4) Cada solicitud de la tienda crea (o reutiliza) su contacto y
--      una oportunidad. La etapa sigue sola al estado del pedido:
--      el pedido es la fuente de verdad (mueve stock), el CRM la lee.
--      Si algo del CRM falla, el pedido se guarda igual: el CRM
--      nunca puede frenar una venta.
--   5) RPC crm_nueva_consulta: carga en un paso una consulta que
--      entró por Instagram, WhatsApp, Facebook, el local, etc.
--
-- Permisos: administrador y vendedor. El encargado de stock no ve el
-- CRM. Nada se borra desde el panel: los contactos se archivan.
--
-- Al pegarlo: abrir Supabase en una ventana de incógnito y SIN el
-- traductor automático del navegador (ya rompió un script antes).
-- ============================================================


-- ──────────────────────────────────────────────
-- 1) FUNCIONES AUXILIARES (puras)
-- ──────────────────────────────────────────────

-- Clave de teléfono para no duplicar contactos: el mismo número escrito
-- como "+54 9 342 648-1326", "0342 15 648-1326" o "3426481326" da
-- siempre "3426481326". La misma regla vive en admin/crm.html (telClave)
-- y las pruebas verifican que las dos coincidan.
CREATE OR REPLACE FUNCTION fn_crm_tel_clave(p_tel TEXT)
RETURNS TEXT LANGUAGE plpgsql IMMUTABLE
SET search_path = public AS $func$
DECLARE
  d   TEXT := regexp_replace(coalesce(p_tel, ''), '\D', '', 'g');
  pos INT;
BEGIN
  IF length(d) < 6 THEN
    RETURN NULL;
  END IF;
  -- Internacional: 54 y, en celulares, el 9 que va después
  IF left(d, 2) = '54' AND length(d) >= 12 THEN
    d := substr(d, 3);
    IF left(d, 1) = '9' THEN
      d := substr(d, 2);
    END IF;
  END IF;
  -- Prefijo de larga distancia nacional
  IF left(d, 1) = '0' THEN
    d := substr(d, 2);
  END IF;
  -- Celular en formato local con 15 (342 15 648-1326): con el 15 son 12 dígitos
  IF length(d) = 12 THEN
    FOREACH pos IN ARRAY ARRAY[3, 2, 4] LOOP
      IF substr(d, pos + 1, 2) = '15' THEN
        d := left(d, pos) || substr(d, pos + 3);
        EXIT;
      END IF;
    END LOOP;
  END IF;
  RETURN right(d, 10);
END;
$func$;

CREATE OR REPLACE FUNCTION fn_crm_etapa_nombre(p_etapa TEXT)
RETURNS TEXT LANGUAGE sql IMMUTABLE
SET search_path = public AS $func$
  SELECT CASE p_etapa
    WHEN 'nueva'      THEN 'Nueva consulta'
    WHEN 'contactado' THEN 'Contactado'
    WHEN 'cotizado'   THEN 'Cotizado'
    WHEN 'ganada'     THEN 'Venta ganada'
    WHEN 'perdida'    THEN 'Perdida'
    ELSE p_etapa
  END
$func$;

-- Estado del pedido (solicitudes) → etapa del CRM
CREATE OR REPLACE FUNCTION fn_crm_etapa_de_solicitud(p_estado TEXT)
RETURNS TEXT LANGUAGE sql IMMUTABLE
SET search_path = public AS $func$
  SELECT CASE p_estado
    WHEN 'nueva'              THEN 'nueva'
    WHEN 'contactado'         THEN 'contactado'
    WHEN 'cotizacion_enviada' THEN 'cotizado'
    WHEN 'confirmado'         THEN 'ganada'
    WHEN 'en_preparacion'     THEN 'ganada'
    WHEN 'entregado'          THEN 'ganada'
    WHEN 'cancelado'          THEN 'perdida'
    ELSE 'nueva'
  END
$func$;


-- ──────────────────────────────────────────────
-- 2) TABLAS
-- ──────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crm_contactos (
  id                  BIGSERIAL PRIMARY KEY,
  tenant_id           INT NOT NULL DEFAULT 1,
  nombre              TEXT NOT NULL CHECK (char_length(nombre) BETWEEN 1 AND 120),
  telefono            TEXT CHECK (telefono IS NULL OR char_length(telefono) <= 40),
  telefono_clave      TEXT,               -- la calcula el trigger, no se escribe a mano
  email               TEXT CHECK (email IS NULL OR char_length(email) <= 160),
  localidad           TEXT CHECK (localidad IS NULL OR char_length(localidad) <= 80),
  tipo                TEXT NOT NULL DEFAULT 'minorista'
                        CHECK (tipo IN ('minorista','mayorista','otro')),
  canal_origen        TEXT NOT NULL DEFAULT 'whatsapp'
                        CHECK (canal_origen IN ('instagram','whatsapp','facebook','web',
                                                'mostrador','referido','otro')),
  instagram           TEXT CHECK (instagram IS NULL OR char_length(instagram) <= 60),
  comercio            TEXT CHECK (comercio IS NULL OR char_length(comercio) <= 120),
  cuit                TEXT CHECK (cuit IS NULL OR char_length(cuit) <= 15),
  notas               TEXT CHECK (notas IS NULL OR char_length(notas) <= 2000),
  archivado           BOOLEAN NOT NULL DEFAULT false,
  ultimo_contacto_at  TIMESTAMPTZ,
  created_by          UUID DEFAULT auth.uid() REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Un contacto activo por teléfono. Los archivados no bloquean.
CREATE UNIQUE INDEX IF NOT EXISTS uq_crm_contactos_tel
  ON crm_contactos(telefono_clave) WHERE telefono_clave IS NOT NULL AND NOT archivado;
CREATE INDEX IF NOT EXISTS idx_crm_contactos_nombre ON crm_contactos(lower(nombre));

CREATE TABLE IF NOT EXISTS crm_oportunidades (
  id                    BIGSERIAL PRIMARY KEY,
  tenant_id             INT NOT NULL DEFAULT 1,
  contacto_id           BIGINT NOT NULL REFERENCES crm_contactos(id) ON DELETE RESTRICT,
  titulo                TEXT NOT NULL CHECK (char_length(titulo) BETWEEN 1 AND 160),
  etapa                 TEXT NOT NULL DEFAULT 'nueva'
                          CHECK (etapa IN ('nueva','contactado','cotizado','ganada','perdida')),
  canal                 TEXT NOT NULL DEFAULT 'whatsapp'
                          CHECK (canal IN ('instagram','whatsapp','facebook','web',
                                           'mostrador','referido','otro')),
  monto                 NUMERIC(12,2) CHECK (monto IS NULL OR monto >= 0),
  -- Pedido de la tienda que originó la oportunidad. Si se borrara el
  -- pedido (no se hace desde el panel), se va con él.
  solicitud_id          BIGINT UNIQUE REFERENCES solicitudes(id) ON DELETE CASCADE,
  responsable_id        UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  proxima_accion        TEXT CHECK (proxima_accion IS NULL OR char_length(proxima_accion) <= 200),
  proxima_accion_fecha  DATE,
  motivo_perdida        TEXT CHECK (motivo_perdida IS NULL OR char_length(motivo_perdida) <= 300),
  cerrada_at            TIMESTAMPTZ,
  created_by            UUID DEFAULT auth.uid() REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at            TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_crm_opp_contacto ON crm_oportunidades(contacto_id);
CREATE INDEX IF NOT EXISTS idx_crm_opp_etapa    ON crm_oportunidades(etapa);
CREATE INDEX IF NOT EXISTS idx_crm_opp_proxima  ON crm_oportunidades(proxima_accion_fecha)
  WHERE etapa IN ('nueva','contactado','cotizado');

CREATE TABLE IF NOT EXISTS crm_actividades (
  id              BIGSERIAL PRIMARY KEY,
  contacto_id     BIGINT NOT NULL REFERENCES crm_contactos(id) ON DELETE CASCADE,
  oportunidad_id  BIGINT REFERENCES crm_oportunidades(id) ON DELETE CASCADE,
  tipo            TEXT NOT NULL CHECK (tipo IN ('nota','llamada','whatsapp','instagram',
                                                'visita','cambio_etapa','sistema')),
  detalle         TEXT CHECK (detalle IS NULL OR char_length(detalle) <= 2000),
  usuario_id      UUID DEFAULT auth.uid() REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_crm_act_contacto ON crm_actividades(contacto_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_crm_act_opp      ON crm_actividades(oportunidad_id);


-- ──────────────────────────────────────────────
-- 3) TRIGGERS DE LAS TABLAS DEL CRM
-- ──────────────────────────────────────────────
CREATE OR REPLACE TRIGGER tr_crm_contactos_updated_at
  BEFORE UPDATE ON crm_contactos FOR EACH ROW EXECUTE FUNCTION fn_updated_at();
CREATE OR REPLACE TRIGGER tr_crm_oportunidades_updated_at
  BEFORE UPDATE ON crm_oportunidades FOR EACH ROW EXECUTE FUNCTION fn_updated_at();

-- Contactos: limpia los datos y calcula la clave del teléfono
CREATE OR REPLACE FUNCTION fn_crm_contacto_normalizar()
RETURNS TRIGGER LANGUAGE plpgsql
SET search_path = public AS $func$
BEGIN
  NEW.nombre    := left(btrim(regexp_replace(NEW.nombre, '\s+', ' ', 'g')), 120);
  NEW.telefono  := nullif(btrim(NEW.telefono), '');
  NEW.email     := nullif(lower(btrim(NEW.email)), '');
  NEW.localidad := nullif(btrim(NEW.localidad), '');
  NEW.instagram := nullif(regexp_replace(btrim(coalesce(NEW.instagram, '')), '^@+', ''), '');
  NEW.comercio  := nullif(btrim(NEW.comercio), '');
  NEW.cuit      := nullif(btrim(NEW.cuit), '');
  NEW.notas     := nullif(btrim(NEW.notas), '');
  NEW.telefono_clave := fn_crm_tel_clave(NEW.telefono);
  RETURN NEW;
END;
$func$;

CREATE OR REPLACE TRIGGER tr_crm_contactos_normalizar
  BEFORE INSERT OR UPDATE ON crm_contactos
  FOR EACH ROW EXECUTE FUNCTION fn_crm_contacto_normalizar();

-- Oportunidades: reglas de etapa y cierre.
-- Las que vienen de un pedido de la tienda solo cambian de etapa por la
-- sincronización (flag transaccional mh.crm_sync), igual que el estado
-- de las solicitudes solo cambia por su RPC (mh.interno, ver 007).
CREATE OR REPLACE FUNCTION fn_crm_oportunidad_antes()
RETURNS TRIGGER LANGUAGE plpgsql
SET search_path = public AS $func$
DECLARE
  v_sync BOOLEAN := coalesce(current_setting('mh.crm_sync', true), '') = '1';
BEGIN
  NEW.titulo         := left(btrim(regexp_replace(NEW.titulo, '\s+', ' ', 'g')), 160);
  NEW.proxima_accion := nullif(btrim(NEW.proxima_accion), '');
  NEW.motivo_perdida := nullif(btrim(NEW.motivo_perdida), '');

  IF TG_OP = 'INSERT' THEN
    IF NEW.solicitud_id IS NOT NULL AND NOT v_sync THEN
      RAISE EXCEPTION 'solicitud_solo_por_sync'
        USING HINT = 'Las oportunidades de los pedidos de la tienda se crean solas.';
    END IF;
  ELSE
    IF NEW.solicitud_id IS DISTINCT FROM OLD.solicitud_id AND NOT v_sync THEN
      RAISE EXCEPTION 'solicitud_solo_por_sync'
        USING HINT = 'No se puede cambiar el pedido vinculado a una oportunidad.';
    END IF;
    IF OLD.solicitud_id IS NOT NULL AND NEW.etapa IS DISTINCT FROM OLD.etapa AND NOT v_sync THEN
      RAISE EXCEPTION 'etapa_por_pedido'
        USING HINT = 'Esta oportunidad viene de un pedido de la tienda: su etapa se actualiza sola al cambiar el estado del pedido en Solicitudes.';
    END IF;
  END IF;

  IF NEW.etapa IN ('ganada','perdida') THEN
    IF TG_OP = 'INSERT' THEN
      NEW.cerrada_at := coalesce(NEW.cerrada_at, now());
    ELSIF OLD.etapa NOT IN ('ganada','perdida') THEN
      NEW.cerrada_at := now();
    END IF;
    -- Cerrada no tiene próximo paso: así no aparece en "Para hoy"
    NEW.proxima_accion       := NULL;
    NEW.proxima_accion_fecha := NULL;
  ELSE
    NEW.cerrada_at := NULL;
  END IF;
  IF NEW.etapa <> 'perdida' THEN
    NEW.motivo_perdida := NULL;
  END IF;
  RETURN NEW;
END;
$func$;

CREATE OR REPLACE TRIGGER tr_crm_oportunidades_antes
  BEFORE INSERT OR UPDATE ON crm_oportunidades
  FOR EACH ROW EXECUTE FUNCTION fn_crm_oportunidad_antes();

-- Oportunidades: deja asentado en el historial el alta y cada cambio de etapa
CREATE OR REPLACE FUNCTION fn_crm_oportunidad_despues()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $func$
BEGIN
  IF TG_OP = 'INSERT' THEN
    INSERT INTO crm_actividades (contacto_id, oportunidad_id, tipo, detalle, usuario_id)
    VALUES (NEW.contacto_id, NEW.id, 'cambio_etapa',
            format('Oportunidad creada en "%s"', fn_crm_etapa_nombre(NEW.etapa)), auth.uid());
  ELSIF NEW.etapa IS DISTINCT FROM OLD.etapa THEN
    INSERT INTO crm_actividades (contacto_id, oportunidad_id, tipo, detalle, usuario_id)
    VALUES (NEW.contacto_id, NEW.id, 'cambio_etapa',
            fn_crm_etapa_nombre(OLD.etapa) || ' → ' || fn_crm_etapa_nombre(NEW.etapa)
              || CASE WHEN NEW.motivo_perdida IS NOT NULL
                      THEN ' (' || NEW.motivo_perdida || ')' ELSE '' END,
            auth.uid());
  END IF;
  RETURN NULL;
END;
$func$;

CREATE OR REPLACE TRIGGER tr_crm_oportunidades_historial
  AFTER INSERT OR UPDATE OF etapa ON crm_oportunidades
  FOR EACH ROW EXECUTE FUNCTION fn_crm_oportunidad_despues();

-- Actividades: el contacto sale siempre de la oportunidad (no pueden
-- quedar cruzados) y el texto vacío se guarda como NULL
CREATE OR REPLACE FUNCTION fn_crm_actividad_antes()
RETURNS TRIGGER LANGUAGE plpgsql
SET search_path = public AS $func$
DECLARE
  v_contacto BIGINT;
BEGIN
  IF NEW.oportunidad_id IS NOT NULL THEN
    SELECT contacto_id INTO v_contacto FROM crm_oportunidades WHERE id = NEW.oportunidad_id;
    IF v_contacto IS NOT NULL THEN
      NEW.contacto_id := v_contacto;
    END IF;
  END IF;
  NEW.detalle := nullif(btrim(NEW.detalle), '');
  RETURN NEW;
END;
$func$;

CREATE OR REPLACE TRIGGER tr_crm_actividades_antes
  BEFORE INSERT ON crm_actividades
  FOR EACH ROW EXECUTE FUNCTION fn_crm_actividad_antes();

-- Actividades: registrar un contacto real (llamada, WhatsApp, Instagram,
-- visita) actualiza "último contacto" y saca de "Nueva consulta" a las
-- oportunidades cargadas a mano (las de pedidos siguen al pedido).
CREATE OR REPLACE FUNCTION fn_crm_actividad_despues()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $func$
BEGIN
  IF NEW.tipo IN ('llamada','whatsapp','instagram','visita') THEN
    UPDATE crm_contactos
       SET ultimo_contacto_at = NEW.created_at
     WHERE id = NEW.contacto_id
       AND (ultimo_contacto_at IS NULL OR ultimo_contacto_at < NEW.created_at);

    IF NEW.oportunidad_id IS NOT NULL THEN
      UPDATE crm_oportunidades
         SET etapa = 'contactado'
       WHERE id = NEW.oportunidad_id AND etapa = 'nueva' AND solicitud_id IS NULL;
    END IF;
  END IF;
  RETURN NULL;
END;
$func$;

CREATE OR REPLACE TRIGGER tr_crm_actividades_despues
  AFTER INSERT ON crm_actividades
  FOR EACH ROW EXECUTE FUNCTION fn_crm_actividad_despues();


-- ──────────────────────────────────────────────
-- 4) CONEXIÓN CON LAS SOLICITUDES DE LA TIENDA
-- ──────────────────────────────────────────────

-- Crea (una sola vez) el contacto y la oportunidad de una solicitud.
-- Devuelve el id de la oportunidad. Uso interno: la llaman los
-- triggers y la carga inicial, no el navegador.
CREATE OR REPLACE FUNCTION fn_crm_vincular_solicitud(p_solicitud_id BIGINT)
RETURNS BIGINT LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $func$
DECLARE
  v_sol      solicitudes%ROWTYPE;
  v_opp      BIGINT;
  v_contacto BIGINT;
  v_clave    TEXT;
  v_etapa    TEXT;
  v_mayor    BOOLEAN;
BEGIN
  SELECT id INTO v_opp FROM crm_oportunidades WHERE solicitud_id = p_solicitud_id;
  IF FOUND THEN
    RETURN v_opp;
  END IF;

  SELECT * INTO v_sol FROM solicitudes WHERE id = p_solicitud_id;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  v_mayor := v_sol.es_mayorista OR v_sol.canal = 'mayorista';
  v_clave := fn_crm_tel_clave(v_sol.telefono);
  IF v_clave IS NOT NULL THEN
    -- Si hay uno activo se usa ese; si solo hay archivado, se reactiva
    SELECT id INTO v_contacto FROM crm_contactos
     WHERE telefono_clave = v_clave
     ORDER BY archivado, id
     LIMIT 1;
  END IF;

  IF v_contacto IS NULL THEN
    INSERT INTO crm_contactos (nombre, telefono, localidad, tipo, canal_origen,
                               comercio, cuit, created_by, created_at)
    VALUES (v_sol.cliente_nombre, v_sol.telefono, v_sol.localidad,
            CASE WHEN v_mayor THEN 'mayorista' ELSE 'minorista' END,
            'web', v_sol.comercio, v_sol.cuit, NULL, v_sol.created_at)
    RETURNING id INTO v_contacto;
  ELSE
    UPDATE crm_contactos
       SET archivado = false,
           localidad = coalesce(localidad, v_sol.localidad),
           comercio  = coalesce(comercio,  v_sol.comercio),
           cuit      = coalesce(cuit,      v_sol.cuit),
           tipo      = CASE WHEN v_mayor THEN 'mayorista' ELSE tipo END
     WHERE id = v_contacto;
  END IF;

  v_etapa := fn_crm_etapa_de_solicitud(v_sol.estado);

  PERFORM set_config('mh.crm_sync', '1', true);
  INSERT INTO crm_oportunidades (contacto_id, titulo, etapa, canal, monto, solicitud_id,
                                 created_by, created_at, cerrada_at)
  VALUES (v_contacto,
          'Pedido ' || v_sol.codigo || CASE WHEN v_sol.canal = 'mayorista'
                                            THEN ' · consulta mayorista' ELSE '' END,
          v_etapa, 'web', v_sol.total_estimado, v_sol.id,
          NULL, v_sol.created_at,
          CASE WHEN v_etapa IN ('ganada','perdida') THEN v_sol.updated_at END)
  RETURNING id INTO v_opp;
  PERFORM set_config('mh.crm_sync', '', true);

  RETURN v_opp;
END;
$func$;

-- Alta de solicitud → alta en el CRM. Blindado: si falla, avisa con un
-- WARNING en el log y el pedido sigue su curso normal.
CREATE OR REPLACE FUNCTION fn_crm_solicitud_creada()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $func$
BEGIN
  BEGIN
    PERFORM fn_crm_vincular_solicitud(NEW.id);
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'CRM: no se pudo registrar la solicitud % (%). El pedido se guardó igual.',
      NEW.codigo, SQLERRM;
  END;
  RETURN NULL;
END;
$func$;

DROP TRIGGER IF EXISTS tr_solicitudes_crm_alta ON solicitudes;
CREATE TRIGGER tr_solicitudes_crm_alta
  AFTER INSERT ON solicitudes
  FOR EACH ROW EXECUTE FUNCTION fn_crm_solicitud_creada();

-- Cambio de estado o de total de una solicitud → etapa y monto en el CRM
CREATE OR REPLACE FUNCTION fn_crm_solicitud_actualizada()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $func$
DECLARE
  v_opp   BIGINT;
  v_etapa TEXT;
BEGIN
  BEGIN
    v_opp := fn_crm_vincular_solicitud(NEW.id);
    IF v_opp IS NOT NULL THEN
      v_etapa := fn_crm_etapa_de_solicitud(NEW.estado);
      PERFORM set_config('mh.crm_sync', '1', true);
      UPDATE crm_oportunidades
         SET etapa = v_etapa,
             monto = NEW.total_estimado
       WHERE id = v_opp
         AND (etapa IS DISTINCT FROM v_etapa OR monto IS DISTINCT FROM NEW.total_estimado);
      PERFORM set_config('mh.crm_sync', '', true);
    END IF;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'CRM: no se pudo sincronizar la solicitud % (%). El pedido se actualizó igual.',
      NEW.codigo, SQLERRM;
  END;
  RETURN NULL;
END;
$func$;

DROP TRIGGER IF EXISTS tr_solicitudes_crm_sync ON solicitudes;
CREATE TRIGGER tr_solicitudes_crm_sync
  AFTER UPDATE OF estado, total_estimado ON solicitudes
  FOR EACH ROW EXECUTE FUNCTION fn_crm_solicitud_actualizada();


-- ──────────────────────────────────────────────
-- 5) RPC: cargar una consulta en un solo paso
--    SECURITY INVOKER: corre con los permisos de quien la llama, así
--    la barrera sigue siendo RLS (abajo), no esta función.
-- ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION crm_nueva_consulta(p JSONB)
RETURNS JSONB LANGUAGE plpgsql SECURITY INVOKER
SET search_path = public AS $func$
DECLARE
  v_nombre   TEXT := left(btrim(regexp_replace(coalesce(p->>'nombre', ''), '\s+', ' ', 'g')), 120);
  v_tel      TEXT := nullif(left(btrim(coalesce(p->>'telefono', '')), 40), '');
  v_canal    TEXT := coalesce(nullif(p->>'canal', ''), 'whatsapp');
  v_tipo     TEXT := CASE WHEN p->>'tipo' IN ('minorista','mayorista','otro')
                          THEN p->>'tipo' ELSE 'minorista' END;
  v_titulo   TEXT := left(btrim(regexp_replace(coalesce(p->>'titulo', ''), '\s+', ' ', 'g')), 160);
  v_paso     TEXT := nullif(left(btrim(coalesce(p->>'proxima_accion', '')), 200), '');
  v_nota     TEXT := nullif(left(btrim(coalesce(p->>'nota', '')), 2000), '');
  v_monto    NUMERIC(12,2);
  v_fecha    DATE;
  v_clave    TEXT;
  v_contacto BIGINT;
  v_nuevo    BOOLEAN := false;
  v_opp      BIGINT;
BEGIN
  IF coalesce(fn_get_user_role(), '') NOT IN ('administrador','vendedor') THEN
    RAISE EXCEPTION 'sin_permiso' USING HINT = 'Tu rol no puede cargar consultas en el CRM.';
  END IF;

  IF v_canal NOT IN ('instagram','whatsapp','facebook','web','mostrador','referido','otro') THEN
    v_canal := 'otro';
  END IF;
  IF char_length(v_titulo) < 2 THEN
    RAISE EXCEPTION 'titulo_invalido'
      USING HINT = 'Contá en pocas palabras qué busca (ej.: "Freidora de aire").';
  END IF;

  BEGIN
    v_monto := nullif(btrim(coalesce(p->>'monto', '')), '')::numeric;
  EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'monto_invalido' USING HINT = 'El monto tiene que ser un número.';
  END;
  IF v_monto < 0 THEN
    RAISE EXCEPTION 'monto_invalido' USING HINT = 'El monto no puede ser negativo.';
  END IF;

  BEGIN
    v_fecha := nullif(btrim(coalesce(p->>'proxima_accion_fecha', '')), '')::date;
  EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'fecha_invalida' USING HINT = 'La fecha del próximo paso no es válida.';
  END;

  -- Contacto: el elegido, el que ya tiene ese teléfono, o uno nuevo
  IF coalesce(p->>'contacto_id', '') ~ '^\d+$' THEN
    SELECT id INTO v_contacto FROM crm_contactos WHERE id = (p->>'contacto_id')::bigint;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'contacto_no_encontrado' USING HINT = 'Ese contacto ya no existe. Recargá la página.';
    END IF;
  ELSE
    v_clave := fn_crm_tel_clave(v_tel);
    IF v_clave IS NOT NULL THEN
      SELECT id INTO v_contacto FROM crm_contactos
       WHERE telefono_clave = v_clave
       ORDER BY archivado, id
       LIMIT 1;
    END IF;

    IF v_contacto IS NULL THEN
      IF char_length(v_nombre) < 2 THEN
        RAISE EXCEPTION 'nombre_invalido' USING HINT = 'Ingresá el nombre del cliente.';
      END IF;
      INSERT INTO crm_contactos (nombre, telefono, tipo, canal_origen, instagram, localidad)
      VALUES (v_nombre, v_tel, v_tipo, v_canal,
              nullif(left(btrim(coalesce(p->>'instagram', '')), 60), ''),
              nullif(left(btrim(coalesce(p->>'localidad', '')), 80), ''))
      RETURNING id INTO v_contacto;
      v_nuevo := true;
    ELSE
      UPDATE crm_contactos SET archivado = false WHERE id = v_contacto AND archivado;
    END IF;
  END IF;

  INSERT INTO crm_oportunidades (contacto_id, titulo, etapa, canal, monto,
                                 proxima_accion, proxima_accion_fecha, responsable_id)
  VALUES (v_contacto, v_titulo, 'nueva', v_canal, v_monto, v_paso, v_fecha, auth.uid())
  RETURNING id INTO v_opp;

  IF v_nota IS NOT NULL THEN
    INSERT INTO crm_actividades (contacto_id, oportunidad_id, tipo, detalle)
    VALUES (v_contacto, v_opp, 'nota', v_nota);
  END IF;

  RETURN jsonb_build_object('contacto_id', v_contacto, 'oportunidad_id', v_opp,
                            'contacto_nuevo', v_nuevo);
END;
$func$;


-- ──────────────────────────────────────────────
-- 6) SEGURIDAD (RLS)
--    Ven y editan: administrador y vendedor.
--    El historial (crm_actividades) no se edita ni se borra; a mano solo
--    se cargan notas y contactos, los cambios de etapa los asienta la base.
--    No hay políticas de DELETE: desde el panel nada se borra.
-- ──────────────────────────────────────────────
ALTER TABLE crm_contactos     ENABLE ROW LEVEL SECURITY;
ALTER TABLE crm_oportunidades ENABLE ROW LEVEL SECURITY;
ALTER TABLE crm_actividades   ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "crm_contactos_select" ON crm_contactos;
CREATE POLICY "crm_contactos_select" ON crm_contactos FOR SELECT
  USING (fn_get_user_role() IN ('administrador','vendedor'));
DROP POLICY IF EXISTS "crm_contactos_insert" ON crm_contactos;
CREATE POLICY "crm_contactos_insert" ON crm_contactos FOR INSERT
  WITH CHECK (fn_get_user_role() IN ('administrador','vendedor'));
DROP POLICY IF EXISTS "crm_contactos_update" ON crm_contactos;
CREATE POLICY "crm_contactos_update" ON crm_contactos FOR UPDATE
  USING (fn_get_user_role() IN ('administrador','vendedor'))
  WITH CHECK (fn_get_user_role() IN ('administrador','vendedor'));

DROP POLICY IF EXISTS "crm_oportunidades_select" ON crm_oportunidades;
CREATE POLICY "crm_oportunidades_select" ON crm_oportunidades FOR SELECT
  USING (fn_get_user_role() IN ('administrador','vendedor'));
DROP POLICY IF EXISTS "crm_oportunidades_insert" ON crm_oportunidades;
CREATE POLICY "crm_oportunidades_insert" ON crm_oportunidades FOR INSERT
  WITH CHECK (fn_get_user_role() IN ('administrador','vendedor'));
DROP POLICY IF EXISTS "crm_oportunidades_update" ON crm_oportunidades;
CREATE POLICY "crm_oportunidades_update" ON crm_oportunidades FOR UPDATE
  USING (fn_get_user_role() IN ('administrador','vendedor'))
  WITH CHECK (fn_get_user_role() IN ('administrador','vendedor'));

DROP POLICY IF EXISTS "crm_actividades_select" ON crm_actividades;
CREATE POLICY "crm_actividades_select" ON crm_actividades FOR SELECT
  USING (fn_get_user_role() IN ('administrador','vendedor'));
DROP POLICY IF EXISTS "crm_actividades_insert" ON crm_actividades;
CREATE POLICY "crm_actividades_insert" ON crm_actividades FOR INSERT
  WITH CHECK (fn_get_user_role() IN ('administrador','vendedor')
              AND usuario_id = auth.uid()
              AND tipo IN ('nota','llamada','whatsapp','instagram','visita'));

-- El público (anon) no toca el CRM por ningún lado
REVOKE ALL ON crm_contactos, crm_oportunidades, crm_actividades FROM anon;
REVOKE ALL ON SEQUENCE crm_contactos_id_seq, crm_oportunidades_id_seq,
                       crm_actividades_id_seq FROM anon;

REVOKE ALL ON FUNCTION fn_crm_tel_clave(TEXT)          FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION fn_crm_etapa_nombre(TEXT)       FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION fn_crm_etapa_de_solicitud(TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION fn_crm_tel_clave(TEXT)          TO authenticated;
GRANT EXECUTE ON FUNCTION fn_crm_etapa_nombre(TEXT)       TO authenticated;
GRANT EXECUTE ON FUNCTION fn_crm_etapa_de_solicitud(TEXT) TO authenticated;

-- Internas: solo las usan los triggers
REVOKE ALL ON FUNCTION fn_crm_vincular_solicitud(BIGINT) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION fn_crm_contacto_normalizar()      FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION fn_crm_oportunidad_antes()        FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION fn_crm_oportunidad_despues()      FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION fn_crm_actividad_antes()          FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION fn_crm_actividad_despues()        FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION fn_crm_solicitud_creada()         FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION fn_crm_solicitud_actualizada()    FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION crm_nueva_consulta(JSONB) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION crm_nueva_consulta(JSONB) TO authenticated;


-- ──────────────────────────────────────────────
-- 7) CARGA INICIAL: las solicitudes que ya existían entran al CRM
--    (idempotente: las que ya tienen oportunidad se saltean)
-- ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_crm_incorporar_solicitudes()
RETURNS INT LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $func$
DECLARE
  r RECORD;
  n INT := 0;
BEGIN
  FOR r IN
    SELECT s.id FROM solicitudes s
     WHERE NOT EXISTS (SELECT 1 FROM crm_oportunidades o WHERE o.solicitud_id = s.id)
     ORDER BY s.created_at, s.id
  LOOP
    PERFORM fn_crm_vincular_solicitud(r.id);
    n := n + 1;
  END LOOP;
  RETURN n;
END;
$func$;

REVOKE ALL ON FUNCTION fn_crm_incorporar_solicitudes() FROM PUBLIC, anon, authenticated;

SELECT fn_crm_incorporar_solicitudes() AS solicitudes_incorporadas_al_crm;

NOTIFY pgrst, 'reload schema';

-- ============================================================
-- VERIFICACIÓN RÁPIDA (opcional, después de correrlo):
--   1. Panel → CRM: tiene que abrir sin el aviso de "falta ejecutar".
--   2. "+ Nueva consulta" con un teléfono de prueba → aparece en "Para hoy".
--   3. Cargarla de nuevo con el mismo teléfono escrito distinto
--      (ej. con 0 y 15) → se suma al mismo contacto, no crea otro.
--   4. Un pedido de prueba desde la tienda → aparece solo en el CRM;
--      al cambiarle el estado en Solicitudes, la etapa lo sigue.
-- ============================================================
