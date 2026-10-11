-- Vesper: only signed-in users may call the team workspace functions.
-- Run once in the Supabase SQL Editor, after 0002_team_workspaces.sql.
--
-- Postgres grants EXECUTE on new functions to PUBLIC, so revoking from anon
-- alone (as 0002 did) is not enough. The functions already refuse to do
-- anything without a signed-in user; this removes them from the anonymous
-- API altogether.

do $$
declare
  fn text;
begin
  foreach fn in array array[
    'public.share_workspace(text, text)',
    'public.accept_workspace_invites()',
    'public.is_workspace_member(text)',
    'public.is_workspace_owner(text)',
    'public.current_email()'
  ] loop
    execute format('revoke execute on function %s from public, anon', fn);
    execute format('grant execute on function %s to authenticated', fn);
  end loop;
end;
$$;

-- Trigger functions are never called through the API.
revoke execute on function public.sync_items_before_write() from public, anon, authenticated;
revoke execute on function public.shared_items_before_write() from public, anon, authenticated;
