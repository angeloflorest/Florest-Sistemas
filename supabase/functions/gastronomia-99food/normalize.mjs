const cent=(v,name,optional=false)=>{if(optional&&v==null)return 0;if(!Number.isSafeInteger(v)||v<0||v>1e10)throw Error('Valor inválido em '+name+'.');return v};
export function normalizeOrder(d){
 const warnings=[],prices=d.price??{},fees=prices.others_fees??{},mode=d.fulfillment_mode===1||d.delivery_type===0?'retirada':'entrega';
 if(![0,1,2].includes(d.delivery_type))warnings.push('Modalidade de entrega desconhecida.');
 const subtotal=cent(prices.order_price,'order_price'),platformPrice=d.delivery_type===1&&prices.real_price==null;
 let subsidy=0;for(const promo of d.promotions??[]){if(promo.shop_subside_price==null){if(platformPrice)warnings.push('Subsídio da promoção não informado: concilie o valor da loja.');}else subsidy+=cent(promo.shop_subside_price,'shop_subside_price');}
 if(platformPrice&&prices.items_discount>0&&!Array.isArray(d.promotions))warnings.push('Promoções não informadas: concilie o valor da loja.');
 // Modelo 1 não contém real_price/real_pay_price. Serviço e frete da plataforma não são receita da loja.
 const total=platformPrice?cent(subtotal-subsidy+cent(prices.meal_top_up_price,'meal_top_up_price',true),'total_loja'):cent(prices.real_price,'real_price');
 const customer=prices.real_pay_price==null&&platformPrice?null:cent(prices.real_pay_price,'real_pay_price');
 const p={itens:subtotal,total_cliente:customer,total_loja:total,subsidio_loja:subsidy,entrega_original:cent(prices.store_charged_delivery_price,'store_charged_delivery_price',true),entrega:cent(prices.delivery_price,'delivery_price',true),desconto_itens:cent(prices.items_discount,'items_discount',true),desconto_entrega:cent(prices.delivery_discount,'delivery_discount',true),reembolso:cent(prices.refund_price,'refund_price',true),servico:cent(fees.service_price??prices.service_price,'service_price',true),pedido_minimo:cent(fees.small_order_price,'small_order_price',true),complemento_minimo:cent(fees.meal_top_up_price??prices.meal_top_up_price,'meal_top_up_price',true),gorjeta:cent(fees.total_tip_money,'total_tip_money',true),cupom:cent(fees.coupon_discount,'coupon_discount',true),cancelamento_parcial:cent(prices.in_sale_refund_to_c_fee,'in_sale_refund_to_c_fee',true)};
 // coupon_discount e items_discount podem descrever o mesmo desconto. Nunca somar novamente.
 const lines=[];
 function item(raw,multiplier=1,depth=0){
  if(depth>8)throw Error('Complementos excedem oito níveis.');
  const qty=Number(raw.amount);if(!Number.isFinite(qty)||qty<=0||qty>100)throw Error('Quantidade inválida.');
  const result={codigo_externo:String(raw.app_item_id??''),nome:String(raw.name??'').slice(0,200),quantidade:qty*multiplier,total:cent(raw.total_price??(depth>0?cent(raw.sku_price,'item.sku_price',true)*qty:undefined),'item.total_price'),observacao:String(raw.remark??'').slice(0,1000),adicionais:[],detalhe:raw};
  if(!result.codigo_externo)warnings.push('Produto sem app_item_id: '+result.nome);
  for(const child of raw.sub_item_list??[]){const sub=item(child,multiplier*qty,depth+1);result.adicionais.push(sub,...sub.adicionais);}
  if(Number(raw.submit_refund_amount)>0)warnings.push('Item com cancelamento parcial: '+result.nome);
  return result;
 }
 if(!Array.isArray(d.order_items)||!d.order_items.length||d.order_items.length>200)throw Error('Lista de produtos inválida.');
 for(const raw of d.order_items)lines.push(item(raw));
 if(lines.reduce((sum,i)=>sum+i.total,0)!==subtotal)warnings.push('A soma dos itens difere do subtotal informado pela 99Food.');
 const pos=[154,262,263,264].includes(d.pay_channel)||d.pay_type===3,offline=d.pay_channel===153||pos||d.pay_type===2,platform=d.delivery_type===1;
 if(![1,2,3,4,5,6].includes(d.pay_type))warnings.push('Forma de pagamento desconhecida: confira o recebimento.');
 const rawDue=platform?prices.shop_paid_money:prices.customer_need_paying_money;
 const pendingCash=offline&&rawDue==null;
 const due=offline?cent(rawDue,platform?'shop_paid_money':'customer_need_paying_money',true):0;
 const companyOffline=Math.min(due,total),offlineFee=Math.max(0,due-companyOffline),online=pendingCash?0:Math.max(0,total-companyOffline);
 if(p.reembolso||p.cancelamento_parcial)warnings.push('Pedido com reembolso/cancelamento parcial: conciliação necessária.');
 const address=d.receive_address??{},name=address.name||[address.first_name,address.last_name].filter(Boolean).join(' ')||'Cliente 99Food';
 return {versao:1,order_id:String(d.order_id),numero:d.order_index,tipo:mode,cliente:name,telefone:[address.virtual_phone_number||address.phone,address.virtual_phone_number&&address.locator?'ramal '+address.locator:''].filter(Boolean).join(' · '),endereco:[address.poi_address||address['formatted Address'],address.house_number].filter(Boolean).join(', '),complemento:address.complement||'',referencia:address.reference||'',observacao:d.remark||'',itens:lines,precos:p,total,pago_online:online,a_cobrar:due,valor_presencial_loja:companyOffline,taxa_presencial_plataforma:offlineFee,aguardando_valor_presencial:pendingCash,forma_presencial:pos?'Cartão na entrega':'Dinheiro',pay_type:d.pay_type,pay_channel:d.pay_channel,promocoes:Array.isArray(d.promotions)?d.promotions:[],avisos:[...new Set(warnings)]};
}
