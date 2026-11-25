export async function mountSandbox99Food(root,{list,accept,current}){
  function element(tag,text,className){
    const node=document.createElement(tag);
    if(text)node.textContent=text;
    if(className)node.className=className;
    return node;
  }

  const section=element('section','','gs-card');
  const message=element('p','','gs-meta');
  const orders=element('div','','gs-grid gs-orders-compact');
  message.setAttribute('role','status');
  section.append(
    element('h3','99Food · Pedidos de teste'),
    element('p','Florest Gastronomia Teste. Aceites feitos aqui ficam no ambiente de teste da 99Food.','gs-meta'),
    message,orders,
  );
  root.append(section);

  const stateLabels={recebido:'Recebido',aceito:'Aceito na 99Food',encerrado:'Encerrado na 99Food'};
  const formatter=new Intl.DateTimeFormat('pt-BR',{dateStyle:'short',timeStyle:'short',timeZone:'America/Sao_Paulo'});
  async function refresh(){
    const received=await list();
    if(!current()||!section.isConnected)return;
    orders.replaceChildren();
    if(!received.length){
      orders.append(element('p','Nenhum evento de teste recebido.','gs-meta'));
      return;
    }
    for(const order of received){
      const card=element('article','','gs-card gs-order gs-order--99food');
      card.append(
        element('div','99Food · Teste','gs-order-channel gs-order-channel--99food'),
        element('h4',order.order_index==null?'Pedido de teste':'Pedido #'+order.order_index),
        element('p','ID 99Food: '+order.order_id,'gs-meta'),
        element('p',formatter.format(new Date(order.recebido_em)),'gs-meta'),
        element('strong',stateLabels[order.estado]||'Recebido'),
      );
      if(order.estado==='recebido'){
        const button=element('button','Aceitar pedido de teste','gs-btn');
        button.type='button';
        button.onclick=async()=>{
          if(!current()||button.disabled)return;
          button.disabled=true;
          message.textContent='Consultando a 99Food…';
          try{
            const result=await accept(order.order_id);
            if(!current()||!section.isConnected)return;
            message.textContent=result.erro||stateLabels[result.estado]||'Resultado indisponível.';
            await refresh();
          }catch{
            if(current())message.textContent='Resultado indisponível. Atualize a lista ou tente novamente.';
          }finally{button.disabled=false}
        };
        const actions=element('div','','gs-actions');
        actions.append(button);
        card.append(actions);
      }
      orders.append(card);
    }
  }
  try{await refresh()}
  catch{if(current())message.textContent='Não foi possível carregar os pedidos de teste da 99Food.'}
}
