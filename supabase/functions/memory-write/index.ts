import { createClient } from "npm:@supabase/supabase-js@2.57.4";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const allowedTypes = new Set([
  "episode",
  "fact",
  "decision",
  "intention",
  "project",
  "reflection",
  "preference",
  "procedure",
  "identity",
  "hypothesis",
]);

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
    if (!body || typeof body !== "object" || Array.isArray(body)) {
      return Response.json(
        { error: "JSON object required" },
        { status: 400, headers: corsHeaders },
      );
    }

    const eventKey = String(body.event_key ?? "").trim();
    const memoryType = String(body.memory_type ?? "").trim();
    const title = String(body.title ?? "").trim();
    const content = String(body.content ?? "").trim();

    if (!eventKey) {
      return Response.json(
        { error: "event_key is required" },
        { status: 400, headers: corsHeaders },
      );
    }
    if (!allowedTypes.has(memoryType)) {
      return Response.json(
        { error: "Invalid memory_type" },
        { status: 400, headers: corsHeaders },
      );
    }
    if (!title || !content) {
      return Response.json(
        { error: "title and content are required" },
        { status: 400, headers: corsHeaders },
      );
    }

    const normalizedSource = body.source
        && typeof body.source === "object"
        && !Array.isArray(body.source)
      ? { ...body.source, type: body.source.type ?? body.source.source_type }
      : body.source;

    const payload = {
      ...body,
      owner_id: userData.user.id,
      event_key: eventKey,
      memory_type: memoryType,
      title,
      content,
      source: normalizedSource,
    };

    const { data, error } = await supabase.rpc("matrix_remember", {
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
      status: data?.status === "created" ? 201 : 200,
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
