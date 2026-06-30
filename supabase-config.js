// ============================================================
// Mundo Hogar — Configuración de Supabase
// ============================================================
//
// SOBRE SEGURIDAD:
//   SUPABASE_PUBLISHABLE_KEY es una clave PÚBLICA (publishable):
//   está diseñada para ir en el navegador. Los datos se protegen con
//   Row Level Security (RLS) en la base de datos, no por ocultar esta clave.
//   NUNCA pongas acá la clave secreta (sb_secret_...) ni la password de la base.
//
//   Para encontrar estos valores: supabase.com → tu proyecto →
//   Project Settings → API  (Project URL y API Keys → publishable / anon public)
// ============================================================

const SUPABASE_URL = 'https://zydotmaolgddwenwywyc.supabase.co';

// Clave PÚBLICA (publishable). Reemplaza a la antigua "anon key".
const SUPABASE_PUBLISHABLE_KEY = 'sb_publishable_8mXhNbUrp3wiWeHuZBVkVA_mFAihF_t';

// Compatibilidad: el código del panel usa SUPABASE_ANON_KEY como nombre.
const SUPABASE_ANON_KEY = SUPABASE_PUBLISHABLE_KEY;
