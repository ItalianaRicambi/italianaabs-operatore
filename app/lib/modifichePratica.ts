type Campo = HTMLInputElement | HTMLTextAreaElement | HTMLSelectElement;
const SELETTORE = 'main form input:not([type="hidden"]):not([type="submit"]):not([type="button"]), main form textarea, main form select';
type Controllo = { documento: Document; iniziali: WeakMap<Campo, string>; modificati: Set<Campo> };
let controllo: Controllo | null = null;

function gestito(campo: Campo): boolean {
  return !!campo.closest('form[data-monitoraggio-modifiche="gestito"]');
}

function daControllare(campo: Campo): boolean {
  return !gestito(campo) && campo.closest('form')?.getAttribute('method')?.toLowerCase() !== 'get';
}

function valore(campo: Campo): string {
  if (campo.tagName === 'SELECT') {
    return JSON.stringify(Array.from((campo as HTMLSelectElement).selectedOptions).map(opzione => opzione.value));
  }
  if (campo.tagName === 'INPUT') {
    const input = campo as HTMLInputElement;
    if (['checkbox', 'radio'].includes(input.type)) return String(input.checked);
    if (input.type === 'file') return JSON.stringify(Array.from(input.files || []).map(file => [file.name, file.size, file.lastModified]));
  }
  return campo.value;
}

// I default HTML non rappresentano sempre il valore iniziale di un campo React:
// durante la navigazione SPA un select controllato può avere defaultSelected=false
// su tutte le opzioni. Registriamo i valori effettivi e le sole modifiche ai campi.
export function avviaControlloModifiche(documento: Document = document): () => void {
  const stato: Controllo = { documento, iniziali: new WeakMap(), modificati: new Set() };
  controllo = stato;
  const registraCampi = () => {
    for (const campo of documento.querySelectorAll<Campo>(SELETTORE)) {
      if (daControllare(campo) && !stato.iniziali.has(campo)) stato.iniziali.set(campo, valore(campo));
    }
  };
  registraCampi();
  const trovaCampo = (event: Event): Campo | null => {
    const campo = event.target as Campo | null;
    return campo?.matches?.(SELETTORE) && !campo.disabled && daControllare(campo) ? campo : null;
  };
  const prepara = (event: Event) => {
    const campo = trovaCampo(event);
    // Aggiornamenti automatici/prefill non sono modifiche dell'operatore.
    if (campo && !stato.modificati.has(campo)) stato.iniziali.set(campo, valore(campo));
  };
  const registraModifica = (event: Event) => {
    const campo = trovaCampo(event);
    if (!campo) return;
    if (stato.iniziali.get(campo) !== valore(campo)) stato.modificati.add(campo);
    else stato.modificati.delete(campo);
  };
  documento.addEventListener('focusin', prepara, true);
  documento.addEventListener('beforeinput', prepara, true);
  documento.addEventListener('input', registraModifica, true);
  documento.addEventListener('change', registraModifica, true);
  const Osservatore = documento.defaultView?.MutationObserver;
  const osservatore = Osservatore ? new Osservatore(registraCampi) : null;
  osservatore?.observe(documento.querySelector('main') || documento, { childList: true, subtree: true });
  return () => {
    documento.removeEventListener('focusin', prepara, true);
    documento.removeEventListener('beforeinput', prepara, true);
    documento.removeEventListener('input', registraModifica, true);
    documento.removeEventListener('change', registraModifica, true);
    osservatore?.disconnect();
    if (controllo === stato) controllo = null;
  };
}

export function modificheNonSalvate(): boolean {
  const documento = controllo?.documento || document;
  if (documento.querySelector('main form[data-monitoraggio-modifiche="gestito"][data-modifiche-non-salvate="true"]')) return true;
  if (!controllo) return false;
  for (const campo of controllo.modificati) {
    if (campo.isConnected && !campo.disabled && daControllare(campo) && controllo.iniziali.get(campo) !== valore(campo)) return true;
  }
  return false;
}
