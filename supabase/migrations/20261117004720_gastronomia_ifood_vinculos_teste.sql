-- Vínculos fictícios por nome são exclusivos de pedidos isTest; não publicam catálogo.
ALTER TABLE private.gastronomia_ifood_vinculos ADD COLUMN nome_teste text CHECK(nome_teste IS NULL OR length(nome_teste) BETWEEN 1 AND 120);
