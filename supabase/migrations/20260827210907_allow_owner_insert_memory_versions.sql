create policy "memory_versions_insert_own"
on public.memory_versions
for insert
to authenticated
with check ((select auth.uid()) = owner_id);
