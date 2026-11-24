create schema haru_private;
revoke all on schema haru_private from public, anon, authenticated;

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  nickname varchar(30),
  village_name varchar(50) not null default '나의 하루랜드',
  created_at timestamptz not null default now(),
  check (nickname is null or btrim(nickname) <> ''),
  check (btrim(village_name) <> '')
);

create table public.diary_entries (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  entry_date date not null check (isfinite(entry_date)),
  title varchar(100),
  content text not null check (content ~ '[^[:space:]]' and length(content) <= 20000),
  analysis_status text not null default 'pending' check (analysis_status in ('pending', 'completed')),
  analysis_source text check (analysis_source in ('mock', 'manual')),
  revision integer not null default 1 check (revision > 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check ((analysis_status = 'pending') = (analysis_source is null))
);

create index diary_entries_owner_date_idx
  on public.diary_entries (user_id, entry_date desc, created_at desc, id);

create table public.diary_activities (
  diary_id uuid not null references public.diary_entries(id) on delete cascade,
  activity_type text not null check (activity_type in ('study', 'exercise', 'rest', 'social')),
  primary key (diary_id, activity_type)
);

create table public.villages (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null unique references public.profiles(id) on delete cascade,
  level integer not null default 1 check (level >= 1),
  diary_days integer not null default 0 check (diary_days >= 0),
  total_xp bigint not null default 0 check (total_xp >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.village_areas (
  village_id uuid not null references public.villages(id) on delete cascade,
  area_code text not null check (area_code in ('starter', 'east_01', 'south_01')),
  is_unlocked boolean not null,
  primary key (village_id, area_code)
);

create table public.village_buildings (
  village_id uuid not null,
  area_code text not null,
  building_type text not null check (building_type in ('home', 'library', 'gym', 'park', 'cafe')),
  level integer not null check (level >= 0),
  xp bigint not null check (xp >= 0),
  activity_days integer not null check (activity_days >= 0),
  is_unlocked boolean not null,
  primary key (village_id, building_type),
  foreign key (village_id, area_code) references public.village_areas(village_id, area_code) on delete cascade,
  check (is_unlocked = (level > 0))
);

create index village_buildings_area_idx on public.village_buildings (village_id, area_code);

alter table public.profiles enable row level security;
alter table public.diary_entries enable row level security;
alter table public.diary_activities enable row level security;
alter table public.villages enable row level security;
alter table public.village_areas enable row level security;
alter table public.village_buildings enable row level security;

revoke all on public.profiles, public.diary_entries, public.diary_activities,
  public.villages, public.village_areas, public.village_buildings from public, anon, authenticated;
grant select on public.profiles, public.diary_entries, public.diary_activities,
  public.villages, public.village_areas, public.village_buildings to authenticated;
grant update (nickname, village_name) on public.profiles to authenticated;

create policy profiles_read on public.profiles for select to authenticated
  using (id = (select auth.uid()));
create policy profiles_edit on public.profiles for update to authenticated
  using (id = (select auth.uid())) with check (id = (select auth.uid()));
create policy diaries_read on public.diary_entries for select to authenticated
  using (user_id = (select auth.uid()));
create policy activities_read on public.diary_activities for select to authenticated
  using (exists (select 1 from public.diary_entries d
    where d.id = diary_id and d.user_id = (select auth.uid())));
create policy villages_read on public.villages for select to authenticated
  using (user_id = (select auth.uid()));
create policy areas_read on public.village_areas for select to authenticated
  using (exists (select 1 from public.villages v
    where v.id = village_id and v.user_id = (select auth.uid())));
create policy buildings_read on public.village_buildings for select to authenticated
  using (exists (select 1 from public.villages v
    where v.id = village_id and v.user_id = (select auth.uid())));

-- The caller owns the village lock throughout a diary mutation and its recomputation.
create function haru_private.recalculate(p_user_id uuid, p_village_id uuid)
returns void language plpgsql set search_path = '' as $$
declare
  days integer;
  village_level integer;
begin
  select count(distinct entry_date) into days
  from public.diary_entries where user_id = p_user_id;

  village_level := case when days >= 7 then 4 when days >= 3 then 3
                        when days >= 1 then 2 else 1 end;

  update public.villages set diary_days = days, level = village_level,
    total_xp = days::bigint * 10, updated_at = now() where id = p_village_id;

  insert into public.village_areas (village_id, area_code, is_unlocked)
  values (p_village_id, 'starter', true),
         (p_village_id, 'east_01', days >= 3),
         (p_village_id, 'south_01', days >= 7)
  on conflict (village_id, area_code) do update set is_unlocked = excluded.is_unlocked;

  with activity_counts as (
    select a.activity_type, count(distinct d.entry_date)::integer as days
    from public.diary_entries d join public.diary_activities a on a.diary_id = d.id
    where d.user_id = p_user_id
    group by a.activity_type
  ), building_rules(activity_type, building_type, area_code) as (
    values ('study', 'library', 'east_01'), ('exercise', 'gym', 'east_01'),
           ('rest', 'park', 'east_01'), ('social', 'cafe', 'south_01')
  ), building_progress as (
    select r.building_type, r.area_code, coalesce(a.days, 0) as activity_days
    from building_rules r left join activity_counts a using (activity_type)
  )
  insert into public.village_buildings
    (village_id, area_code, building_type, level, xp, activity_days, is_unlocked)
  select p_village_id, area_code, building_type, activity_days / 3,
    activity_days::bigint * 10, activity_days, activity_days >= 3
  from building_progress
  union all
  select p_village_id, 'starter', 'home', least(village_level, 2), 0, 0, true
  on conflict (village_id, building_type) do update set
    level = excluded.level, xp = excluded.xp, activity_days = excluded.activity_days,
    is_unlocked = excluded.is_unlocked;
end;
$$;

create function haru_private.initialize_player(p_user_id uuid)
returns void language plpgsql set search_path = '' as $$
declare
  village_id uuid;
begin
  insert into public.profiles (id) values (p_user_id) on conflict do nothing;
  insert into public.villages (user_id) values (p_user_id)
    on conflict (user_id) do nothing returning id into village_id;
  if village_id is not null then
    perform haru_private.recalculate(p_user_id, village_id);
  end if;
end;
$$;

create function haru_private.handle_signup()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  perform haru_private.initialize_player(new.id);
  return new;
end;
$$;

create trigger haru_initialize_player after insert on auth.users
  for each row execute function haru_private.handle_signup();

select haru_private.initialize_player(id) from auth.users;

create function haru_private.lock_village(p_user_id uuid)
returns uuid language plpgsql set search_path = '' as $$
declare
  village_id uuid;
begin
  if p_user_id is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;
  select id into strict village_id from public.villages where user_id = p_user_id for update;
  return village_id;
end;
$$;

create function haru_private.require_diary(p_user_id uuid, p_diary_id uuid, p_revision integer)
returns public.diary_entries language plpgsql set search_path = '' as $$
declare
  diary public.diary_entries;
begin
  select * into diary from public.diary_entries where id = p_diary_id and user_id = p_user_id;
  if not found then
    raise sqlstate 'PT404' using message = 'Diary not found';
  end if;
  if diary.revision is distinct from p_revision then
    raise sqlstate 'PT409' using message = 'Diary changed; reload and retry';
  end if;
  return diary;
end;
$$;

-- Adapter contract: input is diary text, output is a set of supported activity tags.
create function haru_private.mock_analyze(p_text text)
returns text[] language sql immutable set search_path = '' as $$
  select array(
    select activity_type
    from (values
      ('study', '공부|독서|숙제|study|studied|homework'),
      ('exercise', '운동|달리기|헬스|exercise|workout|running'),
      ('rest', '휴식|쉬었|산책|취미|rested|relax|walk'),
      ('social', '친구|모임|카페|friend|meetup|cafe')
    ) as keywords(activity_type, pattern)
    where p_text ~* pattern
    order by activity_type
  );
$$;

create function public.create_diary(p_entry_date date, p_content text, p_title text default null)
returns public.diary_entries language plpgsql security definer set search_path = '' as $$
declare
  caller uuid := auth.uid();
  village_id uuid := haru_private.lock_village(caller);
  diary public.diary_entries;
begin
  insert into public.diary_entries (user_id, entry_date, content, title)
    values (caller, p_entry_date, p_content, p_title) returning * into diary;
  perform haru_private.recalculate(caller, village_id);
  return diary;
end;
$$;

create function public.update_diary(
  p_id uuid, p_expected_revision integer, p_entry_date date, p_content text, p_title text default null
)
returns public.diary_entries language plpgsql security definer set search_path = '' as $$
declare
  caller uuid := auth.uid();
  village_id uuid := haru_private.lock_village(caller);
  diary public.diary_entries := haru_private.require_diary(caller, p_id, p_expected_revision);
  text_changed boolean := (diary.content, diary.title) is distinct from (p_content, p_title);
begin
  if text_changed then
    delete from public.diary_activities where diary_id = p_id;
  end if;
  update public.diary_entries set entry_date = p_entry_date, content = p_content, title = p_title,
    analysis_status = case when text_changed then 'pending' else diary.analysis_status end,
    analysis_source = case when text_changed then null else diary.analysis_source end,
    revision = diary.revision + 1, updated_at = now()
  where id = p_id returning * into diary;
  perform haru_private.recalculate(caller, village_id);
  return diary;
end;
$$;

create function public.delete_diary(p_id uuid, p_expected_revision integer)
returns void language plpgsql security definer set search_path = '' as $$
declare
  caller uuid := auth.uid();
  village_id uuid := haru_private.lock_village(caller);
begin
  perform haru_private.require_diary(caller, p_id, p_expected_revision);
  delete from public.diary_entries where id = p_id;
  perform haru_private.recalculate(caller, village_id);
end;
$$;

create function haru_private.replace_analysis(p_id uuid, p_source text, p_activities text[])
returns public.diary_entries language plpgsql set search_path = '' as $$
declare
  diary public.diary_entries;
begin
  if p_activities is null or exists (
    select 1 from unnest(p_activities) as tags(activity)
    where activity is null or activity not in ('study', 'exercise', 'rest', 'social')
  ) then
    raise sqlstate 'PT422' using message = 'Provide an array of supported activity tags';
  end if;
  delete from public.diary_activities where diary_id = p_id;
  insert into public.diary_activities (diary_id, activity_type)
    select distinct p_id, activity from unnest(p_activities) as tags(activity);
  update public.diary_entries set analysis_status = 'completed', analysis_source = p_source,
    revision = revision + 1, updated_at = now()
  where id = p_id returning * into diary;
  return diary;
end;
$$;

create function public.analyze_diary(p_id uuid, p_expected_revision integer)
returns public.diary_entries language plpgsql security definer set search_path = '' as $$
declare
  caller uuid := auth.uid();
  village_id uuid := haru_private.lock_village(caller);
  diary public.diary_entries := haru_private.require_diary(caller, p_id, p_expected_revision);
begin
  diary := haru_private.replace_analysis(p_id, 'mock',
    haru_private.mock_analyze(concat_ws(' ', diary.title, diary.content)));
  perform haru_private.recalculate(caller, village_id);
  return diary;
end;
$$;

create function public.set_diary_activities(p_id uuid, p_expected_revision integer, p_activities text[])
returns public.diary_entries language plpgsql security definer set search_path = '' as $$
declare
  caller uuid := auth.uid();
  village_id uuid := haru_private.lock_village(caller);
  diary public.diary_entries;
begin
  perform haru_private.require_diary(caller, p_id, p_expected_revision);
  diary := haru_private.replace_analysis(p_id, 'manual', p_activities);
  perform haru_private.recalculate(caller, village_id);
  return diary;
end;
$$;

revoke execute on all functions in schema haru_private from public, anon, authenticated;
revoke execute on function
  public.create_diary(date, text, text), public.update_diary(uuid, integer, date, text, text),
  public.delete_diary(uuid, integer), public.analyze_diary(uuid, integer),
  public.set_diary_activities(uuid, integer, text[]) from public, anon, authenticated;
grant execute on function
  public.create_diary(date, text, text), public.update_diary(uuid, integer, date, text, text),
  public.delete_diary(uuid, integer), public.analyze_diary(uuid, integer),
  public.set_diary_activities(uuid, integer, text[]) to authenticated;
