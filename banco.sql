-- ============================================================
--  RASTREIO DE PEDIDOS — RODRIAÇO + SODEXO
--  Roda no projeto Supabase único da Rodriaço, ao lado do
--  Estoque Livre e do Controle de Ferramentas, sem encostar
--  em nada deles: só cria coisas com o prefixo "rastreio".
--  Rode UMA VEZ, inteiro, no SQL Editor. Pode rodar de novo
--  sem quebrar nada (é idempotente).
-- ============================================================


-- ------------------------------------------------------------
-- 1. PEDIDOS
--    Uma linha por ENTREGA. O número não é único de propósito:
--    a mesma ordem de compra pode sair em várias entregas, cada
--    uma com sua NF e seu status.
--    O status nunca é digitado: é a etapa mais avançada que tem
--    data. Assim status e histórico não têm como discordar.
-- ------------------------------------------------------------
create table if not exists public.rastreio_pedidos (
  id             uuid primary key default gen_random_uuid(),
  numero         text not null check (btrim(numero) <> '' and char_length(numero) <= 40),
  cliente        text not null default '',
  descricao      text not null default '',

  producao_em    timestamptz,
  agendado_em    timestamptz,
  pronto_em      timestamptz,
  transito_em    timestamptz,
  entregue_em    timestamptz,
  status         text generated always as (
                   case
                     when entregue_em is not null then 'ENTREGUE'
                     when transito_em is not null then 'EM TRANSITO'
                     when pronto_em   is not null then 'PRONTO'
                     when agendado_em is not null then 'AGENDADO'
                     when producao_em is not null then 'PRODUCAO'
                     else ''
                   end
                 ) stored,

  previsao       date,
  localizacao    text not null default '',
  recebido_por   text not null default '',
  transportadora text not null default '',
  motorista      text not null default '',
  telefone       text not null default '',
  nota_fiscal    text not null default '',
  observacao     text not null default '',

  -- PDF da NF: caminho dentro do bucket da seção 5.
  nf_arquivo     text not null default '',
  -- Link antigo do Google Drive, só dos pedidos importados. Fica vazio
  -- depois que o PDF correspondente for copiado para o bucket.
  nf_link        text not null default '',

  criado_em      timestamptz not null default now(),
  atualizado_em  timestamptz not null default now()
);

-- A consulta pública procura por aqui (ver seção 4).
create index if not exists rastreio_numero_idx on public.rastreio_pedidos (upper(btrim(numero)));
create index if not exists rastreio_nf_idx     on public.rastreio_pedidos (nota_fiscal);
create index if not exists rastreio_criado_idx on public.rastreio_pedidos (criado_em desc);

create or replace function public.rastreio_toca()
returns trigger language plpgsql as $fn$
begin
  new.atualizado_em := now();
  return new;
end; $fn$;

drop trigger if exists rastreio_pedidos_toca on public.rastreio_pedidos;
create trigger rastreio_pedidos_toca
before update on public.rastreio_pedidos
for each row execute function public.rastreio_toca();


-- ------------------------------------------------------------
-- 2. QUEM ENTRA NO ADM
--    O ADM tem um login só, compartilhado, sem tela de cadastro.
--    Esta tabela diz qual conta é essa. Ela existe porque o
--    cadastro de contas é um só para o projeto inteiro: sem isto,
--    qualquer conta do Estoque Livre abriria o ADM.
--    Ninguém lê nem escreve aqui pelo app — só pelo SQL Editor,
--    com as funções da seção 6.
-- ------------------------------------------------------------
create table if not exists public.rastreio_acesso (
  usuario_id uuid primary key references auth.users(id) on delete cascade,
  email      text not null default '',
  criado_em  timestamptz not null default now()
);

create or replace function public.rastreio_pode()
returns boolean language sql stable security definer set search_path = public as $fn$
  select exists (
    select 1 from public.rastreio_acesso a where a.usuario_id = auth.uid()
  );
$fn$;

revoke all on function public.rastreio_pode() from public, anon;
grant execute on function public.rastreio_pode() to authenticated;


-- ------------------------------------------------------------
-- 3. REGRAS DE ACESSO
--    Quem entrou com o login do ADM: lê, cadastra, edita e exclui.
--    Quem não entrou (o cliente, no rastreio): não enxerga a
--    tabela. Consulta só pela função da seção 4.
-- ------------------------------------------------------------
alter table public.rastreio_pedidos enable row level security;
alter table public.rastreio_acesso  enable row level security;

drop policy if exists rastreio_ler     on public.rastreio_pedidos;
drop policy if exists rastreio_inserir on public.rastreio_pedidos;
drop policy if exists rastreio_alterar on public.rastreio_pedidos;
drop policy if exists rastreio_apagar  on public.rastreio_pedidos;
create policy rastreio_ler     on public.rastreio_pedidos for select to authenticated
  using (public.rastreio_pode());
create policy rastreio_inserir on public.rastreio_pedidos for insert to authenticated
  with check (public.rastreio_pode());
create policy rastreio_alterar on public.rastreio_pedidos for update to authenticated
  using (public.rastreio_pode()) with check (public.rastreio_pode());
create policy rastreio_apagar  on public.rastreio_pedidos for delete to authenticated
  using (public.rastreio_pode());

-- rastreio_acesso fica sem política nenhuma: com RLS ligado, isso
-- significa que pela API ninguém lê nem grava.

-- O Supabase concede tudo sozinho para tabelas novas em public, inclusive
-- para quem não está logado. As políticas acima já barram, mas aqui o
-- visitante anônimo perde até a permissão de tentar.
revoke all on public.rastreio_pedidos from anon;
revoke all on public.rastreio_acesso  from anon, authenticated;
grant select, insert, update, delete on public.rastreio_pedidos to authenticated;


-- ------------------------------------------------------------
-- 4. CONSULTA PÚBLICA
--    É a única porta do rastreio, que roda sem login. Devolve só
--    as entregas do número digitado e só os campos que a tela
--    mostra — não existe jeito de listar a tabela por aqui.
--    O número precisa ter algum dígito: pedidos lançados como
--    "SEM OC" não são rastreáveis, senão quem digitasse isso
--    veria as entregas de vários clientes de uma vez.
-- ------------------------------------------------------------
create or replace function public.rastreio_consultar(p_numero text)
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
  previsao       date,
  localizacao    text,
  recebido_por   text,
  transportadora text,
  motorista      text,
  telefone       text,
  nota_fiscal    text,
  observacao     text,
  nf_arquivo     text,
  nf_link        text
)
language sql stable security definer set search_path = public as $fn$
  select p.numero, p.cliente, p.descricao, p.status,
         p.producao_em, p.agendado_em, p.pronto_em, p.transito_em, p.entregue_em,
         p.previsao, p.localizacao, p.recebido_por,
         p.transportadora, p.motorista, p.telefone,
         p.nota_fiscal, p.observacao, p.nf_arquivo, p.nf_link
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
-- 5. PDF DAS NOTAS FISCAIS — bucket aberto por link
--    Igual ao Google Drive de hoje: quem tem o link abre o PDF,
--    e o rastreio entrega esse link junto com o pedido. O nome
--    do arquivo é sorteado pelo ADM, então não dá para adivinhar
--    o link de uma NF, e o bucket não pode ser listado por fora.
--    Só quem entrou no ADM envia, troca ou apaga.
-- ------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('rastreio-nf', 'rastreio-nf', true, 10485760, array['application/pdf'])
on conflict (id) do update
  set public             = excluded.public,
      file_size_limit    = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "rastreio nf ver"    on storage.objects;
drop policy if exists "rastreio nf enviar" on storage.objects;
drop policy if exists "rastreio nf trocar" on storage.objects;
drop policy if exists "rastreio nf apagar" on storage.objects;

create policy "rastreio nf ver" on storage.objects for select to authenticated
  using (bucket_id = 'rastreio-nf' and public.rastreio_pode());
create policy "rastreio nf enviar" on storage.objects for insert to authenticated
  with check (bucket_id = 'rastreio-nf' and public.rastreio_pode());
create policy "rastreio nf trocar" on storage.objects for update to authenticated
  using (bucket_id = 'rastreio-nf' and public.rastreio_pode())
  with check (bucket_id = 'rastreio-nf' and public.rastreio_pode());
create policy "rastreio nf apagar" on storage.objects for delete to authenticated
  using (bucket_id = 'rastreio-nf' and public.rastreio_pode());


-- ------------------------------------------------------------
-- 6. LIBERAR E BLOQUEAR O LOGIN DO ADM
--    Só funcionam no SQL Editor; pelo app ninguém chama.
--
--    p_so_rastreio = true  -> a conta serve SÓ para o ADM: some do
--                             cadastro do Estoque Livre / Ferramentas
--                             e não abre esses apps. É o caso do
--                             login compartilhado.
--    p_so_rastreio = false -> a conta continua valendo nos outros
--                             apps e passa a abrir o ADM também.
-- ------------------------------------------------------------
create or replace function public.rastreio_liberar(p_email text, p_so_rastreio boolean)
returns text language plpgsql security definer set search_path = public as $fn$
declare
  v_email text := lower(btrim(p_email));
  v_id    uuid;
  v_papel text;
begin
  select u.id into v_id from auth.users u where lower(u.email) = v_email;
  if v_id is null then
    raise exception 'A conta % nao existe. Crie primeiro em Authentication > Users.', v_email;
  end if;

  if p_so_rastreio and to_regclass('public.perfis') is not null then
    execute 'select papel from public.perfis where id = $1' into v_papel using v_id;
    -- trava contra apagar por engano o perfil de alguém que já usa os outros apps
    if v_papel in ('admin', 'estoque') then
      raise exception 'A conta % e % nos outros apps. Para libera-la no ADM sem tira-la de la, use rastreio_liberar(email, false).', v_email, v_papel;
    end if;
    execute 'delete from public.perfis where id = $1' using v_id;
  end if;

  insert into public.rastreio_acesso (usuario_id, email)
  values (v_id, v_email)
  on conflict (usuario_id) do update set email = excluded.email;

  return 'Liberado no ADM do rastreio: ' || v_email;
end; $fn$;

create or replace function public.rastreio_bloquear(p_email text)
returns text language plpgsql security definer set search_path = public as $fn$
declare
  v_email text := lower(btrim(p_email));
  v_n     int;
begin
  delete from public.rastreio_acesso a
  using auth.users u
  where u.id = a.usuario_id and lower(u.email) = v_email;
  get diagnostics v_n = row_count;
  if v_n = 0 then
    return 'Nada a fazer: ' || v_email || ' nao estava liberado.';
  end if;
  return 'Bloqueado no ADM do rastreio: ' || v_email;
end; $fn$;

revoke all on function public.rastreio_liberar(text, boolean) from public, anon, authenticated;
revoke all on function public.rastreio_bloquear(text)         from public, anon, authenticated;


-- ------------------------------------------------------------
-- 7. DEPOIS DE RODAR ESTE ARQUIVO
--    a) Crie a conta do ADM em Authentication > Users > Add user,
--       marcando "Auto Confirm User". A senha é você quem escolhe.
--    b) Libere essa conta (troque o e-mail pelo que você criou):
--
--         select public.rastreio_liberar('EMAIL-DA-CONTA-DO-ADM', true);
--
--    Para trocar a senha depois, sem mexer no app: em
--    Authentication > Users, apague a conta, crie de novo com o
--    mesmo e-mail e a senha nova, e rode outra vez a linha do
--    item (b). Os pedidos não são afetados.
-- ------------------------------------------------------------

select 'Rastreio: banco pronto.' as resultado;
