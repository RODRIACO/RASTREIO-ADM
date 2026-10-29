-- ============================================================
-- Rastrear tambem pela CRM
-- Projeto Supabase: vgcwzfeucfkaawwwhvjo  (SQL Editor > New query)
--
-- Ate agora a consulta publica so achava o pedido pelo numero. Passa a
-- achar tambem pela CRM, que fica gravada na coluna "descricao".
--
-- Como a CRM foi cadastrada de varios jeitos ("38858", "CRM 38858",
-- "CRM: 38858"), a comparacao usa so os digitos do que a pessoa digitou
-- e procura essa sequencia dentro da descricao.
--
-- Trava: so vale como CRM a partir de 5 digitos. Assim uma descricao
-- antiga de texto livre ("2 BALCOES") nunca e devolvida por engano.
--
-- A funcao tem colunas fixas, entao precisa ser recriada - nao da para
-- so alterar. Sao alguns segundos; uma consulta que caia exatamente
-- nesse instante falha e basta tentar de novo.
--
-- Rodar de novo nao faz mal.
-- ============================================================

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
  with termo as (
    select btrim(coalesce(p_numero, ''))                            as texto,
           regexp_replace(coalesce(p_numero, ''), '\D', '', 'g')    as digitos
  )
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
  from public.rastreio_pedidos p, termo t
  where (
          -- pelo numero do pedido, como sempre foi
          upper(btrim(p.numero)) = upper(t.texto)
          -- ou pela CRM: a sequencia de digitos inteira dentro da descricao,
          -- nunca grudada em outro numero ("138858" nao responde por "38858")
          or (
            char_length(t.digitos) >= 5
            and p.descricao ~ ('(^|[^0-9])' || t.digitos || '([^0-9]|$)')
          )
        )
    and p_numero ~ '[0-9]'
    and char_length(p_numero) <= 40
  order by p.criado_em, p.id
  limit 50;
$fn$;

revoke all on function public.rastreio_consultar(text) from public;
grant execute on function public.rastreio_consultar(text) to anon, authenticated;


-- ------------------------------------------------------------
-- Conferencia (troque pelos seus valores)
-- ------------------------------------------------------------
-- select numero, cliente, descricao from public.rastreio_consultar('38858');
-- select numero, cliente, descricao from public.rastreio_consultar('CRM 38858');
-- select numero, cliente, descricao from public.rastreio_consultar('304061768');
