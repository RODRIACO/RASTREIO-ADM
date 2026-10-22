-- ============================================================
-- Anexo pode ter qualquer nome
-- Projeto Supabase: vgcwzfeucfkaawwwhvjo  (SQL Editor > New query)
--
-- A tabela exigia que o nome comecasse com NF ou CRM. Essa regra sai:
-- o nome passa a ser o do arquivo, seja ele qual for.
--
-- Continua valendo o basico: nome nao vazio e no maximo 40 caracteres
-- (e o que cabe no botao da tela do cliente sem quebrar o layout).
--
-- Rodar de novo nao faz mal.
-- ============================================================

alter table public.rastreio_anexos
  drop constraint if exists rastreio_anexos_nome_ok;

alter table public.rastreio_anexos
  add constraint rastreio_anexos_nome_ok check (
    btrim(nome) <> ''
    and char_length(nome) <= 40
  );
