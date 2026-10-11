-- Vesper team workspaces. Run once in the Supabase SQL Editor, after
-- 0001_vesper_sync.sql.
--
-- A shared workspace has members (owner + members). Its collections,
-- folders, requests and environments are stored in shared_items, readable and
-- writable by every member. History and secrets are never shared.

-- ------------------------------------------------------------------ tables

create table if not exists public.team_workspaces (
  id text primary key check (char_length(id) between 1 and 200),
  owner_id uuid not null references auth.users (id) on delete cascade,
  name text not null default 'Workspace',
  created_at timestamptz not null default now()
);

create table if not exists public.workspace_members (
  workspace_id text not null references public.team_workspaces (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  email text not null default '',
  role text not null default 'member' check (role in ('owner', 'member')),
  added_at timestamptz not null default now(),
  primary key (workspace_id, user_id)
);

create table if not exists public.workspace_invites (
  workspace_id text not null references public.team_workspaces (id) on delete cascade,
  email text not null check (email = lower(email) and position('@' in email) > 1),
  invited_by uuid not null default auth.uid() references auth.users (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (workspace_id, email)
);

create table if not exists public.shared_items (
  workspace_id text not null references public.team_workspaces (id) on delete cascade,
  kind text not null check (kind in ('workspace', 'collection', 'folder', 'request', 'environment')),
  id text not null check (char_length(id) between 1 and 200),
  data jsonb,
  deleted boolean not null default false,
  client_updated_at timestamptz not null,
  server_updated_at timestamptz not null default clock_timestamp(),
  updated_by uuid default auth.uid(),
  primary key (workspace_id, kind, id),
  constraint shared_items_size check (pg_column_size(data) < 4 * 1024 * 1024)
);

create index if not exists shared_items_workspace_server_updated
  on public.shared_items (workspace_id, server_updated_at);
create index if not exists workspace_members_user on public.workspace_members (user_id);
create index if not exists workspace_invites_email on public.workspace_invites (email);

-- --------------------------------------------------------------- helpers
-- security definer so policies can check membership without recursing.

create or replace function public.is_workspace_member(ws text)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.workspace_members m
    where m.workspace_id = ws and m.user_id = (select auth.uid())
  );
$$;

create or replace function public.is_workspace_owner(ws text)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.team_workspaces w
    where w.id = ws and w.owner_id = (select auth.uid())
  );
$$;

create or replace function public.current_email()
returns text
language sql stable set search_path = ''
as $$
  select lower(coalesce((select auth.jwt()) ->> 'email', ''));
$$;

-- Shares one of the caller's workspaces: creates it with the caller as owner.
create or replace function public.share_workspace(ws text, ws_name text)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if (select auth.uid()) is null then
    raise exception 'Not signed in';
  end if;
  insert into public.team_workspaces (id, owner_id, name)
  values (ws, (select auth.uid()), coalesce(nullif(ws_name, ''), 'Workspace'))
  on conflict (id) do update set name = excluded.name
  where public.team_workspaces.owner_id = (select auth.uid());
  if not public.is_workspace_owner(ws) then
    raise exception 'This workspace belongs to someone else';
  end if;
  insert into public.workspace_members (workspace_id, user_id, email, role)
  values (ws, (select auth.uid()), public.current_email(), 'owner')
  on conflict (workspace_id, user_id) do update set role = 'owner';
end;
$$;

-- Turns invites addressed to the caller's verified email into memberships.
create or replace function public.accept_workspace_invites()
returns integer
language plpgsql security definer set search_path = ''
as $$
declare
  accepted integer;
begin
  if (select auth.uid()) is null or public.current_email() = '' then
    return 0;
  end if;
  insert into public.workspace_members (workspace_id, user_id, email, role)
  select i.workspace_id, (select auth.uid()), i.email, 'member'
  from public.workspace_invites i
  where i.email = public.current_email()
  on conflict (workspace_id, user_id) do nothing;
  get diagnostics accepted = row_count;
  delete from public.workspace_invites where email = public.current_email();
  return accepted;
end;
$$;

revoke all on function public.share_workspace(text, text) from anon;
revoke all on function public.accept_workspace_invites() from anon;
grant execute on function public.share_workspace(text, text) to authenticated;
grant execute on function public.accept_workspace_invites() to authenticated;
grant execute on function public.is_workspace_member(text) to authenticated;
grant execute on function public.is_workspace_owner(text) to authenticated;
grant execute on function public.current_email() to authenticated;

-- ------------------------------------------------------- row level security

alter table public.team_workspaces enable row level security;
alter table public.workspace_members enable row level security;
alter table public.workspace_invites enable row level security;
alter table public.shared_items enable row level security;

revoke all on public.team_workspaces, public.workspace_members,
  public.workspace_invites, public.shared_items from anon;
grant select, update, delete on public.team_workspaces to authenticated;
grant select, delete on public.workspace_members to authenticated;
grant select, insert, delete on public.workspace_invites to authenticated;
grant select, insert, update on public.shared_items to authenticated;

drop policy if exists "Members see their workspaces" on public.team_workspaces;
create policy "Members see their workspaces" on public.team_workspaces
  for select to authenticated using (public.is_workspace_member(id));

drop policy if exists "Owners rename workspaces" on public.team_workspaces;
create policy "Owners rename workspaces" on public.team_workspaces
  for update to authenticated
  using (owner_id = (select auth.uid()))
  with check (owner_id = (select auth.uid()));

drop policy if exists "Owners delete workspaces" on public.team_workspaces;
create policy "Owners delete workspaces" on public.team_workspaces
  for delete to authenticated using (owner_id = (select auth.uid()));

drop policy if exists "Members see each other" on public.workspace_members;
create policy "Members see each other" on public.workspace_members
  for select to authenticated using (public.is_workspace_member(workspace_id));

drop policy if exists "Owners remove members, members leave" on public.workspace_members;
create policy "Owners remove members, members leave" on public.workspace_members
  for delete to authenticated using (
    (public.is_workspace_owner(workspace_id) and role <> 'owner')
    or (user_id = (select auth.uid()) and role <> 'owner')
  );

drop policy if exists "Owners and invitees see invites" on public.workspace_invites;
create policy "Owners and invitees see invites" on public.workspace_invites
  for select to authenticated using (
    public.is_workspace_owner(workspace_id) or email = public.current_email()
  );

drop policy if exists "Owners invite" on public.workspace_invites;
create policy "Owners invite" on public.workspace_invites
  for insert to authenticated with check (
    public.is_workspace_owner(workspace_id) and invited_by = (select auth.uid())
  );

drop policy if exists "Owners cancel invites" on public.workspace_invites;
create policy "Owners cancel invites" on public.workspace_invites
  for delete to authenticated using (public.is_workspace_owner(workspace_id));

drop policy if exists "Members read shared items" on public.shared_items;
create policy "Members read shared items" on public.shared_items
  for select to authenticated using (public.is_workspace_member(workspace_id));

drop policy if exists "Members add shared items" on public.shared_items;
create policy "Members add shared items" on public.shared_items
  for insert to authenticated with check (public.is_workspace_member(workspace_id));

drop policy if exists "Members change shared items" on public.shared_items;
create policy "Members change shared items" on public.shared_items
  for update to authenticated
  using (public.is_workspace_member(workspace_id))
  with check (public.is_workspace_member(workspace_id));

-- ------------------------------------------------- last write wins, realtime

create or replace function public.shared_items_before_write()
returns trigger
language plpgsql set search_path = ''
as $$
begin
  if tg_op = 'UPDATE' and new.client_updated_at < old.client_updated_at then
    return null;
  end if;
  new.server_updated_at := clock_timestamp();
  new.updated_by := (select auth.uid());
  return new;
end;
$$;

drop trigger if exists shared_items_before_write on public.shared_items;
create trigger shared_items_before_write
  before insert or update on public.shared_items
  for each row execute function public.shared_items_before_write();

do $$
declare
  t text;
begin
  foreach t in array array['shared_items', 'workspace_members'] loop
    if not exists (
      select 1 from pg_publication_tables
      where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t
    ) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end;
$$;
