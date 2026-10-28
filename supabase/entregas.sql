-- Caixa de entrega do EyeLearn: onde o aparelho da criança deixa a sessão e o
-- painel do professor a busca.
--
-- Rodar uma vez no projeto Supabase (SQL Editor > New query > colar > Run).
--
-- O que fica aqui: a turma (o identificador público, 16 caracteres hex), a
-- hora de chegada e um bloco cifrado para o professor -- AES-256-GCM com chave
-- tirada de ECDH P-256 com a chave pública dele, que vai no link da turma.
-- Sem a chave privada, que fica só no cofre do painel do professor, ninguém lê
-- o bloco: nem o Supabase, nem quem tiver a chave anon do projeto. Nenhum
-- nome de criança chega aqui; a sessão leva só o código do aluno e medidas.
--
-- O que a chave anon (pública, vai no site) pode fazer: inserir entregas e
-- listar entregas. Não pode alterar nem apagar. Listar é aberto porque o
-- painel não tem conta no Supabase: o que protege o conteúdo é a cifra.

create table if not exists public.entregas (
  id bigint generated always as identity primary key,
  turma text not null check (turma ~ '^[0-9a-f]{16}$'),
  blob text not null,
  criado_em timestamptz not null default now()
);

-- Tamanho do bloco: até 500 mil caracteres. O primeiro limite (20 mil)
-- ficou pequeno quando a sessão passou a levar o percurso do olhar para o
-- time-lapse do painel (uma leitura de um minuto passa disso). Em separado da
-- tabela para valer também em quem já a criou: rodar de novo troca a regra.
alter table public.entregas drop constraint if exists entregas_blob_check;
alter table public.entregas add constraint entregas_blob_check
  check (length(blob) between 60 and 500000);

create index if not exists entregas_por_turma on public.entregas (turma, id);

alter table public.entregas enable row level security;

drop policy if exists "aparelho entrega" on public.entregas;
create policy "aparelho entrega" on public.entregas
  for insert to anon with check (true);

drop policy if exists "painel busca" on public.entregas;
create policy "painel busca" on public.entregas
  for select to anon using (true);

-- Sem política de update nem de delete: com RLS ligado, a chave anon não
-- altera nem apaga nada.
