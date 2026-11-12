// Lógica pura de la Edge Function "usuarios" (sin Supabase ni red), para
// poder probarla con node: scripts/test-usuarios-fn.mjs

export const ROLES = ["administrador", "encargado_stock", "vendedor", "cajero"] as const;
export type Rol = typeof ROLES[number];

// Sin letras que se confunden al dictarla o leerla (0/o, 1/l/i).
const ALFABETO = "abcdefghjkmnpqrstuvwxyz23456789";

/** Contraseña temporal legible: "k7mq-x4rt-9bne" (3 grupos de 4, ~59 bits). */
export function claveTemporal(azar: (n: number) => Uint8Array = n => crypto.getRandomValues(new Uint8Array(n))): string {
  const out: string[] = [];
  // Descarta los bytes que sesgarían el reparto (256 no es múltiplo de 31).
  const tope = 256 - (256 % ALFABETO.length);
  while (out.length < 12) {
    for (const b of azar(24)) {
      if (b < tope && out.length < 12) out.push(ALFABETO[b % ALFABETO.length]);
    }
  }
  return [out.slice(0, 4), out.slice(4, 8), out.slice(8)].map(g => g.join("")).join("-");
}

export type Alta = { email: string; nombre: string; rol: Rol };

/** Valida el pedido de alta. Devuelve el alta limpia o el código de error. */
export function validarAlta(body: Record<string, unknown>): Alta | { error: string } {
  const email = String(body.email ?? "").trim().toLowerCase();
  const nombre = String(body.nombre ?? "").trim().replace(/\s+/g, " ");
  const rol = String(body.rol ?? "");
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(email) || email.length > 254) return { error: "email_invalido" };
  if (!nombre || nombre.length > 80) return { error: "nombre_invalido" };
  if (!(ROLES as readonly string[]).includes(rol)) return { error: "rol_invalido" };
  return { email, nombre, rol: rol as Rol };
}

/** ¿El error de Supabase Auth es "ese email ya tiene cuenta"? */
export function esEmailExistente(err: { message?: string; code?: string; status?: number } | null): boolean {
  if (!err) return false;
  const msg = err.message ?? "";
  return err.code === "email_exists"
    || (err.status === 422 && /already|registered|exists/i.test(msg))
    || /already been registered|already exists/i.test(msg);
}
