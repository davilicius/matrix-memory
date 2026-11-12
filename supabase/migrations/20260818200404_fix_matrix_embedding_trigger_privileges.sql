
create or replace function private.prepare_matrix_embedding()
returns trigger language plpgsql security definer set search_path='' as $m$
declare v_hash text;
begin
  v_hash:=private.matrix_embedding_hash(new.title,new.summary,new.content,new.place_text);
  if tg_op='INSERT' or v_hash is distinct from old.embedding_input_hash then
    new.embedding:=null;
    new.embedding_status:='pending';
    new.embedding_input_hash:=v_hash;
    new.embedding_updated_at:=null;
    new.embedding_error:=null;
  end if;
  return new;
end $m$;
revoke all on function private.prepare_matrix_embedding() from public,anon,authenticated;
