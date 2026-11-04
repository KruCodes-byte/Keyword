create schema if not exists private;
grant usage on schema private to anon, authenticated;

create table if not exists public.keyword_draw_reports (
  share_id uuid primary key,
  event_name text not null default '',
  total_count integer not null default 0 check (total_count >= 0),
  remaining_count integer not null default 0 check (remaining_count >= 0 and remaining_count <= total_count),
  draws jsonb not null default '[]'::jsonb check (jsonb_typeof(draws) = 'array'),
  updated_at timestamptz not null default now()
);
alter table public.keyword_draw_reports enable row level security;
revoke all on table public.keyword_draw_reports from public, anon, authenticated;

create table if not exists private.keyword_draw_report_writers (
  share_id uuid primary key references public.keyword_draw_reports(share_id) on delete cascade,
  writer_token text not null
);
alter table private.keyword_draw_report_writers enable row level security;
revoke all on table private.keyword_draw_report_writers from public, anon, authenticated;

create or replace function private.create_keyword_draw_report(
  p_share_id uuid, p_writer_token text, p_event_name text,
  p_total_count integer, p_remaining_count integer, p_draws jsonb
) returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if p_share_id is null or length(coalesce(p_writer_token, '')) < 32 then
    raise exception 'invalid report credentials';
  end if;
  if p_total_count < 0 or p_remaining_count < 0 or p_remaining_count > p_total_count
     or jsonb_typeof(p_draws) <> 'array' or jsonb_array_length(p_draws) > 5000 then
    raise exception 'invalid report snapshot';
  end if;
  insert into public.keyword_draw_reports(share_id, event_name, total_count, remaining_count, draws)
  values (p_share_id, left(coalesce(p_event_name, ''), 100), p_total_count, p_remaining_count, p_draws);
  insert into private.keyword_draw_report_writers(share_id, writer_token)
  values (p_share_id, p_writer_token);
end;
$$;

create or replace function private.save_keyword_draw_report(
  p_share_id uuid, p_writer_token text, p_event_name text,
  p_total_count integer, p_remaining_count integer, p_draws jsonb
) returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if not exists (
    select 1 from private.keyword_draw_report_writers w
    where w.share_id = p_share_id and w.writer_token = p_writer_token
  ) then
    raise exception 'invalid report credentials';
  end if;
  if p_total_count < 0 or p_remaining_count < 0 or p_remaining_count > p_total_count
     or jsonb_typeof(p_draws) <> 'array' or jsonb_array_length(p_draws) > 5000 then
    raise exception 'invalid report snapshot';
  end if;
  update public.keyword_draw_reports r
  set event_name = left(coalesce(p_event_name, ''), 100),
      total_count = p_total_count,
      remaining_count = p_remaining_count,
      draws = p_draws,
      updated_at = now()
  where r.share_id = p_share_id;
  if not found then raise exception 'report not found'; end if;
end;
$$;

create or replace function private.read_keyword_draw_report(p_share_id uuid)
returns jsonb
language sql stable security definer set search_path = ''
as $$
  select jsonb_build_object(
    'share_id', r.share_id,
    'event_name', r.event_name,
    'total_count', r.total_count,
    'remaining_count', r.remaining_count,
    'draws', r.draws,
    'updated_at', r.updated_at
  )
  from public.keyword_draw_reports r
  where r.share_id = p_share_id;
$$;

create or replace function public.create_keyword_draw_report(
  p_share_id uuid, p_writer_token text, p_event_name text,
  p_total_count integer, p_remaining_count integer, p_draws jsonb
) returns void
language plpgsql security invoker set search_path = ''
as $$
begin
  perform private.create_keyword_draw_report(
    p_share_id, p_writer_token, p_event_name, p_total_count, p_remaining_count, p_draws
  );
end;
$$;

create or replace function public.save_keyword_draw_report(
  p_share_id uuid, p_writer_token text, p_event_name text,
  p_total_count integer, p_remaining_count integer, p_draws jsonb
) returns void
language plpgsql security invoker set search_path = ''
as $$
begin
  perform private.save_keyword_draw_report(
    p_share_id, p_writer_token, p_event_name, p_total_count, p_remaining_count, p_draws
  );
end;
$$;

create or replace function public.get_keyword_draw_report(p_share_id uuid)
returns jsonb
language sql stable security invoker set search_path = ''
as $$
  select private.read_keyword_draw_report(p_share_id);
$$;

revoke all on function private.create_keyword_draw_report(uuid, text, text, integer, integer, jsonb) from public;
revoke all on function private.save_keyword_draw_report(uuid, text, text, integer, integer, jsonb) from public;
revoke all on function private.read_keyword_draw_report(uuid) from public;
grant execute on function private.create_keyword_draw_report(uuid, text, text, integer, integer, jsonb) to anon, authenticated;
grant execute on function private.save_keyword_draw_report(uuid, text, text, integer, integer, jsonb) to anon, authenticated;
grant execute on function private.read_keyword_draw_report(uuid) to anon, authenticated;

revoke all on function public.create_keyword_draw_report(uuid, text, text, integer, integer, jsonb) from public;
revoke all on function public.save_keyword_draw_report(uuid, text, text, integer, integer, jsonb) from public;
revoke all on function public.get_keyword_draw_report(uuid) from public;
grant usage on schema public to anon, authenticated;
grant execute on function public.create_keyword_draw_report(uuid, text, text, integer, integer, jsonb) to anon, authenticated;
grant execute on function public.save_keyword_draw_report(uuid, text, text, integer, integer, jsonb) to anon, authenticated;
grant execute on function public.get_keyword_draw_report(uuid) to anon, authenticated;

create or replace function private.broadcast_keyword_draw_report()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  perform realtime.broadcast_changes(
    'keyword-draw:' || new.share_id::text,
    tg_op, tg_op, tg_table_name, tg_table_schema, new, old
  );
  return null;
end;
$$;
drop trigger if exists keyword_draw_report_broadcast on public.keyword_draw_reports;
create trigger keyword_draw_report_broadcast
after insert or update on public.keyword_draw_reports
for each row execute function private.broadcast_keyword_draw_report();

do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'realtime' and tablename = 'messages'
      and policyname = 'keyword_draw_share_channel_read'
  ) then
    execute $policy$
      create policy keyword_draw_share_channel_read
      on realtime.messages for select to anon, authenticated
      using (realtime.topic() ~ '^keyword-draw:[0-9a-f-]{36}$')
    $policy$;
  end if;
end;
$$;
