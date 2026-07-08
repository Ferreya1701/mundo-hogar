# Guía: activar la IA del Asistente MH (opcional)

## Qué hay hoy (sin costo, ya funcionando)

El panel tiene el **Asistente MH** (botón violeta ✨ abajo a la derecha). En su versión actual:

- Responde con **datos reales del negocio**: productos sin precio, sin imagen, stock crítico, solicitudes pendientes, destacados, movimientos de la semana, categorías vacías.
- Explica **cómo usar cada pantalla** (crear productos, ofertas, cambiar el WhatsApp, etc.).
- Genera **respuestas de WhatsApp** con plantillas (desde Solicitudes → Ver).
- No usa ninguna API paga: funciona con la sesión del usuario y respeta los permisos (RLS).

## Qué agrega la IA (requiere activación)

Cuando se activa la Edge Function `asistente`, las **preguntas libres** que el asistente no reconoce dejan de responder "no tengo respuesta preparada" y pasan a responderse con **Claude** (la IA de Anthropic), usando el resumen real del negocio como contexto. El panel la detecta solo: no hay que tocar código.

## Qué se necesita

1. **Una API key de Anthropic** (console.anthropic.com → API Keys). Requiere cargar crédito; con el modelo usado (Haiku), una consulta cuesta fracciones de centavo de dólar — con USD 5 se cubren miles de preguntas.
2. **10 minutos** en el panel de Supabase.

## Pasos de activación (una sola vez)

### Opción A — desde el panel de Supabase (recomendada, sin instalar nada)

1. Entrá a **supabase.com → tu proyecto → Edge Functions**.
2. Botón **"Deploy a new function"** → elegí crear desde el editor.
3. Nombre de la función: `asistente` (exactamente así).
4. Borrá el contenido de ejemplo y pegá **todo** el archivo `supabase/functions/asistente/index.ts` de este repo.
5. Deploy.
6. Andá a **Edge Functions → Secrets** (o Project Settings → Edge Functions) y agregá:
   - Nombre: `ANTHROPIC_API_KEY`
   - Valor: tu clave `sk-ant-...`
7. Listo. Abrí el panel admin, botón ✨, y hacé una pregunta libre (ej: "¿qué me conviene hacer esta semana?").

### Opción B — con la CLI de Supabase

```bash
npx supabase functions deploy asistente --project-ref zydotmaolgddwenwywyc
npx supabase secrets set ANTHROPIC_API_KEY=sk-ant-... --project-ref zydotmaolgddwenwywyc
```

## Seguridad (cómo está protegido)

- La API key vive como **secreto en Supabase**: nunca llega al navegador ni al repo.
- La función **verifica la sesión**: solo usuarios logueados del panel pueden usarla (un visitante anónimo recibe 401).
- La IA **solo recibe un resumen numérico** del negocio (cantidades), no datos de clientes.
- La IA **no puede modificar nada**: no tiene acceso de escritura a la base.
- Límite de 500 caracteres por pregunta y ~400 tokens por respuesta (control de costo).

## Cómo probar que quedó activa

1. Abrí el panel admin → botón ✨.
2. Preguntá algo libre, por ejemplo: *"dame ideas para vender más esta semana"*.
3. Si responde con una sugerencia redactada (y no con el mensaje "no tengo una respuesta preparada"), la IA está activa.

## Futuras mejoras preparadas (no implementadas a propósito)

- **Historial de conversaciones**: tablas `ai_conversations` / `ai_messages` (hoy el chat no se guarda: más privado y simple).
- **Generación de descripciones de producto con IA**: la función ya puede extenderse con una acción `generar_descripcion`.
- **Registro de uso** (`ai_actions_log`) si se quiere auditar cuánto se usa la IA.
