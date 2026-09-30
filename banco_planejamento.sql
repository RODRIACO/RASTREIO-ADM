-- ============================================================
-- Planejamento de Entregas alimentado pelo rastreio
-- Projeto Supabase: vgcwzfeucfkaawwwhvjo  (SQL Editor > New query)
--
-- Este arquivo NAO renomeia nada e NAO apaga dados.
-- Pode rodar com o ADM e o rastreio publico no ar: as telas
-- atuais continuam funcionando igual depois dele.
--
-- Rodar de novo nao faz mal (tudo e "if not exists" / "or replace").
-- ============================================================


-- ------------------------------------------------------------
-- 1. Colunas novas
--
--    rota / embarque_previsto  -> so alimentam o painel da TV,
--                                 nao aparecem na consulta publica.
--    embarque_previsto_anterior-> guarda a data antiga quando o
--                                 embarque e adiado (vira REAGENDADO).
--    cancelado_em              -> cancelamento de verdade, diferente
--                                 de excluir (excluir apaga a linha).
-- ------------------------------------------------------------
alter table public.rastreio_pedidos
  add column if not exists rota                       text not null default '',
  add column if not exists embarque_previsto          date,
  add column if not exists embarque_previsto_anterior date,
  add column if not exists cancelado_em               timestamptz;


-- ------------------------------------------------------------
-- 2. Status gerado, agora com CANCELADO no topo
--
--    Uma coluna gerada nao pode ter a formula alterada, entao ela
--    e removida e recriada. Nada se perde: o valor e sempre
--    calculado a partir das datas das etapas.
--
--    Cancelado ganha de tudo: um pedido que ja teve producao ou
--    agendamento e depois foi cancelado continua CANCELADO.
-- ------------------------------------------------------------
alter table public.rastreio_pedidos drop column if exists status;

alter table public.rastreio_pedidos
  add column status text generated always as (
    case
      when cancelado_em is not null then 'CANCELADO'
      when entregue_em  is not null then 'ENTREGUE'
      when transito_em  is not null then 'EM TRANSITO'
      when pronto_em    is not null then 'PRONTO'
      when agendado_em  is not null then 'AGENDADO'
      when producao_em  is not null then 'PRODUCAO'
      else ''
    end
  ) stored;


-- ------------------------------------------------------------
-- 3. Reagendamento automatico
--
--    Quando alguem empurra a previsao de embarque para frente,
--    a data antiga fica guardada. E isso que faz o card aparecer
--    como REAGENDADO no painel.
--
--    Antecipar a data nao marca reagendamento.
-- ------------------------------------------------------------
create or replace function public.rastreio_marca_reagendamento()
returns trigger
language plpgsql
as $$
begin
  if new.embarque_previsto is distinct from old.embarque_previsto
     and old.embarque_previsto is not null
     and new.embarque_previsto is not null
     and new.embarque_previsto > old.embarque_previsto then
    new.embarque_previsto_anterior := old.embarque_previsto;
  end if;
  return new;
end;
$$;

drop trigger if exists rastreio_reagendamento on public.rastreio_pedidos;
create trigger rastreio_reagendamento
  before update on public.rastreio_pedidos
  for each row
  execute function public.rastreio_marca_reagendamento();


-- ------------------------------------------------------------
-- 4. A view que a TV le
--
--    Mostra SO o que aparece no card: cliente, CRM, rota, data e
--    status. Transportadora, motorista, telefone, NF e observacao
--    ficam de fora.
--
--    A view roda com os direitos de quem a criou, entao ela enxerga
--    a tabela mesmo com o RLS ligado - e por isso ela expoe apenas
--    estas cinco colunas.
--
--    Traducao dos status para o vocabulario do painel:
--      cancelado            -> CANCELADO
--      entregue             -> ENTREGUE
--      em transito          -> EM ROTA
--      data passou, nao saiu-> ATRASADO
--      embarque adiado      -> REAGENDADO
--      resto (producao,
--      agendado, pronto)    -> vazio = Planejado
--
--    A data de "hoje" usa o horario de Brasilia, senao o card viraria
--    atrasado 3 horas antes da hora.
-- ------------------------------------------------------------
create or replace view public.embarques_tv as
select
  row_number() over (order by p.embarque_previsto, p.criado_em, p.id)::text as seq,
  p.cliente,
  btrim(regexp_replace(p.descricao, '^\s*CRM\s*[-:]?\s*', '', 'i')) as crm,
  p.embarque_previsto as data,
  p.rota              as roteiro,
  case
    when p.cancelado_em is not null then 'CANCELADO'
    when p.entregue_em  is not null then 'ENTREGUE'
    when p.transito_em  is not null then 'EM ROTA'
    when p.embarque_previsto < (now() at time zone 'America/Sao_Paulo')::date then 'ATRASADO'
    when p.embarque_previsto_anterior is not null then 'REAGENDADO'
    else ''
  end as status
from public.rastreio_pedidos p
where p.embarque_previsto is not null;

grant select on public.embarques_tv to anon, authenticated;


-- ------------------------------------------------------------
-- 5. Conferencia
--
--    Depois de rodar, isto deve responder sem erro. Vai voltar
--    vazio ate alguem preencher rota e previsao de embarque no ADM.
-- ------------------------------------------------------------
-- select * from public.embarques_tv order by data, seq;
