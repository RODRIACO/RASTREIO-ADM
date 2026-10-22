-- ============================================================
-- Aviso em tempo real para o painel da TV
-- Projeto Supabase: vgcwzfeucfkaawwwhvjo  (SQL Editor > New query)
--
-- Por que nao e o realtime "normal": ele avisa mudancas de TABELA,
-- e a TV nao pode enxergar rastreio_pedidos (la tem transportadora,
-- motorista, telefone e NF). Entao o banco manda apenas um aviso
-- curto - sem dado nenhum - e a TV busca a view embarques_tv de novo.
--
-- O aviso e por comando (for each statement), nao por linha: mexer
-- em 300 pedidos de uma vez manda UM aviso, nao 300.
--
-- Rodar de novo nao faz mal.
-- ============================================================

create or replace function public.rastreio_avisa_painel()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform realtime.send(
    jsonb_build_object('em', now()),  -- carga: so um horario, nenhum dado do pedido
    'mudou',                          -- nome do evento
    'painel-embarques',               -- canal que a TV escuta
    false                             -- canal publico: a TV assina sem login
  );
  return null;
end;
$$;

drop trigger if exists rastreio_avisa_painel on public.rastreio_pedidos;
create trigger rastreio_avisa_painel
  after insert or update or delete on public.rastreio_pedidos
  for each statement
  execute function public.rastreio_avisa_painel();
