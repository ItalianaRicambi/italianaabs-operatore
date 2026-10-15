import 'server-only';
import { recuperaMessaggiKeplero } from './kepleroMessages';

export function leggiMessaggiConversazioneKeplero(conversazione: string) {
 return recuperaMessaggiKeplero(conversazione, process.env.KEPLERO_API_KEY);
}
