import React, { useEffect, useRef, useState } from 'react';
import { ActivityIndicator, Modal, SafeAreaView, StyleSheet, Text, TouchableOpacity, View } from 'react-native';
import { Alert } from 'react-native';
import type { MobilePOS } from './useMobilePOS';
import type { SupabaseClient } from '@supabase/supabase-js';
import { historyDetail, historyPage, readableError, searchCustomers } from './api';
import { KeyboardInput as Input, KeyboardScroll as Scroll } from './KeyboardForm';
import { money, type CartItem, type Profile } from './domain';
import { addPayment, canReadHistory, DEFAULT_CUSTOMER, draftTotal, filterSales, parseCents, PAYMENT_METHODS, validateCredit, type Customer, type HistoryFilters, type Payment, type SaleRow } from './commerce';
export function Action({ title, onPress, disabled = false }: { title: string; onPress: () => void; disabled?: boolean }) {
  return <TouchableOpacity accessibilityRole="button" accessibilityState={{ disabled }} disabled={disabled} onPress={onPress} style={[s.button, disabled && { opacity: 0.5 }]}><Text style={s.buttonText}>{title}</Text></TouchableOpacity>;
}
export function CustomerPicker({ c, profile, selected, onSelect, disabled=false }: { disabled?: boolean; c: SupabaseClient; profile: Profile; selected: Customer; onSelect: (customer: Customer) => void }) {
  const [open, setOpen] = useState(false), [term, setTerm] = useState(''), [items, setItems] = useState<Customer[]>([]), [error, setError] = useState(''), [busy, setBusy] = useState(false);
  useEffect(() => {
    let active = true; setItems([]); setError('');
    if (!open) return;
    setBusy(true);
    const timer = setTimeout(() => searchCustomers(c, profile, term).then(rows => { if (active) setItems(rows); }).catch(e => { if (active) setError(readableError(e)); }).finally(() => { if (active) setBusy(false); }), 250);
    return () => { active = false; clearTimeout(timer); };
  }, [open, term, profile.id, profile.empresa_id]);
  return <View style={s.card}><Text style={s.title}>Cliente · {selected.nome}</Text><Action title="Alterar cliente" disabled={disabled} onPress={() => { setTerm(''); setOpen(true); }}/><Modal visible={open} onRequestClose={() => setOpen(false)}><SafeAreaView style={s.screen}><Scroll contentContainerStyle={s.content}><Text style={s.title}>Selecionar cliente</Text><Text>Somente cadastros existentes na sua empresa.</Text><Input style={s.input} placeholder="Pesquisar nome" value={term} onChangeText={setTerm} accessibilityLabel="Pesquisar cliente"/><Action title="Consumidor Padrão" onPress={() => { onSelect(DEFAULT_CUSTOMER); setOpen(false); }}/>{busy && <ActivityIndicator/>}{!!error && <Text accessibilityRole="alert" style={s.error}>{error}</Text>}{items.map(row => <Action key={row.id} title={row.nome} onPress={() => { onSelect(row); setOpen(false); }}/>) }{!busy && !error && !items.length && <Text>Nenhum cliente encontrado.</Text>}{items.length === 40 && <Text>Refine o nome para encontrar outros clientes.</Text>}<Action title="Fechar" onPress={() => setOpen(false)}/></Scroll></SafeAreaView></Modal></View>;
}
export function PaymentDraft({ cart, customer, mobile }: { cart: CartItem[]; customer: Customer; mobile: MobilePOS }) {
 const [open,setOpen]=useState(false),[error,setError]=useState(''),[sending,setSending]=useState(false);
 const lock=useRef(false),total=draftTotal(cart);
 const pay=async(method:string)=>{
  if(lock.current||mobile.busy||mobile.pending)return;
  try {
   lock.current=true;setSending(true);setError('');
   const credit=method==='Nota a prazo';
   if(credit)validateCredit(customer,[],total);
   const payments:Payment[]=credit?[]:[{id:1,method,cents:total,band:''}];
   const result=await mobile.sell(cart,customer,payments,credit);
   if(result.state==='confirmed')setOpen(false);
   else setError(result.state==='rejected'?result.error:'Não foi possível confirmar a venda.');
  }catch(e){setError(readableError(e));}
  finally{lock.current=false;setSending(false);}
 };
 return <><Action title="Finalizar venda" disabled={!cart.length||total<=0||!mobile.context?.caixa||!mobile.context?.venda_habilitada||mobile.pending||mobile.busy} onPress={()=>{setError('');setOpen(true);}}/>
 <Modal visible={open} onRequestClose={()=>{if(!sending)setOpen(false);}}><SafeAreaView style={s.screen}><Scroll contentContainerStyle={s.content}>
 <Text style={s.title}>Pagamento</Text><Text style={s.title}>Total {money(total/100)}</Text>
 {['Dinheiro','Pix','Cartão de Crédito','Cartão de Débito','Nota a prazo'].map(method=><Action key={method} title={method} disabled={sending||mobile.busy||mobile.pending} onPress={()=>pay(method)}/>)}
 {sending&&<ActivityIndicator/>}{!!error&&<Text accessibilityRole="alert" style={s.error}>{error}</Text>}
 <Action title="Voltar" disabled={sending} onPress={()=>setOpen(false)}/>
 </Scroll></SafeAreaView></Modal></>;
}
const emptyFilters: HistoryFilters = { start: '', end: '', number: '', customer: '', cash: '', operator: '' };
export function SalesHistory({ c, profile }: { c: SupabaseClient; profile: Profile }) {
  const [search, setSearch] = useState(''), [filters, setFilters] = useState(emptyFilters), [rows, setRows] = useState<SaleRow[]>([]), [hasMore, setHasMore] = useState(false), [busy, setBusy] = useState(false), [error, setError] = useState('');
  const [detail, setDetail] = useState<Awaited<ReturnType<typeof historyDetail>> | null>(null);
  const generation = useRef(0), inFlight = useRef(false), loaded = useRef(false);
  const allowed = true; // Server limits non-financial operators to their own mobile sales.
  useEffect(() => { generation.current++; setRows([]); setDetail(null); setHasMore(false); loaded.current=false; return () => { generation.current++; }; }, [profile.id, profile.empresa_id, search, JSON.stringify(filters)]);
  async function load(reset: boolean) {
    if (inFlight.current || !allowed) return;
    inFlight.current = true; setBusy(true); setError(''); setDetail(null);
    const seq = ++generation.current;
    try { const page = await historyPage(c, profile, search, reset ? 0 : rows.length, filters); if (seq === generation.current) { setRows(prev => reset ? page : [...prev,...page]); setHasMore(page.length === 100); loaded.current=true; } }
    catch(e) { if (seq === generation.current) { setError(readableError(e)); if (reset) setRows([]); } }
    finally { inFlight.current=false; setBusy(false); }
  }
  async function open(row: SaleRow) {
    if (inFlight.current) return;
    const seq = ++generation.current; inFlight.current=true; setBusy(true); setError(''); setDetail(null);
    try { const result = await historyDetail(c, profile, row.id); if (seq === generation.current) setDetail(result); }
    catch(e) { if (seq === generation.current) setError(readableError(e)); }
    finally { inFlight.current=false; setBusy(false); }
  }
  let visible: SaleRow[] = [], filterError = '';
  try { filterSales([], filters); visible=rows; } catch(e) { filterError=readableError(e); }
  const cashAvailable = true;
  const operatorAvailable = canReadHistory(profile);
  if (!allowed) return <View style={s.card}><Text style={s.title}>Histórico de vendas</Text><Text>Seu perfil não possui acesso ao Financeiro, exigido nesta consulta do ERP.</Text></View>;
  return <View style={s.card}><Text style={s.title}>Vendas · somente consulta</Text><Input style={s.input} accessibilityLabel="Busca no histórico" placeholder="Número da venda (ou use os filtros abaixo)" value={search} onChangeText={setSearch}/><Action title="Consultar vendas no ERP" disabled={busy} onPress={() => load(true)}/><Text style={s.warning}>Os filtros são aplicados no servidor. Operadores sem acesso financeiro consultam somente as próprias vendas móveis; perfis financeiros também consultam o PDV Principal. Após alterar filtros, toque em Consultar.</Text>{(['start','end','number','customer','cash','operator'] as const).map(key => <Input key={key} style={s.input} value={filters[key]} accessibilityLabel={key} placeholder={{start:'Data inicial AAAA-MM-DD',end:'Data final AAAA-MM-DD',number:'Número da venda',customer:'Cliente',cash:'Número ou ID do caixa',operator:'Operador (acesso financeiro)'}[key]} editable={key === 'cash' ? cashAvailable : key === 'operator' ? operatorAvailable : true} onChangeText={value => setFilters(f => ({...f,[key]:value}))}/>)}<Action title="Limpar filtros locais" onPress={() => setFilters(emptyFilters)}/>{busy && <ActivityIndicator/>}{!!(error || filterError) && <Text accessibilityRole="alert" style={s.error}>{error || filterError}</Text>}{visible.map(row => <View key={row.id} style={s.card}><Text style={s.title}>#{row.numero_venda} · {money(row.total)}</Text><Text>{new Date(row.criado_em).toLocaleString('pt-BR')} · {row.cliente_nome || 'Consumidor'}</Text><Text>Origem: {row.origem || 'Não informada pelo ERP'}</Text><Text>Caixa: {row.caixa_numero ?? row.caixa_id ?? 'Não informado'} · Operador: {row.operador_nome || 'Não informado'}</Text>{!!row.cancelada_em && <Text>Cancelada</Text>}<Action title="Ver detalhes" onPress={() => open(row)} disabled={busy}/></View>)}{loaded.current && !busy && !visible.length && !error && !filterError && <Text>Nenhuma venda encontrada no servidor para esses filtros.</Text>}{hasMore && <Action title="Carregar mais (próximas 100)" disabled={busy} onPress={() => load(false)}/>}{detail && <View style={s.card}><Text style={s.title}>Venda #{detail.venda.numero_venda}</Text><Text>{detail.cliente_nome || 'Consumidor'} · {new Date(detail.venda.criado_em).toLocaleString('pt-BR')}</Text><Text>Origem: {detail.venda.origem || 'Não informada'} · Caixa: {detail.venda.caixa_numero ?? detail.venda.caixa_id ?? 'Não informado'}</Text><Text>Operador: {detail.venda.operador_nome || 'Não informado'}</Text>{detail.itens.map((item,i) => <View key={i} style={s.card}><Text>{item.nome} · {item.quantidade} × {money(Number(item.preco_unitario))}</Text><Text>Desconto por unidade: {item.desconto == null ? 'Não discriminado pelo ERP' : money(Number(item.desconto))}</Text><Text>Acréscimo por unidade: {item.acrescimo == null ? 'Não discriminado pelo ERP' : money(Number(item.acrescimo))}</Text></View>)}{detail.titulo&&<Text>Nota a prazo · saldo {money(Number(detail.titulo.saldo_aberto))} · vencimento {detail.titulo.vencimento}</Text>}{detail.pagamentos.map((p,i) => <Text key={i}>{p.forma_pagamento} · {money(Number(p.valor))}</Text>)}<Text style={s.title}>Total registrado {money(Number(detail.venda.total))}</Text><Action title="Fechar detalhes" onPress={() => setDetail(null)}/></View>}</View>;
}
const s = StyleSheet.create({ screen:{flex:1,backgroundColor:'#f1f3f6'}, content:{padding:20,paddingBottom:40},card:{backgroundColor:'white',borderRadius:16,padding:16,marginVertical:8,borderWidth:1,borderColor:'#e0e5ed'},title:{fontWeight:'800',fontSize:18,color:'#102b49',marginVertical:8},input:{borderWidth:1,borderColor:'#cbd4df',borderRadius:12,padding:14,marginVertical:8,fontSize:16,color:'#102b49'},button:{backgroundColor:'#f8c928',borderRadius:12,padding:15,marginVertical:6,alignItems:'center'},buttonText:{fontWeight:'800',color:'#102b49'},error:{color:'#9c2525',padding:12},warning:{color:'#536277',lineHeight:21,marginVertical:12}});
