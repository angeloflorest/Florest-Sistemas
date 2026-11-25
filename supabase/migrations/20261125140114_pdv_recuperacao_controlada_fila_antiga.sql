-- Exceção administrativa explícita para sincronizar filas antigas, sem reabrir caixas.
CREATE TABLE private.pdv_desktop_recuperacao_liberacoes (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 empresa_id uuid NOT NULL REFERENCES public.empresas(id),
 caixa_destino uuid NOT NULL REFERENCES public.caixas(id),
 caixas_origem uuid[] NOT NULL CHECK(cardinality(caixas_origem)>0),
 criada_ate timestamptz NOT NULL,
 expira_em timestamptz NOT NULL,
 ativo boolean NOT NULL DEFAULT true,
 motivo text NOT NULL,
 autorizado_em timestamptz NOT NULL DEFAULT clock_timestamp(),
 CHECK(expira_em>autorizado_em AND expira_em<=autorizado_em+interval '24 hours')
);
CREATE UNIQUE INDEX pdv_desktop_recuperacao_ativa ON private.pdv_desktop_recuperacao_liberacoes(empresa_id) WHERE ativo;
ALTER TABLE private.pdv_desktop_recuperacao_liberacoes ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON private.pdv_desktop_recuperacao_liberacoes FROM PUBLIC,anon,authenticated;
CREATE TABLE private.pdv_desktop_recuperacao_auditoria (
 empresa_id uuid NOT NULL,
 id_local uuid NOT NULL,
 liberacao_id uuid NOT NULL REFERENCES private.pdv_desktop_recuperacao_liberacoes(id),
 usuario_id uuid NOT NULL,
 caixa_origem uuid NOT NULL REFERENCES public.caixas(id),
 caixa_destino uuid NOT NULL REFERENCES public.caixas(id),
 criada_local_em timestamptz NOT NULL,
 recuperada_em timestamptz NOT NULL DEFAULT clock_timestamp(),
 venda_id uuid NOT NULL REFERENCES public.vendas(id),
 PRIMARY KEY(empresa_id,id_local),
 FOREIGN KEY(empresa_id,id_local) REFERENCES private.pdv_desktop_recebimentos(empresa_id,id_local)
);
CREATE INDEX pdv_desktop_recuperacao_por_liberacao ON private.pdv_desktop_recuperacao_auditoria(liberacao_id);
CREATE INDEX pdv_desktop_recuperacao_por_venda ON private.pdv_desktop_recuperacao_auditoria(venda_id);
CREATE INDEX pdv_desktop_recuperacao_origem ON private.pdv_desktop_recuperacao_auditoria(caixa_origem);
CREATE INDEX pdv_desktop_recuperacao_destino ON private.pdv_desktop_recuperacao_auditoria(caixa_destino);
CREATE INDEX pdv_desktop_recuperacao_destino_liberacao ON private.pdv_desktop_recuperacao_liberacoes(caixa_destino);
ALTER TABLE private.pdv_desktop_recuperacao_auditoria ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON private.pdv_desktop_recuperacao_auditoria FROM PUBLIC,anon,authenticated;
DO $patch$
DECLARE src text;old text;
BEGIN
 src:=pg_get_functiondef('public.pdv_desktop_sincronizar(uuid,uuid,jsonb,timestamptz)'::regprocedure);
 old:='v uuid; num bigint; atual uuid;';
 IF strpos(src,old)=0 THEN RAISE EXCEPTION 'Declaração de sincronização divergente';END IF;
 src:=replace(src,old,old||' liberacao private.pdv_desktop_recuperacao_liberacoes%rowtype; origem public.caixas%rowtype; recuperando boolean:=false;');
 old:=$old$if atual<>p_caixa_id then raise exception 'O caixa desta venda foi fechado ou substituído. A venda permanece pendente para conferência.' using errcode='CX003'; end if;$old$;
 IF strpos(src,old)=0 THEN RAISE EXCEPTION 'Validação de caixa divergente';END IF;
 src:=replace(src,old,$new$if atual<>p_caixa_id then
    select * into liberacao from private.pdv_desktop_recuperacao_liberacoes l
     where l.empresa_id=e and l.caixa_destino=atual and p_caixa_id=ANY(l.caixas_origem)
      and l.ativo and l.expira_em>clock_timestamp() and p_criada_em<=l.criada_ate for share;
    if liberacao.id is null then
      raise exception 'O caixa desta venda foi fechado ou substituído. A venda permanece pendente para conferência.' using errcode='CX003';
    end if;
    select * into origem from public.caixas where empresa_id=e and id=p_caixa_id and tipo_caixa='PDV' and status='fechado' for share;
    if origem.id is null or origem.fechado_em is null or p_criada_em<origem.aberto_em-interval '5 minutes' or p_criada_em>origem.fechado_em+interval '5 minutes' then
      raise exception 'A data da venda não corresponde ao caixa de origem autorizado.' using errcode='CX003';
    end if;
    if p_pedido->>'userId' is distinct from auth.uid()::text or p_pedido->>'caixaId' is distinct from p_caixa_id::text then
      raise exception 'A recuperação exige o operador e o caixa originais da venda.' using errcode='42501';
    end if;
    recuperando:=true;
  end if;$new$);
 old:=$old$return jsonb_build_object('empresaId',e,'idLocal',p_id_local,'idRemoto',v,'numeroVenda',num,'repetida',false);$old$;
 IF strpos(src,old)=0 THEN RAISE EXCEPTION 'Retorno de sincronização divergente';END IF;
 src:=replace(src,old,$new$if recuperando then
    insert into private.pdv_desktop_recuperacao_auditoria(empresa_id,id_local,liberacao_id,usuario_id,caixa_origem,caixa_destino,criada_local_em,venda_id)
     values(e,p_id_local,liberacao.id,auth.uid(),p_caixa_id,atual,p_criada_em,v);
  end if;
  return jsonb_build_object('empresaId',e,'idLocal',p_id_local,'idRemoto',v,'numeroVenda',num,'repetida',false);$new$);
 EXECUTE src;
END $patch$;
