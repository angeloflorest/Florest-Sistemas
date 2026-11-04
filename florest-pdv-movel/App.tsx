import 'react-native-url-polyfill/auto';
import React, { useEffect, useRef, useState } from 'react';
import { Alert, Linking, SafeAreaView, ScrollView, StyleSheet, Text, TextInput, TouchableOpacity, View } from 'react-native';
import { CameraView, useCameraPermissions } from 'expo-camera';
import { createClient, type Session } from '@supabase/supabase-js';
import AsyncStorage from '@react-native-async-storage/async-storage';

const url = process.env.EXPO_PUBLIC_SUPABASE_URL || '';
const key = process.env.EXPO_PUBLIC_SUPABASE_ANON_KEY || '';
const client = url && key ? createClient(url, key, { auth: { storage: AsyncStorage, autoRefreshToken: true, persistSession: true, detectSessionInUrl: false } }) : null;
type Product = { id: string; nome: string; codigo: string | null; gtin: string | null; preco_venda: number; empresa_id: string };
type CartItem = { product: Product; quantity: number };
const money = (v: number) => 'R$ ' + v.toFixed(2).replace('.', ',');
export default function App() {
  const [session, setSession] = useState<Session | null>(null);
  const [email, setEmail] = useState(''); const [password, setPassword] = useState('');
  const [busy, setBusy] = useState(false); const [company, setCompany] = useState('');
  const [term, setTerm] = useState(''); const [products, setProducts] = useState<Product[]>([]);
  const [cart, setCart] = useState<CartItem[]>([]); const [camera, setCamera] = useState(false);
  const [permission, requestPermission] = useCameraPermissions();
  const [update, setUpdate] = useState<{ version: string; apkUrl: string } | null>(null);
  const scanLock = useRef(false);
  useEffect(() => {
    if (!client) return;
    client.auth.getSession().then(({ data }) => setSession(data.session));
    const { data } = client.auth.onAuthStateChange((_event, next) => setSession(next));
    return () => data.subscription.unsubscribe();
  }, []);
  useEffect(() => {
    const manifest = process.env.EXPO_PUBLIC_UPDATE_MANIFEST_URL;
    if (!manifest || !/^https:\/\//.test(manifest)) return;
    fetch(manifest).then(r => r.ok ? r.json() : null).then(m => {
      if (m && typeof m.version === 'string' && typeof m.apkUrl === 'string' && /^https:\/\//.test(m.apkUrl) && m.version !== '0.1.0') setUpdate(m);
    }).catch(() => {});
  }, []);
  useEffect(() => {
    if (!client || !session || !company || !term.trim()) { setProducts([]); return; }
    let active = true;
    const timer = setTimeout(async () => {
      const t = term.trim().replace(/[%_,()]/g, '');
      if (!t) return;
      const { data, error } = await client!.from('produtos').select('id,nome,codigo,gtin,preco_venda,empresa_id').eq('empresa_id', company).eq('ativo', true).or('nome.ilike.%' + t + '%,codigo.ilike.%' + t + '%,gtin.eq.' + t).order('nome').limit(40);
      if (active) { if (error) Alert.alert('Busca', error.message); else setProducts((data || []) as Product[]); }
    }, 220);
    return () => { active = false; clearTimeout(timer); };
  }, [term, company, session]);
  const login = async () => {
    if (!client) return Alert.alert('Configuração pendente', 'Configure a URL e a chave pública do Supabase.');
    setBusy(true);
    const { error } = await client.auth.signInWithPassword({ email: email.trim(), password });
    setBusy(false); if (error) Alert.alert('Login', error.message);
  };
  const add = (p: Product) => {
    setCart(prev => { const found = prev.find(x => x.product.id === p.id); return found ? prev.map(x => x.product.id === p.id ? { ...x, quantity: x.quantity + 1 } : x) : [...prev, { product: p, quantity: 1 }]; });
    setTerm(''); setProducts([]); setCamera(false); scanLock.current = false;
  };
  const onScan = ({ data }: { data: string }) => {
    if (scanLock.current) return;
    scanLock.current = true; setCamera(false); setTerm(data);
    setTimeout(() => { scanLock.current = false; }, 800);
  };
  const total = cart.reduce((sum, x) => sum + x.quantity * Number(x.product.preco_venda || 0), 0);
  const button = (label: string, fn: () => void, disabled = false) => <TouchableOpacity disabled={disabled} onPress={fn} style={[styles.button, disabled && styles.disabled]}><Text style={styles.buttonText}>{label}</Text></TouchableOpacity>;
  if (!client) return <SafeAreaView style={styles.root}><Text style={styles.heading}>Florest PDV Móvel</Text><Text>Configure as variáveis EXPO_PUBLIC_SUPABASE_URL e EXPO_PUBLIC_SUPABASE_ANON_KEY antes de iniciar.</Text></SafeAreaView>;
  if (!session) return <SafeAreaView style={styles.root}><Text style={styles.heading}>Florest PDV Móvel</Text><Text>Entrar com usuário do Florest ERP</Text><TextInput style={styles.input} placeholder="E-mail" autoCapitalize="none" keyboardType="email-address" value={email} onChangeText={setEmail}/><TextInput style={styles.input} placeholder="Senha" secureTextEntry value={password} onChangeText={setPassword}/>{button(busy ? 'Entrando...' : 'Entrar', login, busy)}</SafeAreaView>;
  return <SafeAreaView style={styles.root}><ScrollView keyboardShouldPersistTaps="handled">
    <Text style={styles.heading}>Florest PDV Móvel</Text>
    <Text style={styles.muted}>Base inicial — sem finalização de vendas</Text>
    {update && button('Atualização disponível: ' + update.version, () => Linking.openURL(update.apkUrl))}
    <Text style={styles.label}>Empresa (ID da empresa autorizado no ERP)</Text>
    <TextInput style={styles.input} placeholder="Identificador da empresa" value={company} onChangeText={v => { setCompany(v.trim()); setCart([]); }} autoCapitalize="none"/>
    <Text style={styles.muted}>A seleção automática e a validação do vínculo do usuário à empresa ainda serão integradas. O filtro atual depende das políticas RLS do Supabase.</Text>
    <Text style={styles.label}>Buscar produto</Text>
    <TextInput style={styles.input} placeholder="Nome, código ou leitor Bluetooth" value={term} onChangeText={setTerm}/>
    {button(camera ? 'Fechar câmera' : 'Ler código com a câmera', async () => { if (!permission?.granted) { const result = await requestPermission(); if (!result.granted) return Alert.alert('Câmera', 'Permissão necessária.'); } setCamera(v => !v); })}
    {camera && <CameraView style={{ height: 260, marginVertical: 12 }} facing="back" barcodeScannerSettings={{ barcodeTypes: ['ean13', 'ean8', 'upc_a', 'code128', 'code39', 'itf14'] }} onBarcodeScanned={onScan}/>}
    {products.map(p => <TouchableOpacity key={p.id} onPress={() => add(p)} style={styles.item}><Text>{p.nome}</Text><Text>{money(Number(p.preco_venda))}  +</Text></TouchableOpacity>)}
    <Text style={styles.label}>Carrinho</Text>
    {cart.map(x => <View key={x.product.id} style={styles.item}><View style={{ flex: 1 }}><Text>{x.product.nome}</Text><Text>{x.quantity} × {money(Number(x.product.preco_venda))} = {money(x.quantity * Number(x.product.preco_venda))}</Text></View><TouchableOpacity onPress={() => setCart(c => c.map(y => y.product.id === x.product.id ? { ...y, quantity: Math.max(0, y.quantity - 1) } : y).filter(y => y.quantity > 0))}><Text style={styles.remove}>−</Text></TouchableOpacity></View>)}
    <Text style={styles.total}>Total: {money(total)}</Text>
    {button('Finalizar venda — integração pendente', () => {}, true)}
    <Text style={styles.muted}>Nenhuma venda ou alteração de estoque será executada nesta versão inicial.</Text>
    {button('Sair', () => { setCart([]); setCompany(''); client.auth.signOut(); })}
  </ScrollView></SafeAreaView>;
}
const styles = StyleSheet.create({ root: { flex: 1, backgroundColor: '#f7f9fc', padding: 20 }, heading: { fontSize: 25, fontWeight: '800', color: '#123b60', marginVertical: 16 }, label: { fontSize: 17, fontWeight: '700', marginTop: 22, marginBottom: 8 }, input: { borderWidth: 1, borderColor: '#c9d4e2', backgroundColor: 'white', borderRadius: 10, padding: 13, marginVertical: 7 }, button: { backgroundColor: '#1768a3', padding: 15, borderRadius: 10, marginVertical: 8, alignItems: 'center' }, disabled: { backgroundColor: '#8b9bab' }, buttonText: { color: 'white', fontWeight: '700' }, item: { padding: 13, backgroundColor: 'white', marginVertical: 3, borderRadius: 8, flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center', gap: 12 }, total: { fontSize: 24, fontWeight: '800', marginVertical: 18 }, muted: { color: '#68788a', fontSize: 12, marginVertical: 8 }, remove: { fontSize: 30, color: '#a22', paddingHorizontal: 12 } });
