-- ============================================================
-- Vários anexos por pedido (NF, CRM, ...)
-- Projeto Supabase: vgcwzfeucfkaawwwhvjo  (SQL Editor > New query)
--
-- Antes: um PDF por pedido, no proprio registro (nf_arquivo / nf_link).
-- Agora: uma lista. O nome e o que o operador digita, e e ele que
-- aparece no botao da tela do cliente - "NF39027", "CRM39027".
--
-- As colunas antigas continuam existindo e sendo devolvidas pela
-- consulta, para a tela publica atual seguir funcionando ate a nova
-- subir. Nada e apagado por este arquivo.
--
-- Rodar de novo nao faz mal.
-- ============================================================


-- ------------------------------------------------------------
-- 1. A lista de anexos
--
--    nome    -> o que o operador digitou; tem que comecar com NF ou CRM
--    arquivo -> caminho no bucket rastreio-nf
--    link    -> link antigo do Google Drive (so nos importados)
--    publico -> false esconde o anexo do cliente; serve so a equipe
--
--    Apagar o pedido leva os anexos junto (on delete cascade); os
--    arquivos no bucket quem remove e o ADM.
-- ------------------------------------------------------------
create table if not exists public.rastreio_anexos (
  id         uuid primary key default gen_random_uuid(),
  pedido_id  uuid not null references public.rastreio_pedidos(id) on delete cascade,
  nome       text not null,
  arquivo    text not null default '',
  link       text not null default '',
  publico    boolean not null default true,
  criado_em  timestamptz not null default now(),

  constraint rastreio_anexos_nome_ok check (
    btrim(nome) <> ''
    and char_length(nome) <= 40
    and upper(btrim(nome)) ~ '^(NF|CRM)'
  ),
  -- anexo sem arquivo nenhum nao serve para nada
  constraint rastreio_anexos_tem_arquivo check (
    btrim(arquivo) <> '' or btrim(link) <> ''
  )
);

create index if not exists rastreio_anexos_pedido_idx
  on public.rastreio_anexos (pedido_id, criado_em);


-- ------------------------------------------------------------
-- 2. Quem mexe
--    Mesma regra da tabela de pedidos: so quem entrou no ADM.
--    O cliente nao le esta tabela direto - os anexos chegam a ele
--    pela funcao de consulta da secao 4.
-- ------------------------------------------------------------
alter table public.rastreio_anexos enable row level security;

drop policy if exists rastreio_anexos_ler     on public.rastreio_anexos;
drop policy if exists rastreio_anexos_inserir on public.rastreio_anexos;
drop policy if exists rastreio_anexos_alterar on public.rastreio_anexos;
drop policy if exists rastreio_anexos_apagar  on public.rastreio_anexos;

create policy rastreio_anexos_ler     on public.rastreio_anexos for select to authenticated
  using (public.rastreio_pode());
create policy rastreio_anexos_inserir on public.rastreio_anexos for insert to authenticated
  with check (public.rastreio_pode());
create policy rastreio_anexos_alterar on public.rastreio_anexos for update to authenticated
  using (public.rastreio_pode()) with check (public.rastreio_pode());
create policy rastreio_anexos_apagar  on public.rastreio_anexos for delete to authenticated
  using (public.rastreio_pode());


-- ------------------------------------------------------------
-- 3. O que ja existe vira o primeiro item da lista
--
--    137 dos PDFs atuais tem como "nota fiscal" a chave de 44
--    digitos, que daria um botao ilegivel na tela do cliente. Entao:
--    numero curto vira "NF12345"; o resto fica so "NF", e quem quiser
--    renomeia depois pelo ADM.
--
--    So roda uma vez: o "not exists" impede duplicar se rodar de novo.
-- ------------------------------------------------------------
insert into public.rastreio_anexos (pedido_id, nome, arquivo, link, publico)
select p.id,
       case when btrim(p.nota_fiscal) ~ '^[0-9]{1,9}$'
            then 'NF' || btrim(p.nota_fiscal)
            else 'NF'
       end,
       coalesce(p.nf_arquivo, ''),
       coalesce(p.nf_link, ''),
       true
from public.rastreio_pedidos p
where (btrim(coalesce(p.nf_arquivo,'')) <> '' or btrim(coalesce(p.nf_link,'')) <> '')
  and not exists (
    select 1 from public.rastreio_anexos a where a.pedido_id = p.id
  );


-- ------------------------------------------------------------
-- 4. A consulta publica passa a devolver a lista
--
--    Ganha duas colunas: cancelado_em (para a tela mostrar
--    "Cancelado" com a data) e anexos (so os publicos).
--
--    A funcao tem colunas fixas, entao precisa ser recriada - nao da
--    para so alterar. Sao alguns segundos; uma consulta que caia
--    exatamente nesse instante falha e basta tentar de novo.
-- ------------------------------------------------------------
drop function if exists public.rastreio_consultar(text);

create function public.rastreio_consultar(p_numero text)
returns table (
  numero         text,
  cliente        text,
  descricao      text,
  status         text,
  producao_em    timestamptz,
  agendado_em    timestamptz,
  pronto_em      timestamptz,
  transito_em    timestamptz,
  entregue_em    timestamptz,
  cancelado_em   timestamptz,
  previsao       date,
  localizacao    text,
  recebido_por   text,
  transportadora text,
  motorista      text,
  telefone       text,
  nota_fiscal    text,
  observacao     text,
  nf_arquivo     text,
  nf_link        text,
  anexos         jsonb
)
language sql stable security definer set search_path = public as $fn$
  select p.numero, p.cliente, p.descricao, p.status,
         p.producao_em, p.agendado_em, p.pronto_em, p.transito_em, p.entregue_em,
         p.cancelado_em,
         p.previsao, p.localizacao, p.recebido_por,
         p.transportadora, p.motorista, p.telefone,
         p.nota_fiscal, p.observacao, p.nf_arquivo, p.nf_link,
         coalesce((
           select jsonb_agg(
                    jsonb_build_object('nome', a.nome, 'arquivo', a.arquivo, 'link', a.link)
                    order by a.criado_em
                  )
           from public.rastreio_anexos a
           where a.pedido_id = p.id and a.publico
         ), '[]'::jsonb)
  from public.rastreio_pedidos p
  where upper(btrim(p.numero)) = upper(btrim(p_numero))
    and p_numero ~ '[0-9]'
    and char_length(p_numero) <= 40
  order by p.criado_em, p.id
  limit 50;
$fn$;

revoke all on function public.rastreio_consultar(text) from public;
grant execute on function public.rastreio_consultar(text) to anon, authenticated;


-- ------------------------------------------------------------
-- 5. Conferencia
-- ------------------------------------------------------------
-- select count(*) from public.rastreio_anexos;
-- select numero, status, anexos from public.rastreio_consultar('304061768');
