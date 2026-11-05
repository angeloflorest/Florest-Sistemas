import 'react-native-url-polyfill/auto';
import React, { useCallback, useEffect, useRef, useState } from 'react';
import { ActivityIndicator, Alert, AppState, Image, KeyboardAvoidingView, Linking, Modal, Platform, SafeAreaView, ScrollView, StyleSheet, Text, TextInput, TouchableOpacity, View } from 'react-native';
import { CameraView, useCameraPermissions } from 'expo-camera';
import Constants from 'expo-constants';
import { StatusBar } from 'expo-status-bar';
import AsyncStorage from '@react-native-async-storage/async-storage';
import type { Session } from '@supabase/supabase-js';
import { client, legacyStorageKey, loadProfile, readableError, searchProducts } from './src/api';
import { itemCents, money, parseQuantity, totalCents, validUpdate, type CartItem, type Product, type Profile } from './src/domain';

const logo = require('./assets/logo-florest.png');
const version = Constants.expoConfig?.version || '0.2.0';
const BLOCKED = 'O ERP atual utiliza um Caixa PDV compartilhado. O caixa exclusivo do celular e a confirmação idempotente de vendas precisam ser disponibilizados no backend antes de operar por aqui. Nenhuma venda ou pagamento foi registrado.';
type ButtonProps = { title: string; onPress: () => void; disabled?: boolean; secondary?: boolean };
function Button({ title, onPress, disabled, secondary }: ButtonProps) {
  return <TouchableOpacity accessibilityRole="button" accessibilityState={{ disabled: !!disabled }} disabled={disabled} onPress={onPress} style={[s.button, secondary && s.secondary, disabled && s.disabled]}><Text style={[s.buttonText, secondary && { color: '#102b49' }]}>{title}</Text></TouchableOpacity>;
}
export default function App() {
  const [session, setSession] = useState<Session | null>(null);
  const [profile, setProfile] = useState<Profile | null>(null);
  const [initializing, setInitializing] = useState(true);
  const [loadingProfile, setLoadingProfile] = useState(false);
  const [error, setError] = useState('');
  const [email, setEmail] = useState(''), [password, setPassword] = useState('');
  const [showPassword, setShowPassword] = useState(false), [busy, setBusy] = useState(false);
  const [tab, setTab] = useState<'sale' | 'cash'>('sale');
  const [term, setTerm] = useState(''), [barcode, setBarcode] = useState(false);
  const [products, setProducts] = useState<Product[]>([]), [searching, setSearching] = useState(false);
  const [searchError, setSearchError] = useState(''), [searched, setSearched] = useState(false);
  const [cart, setCart] = useState<CartItem[]>([]), [camera, setCamera] = useState(false);
  const [permission, requestPermission] = useCameraPermissions();
  const [editing, setEditing] = useState<Product | null>(null), [quantity, setQuantity] = useState('1');
  const [quantityError, setQuantityError] = useState('');
  const [update, setUpdate] = useState<{ version: string; apkUrl: string } | null>(null);
  const [retry, setRetry] = useState(0);
  const authUser = useRef<string | null>(null), authGeneration = useRef(0), searchGeneration = useRef(0);
  const scanLock = useRef(false), loginLock = useRef(false);
  const companyRef = useRef<string | null>(null);

  const clearSale = useCallback(() => {
    searchGeneration.current++; setProducts([]); setCart([]); setTerm(''); setCamera(false);
    setEditing(null); setSearchError(''); setSearched(false); setBarcode(false); scanLock.current = false;
  }, []);
  useEffect(() => {
    if (!client) { setInitializing(false); return; }
    let active = true;
    const applySession = (next: Session | null) => {
      if (!active) return;
      if (authUser.current !== (next?.user.id || null)) {
        authGeneration.current++; authUser.current = next?.user.id || null;
        companyRef.current = null;
        setProfile(null); setError(''); clearSale();
      }
      setSession(next); setInitializing(false);
    };
    let eventReceived = false;
    const { data } = client.auth.onAuthStateChange((_event, next) => { eventReceived = true; applySession(next); });
    (async () => {
      // Remove legacy plaintext storage; never migrate unencrypted tokens into a session.
      if (legacyStorageKey) await AsyncStorage.removeItem(legacyStorageKey);
      const { data, error } = await client.auth.getSession();
      if (error) throw error;
      if (!eventReceived) applySession(data.session);
    })().catch(e => { if (active) { setError(readableError(e)); setInitializing(false); } });
    const appState = AppState.addEventListener('change', state => {
      if (state === 'active') { client!.auth.startAutoRefresh(); setProfile(null); searchGeneration.current++; setProducts([]); setCamera(false); setEditing(null); setRetry(n => n + 1); }
      else { client!.auth.stopAutoRefresh(); setCamera(false); }
    });
    if (AppState.currentState === 'active') client.auth.startAutoRefresh();
    return () => { active = false; data.subscription.unsubscribe(); appState.remove(); client!.auth.stopAutoRefresh(); };
  }, [clearSale]);

  useEffect(() => {
    if (!client || !session?.user.id) return;
    let active = true;
    const generation = authGeneration.current;
    setLoadingProfile(true); setError(''); setProfile(null);
    loadProfile(client, session.user.id).then(p => {
      if (active && generation === authGeneration.current) {
        if (companyRef.current && companyRef.current !== p.empresa_id) clearSale();
        companyRef.current = p.empresa_id;
        setProfile(p);
      }
    }).catch(e => { if (active && generation === authGeneration.current) { clearSale(); setError(readableError(e)); } })
      .finally(() => { if (active) setLoadingProfile(false); });
    return () => { active = false; };
  }, [session?.user.id, retry, clearSale]);

  useEffect(() => {
    const manifest = process.env.EXPO_PUBLIC_UPDATE_MANIFEST_URL;
    if (!manifest || !/^https:\/\//.test(manifest)) return;
    const controller = new AbortController(), timer = setTimeout(() => controller.abort(), 10000);
    fetch(manifest, { signal: controller.signal }).then(r => r.ok ? r.json() : null)
      .then(m => { if (!controller.signal.aborted) setUpdate(validUpdate(m, version, manifest)); }).catch(() => {}).finally(() => clearTimeout(timer));
    return () => { clearTimeout(timer); controller.abort(); };
  }, []);

  useEffect(() => {
    const generation = ++searchGeneration.current;
    setProducts([]); setSearchError(''); setSearched(false); setSearching(false);
    if (!client || !session || !profile || !term.trim()) return;
    setSearching(true);
    const timer = setTimeout(() => {
      searchProducts(client!, term, barcode).then(data => {
        if (generation === searchGeneration.current) { setProducts(data); setSearched(true); }
      }).catch(e => { if (generation === searchGeneration.current) setSearchError(readableError(e)); })
        .finally(() => { if (generation === searchGeneration.current) setSearching(false); });
    }, 250);
    return () => { clearTimeout(timer); searchGeneration.current++; };
  }, [term, barcode, profile, session?.user.id, retry]);

  const login = async () => {
    if (!client || loginLock.current) return;
    if (!email.trim() || !password) { setError('Informe seu e-mail e sua senha do ERP.'); return; }
    loginLock.current = true; setBusy(true); setError('');
    try {
      const { error } = await client.auth.signInWithPassword({ email: email.trim(), password });
      if (error) throw error;
      setPassword('');
    } catch (e) { setError(readableError(e)); }
    finally { loginLock.current = false; setBusy(false); }
  };
  const logout = async () => {
    if (!client || loginLock.current) return;
    loginLock.current = true; setBusy(true);
    try {
      const { error } = await client.auth.signOut({ scope: 'local' });
      if (error) throw error;
      authGeneration.current++; setSession(null); setProfile(null); clearSale(); setPassword('');
    } catch (e) { Alert.alert('Não foi possível sair', readableError(e)); }
    finally { loginLock.current = false; setBusy(false); }
  };
  const choose = (p: Product) => {
    setCamera(false); setQuantityError(''); setEditing(p);
    setQuantity(String(cart.find(x => x.product.id === p.id)?.quantity || 1).replace('.', ','));
  };
  const saveQuantity = () => {
    if (!editing || !profile) return;
    try {
      const qty = parseQuantity(quantity);
      if (!Number.isFinite(qty * editing.preco_venda * 100) || qty * editing.preco_venda > 99999999) throw Error('Valor do item excede o limite.');
      setCart(prev => [...prev.filter(x => x.product.id !== editing.id), { product: editing, quantity: qty }]);
      setEditing(null); searchGeneration.current++; setTerm(''); setProducts([]); setSearched(false);
    } catch (e) { setQuantityError(readableError(e)); }
  };
  const openCamera = async () => {
    try {
      if (!permission?.granted && !(await requestPermission()).granted) { Alert.alert('Câmera', 'Autorize a câmera nas configurações do Android ou digite o código na busca.'); return; }
      scanLock.current = false; setCamera(true);
    } catch (e) { Alert.alert('Câmera', readableError(e)); }
  };
  const scan = ({ data }: { data: string }) => {
    if (scanLock.current) return;
    scanLock.current = true; setCamera(false); setBarcode(true); setTerm(data.trim()); setRetry(n => n + 1);
  };
  const brand = <View style={s.brand}><Image source={logo} style={s.logo} resizeMode="contain" accessibilityLabel="Florest ERP PDV"/><Text style={s.eyebrow}>PDV MÓVEL · {version}</Text></View>;
  const notice = error ? <Text accessibilityRole="alert" style={s.error}>{error}</Text> : null;
  let content;
  if (!client) content = <View style={s.card}>{brand}<Text style={s.title}>Configuração necessária</Text><Text style={s.body}>Este instalador não contém uma conexão pública válida com o ERP. Solicite ao responsável um APK configurado.</Text></View>;
  else if (initializing) content = <View style={s.card}>{brand}<ActivityIndicator color="#102b49"/><Text style={s.body}>Verificando sessão segura…</Text>{notice}</View>;
  else if (!session) content = <KeyboardAvoidingView behavior={Platform.OS === 'ios' ? 'padding' : undefined} style={{ flex: 1 }}><ScrollView keyboardShouldPersistTaps="handled" contentContainerStyle={s.loginWrap}>{brand}<View style={s.card}><Text style={s.eyebrow}>BEM-VINDO À FLOREST</Text><Text style={s.title}>Seu balcão, na palma da mão.</Text><Text style={s.body}>Entre com o e-mail e a senha da sua conta no ERP. Sua empresa será identificada automaticamente.</Text><Text style={s.label}>E-mail</Text><TextInput accessibilityLabel="E-mail" style={s.input} placeholder="voce@empresa.com.br" autoCapitalize="none" autoCorrect={false} keyboardType="email-address" autoComplete="email" value={email} onChangeText={setEmail}/><Text style={s.label}>Senha</Text><TextInput accessibilityLabel="Senha" style={s.input} placeholder="Sua senha" secureTextEntry={!showPassword} autoComplete="current-password" value={password} onChangeText={setPassword} onSubmitEditing={login}/><TouchableOpacity accessibilityRole="button" onPress={() => setShowPassword(v => !v)}><Text style={s.link}>{showPassword ? 'Ocultar senha' : 'Mostrar senha'}</Text></TouchableOpacity>{notice}<Button title={busy ? 'Entrando…' : 'Entrar na minha conta'} onPress={login} disabled={busy}/><Text style={s.caption}>Conexão com internet obrigatória • Sessão protegida no dispositivo</Text></View></ScrollView></KeyboardAvoidingView>;
  else if (!profile) content = <View style={s.card}>{brand}<Text style={s.title}>Conectando à sua empresa</Text>{loadingProfile ? <ActivityIndicator/> : notice}<Button title="Tentar novamente" onPress={() => setRetry(n => n + 1)} disabled={loadingProfile}/><Button secondary title="Sair da conta" onPress={logout} disabled={busy}/></View>;
  else content = <><View style={s.header}><Image source={logo} style={s.headerLogo} resizeMode="contain" accessibilityLabel="Florest ERP PDV"/><TouchableOpacity accessibilityRole="button" disabled={busy} onPress={() => Alert.alert('Sair da conta?', 'A lista de itens será descartada.', [{ text: 'Continuar', style: 'cancel' }, { text: 'Sair', onPress: logout }])}><Text style={s.link}>Sair</Text></TouchableOpacity></View><View style={s.company}><Text style={s.companyName}>{profile.empresas.nome}</Text><Text style={s.companyMeta}>{profile.nome} · PDV Móvel {version}</Text></View><View style={s.tabs}>{(['sale', 'cash'] as const).map(t => <TouchableOpacity key={t} accessibilityRole="tab" accessibilityState={{ selected: tab === t }} onPress={() => { setTab(t); setCamera(false); }} style={[s.tab, tab === t && s.tabActive]}><Text style={[s.tabText, tab === t && { color: '#102b49' }]}>{t === 'sale' ? 'Produtos e itens' : 'Caixa móvel'}</Text></TouchableOpacity>)}</View><ScrollView keyboardShouldPersistTaps="handled" contentContainerStyle={s.scroll}>
    {update && <Button secondary title={`Nova versão ${update.version} · Baixar APK`} onPress={() => Linking.openURL(update.apkUrl).catch(() => Alert.alert('Atualização', 'Não foi possível abrir o endereço do APK.'))}/>}
    {tab === 'cash' ? <View style={s.card}><Text style={s.eyebrow}>OPERAÇÃO DE CAIXA</Text><Text style={s.title}>Caixa móvel indisponível</Text><Text style={s.body}>{BLOCKED}</Text><Text style={s.label}>Abertura e fechamento</Text><Text style={s.body}>Não é seguro abrir ou fechar o caixa compartilhado do computador a partir deste aplicativo.</Text><Text style={s.label}>Pagamentos e estoque</Text><Text style={s.body}>Dinheiro, Pix e cartões serão registrados pelo fluxo autorizado do ERP quando a integração estiver disponível. A baixa de estoque depende da venda confirmada no servidor.</Text><Button title="Abrir caixa" disabled onPress={() => {}}/><Button title="Fechar caixa e consultar totais" disabled onPress={() => {}}/></View> : <>
    <View style={s.card}><Text style={s.eyebrow}>CATÁLOGO DA SUA EMPRESA</Text><Text style={s.sectionTitle}>Encontre um produto</Text><TextInput accessibilityLabel="Buscar produto" style={s.input} placeholder="Nome, código ou código de barras" value={term} onChangeText={v => { setBarcode(false); setTerm(v); }} onSubmitEditing={() => { setBarcode(true); setRetry(n => n + 1); }} returnKeyType="search"/><View style={s.row}><Button secondary title="Ler com câmera" onPress={openCamera}/><Button secondary title="Buscar código exato" disabled={!term.trim()} onPress={() => { setBarcode(true); setRetry(n => n + 1); }}/></View>{searching && <ActivityIndicator color="#102b49"/>}{searchError ? <><Text accessibilityRole="alert" style={s.error}>{searchError}</Text><Button secondary title="Repetir busca" onPress={() => setRetry(n => n + 1)}/></> : null}{searched && !products.length && <Text style={s.body}>Nenhum produto encontrado. Confira o nome ou o código cadastrado no ERP.</Text>}{products.map(p => <TouchableOpacity accessibilityRole="button" key={p.id} onPress={() => choose(p)} style={s.product}><View style={{ flex: 1 }}><Text style={s.productName}>{p.nome}</Text><Text style={s.caption}>{p.codigo || p.gtin || 'Sem código'}{p.unidade_comercial ? ` · ${p.unidade_comercial}` : ''}</Text></View><Text style={s.price}>{money(p.preco_venda)} ＋</Text></TouchableOpacity>)}{products.length >= 40 && <Text style={s.caption}>Mostrando até 40 produtos. Refine sua busca.</Text>}</View>
    <View style={s.card}><View style={s.between}><Text style={s.sectionTitle}>Itens selecionados</Text><Text style={s.badge}>{cart.length} itens</Text></View>{!cart.length && <Text style={s.body}>Busque ou escaneie um produto para montar a lista.</Text>}{cart.map(item => <View style={s.product} key={item.product.id}><TouchableOpacity accessibilityRole="button" style={{ flex: 1 }} onPress={() => choose(item.product)}><Text style={s.productName}>{item.product.nome}</Text><Text style={s.caption}>{String(item.quantity).replace('.', ',')} × {money(item.product.preco_venda)} · Editar</Text><Text style={s.price}>{money(itemCents(item) / 100)}</Text></TouchableOpacity><TouchableOpacity accessibilityRole="button" accessibilityLabel={`Remover ${item.product.nome}`} onPress={() => setCart(prev => prev.filter(x => x.product.id !== item.product.id))}><Text style={s.remove}>Remover</Text></TouchableOpacity></View>)}</View>
    <View style={s.totalCard}><Text style={s.totalLabel}>TOTAL DOS ITENS</Text><Text style={s.total}>{money(totalCents(cart) / 100)}</Text><Text style={s.totalNote}>Valores do cadastro do ERP. Nenhuma venda foi registrada.</Text><Button title="Finalização indisponível" disabled onPress={() => {}}/><TouchableOpacity accessibilityRole="button" onPress={() => Alert.alert('Integração do caixa móvel', BLOCKED)}><Text style={s.totalNote}>Ver situação da integração</Text></TouchableOpacity></View>
    </>}
  </ScrollView></>;
  return <SafeAreaView style={s.root}><StatusBar style="dark"/>{content}<Modal visible={camera} onRequestClose={() => setCamera(false)} animationType="slide"><SafeAreaView style={s.root}><Text style={[s.title, { padding: 20 }]}>Ler código de barras</Text><Text style={[s.body, { paddingHorizontal: 20 }]}>Aponte a câmera para o código do produto.</Text>{camera && <CameraView style={{ flex: 1 }} facing="back" barcodeScannerSettings={{ barcodeTypes: ['ean13', 'ean8', 'upc_a', 'upc_e', 'code128', 'code39', 'itf14'] }} onBarcodeScanned={scan}/>}<Button title="Fechar câmera" onPress={() => setCamera(false)}/></SafeAreaView></Modal><Modal transparent visible={!!editing} animationType="fade" onRequestClose={() => setEditing(null)}><KeyboardAvoidingView style={s.overlay} behavior={Platform.OS === 'ios' ? 'padding' : undefined}><View style={s.modalCard}><Text style={s.eyebrow}>QUANTIDADE</Text><Text style={s.sectionTitle}>{editing?.nome}</Text><Text style={s.body}>{editing && money(editing.preco_venda)} por {editing?.unidade_comercial || 'unidade'}</Text><TextInput accessibilityLabel="Quantidade" autoFocus style={s.input} keyboardType="decimal-pad" value={quantity} onChangeText={setQuantity} maxLength={12}/>{!!quantityError && <Text accessibilityRole="alert" style={s.error}>{quantityError}</Text>}<Button title="Confirmar quantidade" onPress={saveQuantity}/><Button secondary title="Cancelar" onPress={() => setEditing(null)}/></View></KeyboardAvoidingView></Modal></SafeAreaView>;
}
const s = StyleSheet.create({
  root: { flex: 1, backgroundColor: '#f1f3f6', paddingTop: Platform.OS === 'android' ? Constants.statusBarHeight : 0 },
  loginWrap: { flexGrow: 1, justifyContent: 'center', padding: 20 }, brand: { alignItems: 'center', paddingVertical: 24 }, logo: { width: '100%', maxWidth: 330, height: 130 },
  eyebrow: { fontSize: 11, letterSpacing: 1.7, fontWeight: '800', color: '#786011', marginVertical: 10 },
  card: { padding: 18, backgroundColor: '#fff', borderRadius: 20, marginBottom: 14, borderWidth: 1, borderColor: '#e2e7ee' },
  title: { fontSize: 27, lineHeight: 33, fontWeight: '800', color: '#102b49', marginBottom: 10 },
  body: { color: '#536277', fontSize: 14, lineHeight: 22, marginVertical: 8 }, label: { fontSize: 13, fontWeight: '700', color: '#102b49', marginTop: 14 },
  input: { borderWidth: 1, borderColor: '#cbd4df', backgroundColor: '#f8fafc', borderRadius: 12, padding: 14, marginVertical: 8, fontSize: 16, color: '#102b49' },
  button: { backgroundColor: '#f8c928', paddingVertical: 15, paddingHorizontal: 13, borderRadius: 12, marginVertical: 7, alignItems: 'center' },
  secondary: { backgroundColor: '#edf1f5' }, disabled: { backgroundColor: '#d9dfe7', opacity: 0.7 }, buttonText: { color: '#102b49', fontWeight: '800', fontSize: 14 },
  link: { color: '#174f83', fontWeight: '700', paddingVertical: 10 }, caption: { fontSize: 12, lineHeight: 18, color: '#617086' },
  error: { backgroundColor: '#fff0ef', color: '#9c2525', padding: 12, borderRadius: 10, lineHeight: 21, marginVertical: 8 },
  header: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', backgroundColor: '#fff', paddingHorizontal: 18 }, headerLogo: { width: 160, height: 66 },
  company: { backgroundColor: '#102b49', padding: 18 }, companyName: { color: '#fff', fontWeight: '800', fontSize: 19 }, companyMeta: { color: '#ced8e6', fontSize: 12, marginTop: 5 },
  tabs: { flexDirection: 'row', backgroundColor: '#102b49', padding: 8, gap: 8 }, tab: { flex: 1, padding: 12, alignItems: 'center', borderRadius: 10 }, tabActive: { backgroundColor: '#f8c928' }, tabText: { color: '#fff', fontWeight: '700' },
  scroll: { padding: 14, paddingBottom: 28 }, sectionTitle: { fontSize: 19, color: '#102b49', fontWeight: '800' }, row: { flexDirection: 'row', flexWrap: 'wrap', gap: 8 }, between: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between' },
  badge: { backgroundColor: '#eef3f7', color: '#102b49', borderRadius: 10, padding: 7, fontSize: 12 }, product: { flexDirection: 'row', alignItems: 'center', gap: 12, paddingVertical: 15, borderBottomWidth: 1, borderColor: '#edf0f4' }, productName: { color: '#102b49', fontWeight: '700', fontSize: 15, marginBottom: 4 }, price: { color: '#174f68', fontWeight: '800', fontSize: 15 }, remove: { color: '#a13030', fontWeight: '700', padding: 10, fontSize: 12 },
  totalCard: { backgroundColor: '#102b49', borderRadius: 20, padding: 22 }, totalLabel: { color: '#d0dcec', fontSize: 11, letterSpacing: 1.4 }, total: { color: '#f8c928', fontSize: 36, fontWeight: '800', marginVertical: 8 }, totalNote: { color: '#d0dcec', fontSize: 12, lineHeight: 19, marginVertical: 6 },
  overlay: { flex: 1, justifyContent: 'center', backgroundColor: '#071c39aa', padding: 24 }, modalCard: { borderRadius: 20, backgroundColor: 'white', padding: 22 },
});
