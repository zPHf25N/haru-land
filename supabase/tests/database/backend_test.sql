begin;

-- One TAP test wraps the integration scenario. Any assertion aborts the run.
set local plpgsql.check_asserts = on;
select '1..1';

insert into auth.users (id) values
  ('10000000-0000-0000-0000-000000000001'),
  ('20000000-0000-0000-0000-000000000001');

set local role authenticated;
set local request.jwt.claim.sub = '10000000-0000-0000-0000-000000000001';

do $test$
declare
  first_diary public.diary_entries;
  duplicate_diary public.diary_entries;
  extra_diary public.diary_entries;
  idx integer;
begin
  assert (select count(*) = 1 from public.profiles), 'profile signup and RLS';
  assert (select level = 1 and total_xp = 0 from public.villages), 'starting village';
  assert (select level = 1 from public.village_buildings where building_type = 'home'), 'starting home';
  update public.profiles set nickname = '하루';
  assert (select nickname = '하루' from public.profiles);

  begin
    perform public.create_diary('2026-11-01', E' \n\t ');
    assert false, 'whitespace diary accepted';
  exception when check_violation then null;
  end;

  first_diary := public.create_diary('2026-11-01', '공부하고 친구를 만났다.');
  assert first_diary.analysis_status = 'pending';
  assert (select level = 2 and total_xp = 10 from public.villages), 'first diary reaches level 2';
  assert (select level = 2 from public.village_buildings where building_type = 'home');
  duplicate_diary := public.create_diary('2026-11-01', '공부와 운동');
  assert (select diary_days = 1 and total_xp = 10 from public.villages), 'duplicate date XP';

  first_diary := public.analyze_diary(first_diary.id, first_diary.revision);
  duplicate_diary := public.analyze_diary(duplicate_diary.id, duplicate_diary.revision);
  assert first_diary.analysis_source = 'mock';
  assert (select count(*) = 2 from public.diary_activities where diary_id = first_diary.id);
  assert (select activity_days = 1 and xp = 10 from public.village_buildings where building_type = 'library');

  begin
    perform public.set_diary_activities(first_diary.id, first_diary.revision, array['invalid']);
    assert false, 'invalid analysis accepted';
  exception when sqlstate 'PT422' then null;
  end;
  assert (select count(*) = 2 from public.diary_activities where diary_id = first_diary.id);

  for idx in 2..7 loop
    extra_diary := public.create_diary(make_date(2026, 11, idx), '기록');
    if idx <= 3 then
      extra_diary := public.set_diary_activities(extra_diary.id, extra_diary.revision,
        array['study', 'social', 'study']);
      assert extra_diary.analysis_source = 'manual';
    end if;
    if idx = 3 then
      assert (select is_unlocked from public.village_areas where area_code = 'east_01');
      assert (select is_unlocked and activity_days = 3 from public.village_buildings where building_type = 'library');
      assert (select is_unlocked from public.village_buildings where building_type = 'cafe');
      assert (select not is_unlocked from public.village_areas where area_code = 'south_01');
    end if;
  end loop;

  assert (select level = 4 and total_xp = 70 from public.villages);
  assert (select is_unlocked from public.village_areas where area_code = 'south_01');
  perform public.delete_diary(extra_diary.id, extra_diary.revision);
  assert (select not is_unlocked from public.village_areas where area_code = 'south_01');

  first_diary := public.set_diary_activities(first_diary.id, first_diary.revision, array[]::text[]);
  assert first_diary.analysis_status = 'completed' and first_diary.analysis_source = 'manual';
  assert (select not is_unlocked and activity_days = 2 from public.village_buildings where building_type = 'cafe');
  first_diary := public.analyze_diary(first_diary.id, first_diary.revision);
  assert (select is_unlocked from public.village_buildings where building_type = 'cafe'), 'reanalysis rebuilds activity progress';

  first_diary := public.update_diary(first_diary.id, first_diary.revision, '2026-11-02', first_diary.content);
  assert first_diary.analysis_source = 'mock', 'date-only edit preserves analysis';
  assert (select not is_unlocked from public.village_buildings where building_type = 'cafe'), 'date-only edit moves activity';
  assert (select total_xp = 60 from public.villages), 'other diary preserves original day';
  perform public.delete_diary(duplicate_diary.id, duplicate_diary.revision);
  assert (select total_xp = 50 from public.villages);
  assert (select not is_unlocked from public.village_buildings where building_type = 'library');

  begin
    perform public.analyze_diary(first_diary.id, first_diary.revision - 1);
    assert false, 'stale analysis accepted';
  exception when sqlstate 'PT409' then null;
  end;

  first_diary := public.update_diary(first_diary.id, first_diary.revision, first_diary.entry_date, '수정');
  assert first_diary.analysis_status = 'pending';
  assert not exists (select 1 from public.diary_activities where diary_id = first_diary.id);
  perform set_config('haru_test.diary_id', first_diary.id::text, true);

  begin
    update public.villages set total_xp = 999;
    assert false, 'client XP write accepted';
  exception when insufficient_privilege then null;
  end;
  begin
    insert into public.diary_entries (user_id, entry_date, content)
      values (auth.uid(), current_date, '우회');
    assert false, 'direct diary insert accepted';
  exception when insufficient_privilege then null;
  end;
  begin
    delete from public.diary_activities;
    assert false, 'direct activity delete accepted';
  exception when insufficient_privilege then null;
  end;
end
$test$;

set local request.jwt.claim.sub = '20000000-0000-0000-0000-000000000001';

do $test$
declare
  other_id uuid := current_setting('haru_test.diary_id')::uuid;
begin
  assert not exists (select 1 from public.diary_entries);
  assert not exists (select 1 from public.diary_activities);
  assert (select count(*) = 3 from public.village_areas);
  assert (select count(*) = 5 from public.village_buildings);
  assert (select level = 1 and total_xp = 0 from public.villages);
  begin
    perform public.update_diary(other_id, 1, current_date, '다른 사람의 기록');
    assert false, 'cross-account update accepted';
  exception when sqlstate 'PT404' then null;
  end;
  begin
    perform public.delete_diary(other_id, 1);
    assert false, 'cross-account delete accepted';
  exception when sqlstate 'PT404' then null;
  end;
  begin
    perform public.analyze_diary(other_id, 1);
    assert false, 'cross-account analysis accepted';
  exception when sqlstate 'PT404' then null;
  end;
end
$test$;

set local role anon;
set local request.jwt.claim.sub = '';
do $test$
begin
  begin
    perform 1 from public.diary_entries;
    assert false, 'anonymous diary read accepted';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.create_diary(current_date, '익명');
    assert false, 'anonymous RPC accepted';
  exception when insufficient_privilege then null;
  end;
end
$test$;

reset role;
set local request.jwt.claim.sub = '10000000-0000-0000-0000-000000000001';
set local role authenticated;
do $test$
declare
  diary record;
begin
  for diary in select id, revision from public.diary_entries loop
    perform public.delete_diary(diary.id, diary.revision);
  end loop;
  assert (select level = 1 and diary_days = 0 and total_xp = 0 from public.villages);
  assert (select count(*) = 1 from public.village_areas where is_unlocked);
  assert (select count(*) = 1 from public.village_buildings where is_unlocked);
end
$test$;

reset role;
delete from auth.users where id = '10000000-0000-0000-0000-000000000001';
do $test$
begin
  assert not exists (select 1 from public.profiles where id = '10000000-0000-0000-0000-000000000001');
  assert not exists (select 1 from public.villages where user_id = '10000000-0000-0000-0000-000000000001');
end
$test$;

select 'ok 1 - diary lifecycle, growth, analysis and account isolation';
rollback;
