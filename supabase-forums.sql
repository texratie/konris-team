-- Konri's Team per-mod forums. Run this entire script in Supabase SQL Editor.
-- RLS stays enabled. Public users may read; only GitHub-authenticated users may post.

create table if not exists public.forum_topics (
  id uuid primary key default gen_random_uuid(),
  mod_slug text not null,
  title text not null,
  body text not null default '',
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  name text,
  avatar_url text,
  files jsonb not null default '[]'::jsonb,
  created_at timestamptz not null default now()
);

create table if not exists public.forum_posts (
  id uuid primary key default gen_random_uuid(),
  topic_id uuid not null references public.forum_topics(id) on delete cascade,
  body text not null default '',
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  name text,
  avatar_url text,
  files jsonb not null default '[]'::jsonb,
  created_at timestamptz not null default now()
);

-- Upgrade existing forum tables safely.
alter table public.forum_topics add column if not exists user_id uuid references auth.users(id) on delete cascade default auth.uid();
alter table public.forum_topics alter column user_id set default auth.uid();
alter table public.forum_posts add column if not exists user_id uuid references auth.users(id) on delete cascade default auth.uid();
alter table public.forum_posts alter column user_id set default auth.uid();
alter table public.forum_topics add column if not exists name text;
alter table public.forum_topics add column if not exists avatar_url text;
alter table public.forum_topics add column if not exists files jsonb not null default '[]'::jsonb;
alter table public.forum_posts add column if not exists name text;
alter table public.forum_posts add column if not exists avatar_url text;
alter table public.forum_posts add column if not exists files jsonb not null default '[]'::jsonb;

create index if not exists forum_topics_mod_created_idx
  on public.forum_topics (mod_slug, created_at desc);
create index if not exists forum_posts_topic_created_idx
  on public.forum_posts (topic_id, created_at asc);

alter table public.forum_topics enable row level security;
alter table public.forum_posts enable row level security;

-- Remove any older forum policies first, so permissive legacy policies cannot bypass these rules.
do $$
declare pol record;
begin
  for pol in
    select schemaname, tablename, policyname
    from pg_policies
    where schemaname = 'public' and tablename in ('forum_topics', 'forum_posts')
  loop
    execute format('drop policy if exists %I on %I.%I', pol.policyname, pol.schemaname, pol.tablename);
  end loop;
end
$$;

drop policy if exists "forum topics are readable by everyone" on public.forum_topics;
create policy "forum topics are readable by everyone"
  on public.forum_topics for select
  using (true);

drop policy if exists "GitHub users can create forum topics" on public.forum_topics;
create policy "GitHub users can create forum topics"
  on public.forum_topics for insert
  to authenticated
  with check (
    auth.uid() = user_id
    and auth.jwt() -> 'app_metadata' ->> 'provider' = 'github'
  );

drop policy if exists "Authors can delete their forum topics" on public.forum_topics;
create policy "Authors can delete their forum topics"
  on public.forum_topics for delete
  to authenticated
  using (auth.uid() = user_id);

drop policy if exists "forum posts are readable by everyone" on public.forum_posts;
create policy "forum posts are readable by everyone"
  on public.forum_posts for select
  using (true);

drop policy if exists "GitHub users can create forum posts" on public.forum_posts;
create policy "GitHub users can create forum posts"
  on public.forum_posts for insert
  to authenticated
  with check (
    auth.uid() = user_id
    and auth.jwt() -> 'app_metadata' ->> 'provider' = 'github'
    and exists (
      select 1 from public.forum_topics t
      where t.id = forum_posts.topic_id
    )
  );

drop policy if exists "Authors can delete their forum posts" on public.forum_posts;
create policy "Authors can delete their forum posts"
  on public.forum_posts for delete
  to authenticated
  using (auth.uid() = user_id);

-- Forum attachments reuse the existing public comment-files bucket.
-- Uploaded objects must be inside a folder named after the signed-in user's auth UID.
drop policy if exists "GitHub users can upload forum attachments" on storage.objects;
create policy "GitHub users can upload forum attachments"
  on storage.objects for insert
  to authenticated
  with check (
    bucket_id = 'comment-files'
    and (storage.foldername(name))[1] = auth.uid()::text
    and auth.jwt() -> 'app_metadata' ->> 'provider' = 'github'
  );
