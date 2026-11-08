import React, { useState } from 'react';
import { Alert, StyleSheet, Text, View } from 'react-native';
import { Action } from './CommercePanels';
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
 const [name]=useState('Meu celular'),[amount]=useState('0'),[localError,setLocalError]=useState(''),[showReport,setShowReport]=useState(false);
 const cash=mobile.context?.caixa;
 const details=(c:MobileCash)=><View key={c.id} style={s.reportItem}>
  <Text style={s.reportTitle}>Caixa #{c.numero} · {c.status==='aberto'?'Aberto':'Fechado'}</Text>
  <Text>Abertura: {new Date(c.aberto_em).toLocaleString('pt-BR')}</Text>
  <Text>Operador: {c.aberto_por_nome}</Text>
  <Text>Valor inicial: {money(Number(c.valor_inicial))}</Text>
  {c.fechado_em&&<Text>Fechamento: {new Date(c.fechado_em).toLocaleString('pt-BR')}</Text>}
  {c.fechamento_resumo&&<Summary value={c.fechamento_resumo}/>}
  {c.status==='aberto'&&mobile.context?.resumo&&<Summary value={mobile.context.resumo}/>}
 </View>;
 return <View style={s.card}><Text style={s.title}>Caixa</Text>
 {mobile.context?.motivo&&<Text style={s.error}>{mobile.context.motivo}</Text>}{localError&&<Text accessibilityRole="alert" style={s.error}>{localError}</Text>}
 <Action title="Relatório" disabled={mobile.busy} onPress={()=>{setShowReport(v=>!v);if(!showReport)void mobile.refresh();}}/>
 {showReport&&<View>{mobile.history.length?mobile.history.map(details):<Text>Nenhum caixa encontrado para este celular.</Text>}</View>}
 {cash?<Action title="Fechar caixa" disabled={mobile.busy||mobile.pending} onPress={()=>Alert.alert('Fechar caixa?', 'Após o fechamento, as vendas deste caixa ficarão disponíveis somente para consulta.',[{text:'Voltar',style:'cancel'},{text:'Fechar caixa',onPress:()=>mobile.close().catch(()=>{})}])}/>:<Action title="Abrir caixa" disabled={mobile.busy||mobile.pending||!mobile.context} onPress={()=>{try{setLocalError('');mobile.open(name,Number(amount)).catch(()=>{});}catch(e){setLocalError((e as Error).message);}}}/>}
 </View>;
}

const s=StyleSheet.create({reportItem:{padding:12,marginVertical:6,borderWidth:1,borderColor:'#dce3ed',borderRadius:12},reportTitle:{fontSize:16,fontWeight:'800',color:'#102b49',marginBottom:6},card:{backgroundColor:'white',padding:16,borderRadius:16,marginVertical:8,borderColor:'#dce3ed',borderWidth:1},title:{fontSize:18,fontWeight:'800',color:'#102b49',marginVertical:10},error:{color:'#a32c2c',lineHeight:21,paddingVertical:10},input:{borderWidth:1,borderColor:'#cbd4df',borderRadius:12,padding:14,marginVertical:8,fontSize:16}});
