import React, { useState } from 'react';
import { Alert, StyleSheet, Text, View } from 'react-native';
import { KeyboardInput as Input } from './KeyboardForm';
import { Action } from './CommercePanels';
import { parseCents } from './commerce';
import { money } from './domain';
import type { MobilePOS } from './useMobilePOS';
import type { CashSummary, MobileCash } from './mobileGateway';
export function Summary({value}:{value:CashSummary}) {
 return <View><Text>Vendas: {value.quantidade_vendas} · Total vendido: {money(Number(value.total_vendido))}</Text>{['Dinheiro','Pix','Cartão de Crédito','Cartão de Débito'].map(method=><Text key={method}>{method}: {money(Number(value.por_forma.find(p=>p.forma_pagamento===method)?.total||0))}</Text>)}<Text>Nota a prazo: {money(Number(value.nota_prazo))}</Text><Text>Dinheiro esperado (inclui abertura): {money(Number(value.dinheiro_esperado))}</Text></View>;
}
export function OperationReceipt({mobile}:{mobile:MobilePOS}) {
 if(!mobile.pending&&!mobile.error)return null;
 const r=mobile.receipt;
 return <View style={s.card}><Text style={s.title}>Resultado da operação</Text>{mobile.error ? <Text accessibilityRole="alert" style={s.error}>{mobile.error}</Text>:null}
 {mobile.pending&&<><Text>{r?.state==='confirmed'?'Operação confirmada pelo servidor.':r?.state==='rejected'?`Operação recusada: ${r.error}`:'Existe tentativa pendente. Consulte o resultado antes de continuar.'}</Text>{r?.state==='confirmed'&&mobile.kind==='sale'&&<Text>Venda #{String(r.result.numero_venda)} · {money(Number(r.result.total))}</Text>}<Action title="Consultar resultado no servidor" onPress={()=>mobile.recover(false)} disabled={mobile.busy}/>{r?.state==='absent'&&<Action title="Reenviar a mesma tentativa" disabled={mobile.busy} onPress={()=>Alert.alert('Repetir a tentativa?', 'Será mantida a mesma chave e os mesmos dados. O servidor impede duplicidade.',[{text:'Voltar',style:'cancel'},{text:'Reenviar',onPress:()=>mobile.recover(true)}])}/>} {r&&r.state!=='absent'&&<Action title={r.state==='confirmed'&&mobile.kind==='sale'?'Reconhecer venda e iniciar outra':'Reconhecer resultado'} onPress={mobile.acknowledge} disabled={mobile.busy}/>}</>}
 </View>;
}
export function MobileCashPanel({mobile,deviceId}:{mobile:MobilePOS;deviceId:string}) {
 const [name,setName]=useState('Meu celular'),[amount,setAmount]=useState('0'),[localError,setLocalError]=useState('');
 const cash=mobile.context?.caixa;
 const details=(c:MobileCash)=><><Text>Caixa móvel #{c.numero} · {c.dispositivo_nome}</Text><Text>Operador: {c.aberto_por_nome}</Text><Text>Abertura: {new Date(c.aberto_em).toLocaleString('pt-BR')} · Troco {money(Number(c.valor_inicial))}</Text>{c.fechado_em&&<Text>Fechado: {new Date(c.fechado_em).toLocaleString('pt-BR')} · {c.fechado_por_nome}</Text>}</>;
 return <View style={s.card}><Text style={s.title}>Caixa deste celular</Text><Text>Dispositivo: {deviceId}</Text><Action title="Atualizar caixa e relatório" disabled={mobile.busy} onPress={mobile.refresh}/>{mobile.context?.motivo&&<Text style={s.error}>{mobile.context.motivo}</Text>}{localError&&<Text accessibilityRole="alert" style={s.error}>{localError}</Text>}
 {cash?<>{details(cash)}{mobile.context?.resumo&&<Summary value={mobile.context.resumo}/>}<Action title="Fechar este caixa móvel" disabled={mobile.busy||mobile.pending} onPress={()=>Alert.alert('Fechar caixa móvel?', 'O fechamento será registrado no servidor e impedirá novas vendas nesta sessão. O caixa principal permanece intacto.',[{text:'Voltar',style:'cancel'},{text:'Fechar caixa',onPress:()=>mobile.close().catch(()=>{})}])}/></>:<><Text>Sem caixa móvel aberto.</Text><Input style={s.input} accessibilityLabel="Nome do celular" placeholder="Identificação do celular" value={name} onChangeText={setName} maxLength={60}/><Input style={s.input} accessibilityLabel="Troco inicial" placeholder="Troco inicial em reais" value={amount} onChangeText={setAmount} keyboardType="decimal-pad"/><Action title="Abrir caixa deste celular" disabled={mobile.busy||mobile.pending||!mobile.context} onPress={()=>{try{setLocalError('');const cents=parseCents(amount);mobile.open(name.trim(),cents/100).catch(()=>{});}catch(e){setLocalError((e as Error).message);}}}/></>}
 <Text style={s.title}>Histórico de caixas e movimentações</Text>{mobile.history.map(c=><View key={c.id} style={s.card}>{details(c)}<Text>{c.status==='aberto'?'Aberto':'Fechado'}</Text>{(c.resumo||c.fechamento_resumo)&&<Summary value={(c.resumo||c.fechamento_resumo)!}/>}<Text>Consulte as vendas e os pagamentos deste caixa na aba Vendas usando o identificador: {c.id}</Text></View>)}</View>;
}
const s=StyleSheet.create({card:{backgroundColor:'white',padding:16,borderRadius:16,marginVertical:8,borderColor:'#dce3ed',borderWidth:1},title:{fontSize:18,fontWeight:'800',color:'#102b49',marginVertical:10},error:{color:'#a32c2c',lineHeight:21,paddingVertical:10},input:{borderWidth:1,borderColor:'#cbd4df',borderRadius:12,padding:14,marginVertical:8,fontSize:16}});
