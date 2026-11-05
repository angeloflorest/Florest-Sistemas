import { randomUUID } from 'expo-crypto';
import { secureStorage } from './secureStorage';
const key='florest.mobile.installation';
let inflight: Promise<string> | null=null;
export function deviceIdentity(): Promise<string> {
  if (inflight) return inflight;
  inflight=(async()=>{
    const saved=await secureStorage.getItem(key);
    if (saved) {
      if (!/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(saved)) throw Error('Identificação segura do dispositivo inválida. Não abra outro caixa; contate o suporte.');
      return saved;
    }
    const id=randomUUID();
    await secureStorage.setItem(key,id);
    return id;
  })().catch(e=>{inflight=null;throw e;});
  return inflight;
}
export const newOperationKey = () => randomUUID();
