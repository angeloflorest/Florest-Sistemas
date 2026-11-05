import * as SecureStore from 'expo-secure-store';

// Supabase sessions exceed SecureStore's per-value limit. Commit a small manifest
// only after every chunk is saved; an interrupted write never restores half a token.
const options = { keychainAccessible: SecureStore.WHEN_UNLOCKED_THIS_DEVICE_ONLY };
type Manifest = { generation: string; count: number };
async function manifest(key: string): Promise<Manifest | null> {
  const raw = await SecureStore.getItemAsync(key, options);
  if (!raw) return null;
  const m = JSON.parse(raw);
  if (typeof m.generation !== 'string' || !/^[a-z0-9-]+$/.test(m.generation) || !Number.isInteger(m.count) || m.count < 1 || m.count > 200) throw Error('Sessão armazenada inválida.');
  return m;
}
async function cleanup(key: string, m: Manifest | null) {
  if (m) await Promise.all(Array.from({ length: m.count }, (_, i) => SecureStore.deleteItemAsync(`${key}.${m.generation}.${i}`, options)));
}
let pending: Promise<unknown> = Promise.resolve();
function serial<T>(fn: () => Promise<T>): Promise<T> {
  const next = pending.then(fn, fn);
  pending = next.catch(() => {});
  return next;
}
export const secureStorage = {
  getItem: (key: string) => serial(async () => {
    const m = await manifest(key);
    if (!m) return null;
    const values = await Promise.all(Array.from({ length: m.count }, (_, i) => SecureStore.getItemAsync(`${key}.${m.generation}.${i}`, options)));
    if (values.some(v => v === null)) throw Error('Sessão incompleta. Entre novamente.');
    return values.join('');
  }),
  setItem: (key: string, value: string) => serial(async () => {
    const old = await manifest(key);
    const characters = Array.from(value);
    const next = { generation: Date.now().toString(36) + '-' + Math.random().toString(36).slice(2), count: Math.max(1, Math.ceil(characters.length / 400)) };
    if (next.count > 200) throw Error('Sessão excede o limite de armazenamento seguro.');
    try {
      for (let i = 0; i < next.count; i++) await SecureStore.setItemAsync(`${key}.${next.generation}.${i}`, characters.slice(i * 400, (i + 1) * 400).join(''), options);
      await SecureStore.setItemAsync(key, JSON.stringify(next), options);
    } catch (error) { await cleanup(key, next).catch(() => {}); throw error; }
    await cleanup(key, old).catch(() => {});
  }),
  removeItem: (key: string) => serial(async () => {
    const old = await manifest(key).catch(() => null);
    await SecureStore.deleteItemAsync(key, options);
    await cleanup(key, old);
  }),
};
