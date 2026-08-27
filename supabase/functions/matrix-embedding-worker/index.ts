import postgres from "npm:postgres@3.4.7";

type EmbeddingJob = {
  job_id: number;
  memory_id: string;
  owner_id: string;
  input_hash: string;
};

const dbUrl = Deno.env.get("SUPABASE_DB_URL");
if (!dbUrl) throw new Error("SUPABASE_DB_URL is not configured");

const sql = postgres(dbUrl, { max: 1, prepare: false });
const model = new Supabase.ai.Session("gte-small");
const uuidPattern =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const hashPattern = /^[0-9a-f]{32}$/i;

async function sha256(value: string): Promise<Uint8Array> {
  return new Uint8Array(
    await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value)),
  );
}

function equalBytes(left: Uint8Array, right: Uint8Array): boolean {
  if (left.length !== right.length) return false;
  let difference = 0;
  for (let index = 0; index < left.length; index += 1) {
    difference |= left[index] ^ right[index];
  }
  return difference === 0;
}

async function authorized(request: Request): Promise<boolean> {
  const supplied = request.headers.get("x-matrix-worker-secret") ?? "";
  if (!supplied) return false;

  const [row] = await sql<{ decrypted_secret: string }[]>`
    select decrypted_secret
    from vault.decrypted_secrets
    where name = 'matrix_embedding_worker_secret'
    limit 1
  `;

  return Boolean(row?.decrypted_secret)
    && equalBytes(await sha256(supplied), await sha256(row.decrypted_secret));
}

function validJob(value: unknown): value is EmbeddingJob {
  if (!value || typeof value !== "object") return false;
  const job = value as Record<string, unknown>;

  return Number.isSafeInteger(job.job_id)
    && Number(job.job_id) > 0
    && typeof job.memory_id === "string"
    && uuidPattern.test(job.memory_id)
    && typeof job.owner_id === "string"
    && uuidPattern.test(job.owner_id)
    && typeof job.input_hash === "string"
    && hashPattern.test(job.input_hash);
}

async function deleteJob(jobId: number): Promise<void> {
  await sql`select pgmq.delete('matrix_embedding_jobs', ${jobId}::bigint)`;
}

async function processJob(job: EmbeddingJob): Promise<"ready" | "stale"> {
  const [memory] = await sql<{
    id: string;
    title: string;
    summary: string | null;
    content: string;
    place_text: string | null;
    embedding_input_hash: string | null;
  }[]>`
    select id, title, summary, content, place_text, embedding_input_hash
    from public.memory_nodes
    where id = ${job.memory_id}::uuid
      and owner_id = ${job.owner_id}::uuid
    limit 1
  `;

  if (!memory || memory.embedding_input_hash !== job.input_hash) {
    await deleteJob(job.job_id);
    return "stale";
  }

  await sql`
    update public.memory_nodes
    set embedding_status = 'processing',
        embedding_error = null
    where id = ${job.memory_id}::uuid
      and owner_id = ${job.owner_id}::uuid
      and embedding_input_hash = ${job.input_hash}
  `;

  const input = [
    memory.title ?? "",
    memory.summary ?? "",
    memory.content ?? "",
    memory.place_text ?? "",
  ].join("\n\n");
  const embedding = await model.run(input, {
    mean_pool: true,
    normalize: true,
  });

  const result = await sql`
    update public.memory_nodes
    set embedding = ${JSON.stringify(embedding)}::extensions.vector,
        embedding_model = 'Supabase/gte-small',
        embedding_status = 'ready',
        embedding_updated_at = now(),
        embedding_error = null
    where id = ${job.memory_id}::uuid
      and owner_id = ${job.owner_id}::uuid
      and embedding_input_hash = ${job.input_hash}
    returning id
  `;

  if (result.length === 0) {
    await deleteJob(job.job_id);
    return "stale";
  }

  await deleteJob(job.job_id);
  return "ready";
}

Deno.serve(async (request: Request) => {
  if (request.method !== "POST") {
    return Response.json({ error: "Method not allowed" }, { status: 405 });
  }

  try {
    if (!(await authorized(request))) {
      return Response.json({ error: "Unauthorized" }, { status: 401 });
    }

    const payload: unknown = await request.json();
    if (
      !Array.isArray(payload)
      || payload.length < 1
      || payload.length > 50
      || !payload.every(validJob)
    ) {
      return Response.json({ error: "Invalid job batch" }, { status: 400 });
    }

    let ready = 0;
    let stale = 0;
    const failed: Array<{ job_id: number; error: string }> = [];

    for (const job of payload) {
      try {
        const status = await processJob(job);
        if (status === "ready") ready += 1;
        else stale += 1;
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        failed.push({ job_id: job.job_id, error: message.slice(0, 500) });

        await sql`
          update public.memory_nodes
          set embedding_status = 'error',
              embedding_error = ${message.slice(0, 1000)}
          where id = ${job.memory_id}::uuid
            and owner_id = ${job.owner_id}::uuid
            and embedding_input_hash = ${job.input_hash}
        `;
      }
    }

    return Response.json({ ready, stale, failed });
  } catch (error) {
    return Response.json(
      { error: error instanceof Error ? error.message : String(error) },
      { status: 500 },
    );
  }
});

addEventListener("beforeunload", () => {
  void sql.end({ timeout: 0 });
});
