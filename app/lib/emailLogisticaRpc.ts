export async function leggiRispostaEmailRpc<T = void>(response: Response): Promise<T> {
  // Le RPC void di PostgREST restituiscono 204 senza JSON, anche se
  // il salvataggio è riuscito. Non trasformarle in un errore di parsing.
  if (!response.ok) throw new Error('Operazione email logistica non riuscita.');
  if (response.status === 204) return undefined as T;
  try {
    return await response.json() as T;
  } catch {
    // Non propagare risposte DB che potrebbero contenere argomenti sensibili.
    throw new Error('Risposta email logistica non valida.');
  }
}
