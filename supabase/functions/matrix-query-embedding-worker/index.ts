import postgres from "npm:postgres@3.4.7";

type QueryJob = {
  job_id: number;
  request_id: string;
  owner_id: string;
  query_hash: string;
};

const dbUrl = Deno.env.get("SUPABASE_DB_URL");
if (!dbUrl) throw new Error("SUPABASE_DB_URL is not configured");

const sql = postgres(dbUrl, { max: 1, prepare: false });
const model = new Supabase.ai.Session("gte-small");
const uuidPattern =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const hashPattern = /^[0-9a-f]{32}$/i;

async function digest(value: string): Promise<Uint8Array> {
  return new Uint8Array(
    await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value)),
  );
}

function equal(left: Uint8Array, right: Uint8Array): boolean {
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
    && equal(await digest(supplied), await digest(row.decrypted_secret));
}

function validJob(value: unknown): value is QueryJob {
  if (!value || typeof value !== "object") return false;
  const job = value as Record<string, unknown>;

  return Number.isSafeInteger(job.job_id)
    && Number(job.job_id) > 0
    && typeof job.request_id === "string"
    && uuidPattern.test(job.request_id)
    && typeof job.owner_id === "string"
    && uuidPattern.test(job.owner_id)
    && typeof job.query_hash === "string"
    && hashPattern.test(job.query_hash);
}

async function deleteJob(jobId: number): Promise<void> {
  await sql`select pgmq.delete('matrix_query_embedding_jobs', ${jobId}::bigint)`;
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
      || payload.length > 10
      || !payload.every(validJob)
    ) {
      return Response.json({ error: "Invalid job batch" }, { status: 400 });
    }

    let ready = 0;
    let stale = 0;
    const failed: Array<{ job_id: number; error: string }> = [];

    for (const job of payload) {
      try {
        const [row] = await sql<{
          query_text: string;
          query_hash: string;
          status: string;
        }[]>`
          select query_text, query_hash, status
          from public.matrix_recall_requests
          where id = ${job.request_id}::uuid
            and owner_id = ${job.owner_id}::uuid
          limit 1
        `;

        if (!row || row.query_hash !== job.query_hash) {
          await deleteJob(job.job_id);
          stale += 1;
          continue;
        }

        await sql`
          update public.matrix_recall_requests
          set status = 'processing',
              error = null,
              updated_at = now()
          where id = ${job.request_id}::uuid
            and owner_id = ${job.owner_id}::uuid
            and query_hash = ${job.query_hash}
        `;

        const vector = await model.run(row.query_text, {
          mean_pool: true,
          normalize: true,
        });

        await sql`
          update public.matrix_recall_requests
          set embedding = ${JSON.stringify(vector)}::extensions.vector,
              status = 'ready',
              error = null,
              updated_at = now(),
              expires_at = now() + interval '24 hours'
          where id = ${job.request_id}::uuid
            and owner_id = ${job.owner_id}::uuid
            and query_hash = ${job.query_hash}
        `;

        await deleteJob(job.job_id);
        ready += 1;
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        failed.push({ job_id: job.job_id, error: message.slice(0, 500) });

        await sql`
          update public.matrix_recall_requests
          set status = 'error',
              error = ${message.slice(0, 1000)},
              updated_at = now()
          where id = ${job.request_id}::uuid
            and owner_id = ${job.owner_id}::uuid
            and query_hash = ${job.query_hash}
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
