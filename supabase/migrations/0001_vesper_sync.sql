-- Vesper cloud sync schema. Run once in the Supabase SQL Editor.
--
-- Every synced item (workspace, collection, folder, request, environment,
-- history entry) is one row per user. Row Level Security limits each user to
-- their own rows. Secrets are never sent: Vesper keeps them in the OS vault.

create table if not exists public.sync_items (
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  kind text not null check (
    kind in ('workspace', 'collection', 'folder', 'request', 'environment', 'history')
  ),
  id text not null check (char_length(id) between 1 and 200),
  data jsonb,
  deleted boolean not null default false,
  -- When the item last changed on a device (last write wins).
  client_updated_at timestamptz not null,
  -- When the server stored it; devices pull changes after this cursor.
  server_updated_at timestamptz not null default clock_timestamp(),
  primary key (user_id, kind, id),
  constraint sync_items_size check (pg_column_size(data) < 4 * 1024 * 1024)
);

create index if not exists sync_items_user_server_updated
  on public.sync_items (user_id, server_updated_at);

alter table public.sync_items enable row level security;

-- Only signed-in users reach the table through the Data API (works whether or
-- not "Automatically expose new tables" was enabled for the project).
revoke all on public.sync_items from anon;
grant select, insert, update, delete on public.sync_items to authenticated;

drop policy if exists "Users read their own items" on public.sync_items;
create policy "Users read their own items" on public.sync_items
  for select to authenticated using ((select auth.uid()) = user_id);

drop policy if exists "Users add their own items" on public.sync_items;
create policy "Users add their own items" on public.sync_items
  for insert to authenticated with check ((select auth.uid()) = user_id);

drop policy if exists "Users change their own items" on public.sync_items;
create policy "Users change their own items" on public.sync_items
  for update to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

drop policy if exists "Users remove their own items" on public.sync_items;
create policy "Users remove their own items" on public.sync_items
  for delete to authenticated using ((select auth.uid()) = user_id);

-- Stamps the server time and ignores writes older than what is stored, so a
-- device that was offline cannot overwrite a newer change.
create or replace function public.sync_items_before_write()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'UPDATE' and new.client_updated_at < old.client_updated_at then
    return null;
  end if;
  new.server_updated_at := clock_timestamp();
  return new;
end;
$$;

drop trigger if exists sync_items_before_write on public.sync_items;
create trigger sync_items_before_write
  before insert or update on public.sync_items
  for each row execute function public.sync_items_before_write();

-- Live updates to other signed-in devices.
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'sync_items'
  ) then
    alter publication supabase_realtime add table public.sync_items;
  end if;
end;
$$;
