alter table public.keyword_draw_reports
  add column if not exists event_id uuid not null default gen_random_uuid(),
  add column if not exists round_number integer not null default 1,
  add column if not exists category text not null default 'M';

alter table public.keyword_draw_reports
  add constraint keyword_draw_reports_round_number_positive check (round_number > 0),
  add constraint keyword_draw_reports_category_check check (category in ('M', 'G')),
  add constraint keyword_draw_reports_event_round_unique unique (event_id, round_number);

drop function if exists public.create_keyword_draw_report(uuid, text, text, integer, integer, jsonb);
drop function if exists public.save_keyword_draw_report(uuid, text, text, integer, integer, jsonb);
drop function if exists public.get_keyword_draw_report(uuid);
drop function if exists private.create_keyword_draw_report(uuid, text, text, integer, integer, jsonb);
drop function if exists private.save_keyword_draw_report(uuid, text, text, integer, integer, jsonb);
drop function if exists private.read_keyword_draw_report(uuid);

create or replace function private.create_keyword_draw_report(
  p_share_id uuid, p_event_id uuid, p_round_number integer, p_category text,
  p_writer_token text, p_event_name text, p_total_count integer,
  p_remaining_count integer, p_draws jsonb
) returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if p_share_id is null or p_event_id is null or length(coalesce(p_writer_token, '')) < 32 then
    raise exception 'invalid report credentials';
  end if;
  if p_round_number < 1 or p_category not in ('M', 'G')
     or p_total_count < 0 or p_remaining_count < 0 or p_remaining_count > p_total_count
     or jsonb_typeof(p_draws) <> 'array' or jsonb_array_length(p_draws) > 5000 then
    raise exception 'invalid report snapshot';
  end if;
  insert into public.keyword_draw_reports(
    share_id, event_id, round_number, category, event_name, total_count, remaining_count, draws
  )
  values (
    p_share_id, p_event_id, p_round_number, p_category,
    left(coalesce(p_event_name, ''), 100), p_total_count, p_remaining_count, p_draws
  );
  insert into private.keyword_draw_report_writers(share_id, writer_token)
  values (p_share_id, p_writer_token);
end;
$$;

create or replace function private.save_keyword_draw_report(
  p_share_id uuid, p_event_id uuid, p_round_number integer, p_category text,
  p_writer_token text, p_event_name text, p_total_count integer,
  p_remaining_count integer, p_draws jsonb
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
  if p_event_id is null or p_round_number < 1 or p_category not in ('M', 'G')
     or p_total_count < 0 or p_remaining_count < 0 or p_remaining_count > p_total_count
     or jsonb_typeof(p_draws) <> 'array' or jsonb_array_length(p_draws) > 5000 then
    raise exception 'invalid report snapshot';
  end if;
  update public.keyword_draw_reports r
  set event_id = p_event_id,
      round_number = p_round_number,
      category = p_category,
      event_name = left(coalesce(p_event_name, ''), 100),
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
    'event_id', r.event_id,
    'round_number', r.round_number,
    'category', r.category,
    'event_name', r.event_name,
    'total_count', r.total_count,
    'remaining_count', r.remaining_count,
    'draws', r.draws,
    'updated_at', r.updated_at,
    'rounds', (
      select coalesce(
        jsonb_agg(jsonb_build_object(
          'share_id', h.share_id,
          'round_number', h.round_number,
          'category', h.category,
          'draw_count', jsonb_array_length(h.draws),
          'event_name', h.event_name
        ) order by h.round_number desc),
        '[]'::jsonb
      )
      from public.keyword_draw_reports h
      where h.event_id = r.event_id
    )
  )
  from public.keyword_draw_reports r
  where r.share_id = p_share_id;
$$;

create or replace function public.create_keyword_draw_report(
  p_share_id uuid, p_event_id uuid, p_round_number integer, p_category text,
  p_writer_token text, p_event_name text, p_total_count integer,
  p_remaining_count integer, p_draws jsonb
) returns void
language plpgsql security invoker set search_path = ''
as $$
begin
  perform private.create_keyword_draw_report(
    p_share_id, p_event_id, p_round_number, p_category, p_writer_token,
    p_event_name, p_total_count, p_remaining_count, p_draws
  );
end;
$$;

create or replace function public.save_keyword_draw_report(
  p_share_id uuid, p_event_id uuid, p_round_number integer, p_category text,
  p_writer_token text, p_event_name text, p_total_count integer,
  p_remaining_count integer, p_draws jsonb
) returns void
language plpgsql security invoker set search_path = ''
as $$
begin
  perform private.save_keyword_draw_report(
    p_share_id, p_event_id, p_round_number, p_category, p_writer_token,
    p_event_name, p_total_count, p_remaining_count, p_draws
  );
end;
$$;

create or replace function public.get_keyword_draw_report(p_share_id uuid)
returns jsonb
language sql stable security invoker set search_path = ''
as $$
  select private.read_keyword_draw_report(p_share_id);
$$;

revoke all on function private.create_keyword_draw_report(uuid, uuid, integer, text, text, text, integer, integer, jsonb) from public;
revoke all on function private.save_keyword_draw_report(uuid, uuid, integer, text, text, text, integer, integer, jsonb) from public;
revoke all on function private.read_keyword_draw_report(uuid) from public;
grant execute on function private.create_keyword_draw_report(uuid, uuid, integer, text, text, text, integer, integer, jsonb) to anon, authenticated;
grant execute on function private.save_keyword_draw_report(uuid, uuid, integer, text, text, text, integer, integer, jsonb) to anon, authenticated;
grant execute on function private.read_keyword_draw_report(uuid) to anon, authenticated;

revoke all on function public.create_keyword_draw_report(uuid, uuid, integer, text, text, text, integer, integer, jsonb) from public;
revoke all on function public.save_keyword_draw_report(uuid, uuid, integer, text, text, text, integer, integer, jsonb) from public;
revoke all on function public.get_keyword_draw_report(uuid) from public;
grant execute on function public.create_keyword_draw_report(uuid, uuid, integer, text, text, text, integer, integer, jsonb) to anon, authenticated;
grant execute on function public.save_keyword_draw_report(uuid, uuid, integer, text, text, text, integer, integer, jsonb) to anon, authenticated;
grant execute on function public.get_keyword_draw_report(uuid) to anon, authenticated;

create or replace function private.broadcast_keyword_draw_report()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  perform realtime.broadcast_changes(
    'keyword-event:' || new.event_id::text,
    tg_op, tg_op, tg_table_name, tg_table_schema, new, old
  );
  return null;
end;
$$;

drop policy if exists keyword_draw_share_channel_read on realtime.messages;
do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'realtime' and tablename = 'messages'
      and policyname = 'keyword_draw_event_channel_read'
  ) then
    execute $policy$
      create policy keyword_draw_event_channel_read
      on realtime.messages for select to anon, authenticated
      using (realtime.topic() ~ '^keyword-event:[0-9a-f-]{36}$')
    $policy$;
  end if;
end;
$$;
