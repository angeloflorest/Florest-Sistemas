-- Somente comprovantes técnicos dos pedidos simulados, sem payload ou dados do consumidor.
CREATE TABLE public.gastronomia_99food_sandbox_recebimentos (
  app_shop_id text NOT NULL CHECK (app_shop_id = 'florest-gastronomia-teste-01'),
  order_id text NOT NULL CHECK (order_id ~ '^[1-9][0-9]{0,18}$'),
  order_index integer CHECK (order_index >= 0),
  recebido_em timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (app_shop_id, order_id)
);
ALTER TABLE public.gastronomia_99food_sandbox_recebimentos ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.gastronomia_99food_sandbox_recebimentos FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT, INSERT ON TABLE public.gastronomia_99food_sandbox_recebimentos TO service_role;
