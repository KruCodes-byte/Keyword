drop function if exists public.delete_keyword_draw_history(uuid, uuid, integer, text);
drop function if exists private.delete_keyword_draw_history(uuid, uuid, integer, text);

create or replace function private.delete_keyword_draw_history(
  p_event_id uuid,
  p_share_id uuid,
  p_current_round_number integer,
  p_writer_token text
) returns integer
language plpgsql security definer set search_path = ''
as $$
declare
  deleted_count integer;
begin
  if p_event_id is null or p_current_round_number < 2
     or length(coalesce(p_writer_token, '')) < 32 then
    raise exception 'invalid history credentials';
  end if;

  if not exists (
    select 1
    from private.keyword_draw_report_writers w
    join public.keyword_draw_reports r on r.share_id = w.share_id
    where r.event_id = p_event_id and w.writer_token = p_writer_token
  ) then
    raise exception 'invalid history credentials';
  end if;

  if p_share_id is not null and not exists (
    select 1 from public.keyword_draw_reports r
    where r.share_id = p_share_id
      and r.event_id = p_event_id
      and r.round_number < p_current_round_number
  ) then
    raise exception 'round not found in event history';
  end if;

  delete from public.keyword_draw_reports r
  where r.event_id = p_event_id
    and r.round_number < p_current_round_number
    and (p_share_id is null or r.share_id = p_share_id);

  get diagnostics deleted_count = row_count;
  return deleted_count;
end;
$$;

create or replace function public.delete_keyword_draw_history(
  p_event_id uuid,
  p_share_id uuid,
  p_current_round_number integer,
  p_writer_token text
) returns integer
language plpgsql security invoker set search_path = ''
as $$
begin
  return private.delete_keyword_draw_history(
    p_event_id, p_share_id, p_current_round_number, p_writer_token
  );
end;
$$;

revoke all on function private.delete_keyword_draw_history(uuid, uuid, integer, text) from public;
grant execute on function private.delete_keyword_draw_history(uuid, uuid, integer, text) to anon, authenticated;
revoke all on function public.delete_keyword_draw_history(uuid, uuid, integer, text) from public;
grant execute on function public.delete_keyword_draw_history(uuid, uuid, integer, text) to anon, authenticated;
