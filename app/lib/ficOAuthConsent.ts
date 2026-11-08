/** Supabase authorization IDs are opaque URL-safe strings, not UUIDs.
 * This only validates transport syntax; Supabase validates the request after login.
 * Reject path/query delimiters because auth-js interpolates the ID into a URL path.
 */
export function authorizationIdValido(value: unknown): value is string {
  return typeof value === 'string' && value.length > 0 && value.length <= 1024
    && !/[^A-Za-z0-9_-]/.test(value);
}
