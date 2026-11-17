-- Índices restritos ao módulo iFood, conforme advisors, sem mudar dados de outros canais.
CREATE INDEX IF NOT EXISTS gastronomia_ifood_eventos_loja_idx ON private.gastronomia_ifood_eventos(empresa_id,merchant_id);
CREATE INDEX IF NOT EXISTS gastronomia_ifood_pagamentos_pedido_idx ON private.gastronomia_ifood_pagamentos(empresa_id,merchant_id,pedido_id);
CREATE INDEX IF NOT EXISTS gastronomia_ifood_vinculos_produto_idx ON private.gastronomia_ifood_vinculos(produto_id);
-- Não transformar reembolso negociado em quitação nem devolver estoque já preparado.
DO $fix$ DECLARE src text;BEGIN
src:=pg_get_functiondef('private.gastronomia_ifood_encerrar(uuid,uuid)'::regprocedure);
src:=replace(src,'AND ip.negociacao->>''action'' IN (''PARTIAL_CANCELLATION'',''PROPOSED_AMOUNT_REFUND'')','AND (ip.negociacao->>''action'' IN (''PARTIAL_CANCELLATION'',''PROPOSED_AMOUNT_REFUND'') OR ip.negociacao#>>''{selectedDisputeAlternative,type}'' IN (''REFUND'',''BENEFIT''))');EXECUTE src;
END $fix$;
