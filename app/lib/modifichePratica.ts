export function modificheNonSalvate(): boolean {
  if (document.querySelector('main form[data-monitoraggio-modifiche="gestito"][data-modifiche-non-salvate="true"]')) return true;
  // Solo campi editabili nelle form della pratica, mai hidden o azioni sui pulsanti.
  const campi = document.querySelectorAll<HTMLInputElement | HTMLTextAreaElement | HTMLSelectElement>(
    'main form input:not([type="hidden"]):not([type="submit"]):not([type="button"]), main form textarea, main form select'
  );
  for (const campo of campi) {
    if (campo.disabled || campo.closest('form[data-monitoraggio-modifiche="gestito"]')) continue;
    if (campo instanceof HTMLSelectElement) {
      const opzioni = Array.from(campo.options);
      const predefiniti = opzioni.filter((opzione) => opzione.defaultSelected).map((opzione) => opzione.value);
      const iniziali = predefiniti.length ? predefiniti : campo.multiple ? [] : opzioni.slice(0, 1).map((opzione) => opzione.value);
      const attuali = Array.from(campo.selectedOptions).map((opzione) => opzione.value);
      if (JSON.stringify(attuali) !== JSON.stringify(iniziali)) return true;
    } else if (campo instanceof HTMLInputElement && ["checkbox", "radio"].includes(campo.type)) {
      if (campo.checked !== campo.defaultChecked) return true;
    } else if (campo instanceof HTMLInputElement && campo.type === "file") {
      if (campo.files?.length) return true;
    } else if (campo.value !== campo.defaultValue) {
      return true;
    }
  }
  return false;
}
