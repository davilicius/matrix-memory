import { createClient } from "npm:@supabase/supabase-js@2.57.4";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

Deno.serve(async (request: Request) => {
  if (request.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  if (request.method !== "POST") {
    return Response.json(
      { error: "Method not allowed" },
      { status: 405, headers: corsHeaders },
    );
  }

  try {
    const authorization = request.headers.get("Authorization");
    if (!authorization) {
      return Response.json(
        { error: "Missing authorization" },
        { status: 401, headers: corsHeaders },
      );
    }

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_ANON_KEY")!,
      { global: { headers: { Authorization: authorization } } },
    );

    const { data: userData, error: userError } = await supabase.auth.getUser();
    if (userError || !userData.user) {
      return Response.json(
        { error: "Invalid session" },
        { status: 401, headers: corsHeaders },
      );
    }

    const body = await request.json();
    const query = String(body.query ?? "").trim();
    if (!query) {
      return Response.json(
        { error: "query is required" },
        { status: 400, headers: corsHeaders },
      );
    }

    const limit = Math.min(Math.max(Number(body.limit ?? 12), 1), 30);
    const hops = Math.min(Math.max(Number(body.hops ?? 1), 0), 2);
    const model = new Supabase.ai.Session("gte-small");
    const rawEmbedding = await model.run(query, {
      mean_pool: true,
      normalize: true,
    });
    const queryEmbedding = Array.from(rawEmbedding as ArrayLike<number>);

    const payload = {
      ...body,
      owner_id: userData.user.id,
      query,
      limit,
      hops,
      query_embedding: queryEmbedding,
      channel: "edge",
    };

    const { data, error } = await supabase.rpc("matrix_recall", {
      p_payload: payload,
    });

    if (error) {
      return Response.json(
        { error: error.message },
        {
          status: 400,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        },
      );
    }

    return Response.json(data, {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  } catch (error) {
    return Response.json(
      { error: error instanceof Error ? error.message : String(error) },
      {
        status: 500,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      },
    );
  }
});
