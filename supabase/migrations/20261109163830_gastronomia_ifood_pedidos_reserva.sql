-- Somente reservas da nova integração; não cria atendimentos ou recebimentos.
ALTER TABLE private.gastronomia_ifood_config ADD CONSTRAINT gastronomia_ifood_config_loja UNIQUE(empresa_id,merchant_id);
ALTER TABLE private.gastronomia_ifood_eventos ADD CONSTRAINT gastronomia_ifood_eventos_loja FOREIGN KEY(empresa_id,merchant_id) REFERENCES private.gastronomia_ifood_config(empresa_id,merchant_id);
CREATE TABLE private.gastronomia_ifood_pedidos (
 empresa_id uuid NOT NULL, merchant_id uuid NOT NULL, pedido_id uuid NOT NULL,
 atendimento_id uuid UNIQUE REFERENCES public.gastronomia_atendimentos(id),
 estado_ifood text NOT NULL DEFAULT 'recebido', ultimo_evento_em timestamptz,
 detalhe jsonb NOT NULL DEFAULT '{}', normalizado jsonb NOT NULL DEFAULT '{}',
 total_centavos bigint NOT NULL DEFAULT 0 CHECK(total_centavos>=0),
 pago_online_centavos bigint NOT NULL DEFAULT 0 CHECK(pago_online_centavos>=0),
 a_cobrar_centavos bigint NOT NULL DEFAULT 0 CHECK(a_cobrar_centavos>=0),
 criado_em timestamptz NOT NULL DEFAULT now(), atualizado_em timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(empresa_id,merchant_id,pedido_id),
 FOREIGN KEY(empresa_id,merchant_id) REFERENCES private.gastronomia_ifood_config(empresa_id,merchant_id)
);
ALTER TABLE private.gastronomia_ifood_pedidos ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON private.gastronomia_ifood_pedidos FROM PUBLIC,anon,authenticated;
