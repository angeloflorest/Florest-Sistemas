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
 const [payments,setPayments]=useState<Payment[]>([]),[value,setValue]=useState(''),[credit,setCredit]=useState(false);
 const [band,setBand]=useState('');const lock=useRef(false),nextId=useRef(0),total=draftTotal(cart);
 const signature=JSON.stringify({cart,customer});
 useEffect(()=>{setOpen(false);setPayments([]);setValue('');setCredit(false);setBand('');setError('');},[signature]);
 const paid=payments.reduce((sum,p)=>sum+p.cents,0),remaining=total-paid;
 const add=(method:string)=>{
  try{
   const cents=parseCents(value);
   const next=addPayment(payments,method,cents,total,++nextId.current);
   const rules=mobile.context?.taxas.ativo?mobile.context.taxas.regras.filter(r=>r.forma===method):[];
   if(rules?.length&&!rules.some(r=>(r.bandeira||'')===band))throw Error('Selecione a bandeira cadastrada para este cartão.');
   next[next.length-1].band=band;
   setPayments(next);setValue(((total-next.reduce((sum,p)=>sum+p.cents,0))/100).toFixed(2).replace('.',','));setError('');
  }catch(e){setError(readableError(e));}
 };
 const confirm=async()=>{
  if(lock.current||mobile.busy||mobile.pending)return;
  try{
   if(credit)validateCredit(customer,payments,total);
   else if(remaining!==0||payments.length===0)throw Error('Complete o valor da venda antes de confirmar.');
   lock.current=true;setSending(true);setError('');
   const result=await mobile.sell(cart,customer,payments,credit);
   if(result.state==='confirmed')setOpen(false);
   else setError(result.state==='rejected'?result.error:'Venda não confirmada.');
  }catch(e){setError(readableError(e));}
  finally{lock.current=false;setSending(false);}
 };
 return <><Action title="Finalizar venda" disabled={!cart.length||total<=0||!mobile.context?.caixa||!mobile.context?.venda_habilitada||mobile.pending||mobile.busy} onPress={()=>{setError('');setPayments([]);setCredit(false);setValue((total/100).toFixed(2).replace('.',','));setOpen(true);}}/>
 <Modal visible={open} onRequestClose={()=>{if(!sending)setOpen(false);}}><SafeAreaView style={s.screen}><Scroll contentContainerStyle={s.content}>
 <Text style={s.title}>Pagamento</Text><Text style={s.title}>Total {money(total/100)}</Text>
 <Text>Recebido: {money(paid/100)} · Restante: {money(remaining/100)}</Text>
 {payments.map(p=><View key={p.id} style={s.card}><Text>{p.method} · {money(p.cents/100)}</Text><Action title="Remover pagamento" disabled={sending} onPress={()=>{setPayments(old=>old.filter(x=>x.id!==p.id));setValue((Math.min(total,remaining+p.cents)/100).toFixed(2).replace('.',','));}}/></View>)}
 {!credit&&remaining>0&&<><Input style={s.input} accessibilityLabel="Valor deste pagamento" placeholder="Valor deste pagamento" keyboardType="decimal-pad" value={value} onChangeText={setValue}/>
 {mobile.context?.taxas.ativo&&mobile.context.taxas.regras.some(r=>!!r.bandeira)&&<><Text>Bandeira do cartão</Text>{[...new Set(mobile.context.taxas.regras.map(r=>r.bandeira).filter((x):x is string=>!!x))].map(name=><Action key={name} title={band===name?'✓ '+name:name} onPress={()=>setBand(name)}/>)}</>}
 {PAYMENT_METHODS.map(method=><Action key={method} title={method} disabled={sending} onPress={()=>add(method)}/>)}</>}
 {!payments.length&&<Action title={credit?'Cancelar nota a prazo':'Nota a prazo'} disabled={sending} onPress={()=>{try{if(!credit)validateCredit(customer,[],total);setCredit(!credit);setError('');}catch(e){setError(readableError(e));}}}/>}
 {!!error&&<Text accessibilityRole="alert" style={s.error}>{error}</Text>}
 <Action title={sending?'Registrando…':'Confirmar venda'} disabled={sending||mobile.busy||mobile.pending||(!credit&&(remaining!==0||!payments.length))} onPress={()=>Alert.alert('Confirmar venda?',money(total/100),[{text:'Voltar',style:'cancel'},{text:'Confirmar',onPress:()=>{void confirm();}}])}/>
 <Action title="Voltar" disabled={sending} onPress={()=>setOpen(false)}/>
 </Scroll></SafeAreaView></Modal></>;
}
const emptyFilters: HistoryFilters = { start: '', end: '', number: '', customer: '', cash: '', operator: '' };
export function SalesHistory({ c, profile }: { c: SupabaseClient; profile: Profile }) {
 const [rows,setRows]=useState<SaleRow[]>([]),[detail,setDetail]=useState<Awaited<ReturnType<typeof historyDetail>>|null>(null);
 const [busy,setBusy]=useState(false),[error,setError]=useState(''),[hasMore,setHasMore]=useState(false);
 const [reload,setReload]=useState(0);
 const seq=useRef(0);
 useEffect(()=>{
  let active=true;const id=++seq.current;
  setBusy(true);setError('');setRows([]);setDetail(null);
  const start=new Date();start.setDate(start.getDate()-7);
  const filters:HistoryFilters={start:start.toISOString().slice(0,10),end:new Date().toISOString().slice(0,10),number:'',customer:'',cash:'',operator:''};
  historyPage(c,profile,'',0,filters).then(page=>{if(active&&id===seq.current){setRows(page);setHasMore(page.length===100);}}).catch(e=>{if(active)setError(readableError(e));}).finally(()=>{if(active)setBusy(false);});
  return()=>{active=false;};
 },[c,profile.id,profile.empresa_id,reload]);
 const open=async(row:SaleRow)=>{setBusy(true);setError('');try{setDetail(await historyDetail(c,profile,row.id));}catch(e){setError(readableError(e));}finally{setBusy(false);}};
 return <View style={s.card}><Text style={s.title}>Vendas dos últimos 7 dias</Text>
 <Action title="Atualizar vendas" disabled={busy} onPress={()=>setReload(x=>x+1)}/>
 {busy&&<ActivityIndicator/>}{!!error&&<Text accessibilityRole="alert" style={s.error}>{error}</Text>}
 {rows.map(row=><TouchableOpacity accessibilityRole="button" key={row.id} style={s.card} onPress={()=>open(row)} disabled={busy}>
 <Text style={s.title}>Venda #{row.numero_venda} · {money(row.total)}</Text><Text>{new Date(row.criado_em).toLocaleString('pt-BR')} · {row.cliente_nome||'Consumidor'}</Text>
 <Text>Toque para ver detalhes</Text></TouchableOpacity>)}
 {!busy&&!rows.length&&!error&&<Text>Nenhuma venda encontrada nos últimos sete dias.</Text>}
 {hasMore&&<Text>Exibindo as 100 vendas mais recentes. A consulta completa exige paginação.</Text>}
 {detail&&<View style={s.card}><Text style={s.title}>Venda #{detail.venda.numero_venda}</Text>
 <Text>{detail.cliente_nome||'Consumidor'}</Text>
 {detail.itens.map((item,i)=><Text key={i}>{item.nome} · {item.quantidade} × {money(Number(item.preco_unitario))}</Text>)}
 {detail.pagamentos.map((p,i)=><Text key={i}>{p.forma_pagamento} · {money(Number(p.valor))}</Text>)}
 <Text style={s.title}>Total {money(Number(detail.venda.total))}</Text>
 <Text>Somente consulta. Edição depende de validação do caixa aberto e de operação segura no servidor.</Text>
 <Action title="Fechar detalhes" onPress={()=>setDetail(null)}/></View>}
 </View>;
}
const s = StyleSheet.create({ screen:{flex:1,backgroundColor:'#f1f3f6'}, content:{padding:20,paddingBottom:40},card:{backgroundColor:'white',borderRadius:16,padding:16,marginVertical:8,borderWidth:1,borderColor:'#e0e5ed'},title:{fontWeight:'800',fontSize:18,color:'#102b49',marginVertical:8},input:{borderWidth:1,borderColor:'#cbd4df',borderRadius:12,padding:14,marginVertical:8,fontSize:16,color:'#102b49'},button:{backgroundColor:'#f8c928',borderRadius:12,padding:15,marginVertical:6,alignItems:'center'},buttonText:{fontWeight:'800',color:'#102b49'},error:{color:'#9c2525',padding:12},warning:{color:'#536277',lineHeight:21,marginVertical:12}});
