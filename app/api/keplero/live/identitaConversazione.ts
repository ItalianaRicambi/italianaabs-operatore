/** Il SessionId documentato da K è un riferimento alla chat, non un telefono.
 * Va letto soltanto dopo aver autenticato il webhook. */
export function leggiIdConversazioneKeplero(body: Record<string, unknown>, headers: Headers): string {
  for (const campo of ["conversation_id", "keplero_conversation_id", "session_id", "conversationId", "chat_id", "chatId", "thread_id", "threadId"]) {
    const value = body[campo];
    if ((typeof value === "string" || typeof value === "number") && String(value).trim()) return String(value).trim();
  }
  for (const campo of ["x-keplero-sessionid", "x-keplero-conversation-id", "x-conversation-id", "x-session-id"]) {
    const value = headers.get(campo)?.trim();
    if (value) return value;
  }
  return "";
}
