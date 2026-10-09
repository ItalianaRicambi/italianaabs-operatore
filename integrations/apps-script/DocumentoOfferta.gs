/**
 * Estensione dell'attuale notifica /api/preventivi/emesso.
 * Mantiene cartelle, registro e proprietà private del progetto esistente.
 * Nella notifica, sostituire JSON.stringify(payload) con:
 * JSON.stringify(preparaPayloadOffertaCompleta(payload))
 */
function preparaPayloadOffertaCompleta(payload) {
  if (!payload || typeof payload !== 'object') throw new Error('Payload preventivo assente');
  const completo = Object.assign({}, payload);
  const fileId = String(payload.external_id || payload.file_id || payload.drive_file_id || '');
  if (!fileId) throw new Error('Identificativo PDF assente');
  try {
    const file = DriveApp.getFileById(fileId);
    if (file.getMimeType() !== 'application/pdf') throw new Error('Il documento non è un PDF');
    if (file.getSize() > 3 * 1024 * 1024) throw new Error('PDF superiore a 3 MB: verifica operatore richiesta');
    completo.pdf_base64 = Utilities.base64Encode(file.getBlob().getBytes());
  } catch (error) {
    // L'offerta resta contabilizzata; il backend registra una lettura da verificare.
    completo.errore_lettura_pdf = error && error.message ? error.message : String(error);
  }
  return completo;
}
